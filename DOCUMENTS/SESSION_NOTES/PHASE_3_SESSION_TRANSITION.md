# PHASE_3_SESSION_TRANSITION.md
Colossus Proxmox Project

**Date:** Sunday, Feb 8, 2026
**Phase:** Phase 3 — PROD DB VM on pve-1
**Status:** Infrastructure deployed; validation pending

---

## 1. Purpose of This Document

This document captures all work performed during today's Phase 3 execution
session and defines the exact starting conditions for the next session where
validation, PBS configuration, and Phase 3 closeout will occur.

---

## 2. What Was Accomplished Today

### 2.1 Phase 3 Artifact Creation

A complete PROD automation package was created, adapted from the validated
DEV (Phase 2) artifacts:

| Artifact | Purpose |
|----------|---------|
| `colossus-prod-db1.bu` | Butane config — static IP, PROD mappings, SELinux fix |
| `01-create-prod-zfs.sh` | ZFS pool + datasets on pve-1 |
| `02-setup-prod-directory-mappings.sh` | Proxmox directory mappings (prod-db-*) |
| `03-create-vm-110.sh` | VM creation — q35, virtiofs, Ignition |
| `04-restore-postgres.sh` | PostgreSQL restore from SQL dump |
| `05-restore-neo4j.sh` | Neo4j restore (offline, --security-opt label=disable) |
| `06-restore-qdrant.sh` | Qdrant snapshot upload via HTTP API |
| `07-validate-prod.sh` | Full validation + optional DEV comparison |
| `README.md` | Step-by-step execution guide |

### 2.2 Infrastructure Deployed

All steps executed successfully in order:

| Step | Action | Result |
|------|--------|--------|
| Step 1 | ZFS pool `prod-zfs` on Crucial T500 2TB NVMe | ✅ Pool + 3 datasets created |
| Step 2 | Directory mappings (prod-db-postgres/neo4j/qdrant) | ✅ All 3 created and verified |
| Step 3 | CoreOS QCOW2 downloaded to pve-1 | ✅ Same image as DEV (42.20250929.3.0) |
| Step 4 | Butane → Ignition transpiled and copied | ✅ |
| Step 5 | UID ownership set on ZFS datasets | ✅ 999:999, 7474:7474, 1000:1000 |
| Step 6 | VM-110 created and started | ✅ |
| Step 7 | First boot verification | ✅ All 3 mounts with container_file_t, all 3 containers running |
| Reboot | CoreOS auto-updated to 43.20260119.3.1 and rebooted | ✅ Survived — mounts and containers came back |
| Step 8a | PostgreSQL restore | ✅ Database `colossus` with 25 tables confirmed |
| Step 8b | Neo4j restore | ✅ Node counts match DEV |
| Step 8c | Qdrant restore | ✅ Complete |
| Step 9 | Validation script | ❌ Blocked by network issue (see Section 3) |

### 2.3 Manual Verification Performed

From pve-1 console (bypassing the network issue):

```
Neo4j:  curl -s http://10.10.100.110:7474 → responded with version info (5.26.21)
Qdrant: curl -s http://10.10.100.110:6333/healthz → "healthz check passed"
```

Partial validation script output before freeze:
- SSH connectivity: ✅
- virtiofs mounts (all 3): ✅ with container_file_t
- Container status (all 3): ✅ Up
- PostgreSQL `colossus` database: ✅ exists

---

## 3. Issue Discovered: pve-1 Network Instability

### 3.1 Symptom

SSH connections to pve-1 (10.10.100.3) and VM-110 (10.10.100.110) are
intermittent. Connections work for a period, then timeout/hang, then
recover after a few minutes. Both pve-2 and VM-210 are unaffected.

The validation script (07-validate-prod.sh) reliably triggers the issue
because it opens many sequential SSH connections to VM-110.

### 3.2 Root Cause Investigation

| Check | Result |
|-------|--------|
| IP conflict (arping) | No duplicate detected |
| NIC link flaps (dmesg) | None — link stable at 1000Mb/s full duplex |
| RX errors | 0 errors, 58 drops (minor) |
| EEE (Energy Efficient Ethernet) | Already disabled |
| NIC power management | No control file found |
| sshd MaxStartups | 10:30:100 — same as working pve-2 |
| PTM (Precision Time Measurement) | Attempted disable |
| TCP offloading (tso/gso/gro) | Disabled as test |

