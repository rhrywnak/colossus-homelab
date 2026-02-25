#!/usr/bin/env bash
# =============================================================================
# 05-validate-vm-storage.sh — Validate virtiofs storage inside app VM
# =============================================================================
# Run on: Workstation (proxima-centauri)
#
# SSH into the app VM and verify:
#   - virtiofs mount is active
#   - Mount path is correct (canonical /var/mnt/data/legal-docs)
#   - SELinux context is container_file_t
#   - PDFs are accessible
#   - systemd mount unit is enabled and active
#   - Backend container has correct volume mount (if running)
#
# Usage: ENV=dev  ./05-validate-vm-storage.sh
#        ENV=prod ./05-validate-vm-storage.sh
# =============================================================================
set -euo pipefail
ERRORS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

VM_SSH="core@${VM_IP}"

header "Validating VM-${VMID} (${VM_NAME}) storage (${ENV^^})"

# ── Pre-flight: VM reachable via SSH ─────────────────────────────────────────
echo "  Checking SSH connectivity to ${VM_SSH}..."
if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${VM_SSH}" "true" 2>/dev/null; then
    fail "Cannot SSH to ${VM_SSH}"
    echo "  VM may still be booting. Wait 2-3 minutes and retry."
    echo "  If VM was just recreated, you may need to clear the old host key:"
    echo "    ssh-keygen -R ${VM_IP}"
    exit 1
fi
pass "SSH connection to ${VM_SSH} established"

# ── Check 1: virtiofs mount is present ───────────────────────────────────────
header "virtiofs mount"

MOUNT_OUTPUT=$(ssh "${VM_SSH}" "mount | grep virtiofs" 2>/dev/null || true)
if [[ -n "$MOUNT_OUTPUT" ]]; then
    pass "virtiofs mount found"
    echo "  ${MOUNT_OUTPUT}"
else
    fail "No virtiofs mount found"
    echo "  Check: qm config ${VMID} | grep virtiofs"
    echo "  Check: systemctl status var-mnt-data-legal\\\\x2ddocs.mount"
fi

# Verify mount is at the correct path
if echo "$MOUNT_OUTPUT" | grep -q "${VM_MOUNT_CANONICAL}"; then
    pass "Mount at correct path: ${VM_MOUNT_CANONICAL}"
else
    fail "Mount not at expected path: ${VM_MOUNT_CANONICAL}"
fi

# ── Check 2: systemd mount unit ─────────────────────────────────────────────
header "systemd mount unit"

UNIT_STATUS=$(ssh "${VM_SSH}" "systemctl is-active var-mnt-data-legal\\\\x2ddocs.mount" 2>/dev/null || echo "unknown")
if [[ "$UNIT_STATUS" == "active" ]]; then
    pass "Mount unit is active"
else
    fail "Mount unit status: ${UNIT_STATUS} (expected active)"
fi

UNIT_ENABLED=$(ssh "${VM_SSH}" "systemctl is-enabled var-mnt-data-legal\\\\x2ddocs.mount" 2>/dev/null || echo "unknown")
if [[ "$UNIT_ENABLED" == "enabled" ]]; then
    pass "Mount unit is enabled (survives reboot)"
else
    fail "Mount unit enabled status: ${UNIT_ENABLED} (expected enabled)"
fi

# ── Check 3: SELinux context ─────────────────────────────────────────────────
header "SELinux context"

SELINUX_OUTPUT=$(ssh "${VM_SSH}" "ls -Z ${VM_MOUNT_PATH}/ | head -3" 2>/dev/null || true)
if echo "$SELINUX_OUTPUT" | grep -q "container_file_t"; then
    pass "SELinux context is container_file_t"
    echo "  Sample:"
    echo "$SELINUX_OUTPUT" | sed 's/^/    /'
else
    fail "SELinux context is NOT container_file_t"
    echo "  Got:"
    echo "$SELINUX_OUTPUT" | sed 's/^/    /'
    echo ""
    echo "  Verify Butane mount unit includes:"
    echo "    Options=context=\"system_u:object_r:container_file_t:s0\""
fi

# ── Check 4: PDF files accessible ────────────────────────────────────────────
header "Document files"

REMOTE_PDF_COUNT=$(ssh "${VM_SSH}" "find ${VM_MOUNT_PATH} -maxdepth 1 -name '*.pdf' -type f | wc -l" 2>/dev/null || echo "0")
if [[ "$REMOTE_PDF_COUNT" -gt 0 ]]; then
    pass "${REMOTE_PDF_COUNT} PDF(s) accessible in ${VM_MOUNT_PATH}"
else
    fail "No PDFs found in ${VM_MOUNT_PATH}"
fi

if [[ "$REMOTE_PDF_COUNT" -eq "${EXPECTED_PDF_COUNT}" ]]; then
    pass "PDF count matches expected: ${EXPECTED_PDF_COUNT}"
else
    info "Expected ${EXPECTED_PDF_COUNT} PDFs, found ${REMOTE_PDF_COUNT}"
fi

# ── Check 5: Container volume mount (if containers are running) ──────────────
header "Container status"

CONTAINER_RUNNING=$(ssh "${VM_SSH}" "sudo podman ps --format '{{.Names}}' 2>/dev/null" || true)
if echo "$CONTAINER_RUNNING" | grep -q "colossus-backend"; then
    pass "colossus-backend container is running"

    # Check volume mounts
    MOUNT_JSON=$(ssh "${VM_SSH}" "sudo podman inspect colossus-backend --format '{{json .Mounts}}'" 2>/dev/null || echo "[]")
    if echo "$MOUNT_JSON" | grep -q "legal-docs"; then
        pass "Container has legal-docs volume mount"
        echo "  Mounts:"
        echo "$MOUNT_JSON" | python3 -m json.tool 2>/dev/null | sed 's/^/    /' || echo "    ${MOUNT_JSON}"
    else
        fail "Container missing legal-docs volume mount"
        echo "  This may be expected if Ansible hasn't deployed yet."
        echo "  Run Ansible deploy after this validation."
    fi
else
    info "colossus-backend not running — expected if Ansible hasn't deployed yet"
    echo "  Ignition-placed Quadlet may be using old image tags."
    echo "  Run Ansible deploy (Phase 8 in runbook) to fix."
fi

# ── Check 6: Hostname ────────────────────────────────────────────────────────
header "VM identity"

REMOTE_HOSTNAME=$(ssh "${VM_SSH}" "hostname" 2>/dev/null || echo "unknown")
if [[ "$REMOTE_HOSTNAME" == "${VM_NAME}" ]]; then
    pass "Hostname: ${REMOTE_HOSTNAME}"
else
    fail "Hostname: ${REMOTE_HOSTNAME} (expected ${VM_NAME})"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
header "Summary"

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GRN}All checks passed!${NC}"
    echo ""
    echo "  VM-${VMID} (${VM_NAME}) has virtiofs document storage working."
    echo ""
    echo "  Next steps:"
    echo "    1. Update Ansible role (Phase 7 in runbook)"
    echo "    2. Deploy via Ansible: ENV=${ENV} — version v0.2.0"
    echo "    3. Re-run this script to verify container mounts"
else
    echo -e "${RED}${ERRORS} check(s) failed.${NC}"
    echo ""
    echo "  Review failures above. Common causes:"
    echo "    - VM still booting (wait and retry)"
    echo "    - Old SSH host key (ssh-keygen -R ${VM_IP})"
    echo "    - Ignition typo (check Butane source)"
    echo "    - Missing virtiofs attachment (qm config ${VMID} | grep virtiofs)"
    exit 1
fi
