# Colossus TrueNAS Integration Design
**Version:** v1.0
**Date:** Wednesday, Feb 12, 2026
**Status:** DESIGN — ready for review and execution
**Depends on:** Phase 5B Ansible (automation), Master Context v3

---

## 1. Executive Summary

Integrate the existing TrueNAS appliance (TerraMaster F4-423) into the Colossus homelab
as a secondary backup target and shared storage platform. Primary goals:

1. **PBS backup replication** — sync all PBS backups to TrueNAS for 3-2-1 compliance
2. **Shared ISO/template library** — single NFS share visible to all Proxmox nodes
3. **Future cold backup** — USB-attached drive for air-gapped offline copies
4. **NAS VLAN** — dedicated storage network (10.10.40.0/24) for isolation and future expansion

---

## 2. Current TrueNAS State

### 2.1 Hardware

| Property | Value |
|----------|-------|
| Appliance | TerraMaster F4-423 |
| OS | TrueNAS Community Edition 25.04.2.6 |
| NICs | 2× 2.5GbE (active: 10.10.0.38, secondary: 10.10.0.39) |
| Drives | 4× 4TB HDD |
| Pool | Pool-1 |
| Topology | 2× mirror vdevs, 2 wide (RAID10 equivalent) |
| Usable capacity | 7.13 TiB |
| Used | 251.91 GiB (3.5%) |
| ZFS health | Online, 0 errors |
| Last scrub | 2026-01-11, 8 min 34 sec, 0 errors |
| Auto TRIM | Off (HDDs — not applicable, correct) |

### 2.2 Network Reachability

All Proxmox nodes can reach TrueNAS across subnets (verified):

```
pve-3 (10.10.100.5) → TrueNAS (10.10.0.38): 0.2–0.3ms, TTL=63 (1 router hop)
```

UDM handles inter-VLAN routing between 10.10.100.0/24 and 10.10.0.0/24.

### 2.3 Starting Point

Existing datasets and shares are stale and will be **wiped and reconfigured** from scratch.
Only Pool-1 geometry (2× mirror) is retained.

---

## 3. Target Dataset Layout

All datasets live under `Pool-1`. Naming follows function, not application.

```
Pool-1/
├── backups/
│   └── pbs-sync/          # PBS backup replication target (NFS → PBS)
├── iso/                   # Proxmox ISO library (NFS → all nodes)
├── templates/             # VM templates, container images (NFS → all nodes)
├── cold/                  # Future: staging area for cold backup to USB
└── scratch/               # General workspace, experiments
```

### 3.1 Dataset Properties

| Dataset | Compression | Atime | Recordsize | Quota | Notes |
|---------|-------------|-------|------------|-------|-------|
| Pool-1/backups/pbs-sync | zstd | off | 128K | none | PBS chunks avg 4MB; 128K balances read/write |
| Pool-1/iso | lz4 | off | 1M | 500G | Large files, fast compression |
| Pool-1/templates | lz4 | off | 1M | 200G | Large files |
| Pool-1/cold | zstd | off | 128K | none | Matches pbs-sync for rsync compatibility |
| Pool-1/scratch | lz4 | off | 128K | 500G | General purpose |

**Why 128K for PBS data:** PBS chunks are typically 4MB. ZFS recordsize is a *maximum*,
not a fixed block size. 128K gives good sequential throughput on HDDs without excessive
metadata overhead. The default 128K is the sweet spot.

### 3.2 ZFS Snapshot Policy (TrueNAS-managed)

Configure via TrueNAS UI → Data Protection → Periodic Snapshot Tasks:

| Dataset | Schedule | Retention | Purpose |
|---------|----------|-----------|---------|
| Pool-1/backups/pbs-sync | Every 6 hours | 7 days | Ransomware protection — PBS can't delete these |
| Pool-1/iso | Daily | 30 days | Rollback bad ISOs |
| Pool-1/templates | Daily | 30 days | Template rollback |

This is a critical safety layer: even if an attacker compromises PBS and deletes
backups, the TrueNAS ZFS snapshots survive because they're managed by a completely
separate system that PBS has no access to.

