#!/usr/bin/env bash
# =============================================================================
# 06-restore-qdrant.sh — Restore Qdrant from snapshot via HTTP API
# =============================================================================
# Run on: Workstation (proxima-centauri)
# Target: VM-110 (colossus-prod-db1) at 10.10.100.110
#
# Qdrant restore uploads a snapshot via HTTP. No downtime required.
#
# Usage:
#   bash scripts/06-restore-qdrant.sh <snapshot_file> <collection_name> [vm_ip]
#
# Example:
#   bash scripts/06-restore-qdrant.sh \
#     ~/colossus-db-backup/dev/qdrant/paper_chunks-8293711371686424-2026-02-06-18-05-12.snapshot \
#     paper_chunks \
#     10.10.100.110
# =============================================================================
set -euo pipefail

SNAPSHOT_FILE="${1:?Usage: $0 <snapshot_file> <collection_name> [vm_ip]}"
COLLECTION="${2:?Usage: $0 <snapshot_file> <collection_name> [vm_ip]}"
VM_IP="${3:-10.10.100.110}"
QDRANT_URL="http://${VM_IP}:6333"

if [[ ! -f "$SNAPSHOT_FILE" ]]; then
    echo "ERROR: Snapshot file not found: $SNAPSHOT_FILE" >&2
    exit 1
fi

echo "== Qdrant Restore =="
echo "  Snapshot: $SNAPSHOT_FILE"
echo "  Collection: $COLLECTION"
echo "  Target: ${QDRANT_URL}"
echo ""

# Verify Qdrant is healthy
echo "Checking Qdrant health..."
curl -sf "${QDRANT_URL}/healthz" && echo " OK" || { echo " FAILED"; exit 1; }
echo ""

# Upload snapshot
echo "Uploading snapshot (this may take a moment)..."
HTTP_CODE=$(curl -s -o /tmp/qdrant_restore.json -w "%{http_code}" \
    -X POST \
    -H "Content-Type: multipart/form-data" \
    -F "snapshot=@${SNAPSHOT_FILE}" \
    "${QDRANT_URL}/collections/${COLLECTION}/snapshots/upload?priority=snapshot")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "  Restore successful (HTTP 200)"
else
    echo "  Restore FAILED (HTTP $HTTP_CODE)"
    cat /tmp/qdrant_restore.json
    rm -f /tmp/qdrant_restore.json
    exit 1
fi
rm -f /tmp/qdrant_restore.json

# Verify
echo ""
echo "== Verification =="
echo "Collections:"
curl -s "${QDRANT_URL}/collections" | python3 -m json.tool 2>/dev/null || \
    curl -s "${QDRANT_URL}/collections"

echo ""
echo "Point count:"
POINTS=$(curl -s "${QDRANT_URL}/collections/${COLLECTION}" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['result']['points_count'])" 2>/dev/null || echo "unknown")
echo "  ${COLLECTION}: ${POINTS} points"

echo ""
echo "Qdrant restore complete."
