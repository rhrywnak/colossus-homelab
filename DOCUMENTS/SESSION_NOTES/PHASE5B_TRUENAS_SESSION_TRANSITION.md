# TrueNAS Integration: Session Transition Document

**Date:** Thursday, Feb 13, 2026  
**Scope:** TrueNAS integration — PBS backup replication, ISO library, backup scheduling  
**Status:** ✅ Complete  
**Sessions consumed:** 1

---

## 1. Purpose of This Document

This document records the TrueNAS integration session for continuity. It captures what was done, what was discovered, and what remains for future phases.

---

## 2. Current Project State

### 2.1 Completed Phases

| Phase | Status | Date |
|-------|--------|------|
| Phase 1 — Backups & PBS | 🔒 Locked | 2026-02-05 |
| Phase 2 — DEV DB Externalization | 🔒 Locked | 2026-02-08 |
| Phase 3 — PROD DB Deployment | 🔒 Locked | 2026-02-09 |
| Phase 4A — Application Deployment | 🔒 Locked | 2026-02-11 |
| Phase 4B — Edge Services | 🔒 Locked | 2026-02-11 |
| Phase 5A — Traefik Reverse Proxy | 🔒 Locked | 2026-02-12 |
| TrueNAS Integration | ✅ Complete | 2026-02-13 |

### 2.2 Next Up

| Task | Design Document | Status |
|------|----------------|--------|
| Phase 5B-1: Ansible Foundation | `COLOSSUS_PHASE5B_ANSIBLE_DESIGN_v1.md` | Ready for execution |
| Phase 5B-2+: Infrastructure codification | `COLOSSUS_PHASE5B_ANSIBLE_DESIGN_v1.md` | Depends on 5B-1 |

---

## 3. What Was Done This Session

### 3.1 Execution Summary (11 Steps)

| Step | Task | Result |
|------|------|--------|
| 1 | Clean stale TrueNAS config | Old datasets, shares, snapshot tasks removed |
| 2 | Create 6 datasets | backups/pbs-sync, iso, templates, cold, scratch — proper ZFS properties |
| 3 | Create 3 NFS shares | pbs-sync, iso, templates — NFSv4, authorized to Proxmox subnets |
| 4 | Create 3 snapshot tasks | pbs-sync (6hr), iso (daily), templates (daily) |
| 5 | Add NFS storage to Proxmox | truenas-iso (500 GiB) and truenas-templates (200 GiB) — active all nodes |
| 6 | Verify ISO library | Write access confirmed from pve-3 |
| 7 | Mount NFS in PBS VM-900 | fstab entry with hard,nfsvers=4 — 7.2 TiB available |
| 8 | Add truenas-sync datastore | Second PBS datastore on NFS — config file method (see below) |
| 9 | Create PBS sync job | pbs-to-truenas, daily 02:00, remove-vanished=true |
| 10 | Run first sync | 17.7 GiB, 7 groups, 21 MiB/s average — TASK OK |
| 11 | Schedule all VM/CT backups | 8 jobs in /etc/pve/jobs.cfg (was only VM-110) |

### 3.2 Additional Fixes

- `pbs-zfs` storage definition restricted to pve-3 only (`pvesm set pbs-zfs --nodes pve-3`) to eliminate ZFS errors on pve-1/pve-2

---

## 4. Key Discoveries and Lessons Learned

### 4.1 PBS Chunk Store Over NFS Is Extremely Slow

PBS `datastore create` builds 65,536 directories (256×256 hash tree). Over NFS to spinning HDDs, this crawled at ~1% per several minutes. Each directory creation is a separate NFS metadata operation.

**Workaround:** Create the directory structure locally on TrueNAS via web shell (System → Shell), then fix ownership:

```bash
# On TrueNAS web shell
sudo bash -c 'cd /mnt/Pool-1/backups/pbs-sync && mkdir -p .chunks && for i in $(printf "%04x\n" $(seq 0 65535)); do mkdir -p ".chunks/$i"; done'
sudo chown -R 34:34 /mnt/Pool-1/backups/pbs-sync/.chunks
```

Completed in under a minute locally vs. estimated 1-2 hours over NFS.

### 4.2 PBS Datastore Create Refuses Pre-Existing .chunks

`proxmox-backup-manager datastore create` errors with `EEXIST: File exists` if `.chunks` directory already exists. There is no `--force` flag.

**Workaround:** Add the datastore directly to the config file:

```bash
cat >> /etc/proxmox-backup/datastore.cfg << 'EOF'

datastore: truenas-sync
    path /mnt/truenas-pbs
    gc-schedule Sun 03:00
    prune-schedule Mon 04:00
EOF

systemctl restart proxmox-backup.service
```

### 4.3 PBS Backup User UID

PBS daemon writes as `backup:backup` (UID 34, GID 34). All chunk store directories must be owned by this user. The TrueNAS `backup` user doesn't exist, so use numeric UID.

### 4.4 TrueNAS SSH Disabled by Default

Cannot SSH into TrueNAS CE 25.04 out of the box. Use the web shell at System → Shell for admin tasks, or enable SSH via System → Services.

