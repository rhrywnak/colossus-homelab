#!/usr/bin/env bash
# =============================================================================
# 02-setup-prod-directory-mappings.sh — Create Proxmox directory mappings
# =============================================================================
# Run on: pve-1 (Proxmox host)
#
# Creates cluster-level directory resource mappings for PROD:
#   prod-db-postgres → /prod-zfs/postgres on pve-1
#   prod-db-neo4j    → /prod-zfs/neo4j    on pve-1
#   prod-db-qdrant   → /prod-zfs/qdrant   on pve-1
#
# These use separate IDs from DEV (db-postgres, etc.) to avoid conflicts.
# The Butane config references these dirids in its virtiofs mount units.
# =============================================================================
set -euo pipefail

NODE="${NODE:-pve-1}"
BASE_MP="${BASE_MP:-/prod-zfs}"

declare -A MAPPINGS=(
    [prod-db-postgres]="${BASE_MP}/postgres"
    [prod-db-neo4j]="${BASE_MP}/neo4j"
    [prod-db-qdrant]="${BASE_MP}/qdrant"
)

echo "== Pre-flight: verify paths exist on disk =="
for dirid in "${!MAPPINGS[@]}"; do
    path="${MAPPINGS[$dirid]}"
    if [[ -d "$path" ]]; then
        echo "  OK: $path exists"
    else
        echo "  ERROR: $path does not exist. Run 01-create-prod-zfs.sh first."
        exit 1
    fi
done

echo ""
echo "== Creating Proxmox directory mappings =="
for dirid in "${!MAPPINGS[@]}"; do
    path="${MAPPINGS[$dirid]}"

    if pvesh get "/cluster/mapping/dir/${dirid}" > /dev/null 2>&1; then
        echo "  EXISTS: ${dirid} (already mapped)"
    else
        echo "  CREATE: ${dirid} → ${NODE}:${path}"
        pvesh create /cluster/mapping/dir \
            --id "${dirid}" \
            --map "node=${NODE},path=${path}"
    fi
done

echo ""
echo "== Verify mappings =="
for dirid in "${!MAPPINGS[@]}"; do
    pvesh get "/cluster/mapping/dir/${dirid}" 2>/dev/null && echo "" || echo "  WARNING: ${dirid} not found"
done

echo ""
echo "Directory mappings ready. Proceed to 03-create-vm-110.sh"
