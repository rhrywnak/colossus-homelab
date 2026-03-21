#!/usr/bin/env bash
# =============================================================================
# 02-create-directory-mappings.sh — Create Proxmox directory mappings
# =============================================================================
# Run on: pve-3 (or any Proxmox cluster node — mappings are cluster-level)
#
# Creates cluster-level directory resource mappings for virtiofs:
#   authentik-postgres → pve-3:/pbs-zfs/services/authentik/postgres
#   authentik-data     → pve-3:/pbs-zfs/services/authentik/data
#
# These are referenced by `qm set --virtiofs<N> dirid=<mapping-id>` when
# creating the VM, and by the virtiofs `What=` tag in Butane mount units.
#
# Idempotent — skips creation if mapping already exists.
# =============================================================================
set -euo pipefail
ERRORS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

header "Creating Proxmox directory mappings for Authentik"

# ── Pre-flight: verify ZFS mountpoints exist ─────────────────────────────────
declare -A MAPPINGS=(
    ["${MAPPING_POSTGRES}"]="${ZFS_POSTGRES_MOUNTPOINT}"
    ["${MAPPING_DATA}"]="${ZFS_DATA_MOUNTPOINT}"
)

for dirid in "${!MAPPINGS[@]}"; do
    path="${MAPPINGS[$dirid]}"
    HOSTNAME_ACTUAL=$(hostname)

    if [[ "$HOSTNAME_ACTUAL" == "${PVE_NODE}" ]]; then
        if [[ -d "$path" ]]; then
            pass "Path $path exists on ${PVE_NODE}"
        else
            fail "Path $path does not exist on ${PVE_NODE}"
            echo "  Run 01-create-zfs-datasets.sh first."
            exit 1
        fi
    else
        info "Running on ${HOSTNAME_ACTUAL}, checking ${PVE_NODE} via SSH..."
        if ssh -o ConnectTimeout=5 "${PVE_HOST}" "test -d ${path}" 2>/dev/null; then
            pass "Path ${path} exists on ${PVE_NODE}"
        else
            fail "Path ${path} does not exist on ${PVE_NODE}"
            echo "  Run 01-create-zfs-datasets.sh on ${PVE_NODE} first."
            exit 1
        fi
    fi
done

# ── Create directory mappings (idempotent) ───────────────────────────────────
header "Creating mappings"

for dirid in "${!MAPPINGS[@]}"; do
    path="${MAPPINGS[$dirid]}"

    if pvesh get "/cluster/mapping/dir/${dirid}" > /dev/null 2>&1; then
        info "Mapping '${dirid}' already exists — skipping"
    else
        echo "  Creating: ${dirid} → ${PVE_NODE}:${path}"
        pvesh create /cluster/mapping/dir \
            --id "${dirid}" \
            --map "node=${PVE_NODE},path=${path}"
        pass "Mapping '${dirid}' created"
    fi
done

# ── Verify ───────────────────────────────────────────────────────────────────
header "Verification"

for dirid in "${!MAPPINGS[@]}"; do
    if pvesh get "/cluster/mapping/dir/${dirid}" > /dev/null 2>&1; then
        pass "Mapping '${dirid}' exists in cluster config"
        pvesh get "/cluster/mapping/dir/${dirid}" 2>/dev/null
        echo ""
    else
        fail "Mapping '${dirid}' not found"
    fi
done

if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GRN}Directory mappings ready.${NC} Next: ./03-create-vm.sh"
else
    echo -e "${RED}${ERRORS} check(s) failed.${NC} Fix before proceeding."
    exit 1
fi
