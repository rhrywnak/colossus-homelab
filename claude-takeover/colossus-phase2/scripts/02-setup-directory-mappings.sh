#!/usr/bin/env bash
# =============================================================================
# 02-setup-directory-mappings.sh — Create Proxmox directory mappings for virtiofs
# =============================================================================
# Run on: pve-2 (Proxmox host)
# Purpose: Create cluster-level directory resource mappings that allow VMs
#          to mount host directories via virtiofs.
#
# These mappings connect:
#   dirid "db-postgres" → /dev-zfs/postgres on pve-2
#   dirid "db-neo4j"    → /dev-zfs/neo4j    on pve-2
#   dirid "db-qdrant"   → /dev-zfs/qdrant   on pve-2
#
# The Butane config references these dirids in its virtiofs mount units.
# The VM creation script attaches them via --virtiofs<N> dirid=<name>.
# =============================================================================
set -euo pipefail

NODE="${NODE:-pve-2}"
BASE_MP="${BASE_MP:-/dev-zfs}"

declare -A MAPPINGS=(
    [db-postgres]="${BASE_MP}/postgres"
    [db-neo4j]="${BASE_MP}/neo4j"
    [db-qdrant]="${BASE_MP}/qdrant"
)

echo "== Pre-flight: verify paths exist on disk =="
for dirid in "${!MAPPINGS[@]}"; do
    path="${MAPPINGS[$dirid]}"
    if [[ -d "$path" ]]; then
        echo "  OK: $path exists"
    else
        echo "  ERROR: $path does not exist. Run 01-verify-dev-zfs.sh first."
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
echo "Directory mappings ready. Proceed to 03-create-vm-210.sh"
