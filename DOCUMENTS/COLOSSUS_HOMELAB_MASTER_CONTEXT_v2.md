# Colossus Homelab — Master Context, Architecture, and Execution Plan

**Project Name:** Colossus  
**Scope:** On-prem Proxmox homelab for containerized databases, LLM infrastructure, and agentic systems  
**Audience:** Primary operator (authoritative), future collaborators, future self  
**Document Type:** Canonical context + execution reference  
**Status:** Living document with phase locks  
**Last Updated:** 2026-02-09 (Phase 3 PROD complete)

---

## 1. Purpose of This Document

This document exists to:

1. Define **why** the Colossus homelab exists
2. Describe **what was designed**
3. Record **what has been implemented**
4. Explicitly enumerate **what remains to be done**
5. Ensure **DEV and PROD parity** through repeatable processes

This document is **authoritative**.  
If reality diverges from this document, execution **must pause** and the document must be updated first.

---

## 2. Objectives

### 2.1 Primary Objectives

The Colossus homelab is designed to:

- Provide a **reproducible, deterministic infrastructure** for:
  - Databases (PostgreSQL, Neo4j, Qdrant)
  - Vector search and knowledge graphs
  - LLM inference, experimentation, and agentic systems
- Support **parallel environments** (DEV → PROD) without in-place mutation
- Enable **safe rebuilds** instead of fragile upgrades
- Make infrastructure **boring, inspectable, and scriptable**
- Allow long pauses in work without loss of understanding

---

### 2.2 Explicit Non-Goals

The homelab is **not** intended to be:

- Kubernetes-based
- Click-ops driven
- Tuned for maximum density or micro-optimizations
- A high-availability enterprise cluster
- Continuously modified in place

Correctness, recoverability, and clarity are prioritized over performance.

---

## 3. Design Principles (Hard Rules)

These principles are non-negotiable:

1. **Rebuild > mutate**
2. **Data lives outside the VM**
3. **VMs are disposable; datasets are not**
4. **systemd controls lifecycle, not humans**
5. **Everything important must be scriptable**
6. **Parallel validation before cutover**
7. **No silent assumptions**
8. **Production must be reproducible from DEV artifacts**

---

## 4. High-Level Architecture

### 4.1 Physical Layer

| Node  | Role |
|-------|------|
| pve-1 | Production workloads |
| pve-2 | Development workloads |
| pve-3 | Proxmox Backup Server + infrastructure services |

Roles are **exclusive**. No node serves mixed responsibilities.

---

### 4.2 Virtualization Layer

- Proxmox VE 9.1.5 cluster (`colossus`)
- VM lifecycle controlled via `qm` CLI
- No UI-only configuration considered authoritative
- All important VM configuration must be expressible in scripts
- **Machine type `q35` is required** for VMs using virtiofs

---

### 4.3 Operating System Standard

**Fedora CoreOS** is the only supported OS for service VMs.

Reasons:
- Immutable base
- Ignition-driven provisioning
- Deterministic startup
- Container-native lifecycle

All configuration is expressed via:
- Butane → Ignition
- Podman Quadlet (`.container` files)
- systemd mount units

---

## 5. Storage Architecture (Canonical)

### 5.1 Host-Level Storage

- ZFS pools created on Proxmox hosts
- One pool per environment
- Separate datasets per service

Dataset layout (as-built):

```
dev-zfs/          (pve-2, Crucial MX500 2TB SATA SSD)
├── postgres      recordsize=16K, compression=zstd
├── neo4j         recordsize=1M, compression=zstd
└── qdrant        recordsize=128K, compression=zstd

prod-zfs/         (pve-1, Crucial T500 2TB NVMe)
├── postgres      recordsize=16K, compression=zstd
├── neo4j         recordsize=1M, compression=zstd
└── qdrant        recordsize=128K, compression=zstd
```

---

### 5.2 VM-Level Access

- **virtiofs** is used to mount host ZFS datasets into CoreOS VMs
- VM root filesystem never contains authoritative data
- All persistent state resides on the Proxmox host
- virtiofs requires Proxmox **directory resource mappings** (`pvesh create /cluster/mapping/dir`)
- virtiofs requires **q35 machine type** on the VM

This enables:
- Fast rebuilds
- Safe restores
- Clear failure boundaries

### 5.3 SELinux and virtiofs (Critical)

Fedora CoreOS runs SELinux in **enforcing mode**. virtiofs mounts from a non-SELinux host (Proxmox/Debian) appear with context `virtiofs_t`, which containers (`container_t`) cannot access.

**Required fix:** All virtiofs systemd mount units must include:

```ini
Options=context="system_u:object_r:container_file_t:s0"
```

