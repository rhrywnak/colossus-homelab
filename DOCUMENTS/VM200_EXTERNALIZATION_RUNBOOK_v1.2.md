# VM 200 Externalization Runbook (Dev DB VM on pve-2)
**Version:** v1.2  
**Date:** 2026-02-02  
**Scope:** Externalize Neo4j/Postgres/Qdrant persistence for **VM 200 (`colossus-db1-dev`)** so DB data is **outside container layers** and **outside the VM OS disk** (preferred).  
**Target audience:** Roman (operator)

---

## 0) Goal and Success Criteria

### Goal
Move all **stateful DB data** currently living in container writable layers (or inside the VM’s main disk) to **host-managed persistent storage** on **pve-2**, then mount into the CoreOS VM and map into containers.

### Success criteria
- VM 200 still boots normally.
- Postgres/Neo4j/Qdrant start automatically and are reachable.
- Data directories are stored on pve-2 “dev data” storage (not inside container layers).
- A rollback path exists and is tested (snapshot).
- PBS backup can capture the VM + externalized data reliably (later step).

---

## 1) High-Level Plan (Order Matters)

1. **Pre-flight & snapshot**
2. **Prepare pve-2 persistent storage** (recommended: ZFS pool on the 2TB MX500)
3. **Expose datasets to VM 200** (recommended: **virtiofs** mounts)
4. **Inside VM 200: mount volumes + create target directories**
5. **Cut over each service one-by-one**:
   - Postgres → Neo4j → Qdrant  
6. **Verification**
7. **Rollback plan (if needed)**
8. **Post-cutover: backup and documentation**

---

## 2) Preconditions and Safety

### 2.1 Preconditions
- Cluster `colossus` healthy (3 nodes, quorum OK).
- VM 200 running on **pve-2** and reachable.
- A snapshot already exists (you created `post-cluster-recover-2026-02-02`). Good.

### 2.2 Safety rules
- **Do not** delete or format any disk that contains active VM storage.
- Stop only **one DB service at a time**.
- Copy data while the service is **stopped**.
- Keep the old data in place until you’ve validated and backed up.

---

## 3) Prepare Persistent Storage on pve-2 (Recommended: ZFS on 2TB MX500)

### 3.1 Identify the 2TB MX500 device
On **pve-2**:
```bash
lsblk
```
Identify the 2TB device (likely `/dev/sda` or `/dev/sdb` depending on your cabling).  
In this runbook we will refer to it as **`/dev/sdX`**. Replace accordingly.

### 3.2 Create ZFS pool (dev data pool)
On **pve-2**:
```bash
zpool create \
  -o ashift=12 \
  -O compression=zstd \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  dev-zfs \
  /dev/sdX
```

Verify:
```bash
zpool status
zfs list
```

### 3.3 Create datasets for each DB
On **pve-2**:
```bash
zfs create dev-zfs/db-postgres
zfs create dev-zfs/db-neo4j
zfs create dev-zfs/db-qdrant
```

Optional tuning (safe defaults; can refine later):
```bash
zfs set recordsize=16K dev-zfs/db-postgres
zfs set recordsize=1M dev-zfs/db-neo4j
zfs set recordsize=128K dev-zfs/db-qdrant
```

### 3.4 Confirm mountpoints
ZFS will mount datasets under `/dev-zfs/...` **or** `/dev-zfs` style depending on your system’s mountpoint. Check:
```bash
zfs get mountpoint dev-zfs/db-postgres
zfs get mountpoint dev-zfs/db-neo4j
zfs get mountpoint dev-zfs/db-qdrant
```

If mountpoints are not what you want, set them explicitly:
```bash
zfs set mountpoint=/dev-zfs/db-postgres dev-zfs/db-postgres
zfs set mountpoint=/dev-zfs/db-neo4j dev-zfs/db-neo4j
zfs set mountpoint=/dev-zfs/db-qdrant dev-zfs/db-qdrant
```

Then:
```bash
ls -la /dev-zfs
```

---

## 4) Expose pve-2 Datasets to VM 200 (virtiofs)

### 4.1 Why virtiofs
- High performance
- Simple semantics for “host path mounted into guest”
- Ideal for CoreOS container hosts

### 4.2 Add virtiofs mounts to VM 200
On **pve-2** (host), **shutdown is not required** but a reboot of the guest may be simplest after adding devices.

