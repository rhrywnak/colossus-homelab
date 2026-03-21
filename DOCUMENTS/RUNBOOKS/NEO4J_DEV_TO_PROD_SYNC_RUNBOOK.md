# Neo4j Dev → Prod Database Sync Runbook

**Version:** v1.0  
**Date:** 2026-02-17  
**Scope:** Sync Neo4j database from VM-210 (Dev) to VM-110 (Prod)  
**Direction:** DEV → PROD (make Prod identical to Dev)  
**Estimated Downtime:** ~5 minutes per VM (Neo4j offline operations)

---

## 0. Overview

This runbook synchronizes the Neo4j graph database from the Dev environment (VM-210, `colossus-dev-db1`) to the Prod environment (VM-110, `colossus-prod-db1`). This is a **full database replacement** — all data in Prod Neo4j will be overwritten with the Dev copy.

### Why a Full Dump/Load?

Neo4j Community Edition does not support online (hot) backups or incremental replication. The only supported method is `neo4j-admin database dump` (export) and `neo4j-admin database load` (import), both of which require the Neo4j service to be **stopped**. This is an offline operation by design.

### What Gets Synced

The dump captures the **entire `neo4j` database**: all nodes, relationships, properties, indexes, and constraints. It does **not** include authentication configuration — Prod's Neo4j password will remain unchanged after the load.

### What Does NOT Get Synced

- Neo4j authentication/passwords (stored separately from the database)
- Container configuration (Quadlet files, systemd units)
- Environment files (`backend.env` on the app VMs)

---

## 1. Architecture Reference

Both VMs follow the same CoreOS + virtiofs + Podman Quadlet architecture:

```
pve-1 (Prod host)                          pve-2 (Dev host)
├── prod-zfs/neo4j (ZFS dataset)           ├── dev-zfs/neo4j (ZFS dataset)
│   └── virtiofs mount ──────────┐         │   └── virtiofs mount ──────────┐
│                                ▼         │                                ▼
└── VM-110 (colossus-prod-db1)             └── VM-210 (colossus-dev-db1)
    IP: 10.10.100.110                          IP: 10.10.100.200
    Mount: /var/mnt/data/neo4j                 Mount: /var/mnt/data/neo4j
    Service: colossus-neo4j.service            Service: colossus-neo4j.service
    Image: docker.io/library/neo4j:5           Image: docker.io/library/neo4j:5
```

Key architectural points:

- **Data lives outside the VM.** The Neo4j data directory (`/var/mnt/data/neo4j` inside the VM) is actually a virtiofs mount pointing to a ZFS dataset on the Proxmox host. The VM's root filesystem contains no persistent data.
- **SELinux is enforcing.** CoreOS runs SELinux in enforcing mode. The virtiofs mounts use `context="system_u:object_r:container_file_t:s0"` in their systemd mount units to allow container access.
- **One-shot admin containers need `--security-opt label=disable`.** Since virtiofs doesn't support the xattr operations needed for `:Z` volume relabeling, we disable SELinux label checking entirely for the short-lived `neo4j-admin` containers. This is safe because these containers run for seconds, perform a single operation, and exit.

---

## 2. Prerequisites

All commands in this runbook are executed from your workstation (`proxima-centauri`, 10.10.0.99) via SSH. You need:

- SSH key access to both VMs as `core` user
- The Neo4j container image (`docker.io/library/neo4j:5`) available on both VMs (it should already be cached from normal operations)
- Sufficient disk space on your workstation for two dump files (~50–200 MB each depending on database size)
- The Prod and Dev Neo4j passwords (stored in `backend.env` on the respective app VMs — VM-120 for Prod, VM-220 for Dev)

### Set Variables

These variables are used throughout the runbook. Set them once at the start of your session:

```bash
# ── Environment Variables (set once) ──────────────────────────────
VM110_IP="10.10.100.110"    # Prod DB VM
VM210_IP="10.10.100.200"    # Dev DB VM
NEO4J_IMAGE="docker.io/library/neo4j:5"
DATE=$(date +%Y-%m-%d)

# Local backup directories
PROD_BACKUP_DIR=~/colossus-db-backup/prod/neo4j
SYNC_DIR=~/colossus-db-backup/sync
mkdir -p "$PROD_BACKUP_DIR" "$SYNC_DIR"
```

