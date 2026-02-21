# Colossus Phase 3 Completion Report — PROD DB VM on pve-1

**Date:** 2026-02-09  
**Phase:** Phase 3 — Production Database Deployment  
**Status:** ✅ COMPLETE  
**VM:** VM-110 (`colossus-prod-db1`) on pve-1  

---

## 1. Objective

Deploy a production database VM on pve-1 using the same scripts, Butane configuration, and procedures validated during Phase 2 (DEV on pve-2). Restore all three databases from verified backups and confirm DEV/PROD parity.

---

## 2. What Was Built

### 2.1 Host Storage (pve-1)

ZFS pool `prod-zfs` created on Crucial T500 2TB NVMe:

```
prod-zfs/           /prod-zfs
├── postgres         recordsize=16K, compression=zstd, atime=off
├── neo4j            recordsize=1M, compression=zstd, atime=off
└── qdrant           recordsize=128K, compression=zstd, atime=off
```

### 2.2 Proxmox Directory Mappings

| Mapping ID | Path on pve-1 |
|------------|---------------|
| prod-db-postgres | /prod-zfs/postgres |
| prod-db-neo4j | /prod-zfs/neo4j |
| prod-db-qdrant | /prod-zfs/qdrant |

### 2.3 VM-110 Configuration

| Parameter | Value |
|-----------|-------|
| VMID | 110 |
| Name | `colossus-prod-db1` |
| Node | pve-1 |
| Machine type | q35 (required for virtiofs) |
| CPU | 4 cores |
| Memory | 16384 MiB |
| Disk | local-lvm + 40G |
| Network | virtio, bridge=vmbr0, static IP 10.10.100.110 |
| OS | Fedora CoreOS (initially 42.20250929.3.0, auto-updated to 43.20260119.3.1) |
| Ignition | Delivered via cloud-init vendor snippet |

### 2.4 Services Deployed

| Service | Image | Ports | Container Name |
|---------|-------|-------|----------------|
| PostgreSQL 17 | `docker.io/library/postgres:17` | 5432 | colossus-postgres |
| Neo4j 5 | `docker.io/library/neo4j:5` | 7474, 7687 | colossus-neo4j |
| Qdrant | `docker.io/qdrant/qdrant:latest` | 6333, 6334 | colossus-qdrant |

All containers managed via Podman Quadlet with systemd lifecycle control.

---

## 3. Execution Timeline

### 3.1 Session 1 — 2026-02-08 (Infrastructure + Restore)

| Step | Action | Result |
|------|--------|--------|
| 1 | Created PROD automation package from DEV artifacts | ✅ |
| 2 | Created ZFS pool `prod-zfs` on T500 NVMe | ✅ |
| 3 | Created directory mappings (prod-db-*) | ✅ |
| 4 | Downloaded CoreOS QCOW2 to pve-1 | ✅ |
| 5 | Transpiled Butane → Ignition, deployed to pve-1 | ✅ |
| 6 | Set UID ownership on ZFS datasets | ✅ |
| 7 | Created and started VM-110 | ✅ |
| 8 | First boot verification — mounts + containers | ✅ |
| 9 | CoreOS auto-update survived (42 → 43) | ✅ |
| 10 | PostgreSQL restore | ✅ |
| 11 | Neo4j restore | ✅ |
| 12 | Qdrant restore | ✅ |
| 13 | Automated validation script | ❌ Blocked by NIC issue |
| 14 | Manual verification from pve-1 console | ✅ |

### 3.2 Session 2 — 2026-02-09 (Validation + Closeout)

| Step | Action | Result |
|------|--------|--------|
| 1 | SSH multiplexing configured on workstation | ✅ |
| 2 | Full validation script (07-validate-prod.sh) | ✅ All checks passed |
| 3 | DEV vs PROD parity confirmed | ✅ |
| 4 | Reboot test — mounts + containers survived | ✅ |
| 5 | First PBS backup of VM-110 | ✅ (32 seconds, 50 GiB) |
| 6 | Scheduled daily PBS backup job created | ✅ |
| 7 | Phase 3 Completion Report (this document) | ✅ |
| 8 | Master Context updated | ✅ |

---

## 4. Validation Results

### 4.1 Full Validation (07-validate-prod.sh)

```
SSH Connectivity:        ✅ hostname: colossus-prod-db1
virtiofs Mounts:         ✅ 3/3 with container_file_t
Container Status:        ✅ 3/3 running
PostgreSQL:              ✅ Database 'colossus', 25 tables
Neo4j:                   ✅ HTTP endpoint, 207 nodes
Qdrant:                  ✅ Health OK, 1 collection, 287 points
```