Run:
```bash
qm set 200 --virtiofs0 /dev-zfs/db-postgres,tag=pgdata
qm set 200 --virtiofs1 /dev-zfs/db-neo4j,tag=neo4jdata
qm set 200 --virtiofs2 /dev-zfs/db-qdrant,tag=qdrantdata
```

Confirm config:
```bash
qm config 200 | grep -i virtiofs
```

Restart VM 200 (recommended):
```bash
qm reboot 200
```

---

## 5) Inside VM 200 (CoreOS): Mount the virtiofs shares

> CoreOS expects you to be declarative; however, for this migration run we’ll apply a minimal, repeatable method you can later encode in Ignition.

### 5.1 Create mount points
Inside the VM:
```bash
sudo mkdir -p /mnt/data/postgres
sudo mkdir -p /mnt/data/neo4j
sudo mkdir -p /mnt/data/qdrant
```

### 5.2 Mount virtiofs shares (test)
Inside the VM:
```bash
sudo mount -t virtiofs pgdata /mnt/data/postgres
sudo mount -t virtiofs neo4jdata /mnt/data/neo4j
sudo mount -t virtiofs qdrantdata /mnt/data/qdrant
```

Verify:
```bash
mount | grep virtiofs
df -h | grep /mnt/data
```

### 5.3 Make mounts persistent (systemd mount units)
Create these files:

**`/etc/systemd/system/mnt-data-postgres.mount`**
```ini
[Unit]
Description=Mount Postgres data (virtiofs)
After=network-online.target

[Mount]
What=pgdata
Where=/mnt/data/postgres
Type=virtiofs
Options=defaults

[Install]
WantedBy=multi-user.target
```

**`/etc/systemd/system/mnt-data-neo4j.mount`**
```ini
[Unit]
Description=Mount Neo4j data (virtiofs)
After=network-online.target

[Mount]
What=neo4jdata
Where=/mnt/data/neo4j
Type=virtiofs
Options=defaults

[Install]
WantedBy=multi-user.target
```

**`/etc/systemd/system/mnt-data-qdrant.mount`**
```ini
[Unit]
Description=Mount Qdrant data (virtiofs)
After=network-online.target

[Mount]
What=qdrantdata
Where=/mnt/data/qdrant
Type=virtiofs
Options=defaults

[Install]
WantedBy=multi-user.target
```

Enable:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mnt-data-postgres.mount
sudo systemctl enable --now mnt-data-neo4j.mount
sudo systemctl enable --now mnt-data-qdrant.mount
```

Reboot once and confirm mounts return automatically:
```bash
sudo reboot
```

---

## 6) Determine Your Current Container Runtime Layout (One-Time Discovery)

Inside VM 200, run:

```bash
sudo podman ps --format "table {.Names}\t{.Image}\t{.Status}\t{.Ports}"
sudo podman inspect postgres 2>/dev/null | head
sudo podman inspect neo4j 2>/dev/null | head
sudo podman inspect qdrant 2>/dev/null | head
```

If your containers are not named `postgres/neo4j/qdrant`, list names and adapt.

Also locate current data paths:
```bash
sudo podman inspect <name> --format '{{json .Mounts}}'
```

We will migrate from the *current data directory* to the new `/mnt/data/...` mount.

---

## 7) Cutover Procedure: Postgres (First)

### 7.1 Stop Postgres
```bash
sudo systemctl stop postgres.service 2>/dev/null || true
sudo podman stop postgres
```

Confirm stopped:
```bash
sudo podman ps | grep -i postgres || echo "postgres stopped"
```

### 7.2 Identify current Postgres data directory
Common cases:
- Volume mapped to `/var/lib/postgresql/data`
- Or data inside container layer (bad)

Check:
```bash
sudo podman inspect postgres --format '{{range .Mounts}}{{println .Source .Destination}}{{end}}'
```

If you already have a host path like `/some/path:/var/lib/postgresql/data`, we will migrate that **host path** to `/mnt/data/postgres/data`.

### 7.3 Create target directory and set ownership
```bash
sudo mkdir -p /mnt/data/postgres/data
sudo chown -R 999:999 /mnt/data/postgres/data || true
```
> Note: Postgres UID inside official images is often 999. If your image differs, use `podman exec -it postgres id` before stopping next time.

### 7.4 Copy data (rsync)
If current host path is known (example `/var/lib/containers/storage/volumes/pgdata/_data`):
```bash
sudo rsync -aHAX --numeric-ids <OLD_PGDATA_PATH>/ /mnt/data/postgres/data/
```

### 7.5 Update container definition to use new path
**If you use systemd services**: edit the unit so it mounts:
- `-v /mnt/data/postgres/data:/var/lib/postgresql/data`

**If you start manually** (temporary):
```bash
sudo podman run -d \
  --name postgres \
  -p 5432:5432 \
  -v /mnt/data/postgres/data:/var/lib/postgresql/data \
  --restart=always \
  postgres:16
