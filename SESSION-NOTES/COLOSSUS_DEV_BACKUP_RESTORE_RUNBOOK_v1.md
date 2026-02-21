# Colossus DEV Database Backup & Restore Runbook

**Version:** v1.0  
**Date:** 2026-02-08  
**Scope:** VM-210 (`colossus-dev-db1`) on pve-2  
**Databases:** PostgreSQL 17, Neo4j 5, Qdrant  

---

## 0. Architecture Summary

```
pve-2 (Proxmox host)
├── dev-zfs/postgres  ──virtiofs──→  VM-210:/var/mnt/data/postgres  → colossus-postgres
├── dev-zfs/neo4j     ──virtiofs──→  VM-210:/var/mnt/data/neo4j     → colossus-neo4j
└── dev-zfs/qdrant    ──virtiofs──→  VM-210:/var/mnt/data/qdrant    → colossus-qdrant
```

- VM-210 IP: `10.10.100.200`
- VM-200 (frozen reference): `10.10.100.50`
- All data lives on ZFS datasets on pve-2 — outside the VM
- Containers are systemd-managed via Podman Quadlet
- virtiofs mounts use SELinux `context="system_u:object_r:container_file_t:s0"`

---

## 1. SELinux Considerations (Critical)

Fedora CoreOS runs SELinux in **enforcing mode**. virtiofs mounts from a
non-SELinux host (Proxmox/Debian) appear as `virtiofs_t`, which containers
cannot access.

### Rules

1. **systemd mount units** use `Options=context="system_u:object_r:container_file_t:s0"` —
   this assigns the correct SELinux label at the VFS level
2. **Quadlet Volume= lines** do NOT use `:z` or `:Z` — the mount-level context
   already handles labeling, and virtiofs lacks the xattr support needed for relabeling
3. **One-shot admin containers** (e.g., neo4j-admin for restore) must use
   `--security-opt label=disable` instead of `:Z` on their volume mounts

Failure to follow these rules results in "Permission denied" errors even when
Unix file permissions are correct.

---

## 2. Backup Locations (Recommended)

On your Linux workstation (`proxima-centauri`):

```
~/colossus-db-backup/dev/
├── postgres/
│   └── postgres_dump_YYYY-MM-DD.sql
├── neo4j/
│   └── neo4j.dump
└── qdrant/
    └── paper_chunks-<id>-YYYY-MM-DD-HH-MM-SS.snapshot
```

Backups should also be verified against PBS (Proxmox Backup Server on pve-3).

---

## 3. PostgreSQL 17

### 3.1 Backup (pg_dumpall)

PostgreSQL backup runs against the **live container** — no downtime required.

**From your workstation:**

```bash
# Variables
VM210_IP="10.10.100.200"
DATE=$(date +%Y-%m-%d)
BACKUP_DIR=~/colossus-db-backup/dev/postgres
DUMP_FILE="${BACKUP_DIR}/postgres_dump_${DATE}.sql"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Run pg_dumpall inside the running container
ssh core@${VM210_IP} \
  'sudo podman exec colossus-postgres pg_dumpall -U postgres' \
  > "$DUMP_FILE"

# Verify
ls -lh "$DUMP_FILE"
head -20 "$DUMP_FILE"
echo "Tables in dump:"
grep -c "CREATE TABLE" "$DUMP_FILE"
```

**Expected output:** A SQL file containing all databases, roles, and table
definitions. The `colossus` database should contain 25 tables.

### 3.2 Restore (psql)

Restore runs against the **live container**. For a fresh restore (e.g., after
VM rebuild), the container auto-initializes an empty database on first start.

**From your workstation:**

```bash
# Variables
VM210_IP="10.10.100.200"
DUMP_FILE=~/colossus-db-backup/dev/postgres/postgres_dump_2026-02-06.sql

# Verify container is running
ssh core@${VM210_IP} \
  'sudo podman ps --filter name=colossus-postgres --format "{{.Names}} {{.Status}}"'

# Copy dump to VM
scp "$DUMP_FILE" core@${VM210_IP}:/tmp/postgres_restore.sql

# Restore
ssh core@${VM210_IP} \
  'sudo podman exec -i colossus-postgres psql -U postgres < /tmp/postgres_restore.sql'

# Verify
ssh core@${VM210_IP} \
  'sudo podman exec colossus-postgres psql -U postgres -c "\l"'
ssh core@${VM210_IP} \
  'sudo podman exec colossus-postgres psql -U postgres -d colossus -c "
    SELECT schemaname, tablename
    FROM pg_tables
    WHERE schemaname NOT IN ('\''pg_catalog'\'', '\''information_schema'\'')
    ORDER BY schemaname, tablename;"'

# Cleanup
ssh core@${VM210_IP} 'rm -f /tmp/postgres_restore.sql'
```

