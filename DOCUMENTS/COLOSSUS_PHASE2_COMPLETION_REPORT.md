# Colossus Phase 2 — DEV Database Externalization: Completion Report

**Date:** 2026-02-08  
**Phase:** 2 (DEV Execution)  
**Status:** COMPLETE  
**Applies to:** pve-2 (DEV only)

---

## 1. Objective (Achieved)

Externalize all database persistence from the DEV database VM so that:

- The VM is fully disposable — destroyable and rebuildable from configuration
- All stateful data survives VM destruction (lives on host ZFS datasets)
- The same process can be repeated mechanically for production (Phase 3)

**Result:** All three databases (PostgreSQL 17, Neo4j 5, Qdrant) run on VM-210 with data stored entirely on host-managed ZFS datasets exposed via virtiofs. Parallel validation against VM-200 passed. VM-200 remains untouched.

---

## 2. What Was Built

### 2.1 Infrastructure

| Component | Detail |
|-----------|--------|
| **New VM** | VM-210 (`colossus-dev-db1`) on pve-2 |
| **Old VM** | VM-200 (`colossus-db1-dev`) — frozen reference, untouched |
| **OS** | Fedora CoreOS (stable, image `fedora-coreos-42.20250929.3.0-proxmoxve.x86_64.qcow2`) |
| **Machine type** | q35 (required for virtiofs) |
| **CPU/RAM** | 4 cores / 16 GiB |
| **Boot disk** | local-lvm, grown +40G |
| **Storage model** | virtiofs mounts from host ZFS datasets |

### 2.2 ZFS Datasets (pve-2 host)

| Dataset | Mountpoint | Recordsize | Compression |
|---------|-----------|------------|-------------|
| `dev-zfs/postgres` | `/dev-zfs/postgres` | 16K | zstd |
| `dev-zfs/neo4j` | `/dev-zfs/neo4j` | 1M | zstd |
| `dev-zfs/qdrant` | `/dev-zfs/qdrant` | 128K | zstd |

### 2.3 Proxmox Directory Mappings

| Mapping ID | Host Path | Node |
|-----------|-----------|------|
| `db-postgres` | `/dev-zfs/postgres` | pve-2 |
| `db-neo4j` | `/dev-zfs/neo4j` | pve-2 |
| `db-qdrant` | `/dev-zfs/qdrant` | pve-2 |

These are cluster-level resources created via `pvesh create /cluster/mapping/dir`.

### 2.4 virtiofs Attachment

```
qm set 210 -virtiofs0 "dirid=db-postgres,cache=always"
qm set 210 -virtiofs1 "dirid=db-neo4j,cache=always"
qm set 210 -virtiofs2 "dirid=db-qdrant,cache=always"
```

### 2.5 Container Stack

| Container | Image | Ports | Volume Mount |
|-----------|-------|-------|-------------|
| `colossus-postgres` | `docker.io/library/postgres:17` | 5432 | `/mnt/data/postgres:/var/lib/postgresql/data` |
| `colossus-neo4j` | `docker.io/library/neo4j:5` | 7474, 7687 | `/mnt/data/neo4j:/data` |
| `colossus-qdrant` | `docker.io/qdrant/qdrant:latest` | 6333, 6334 | `/mnt/data/qdrant:/qdrant/storage` |

Containers are managed via Podman Quadlet (`.container` files in `/etc/containers/systemd/`), not traditional systemd unit files with `ExecStart=podman run`.

### 2.6 Network

| VM | IP | Method |
|----|-----|--------|
| VM-200 (old) | 10.10.100.50 | existing |
| VM-210 (new) | 10.10.100.200 | DHCP |

---

## 3. Automation Artifacts

All Phase 2 automation lives in `~/colossus-phase2/` on the operator workstation.

### 3.1 Scripts (run on pve-2 host)

| Script | Purpose |
|--------|---------|
| `01-verify-dev-zfs.sh` | Validates ZFS pool, datasets, tuning |
| `02-setup-directory-mappings.sh` | Creates Proxmox cluster directory resource mappings |
| `03-create-vm-210.sh` | Creates the VM with q35, virtiofs, Ignition delivery |

### 3.2 Butane/Ignition

| File | Purpose |
|------|---------|
| `colossus-dev-db1.bu` | Authoritative Butane config (YAML) |
| `colossus-dev-db1.ign` | Transpiled Ignition (JSON) — delivered via cloud-init vendor snippet |

