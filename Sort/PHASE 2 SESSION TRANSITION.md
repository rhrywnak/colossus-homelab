 # PHASE_2_SESSION_TRANSITION.md
Colossus Proxmox Project

Date: Friday, Feb 6, 2026  
Phase: Transition from Phase 1 (PBS + backups) → Phase 2 (DEV DB externalization)  
Status: Phase 2 preparation complete; execution not yet started

---

## 1. Purpose of This Document

This document formally closes Phase 2 preparation work and defines the exact
starting conditions for the next ChatGPT session, where Phase 2 execution
will begin.

Its goals are to:

- Preserve validated knowledge from Phase 1 and Phase 2 prep
- Prevent re-litigation of resolved issues
- Ensure Phase 2 execution is repeatable, scripted, and non-destructive
- Enable safe DEV migration using parallel validation instead of in-place changes

---

## 2. High-Level Phase 2 Objective (Authoritative)

Phase 2 objective:

Externalize all database storage from the DEV database VM (VM-200 on pve-2)
by rebuilding databases on a new Fedora CoreOS VM using external host-mounted
storage, then validating correctness by running old and new systems
side-by-side.

Key constraints:

- VM-200 remains untouched during migration
- No in-place container modification on VM-200
- Validation precedes any cutover
- Production (pve-1) is modified only after DEV passes validation

---

## 3. Current Infrastructure State (Locked)

### 3.1 Proxmox Cluster
- Cluster healthy
- pve-1: future production DB host
- pve-2: DEV DB host (VM-200)
- pve-3: PBS host (Phase 1 complete)

### 3.2 VM-200 (DEV, pve-2)
- OS: Fedora CoreOS
- Container runtime: Podman
- Containers (systemd-managed via Butane):
  - colossus-postgres
  - colossus-neo4j
  - colossus-qdrant
- Database data currently stored inside VM filesystem
- Container lifecycle controlled by systemd units

---

## 4. Backup State (Hard Gate — VERIFIED)

All backups below are complete, validated, and copied off-host.

### 4.1 Neo4j
- Version: Neo4j 5.x
- Backup method:
  - systemctl stop colossus-neo4j.service
  - one-shot neo4j-admin database dump container
  - systemctl start colossus-neo4j.service
- Artifact:
  - neo4j.dump
- Status: VERIFIED

### 4.2 PostgreSQL
- Backup method:
  - pg_dumpall from running container
- Artifact:
  - postgres_dump_2026-02-06.sql
- Location:
  - Linux desktop: ~/colossus-db-backup/dev/postgres/
- Status: VERIFIED

### 4.3 Qdrant
- Key discovery:
  - Snapshots stored in /qdrant/snapshots inside container
  - That path is not bind-mounted to the host
- Canonical backup method:
  - Create snapshot via API
  - Export snapshot via HTTP download
- Artifact:
  - paper_chunks-8293711371686424-2026-02-06-18-05-12.snapshot
- Location:
  - /var/containers/colossus/qdrant-backups/
- Status: VERIFIED

No Phase 2 execution may begin unless all three artifacts exist.

---

## 5. Canonical Documentation & Artifacts

### 5.1 Phase 2 Runbook
Authoritative bundle:

PHASE2_REFAC_BUTANE_VIRTIOFS_v2.zip

Includes:
- Correct, validated backup procedures
- Hard pre-migration gate
- Backup and restore script templates
- No filesystem layout assumptions
- Explicit sudo usage
- Idempotent command structure

### 5.2 Lessons Learned (Must Be Respected)

1. Never assume container filesystem layout — always inspect mounts
2. Systemd controls container lifecycle — stop services, not processes
3. Qdrant backups must be exported via HTTP
4. All steps must be repeatable and scriptable
5. Pause execution when reality diverges from assumptions

---

## 6. Phase 2 Execution Strategy (Agreed)

### 6.1 Migration Pattern
- Create a new Fedora CoreOS VM (DEV candidate)
- Use:
  - virtiofs
  - host ZFS datasets
  - Butane + Ignition
- Recreate database containers from scratch
- Restore data from verified backups
- Run old and new databases in parallel
- Validate data equivalence (Neo4j, PostgreSQL, Qdrant)
- Only then consider cutover

### 6.2 Explicit Non-Goals
- No in-place migration on VM-200
- No production changes yet
- No container image optimization
- No performance tuning

---

## 7. Next Session Entry Point (Critical)

When starting the next ChatGPT session, begin with:

“We are resuming the Colossus Proxmox project.
Phase 1 is complete.
Phase 2 preparation is complete.
We are beginning Phase 2 execution using
PHASE2_REFAC_BUTANE_VIRTIOFS_v2.zip.
Do not revisit backup procedures.”

First task in the new session:

Create the Phase 2 execution checklist and begin provisioning
the new DEV Fedora CoreOS VM.

---

## 8. Phase Lock

- Phase 1: LOCKED
- Phase 2 (Preparation): LOCKED
- Phase 2 (Execution): PENDING — next session