---

## 3. Pre-Flight Checks

Before starting the sync, verify both environments are healthy. This establishes a baseline and confirms connectivity.

### 3.1 Verify Both VMs Are Reachable

```bash
echo "=== Checking VM connectivity ==="
echo -n "Dev (VM-210): "
ssh -o ConnectTimeout=5 core@${VM210_IP} 'hostname' && echo "OK" || echo "FAILED"

echo -n "Prod (VM-110): "
ssh -o ConnectTimeout=5 core@${VM110_IP} 'hostname' && echo "OK" || echo "FAILED"
```

Both should return their respective hostnames. If either fails, check that your SSH config has multiplexing set up (see master context § 19.4) and that the VMs are running in Proxmox.

### 3.2 Verify Neo4j Is Running on Both VMs

```bash
echo "=== Checking Neo4j services ==="
echo "Dev:"
ssh core@${VM210_IP} 'sudo systemctl is-active colossus-neo4j.service'
ssh core@${VM210_IP} 'curl -s http://localhost:7474 | head -1'

echo "Prod:"
ssh core@${VM110_IP} 'sudo systemctl is-active colossus-neo4j.service'
ssh core@${VM110_IP} 'curl -s http://localhost:7474 | head -1'
```

Both should show `active` and return a JSON response from the Neo4j HTTP endpoint (port 7474). The JSON response confirms the database is accepting connections.

### 3.3 Record Current Node Counts (Baseline)

This gives you a "before" snapshot so you can verify the sync was successful.

```bash
echo "=== Dev node counts (SOURCE — what Prod should look like after sync) ==="
curl -s -u neo4j:'YOUR_DEV_PASSWORD' \
  -H 'Content-Type: application/json' \
  -d '{"statements":[{"statement":"MATCH (n) RETURN labels(n) AS label, count(n) AS count ORDER BY count DESC"}]}' \
  http://${VM210_IP}:7474/db/neo4j/tx/commit | python3 -m json.tool

echo ""
echo "=== Prod node counts (TARGET — will be overwritten) ==="
curl -s -u neo4j:'YOUR_PROD_PASSWORD' \
  -H 'Content-Type: application/json' \
  -d '{"statements":[{"statement":"MATCH (n) RETURN labels(n) AS label, count(n) AS count ORDER BY count DESC"}]}' \
  http://${VM110_IP}:7474/db/neo4j/tx/commit | python3 -m json.tool
```

**Important:** Replace `YOUR_DEV_PASSWORD` and `YOUR_PROD_PASSWORD` with the actual passwords. If the passwords contain `$` characters, you **must** use single quotes around them to prevent bash variable expansion. For example: `neo4j:'Pa$$word'`

Write down the Dev node counts — these are what Prod should show after the sync.

---

## 4. Step 1 — Back Up Prod (Safety Net)

**This step is critical.** Before overwriting Prod data, create a backup so you can roll back if anything goes wrong. Never skip this step.

### Why We Stop the Service

`neo4j-admin database dump` requires exclusive access to the data files. If Neo4j is running, it holds locks on the transaction logs and store files. Attempting to dump a live database produces corrupted or incomplete output. This is a Neo4j architectural requirement, not a limitation of our setup.

### How the One-Shot Container Works

We can't run `neo4j-admin` directly on CoreOS because it's an immutable OS — there's no package manager to install Neo4j tools. Instead, we spin up a temporary ("one-shot") container using the same Neo4j image. This container mounts the same data directory, runs the admin command, and exits immediately. The `--rm` flag ensures the container is automatically removed after it finishes.