The Butane config declares: hostname, SSH key, systemd mount units, Quadlet container definitions, environment files, and directory structure.

### 3.3 Restore Scripts (run from workstation)

| Script | Purpose |
|--------|---------|
| `04-restore-postgres.sh` | Restores from `pg_dumpall` SQL dump |
| `05-restore-neo4j.sh` | Restores from `neo4j-admin database dump` artifact |
| `06-restore-qdrant.sh` | Restores from Qdrant snapshot via HTTP API |
| `07-validate-parity.sh` | Side-by-side comparison of VM-200 vs VM-210 |

---

## 4. Critical Technical Discoveries

### 4.1 SELinux + virtiofs (The Major Finding)

**Problem:** Containers could not access virtiofs-mounted directories despite correct Unix permissions and ownership.

**Root cause:** Fedora CoreOS runs SELinux in enforcing mode. virtiofs mounts from a non-SELinux host (Proxmox runs Debian, which has no SELinux policy) appear with context `system_u:object_r:virtiofs_t:s0`. Containers run as `container_t` and require `container_file_t` on their volumes. SELinux denied all access.

**Failed approaches:**
- `:z` / `:Z` volume flags on Podman — these attempt xattr-based relabeling, which virtiofs does not support (no xattr passthrough from non-SELinux host)
- `chcon` / `restorecon` — same xattr limitation

**Working solution:** Mount-level SELinux context assignment using the `context=` mount option in systemd mount units:

```ini
[Mount]
What=db-postgres
Where=/var/mnt/data/postgres
Type=virtiofs
Options=context="system_u:object_r:container_file_t:s0"
```

This tells the guest kernel to assign `container_file_t` to all files on the mount at the VFS level, without requiring xattr support from the host. This is the only correct approach for virtiofs from non-SELinux hosts.

### 4.2 CoreOS Path Canonicalization

**Problem:** systemd mount unit filenames must match the escaped canonical path. On CoreOS, `/mnt` is a symlink to `/var/mnt`.

**Impact:** Mount units must use `/var/mnt/data/...` paths and be named `var-mnt-data-*.mount`, not `mnt-data-*.mount`.

**Inside the VM**, both `/mnt/data/` and `/var/mnt/data/` resolve to the same location. SSH commands, container volume paths, and user-facing operations can use either. Only systemd unit definitions require the canonical form.

### 4.3 Quadlet Generator Timing

