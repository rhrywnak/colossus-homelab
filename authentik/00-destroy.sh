#!/usr/bin/env bash
# =============================================================================
# 00-destroy.sh — Destroy Authentik VM (preserves ZFS data)
# =============================================================================
# Run on: pve-3 (Proxmox host)
#
# Destroys VM-316 but leaves ZFS datasets intact. This allows rebuilding
# the VM from Ignition while preserving PostgreSQL data and Authentik
# media/templates.
#
# To also destroy ZFS datasets (full cleanup), use:
#   zfs destroy -r pbs-zfs/services/authentik
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

header "Destroying VM-${VMID} (${VM_NAME})"

# ── Pre-flight ───────────────────────────────────────────────────────────────
if ! command -v qm > /dev/null 2>&1; then
    echo "ERROR: qm not found. This script must run on a Proxmox host." >&2
    exit 1
fi

if ! qm status ${VMID} &>/dev/null; then
    info "VM-${VMID} does not exist — nothing to destroy"
    exit 0
fi

# ── Confirmation ─────────────────────────────────────────────────────────────
VM_STATUS=$(qm status ${VMID} | awk '{print $2}')
echo ""
echo "  VM-${VMID} (${VM_NAME}) is currently: ${VM_STATUS}"
echo "  ZFS datasets will be PRESERVED."
echo ""
read -p "  Destroy VM-${VMID}? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "  Aborted."
    exit 0
fi

# ── Stop if running ──────────────────────────────────────────────────────────
if [[ "${VM_STATUS}" == "running" ]]; then
    echo "  Stopping VM-${VMID}..."
    qm stop ${VMID}
    sleep 3
fi

# ── Destroy ──────────────────────────────────────────────────────────────────
echo "  Destroying VM-${VMID}..."
qm destroy ${VMID} --purge

pass "VM-${VMID} destroyed"

# ── Verify ZFS datasets still exist ─────────────────────────────────────────
header "Verifying ZFS data preserved"

if zfs list "${ZFS_POSTGRES}" &>/dev/null; then
    pass "PostgreSQL data intact: ${ZFS_POSTGRES}"
else
    info "PostgreSQL dataset not found (may not have been created yet)"
fi

if zfs list "${ZFS_DATA}" &>/dev/null; then
    pass "Authentik data intact: ${ZFS_DATA}"
else
    info "Authentik data dataset not found (may not have been created yet)"
fi

echo ""
echo -e "${GRN}VM-${VMID} destroyed. ZFS data preserved.${NC}"
echo "  To recreate: ./03-create-vm.sh"
echo "  To destroy ZFS data: zfs destroy -r ${ZFS_PARENT}"
