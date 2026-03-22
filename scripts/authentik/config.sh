#!/usr/bin/env bash
# =============================================================================
# config.sh — Shared configuration for Authentik VM deployment scripts
# =============================================================================
# Sourced by all scripts in this directory. Edit values here, not in
# individual scripts.
#
# This deploys Authentik 2025.12 on a CoreOS VM with Podman Quadlet.
# No ENV variable needed — Authentik is a singleton infrastructure service.
# =============================================================================

# ── Proxmox host ─────────────────────────────────────────────────────────────
PVE_HOST="root@10.10.100.5"     # pve-3 (infra node)
PVE_NODE="pve-3"

# ── VM parameters ────────────────────────────────────────────────────────────
VMID=316
VM_NAME="authentik"
VM_IP="10.10.100.58"
VM_CIDR="${VM_IP}/24"
VM_GATEWAY="10.10.100.1"
VM_DNS="10.10.100.53"            # Pi-hole
VM_CORES=2
VM_MEMORY=2048
VM_STORAGE="local-lvm"
VM_DISK_GROW="+20G"
VM_BRIDGE="vmbr0"

# ── CoreOS image and Ignition ────────────────────────────────────────────────
COREOS_IMAGE_DIR="/var/coreos/images"
COREOS_SNIPPET_DIR="/var/coreos/snippets"
COREOS_STORE_ID="coreos"
COREOS_STORE_PATH="/var/coreos"
IGN_FILE="authentik.ign"
IGN_PATH="${COREOS_SNIPPET_DIR}/${IGN_FILE}"

# ── ZFS datasets on pve-3 ───────────────────────────────────────────────────
# Under the existing pbs-zfs pool used by other infra services (semaphore, etc.)
ZFS_PARENT="pbs-zfs/services/authentik"
ZFS_POSTGRES="${ZFS_PARENT}/postgres"
ZFS_DATA="${ZFS_PARENT}/data"

# ZFS mountpoints (auto-derived from dataset names)
ZFS_POSTGRES_MOUNTPOINT="/${ZFS_POSTGRES}"    # /pbs-zfs/services/authentik/postgres
ZFS_DATA_MOUNTPOINT="/${ZFS_DATA}"            # /pbs-zfs/services/authentik/data

# ── Proxmox directory mappings (cluster-level) ───────────────────────────────
MAPPING_POSTGRES="authentik-postgres"
MAPPING_DATA="authentik-data"

# ── Authentik container images ───────────────────────────────────────────────
AUTHENTIK_IMAGE="ghcr.io/goauthentik/server:2025.12"
POSTGRES_IMAGE="docker.io/library/postgres:16-alpine"

# ── Ports ────────────────────────────────────────────────────────────────────
AUTHENTIK_HTTP_PORT=9000
AUTHENTIK_HTTPS_PORT=9443

# ── Output helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
BLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  ${GRN}[PASS]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; ERRORS=$((ERRORS + 1)); }
info() { echo -e "  ${YLW}[INFO]${NC} $1"; }
header() { echo -e "\n${BLD}== $1 ==${NC}"; }