### 3.3 Quick Health Check

```bash
# From workstation — database list
ssh core@${VM210_IP} \
  'sudo podman exec colossus-postgres psql -U postgres -c "\l"'

# Table count in colossus
ssh core@${VM210_IP} \
  'sudo podman exec colossus-postgres psql -U postgres -d colossus -c "
    SELECT count(*) FROM pg_tables
    WHERE schemaname NOT IN ('\''pg_catalog'\'', '\''information_schema'\'');"'
```

---

## 4. Neo4j 5

### 4.1 Backup (neo4j-admin database dump)

Neo4j backup requires the **service to be stopped** — this is an offline operation.

**From your workstation:**

```bash
# Variables
VM210_IP="10.10.100.200"
DATE=$(date +%Y-%m-%d)
BACKUP_DIR=~/colossus-db-backup/dev/neo4j
NEO4J_IMAGE="docker.io/library/neo4j:5"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Stop Neo4j service
ssh core@${VM210_IP} 'sudo systemctl stop colossus-neo4j.service'

# Run neo4j-admin dump via one-shot container
# NOTE: --security-opt label=disable is required because virtiofs
#       does not support SELinux xattr relabeling (:Z would fail)
ssh core@${VM210_IP} "sudo podman run --rm \
    --security-opt label=disable \
    -v /var/mnt/data/neo4j:/data \
    ${NEO4J_IMAGE} \
    neo4j-admin database dump neo4j --to-path=/data"

# Copy dump to workstation
scp core@${VM210_IP}:/var/mnt/data/neo4j/neo4j.dump \
    "${BACKUP_DIR}/neo4j_${DATE}.dump"

# Clean up dump from data directory
ssh core@${VM210_IP} 'sudo rm -f /var/mnt/data/neo4j/neo4j.dump'

# Restart Neo4j
ssh core@${VM210_IP} 'sudo systemctl start colossus-neo4j.service'

# Verify
ls -lh "${BACKUP_DIR}/neo4j_${DATE}.dump"
echo "Waiting 15s for Neo4j startup..."
sleep 15
ssh core@${VM210_IP} 'curl -s http://localhost:7474'
```

### 4.2 Restore (neo4j-admin database load)

Neo4j restore also requires the **service to be stopped**.

**From your workstation:**

```bash
# Variables
VM210_IP="10.10.100.200"
DUMP_FILE=~/colossus-db-backup/dev/neo4j/neo4j.dump
NEO4J_IMAGE="docker.io/library/neo4j:5"

# Stop Neo4j service
ssh core@${VM210_IP} 'sudo systemctl stop colossus-neo4j.service'

# Copy dump to VM
scp "$DUMP_FILE" core@${VM210_IP}:/tmp/neo4j.dump
ssh core@${VM210_IP} 'sudo mv /tmp/neo4j.dump /var/mnt/data/neo4j/neo4j.dump'

# Run neo4j-admin load via one-shot container
# NOTE: --security-opt label=disable is required (not :Z)
ssh core@${VM210_IP} "sudo podman run --rm \
    --security-opt label=disable \
    -v /var/mnt/data/neo4j:/data \
    ${NEO4J_IMAGE} \
    neo4j-admin database load neo4j \
        --from-path=/data \
        --overwrite-destination=true"

# Clean up dump file
ssh core@${VM210_IP} 'sudo rm -f /var/mnt/data/neo4j/neo4j.dump'

# Restart Neo4j
ssh core@${VM210_IP} 'sudo systemctl start colossus-neo4j.service'

# Verify
echo "Waiting 15s for Neo4j startup..."
sleep 15
ssh core@${VM210_IP} 'curl -s http://localhost:7474'
```

### 4.3 Quick Health Check

```bash
# HTTP endpoint
ssh core@${VM210_IP} 'curl -s http://localhost:7474'

# Node count (requires auth — use single quotes around password with $ characters)
curl -s -u neo4j:'YOUR_PASSWORD' \
  -H 'Content-Type: application/json' \
  -d '{"statements":[{"statement":"MATCH (n) RETURN count(n) AS total"}]}' \
  http://${VM210_IP}:7474/db/neo4j/tx/commit

# Node count by label
curl -s -u neo4j:'YOUR_PASSWORD' \
  -H 'Content-Type: application/json' \
  -d '{"statements":[{"statement":"MATCH (n) RETURN labels(n) AS label, count(n) AS count ORDER BY count DESC"}]}' \
  http://${VM210_IP}:7474/db/neo4j/tx/commit
```

**Note:** If your Neo4j password contains `$` characters, always wrap it in
single quotes to prevent bash variable expansion.

