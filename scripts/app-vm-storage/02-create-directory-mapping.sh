#!/usr/bin/env bash
# =============================================================================
# 02-create-directory-mapping.sh — Create Proxmox cluster directory mapping
# =============================================================================
# Run on: Any Proxmox node (mappings are cluster-level resources)
#
# Creates the directory resource mapping that wires a host filesystem path
# to a virtiofs tag name. This mapping is referenced when attaching virtiofs
# devices to VMs via `qm set --virtiofs<N> dirid=<mapping-id>`.
#
# Idempotent — skips creation if mapping already exists.
#
# Usage: ENV=dev  ./02-create-directory-mapping.sh
#        ENV=prod ./02-create-directory-mapping.sh
# =============================================================================
set -euo pipefail
ERRORS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

header "Creating Proxmox directory mapping: ${MAPPING_ID} (${ENV^^})"

# ── Pre-flight: verify ZFS dataset path exists on target node ────────────────
# If running on the target node, check directly. Otherwise, check via SSH.
HOSTNAME_ACTUAL=$(hostname)
if [[ "$HOSTNAME_ACTUAL" == "${PVE_NODE}" ]]; then
    if [[ -d "${ZFS_MOUNTPOINT}" ]]; then
        pass "Path ${ZFS_MOUNTPOINT} exists on ${PVE_NODE}"
    else
        fail "Path ${ZFS_MOUNTPOINT} does not exist on ${PVE_NODE}"
        echo "  Run 01-create-zfs-dataset.sh on ${PVE_NODE} first."
        exit 1
    fi
else
    info "Running on ${HOSTNAME_ACTUAL}, checking ${PVE_NODE} via SSH..."
    if ssh -o ConnectTimeout=5 "${PVE_HOST}" "test -d ${ZFS_MOUNTPOINT}" 2>/dev/null; then
        pass "Path ${ZFS_MOUNTPOINT} exists on ${PVE_NODE}"
    else
        fail "Path ${ZFS_MOUNTPOINT} does not exist on ${PVE_NODE}"
        echo "  Run 01-create-zfs-dataset.sh on ${PVE_NODE} first."
        exit 1
    fi
fi

# ── Create directory mapping (idempotent) ────────────────────────────────────
if pvesh get "/cluster/mapping/dir/${MAPPING_ID}" > /dev/null 2>&1; then
    info "Mapping '${MAPPING_ID}' already exists — skipping create"
else
    echo "  Creating mapping: ${MAPPING_ID} → ${PVE_NODE}:${ZFS_MOUNTPOINT}"
    pvesh create /cluster/mapping/dir \
        --id "${MAPPING_ID}" \
        --map "node=${PVE_NODE},path=${ZFS_MOUNTPOINT}"
    pass "Mapping '${MAPPING_ID}' created"
fi

# ── Verify ───────────────────────────────────────────────────────────────────
header "Verification"

if pvesh get "/cluster/mapping/dir/${MAPPING_ID}" > /dev/null 2>&1; then
    pass "Mapping '${MAPPING_ID}' exists in cluster config"
    echo ""
    pvesh get "/cluster/mapping/dir/${MAPPING_ID}"
else
    fail "Mapping '${MAPPING_ID}' not found"
fi

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GRN}Directory mapping ready.${NC} Next: 03-copy-legal-docs.sh"
else
    echo -e "${RED}${ERRORS} check(s) failed.${NC} Fix before proceeding."
    exit 1
fi