This assigns `container_file_t` at the VFS level without requiring xattr support from the host.

**What does NOT work on virtiofs:**
- `:z` or `:Z` volume flags (no xattr passthrough)
- `chcon` / `restorecon` (same limitation)

**For one-shot admin containers** (e.g., neo4j-admin restore), use `--security-opt label=disable`.

---

## 6. Container Model

### 6.1 Runtime

- Podman (rootful)
- Containers managed via **Podman Quadlet** (`.container` files in `/etc/containers/systemd/`)
- systemd generator creates `.service` units automatically on boot

### 6.2 Lifecycle Rules

- Containers are disposable
- Container images are replaceable
- Data is external and persistent
- Containers may be destroyed and recreated at any time

### 6.3 Configuration Model

- Quadlet `.container` files declare image, ports, volumes, dependencies
- Environment files in `/etc/colossus/env/` (credentials)
- systemd mount units wire virtiofs mounts with SELinux context
- All configuration delivered via Butane → Ignition on first boot
- No ad-hoc `podman run` usage

### 6.4 Path Convention

On CoreOS, `/mnt` is a symlink to `/var/mnt`. This matters for systemd:

| Context | Path to use |
|---------|------------|
| systemd mount unit `Where=` and filenames | `/var/mnt/data/{service}` |
| Container volume mounts, SSH commands, scripts | `/mnt/data/{service}` |

Both resolve to the same location. Only systemd units require the canonical form.

---

## 7. Databases in Scope

| Service | Image | Ports | DEV Persistence | PROD Persistence |
|---------|-------|-------|-----------------|------------------|
| PostgreSQL 17 | `docker.io/library/postgres:17` | 5432 | `dev-zfs/postgres` | `prod-zfs/postgres` |
| Neo4j 5 | `docker.io/library/neo4j:5` | 7474, 7687 | `dev-zfs/neo4j` | `prod-zfs/neo4j` |
| Qdrant | `docker.io/qdrant/qdrant:latest` | 6333, 6334 | `dev-zfs/qdrant` | `prod-zfs/qdrant` |

Container UIDs (must be set guest-side, no host-side UID mapping on virtiofs):

| Container | UID:GID |
|-----------|---------|
| PostgreSQL | 999:999 |
| Neo4j | 7474:7474 |
| Qdrant | 1000:1000 |

All follow the same lifecycle:
1. External storage mounted (virtiofs with SELinux context)
2. Empty container started
3. Data restored from verified backups
4. Validated against reference
5. Put into service

---

## 8. Current State

### 8.1 Phase 1 — Backups & PBS

- Proxmox Backup Server configured (VM-900 on pve-3)
- Database backups created and verified
- Off-host copies confirmed

**Status:** 🔒 Locked

---

### 8.2 Phase 2 — Preparation

- Migration strategy defined
- Guardrails written
- Execution checklist authored
- Butane + virtiofs model validated

**Status:** 🔒 Locked

---

### 8.3 Phase 2 — Execution (DEV)

Completed:
- ZFS pool `dev-zfs` created on pve-2 (Crucial MX500 2TB)
- Datasets created and tuned: postgres, neo4j, qdrant
- Proxmox directory resource mappings created (db-postgres, db-neo4j, db-qdrant)
- VM-210 (`colossus-dev-db1`) created via scripted `qm` commands
- Butane config authored with SELinux context fix, Quadlet containers, virtiofs mounts
- Ignition deployed via cloud-init vendor snippet
- All three containers auto-start on boot
- Data restored from Phase 1 backups
- Parallel validation passed against VM-200
- VM-200 remains untouched as frozen reference
- SELinux + virtiofs interaction discovered and documented
- Backup/restore runbook created
- Phase 2 Completion Report authored

**Status:** 🔒 Locked

---

### 8.4 Phase 3 — Execution (PROD)

Completed:
- ZFS pool `prod-zfs` created on pve-1 (Crucial T500 2TB NVMe)
- Datasets created and tuned: postgres, neo4j, qdrant (identical to DEV)
- Proxmox directory resource mappings created (prod-db-postgres, prod-db-neo4j, prod-db-qdrant)
- VM-110 (`colossus-prod-db1`) created via scripted `qm` commands adapted from DEV
- Static IP 10.10.100.110 configured via Butane/Ignition
- All three containers auto-start on boot
- Data restored from DEV-validated backups
- DEV/PROD parity confirmed: PostgreSQL (25 tables), Neo4j (207 nodes), Qdrant (287 points)
- Reboot test passed — mounts and containers survived restart
- CoreOS auto-update survived (42.20250929.3.0 → 43.20260119.3.1)
- First PBS backup completed (32 seconds, 50 GiB)
- Scheduled daily PBS backup job created (`backup-prod-db`)
- Phase 3 Completion Report authored