---

## 5. Qdrant

### 5.1 Backup (Snapshot via HTTP API)

Qdrant backup is performed via the **HTTP API** against a running instance.
No downtime required.

**From your workstation:**

```bash
# Variables
VM210_IP="10.10.100.200"
COLLECTION="paper_chunks"
BACKUP_DIR=~/colossus-db-backup/dev/qdrant
QDRANT_URL="http://${VM210_IP}:6333"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Create snapshot
echo "Creating snapshot..."
SNAPSHOT_RESPONSE=$(curl -s -X POST \
    "${QDRANT_URL}/collections/${COLLECTION}/snapshots")
echo "$SNAPSHOT_RESPONSE"

# Extract snapshot filename
SNAPSHOT_NAME=$(echo "$SNAPSHOT_RESPONSE" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['result']['name'])")
echo "Snapshot name: $SNAPSHOT_NAME"

# Download snapshot
echo "Downloading snapshot..."
curl -o "${BACKUP_DIR}/${SNAPSHOT_NAME}" \
    "${QDRANT_URL}/collections/${COLLECTION}/snapshots/${SNAPSHOT_NAME}"

# Verify
ls -lh "${BACKUP_DIR}/${SNAPSHOT_NAME}"

# Check point count for reference
POINTS=$(curl -s "${QDRANT_URL}/collections/${COLLECTION}" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['result']['points_count'])")
echo "Points in collection: $POINTS"
```

### 5.2 Restore (Snapshot Upload via HTTP API)

Qdrant restore uploads a snapshot via the HTTP API to a **running** instance.
No downtime required — the upload recreates or overwrites the collection.

**From your workstation:**

```bash
# Variables
VM210_IP="10.10.100.200"
COLLECTION="paper_chunks"
SNAPSHOT_FILE=~/colossus-db-backup/dev/qdrant/paper_chunks-8293711371686424-2026-02-06-18-05-12.snapshot
QDRANT_URL="http://${VM210_IP}:6333"

# Verify Qdrant is healthy
curl -s "${QDRANT_URL}/healthz"
echo ""

# Upload snapshot to restore collection
echo "Uploading snapshot..."
HTTP_CODE=$(curl -s -o /tmp/qdrant_restore.json -w "%{http_code}" \
    -X POST \
    -H "Content-Type: multipart/form-data" \
    -F "snapshot=@${SNAPSHOT_FILE}" \
    "${QDRANT_URL}/collections/${COLLECTION}/snapshots/upload?priority=snapshot")

if [ "$HTTP_CODE" = "200" ]; then
    echo "Restore successful (HTTP 200)"
else
    echo "Restore FAILED (HTTP $HTTP_CODE)"
    cat /tmp/qdrant_restore.json
fi

# Verify point count
POINTS=$(curl -s "${QDRANT_URL}/collections/${COLLECTION}" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['result']['points_count'])")
echo "Points in collection: $POINTS"

# Cleanup
rm -f /tmp/qdrant_restore.json
```

### 5.3 Quick Health Check

```bash
# Health
curl -s http://${VM210_IP}:6333/healthz

# List collections
curl -s http://${VM210_IP}:6333/collections | python3 -m json.tool

# Point count for a collection
curl -s http://${VM210_IP}:6333/collections/paper_chunks | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('Points:', d['result']['points_count'])"
```

---

## 6. Full Backup (All Three)

Run all backups sequentially. Only Neo4j requires brief downtime.