### 3.3 Identified Hardware/Driver

- **NIC:** Intel igc (i225/i226 family) — known problematic driver
- **Interface:** nic0 (igc 0000:ac:00.0) bridged to vmbr0
- **PCIe:** Running at 5.0 GT/s x1 (bandwidth-limited)
- **Speed:** Negotiated 1000Mb/s full duplex
- **Kernel:** 6.17.4-2-pve (Proxmox)
- **Driver:** In-tree igc, srcversion B46E480FFAD2250D89D6F97

### 3.4 Key Insight

The problem is specific to pve-1's igc NIC, not VM-110's configuration.
Evidence: both pve-1 *and* VM-110 drop simultaneously, and pve-2 (different
NIC) has no issues.

The i225/i226 igc chips are known to have issues in Linux, with fixes
landing progressively across kernel versions. The PCIe x1 link width
(4 Gb/s) may also contribute under burst traffic.

### 3.5 Workaround

SSH connection multiplexing on the workstation eliminates the rapid
connection storm that triggers the issue. Add to `~/.ssh/config`:

```
Host 10.10.100.110
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 60s

Host 10.10.100.3
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 60s
```

### 3.6 Permanent Fix (Future Investigation)

Options to explore:
- Make offload changes persistent in `/etc/network/interfaces`
- Test with a Proxmox kernel update
- Consider using one of the other NICs (ice — Intel E800 10G/25G)
- BIOS settings for PCIe lane allocation

This is a separate workstream from Colossus Phase 3.

---

## 4. Current State (As-Built)

### 4.1 VM Inventory

| VMID | Name | Node | IP | Role | Status |
|------|------|------|----|------|--------|
| 200 | colossus-db1-dev | pve-2 | 10.10.100.50 | Frozen DEV reference | Running (do not modify) |
| 210 | colossus-dev-db1 | pve-2 | 10.10.100.200 | Active DEV DB host | Running |
| 110 | colossus-prod-db1 | pve-1 | 10.10.100.110 | PROD DB host | Running |
| 900 | PBS | pve-3 | — | Proxmox Backup Server | Running |

### 4.2 PROD ZFS (pve-1)

```
prod-zfs/           /prod-zfs           (Crucial T500 2TB NVMe)
├── postgres         recordsize=16K, compression=zstd
├── neo4j            recordsize=1M, compression=zstd
└── qdrant           recordsize=128K, compression=zstd
```

### 4.3 PROD Directory Mappings

| Mapping ID | Path on pve-1 |
|------------|---------------|
| prod-db-postgres | /prod-zfs/postgres |
| prod-db-neo4j | /prod-zfs/neo4j |
| prod-db-qdrant | /prod-zfs/qdrant |

### 4.4 PROD Services Confirmed Working

| Service | Port | Status |
|---------|------|--------|
| PostgreSQL 17 | 5432 | ✅ Database `colossus`, 25 tables |
| Neo4j 5 | 7474, 7687 | ✅ Node counts match DEV |
| Qdrant | 6333, 6334 | ✅ Health check passed |

### 4.5 CoreOS Version

VM-110 auto-updated from 42.20250929.3.0 to **43.20260119.3.1** on first
boot. Mounts and containers survived the update reboot — this is a
positive validation of the Ignition + Quadlet + virtiofs pattern.

---

## 5. Lessons Learned

### 5.1 scp Trailing Slash

`scp -r dir/ host:/path/` fails with "path canonicalization failed" if
the target doesn't exist. Use `scp -r dir host:/path/` instead.
Fixed in README.md.

### 5.2 CoreOS Image on Non-Podman Hosts

The CoreOS download method uses `coreos-installer` inside a Podman
container. Proxmox hosts don't have Podman. Use `scp` from another host
or `wget` the QCOW2 directly.

### 5.3 Neo4j Restore Latency

The neo4j-admin one-shot container may need to pull the image if it's
not already cached. This can make the restore script appear hung. The
running service's image is managed by Quadlet and may not be reusable
by a raw `podman run` command. Allow extra time or pre-pull the image.

### 5.4 igc NIC Issues

Intel i225/i226 NICs (igc driver) have known Linux issues. Rapid SSH
connection bursts can trigger stalls. SSH multiplexing is an effective
workaround. This should be documented as a known issue for pve-1.

