#!/usr/bin/env bash
# =============================================================================
# 03-create-vm-110.sh — Create Fedora CoreOS VM-110 on pve-1
# =============================================================================
# Run on: pve-1 (Proxmox host)
#
# Prerequisites:
#   - 01-create-prod-zfs.sh completed (pool + datasets exist)
#   - 02-setup-prod-directory-mappings.sh completed (mappings exist)
#   - Ignition file exists at /var/coreos/snippets/colossus-prod-db1.ign
#   - CoreOS QCOW2 exists at /var/coreos/images/
#
# This script:
#   1. Verifies all prerequisites
#   2. Creates VM-110 with q35 machine type (required for virtiofs)
#   3. Imports the CoreOS QCOW2 as the boot disk
#   4. Attaches virtiofs directory mappings (prod-db-*)
#   5. Configures Ignition delivery via cloud-init vendor snippet
#   6. Prints next steps (does NOT auto-start)
# =============================================================================
set -euo pipefail

# --- Configuration -----------------------------------------------------------
VMID="${VMID:-110}"
NAME="${NAME:-colossus-prod-db1}"
CPU="${CPU:-4}"
MEMORY="${MEMORY:-16384}"
DISK_GROW="${DISK_GROW:-+40G}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"

COREOS_STORE_PATH="/var/coreos"
COREOS_STORE_ID="coreos"
IGN_FILE="colossus-prod-db1.ign"

# CoreOS image — update this path if you download a newer version
# If the image doesn't exist yet, the script will tell you how to get it.
QCOW_DIR="${COREOS_STORE_PATH}/images"
QCOW=$(find "$QCOW_DIR" -name "fedora-coreos-*-proxmoxve.x86_64.qcow2" 2>/dev/null | sort -V | tail -1)

# --- Pre-flight checks -------------------------------------------------------
echo "== Pre-flight checks =="

# Verify we're on a Proxmox host
if ! command -v qm > /dev/null 2>&1; then
    echo "ERROR: qm not found. This script must run on a Proxmox host." >&2
    exit 1
fi

# Verify VMID doesn't already exist
if qm status "$VMID" > /dev/null 2>&1; then
    echo "ERROR: VM $VMID already exists. Refusing to overwrite." >&2
    echo "  To remove: qm stop $VMID && qm destroy $VMID" >&2
    exit 1
fi

# Verify CoreOS image exists
if [[ -z "$QCOW" || ! -f "$QCOW" ]]; then
    echo "ERROR: No CoreOS QCOW2 image found in $QCOW_DIR" >&2
    echo "  Download one:" >&2
    echo "  podman run --pull=always --rm -v '${QCOW_DIR}:/data' -w /data \\" >&2
    echo "    quay.io/coreos/coreos-installer:release download -s stable -p proxmoxve -f qcow2.xz --decompress" >&2
    exit 1
fi
echo "  CoreOS image: $QCOW"

# Verify Ignition file exists
IGN_PATH="${COREOS_STORE_PATH}/snippets/${IGN_FILE}"
if [[ ! -f "$IGN_PATH" ]]; then
    echo "ERROR: Ignition file not found at $IGN_PATH" >&2
    echo "  Transpile the Butane config and copy it there first:" >&2
    echo "    scp colossus-prod-db1.ign root@pve-1:${IGN_PATH}" >&2
    exit 1
fi
echo "  Ignition file: $IGN_PATH"

# Ensure Proxmox storage for snippets exists
if ! pvesm status | awk '{print $1}' | grep -qx "$COREOS_STORE_ID"; then
    echo "  Creating Proxmox storage '$COREOS_STORE_ID'..."
    mkdir -p "$COREOS_STORE_PATH"/{images,snippets}
    pvesm add dir "$COREOS_STORE_ID" --path "$COREOS_STORE_PATH" --content images,snippets
fi
echo "  Proxmox storage: $COREOS_STORE_ID"

# Verify PROD directory mappings exist
for dirid in prod-db-postgres prod-db-neo4j prod-db-qdrant; do
    if ! pvesh get "/cluster/mapping/dir/${dirid}" > /dev/null 2>&1; then
        echo "ERROR: Directory mapping '${dirid}' not found." >&2
        echo "  Run 02-setup-prod-directory-mappings.sh first." >&2
        exit 1
    fi
done
echo "  Directory mappings: prod-db-postgres, prod-db-neo4j, prod-db-qdrant"

echo ""
echo "== Creating VM $VMID ($NAME) =="

# --- Create VM ---------------------------------------------------------------
# q35 machine type is REQUIRED for virtiofs support
qm create "$VMID" \
    --name "$NAME" \
    --machine q35 \
    --cores "$CPU" \
    --memory "$MEMORY" \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsihw virtio-scsi-pci

echo "  VM shell created (q35 machine type)"

# --- Import CoreOS disk ------------------------------------------------------
qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${QCOW}"
echo "  CoreOS image imported as scsi0"

# --- Grow disk ---------------------------------------------------------------
qm resize "$VMID" scsi0 "$DISK_GROW"
echo "  Disk grown by $DISK_GROW"

# --- Cloud-init drive (Ignition delivery vehicle) ----------------------------
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
echo "  Cloud-init drive attached"

# --- Boot order --------------------------------------------------------------
qm set "$VMID" --boot order=scsi0
echo "  Boot order: scsi0"

# --- Serial console -----------------------------------------------------------
qm set "$VMID" --serial0 socket --vga serial0
echo "  Serial console enabled (qm terminal $VMID)"

# --- Ignition via cloud-init vendor snippet -----------------------------------
qm set "$VMID" --cicustom "vendor=${COREOS_STORE_ID}:snippets/${IGN_FILE}"
qm set "$VMID" --ciupgrade 0
echo "  Ignition configured via cicustom"

# --- Attach virtiofs shares (PROD mappings) -----------------------------------
qm set "$VMID" -virtiofs0 "dirid=prod-db-postgres,cache=always"
qm set "$VMID" -virtiofs1 "dirid=prod-db-neo4j,cache=always"
qm set "$VMID" -virtiofs2 "dirid=prod-db-qdrant,cache=always"
echo "  virtiofs shares attached (prod-db-postgres, prod-db-neo4j, prod-db-qdrant)"

# --- Summary ------------------------------------------------------------------
echo ""
echo "== VM $VMID created successfully =="
echo ""
qm config "$VMID"
echo ""
echo "==========================================="
echo "  NEXT STEPS:"
echo "==========================================="
echo "  1. Review the config above"
echo "  2. Start the VM:"
echo "       qm start $VMID"
echo "  3. Wait ~60s for boot, then SSH:"
echo "       ssh core@10.10.100.110"
echo "  4. Verify inside VM:"
echo "       mount | grep virtiofs"
echo "       ls -dZ /var/mnt/data/*"
echo "       sudo podman ps"
echo "==========================================="