**Problem:** Traditional systemd unit enablement (`enabled: true` in Butane's systemd section) does not work for Quadlet-generated services because the `.service` files don't exist at Ignition time.

**Solution:** Quadlet `.container` files placed in `/etc/containers/systemd/` include their own `[Install] WantedBy=multi-user.target` section. The systemd generator creates and enables the service units during `daemon-reload`, which happens automatically on boot.

### 4.4 UID Ownership Must Be Set Guest-Side

Proxmox virtiofs has no UID mapping. The container images expect specific UIDs:

| Container | Expected UID | Set via |
|-----------|-------------|---------|
| PostgreSQL | 999 | `chown -R 999:999` from guest |
| Neo4j | 7474 | `chown -R 7474:7474` from guest |
| Qdrant | 1000 | `chown -R 1000:1000` from guest |

The restore scripts handle this automatically before starting the restore.

### 4.5 Neo4j Restore Requires `--security-opt label=disable`

The one-shot Neo4j restore container (`neo4j-admin database load`) needs to access virtiofs-mounted storage. Since `:Z` doesn't work on virtiofs, the restore script uses `--security-opt label=disable` on the one-shot container. The running Quadlet service does not need this because the mount-level `context=` option handles it.

---

## 5. Delta from Original Design Documents

### 5.1 Mount Paths

| Document | Referenced Path | Actual (VM-210) |
|----------|----------------|-----------------|
| Phase 2 Execution Checklist | `/mnt/db/postgres` | `/var/mnt/data/postgres` |
| Phase 2 Draft | `/mnt/db/postgres` | `/var/mnt/data/postgres` |
| VM200 Runbook v1.2 | `/mnt/data/postgres` | `/var/mnt/data/postgres` |
| Cluster Design v1.2 | `/mnt/data/` | `/var/mnt/data/` |

**Canonical path:** `/var/mnt/data/{service}` (in systemd units and Butane config)  
**User-facing path:** `/mnt/data/{service}` (in SSH, scripts, container volumes)

### 5.2 Dataset Names

| Document | Referenced Name | Actual |
|----------|----------------|--------|
| Cluster Design v1.2 | `dev-zfs/db-postgres` | `dev-zfs/postgres` |
| VM200 Runbook v1.2 | `dev-zfs/db-postgres` | `dev-zfs/postgres` |
| Master Context | `dev-zfs/postgres` | `dev-zfs/postgres` ✓ |

**Canonical:** `dev-zfs/postgres`, `dev-zfs/neo4j`, `dev-zfs/qdrant` (no `db-` prefix)

### 5.3 Container Management Model

| Document | Described | Actual |
|----------|-----------|--------|
| Cluster Design v1.2 | Traditional systemd units with `ExecStart=/usr/bin/podman run` | Podman Quadlet `.container` files |
| VM200 Runbook v1.2 | Ad-hoc `podman run` commands | Podman Quadlet `.container` files |

Quadlet is the modern, correct approach for CoreOS. The `.container` files are declarative and the systemd generator handles service creation.

### 5.4 Migration Approach

| Document | Approach | Actual |
|----------|----------|--------|
| VM200 Runbook v1.2 | In-place migration of VM-200 | New VM-210, parallel rebuild from backups |
| Phase 2 Checklist | New VM, parallel validation | New VM-210, parallel validation ✓ |

The VM200 Runbook v1.2 is **retired**. The parallel rebuild approach was executed.

---

## 6. Retired Documents

The following documents served their purpose during planning but are now superseded by this completion report and the actual automation artifacts:

| Document | Status | Reason |
|----------|--------|--------|
| `VM200_EXTERNALIZATION_RUNBOOK_v1.2.md` | **RETIRED** | Described in-place migration; we did parallel rebuild |
| `phase_2_dev_db_externalization_draft.md` | **SUPERSEDED** | Draft; actual implementation differs in paths and container model |
| `PHASE2_REFAC_BUTANE_VIRTIOFS_v2.zip` | **RETIRED** | ChatGPT-generated; had critical errors |

---

## 7. Validation Results

Parallel validation script (`07-validate-parity.sh`) comparing VM-200 vs VM-210:

- **PostgreSQL:** Database lists match, table counts match per database
- **Neo4j:** Node counts by label match
- **Qdrant:** Collection lists match, point counts match per collection

**All parity checks passed.**

---

## 8. Phase 2 Exit Criteria (All Met)

| Criterion | Status |
|-----------|--------|
| VM-210 runs all three databases | ✅ |
| All DB data lives outside the VM (dev-zfs datasets) | ✅ |
| Data parity confirmed against VM-200 | ✅ |
| VM-200 remains unchanged | ✅ |
| Automation artifacts exist and are tested | ✅ |
| SELinux interaction documented | ✅ |

---

## 9. What's Next

### 9.1 Immediate (Backup Infrastructure)

- Create backup/restore runbook for DEV databases (PostgreSQL, Neo4j, Qdrant)
- Establish regular backup cadence for VM-210 data

### 9.2 Phase 3 (Production on pve-1)

Apply the identical pattern:

1. Create `prod-zfs` pool + datasets on pve-1
2. Create directory mappings on pve-1
3. Adjust Butane config (hostname, VMID, env vars)
4. Create PROD VM from the same script structure
5. Restore from DEV-validated backups
6. Validate

**No new design decisions.** Production is a repeat, not a redesign.

---

## 10. Authoritative Artifacts

After Phase 2, these are the source of truth:

| Artifact | Location | Purpose |
|----------|----------|---------|
| `colossus-dev-db1.bu` | Workstation: `~/colossus-phase2/butane/` | VM configuration (Butane → Ignition) |
| `colossus-dev-db1.ign` | pve-2: `/var/coreos/snippets/` | Compiled Ignition config |
| Phase 2 scripts (01–07) | Workstation: `~/colossus-phase2/scripts/` | Automation |
| This document | Project folder | Implementation record |
| Backup/Restore Runbook | Project folder | Operational procedures |

The Butane config is the single source of truth for VM-210's configuration. If the VM needs to be rebuilt, transpile the Butane config, copy the Ignition file, run the creation script, restore data.

---

*End of Phase 2 Completion Report*
