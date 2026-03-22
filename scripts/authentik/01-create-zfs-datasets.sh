#!/usr/bin/env bash
# =============================================================================
# 01-create-zfs-datasets.sh — Create ZFS datasets for Authentik on pve-3
# =============================================================================
# Run on: pve-3 (Proxmox host)
#
# Creates two ZFS datasets under pbs-zfs/services/authentik/:
#   postgres  — PostgreSQL database files (recordsize=8K for DB workload)
#   data      — Authentik media, templates, exports (/data mount in container)
#
# Idempotent — safe to run multiple times.
#
# Design note: Authentik 2025.12 expects a /data mount point for all file
# storage (media, templates, certs, exports). This replaces the separate
# /media and /custom-templates mounts from earlier versions.
# =============================================================================
set -euo pipefail
ERRORS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

header "Creating ZFS datasets for Authentik on ${PVE_NODE}"

# ── Pre-flight: verify pool exists ───────────────────────────────────────────
POOL_NAME="pbs-zfs"
if ! zpool status "${POOL_NAME}" > /dev/null 2>&1; then
    fail "ZFS pool '${POOL_NAME}' does not exist on this host"
    echo "  This script must run on ${PVE_NODE}."
    exit 1
fi

POOL_STATE=$(zpool get -H -o value health "${POOL_NAME}")
if [[ "$POOL_STATE" != "ONLINE" ]]; then
    fail "Pool ${POOL_NAME} state is ${POOL_STATE} (expected ONLINE)"
    exit 1
fi
pass "Pool ${POOL_NAME} is ONLINE"

# ── Create parent dataset (idempotent) ───────────────────────────────────────
if zfs list -H -o name "${ZFS_PARENT}" > /dev/null 2>&1; then
    info "Parent dataset ${ZFS_PARENT} already exists"
else
    echo "  Creating ${ZFS_PARENT}..."
    zfs create "${ZFS_PARENT}"
    pass "Parent dataset ${ZFS_PARENT} created"
fi

# ── Create postgres dataset (recordsize=8K for database workload) ────────────
if zfs list -H -o name "${ZFS_POSTGRES}" > /dev/null 2>&1; then
    info "Dataset ${ZFS_POSTGRES} already exists"
else
    echo "  Creating ${ZFS_POSTGRES} with recordsize=8K..."
    zfs create -o recordsize=8K "${ZFS_POSTGRES}"
    pass "Dataset ${ZFS_POSTGRES} created"
fi

# ── Create data dataset (default recordsize=128K is fine for general files) ──
if zfs list -H -o name "${ZFS_DATA}" > /dev/null 2>&1; then
    info "Dataset ${ZFS_DATA} already exists"
else
    echo "  Creating ${ZFS_DATA}..."
    zfs create "${ZFS_DATA}"
    pass "Dataset ${ZFS_DATA} created"
fi

# ── Set permissions for virtiofs passthrough ─────────────────────────────────
chmod 755 "${ZFS_POSTGRES_MOUNTPOINT}"
chmod 755 "${ZFS_DATA_MOUNTPOINT}"
pass "Permissions set (755) on both mountpoints"

# ── Create subdirectories for Authentik data ─────────────────────────────────
# Authentik 2025.12 expects /data/media and /data/templates to exist
mkdir -p "${ZFS_DATA_MOUNTPOINT}/media"
mkdir -p "${ZFS_DATA_MOUNTPOINT}/templates"
pass "Subdirectories created: media/, templates/"

# ── Verify ───────────────────────────────────────────────────────────────────
header "Verification"

for DS in "${ZFS_PARENT}" "${ZFS_POSTGRES}" "${ZFS_DATA}"; do
    MP=$(zfs get -H -o value mountpoint "${DS}")
    COMP=$(zfs get -H -o value compression "${DS}")
    RS=$(zfs get -H -o value recordsize "${DS}")
    pass "${DS}  mountpoint=${MP}  compression=${COMP}  recordsize=${RS}"
done

echo ""
zfs list -r -o name,mountpoint,used,avail "${ZFS_PARENT}"

echo ""
echo "  Data directory contents:"
ls -la "${ZFS_DATA_MOUNTPOINT}/"

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GRN}ZFS datasets ready.${NC} Next: ./02-create-directory-mappings.sh"
else
    echo -e "${RED}${ERRORS} check(s) failed.${NC} Fix before proceeding."
    exit 1
fi