**Status:** 🔒 Locked

---

## 9. Repeatability & Parity Requirement

From this point forward:

- No VM creation is considered valid unless it is scriptable
- Manual steps are allowed only to discover correct parameters
- All validated steps must be codified

**DEV artifacts are the source of truth for PROD.**

This principle was validated in Phase 3: PROD was deployed mechanically from adapted DEV artifacts with zero new design decisions.

---

## 10. Phase 2 Work — DEV Execution (COMPLETE)

All items completed 2026-02-08:

1. ~~Formalize VM creation script (`qm`-based)~~ ✅
2. ~~Create new DEV CoreOS VM from script~~ ✅ (VM-210)
3. ~~Attach virtiofs datasets~~ ✅ (via directory mappings)
4. ~~Apply Ignition configuration~~ ✅ (via cloud-init vendor snippet)
5. ~~Bring up empty containers~~ ✅ (Quadlet auto-start)
6. ~~Restore PostgreSQL data~~ ✅
7. ~~Restore Neo4j data~~ ✅
8. ~~Restore Qdrant snapshot~~ ✅
9. ~~Run parallel validation vs VM-200~~ ✅ (all checks passed)
10. ~~Phase 2 exit gate~~ ✅

---

## 11. Phase 3 Work — PROD Execution (COMPLETE)

All items completed 2026-02-08/09:

1. ~~Create PROD automation package from DEV artifacts~~ ✅
2. ~~Create ZFS pool `prod-zfs` on pve-1~~ ✅
3. ~~Create directory mappings (prod-db-*)~~ ✅
4. ~~Create and start VM-110~~ ✅
5. ~~Restore PostgreSQL data~~ ✅
6. ~~Restore Neo4j data~~ ✅
7. ~~Restore Qdrant snapshot~~ ✅
8. ~~DEV vs PROD validation~~ ✅ (all metrics match)
9. ~~Reboot test~~ ✅
10. ~~PBS backup + scheduled job~~ ✅
11. ~~Phase 3 exit gate~~ ✅

---

## 12. Known Issues

### 12.1 pve-1 igc NIC Instability

The Intel i225/i226 NIC on pve-1 (igc driver) exhibits intermittent SSH stalls under burst traffic. This does not affect normal operation or database services — only rapid sequential SSH connections.

**Workaround:** SSH connection multiplexing on the workstation (`~/.ssh/config` with ControlMaster/ControlPath/ControlPersist).

**Future investigation:**
- Make ethtool offload changes persistent (`post-up` in `/etc/network/interfaces`)
- Test with newer Proxmox kernel
- Evaluate using ice NIC (Intel E800 10G/25G) instead of igc
- BIOS PCIe lane allocation

### 12.2 CoreOS Auto-Updates

Zincati auto-updates are enabled by default and will reboot VMs without warning. This was validated to be non-destructive (Phase 3 survived it), but for production stability, consider configuring maintenance windows.

---

## 13. Future Work

These are independent workstreams that can be prioritized based on operational need:

- **pve-1 NIC investigation** — permanent offload fix, alternative NIC evaluation
- **CoreOS update strategy** — Zincati maintenance window configuration for PROD
- **Edge services** — domain, DNS, Cloudflare Tunnel, Pi-hole (design exists: `COLOSSUS_EDGE_DNS_CLOUDFLARE_TECHNICAL_DESIGN_v1.0.md`)
- **Management services** — Authentik, reverse proxy, monitoring/logging
- **Application deployment** — services that consume the database infrastructure

---

## 14. Authoritative Artifacts

### 14.1 Configuration

| Artifact | Location | Purpose |
|----------|----------|---------|
| `colossus-dev-db1.bu` | Workstation: `~/colossus-phase2/butane/` | DEV VM configuration source |
| `colossus-dev-db1.ign` | pve-2: `/var/coreos/snippets/` | Compiled Ignition for VM-210 |
| `colossus-prod-db1.bu` | Workstation: `~/colossus-phase3/butane/` | PROD VM configuration source |
| `colossus-prod-db1.ign` | pve-1: `/var/coreos/snippets/` | Compiled Ignition for VM-110 |

### 14.2 Automation Scripts

**DEV (pve-2 / VM-210):**

| Script | Runs on | Purpose |
|--------|---------|---------|
| `01-verify-dev-zfs.sh` | pve-2 | Validate ZFS datasets |
| `02-setup-directory-mappings.sh` | pve-2 | Create Proxmox directory resource mappings |
| `03-create-vm-210.sh` | pve-2 | Create VM with q35, virtiofs, Ignition |
| `04-restore-postgres.sh` | Workstation | Restore PostgreSQL from SQL dump |
| `05-restore-neo4j.sh` | Workstation | Restore Neo4j from dump file |
| `06-restore-qdrant.sh` | Workstation | Restore Qdrant from snapshot |
| `07-validate-parity.sh` | Workstation | Side-by-side validation |

