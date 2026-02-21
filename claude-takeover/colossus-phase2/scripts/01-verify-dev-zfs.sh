#!/usr/bin/env bash
# =============================================================================
# 01-verify-dev-zfs.sh — Verify ZFS datasets on pve-2
# =============================================================================
# Run on: pve-2 (Proxmox host)
# Purpose: Confirm dev-zfs pool and datasets exist with correct tuning.
#          This is a READ-ONLY verification script. It changes nothing.
# =============================================================================
set -euo pipefail

POOL="dev-zfs"
DATASETS=("postgres" "neo4j" "qdrant")

RED='\033[0;31m'
GRN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "${GRN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ERRORS=$((ERRORS + 1)); }

ERRORS=0

echo "== Verifying ZFS pool: $POOL =="
if zpool status "$POOL" > /dev/null 2>&1; then
    STATE=$(zpool get -H -o value health "$POOL")
    if [[ "$STATE" == "ONLINE" ]]; then
        pass "Pool $POOL is ONLINE"
    else
        fail "Pool $POOL state is $STATE (expected ONLINE)"
    fi
else
    fail "Pool $POOL does not exist"
    echo "Cannot continue without the pool. Exiting."
    exit 1
fi

echo ""
echo "== Verifying datasets =="
declare -A EXPECTED_RECORDSIZE=(
    [postgres]="16K"
    [neo4j]="1M"
    [qdrant]="128K"
)

for ds in "${DATASETS[@]}"; do
    FULL="${POOL}/${ds}"

    # Existence
    if zfs list -H -o name "$FULL" > /dev/null 2>&1; then
        pass "Dataset $FULL exists"
    else
        fail "Dataset $FULL does not exist"
        continue
    fi

    # Mountpoint
    MP=$(zfs get -H -o value mountpoint "$FULL")
    EXPECTED_MP="/dev-zfs/${ds}"
    if [[ "$MP" == "$EXPECTED_MP" ]]; then
        pass "  mountpoint = $MP"
    else
        fail "  mountpoint = $MP (expected $EXPECTED_MP)"
    fi

    # Compression
    COMP=$(zfs get -H -o value compression "$FULL")
    if [[ "$COMP" == "zstd" ]]; then
        pass "  compression = zstd"
    else
        fail "  compression = $COMP (expected zstd)"
    fi

    # Atime
    AT=$(zfs get -H -o value atime "$FULL")
    if [[ "$AT" == "off" ]]; then
        pass "  atime = off"
    else
        fail "  atime = $AT (expected off)"
    fi

    # Recordsize
    RS=$(zfs get -H -o value recordsize "$FULL")
    EXPECTED_RS="${EXPECTED_RECORDSIZE[$ds]}"
    if [[ "$RS" == "$EXPECTED_RS" ]]; then
        pass "  recordsize = $RS"
    else
        fail "  recordsize = $RS (expected $EXPECTED_RS)"
    fi
done

echo ""
echo "== Dataset usage =="
zfs list -o name,mountpoint,used,avail -r "$POOL"

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GRN}All checks passed.${NC} ZFS is ready for Phase 2."
else
    echo -e "${RED}${ERRORS} check(s) failed.${NC} Fix before proceeding."
    exit 1
fi