```

### 7.6 Start and verify
```bash
sudo podman start postgres
sudo podman logs --tail 50 postgres
```

Verify connectivity from your workstation:
- psql connect
- or app test
- or check that your Neo4j/Qdrant clients remain unaffected

---

## 8) Cutover Procedure: Neo4j (Second)

### 8.1 Stop Neo4j
```bash
sudo podman stop neo4j
```

### 8.2 Create directories
```bash
sudo mkdir -p /mnt/data/neo4j/data
sudo mkdir -p /mnt/data/neo4j/logs
```

### 8.3 Copy data
Find old mounts:
```bash
sudo podman inspect neo4j --format '{{range .Mounts}}{{println .Source .Destination}}{{end}}'
```

Copy:
```bash
sudo rsync -aHAX --numeric-ids <OLD_NEO4J_DATA_PATH>/ /mnt/data/neo4j/data/
sudo rsync -aHAX --numeric-ids <OLD_NEO4J_LOGS_PATH>/ /mnt/data/neo4j/logs/
```

### 8.4 Update container definition
Use:
- `-v /mnt/data/neo4j/data:/data`
- `-v /mnt/data/neo4j/logs:/logs`

Start:
```bash
sudo podman start neo4j
sudo podman logs --tail 80 neo4j
```

Verify:
- Neo4j browser loads
- `:sysinfo` works
- key node counts match expectation

---

## 9) Cutover Procedure: Qdrant (Third)

### 9.1 Stop Qdrant
```bash
sudo podman stop qdrant
```

### 9.2 Create storage directory
```bash
sudo mkdir -p /mnt/data/qdrant/storage
```

### 9.3 Copy existing storage
```bash
sudo podman inspect qdrant --format '{{range .Mounts}}{{println .Source .Destination}}{{end}}'
sudo rsync -aHAX --numeric-ids <OLD_QDRANT_STORAGE_PATH>/ /mnt/data/qdrant/storage/
```

### 9.4 Update container definition
Use:
- `-v /mnt/data/qdrant/storage:/qdrant/storage`

Start:
```bash
sudo podman start qdrant
sudo podman logs --tail 80 qdrant
```

Verify:
- Qdrant API responds
- collections exist

---

## 10) Verification Checklist (Must Pass)

Inside VM 200:
- `mount | grep virtiofs` shows all 3 mounts
- `ls -la /mnt/data/postgres/data` contains PG files
- `ls -la /mnt/data/neo4j/data` contains Neo4j store files
- `ls -la /mnt/data/qdrant/storage` contains Qdrant state
- `podman ps` shows all 3 containers “Up”
- Service ports respond:
  - Postgres 5432
  - Neo4j 7474/7687
  - Qdrant (as configured)

On pve-2 host:
- `zfs list` shows datasets with non-trivial used space
- Optional: take a VM snapshot labeled `post-externalize`

---

## 11) Rollback Plan (If Something Goes Wrong)

You have two rollback layers:

### 11.1 Fast rollback (snapshot)
- Revert VM 200 to snapshot in Proxmox UI.
- This restores VM OS/config, but **does not automatically revert external ZFS data**.
- Therefore: treat snapshots as “VM state rollback,” not “data rollback.”

### 11.2 Conservative rollback (keep old data)
Because we do not delete old data paths immediately:
- stop service
- repoint container mount back to old path
- restart service

Only delete old paths after:
- stable operation
- PBS backup completed
- at least 48 hours of confidence

---

## 12) Post-Cutover: Make It Reproducible (Template)
Once stabilized:
1) Move your systemd mount units + container unit files into Ignition.
2) Update the CoreOS golden template to include:
   - standard directories
   - mount units
   - container units
   - env file structure

---

## 13) Next: Prepare for Prod Migration
After dev externalization is complete, you can:
- build `prod-db` CoreOS VM on pve-1
- externalize prod data similarly on `prod-zfs/*`
- migrate Neo4j via `neo4j-admin dump/load` (recommended)

---

*End of v1.2 runbook*
