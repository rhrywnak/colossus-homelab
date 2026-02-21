# PHASE 2 — DEV Database Externalization (DRAFT)

**Project:** Colossus Proxmox Build  
**Phase:** 2 (DEV)  
**Status:** DRAFT — DO NOT EXECUTE  
**Applies to:** pve-2 (DEV only)

---

## 0. Purpose and Safety Guarantees

Phase 2 proves that **all database persistence can live outside the VM**, without risking existing data.

**Core safety rule (non-negotiable):**
- **VM-200 is NOT modified.**
- VM-200 remains the reference / baseline DEV system.
- All work is done in a **new DEV DB VM**.
- Rollback is achieved by deleting the new VM only.

This phase intentionally favors **parallel rebuild + restore** over in-place migration.

---

## 1. Phase 2 Objective (Locked)

Move persistence for the following databases **outside of the VM boundary**:

| Database | Current Container | Target State |
|--------|------------------|-------------|
| PostgreSQL 17 | `colossus-postgres` | External ZFS-backed storage |
| Neo4j 5 | `colossus-neo4j` | External ZFS-backed storage |
| Qdrant | `colossus-qdrant` | External ZFS-backed storage |

The VM must become **disposable**, with all state surviving VM deletion.

---

## 2. Lessons Applied from Phase 1 (PBS)

The following lessons are explicitly applied:

1. **Never assume storage exists** — ZFS pools must be registered with Proxmox before use
2. **Separate OS and data disks** — data must never land on the VM root disk
3. **Treat VMs as cattle** — rebuildable by design
4. **Verify at every layer** — host, VM, container
5. **Prefer cold rebuild over live mutation** for stateful systems
6. **Document fingerprints, mounts, and wiring explicitly**

---

## 3. Current State (Reference System)

### 3.1 VM-200 (DEV Reference)

- Node: `pve-2`
- Role: DEV DB host
- OS: Fedora CoreOS
- Runtime: Podman
- Status: **Frozen reference** (no changes allowed)

### 3.2 Current Data Placement (Inside VM-200)

| Database | VM-local Path |
|--------|---------------|
| PostgreSQL | `/var/containers/colossus/postgres` |
| Neo4j | `/var/containers/colossus/neo4j` |
| Qdrant | `/var/containers/colossus/qdrant` |

These paths are **bind-mounted into containers** and therefore still VM-local.

---

## 4. Target Storage Architecture (DEV)

### 4.1 Physical Device (Authoritative)

- Node: `pve-2`
- Device: **Crucial MX500 2TB SATA SSD**
- Purpose: DEV database persistence

### 4.2 ZFS Pool

- Pool name: `dev-zfs`
- Owner: Proxmox host (`pve-2`)
- Managed at host level

### 4.3 ZFS Datasets

| Dataset | Purpose |
|-------|--------|
| `dev-zfs/postgres` | PostgreSQL data |
| `dev-zfs/neo4j` | Neo4j data |
| `dev-zfs/qdrant` | Qdrant data |

Each dataset is independently mountable and snapshot-capable.

---

## 5. New DEV DB VM (Candidate)

### 5.1 VM Characteristics

- Node: `pve-2`
- Role: DEV DB (candidate)
- OS: Fedora CoreOS
- Runtime: Podman
- Data disks: **NONE** (all data comes from host mounts)

### 5.2 Storage Exposure Strategy

- Host ZFS datasets are exposed into the VM via **virtiofs**
- VM sees stable mount points:

```
/mnt/db/postgres
/mnt/db/neo4j
/mnt/db/qdrant
```

---

## 6. Container Recreation Strategy

Containers are recreated **from scratch** in the new VM:

### 6.1 General Rules

- Same images and versions as VM-200
- Qdrant version **pinned** (no `latest`)
- Same ports and env vars
- **Different volume sources** (external mounts)

### 6.2 Volume Mapping (Target)

| Container | External Mount | Container Path |
|---------|---------------|----------------|
| Postgres | `/mnt/db/postgres` | `/var/lib/postgresql/data` |
| Neo4j | `/mnt/db/neo4j` | `/data` |
| Qdrant | `/mnt/db/qdrant` | `/qdrant/storage` |

No container data may live under `/var/containers` in the new VM.

---

## 7. Data Migration Method (Restore-Based)

### 7.1 PostgreSQL

- Export from VM-200 using `pg_dumpall` or logical dumps
- Restore into new container

### 7.2 Neo4j

- Use supported Neo4j backup/export mechanism
- Restore into empty externalized datastore

### 7.3 Qdrant

- Snapshot/export from VM-200
- Import into new Qdrant instance

**No live filesystem copying between running containers.**

---

## 8. Validation Gates (Critical)

Migration is considered successful only if:

### 8.1 Structural Validation

- Database starts cleanly
- No permission or path errors

### 8.2 Data Validation

- Node / table / collection counts match
- Sample queries return identical results

### 8.3 Side-by-Side Comparison

- Old DB (VM-200) vs New DB (candidate VM)
- No client-visible differences

---

## 9. Rollback Strategy

Rollback is trivial:

- Stop new DEV DB VM
- Destroy new VM
- VM-200 remains untouched

No data loss possible.

---

## 10. Promotion to Production (Deferred)

Only after DEV parity is proven:

- Apply **identical process** on `pve-1`
- No new design decisions
- Same dataset layout
- Same validation gates

Production is treated as a **repeat**, not a redesign.

---

## 11. Phase 2 Exit Criteria

Phase 2 (DEV) is complete when:

- New DEV DB VM runs all three databases
- All DB data lives outside the VM
- Side-by-side validation passes
- VM-200 remains intact and unchanged

---

## 12. Phase Status

- **State:** DRAFT
- **Execution:** NOT AUTHORIZED
- **Next step:** Review, annotate, and approve

No steps in this document may be executed until explicitly approved.