### 4.2 DEV vs PROD Parity

| Metric | DEV (VM-210) | PROD (VM-110) | Match |
|--------|-------------|---------------|-------|
| PostgreSQL tables | 25 | 25 | ✅ |
| Neo4j nodes | 207 | 207 | ✅ |
| Qdrant points | 287 | 287 | ✅ |

### 4.3 Reboot Test

VM-110 rebooted and all three virtiofs mounts returned with correct SELinux context. All three containers auto-started. No manual intervention required.

### 4.4 PBS Backup

First backup completed successfully in 32 seconds. Scheduled daily backup job `backup-prod-db` created and active.

---

## 5. Deviations from Plan

### 5.1 Static IP (Enhancement)

PROD VM-110 uses a static IP (10.10.100.110) configured via Butane/Ignition, unlike DEV VM-210 which uses DHCP. This is appropriate for a production service.

### 5.2 PROD-Specific Directory Mapping IDs

DEV used `db-postgres`, `db-neo4j`, `db-qdrant`. PROD used `prod-db-postgres`, `prod-db-neo4j`, `prod-db-qdrant` to avoid conflicts in the cluster-wide mapping namespace.

### 5.3 CoreOS Auto-Update During Deployment

VM-110 auto-updated from CoreOS 42.20250929.3.0 to 43.20260119.3.1 during the first session. This was unplanned but served as a positive validation — the Ignition + Quadlet + virtiofs pattern survived an OS-level upgrade without intervention.

---

## 6. Issues Discovered

### 6.1 pve-1 igc NIC Instability

The Intel i225/i226 NIC on pve-1 (igc driver) exhibits intermittent SSH stalls under burst traffic patterns. The validation script's rapid sequential SSH connections reliably triggers this.

**Root cause:** Known Linux driver issue with igc chipset, possibly compounded by PCIe x1 bandwidth limitation (4 Gb/s).

**Workaround applied:** SSH connection multiplexing on the workstation (`~/.ssh/config` with ControlMaster/ControlPath/ControlPersist). TCP offload disabling (`ethtool -K nic0 tso off gso off gro off`) may also help but is not yet persistent across reboots.

**Impact on Phase 3:** None — workaround is effective. This is a separate workstream for future attention.

**Future options:**
- Make ethtool offload changes persistent in `/etc/network/interfaces`
- Test with newer Proxmox kernel
- Evaluate using the ice NIC (Intel E800 10G/25G) instead of igc
- BIOS PCIe lane allocation investigation

### 6.2 scp Trailing Slash Behavior

`scp -r dir/ host:/path/` fails with "path canonicalization failed" if the target doesn't exist. Use `scp -r dir host:/path/` instead. Documented in README.md.

### 6.3 Neo4j Image Pull Latency

The neo4j-admin one-shot restore container may need to pull the image fresh, causing apparent hangs. The Quadlet-managed service image may not be reusable by raw `podman run`. Pre-pull or allow extra time.

---

## 7. Artifacts

### 7.1 PROD Automation Package

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

### 7.2 Ignition File

Location on pve-1: `/var/coreos/snippets/colossus-prod-db1.ign`

### 7.3 Butane Source

Location on workstation: `~/colossus-phase3/butane/colossus-prod-db1.bu`

---

## 8. Phase 3 Completion Gate

All exit criteria met:

- [x] PROD VM-110 running on pve-1 with all three databases
- [x] DEV/PROD data equivalence confirmed (PostgreSQL, Neo4j, Qdrant)
- [x] Reboot test passed — mounts and containers survive restart
- [x] PBS backup completed and scheduled
- [x] Validation script passes cleanly
- [x] Documentation updated (this report + Master Context)
- [x] No unresolved blockers

**Phase 3 Status: 🔒 LOCKED**

---

## 9. What Comes Next

With DEV and PROD database infrastructure complete, potential next phases include:

- **pve-1 NIC investigation** — make ethtool offload changes persistent, evaluate ice NIC
- **CoreOS auto-update strategy** — configure Zincati maintenance windows for PROD
- **Edge services** — DNS, Cloudflare Tunnel, Pi-hole (per existing technical design)
- **Management services** — Authentik, reverse proxy, monitoring/logging
- **Application deployment** — services that consume the database infrastructure

These are independent workstreams that can be prioritized based on operational need.

---

*End of Phase 3 Completion Report*