**PROD (pve-1 / VM-110):**

| Script | Runs on | Purpose |
|--------|---------|---------|
| `01-create-prod-zfs.sh` | pve-1 | Create ZFS pool + datasets |
| `02-setup-prod-directory-mappings.sh` | pve-1 | Create PROD directory mappings |
| `03-create-vm-110.sh` | pve-1 | Create VM with q35, virtiofs, Ignition |
| `04-restore-postgres.sh` | Workstation | Restore PostgreSQL from SQL dump |
| `05-restore-neo4j.sh` | Workstation | Restore Neo4j from dump file |
| `06-restore-qdrant.sh` | Workstation | Restore Qdrant from snapshot |
| `07-validate-prod.sh` | Workstation | Full validation + DEV comparison |

### 14.3 Documentation

| Document | Status | Purpose |
|----------|--------|---------|
| This document (Master Context) | **ACTIVE** | Canonical project reference |
| `COLOSSUS_PHASE3_COMPLETION_REPORT.md` | **ACTIVE** | Phase 3 implementation record |
| `COLOSSUS_PHASE2_COMPLETION_REPORT.md` | **ACTIVE** | Phase 2 implementation record |
| `COLOSSUS_COREOS_VM_CREATION_RUNBOOK_v1.md` | **ACTIVE** | Repeatable VM creation procedure |
| `COLOSSUS_DEV_BACKUP_RESTORE_RUNBOOK_v1.md` | **ACTIVE** | Backup/restore procedures for all 3 DBs |
| `COLOSSUS_PROXMOX_CLUSTER_DESIGN_v1.2.md` | **ACTIVE** | Cluster architecture (some details superseded by completion reports) |
| `COLOSSUS_EDGE_DNS_CLOUDFLARE_TECHNICAL_DESIGN_v1.0.md` | **ACTIVE** | Edge services technical design |
| `COLOSSUS_EDGE_DNS_CLOUDFLARE_EXECUTION_TASK_TRACKER_v1.0.md` | **ACTIVE** | Edge services execution checklist |
| `colossus_transition_execution_plan_v_1.md` | **REFERENCE** | Original execution plan (Phase 1–6 strategy) |
| `PHASE-2-EXECUTION-CHECKLIST.md` | **COMPLETE** | All items checked off |

### 14.4 Retired Documents

These served their planning purpose but are superseded by the actual implementation:

| Document | Reason |
|----------|--------|
| `VM200_EXTERNALIZATION_RUNBOOK_v1.2.md` | Described in-place migration; we did parallel rebuild |
| `phase_2_dev_db_externalization_draft.md` | Draft with incorrect paths and container model |
| `PHASE_2_SESSION_TRANSITION.md` | Session handoff doc; Phase 2 is complete |
| `PHASE_3_SESSION_TRANSITION.md` | Session handoff doc; Phase 3 is complete |

---

## 15. VM Inventory

| VMID | Name | Node | Role | Status |
|------|------|------|------|--------|
| 110 | `colossus-prod-db1` | pve-1 | PROD DB host | Running |
| 200 | `colossus-db1-dev` | pve-2 | Frozen DEV reference | Running (do not modify) |
| 210 | `colossus-dev-db1` | pve-2 | Active DEV DB host | Running |
| 900 | PBS | pve-3 | Proxmox Backup Server | Running |

---

## 16. Network

| VM | IP | Method |
|----|-----|--------|
| VM-110 | 10.10.100.110 | Static (Ignition) |
| VM-200 | 10.10.100.50 | Existing |
| VM-210 | 10.10.100.200 | DHCP |

---

## 17. Backup Configuration

| VM | Backup Target | Schedule | Status |
|----|---------------|----------|--------|
| VM-110 | pbs-1 | Daily (automatic) | Active |
| VM-210 | pbs-1 | — | Manual as needed |

PBS retention policy: daily 14, weekly 8, monthly 12.

---

## 18. Success Criteria

The Colossus homelab is successful if:

- Any DB VM can be rebuilt from scratch in under an hour
- Data restoration is documented and boring
- No step relies on memory
- Long pauses do not cause relearning
- DEV → PROD parity is mechanical, not conceptual

**Phase 3 validates all five criteria.** PROD was deployed mechanically from DEV artifacts in two sessions.

---

## 19. Final Rule

> If execution deviates from this document, stop and update the document — not the system.