```bash
echo "=== Step 1: Backing up Prod Neo4j ==="

# Stop the Prod Neo4j service.
# This halts all database operations. Any connected applications (VM-120)
# will lose their database connection until we restart.
ssh core@${VM110_IP} 'sudo systemctl stop colossus-neo4j.service'

# Verify it actually stopped (should print "inactive")
ssh core@${VM110_IP} 'sudo systemctl is-active colossus-neo4j.service || true'

# Run neo4j-admin dump via a one-shot container.
#
# Breaking down the command:
#   --rm                          Remove container after exit
#   --security-opt label=disable  Disable SELinux label checking (required for virtiofs)
#   -v /var/mnt/data/neo4j:/data  Mount the host's Neo4j data directory into the container
#   neo4j-admin database dump     The actual dump command
#   neo4j                         The database name (default database)
#   --to-path=/data               Write the dump file into the data directory
#
ssh core@${VM110_IP} "sudo podman run --rm \
    --security-opt label=disable \
    -v /var/mnt/data/neo4j:/data \
    ${NEO4J_IMAGE} \
    neo4j-admin database dump neo4j --to-path=/data"

# The dump command creates a file called "neo4j.dump" in the data directory.
# Copy it to your workstation for safekeeping.
scp core@${VM110_IP}:/var/mnt/data/neo4j/neo4j.dump \
    "${PROD_BACKUP_DIR}/neo4j_pre-sync_${DATE}.dump"

# Clean up the dump file from the VM's data directory.
# neo4j-admin writes the dump into /data (the ZFS dataset), and if we
# leave it there, it wastes ZFS space and could confuse future operations.
ssh core@${VM110_IP} 'sudo rm -f /var/mnt/data/neo4j/neo4j.dump'

# Restart Prod Neo4j so it's available while we dump Dev.
# Applications on VM-120 will reconnect automatically.
ssh core@${VM110_IP} 'sudo systemctl start colossus-neo4j.service'

# Verify the backup file arrived
echo "Prod backup saved:"
ls -lh "${PROD_BACKUP_DIR}/neo4j_pre-sync_${DATE}.dump"
```

**Expected output:** A dump file in `~/colossus-db-backup/prod/neo4j/`. File size depends on your data — for the initial 207-node Colossus-Legal database, expect roughly 1–5 MB.

---

## 5. Step 2 — Dump Dev (The Source Data)

Now we export the Dev database — this is the data that will replace Prod.

```bash
echo "=== Step 2: Dumping Dev Neo4j ==="

# Stop the Dev Neo4j service
ssh core@${VM210_IP} 'sudo systemctl stop colossus-neo4j.service'

# Verify it stopped
ssh core@${VM210_IP} 'sudo systemctl is-active colossus-neo4j.service || true'

# Dump the Dev database using a one-shot container
# (identical pattern to the Prod backup above)
ssh core@${VM210_IP} "sudo podman run --rm \
    --security-opt label=disable \
    -v /var/mnt/data/neo4j:/data \
    ${NEO4J_IMAGE} \
    neo4j-admin database dump neo4j --to-path=/data"

# Copy the dump to a dedicated sync directory on your workstation.
# We keep this separate from the regular backup directory for clarity.
scp core@${VM210_IP}:/var/mnt/data/neo4j/neo4j.dump \
    "${SYNC_DIR}/neo4j_dev_${DATE}.dump"

# Clean up the dump file from the Dev data directory
ssh core@${VM210_IP} 'sudo rm -f /var/mnt/data/neo4j/neo4j.dump'

# Restart Dev Neo4j
ssh core@${VM210_IP} 'sudo systemctl start colossus-neo4j.service'

# Verify the dump file arrived
echo "Dev dump saved:"
ls -lh "${SYNC_DIR}/neo4j_dev_${DATE}.dump"
```

**At this point:** Both VMs are back up and running normally. You have two files on your workstation:

| File | Purpose |
|------|---------|
| `~/colossus-db-backup/prod/neo4j/neo4j_pre-sync_YYYY-MM-DD.dump` | Prod safety backup (for rollback) |
| `~/colossus-db-backup/sync/neo4j_dev_YYYY-MM-DD.dump` | Dev data (will be loaded into Prod) |

---

## 6. Step 3 — Load Dev Data into Prod (DESTRUCTIVE)

**⚠️ This step overwrites all data in the Prod Neo4j database. ⚠️**

The `--overwrite-destination=true` flag tells `neo4j-admin` to replace the existing database entirely. After this command, Prod will contain an exact copy of the Dev database.

### How the Load Works Internally

`neo4j-admin database load` does the following:

1. Removes the existing database store files from the data directory
2. Extracts the dump archive into the data directory
3. Rebuilds internal metadata so Neo4j recognizes the database on next startup

This is why the service must be stopped — we're replacing files that Neo4j would otherwise have locked.