### 4.5 TrueNAS CE 25.04 Dataset Quotas

Quotas are not in the dataset creation wizard. Set them post-creation via the dataset detail panel → Dataset Space Management → Edit.

### 4.6 TrueNAS Web Shell Uses zsh

The TrueNAS web shell runs zsh, not bash. Complex for-loops with `sudo` fail. Use `sudo bash -c '...'` wrapper.

### 4.7 PBS VM Has No Guest Agent

VM-900 does not have QEMU guest agent installed. `qm guest cmd 900 network-get-interfaces` fails. PBS VM IP is 10.10.100.242 (known/documented).

### 4.8 PBS Datastore Name Correction

The existing PBS datastore is called `pbs-zfs` (not `pbs-1` as some design documents assumed). The Proxmox storage ID `pbs-1` maps to this datastore. All documentation updated to use `pbs-zfs`.

---

## 5. Infrastructure State After This Session

### 5.1 Full VM/CT Inventory

| ID | Name | Type | Node | IP | Role | Backup |
|----|------|------|------|----|------|--------|
| 110 | colossus-prod-db1 | VM | pve-1 | 10.10.100.110 | PROD DB | Daily |
| 120 | colossus-prod-app1 | VM | pve-1 | 10.10.100.120 | PROD App | Daily |
| 200 | colossus-db1-dev | VM | pve-2 | 10.10.100.50 | Frozen ref | Daily |
| 210 | colossus-dev-db1 | VM | pve-2 | 10.10.100.200 | DEV DB | Daily |
| 220 | colossus-dev-app1 | VM | pve-2 | 10.10.100.220 | DEV App | Daily |
| 311 | pihole | CT | pve-3 | 10.10.100.53 | DNS | Daily |
| 312 | cloudflared | CT | pve-3 | 10.10.100.54 | Tunnel | Daily |
| 313 | traefik | CT | pve-3 | 10.10.100.55 | Reverse Proxy | Daily |
| 900 | PBS | VM | pve-3 | 10.10.100.242 | Backups | Not backed up (self) |
| — | TrueNAS | Appliance | Standalone | 10.10.0.38 | NAS/Backup | N/A |

### 5.2 Nightly Automation Flow

```
~00:00  Proxmox vzdump (8 VMs/CTs → pbs-zfs on SSD)
 02:00  PBS sync (pbs-zfs → truenas-sync via NFS)
 Every 6h  TrueNAS ZFS snapshots of pbs-sync
 Sun 03:00  PBS garbage collection on truenas-sync
 Mon 04:00  PBS prune on truenas-sync
```

### 5.3 Cluster Storage

```bash
pvesm status | grep truenas
# truenas-iso        nfs  active  524288000  1024  524286976  0.00%
# truenas-templates  nfs  active  209715200  1024  209714176  0.00%
```

---

## 6. Documents Updated This Session

| Document | Action |
|----------|--------|
| `COLOSSUS_HOMELAB_MASTER_CONTEXT_v4.md` | Created from v3 — TrueNAS integration, backup config, inventory updates |
| `COLOSSUS_TRUENAS_PBS_RUNBOOK_v1.md` | Created — operational procedures for TrueNAS/PBS integration |
| `PHASE5B_TRUENAS_SESSION_TRANSITION.md` | Created — this document |

### 6.1 Master Context v3 → v4 Changes

- Header: updated date and last-change description
- Section 5.4: Added TrueNAS Storage subsection
- Section 8.8: Added TrueNAS Integration phase record
- Section 13.5: Added TrueNAS Integration work checklist
- Section 15 (Future Work): Moved backups, TrueNAS, Cloudflare Access to Completed; added NAS VLAN and cold backup to Deferred
- Section 16.4: Added new documents to documentation list; retired v3
- Section 17: Added TrueNAS to inventory; added PBS IP (10.10.100.242)
- Section 18.1: Added PBS and TrueNAS to IP assignments table
- Section 19: Replaced backup configuration with comprehensive 3-section update (jobs, replication, data flow)

---

## 7. Outstanding Items (Not Blocking)

| Item | Priority | Notes |
|------|----------|-------|
| `pbs-zfs` node restriction | Low | Run `pvesm set pbs-zfs --nodes pve-3` if not done |
| PBS VM guest agent | Low | Install qemu-guest-agent for better management |
| Truenas-sync retention policy | Low | Set via PBS UI when ready (daily 7, weekly 4, monthly 6) |
| NAS VLAN (10.10.40.0/24) | Deferred | Network infrastructure change, independent of backup functionality |
| Cold/offline USB backup | Deferred | Buy USB drive, configure ZFS replication task |

---

## 8. Next Session: Phase 5B-1 — Ansible Foundation

**Design document:** `COLOSSUS_PHASE5B_ANSIBLE_DESIGN_v1.md`

**Scope:**
1. Install Ansible on workstation (proxima-centauri)
2. Create inventory file (all Proxmox nodes, VMs, CTs, TrueNAS)
3. Configure Ansible Vault for secrets
4. Ping all hosts to verify connectivity
5. First playbook: gather facts from all managed hosts

**Prerequisites:** None — this session's work is complete and independent.