```bash
#!/usr/bin/env bash
# full-backup-dev.sh — Backup all DEV databases from VM-210
set -euo pipefail

VM210_IP="10.10.100.200"
DATE=$(date +%Y-%m-%d)
BASE_DIR=~/colossus-db-backup/dev
NEO4J_IMAGE="docker.io/library/neo4j:5"

echo "============================================"
echo " Colossus DEV Full Backup — ${DATE}"
echo " Target: VM-210 (${VM210_IP})"
echo "============================================"

# --- PostgreSQL (online) ---
echo ""
echo "== PostgreSQL =="
mkdir -p "${BASE_DIR}/postgres"
PG_DUMP="${BASE_DIR}/postgres/postgres_dump_${DATE}.sql"
ssh core@${VM210_IP} \
    'sudo podman exec colossus-postgres pg_dumpall -U postgres' > "$PG_DUMP"
PG_SIZE=$(du -h "$PG_DUMP" | cut -f1)
PG_TABLES=$(grep -c "CREATE TABLE" "$PG_DUMP" || echo "0")
echo "  File: $PG_DUMP ($PG_SIZE)"
echo "  Tables: $PG_TABLES"

# --- Neo4j (offline — brief downtime) ---
echo ""
echo "== Neo4j =="
mkdir -p "${BASE_DIR}/neo4j"
NEO4J_DUMP="${BASE_DIR}/neo4j/neo4j_${DATE}.dump"
ssh core@${VM210_IP} 'sudo systemctl stop colossus-neo4j.service'
ssh core@${VM210_IP} "sudo podman run --rm \
    --security-opt label=disable \
    -v /var/mnt/data/neo4j:/data \
    ${NEO4J_IMAGE} \
    neo4j-admin database dump neo4j --to-path=/data"
scp core@${VM210_IP}:/var/mnt/data/neo4j/neo4j.dump "$NEO4J_DUMP"
ssh core@${VM210_IP} 'sudo rm -f /var/mnt/data/neo4j/neo4j.dump'
ssh core@${VM210_IP} 'sudo systemctl start colossus-neo4j.service'
NEO4J_SIZE=$(du -h "$NEO4J_DUMP" | cut -f1)
echo "  File: $NEO4J_DUMP ($NEO4J_SIZE)"

# --- Qdrant (online) ---
echo ""
echo "== Qdrant =="
mkdir -p "${BASE_DIR}/qdrant"
COLLECTION="paper_chunks"
QDRANT_URL="http://${VM210_IP}:6333"
SNAP_RESPONSE=$(curl -s -X POST "${QDRANT_URL}/collections/${COLLECTION}/snapshots")
SNAP_NAME=$(echo "$SNAP_RESPONSE" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['result']['name'])")
curl -s -o "${BASE_DIR}/qdrant/${SNAP_NAME}" \
    "${QDRANT_URL}/collections/${COLLECTION}/snapshots/${SNAP_NAME}"
QDRANT_SIZE=$(du -h "${BASE_DIR}/qdrant/${SNAP_NAME}" | cut -f1)
POINTS=$(curl -s "${QDRANT_URL}/collections/${COLLECTION}" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['result']['points_count'])")
echo "  File: ${BASE_DIR}/qdrant/${SNAP_NAME} ($QDRANT_SIZE)"
echo "  Points: $POINTS"

# --- Summary ---
echo ""
echo "============================================"
echo " Backup complete"
echo "  PostgreSQL: $PG_DUMP ($PG_SIZE, $PG_TABLES tables)"
echo "  Neo4j:      $NEO4J_DUMP ($NEO4J_SIZE)"
echo "  Qdrant:     ${SNAP_NAME} ($QDRANT_SIZE, $POINTS points)"
echo "============================================"
```

---

## 7. Full Restore After VM Rebuild

After destroying and recreating VM-210 from Ignition, all three databases
need to be restored. Containers auto-start with empty data.

**Order:** PostgreSQL → Neo4j → Qdrant (Neo4j requires service stop; others don't)

Run the individual restore procedures from Sections 3.2, 4.2, and 5.2 in sequence.

---

## 8. Disaster Recovery Paths

| Scenario | Recovery |
|----------|----------|
| Container crash | systemd auto-restarts; data on ZFS is unaffected |
| VM-210 destroyed | Rebuild from Ignition + restore from backup files |
| ZFS dataset corrupted | Restore ZFS from PBS snapshot on pve-3 |
| pve-2 host failure | Rebuild host, recreate ZFS pool, restore from PBS or backup files |
| All backups lost | VM-200 still exists as frozen reference |

---

## 9. Retention (Recommended)

| Backup Type | Retention |
|-------------|-----------|
| PostgreSQL SQL dumps | Last 7 daily |
| Neo4j dumps | Last 7 daily |
| Qdrant snapshots | Last 7 daily |
| PBS VM backups | daily 14, weekly 8, monthly 12 |

---

## 10. Known Issues & Gotchas

1. **SELinux + virtiofs**: Never use `:z` or `:Z` volume flags with virtiofs mounts.
   Use `--security-opt label=disable` for one-shot admin containers.

2. **Neo4j passwords with `$`**: Always use single quotes in bash to prevent
   variable expansion: `curl -u neo4j:'Pass$word'`

3. **Neo4j dump location**: `neo4j-admin database dump --to-path=/data` writes
   the dump file into the data directory. Always clean it up after copying to
   avoid wasting ZFS space.

4. **Qdrant snapshots accumulate**: Qdrant stores snapshots inside the container's
   storage path. Old snapshots should be cleaned up periodically:
   ```bash
   curl -X DELETE "http://${VM210_IP}:6333/collections/paper_chunks/snapshots/<snapshot_name>"
   ```

5. **VM-200 password differs from VM-210**: The Neo4j password on VM-200 (frozen
   reference) may differ from VM-210. The validation script expects a single
   `NEO4J_PASS` variable — validate manually if passwords differ.
