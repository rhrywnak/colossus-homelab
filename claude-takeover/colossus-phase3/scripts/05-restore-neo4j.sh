#!/usr/bin/env bash
# =============================================================================
# 05-restore-neo4j.sh — Restore Neo4j from dump file
# =============================================================================
# Run on: Workstation (proxima-centauri)
# Target: VM-110 (colossus-prod-db1) at 10.10.100.110
#
# IMPORTANT: This stops the Neo4j service during restore (offline operation).
# Uses --security-opt label=disable (NOT :Z) because virtiofs lacks xattr
# support for SELinux relabeling.
#
# Usage:
#   bash scripts/05-restore-neo4j.sh <dump_file> [vm_ip]
#
# Example:
#   bash scripts/05-restore-neo4j.sh \
#     ~/colossus-db-backup/dev/neo4j/neo4j.dump \
#     10.10.100.110
# =============================================================================
set -euo pipefail

DUMP_FILE="${1:?Usage: $0 <dump_file> [vm_ip]}"
VM_IP="${2:-10.10.100.110}"
NEO4J_IMAGE="docker.io/library/neo4j:5"

if [[ ! -f "$DUMP_FILE" ]]; then
    echo "ERROR: Dump file not found: $DUMP_FILE" >&2
    exit 1
fi

echo "== Neo4j Restore =="
echo "  Dump: $DUMP_FILE"
echo "  Target: core@${VM_IP} (colossus-neo4j)"
echo ""

# Stop Neo4j service
echo "Stopping Neo4j service..."
ssh core@${VM_IP} 'sudo systemctl stop colossus-neo4j.service'
sleep 3

# Copy dump to VM
echo "Copying dump to VM..."
scp "$DUMP_FILE" core@${VM_IP}:/tmp/neo4j.dump
ssh core@${VM_IP} 'sudo mv /tmp/neo4j.dump /var/mnt/data/neo4j/neo4j.dump'

# Restore via one-shot container
# NOTE: --security-opt label=disable is REQUIRED (not :Z)
#       virtiofs does not support SELinux xattr relabeling
echo "Running neo4j-admin database load..."
ssh core@${VM_IP} "sudo podman run --rm \
    --security-opt label=disable \
    -v /var/mnt/data/neo4j:/data \
    ${NEO4J_IMAGE} \
    neo4j-admin database load neo4j \
        --from-path=/data \
        --overwrite-destination=true"

# Clean up dump file from data directory
ssh core@${VM_IP} 'sudo rm -f /var/mnt/data/neo4j/neo4j.dump'

# Restart Neo4j
echo "Starting Neo4j service..."
ssh core@${VM_IP} 'sudo systemctl start colossus-neo4j.service'

# Wait for startup
echo "Waiting 15s for Neo4j startup..."
sleep 15

# Verify
echo ""
echo "== Verification =="
echo "HTTP endpoint:"
ssh core@${VM_IP} 'curl -s http://localhost:7474' || echo "  (may need more time)"

echo ""
echo "Neo4j restore complete."
echo "To verify node counts, use the Neo4j browser or:"
echo "  curl -s -u neo4j:'PASSWORD' -H 'Content-Type: application/json' \\"
echo "    -d '{\"statements\":[{\"statement\":\"MATCH (n) RETURN labels(n) AS label, count(n) AS count ORDER BY count DESC\"}]}' \\"
echo "    http://${VM_IP}:7474/db/neo4j/tx/commit"