```bash
echo "=== Step 3: Loading Dev data into Prod (DESTRUCTIVE) ==="

# Stop Prod Neo4j — this is the last time we stop it before the overwrite
ssh core@${VM110_IP} 'sudo systemctl stop colossus-neo4j.service'

# Verify it stopped
ssh core@${VM110_IP} 'sudo systemctl is-active colossus-neo4j.service || true'

# Copy the Dev dump file to the Prod VM.
# We SCP to /tmp first (which core user can write to), then sudo mv it
# into the data directory (which is owned by the neo4j container UID 7474).
scp "${SYNC_DIR}/neo4j_dev_${DATE}.dump" core@${VM110_IP}:/tmp/neo4j.dump
ssh core@${VM110_IP} 'sudo mv /tmp/neo4j.dump /var/mnt/data/neo4j/neo4j.dump'

# Load the Dev dump into Prod's database.
#
# Key flags:
#   --from-path=/data               Read the dump from the data directory
#   --overwrite-destination=true     Replace existing database (DESTRUCTIVE)
#
# Without --overwrite-destination, neo4j-admin will refuse to load if the
# database already exists, which it does in our case.
#
ssh core@${VM110_IP} "sudo podman run --rm \
    --security-opt label=disable \
    -v /var/mnt/data/neo4j:/data \
    ${NEO4J_IMAGE} \
    neo4j-admin database load neo4j \
        --from-path=/data \
        --overwrite-destination=true"

# Clean up the dump file from Prod's data directory
ssh core@${VM110_IP} 'sudo rm -f /var/mnt/data/neo4j/neo4j.dump'

# Restart Prod Neo4j with the new data
ssh core@${VM110_IP} 'sudo systemctl start colossus-neo4j.service'

echo "Load complete. Waiting 15s for Neo4j to initialize..."
sleep 15
```

**Why 15 seconds?** Neo4j takes a few seconds on startup to read the store files, rebuild caches, and begin accepting connections. 15 seconds is a conservative wait. If your database is large, you may need to increase this.

---

## 7. Step 4 — Validate the Sync

Validation confirms that Prod now contains the same data as Dev.

### 7.1 Basic Health Check

```bash
echo "=== Validating Prod Neo4j is responding ==="
ssh core@${VM110_IP} 'curl -s http://localhost:7474'
```

This should return a JSON response with Neo4j version info. If it times out or returns an error, Neo4j may still be starting up — wait another 15 seconds and try again.

### 7.2 Node Count Comparison

Compare the Prod node counts to the Dev counts you recorded in the pre-flight check (Section 3.3):

```bash
echo "=== Prod node counts (should match Dev from pre-flight) ==="
curl -s -u neo4j:'YOUR_PROD_PASSWORD' \
  -H 'Content-Type: application/json' \
  -d '{"statements":[{"statement":"MATCH (n) RETURN labels(n) AS label, count(n) AS count ORDER BY count DESC"}]}' \
  http://${VM110_IP}:7474/db/neo4j/tx/commit | python3 -m json.tool
```

The label counts should exactly match what Dev reported in Section 3.3.

### 7.3 Verify Dev Is Still Healthy

Confirm Dev wasn't affected by the process:

```bash
echo "=== Dev node counts (should be unchanged) ==="
curl -s -u neo4j:'YOUR_DEV_PASSWORD' \
  -H 'Content-Type: application/json' \
  -d '{"statements":[{"statement":"MATCH (n) RETURN labels(n) AS label, count(n) AS count ORDER BY count DESC"}]}' \
  http://${VM210_IP}:7474/db/neo4j/tx/commit | python3 -m json.tool
```

### 7.4 Application-Level Validation (Optional but Recommended)

If the Colossus-Legal application is deployed, verify it can read from the updated Prod database:

```bash
# Check the PROD backend health endpoint
curl -sf http://${VM110_IP}:3403/health && echo "Backend: OK"

# Check the case endpoint returns data
curl -sf http://${VM110_IP}:3403/case | python3 -m json.tool | head -5

# Check total node count via the app's schema endpoint
curl -sf http://${VM110_IP}:3403/schema | python3 -c "
import sys, json
data = json.load(sys.stdin)
total = sum(nt['count'] for nt in data.get('node_types', []))
print(f'Total nodes via app: {total}')
"
```

**Note:** The backend health/case/schema endpoints are on the app VM (VM-120, 10.10.100.120), not the DB VM (VM-110). Adjust the IP if your backend connects to the DB VM's IP directly.

