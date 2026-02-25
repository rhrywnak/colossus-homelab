#!/usr/bin/env bash
# =============================================================================
# config.sh — Shared configuration for app VM virtiofs storage scripts
# =============================================================================
# Sourced by all scripts in this directory. Edit values here, not in
# individual scripts.
#
# Usage: ENV=dev ./01-create-zfs-dataset.sh
#        ENV=prod ./01-create-zfs-dataset.sh
#
# ENV must be set to "dev" or "prod" before sourcing.
# =============================================================================

if [[ -z "${ENV:-}" ]]; then
    echo "ERROR: ENV must be set to 'dev' or 'prod'"
    echo "Usage: ENV=dev $0"
    exit 1
fi

if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
    echo "ERROR: ENV must be 'dev' or 'prod' (got: '$ENV')"
    exit 1
fi

# ── Environment-specific values ──────────────────────────────────────────────
if [[ "$ENV" == "dev" ]]; then
    PVE_HOST="root@pve-2"
    PVE_NODE="pve-2"
    ZFS_POOL="dev-zfs"
    MAPPING_ID="dev-legal-docs"
    VMID=220
    VM_NAME="colossus-dev-app1"
    VM_IP="10.10.100.220"
    IGN_FILE="colossus-dev-app1.ign"
else
    PVE_HOST="root@pve-1"
    PVE_NODE="pve-1"
    ZFS_POOL="prod-zfs"
    MAPPING_ID="prod-legal-docs"
    VMID=120
    VM_NAME="colossus-prod-app1"
    VM_IP="10.10.100.120"
    IGN_FILE="colossus-prod-app1.ign"
fi

# ── Shared values (same for both environments) ──────────────────────────────
ZFS_DATASET="${ZFS_POOL}/legal-docs"
ZFS_MOUNTPOINT="/${ZFS_POOL}/legal-docs"
VIRTIOFS_TAG="${MAPPING_ID}"

# VM creation parameters
VM_STORAGE="local-lvm"
VM_CORES=2
VM_MEMORY=4096
VM_DISK_GROW="20G"

# Paths on Proxmox host
COREOS_IMAGE_DIR="/var/coreos/images"
COREOS_SNIPPET_DIR="/var/coreos/snippets"
IGN_PATH="${COREOS_SNIPPET_DIR}/${IGN_FILE}"

# Document source on workstation
DOCS_SOURCE="${HOME}/colossus-legal-data/documents"
EXPECTED_PDF_COUNT=16

# VM mount paths (inside CoreOS)
VM_MOUNT_PATH="/mnt/data/legal-docs"           # symlink path (usable by containers)
VM_MOUNT_CANONICAL="/var/mnt/data/legal-docs"   # canonical path (for systemd units)

# ── Output helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
BLD='\033[1m'
NC='\033[0m'

pass() { echo -e "${GRN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ERRORS=$((ERRORS + 1)); }
info() { echo -e "${YLW}[INFO]${NC} $1"; }
header() { echo -e "\n${BLD}== $1 ==${NC}"; }
