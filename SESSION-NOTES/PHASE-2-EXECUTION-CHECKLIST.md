# PHASE 2 EXECUTION CHECKLIST

**Status:** ✅ COMPLETE — 2026-02-08  
**VM-210:** `colossus-dev-db1` on pve-2  

---

## PRE-FLIGHT (MUST ALL BE TRUE)
- [x] Phase 1 locked
- [x] Phase 2 prep locked
- [x] PHASE2_REFAC_BUTANE_VIRTIOFS_v2.zip reviewed (NOTE: contained critical errors; corrected during execution)
- [x] Neo4j dump exists and copied off VM-200
- [x] PostgreSQL SQL dump exists and copied off VM-200
- [x] Qdrant snapshot exists and copied off VM-200
- [x] VM-200 unchanged since backups
- [x] No production (pve-1) changes planned

---

## STEP 1 — Host Storage Prep (pve-2)
- [x] Identify target host disk (SATA SSD Crucial MX500 2TB)
- [x] Create ZFS pool (`dev-zfs`)
- [x] Create datasets:
  - [x] postgres (recordsize=16K)
  - [x] neo4j (recordsize=1M)
  - [x] qdrant (recordsize=128K)
- [x] Set mountpoints
- [x] Verify permissions and ownership model

---

## STEP 2 — New DEV CoreOS VM Provisioning
- [x] Create new VM (VM-210, did NOT reuse VM-200)
- [x] Attach virtiofs mounts via Proxmox directory resource mappings:
  - [x] /var/mnt/data/postgres (dirid=db-postgres)
  - [x] /var/mnt/data/neo4j (dirid=db-neo4j)
  - [x] /var/mnt/data/qdrant (dirid=db-qdrant)
- [x] Verify virtiofs mounts inside VM (with SELinux context=container_file_t)
- [x] Apply Ignition via Butane (cloud-init vendor snippet)
- [x] Confirm systemd units created (Quadlet generator)

---

## STEP 3 — Container Bring-Up (Empty Data)
- [x] Start PostgreSQL container (colossus-postgres)
- [x] Start Neo4j container (colossus-neo4j)
- [x] Start Qdrant container (colossus-qdrant)
- [x] Confirm containers running
- [x] Confirm no data present

---

## STEP 4 — Data Restore
- [x] PostgreSQL restore from SQL dump (pg_dumpall via podman exec)
- [x] Neo4j restore from neo4j.dump (offline, one-shot container with --security-opt label=disable)
- [x] Qdrant restore from snapshot via HTTP API upload
- [x] Confirm restore success per service

---

## STEP 5 — Parallel Validation
- [x] Old Neo4j reachable (VM-200, 10.10.100.50)
- [x] New Neo4j reachable (VM-210, 10.10.100.200)
- [x] Data equivalence verified (node counts match)
- [x] Old PostgreSQL reachable
- [x] New PostgreSQL reachable
- [x] Data equivalence verified (database list, table counts match)
- [x] Old Qdrant reachable
- [x] New Qdrant reachable
- [x] Collection counts verified (point counts match)

---

## STEP 6 — Phase 2 Completion Gate
- [x] Validation passed for all 3 DBs
- [x] VM-200 still intact and unchanged
- [x] No cutover performed
- [x] Phase 2 execution complete

---

## Implementation Notes (Added at Completion)

**Key deviations from original plan:**
- Used **parallel rebuild** (new VM-210) instead of in-place migration on VM-200
- Used **Podman Quadlet** (.container files) instead of traditional systemd ExecStart units
- Mount paths are `/var/mnt/data/` (CoreOS canonical) not `/mnt/db/` as originally planned
- virtiofs attached via **directory resource mappings** (not raw paths in qm set)
- **SELinux context= mount option** was required — not anticipated in original planning

**Critical discovery:** virtiofs mounts from non-SELinux hosts need
`context="system_u:object_r:container_file_t:s0"` in systemd mount units.
Without this, containers get "Permission denied" despite correct Unix permissions.