---

## 8. Rollback Procedure

If something went wrong and you need to restore Prod to its pre-sync state:

```bash
# ── ROLLBACK: Restore Prod from pre-sync backup ──────────────────

# Stop Prod Neo4j
ssh core@${VM110_IP} 'sudo systemctl stop colossus-neo4j.service'

# Copy the pre-sync backup to Prod
scp "${PROD_BACKUP_DIR}/neo4j_pre-sync_${DATE}.dump" core@${VM110_IP}:/tmp/neo4j.dump
ssh core@${VM110_IP} 'sudo mv /tmp/neo4j.dump /var/mnt/data/neo4j/neo4j.dump'

# Load the pre-sync backup
ssh core@${VM110_IP} "sudo podman run --rm \
    --security-opt label=disable \
    -v /var/mnt/data/neo4j:/data \
    ${NEO4J_IMAGE} \
    neo4j-admin database load neo4j \
        --from-path=/data \
        --overwrite-destination=true"

# Clean up and restart
ssh core@${VM110_IP} 'sudo rm -f /var/mnt/data/neo4j/neo4j.dump'
ssh core@${VM110_IP} 'sudo systemctl start colossus-neo4j.service'

echo "Rollback complete. Waiting 15s..."
sleep 15
ssh core@${VM110_IP} 'curl -s http://localhost:7474'
```

---

## 9. Sync Checklist

Use this checklist each time you perform a Dev → Prod sync:

- [ ] Pre-flight: Both VMs reachable via SSH
- [ ] Pre-flight: Both Neo4j instances responding on port 7474
- [ ] Pre-flight: Dev node counts recorded (baseline)
- [ ] Pre-flight: Prod node counts recorded (for comparison)
- [ ] Step 1: Prod backup created and saved to workstation
- [ ] Step 2: Dev dump created and saved to workstation
- [ ] Step 3: Dev dump loaded into Prod with `--overwrite-destination=true`
- [ ] Step 4: Prod node counts match Dev baseline
- [ ] Step 4: Dev node counts unchanged
- [ ] Step 4: Application-level validation passed (if applicable)
- [ ] Cleanup: No stale `.dump` files on either VM's data directory

---

## 10. Known Issues & Gotchas

1. **Passwords with `$` characters.** Both the Dev and Prod Neo4j passwords may contain `$`. Always wrap them in single quotes in bash commands, or the shell will try to expand them as variables. Double quotes will NOT protect against this.

2. **Authentication survives the sync.** The dump/load transfers data only, not auth configuration. Prod's Neo4j password remains whatever it was before the sync. You do not need to change `backend.env` on VM-120 after syncing.

3. **SELinux + virtiofs = no `:Z` flags.** Never use `:z` or `:Z` on the `-v` mount for the one-shot container. virtiofs doesn't support the xattr operations needed for SELinux relabeling. Always use `--security-opt label=disable` instead.

4. **Dump file lands in the data directory.** `neo4j-admin database dump --to-path=/data` writes `neo4j.dump` into the same ZFS dataset that holds the live database. Always remove it after copying to your workstation, or it wastes ZFS space.

5. **Container image must match.** The Neo4j image version used for dump/load should match (or be compatible with) the version that normally runs the database. Using `neo4j:5` for both ensures compatibility. Do not mix Neo4j 4.x and 5.x dump formats.

6. **Total downtime per VM.** Each VM's Neo4j is offline for roughly 1–3 minutes (time to stop, dump/load, restart). The operations themselves are fast for databases under 1 GB. Plan accordingly if users are actively using the Prod application.

---

## 11. References

| Document | Section | What It Covers |
|----------|---------|----------------|
| `COLOSSUS_DEV_BACKUP_RESTORE_RUNBOOK_v1.md` | §4.1, §4.2 | Detailed Neo4j backup/restore for VM-210 |
| `DEPLOYMENT.md` | §7.1, §7.2 | High-level sync workflow and checklist |
| `COLOSSUS_HOMELAB_MASTER_CONTEXT_v5.md` | §5.3 | SELinux + virtiofs constraints |
| `COLOSSUS_HOMELAB_MASTER_CONTEXT_v5.md` | §18 | VM/CT inventory with IPs |
