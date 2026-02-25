#!/usr/bin/env bash
# =============================================================================
# 03-copy-legal-docs.sh — Copy PDF documents to ZFS dataset on Proxmox host
# =============================================================================
# Run on: Workstation (proxima-centauri)
#
# Copies legal document PDFs from the local workstation to the ZFS dataset
# on the target Proxmox host via SCP. Verifies file count after copy.
#
# Source: ~/colossus-legal-data/*.pdf (configurable in config.sh)
#
# Usage: ENV=dev  ./03-copy-legal-docs.sh
#        ENV=prod ./03-copy-legal-docs.sh
# =============================================================================
set -euo pipefail
ERRORS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

header "Copying legal documents to ${PVE_NODE} (${ENV^^})"

# ── Pre-flight: verify source files exist ────────────────────────────────────
if [[ ! -d "${DOCS_SOURCE}" ]]; then
    fail "Source directory not found: ${DOCS_SOURCE}"
    echo "  Set DOCS_SOURCE in config.sh or create the directory."
    exit 1
fi

LOCAL_COUNT=$(find "${DOCS_SOURCE}" -maxdepth 1 -name "*.pdf" -type f | wc -l)
if [[ "$LOCAL_COUNT" -eq 0 ]]; then
    fail "No PDF files found in ${DOCS_SOURCE}"
    exit 1
fi
pass "Found ${LOCAL_COUNT} PDF(s) in ${DOCS_SOURCE}"

if [[ "$LOCAL_COUNT" -ne "${EXPECTED_PDF_COUNT}" ]]; then
    info "Expected ${EXPECTED_PDF_COUNT} PDFs, found ${LOCAL_COUNT} — proceeding anyway"
fi

# ── Pre-flight: verify remote host is reachable ──────────────────────────────
if ! ssh -o ConnectTimeout=5 "${PVE_HOST}" "true" 2>/dev/null; then
    fail "Cannot reach ${PVE_HOST}"
    exit 1
fi
pass "${PVE_HOST} reachable"

# ── Pre-flight: verify ZFS mountpoint exists on remote ───────────────────────
if ! ssh "${PVE_HOST}" "test -d ${ZFS_MOUNTPOINT}" 2>/dev/null; then
    fail "Directory ${ZFS_MOUNTPOINT} does not exist on ${PVE_NODE}"
    echo "  Run 01-create-zfs-dataset.sh on ${PVE_NODE} first."
    exit 1
fi
pass "Remote directory ${ZFS_MOUNTPOINT} exists"

# ── Copy files ───────────────────────────────────────────────────────────────
header "Copying PDFs to ${PVE_HOST}:${ZFS_MOUNTPOINT}/"

scp "${DOCS_SOURCE}"/*.pdf "${PVE_HOST}:${ZFS_MOUNTPOINT}/"

pass "SCP complete"

# ── Verify remote file count ─────────────────────────────────────────────────
header "Verification"

REMOTE_COUNT=$(ssh "${PVE_HOST}" "find ${ZFS_MOUNTPOINT} -maxdepth 1 -name '*.pdf' -type f | wc -l")
if [[ "$REMOTE_COUNT" -eq "$LOCAL_COUNT" ]]; then
    pass "Remote PDF count matches local: ${REMOTE_COUNT}"
else
    fail "Remote PDF count (${REMOTE_COUNT}) does not match local (${LOCAL_COUNT})"
fi

# Show file listing
echo ""
ssh "${PVE_HOST}" "ls -lh ${ZFS_MOUNTPOINT}/*.pdf"

echo ""
TOTAL_SIZE=$(ssh "${PVE_HOST}" "du -sh ${ZFS_MOUNTPOINT}/ | cut -f1")
info "Total size: ${TOTAL_SIZE}"

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GRN}Documents copied successfully.${NC} Next: 04-recreate-app-vm.sh"
else
    echo -e "${RED}${ERRORS} check(s) failed.${NC} Investigate before proceeding."
    exit 1
fi
