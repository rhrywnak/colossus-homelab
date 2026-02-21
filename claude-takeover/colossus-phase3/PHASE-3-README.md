# Colossus Phase 3 — PROD Database VM on pve-1

**Date:** 2026-02-08  
**Target:** VM-110 (`colossus-prod-db1`) on pve-1  
**IP:** 10.10.100.110 (static)  
**Status:** Ready for execution

---

## Overview

Phase 3 replicates the validated DEV pattern on production hardware.
No new design decisions. Every script and config is adapted from the
DEV artifacts that were validated in Phase 2.

**What changes from DEV:**

| Parameter | DEV (VM-210) | PROD (VM-110) |
|-----------|-------------|---------------|
| VMID | 210 | 110 |
| Hostname | colossus-dev-db1 | colossus-prod-db1 |
| Node | pve-2 | pve-1 |
| IP | 10.10.100.200 (DHCP) | 10.10.100.110 (static) |
| ZFS pool | dev-zfs | prod-zfs |
| Storage device | Crucial MX500 2TB (SATA) | Crucial T500 2TB (NVMe) |
| Directory mapping IDs | db-postgres, db-neo4j, db-qdrant | prod-db-postgres, prod-db-neo4j, prod-db-qdrant |

Everything else — Butane structure, Quadlet containers, SELinux context
fix, mount paths, restore procedures — is identical.

---

## Prerequisites

Before starting:

- [ ] Phase 2 complete and locked
- [ ] VM-210 (DEV) running and validated
- [ ] Backup artifacts exist on workstation:
  - `~/colossus-db-backup/dev/postgres/postgres_dump_2026-02-06.sql`
  - `~/colossus-db-backup/dev/neo4j/neo4j.dump`
  - `~/colossus-db-backup/dev/qdrant/paper_chunks-*.snapshot`
- [ ] pve-1 accessible via SSH
- [ ] CoreOS QCOW2 image available (download to pve-1 if needed)

---

## Execution Steps

### Step 0: Copy scripts to pve-1

From your workstation:

```bash
scp -r colossus-phase3/ root@pve-1:/root/colossus-phase3/
```

### Step 1: Create ZFS pool and datasets (on pve-1)

```bash
cd /root/colossus-phase3
bash scripts/01-create-prod-zfs.sh
```

This script will:
1. Show available NVMe devices
2. Print the `zpool create` command for you to run manually (safety measure)
3. On re-run after pool creation, create the three datasets with correct tuning

**You will need to run `zpool create` manually** — the script identifies
the device but won't auto-format to prevent accidents.

After creating the pool, re-run the script to create datasets:

```bash
bash scripts/01-create-prod-zfs.sh
```

Expected output: three datasets with compression=zstd, atime=off, and
correct recordsize (16K/1M/128K).

### Step 2: Create directory mappings (on pve-1)

```bash
bash scripts/02-setup-prod-directory-mappings.sh
```

Creates cluster-level mappings: `prod-db-postgres`, `prod-db-neo4j`, `prod-db-qdrant`.

### Step 3: Download CoreOS image (on pve-1, if needed)

If pve-1 doesn't already have a CoreOS QCOW2:

```bash
mkdir -p /var/coreos/{images,snippets}

podman run --pull=always --rm \
  -v '/var/coreos/images:/data' -w /data \
  quay.io/coreos/coreos-installer:release \
  download -s stable -p proxmoxve -f qcow2.xz --decompress
```

### Step 4: Prepare Ignition (on your workstation)

Edit `butane/colossus-prod-db1.bu`:
- Replace `CHANGEME_POSTGRES_PASSWORD` with your Postgres password
- Replace `CHANGEME_NEO4J_PASSWORD` with your Neo4j password

Transpile:

```bash
podman run --rm -i quay.io/coreos/butane:release --pretty --strict \
  < butane/colossus-prod-db1.bu > colossus-prod-db1.ign
```

Copy to pve-1:

```bash
scp colossus-prod-db1.ign root@pve-1:/var/coreos/snippets/
```

### Step 5: Set UID ownership on ZFS datasets (on pve-1)

Before the VM boots, set ownership so containers can write:

```bash
chown -R 999:999 /prod-zfs/postgres
chown -R 7474:7474 /prod-zfs/neo4j
chown -R 1000:1000 /prod-zfs/qdrant
```

### Step 6: Create VM-110 (on pve-1)

```bash
bash scripts/03-create-vm-110.sh
```

Then start:

```bash
qm start 110
```

### Step 7: Verify VM-110 booted correctly

Wait ~60 seconds, then SSH in:

```bash
ssh core@10.10.100.110
```

Check:

```bash
# Hostname
hostname

# virtiofs mounts with SELinux context
mount | grep virtiofs

# SELinux labels
ls -dZ /var/mnt/data/*

# Running containers
sudo podman ps
```

**Expected:** Three virtiofs mounts with `container_file_t`, three
containers running. Containers will have empty data at this point.

### Step 8: Restore databases (from your workstation)

**PostgreSQL** (online restore):

```bash
bash scripts/04-restore-postgres.sh \
  ~/colossus-db-backup/dev/postgres/postgres_dump_2026-02-06.sql \
  10.10.100.110
```

**Neo4j** (stops service briefly):

```bash
bash scripts/05-restore-neo4j.sh \
  ~/colossus-db-backup/dev/neo4j/neo4j.dump \
  10.10.100.110
```

**Qdrant** (online restore):

```bash
bash scripts/06-restore-qdrant.sh \
  ~/colossus-db-backup/dev/qdrant/paper_chunks-8293711371686424-2026-02-06-18-05-12.snapshot \
  paper_chunks \
  10.10.100.110
```

### Step 9: Validate (from your workstation)

PROD only:

```bash
bash scripts/07-validate-prod.sh 10.10.100.110
```

PROD vs DEV comparison:

```bash
NEO4J_PASS='your-neo4j-password' \
  bash scripts/07-validate-prod.sh 10.10.100.110 10.10.100.200
```

All checks must pass.

---

## Rollback

If anything fails:

1. Stop VM-110: `qm stop 110`
2. Destroy VM-110: `qm destroy 110`
3. ZFS datasets can be wiped: `zfs destroy -r prod-zfs` (or keep for retry)
4. DEV (VM-210) is unaffected
5. Re-run from any step after fixing the issue

---

## Phase 3 Completion Gate

Phase 3 is complete when:

- [ ] All 7 validation checks pass
- [ ] DEV vs PROD data equivalence confirmed
- [ ] VM-110 survives a reboot (containers auto-start)
- [ ] PBS backup of VM-110 configured
- [ ] Documentation updated (Master Context)
