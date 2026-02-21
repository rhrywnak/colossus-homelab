# Colossus Homelab – Master Context, Architecture, and Execution Plan

**Project Name:** Colossus  
**Scope:** On-prem Proxmox homelab for containerized databases, LLM infrastructure, and agentic systems  
**Audience:** Primary operator (authoritative), future collaborators, future self  
**Document Type:** Canonical context + execution reference  
**Status:** Living document with phase locks  

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
|-----|------|
| pve-1 | Production workloads |
| pve-2 | Development workloads |
| pve-3 | Proxmox Backup Server |

Roles are **exclusive**. No node serves mixed responsibilities.

---

### 4.2 Virtualization Layer

- Proxmox VE cluster
- VM lifecycle controlled via `qm` CLI
- No UI-only configuration considered authoritative
- All important VM configuration must be expressible in scripts

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
- systemd unit files
- Podman

---

## 5. Storage Architecture (Canonical)

### 5.1 Host-Level Storage

- ZFS pools created on Proxmox hosts
- One pool per environment where appropriate
- Separate datasets per service

Example dataset layout:
dev-zfs/
postgres
neo4j
qdrant

Production mirrors this layout exactly.

---

### 5.2 VM-Level Access

- **virtiofs** is used to mount host ZFS datasets into CoreOS VMs
- VM root filesystem never contains authoritative data
- All persistent state resides on the Proxmox host

This enables:
- Fast rebuilds
- Safe restores
- Clear failure boundaries

---

## 6. Container Model

### 6.1 Runtime

- Podman (rootful)
- Containers managed exclusively via systemd units

### 6.2 Lifecycle Rules

- Containers are disposable
- Container images are replaceable
- Data is external and persistent
- Containers may be destroyed and recreated at any time

### 6.3 Configuration Model

- Environment files in `/etc/containers/env`
- systemd unit files created via Ignition
- No ad-hoc `podman run` usage

---

## 7. Databases in Scope

| Service | Purpose | Persistence |
|------|-------|------------|
| PostgreSQL | Relational data | ZFS dataset |
| Neo4j | Knowledge graph | ZFS dataset |
| Qdrant | Vector search | ZFS dataset |

All follow the same lifecycle:
1. External storage mounted
2. Empty container started
3. Data restored
4. Validated
5. Put into service

---

## 8. Current State (Locked)

### 8.1 Phase 1 — Backups & PBS

- Proxmox Backup Server configured
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
- ZFS pool created on pve-2
- Datasets created and tuned:
  - postgres
  - neo4j
  - qdrant
- Existing DEV VM (VM-200) untouched

**Status:** 🟡 In progress

---

## 9. Repeatability & Parity Requirement

From this point forward:

- No VM creation is considered valid unless it is scriptable
- Manual steps are allowed only to discover correct parameters
- All validated steps must be codified

**DEV artifacts are the source of truth for PROD.**

---

## 10. Remaining Work — Phase 2 (DEV Execution)

1. Formalize VM creation script (`qm`-based)
2. Create new DEV CoreOS VM from script
3. Attach virtiofs datasets
4. Apply Ignition configuration
5. Bring up empty containers
6. Restore PostgreSQL data
7. Restore Neo4j data
8. Restore Qdrant snapshot
9. Run parallel validation vs VM-200
10. Phase 2 exit gate

---

## 11. Production Work — Phase 3 (pve-1)

**All work below must be performed using the same scripts and artifacts validated in DEV.**

### 11.1 Production Host Preparation (pve-1)

- Identify production storage devices
- Create ZFS pool (e.g. `prod-zfs`)
- Create datasets:
  - prod-zfs/postgres
  - prod-zfs/neo4j
  - prod-zfs/qdrant
- Apply identical ZFS tuning (compression, recordsize, atime)

---

### 11.2 Production VM Creation

- Create PROD CoreOS VM via script
- Use same CPU/memory profile unless explicitly justified
- Attach virtiofs datasets
- Apply Ignition config (PROD-specific variables only)

---

### 11.3 Production Container Bring-Up

- Start containers empty
- Verify systemd control
- Verify mounts and permissions
- Confirm no residual data

---

### 11.4 Production Data Migration

- Restore from validated DEV-tested backups
- Do **not** modify containers during restore
- Validate service health

---

### 11.5 Production Validation

- Confirm database integrity
- Confirm application connectivity
- Confirm restart behavior
- Confirm PBS backups function as expected

---

### 11.6 Production Cutover Gate

Production is not considered live until:

- DEV and PROD data equivalence confirmed
- Restart tests pass
- Restore procedure re-verified
- Documentation updated

---

## 12. Success Criteria

The Colossus homelab is successful if:

- Any DB VM can be rebuilt from scratch in under an hour
- Data restoration is documented and boring
- No step relies on memory
- Long pauses do not cause relearning
- DEV → PROD parity is mechanical, not conceptual

---

## 13. Final Rule

> If execution deviates from this document, stop and update the document — not the system.


