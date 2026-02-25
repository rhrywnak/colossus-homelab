#!/usr/bin/env bash
# =============================================================================
# 01-create-zfs-dataset.sh — Create ZFS dataset for legal document storage
# =============================================================================
# Run on: Proxmox host (pve-1 or pve-2, depending on ENV)
#
# Creates a ZFS dataset for legal document PDF storage. Idempotent — safe
# to run multiple times. No special recordsize tuning needed; PDFs are
# large sequential reads and the default 128K inherited from the pool is ideal.
#
# Usage: ENV=dev  ./01-create-zfs-dataset.sh   (runs on pve-2)
#        ENV=prod ./01-create-zfs-dataset.sh   (runs on pve-1)
# =============================================================================
set -euo pipefail
ERRORS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

header "Creating ZFS dataset: ${ZFS_DATASET} (${ENV^^})"

# ── Pre-flight: verify pool exists ───────────────────────────────────────────
if ! zpool status "${ZFS_POOL}" > /dev/null 2>&1; then
    fail "ZFS pool '${ZFS_POOL}' does not exist on this host"
    echo "  This script must run on ${PVE_NODE}."
    exit 1
fi

POOL_STATE=$(zpool get -H -o value health "${ZFS_POOL}")
if [[ "$POOL_STATE" != "ONLINE" ]]; then
    fail "Pool ${ZFS_POOL} state is ${POOL_STATE} (expected ONLINE)"
    exit 1
fi
pass "Pool ${ZFS_POOL} is ONLINE"

# ── Create dataset (idempotent) ──────────────────────────────────────────────
if zfs list -H -o name "${ZFS_DATASET}" > /dev/null 2>&1; then
    info "Dataset ${ZFS_DATASET} already exists — skipping create"
else
    echo "  Creating ${ZFS_DATASET}..."
    zfs create "${ZFS_DATASET}"
    pass "Dataset ${ZFS_DATASET} created"
fi

# ── Set permissions for virtiofs passthrough ─────────────────────────────────
chmod 755 "${ZFS_MOUNTPOINT}"
pass "Permissions set (755) on ${ZFS_MOUNTPOINT}"

# ── Verify ───────────────────────────────────────────────────────────────────
header "Verification"

# Mountpoint
MP=$(zfs get -H -o value mountpoint "${ZFS_DATASET}")
if [[ "$MP" == "${ZFS_MOUNTPOINT}" ]]; then
    pass "mountpoint = ${MP}"
else
    fail "mountpoint = ${MP} (expected ${ZFS_MOUNTPOINT})"
fi

# Compression (inherited from pool)
COMP=$(zfs get -H -o value compression "${ZFS_DATASET}")
if [[ "$COMP" == "zstd" ]]; then
    pass "compression = zstd"
else
    info "compression = ${COMP} (zstd preferred but not required)"
fi

# Recordsize (default 128K is correct for PDFs)
RS=$(zfs get -H -o value recordsize "${ZFS_DATASET}")
pass "recordsize = ${RS}"

# Directory accessible
if [[ -d "${ZFS_MOUNTPOINT}" ]]; then
    pass "Directory ${ZFS_MOUNTPOINT} is accessible"
else
    fail "Directory ${ZFS_MOUNTPOINT} not found"
fi

echo ""
zfs list -o name,mountpoint,used,avail "${ZFS_DATASET}"

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GRN}ZFS dataset ready.${NC} Next: 02-create-directory-mapping.sh"
else
    echo -e "${RED}${ERRORS} check(s) failed.${NC} Fix before proceeding."
    exit 1
fi
