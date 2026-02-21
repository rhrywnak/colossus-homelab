# PHASE_2_EXECUTION_CHECKLIST.md

## PRE-FLIGHT (MUST ALL BE TRUE)
- [ ] Phase 1 locked
- [ ] Phase 2 prep locked
- [ ] PHASE2_REFAC_BUTANE_VIRTIOFS_v2.zip reviewed
- [ ] Neo4j dump exists and copied off VM-200
- [ ] PostgreSQL SQL dump exists and copied off VM-200
- [ ] Qdrant snapshot exists and copied off VM-200
- [ ] VM-200 unchanged since backups
- [ ] No production (pve-1) changes planned

---

## STEP 1 — Host Storage Prep (pve-2)
- [ ] Identify target host disk (SATA SSD Crucial MX500 2TB)
- [ ] Create ZFS pool (if not existing)
- [ ] Create datasets:
  - [ ] postgres
  - [ ] neo4j
  - [ ] qdrant
- [ ] Set mountpoints
- [ ] Verify permissions and ownership model

---

## STEP 2 — New DEV CoreOS VM Provisioning
- [ ] Create new VM (do NOT reuse VM-200)
- [ ] Attach virtiofs mounts:
  - [ ] /mnt/db/postgres
  - [ ] /mnt/db/neo4j
  - [ ] /mnt/db/qdrant
- [ ] Verify virtiofs mounts inside VM
- [ ] Apply Ignition via Butane
- [ ] Confirm systemd units created

---

## STEP 3 — Container Bring-Up (Empty Data)
- [ ] Start PostgreSQL container
- [ ] Start Neo4j container
- [ ] Start Qdrant container
- [ ] Confirm containers running
- [ ] Confirm no data present

---

## STEP 4 — Data Restore
- [ ] PostgreSQL restore from SQL dump
- [ ] Neo4j restore from neo4j.dump (offline)
- [ ] Qdrant restore from snapshot via HTTP
- [ ] Confirm restore success per service

---

## STEP 5 — Parallel Validation
- [ ] Old Neo4j reachable
- [ ] New Neo4j reachable
- [ ] Data equivalence verified
- [ ] Old PostgreSQL reachable
- [ ] New PostgreSQL reachable
- [ ] Data equivalence verified
- [ ] Old Qdrant reachable
- [ ] New Qdrant reachable
- [ ] Collection counts verified

---

## STEP 6 — Phase 2 Completion Gate
- [ ] Validation passed for all 3 DBs
- [ ] VM-200 still intact
- [ ] No cutover performed
- [ ] Phase 2 execution complete

