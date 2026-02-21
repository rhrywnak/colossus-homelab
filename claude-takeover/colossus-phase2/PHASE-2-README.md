# Colossus Phase 2 — DEV Database Externalization

**Date:** 2026-02-07
**Scope:** DEV only (pve-2). Production (pve-1) is explicitly out of scope.
**Replaces:** `PHASE2_REFAC_BUTANE_VIRTIOFS_v2.zip` (retired)

## Safety Contract

- **VM-200 is frozen.** No edits, no cleanup, no in-place migration.
- All work happens in **VM-210** (new candidate).
- Rollback = delete VM-210. VM-200 remains authoritative.

---

## What's In This Package

```
colossus-phase2/
├── README.md                           ← You are here
├── butane/
│   └── colossus-db1-dev2.bu            ← Butane config (→ Ignition JSON)
└── scripts/
    ├── 01-verify-dev-zfs.sh            ← Verify ZFS datasets on pve-2
    ├── 02-setup-directory-mappings.sh  ← Create Proxmox virtiofs mappings
    ├── 03-create-vm-210.sh             ← Create VM-210 (CoreOS + virtiofs)
    ├── 04-restore-postgres.sh          ← Restore PostgreSQL from SQL dump
    ├── 05-restore-neo4j.sh             ← Restore Neo4j from dump file
    ├── 06-restore-qdrant.sh            ← Restore Qdrant from snapshot
    └── 07-validate-parity.sh           ← Side-by-side validation vs VM-200
```

---

## Architecture Summary

```
pve-2 (Proxmox host)
├── dev-zfs/postgres  ──virtiofs──→  VM-210:/mnt/data/postgres  → colossus-postgres container
├── dev-zfs/neo4j     ──virtiofs──→  VM-210:/mnt/data/neo4j     → colossus-neo4j container
└── dev-zfs/qdrant    ──virtiofs──→  VM-210:/mnt/data/qdrant    → colossus-qdrant container
```

- **Data lives on:** ZFS datasets on the Proxmox host (outside the VM)
- **VM is:** disposable (rebuild from Ignition at any time)
- **Containers are:** disposable (Quadlet definitions recreate them on boot)
- **virtiofs tags:** `db-postgres`, `db-neo4j`, `db-qdrant`

---

## Execution Order

### Prerequisites

You should already have:
- [x] Phase 1 complete (PBS backups verified)
- [x] Phase 2 preparation complete
- [x] Database backups exist and copied off VM-200:
  - PostgreSQL: `postgres_dump_2026-02-06.sql`
  - Neo4j: `neo4j.dump`
  - Qdrant: `paper_chunks-*.snapshot`
- [x] ZFS pool `dev-zfs` with datasets on pve-2
- [x] CoreOS QCOW2 on pve-2 at `/var/coreos/images/`

### Step 1: Verify ZFS (on pve-2)

```bash
bash scripts/01-verify-dev-zfs.sh
```

Read-only. Confirms datasets, mountpoints, compression, and recordsize are correct.

### Step 2: Create directory mappings (on pve-2)

```bash
bash scripts/02-setup-directory-mappings.sh
```

Creates Proxmox cluster-level directory resource mappings that wire ZFS
dataset paths to virtiofs tag names.

### Step 3: Prepare Ignition (on your workstation)

**Before transpiling**, edit `butane/colossus-db1-dev2.bu`:
- Replace `CHANGEME_POSTGRES_PASSWORD` with your Postgres password
- Replace `CHANGEME_NEO4J_PASSWORD` with your Neo4j password

Then transpile:

```bash
podman run --rm -i quay.io/coreos/butane:release --pretty --strict \
  < butane/colossus-db1-dev2.bu > colossus-db1-dev2.ign
```

Copy to pve-2:

```bash
scp colossus-db1-dev2.ign root@pve-2:/var/coreos/snippets/ 
```

### Step 4: Create VM-210 (on pve-2)

```bash
bash scripts/03-create-vm-210.sh
```

Then start it:

```bash
qm start 210
```

### Step 5: Verify VM-210 booted correctly

SSH in (find the DHCP IP from your router or `qm terminal 210`):

```bash
ssh core@<vm210-ip>
```

Check:
```bash
# virtiofs mounts
mount | grep virtiofs

# Container services
sudo systemctl status colossus-postgres colossus-neo4j colossus-qdrant

# Running containers
sudo podman ps
```

All three containers should be running with empty data directories.

### Step 6: Restore databases (from your workstation)

**PostgreSQL:**
```bash
bash scripts/04-restore-postgres.sh \
  ~/colossus-db-backup/dev/postgres/postgres_dump_2026-02-06.sql \
  <vm210-ip>
```

**Neo4j:**
```bash
bash scripts/05-restore-neo4j.sh \
  ./neo4j.dump \
  <vm210-ip>
```

**Qdrant:**
```bash
bash scripts/06-restore-qdrant.sh \
  ./paper_chunks-8293711371686424-2026-02-06-18-05-12.snapshot \
  paper_chunks \
  <vm210-ip>
```

### Step 7: Validate parity (from your workstation)

```bash
# Set Neo4j password for both VMs (or export NEO4J_PASS)
NEO4J_PASS=<your-neo4j-password> \
  bash scripts/07-validate-parity.sh <vm200-ip> <vm210-ip>
```

All checks must pass before Phase 2 is considered complete.

---

## Rollback

If anything fails:
1. Stop VM-210: `qm stop 210`
2. Destroy VM-210: `qm destroy 210`
3. VM-200 is untouched and still authoritative
4. ZFS datasets can be wiped and recreated if needed

---

## What This Proves

When Phase 2 completes successfully:
- VM-210 is a fully disposable DB host
- All data survives VM destruction (lives on ZFS)
- The Butane/Ignition config can recreate the VM from scratch
- The same process (with variable substitution) becomes Phase 3 for production

---

## Moving to Production (Phase 3 — Future)

Phase 3 applies the identical pattern on pve-1:
1. Create `prod-zfs` pool + datasets on pve-1
2. Create directory mappings on pve-1
3. Adjust Butane config (hostname, env vars, VMID)
4. Create PROD VM from the same script
5. Restore from DEV-validated backups
6. Validate

**No new design decisions.** Production is a repeat, not a redesign.
