# Colossus TrueNAS & PBS Integration Runbook

**Version:** v1.0  
**Date:** 2026-02-13  
**Scope:** TrueNAS NFS integration, PBS backup replication, ISO library, backup scheduling  
**Appliance:** TerraMaster F4-423, TrueNAS CE 25.04.2.6  
**PBS:** VM-900 on pve-3, IP 10.10.100.242

---

## 0. Architecture Summary

```
┌──────────────────────────┐       ┌──────────────────────────┐
│  PBS (VM-900, pve-3)     │       │  TrueNAS (10.10.0.38)    │
│                          │       │                          │
│  Datastore: pbs-zfs      │       │  Pool-1/backups/pbs-sync │
│  (local SSD, fast)       │       │  (RAID10 HDD, durable)   │
│                          │  NFS  │                          │
│  Datastore: truenas-sync ├───────┤  Exported via NFS        │
│  (NFS mount, 2nd store)  │       │                          │
│                          │       │  ZFS snapshots (6hr)     │
│  Sync Job: pbs-to-truenas│       │  ← independent safety    │
│  (daily 02:00)           │       │                          │
└──────────────────────────┘       └──────────────────────────┘
```

**Data flow:** All Proxmox nodes back up to PBS → `pbs-zfs` (local SSD). Daily at 02:00, PBS syncs all backups to `truenas-sync` (NFS-mounted TrueNAS HDD). TrueNAS takes independent ZFS snapshots every 6 hours as ransomware protection.

---

## 1. TrueNAS Dataset Layout

```
Pool-1/                          (2× mirror vdevs, RAID10, 7.13 TiB usable)
├── backups/
│   └── pbs-sync/                PBS backup replication target (NFS → PBS)
├── iso/                         Proxmox ISO library (NFS → all nodes)
├── templates/                   VM templates, container images (NFS → all nodes)
├── cold/                        Future: staging area for cold backup to USB
└── scratch/                     General workspace, experiments
```

### 1.1 Dataset Properties

| Dataset | Compression | Atime | Recordsize | Quota |
|---------|-------------|-------|------------|-------|
| Pool-1/backups | zstd | off | inherited | none |
| Pool-1/backups/pbs-sync | zstd | off | 128K | none |
| Pool-1/iso | lz4 | off | 1M | 500 GiB |
| Pool-1/templates | lz4 | off | 1M | 200 GiB |
| Pool-1/cold | zstd | off | 128K | none |
| Pool-1/scratch | lz4 | off | 128K | 500 GiB |

### 1.2 ZFS Snapshot Tasks (TrueNAS-managed)

| Dataset | Schedule | Retention |
|---------|----------|-----------|
| Pool-1/backups/pbs-sync | Every 6 hours (`0 */6 * * *`) | 1 week |
| Pool-1/iso | Daily | 30 days |
| Pool-1/templates | Daily | 30 days |

The pbs-sync snapshots are a critical safety layer — even if an attacker compromises PBS and deletes backups, these ZFS snapshots survive because TrueNAS manages them independently.

---

## 2. NFS Shares

### 2.1 Share Configuration

| Share Path | Maproot User | Maproot Group | Allowed Networks |
|------------|-------------|---------------|-----------------|
| /mnt/Pool-1/backups/pbs-sync | root | wheel | 10.10.100.0/24, 10.10.40.0/24 |
| /mnt/Pool-1/iso | root | wheel | 10.10.100.0/24, 10.10.40.0/24 |
| /mnt/Pool-1/templates | root | wheel | 10.10.100.0/24, 10.10.40.0/24 |

### 2.2 NFS Service Settings (TrueNAS)

- NFSv4: Enabled
- Threads: 4
- Bind IP: 10.10.0.38
- Once NAS VLAN is active: add 10.10.40.x bind, remove 10.10.100.0/24 from allowed networks

---

## 3. Proxmox Cluster NFS Storage

Added cluster-wide (propagates to all nodes):

```bash
pvesm add nfs truenas-iso \
    --server 10.10.0.38 \
    --export /mnt/Pool-1/iso \
    --content iso \
    --options vers=4

pvesm add nfs truenas-templates \
    --server 10.10.0.38 \
    --export /mnt/Pool-1/templates \
    --content vztmpl,images \
    --options vers=4
```

### 3.1 Verification

```bash
# From any Proxmox node
pvesm status | grep truenas
# Expected: truenas-iso and truenas-templates both "active"

# Check mount is writable (ISO library)
ls /mnt/pve/truenas-iso/template/iso/
```

### 3.2 Note: pbs-zfs Storage Scope

The `pbs-zfs` storage definition only exists on pve-3. Restrict it to avoid errors on other nodes:

```bash
pvesm set pbs-zfs --nodes pve-3
```

---

## 4. PBS NFS Mount (VM-900)

### 4.1 fstab Entry

On PBS VM-900 (`ssh root@10.10.100.242`):

```
10.10.0.38:/mnt/Pool-1/backups/pbs-sync /mnt/truenas-pbs nfs rw,hard,nfsvers=4,rsize=1048576,wsize=1048576 0 0
```