### 5.5 CoreOS Auto-Updates

Zincati auto-updates are enabled by default and will reboot the VM.
This happened during today's session. It's actually beneficial — it
validated that the infrastructure survives an OS upgrade. For production,
consider configuring an update strategy (maintenance windows) to avoid
unexpected reboots.

---

## 6. Artifacts Delivered Today

### 6.1 Phase 3 Package

Location on pve-1: `/root/colossus-phase3/`

```
colossus-phase3/
├── README.md
├── butane/
│   └── colossus-prod-db1.bu
└── scripts/
    ├── 01-create-prod-zfs.sh
    ├── 02-setup-prod-directory-mappings.sh
    ├── 03-create-vm-110.sh
    ├── 04-restore-postgres.sh
    ├── 05-restore-neo4j.sh
    ├── 06-restore-qdrant.sh
    └── 07-validate-prod.sh
```

### 6.2 Ignition File

Location on pve-1: `/var/coreos/snippets/colossus-prod-db1.ign`

### 6.3 Butane Source

Location on workstation: `~/colossus-phase3/butane/colossus-prod-db1.bu`
(with passwords filled in — do not commit to version control)

---

## 7. Plan for Tomorrow

### 7.1 Pre-Validation Setup

1. Add SSH multiplexing to `~/.ssh/config` on workstation:

```
Host 10.10.100.110
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 60s

Host 10.10.100.3
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 60s
```

2. Verify ethtool changes on pve-1 survived reboot (if pve-1 was rebooted):

```bash
ethtool -k nic0 | grep -E "tcp-segmentation|generic-segmentation|generic-receive"
```

If they reverted, make permanent in `/etc/network/interfaces`.

### 7.2 Validation (Phase 3 Gate)

Run full validation with DEV comparison:

```bash
NEO4J_PASS='your-neo4j-password' \
  bash scripts/07-validate-prod.sh 10.10.100.110 10.10.100.200
```

All checks must pass:
- [ ] SSH connectivity
- [ ] virtiofs mounts with container_file_t (3/3)
- [ ] Containers running (3/3)
- [ ] PostgreSQL: colossus database, 25 tables
- [ ] Neo4j: HTTP endpoint, node count match
- [ ] Qdrant: healthz, collection count, point count match
- [ ] DEV vs PROD equivalence confirmed

### 7.3 Reboot Validation

```bash
ssh core@10.10.100.110 'sudo reboot'
# Wait 60s
ssh core@10.10.100.110 'mount | grep virtiofs && sudo podman ps'
```

### 7.4 PBS Backup Configuration

- Add VM-110 as a backup target in PBS (pve-3)
- Run first backup
- Verify backup metadata visible in PBS UI

### 7.5 Phase 3 Closeout

- Update Master Context document (COLOSSUS_HOMELAB_MASTER_CONTEXT.md):
  - Section 8: Add Phase 3 execution status
  - Section 13: Add VM-110 to inventory
  - Section 14: Add VM-110 IP
  - Section 12: Add PROD artifacts
- Author Phase 3 Completion Report
- Lock Phase 3

### 7.6 Separate Workstream: pve-1 NIC Investigation

Not blocking Phase 3, but should be addressed:
- Make ethtool offload changes permanent
- Research igc driver fixes in newer Proxmox kernels
- Consider BIOS PCIe lane allocation for nic0
- Evaluate using ice NIC (10G) instead of igc (2.5G)

---

## 8. Next Session Entry Point

When starting the next session, begin with:

> We are resuming the Colossus Proxmox project.
> Phase 2 is complete and locked.
> Phase 3 (PROD) infrastructure is deployed — VM-110 running on pve-1
> with all three databases restored.
> We are performing Phase 3 validation and closeout.
> Reference: PHASE_3_SESSION_TRANSITION.md

First task: Apply SSH multiplexing config, then run 07-validate-prod.sh.

---

## 9. Phase Lock Status

| Phase | Status |
|-------|--------|
| Phase 1 (Backups & PBS) | 🔒 Locked |
| Phase 2 Preparation | 🔒 Locked |
| Phase 2 Execution (DEV) | 🔒 Locked |
| Phase 3 Execution (PROD) | ⏳ Infrastructure deployed, validation pending |