---

## 4. NFS Share Configuration

### 4.1 Shares

Create via TrueNAS UI → Shares → NFS:

| Share Path | Maproot User | Maproot Group | Allowed Networks | Purpose |
|------------|-------------|---------------|-----------------|---------|
| /mnt/Pool-1/backups/pbs-sync | root | wheel | 10.10.100.0/24, 10.10.40.0/24 | PBS sync target |
| /mnt/Pool-1/iso | root | wheel | 10.10.100.0/24, 10.10.40.0/24 | ISO library |
| /mnt/Pool-1/templates | root | wheel | 10.10.100.0/24, 10.10.40.0/24 | Template library |

**Security notes:**
- `maproot=root:wheel` is required because PBS and Proxmox storage operations run as root.
- Network restriction limits access to Proxmox subnets only.
- Once NAS VLAN is active, remove the 10.10.100.0/24 allowance and use 10.10.40.0/24 only.

### 4.2 NFS Service Settings

TrueNAS UI → Services → NFS:
- NFSv4 enabled (preferred for single-subnet, simpler permissions)
- Threads: 4 (adequate for this workload)
- Bind IP: 10.10.0.38 (current), add 10.10.40.x once VLAN is active

---

## 5. PBS Backup Sync Architecture

### 5.1 How It Works

```
┌──────────────────────────┐       ┌──────────────────────────┐
│  PBS (VM-900, pve-3)     │       │  TrueNAS (10.10.0.38)    │
│                          │       │                          │
│  Datastore: pbs-1        │       │  Pool-1/backups/pbs-sync │
│  (local SSD, fast)       │       │  (RAID10 HDD, durable)   │
│                          │  NFS  │                          │
│  Datastore: truenas-sync ├───────┤  Exported via NFS        │
│  (NFS mount, 2nd store)  │       │                          │
│                          │       │  ZFS snapshots (6hr)     │
│  Sync Job: pbs1→truenas  │       │  ← independent safety    │
│  (local, scheduled)      │       │                          │
└──────────────────────────┘       └──────────────────────────┘
```

**Option A is the architecture:** single PBS instance, two datastores, local sync job.

### 5.2 Implementation Steps

**Step 1 — Mount NFS inside PBS VM-900:**

SSH to pve-3, then into PBS VM:

```bash
# On PBS VM-900
mkdir -p /mnt/truenas-pbs
echo "10.10.0.38:/mnt/Pool-1/backups/pbs-sync /mnt/truenas-pbs nfs rw,hard,nfsvers=4,rsize=1048576,wsize=1048576 0 0" >> /etc/fstab
mount /mnt/truenas-pbs
df -h /mnt/truenas-pbs
```