Mount options:
- `hard` — retry forever on network issues (don't corrupt data)
- `nfsvers=4` — NFSv4, simpler permission model
- `rsize/wsize=1048576` — 1MB I/O size (matches large PBS chunks, improves HDD throughput)

### 4.2 Verify Mount

```bash
ssh root@10.10.100.242
df -h /mnt/truenas-pbs
# Expected: ~7.2T available on 10.10.0.38:/mnt/Pool-1/backups/pbs-sync
```

### 4.3 Remount After TrueNAS Reboot

If TrueNAS reboots, the NFS mount on PBS should auto-recover due to `hard` option. If manual intervention is needed:

```bash
ssh root@10.10.100.242
mount /mnt/truenas-pbs
systemctl daemon-reload
```

---

## 5. PBS Datastore Configuration

### 5.1 Datastores

```bash
# On PBS VM
proxmox-backup-manager datastore list
```

| Name | Path | Purpose |
|------|------|---------|
| pbs-zfs | /mnt/pbs-datastore | Primary (local SSD, fast restore) |
| truenas-sync | /mnt/truenas-pbs | Secondary (NFS → TrueNAS HDD, durable) |

### 5.2 Datastore Schedules

| Datastore | GC Schedule | Prune Schedule |
|-----------|-------------|----------------|
| pbs-zfs | (default) | (default) |
| truenas-sync | Sun 03:00 | Mon 04:00 |

GC is intentionally weekly and off-peak for truenas-sync because garbage collection on HDD-backed NFS is slow (15-60 min for homelab volume).

### 5.3 Retention Policy

| Datastore | Daily | Weekly | Monthly | Purpose |
|-----------|-------|--------|---------|---------|
| pbs-zfs (SSD) | 14 | 8 | 12 | Primary, fast restore |
| truenas-sync (NFS) | 7 | 4 | 6 | Secondary, space-conscious |

---

## 6. PBS Sync Job

### 6.1 Configuration

```bash
# On PBS VM
proxmox-backup-manager sync-job list
```

| Setting | Value |
|---------|-------|
| ID | pbs-to-truenas |
| Source Store | pbs-zfs |
| Target Store | truenas-sync |
| Schedule | `*-*-* 02:00:00` (daily 02:00) |
| Remove Vanished | true |

### 6.2 Manual Sync

```bash
ssh root@10.10.100.242
proxmox-backup-manager sync-job run pbs-to-truenas
```

### 6.3 Verify Sync Succeeded

1. PBS UI → truenas-sync → Content — should mirror pbs-zfs
2. TrueNAS UI → Datasets → Pool-1/backups/pbs-sync — shows data usage
3. Check PBS task log for `TASK OK`

---

## 7. Backup Job Schedule

### 7.1 Configured Jobs

All jobs configured in `/etc/pve/jobs.cfg` (cluster-wide):

| Job ID | VMID | Name | Type | Node | Schedule | Storage |
|--------|------|------|------|------|----------|---------|
| backup-prod-db | 110 | colossus-prod-db1 | VM | pve-1 | Daily | pbs-1 |
| backup-prod-app | 120 | colossus-prod-app1 | VM | pve-1 | Daily | pbs-1 |
| backup-dev-db-frozen | 200 | colossus-db1-dev | VM | pve-2 | Daily | pbs-1 |
| backup-dev-db | 210 | colossus-dev-db1 | VM | pve-2 | Daily | pbs-1 |
| backup-dev-app | 220 | colossus-dev-app1 | VM | pve-2 | Daily | pbs-1 |
| backup-pihole | 311 | pihole | CT | pve-3 | Daily | pbs-1 |
| backup-cloudflared | 312 | cloudflared | CT | pve-3 | Daily | pbs-1 |
| backup-traefik | 313 | traefik | CT | pve-3 | Daily | pbs-1 |

**Note:** `storage pbs-1` in jobs.cfg is the Proxmox storage ID that maps to PBS datastore `pbs-zfs`.

### 7.2 Not Backed Up

| VMID | Name | Reason |
|------|------|--------|
| 900 | PBS | Cannot back up PBS to itself; rebuildable from config |

### 7.3 Adding a New VM/CT to Backup

Append to `/etc/pve/jobs.cfg` on any Proxmox node:

```
vzdump: backup-<name>
	schedule daily
	compress zstd
	enabled 1
	mode snapshot
	notes-template <Description> scheduled backup
	storage pbs-1
	vmid <VMID>
```

The sync job automatically picks up new backup data — no changes needed on PBS or TrueNAS side.

---

## 8. Nightly Automation Flow

```
 ┌─────────────────────────────────────────────────────────────────┐
 │ Nightly Timeline                                                │
 │                                                                 │
 │  ~00:00   Proxmox vzdump jobs run (8 VMs/CTs → pbs-zfs)       │
 │  02:00    PBS sync job (pbs-zfs → truenas-sync via NFS)        │
 │  03:00    TrueNAS GC on truenas-sync (Sunday only)             │
 │  Every 6h TrueNAS ZFS snapshots of pbs-sync dataset            │
 │  04:00    PBS prune on truenas-sync (Monday only)              │
 └─────────────────────────────────────────────────────────────────┘
```

---

## 9. Disaster Recovery Scenarios

### 9.1 PBS SSD Fails

1. Rebuild PBS VM-900 on pve-3 (or new hardware)
2. Mount TrueNAS NFS share per Section 4
3. Add truenas-sync datastore — all backups are there
4. Restore VMs from truenas-sync datastore
5. Once PBS SSD is replaced, create new pbs-zfs datastore
6. Create reverse sync job (truenas-sync → pbs-zfs) to repopulate

### 9.2 TrueNAS Offline

- No impact on primary backups (pbs-zfs on local SSD continues normally)
- Nightly sync job will fail until TrueNAS is back
- NFS `hard` mount option means PBS will wait (not error out) if TrueNAS is temporarily unreachable
- ISO library temporarily unavailable on Proxmox nodes (existing VMs unaffected)

### 9.3 Ransomware Compromises PBS

- Attacker can delete from pbs-zfs and truenas-sync (PBS has write access)
- TrueNAS ZFS snapshots survive — PBS has no access to them
- Recovery: restore TrueNAS snapshot, re-mount, restore from snapshot data

---

## 10. Troubleshooting

### 10.1 NFS Mount Not Working

```bash
# On PBS VM
showmount -e 10.10.0.38          # Check TrueNAS exports
mount -v /mnt/truenas-pbs        # Verbose mount for errors
```

Common issues:
- TrueNAS NFS service not running → Enable via UI → Services
- Network ACL mismatch → Check Authorized Networks on NFS share
- Firewall blocking NFS → Verify port 2049 reachable

### 10.2 Sync Job Permission Denied

PBS runs as `backup:backup` (UID 34, GID 34). The `.chunks` directory tree must be owned by this user.

```bash
# On TrueNAS web shell
sudo chown -R 34:34 /mnt/Pool-1/backups/pbs-sync/.chunks
```

**Critical lesson learned:** If you ever need to recreate the chunk store directory structure (65,536 directories), do it locally on TrueNAS (fast) rather than over NFS (extremely slow). But you must `chown` to UID 34 afterward:

```bash
# On TrueNAS web shell — creates chunk store structure locally
sudo bash -c 'cd /mnt/Pool-1/backups/pbs-sync && mkdir -p .chunks && for i in $(printf "%04x\n" $(seq 0 65535)); do mkdir -p ".chunks/$i"; done'
sudo chown -R 34:34 /mnt/Pool-1/backups/pbs-sync/.chunks
```

The `proxmox-backup-manager datastore create` command insists on creating `.chunks` itself and will error with `EEXIST` if it already exists. To bypass this, add the datastore config manually:

```bash
# On PBS VM — add datastore via config file instead of create command
cat >> /etc/proxmox-backup/datastore.cfg << 'EOF'

datastore: truenas-sync
    path /mnt/truenas-pbs
    gc-schedule Sun 03:00
    prune-schedule Mon 04:00
EOF

systemctl restart proxmox-backup.service
```

### 10.3 ISO Library Not Visible

```bash
# From any Proxmox node
pvesm status | grep truenas
ls /mnt/pve/truenas-iso/template/iso/
```

If not mounted, check TrueNAS NFS service is running and the share exists.

---

## 11. Key Facts Reference

| Item | Value |
|------|-------|
| TrueNAS IP | 10.10.0.38 |
| TrueNAS Web UI | http://10.10.0.38 |
| TrueNAS SSH | Not enabled by default; use web shell (System → Shell) |
| PBS VM IP | 10.10.100.242 |
| PBS VM QEMU Guest Agent | Not installed |
| PBS datastore (primary) | pbs-zfs at /mnt/pbs-datastore |
| PBS datastore (secondary) | truenas-sync at /mnt/truenas-pbs |
| PBS backup user UID | 34 (backup:backup) |
| NFS version | NFSv4 |
| Pool topology | 2× mirror vdevs (RAID10), 4× 4TB HDD |
| Usable capacity | 7.13 TiB |
| First sync result | 17.7 GiB, 7 groups, 21 MiB/s avg |

---

## 12. Future: NAS VLAN Migration

When VLAN 40 (10.10.40.0/24) is connected to Proxmox nodes:

1. Update NFS mount in PBS fstab: change `10.10.0.38` → `10.10.40.10`
2. Update Proxmox NFS storage entries: `pvesm set truenas-iso --server 10.10.40.10`
3. Update NFS share allowed networks: remove 10.10.100.0/24, keep 10.10.40.0/24
4. This is an IP-address-only change — no architectural changes needed

## 13. Future: Cold/Offline Backup

See `COLOSSUS_TRUENAS_INTEGRATION_DESIGN_v1.md` Section 8 for USB drive cold backup design. Summary: ZFS send/recv via TrueNAS Replication Task to a USB-attached ZFS pool. Plug in monthly, run task, unplug. Completes 3-2-1 rule.
