#!/usr/bin/env bash
# =============================================================================
# 05-restore-neo4j.sh — Restore Neo4j from dump into VM-210
# =============================================================================
# Run on: your workstation (Linux desktop)
#
# Prerequisites:
#   - VM-210 is running
#   - neo4j.dump file exists locally (from Phase 1 backup)
#   - colossus-neo4j service exists on VM-210
#
# The restore process:
#   1. Stop Neo4j service (must be offline for load)
#   2. Copy dump into the virtiofs-mounted data directory
#   3. Run neo4j-admin database load via a one-shot container
#   4. Restart Neo4j service
#
# Usage:
#   bash 05-restore-neo4j.sh <path-to-dump> <vm210-ip>
#
# Example:
#   bash 05-restore-neo4j.sh ./neo4j.dump 192.168.1.xxx
# =============================================================================
set -euo pipefail

DUMP_FILE="${1:-}"
VM210_IP="${2:-}"
DB_NAME="${DB_NAME:-neo4j}"
NEO4J_IMAGE="docker.io/library/neo4j:5"

if [[ -z "$DUMP_FILE" || -z "$VM210_IP" ]]; then
    echo "Usage: $0 <path-to-neo4j-dump> <vm210-ip>" >&2
    echo "Example: $0 ./neo4j.dump 192.168.1.100" >&2
    exit 1
fi

if [[ ! -f "$DUMP_FILE" ]]; then
    echo "ERROR: Dump file not found: $DUMP_FILE" >&2
    exit 1
fi

DUMP_SIZE=$(du -h "$DUMP_FILE" | cut -f1)
echo "== Neo4j Restore =="
echo "  Dump file: $DUMP_FILE ($DUMP_SIZE)"
echo "  Target:    core@${VM210_IP} → /mnt/data/neo4j"
echo "  Database:  $DB_NAME"
echo ""

# --- Stop Neo4j service -------------------------------------------------------
echo "== Stopping colossus-neo4j service on VM-210 =="
ssh "core@${VM210_IP}" 'sudo systemctl stop colossus-neo4j.service || true'
echo "  Service stopped."

# --- Copy dump file to VM-210 ------------------------------------------------
echo ""
echo "== Copying dump to VM-210:/mnt/data/neo4j/ =="
scp "$DUMP_FILE" "core@${VM210_IP}:/tmp/neo4j.dump"
ssh "core@${VM210_IP}" 'sudo mv /tmp/neo4j.dump /mnt/data/neo4j/neo4j.dump'
echo "  Done."

# --- Run neo4j-admin load via one-shot container -----------------------------
echo ""
echo "== Loading dump into Neo4j data directory =="
echo "  Using: $NEO4J_IMAGE"
echo "  This runs neo4j-admin database load against /mnt/data/neo4j..."
ssh "core@${VM210_IP}" "sudo podman run --rm \
    -v /mnt/data/neo4j:/data:Z \
    ${NEO4J_IMAGE} \
    neo4j-admin database load ${DB_NAME} \
        --from-path=/data \
        --overwrite-destination=true"
echo "  Load complete."

# --- Clean up dump file from data directory -----------------------------------
echo ""
echo "== Cleaning up dump file from data directory =="
ssh "core@${VM210_IP}" 'sudo rm -f /mnt/data/neo4j/neo4j.dump'

# --- Start Neo4j service -----------------------------------------------------
echo ""
echo "== Starting colossus-neo4j service =="
ssh "core@${VM210_IP}" 'sudo systemctl start colossus-neo4j.service'
echo "  Waiting 15 seconds for Neo4j to initialize..."
sleep 15

# --- Verify -------------------------------------------------------------------
echo ""
echo "== Verification: service status =="
ssh "core@${VM210_IP}" 'sudo systemctl status colossus-neo4j.service --no-pager -l' || true

echo ""
echo "== Verification: Neo4j HTTP endpoint =="
ssh "core@${VM210_IP}" 'curl -s http://localhost:7474 || echo "Not responding yet — may need more startup time"'

echo ""
echo "== Verification: node count (requires auth) =="
echo "  Run this manually on VM-210 or from your workstation:"
echo "    curl -u neo4j:<password> -H 'Content-Type: application/json' \\"
echo "      -d '{\"statements\":[{\"statement\":\"MATCH (n) RETURN count(n) AS total\"}]}' \\"
echo "      http://<vm210-ip>:7474/db/neo4j/tx/commit"

echo ""
echo "== Neo4j restore complete =="
echo "  Next: Compare node/relationship counts against VM-200."
