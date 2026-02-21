#!/usr/bin/env bash
# =============================================================================
# 06-restore-qdrant.sh — Restore Qdrant collection from snapshot into VM-210
# =============================================================================
# Run on: your workstation (Linux desktop) or VM-210
#
# Prerequisites:
#   - VM-210 is running
#   - colossus-qdrant container is up and responding on port 6333
#   - Snapshot file exists locally
#
# The restore process:
#   1. Verify Qdrant API is responding
#   2. Upload snapshot to recreate the collection
#
# Usage:
#   bash 06-restore-qdrant.sh <snapshot-file> <collection-name> <vm210-ip>
#
# Example:
#   bash 06-restore-qdrant.sh \
#     ./paper_chunks-8293711371686424-2026-02-06-18-05-12.snapshot \
#     paper_chunks \
#     192.168.1.xxx
# =============================================================================
set -euo pipefail

SNAPSHOT_FILE="${1:-}"
COLLECTION="${2:-}"
VM210_IP="${3:-}"

if [[ -z "$SNAPSHOT_FILE" || -z "$COLLECTION" || -z "$VM210_IP" ]]; then
    echo "Usage: $0 <snapshot-file> <collection-name> <vm210-ip>" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $0 ./paper_chunks-8293711371686424-2026-02-06-18-05-12.snapshot paper_chunks 192.168.1.100" >&2
    exit 1
fi

if [[ ! -f "$SNAPSHOT_FILE" ]]; then
    echo "ERROR: Snapshot file not found: $SNAPSHOT_FILE" >&2
    exit 1
fi

SNAP_SIZE=$(du -h "$SNAPSHOT_FILE" | cut -f1)
QDRANT_URL="http://${VM210_IP}:6333"

echo "== Qdrant Restore =="
echo "  Snapshot:   $SNAPSHOT_FILE ($SNAP_SIZE)"
echo "  Collection: $COLLECTION"
echo "  Target:     $QDRANT_URL"
echo ""

# --- Verify Qdrant is responding ----------------------------------------------
echo "== Verifying Qdrant API =="
QDRANT_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "${QDRANT_URL}/healthz" || echo "000")
if [[ "$QDRANT_HEALTH" == "200" ]]; then
    echo "  Qdrant is healthy."
else
    echo "  ERROR: Qdrant not responding (HTTP $QDRANT_HEALTH)." >&2
    echo "  Check: ssh core@${VM210_IP} 'sudo podman ps; sudo podman logs colossus-qdrant'" >&2
    exit 1
fi

# --- Check if collection already exists ---------------------------------------
echo ""
echo "== Checking for existing collection =="
EXISTING=$(curl -s "${QDRANT_URL}/collections/${COLLECTION}" | grep -c '"status":"ok"' || true)
if [[ "$EXISTING" -gt 0 ]]; then
    echo "  WARNING: Collection '${COLLECTION}' already exists."
    echo "  The snapshot upload will overwrite it."
    read -p "  Continue? (y/N) " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "  Aborted."
        exit 0
    fi
fi

# --- Upload snapshot ----------------------------------------------------------
echo ""
echo "== Uploading snapshot to restore collection '${COLLECTION}' =="
echo "  This may take a while depending on snapshot size..."

HTTP_CODE=$(curl -s -o /tmp/qdrant_restore_response.json -w "%{http_code}" \
    -X POST \
    -H "Content-Type: multipart/form-data" \
    -F "snapshot=@${SNAPSHOT_FILE}" \
    "${QDRANT_URL}/collections/${COLLECTION}/snapshots/upload?priority=snapshot")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "  Upload successful (HTTP 200)."
    cat /tmp/qdrant_restore_response.json
    echo ""
else
    echo "  ERROR: Upload failed (HTTP $HTTP_CODE)." >&2
    cat /tmp/qdrant_restore_response.json >&2
    echo "" >&2
    exit 1
fi

# --- Verify -------------------------------------------------------------------
echo ""
echo "== Verification: collection info =="
curl -s "${QDRANT_URL}/collections/${COLLECTION}" | python3 -m json.tool 2>/dev/null || \
    curl -s "${QDRANT_URL}/collections/${COLLECTION}"

echo ""
echo "== Verification: point count =="
POINTS=$(curl -s "${QDRANT_URL}/collections/${COLLECTION}" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('points_count','unknown'))" 2>/dev/null || echo "unknown")
echo "  Points in collection: $POINTS"

echo ""
echo "== Qdrant restore complete =="
echo "  Next: Compare point counts against VM-200 for parity validation."
echo "  On VM-200: curl -s http://<vm200-ip>:6333/collections/${COLLECTION}"

# Cleanup
rm -f /tmp/qdrant_restore_response.json