NFS mount options explained:
- `hard` — retry forever on network issues (don't corrupt data)
- `nfsvers=4` — NFSv4, simpler permission model
- `rsize/wsize=1048576` — 1MB I/O size (matches large PBS chunks, improves HDD throughput)

**Step 2 — Add second datastore in PBS:**

PBS Web UI → Configuration → Datastores → Add:

| Setting | Value |
|---------|-------|
| Name | truenas-sync |
| Backing Path | /mnt/truenas-pbs |
| GC Schedule | Sun 03:00 (weekly, off-peak — slow on HDD) |
| Prune Schedule | Mon 04:00 |
| Verify Schedule | Disabled (TrueNAS ZFS checksums handle integrity) |

Or via CLI:

```bash
proxmox-backup-manager datastore create truenas-sync /mnt/truenas-pbs \
    --gc-schedule "Sun 03:00" \
    --prune-schedule "Mon 04:00"
```

**Step 3 — Create local sync job:**

PBS Web UI → Administration → Sync Jobs → Add:

| Setting | Value |
|---------|-------|
| ID | pbs1-to-truenas |
| Local Store (source) | pbs-1 |
| Local Store (target) | truenas-sync |
| Direction | Local (pull from pbs-1 to truenas-sync) |
| Schedule | Daily 02:00 |
| Remove Vanished | Yes |
| Rate Limit | None (local network, plenty of bandwidth) |

Or via CLI:

```bash
proxmox-backup-manager sync-job create pbs1-to-truenas \
    --store truenas-sync \
    --remote-store pbs-1 \
    --schedule "daily 02:00" \
    --remove-vanished true
```

> **Note:** For local sync between two datastores on the same PBS instance,
> you configure it as a sync job where both source and target are local stores.
> No "remote" configuration is needed.

**Step 4 — Verify:**

After first sync runs:
- PBS UI → truenas-sync → Content — should mirror pbs-1
- TrueNAS UI → Storage → Pool-1/backups/pbs-sync — shows `.chunks/` directory tree
- TrueNAS → Data Protection → verify snapshot task is capturing the dataset

### 5.3 Retention Strategy

The two datastores have **independent** retention policies:

| Datastore | Daily | Weekly | Monthly | Purpose |
|-----------|-------|--------|---------|---------|
| pbs-1 (SSD) | 14 | 8 | 12 | Primary, fast restore |
| truenas-sync (NFS) | 7 | 4 | 6 | Secondary, space-conscious |

The TrueNAS copy can keep fewer snapshots because it's a safety net, not the
primary restore source. If pbs-1 is healthy, you always restore from there (faster).

### 5.4 Performance Expectations

PBS sync on HDD-backed NFS will be slower than local SSD, but for your backup volume
this is perfectly fine:

- **First sync:** Copies all existing backup data. At ~200MB/s NFS write over 2.5GbE,
  a 50GB backup set completes in ~4 minutes.
- **Incremental syncs:** PBS deduplication means only new/changed chunks transfer.
  Daily incrementals will likely be seconds to minutes.
- **Garbage collection:** This is the slow operation on HDDs (~100-200 IOPS).
  For a homelab backup set, expect 15-60 minutes. Scheduled weekly on Sunday at 3 AM.

---

## 6. Proxmox ISO/Template Library

### 6.1 Add NFS Storage to Proxmox Cluster

On **any Proxmox node** (propagates cluster-wide):

Datacenter → Storage → Add → NFS:

| Setting | Value |
|---------|-------|
| ID | truenas-iso |
| Server | 10.10.0.38 |
| Export | /mnt/Pool-1/iso |
| Content | ISO Image |
| Nodes | All |

| Setting | Value |
|---------|-------|
| ID | truenas-templates |
| Server | 10.10.0.38 |
| Export | /mnt/Pool-1/templates |
| Content | Container Template, Disk Image |
| Nodes | All |

Or via CLI (from any node):

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

### 6.2 Verification

```bash
# From any node
pvesm status | grep truenas
# Should show truenas-iso and truenas-templates as active

# Upload an ISO to verify write access
ls /mnt/pve/truenas-iso/template/iso/
```

### 6.3 Benefits

- **Single source of truth** — upload an ISO once, available on all three nodes
- **No local disk waste** — ISOs no longer consume pve-1/pve-2/pve-3 local storage
- **Easy cleanup** — delete from TrueNAS, gone everywhere
- **Existing ISOs** — move any ISOs currently on individual nodes to the NFS share

---

## 7. NAS VLAN Strategy (10.10.40.0/24)

### 7.1 Why a Storage VLAN

- **Isolation** — storage traffic separated from VM/management traffic
- **Future expansion** — additional NAS devices, iSCSI targets, S3-compatible storage
- **Security** — firewall rules can restrict storage access to Proxmox nodes only
- **Performance monitoring** — easier to track storage bandwidth vs. other traffic

### 7.2 Current Network Layout

```
10.10.100.0/24  — Proxmox management + VM network
10.10.0.0/24    — General LAN (TrueNAS currently lives here)
10.10.40.0/24   — NAS VLAN (created in UDM, not yet connected)
```

### 7.3 Implementation Plan

**No USB adapters needed.** All three nodes use VLAN tagging on their existing NIC.

#### How VLAN Tagging Works

A single physical NIC carries traffic for multiple VLANs as tagged Ethernet frames.
The switch port is configured as a "trunk" that allows multiple VLAN tags. The OS
creates virtual interfaces (e.g., `eno1.40`) that filter by VLAN tag. This is standard
enterprise practice — no extra hardware required.

```
Physical NIC (eno1)
├── vmbr0 (untagged, VLAN 100) — 10.10.100.x — management + VMs
└── vmbr1 (tagged, VLAN 40)   — 10.10.40.x  — storage
```

#### Per-Node Configuration

**pve-1 (Minisforum MS-02 Ultra):**
- Has multiple NICs (igc + ice)
- Option A: VLAN tag on existing igc NIC (simple, shared bandwidth)
- Option B: Dedicate ice NIC to storage VLAN (10/25GbE, future-proof)
- **Recommendation:** Option B if the ice NIC is a 10GbE+ — physical separation
  eliminates any bandwidth contention and the igc NIC already has known issues.

**pve-2 (BeeLink SER5):**
- Single 2.5GbE NIC
- **Only option:** VLAN tagging on existing NIC
- This is perfectly fine — storage traffic (NFS for ISOs, occasional PBS verify)
  is lightweight for pve-2 (DEV node)

**pve-3 (Dell Precision 7810):**
- Has multiple NICs
- Option A: VLAN tag on existing NIC
- Option B: Dedicate second NIC to storage VLAN
- **Recommendation:** Option B preferred — pve-3 hosts PBS and will generate the
  most NFS traffic (daily sync to TrueNAS)

**TrueNAS (TerraMaster F4-423):**
- 2× 2.5GbE NICs
- Port 1 (10.10.0.38): remains on general LAN for web UI access
- Port 2 (10.10.0.39 → 10.10.40.10): connect to NAS VLAN
- Or: VLAN tag both ports and use LACP for bandwidth aggregation (future)

#### Proxmox Network Config (per node)

Add to `/etc/network/interfaces` (example for VLAN tag approach):

```
auto vmbr1
iface vmbr1 inet static
    address 10.10.40.<node-id>/24
    bridge-ports eno1.40
    bridge-stp off
    bridge-fd 0
```

| Node | Storage VLAN IP |
|------|----------------|
| pve-1 | 10.10.40.3 |
| pve-2 | 10.10.40.4 |
| pve-3 | 10.10.40.5 |
| TrueNAS | 10.10.40.10 |

#### UDM Switch Configuration

For each Proxmox switch port:
- Set port profile to "trunk" or "all"
- Allow VLAN 40 (tagged) + native VLAN (untagged, for 10.10.100.x)

For TrueNAS port 2:
- Set to VLAN 40 (untagged/access) or tagged depending on approach

#### Migration Path

1. Configure UDM VLAN 40 trunk ports
2. Add vmbr1 to each Proxmox node
3. Assign TrueNAS port 2 to 10.10.40.10
4. Update NFS share allowed networks to include 10.10.40.0/24
5. Test NFS mounts via storage VLAN
6. Update Proxmox NFS storage entries to use 10.10.40.10
7. Remove 10.10.100.0/24 from NFS allowed networks
8. Verify all PBS syncs and ISO access work over VLAN 40

### 7.4 Phasing

The VLAN migration is **independent** of the PBS sync and ISO library work.

**Phase 1 (now):** Set up TrueNAS datasets, NFS shares, PBS sync, and ISO library
using the current cross-subnet path (10.10.100.x → 10.10.0.38). This works today.

**Phase 2 (later):** Implement NAS VLAN, migrate NFS mounts to 10.10.40.x, and
lock down network access. This is a network infrastructure change and can be done
at any time without rebuilding anything — just IP address changes in mount configs.

---

## 8. Future: Cold/Offline Backup

### 8.1 Concept

Attach a USB drive to TrueNAS periodically. Copy the pbs-sync dataset to the USB
drive. Disconnect and store offline (fire safe, off-site, etc.).

This completes the 3-2-1 rule:
- **3 copies:** PBS SSD + TrueNAS HDD + USB drive
- **2 media types:** SSD + HDD + USB (rotating media)
- **1 off-site:** USB drive stored physically elsewhere

### 8.2 Implementation (Future)

```
Pool-1/backups/pbs-sync  →  USB drive (ext4 or ZFS)
          │                       │
     ZFS send/recv           or rsync
```

Options:
- **ZFS send/recv** — create a ZFS pool on the USB drive, use `zfs send` incremental
  replication. Most efficient, preserves snapshots.
- **rsync** — simpler, works with any filesystem on the USB drive. Copies files.
- **TrueNAS Replication Task** — built-in UI for ZFS send to external drive.

**Recommendation:** ZFS send via TrueNAS Replication Task. Create a single-disk ZFS
pool on the USB drive (`cold-backup` pool), configure a replication task from
`Pool-1/backups/pbs-sync` to `cold-backup/pbs-sync`. Plug in monthly, run task, unplug.

### 8.3 USB Drive Sizing

Current PBS backup volume is small (VM-110 was 50GB). With all 9 VMs/CTs backed up
and PBS deduplication, expect 100-200GB total backup data. A 1TB USB drive gives
ample room for growth. A 2TB drive gives years of headroom.

---

## 9. Document Storage Considerations

### 9.1 Colossus-Legal Document Corpus

Currently, Colossus-Legal processed documents are stored on the app VM's local
container volume. As the corpus grows (legal documents can be large), consider:

- **TrueNAS NFS share** for document storage
- Mount into app VMs alongside the application containers
- Benefits: documents survive app VM rebuilds, backed up by PBS + TrueNAS snapshots

This is a **future consideration** — not needed until document volume exceeds
what's comfortable on VM local storage.

### 9.2 arXiv Paper Archive (Colossus-AI)

Similar pattern — processed papers could live on TrueNAS NFS, mounted into the
Colossus-AI app VM. Keeps the app VM stateless (rebuild from Butane + Ansible)
while data persists on durable, backed-up storage.

---

## 10. TrueNAS Cleanup Procedure

Since we're treating this as a fresh start:

### 10.1 Remove Old Configuration

1. TrueNAS UI → Shares → delete all existing NFS and SMB shares
2. TrueNAS UI → Datasets → delete all child datasets under Pool-1
   (keep Pool-1 itself — it's the pool root)
3. TrueNAS UI → Data Protection → remove any old snapshot/replication tasks

### 10.2 Create New Datasets

TrueNAS UI → Datasets → Add Dataset (under Pool-1):

Create in this order:
1. `backups` (parent)
2. `backups/pbs-sync` (child)
3. `iso`
4. `templates`
5. `cold`
6. `scratch`

For each dataset, set properties per Section 3.1 table:
- Advanced Options → Compression, Atime, Record Size
- Quotas where specified

### 10.3 Create NFS Shares

Per Section 4.1 table. Enable NFS service if not already running.

### 10.4 Create Snapshot Tasks

Per Section 3.2 table. TrueNAS UI → Data Protection → Periodic Snapshot Tasks.

---

## 11. Execution Order

| Step | Task | Depends On | Phase |
|------|------|-----------|-------|
| 1 | Clean TrueNAS (remove old datasets/shares) | — | Now |
| 2 | Create datasets per Section 3 | Step 1 | Now |
| 3 | Create NFS shares per Section 4 | Step 2 | Now |
| 4 | Create snapshot tasks per Section 3.2 | Step 2 | Now |
| 5 | Add ISO/template NFS storage to Proxmox cluster | Step 3 | Now |
| 6 | Verify ISO library works (upload test ISO) | Step 5 | Now |
| 7 | Mount NFS in PBS VM-900 | Step 3 | Now |
| 8 | Add truenas-sync datastore to PBS | Step 7 | Now |
| 9 | Create PBS local sync job | Step 8 | Now |
| 10 | Run first sync, verify data on TrueNAS | Step 9 | Now |
| 11 | Schedule all remaining VM/CT backups to PBS | Step 10 | Now |
| 12 | Configure NAS VLAN on UDM | — | Later |
| 13 | Add vmbr1 to Proxmox nodes | Step 12 | Later |
| 14 | Assign TrueNAS port 2 to VLAN 40 | Step 12 | Later |
| 15 | Migrate NFS mounts to storage VLAN IPs | Steps 13–14 | Later |
| 16 | Cold backup USB setup | Step 10 | Future |

Steps 1–11 can be done in a single session. Steps 12–15 are a separate network
infrastructure session. Step 16 is whenever you buy a USB drive and want to set it up.

---

## 12. Integration with Phase 5B Ansible

Once Ansible is operational, the TrueNAS integration becomes codified:

- **`truenas-nfs` role:** Ansible manages NFS mount entries in PBS and Proxmox storage configs
- **`pbs-backup` role:** Includes sync job configuration alongside backup job creation
- **Inventory update:** TrueNAS added as a managed host (Ansible can SSH to TrueNAS CE)
- **Validation playbook:** `validate-all.yml` checks NFS mounts are active, PBS sync
  last ran successfully, TrueNAS snapshots exist

For now, manual setup is fine — Ansible codification happens in Phase 5B-2 when we
build the infrastructure roles.

---

## 13. Updated Infrastructure Inventory

With TrueNAS formally integrated:

| ID | Name | Type | Location | IP | Role |
|----|------|------|----------|-----|------|
| 110 | colossus-prod-db1 | VM | pve-1 | 10.10.100.110 | PROD DB |
| 120 | colossus-prod-app1 | VM | pve-1 | 10.10.100.120 | PROD App |
| 200 | colossus-db1-dev | VM | pve-2 | 10.10.100.50 | Frozen ref |
| 210 | colossus-dev-db1 | VM | pve-2 | 10.10.100.200 | DEV DB |
| 220 | colossus-dev-app1 | VM | pve-2 | 10.10.100.220 | DEV App |
| 311 | pihole | CT | pve-3 | 10.10.100.53 | DNS |
| 312 | cloudflared | CT | pve-3 | 10.10.100.54 | Tunnel |
| 313 | traefik | CT | pve-3 | 10.10.100.55 | Reverse proxy |
| 900 | PBS | VM | pve-3 | — | Backups (primary) |
| — | truenas | Appliance | Standalone | 10.10.0.38 | NAS / backup (secondary) |

---

## 14. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| NFS mount failure (network) | Low | PBS sync fails, ISOs unavailable | `hard` mount option retries; manual ISOs on local as fallback |
| TrueNAS pool failure | Very Low | Lose secondary backup + ISOs | RAID10 tolerates 1 disk per mirror; PBS primary on SSD unaffected |
| PBS GC slow on NFS | Certain | GC takes 15-60 min vs seconds | Schedule weekly off-peak; does not affect backup or restore ops |
| NFS permission issues | Medium | Mounts fail or read-only | maproot=root:wheel; test immediately after creation |
| Cross-subnet latency | Very Low | Slow NFS | Verified < 0.3ms; well within NFS tolerance |

---

## 15. Decision Log

| Decision | Chosen | Alternatives Considered | Rationale |
|----------|--------|------------------------|-----------|
| PBS sync architecture | Option A (NFS datastore + local sync) | Second PBS on TrueNAS, plain rsync | Simplest; single PBS instance; proper dedup awareness |
| NFS version | NFSv4 | NFSv3 | Simpler permissions; better security model |
| PBS verify on TrueNAS store | Disabled | Weekly verify | ZFS checksums handle integrity; verify is very slow on HDD/NFS |
| VLAN approach for pve-2 | VLAN tagging on existing NIC | USB Ethernet adapter | Zero hardware cost; standard practice; adequate bandwidth for DEV node |
| NAS VLAN phasing | Phase 2 (after PBS sync works) | Implement VLAN first | Don't block backup safety on network changes |
| Cold backup method | ZFS send/recv via TrueNAS replication | rsync, manual copy | Most efficient; preserves snapshots; built into TrueNAS UI |
| Pool-1 geometry | Keep existing 2× mirror | Rebuild as RAIDZ2 | RAID10 gives best random I/O for PBS GC; already built; 7TB is sufficient |
