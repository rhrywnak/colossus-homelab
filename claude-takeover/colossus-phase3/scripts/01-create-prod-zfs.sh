#!/usr/bin/env bash
# =============================================================================
# 01-create-prod-zfs.sh — Create ZFS pool and datasets on pve-1
# =============================================================================
# Run on: pve-1 (Proxmox host)
#
# This script creates the prod-zfs pool on the Crucial T500 2TB NVMe and
# the three database datasets with correct tuning.
#
# IMPORTANT: You must identify the correct NVMe device BEFORE running.
# The T500 2TB is the DATA disk (not the OS disk).
#
# To identify:
#   lsblk -d -o NAME,SIZE,MODEL
#   ls -la /dev/disk/by-id/ | grep -i crucial
# =============================================================================
set -euo pipefail

POOL="prod-zfs"
DATASETS=("postgres" "neo4j" "qdrant")

# --- Device identification ---------------------------------------------------
echo "== Identifying available NVMe devices =="
echo ""
lsblk -d -o NAME,SIZE,MODEL | grep -i nvme || true
echo ""
echo "Disk-by-id entries:"
ls -la /dev/disk/by-id/ | grep -i nvme | grep -v part || true
echo ""

# Check if pool already exists
if zpool list "$POOL" > /dev/null 2>&1; then
    echo "Pool '$POOL' already exists:"
    zpool status "$POOL"
    echo ""
    echo "Skipping pool creation. Checking datasets..."
else
    echo "==========================================="
    echo "  MANUAL STEP REQUIRED"
    echo "==========================================="
    echo ""
    echo "Identify the Crucial T500 2TB NVMe from the list above."
    echo "It should be ~2TB and NOT the OS disk."
    echo ""
    echo "Then run this command manually (replacing /dev/disk/by-id/YOUR_DEVICE):"
    echo ""
    echo "  zpool create \\"
    echo "    -o ashift=12 \\"
    echo "    -O compression=zstd \\"
    echo "    -O atime=off \\"
    echo "    -O xattr=sa \\"
    echo "    -O acltype=posixacl \\"
    echo "    ${POOL} \\"
    echo "    /dev/disk/by-id/YOUR_DEVICE"
    echo ""
    echo "After creating the pool, re-run this script to create datasets."
    exit 0
fi

# --- Create datasets ---------------------------------------------------------
echo ""
echo "== Creating datasets =="

declare -A RECORDSIZE=(
    [postgres]="16K"
    [neo4j]="1M"
    [qdrant]="128K"
)

for ds in "${DATASETS[@]}"; do
    FULL="${POOL}/${ds}"
    if zfs list -H -o name "$FULL" > /dev/null 2>&1; then
        echo "  EXISTS: $FULL"
    else
        echo "  CREATE: $FULL (recordsize=${RECORDSIZE[$ds]})"
        zfs create "$FULL"
        zfs set recordsize="${RECORDSIZE[$ds]}" "$FULL"
    fi
done

# --- Verify ------------------------------------------------------------------
echo ""
echo "== Verification =="
zfs list -o name,mountpoint,used,avail,compression,recordsize -r "$POOL"
echo ""

# Check all properties
ERRORS=0
for ds in "${DATASETS[@]}"; do
    FULL="${POOL}/${ds}"
    COMP=$(zfs get -H -o value compression "$FULL")
    AT=$(zfs get -H -o value atime "$FULL")
    RS=$(zfs get -H -o value recordsize "$FULL")

    echo "  ${FULL}: compression=${COMP} atime=${AT} recordsize=${RS}"

    [[ "$COMP" == "zstd" ]] || { echo "    WARNING: compression should be zstd"; ((ERRORS++)); }
    [[ "$AT" == "off" ]] || { echo "    WARNING: atime should be off"; ((ERRORS++)); }
    [[ "$RS" == "${RECORDSIZE[$ds]}" ]] || { echo "    WARNING: recordsize should be ${RECORDSIZE[$ds]}"; ((ERRORS++)); }
done

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All checks passed. ZFS is ready."
else
    echo "${ERRORS} warning(s). Review above."
fi
