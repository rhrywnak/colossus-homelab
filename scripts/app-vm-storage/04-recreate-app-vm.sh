#!/usr/bin/env bash
# =============================================================================
# 04-recreate-app-vm.sh — Destroy and recreate app VM with virtiofs storage
# =============================================================================
# Run on: Proxmox host (pve-1 or pve-2, depending on ENV)
#
# Destroys the existing application VM and recreates it with virtiofs
# document storage attached. This is required because CoreOS Ignition
# only runs on first boot — there is no way to re-apply Ignition to a
# running VM.
#
# App VMs are stateless: all persistent data lives on the host ZFS dataset.
# Destroying and recreating is safe and takes ~2 minutes.
#
# Prerequisites:
#   - 01-create-zfs-dataset.sh completed
#   - 02-create-directory-mapping.sh completed
#   - 03-copy-legal-docs.sh completed (documents on ZFS dataset)
#   - Updated Ignition file at /var/coreos/snippets/
#
# Usage: ENV=dev  ./04-recreate-app-vm.sh
#        ENV=prod ./04-recreate-app-vm.sh
# =============================================================================
set -euo pipefail
ERRORS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

header "Recreating ${VM_NAME} (VM-${VMID}) on ${PVE_NODE} (${ENV^^})"

# ── Pre-flight checks ───────────────────────────────────────────────────────

# CoreOS image
QCOW=$(ls ${COREOS_IMAGE_DIR}/fedora-coreos-*.qcow2 2>/dev/null | sort -V | tail -1)
if [[ -z "$QCOW" ]]; then
    fail "No CoreOS QCOW2 image found in ${COREOS_IMAGE_DIR}"
    echo "  Download: podman run --pull=always --rm -v '${COREOS_IMAGE_DIR}:/data' -w /data \\"
    echo "    quay.io/coreos/coreos-installer:release download -s stable -p proxmoxve -f qcow2.xz --decompress"
    exit 1
fi
pass "CoreOS image: $(basename ${QCOW})"

# Ignition file
if [[ ! -f "${IGN_PATH}" ]]; then
    fail "Ignition file not found: ${IGN_PATH}"
    echo ""
    echo "  Transpile and copy:"
    echo "    podman run --rm -i quay.io/coreos/butane:release --pretty --strict \\"
    echo "      < ${VM_NAME}.bu > ${IGN_FILE}"
    echo "    scp ${IGN_FILE} ${PVE_HOST}:${COREOS_SNIPPET_DIR}/"
    exit 1
fi
pass "Ignition file: ${IGN_PATH}"

# Directory mapping exists
if ! pvesh get "/cluster/mapping/dir/${MAPPING_ID}" > /dev/null 2>&1; then
    fail "Directory mapping '${MAPPING_ID}' not found"
    echo "  Run 02-create-directory-mapping.sh first."
    exit 1
fi
pass "Directory mapping '${MAPPING_ID}' exists"

# ZFS dataset has documents
DOC_COUNT=$(find "${ZFS_MOUNTPOINT}" -maxdepth 1 -name "*.pdf" -type f 2>/dev/null | wc -l)
if [[ "$DOC_COUNT" -eq 0 ]]; then
    fail "No PDFs found in ${ZFS_MOUNTPOINT}"
    echo "  Run 03-copy-legal-docs.sh first."
    exit 1
fi
pass "${DOC_COUNT} PDFs found in ${ZFS_MOUNTPOINT}"

# ── Safety confirmation ──────────────────────────────────────────────────────
echo ""
echo -e "${YLW}WARNING: This will DESTROY VM-${VMID} (${VM_NAME}) and recreate it.${NC}"
echo ""
echo "  VM ID:     ${VMID}"
echo "  VM Name:   ${VM_NAME}"
echo "  Node:      ${PVE_NODE}"
echo "  Cores:     ${VM_CORES}"
echo "  Memory:    ${VM_MEMORY} MiB"
echo "  Disk:      base + ${VM_DISK_GROW}"
echo "  virtiofs:  ${MAPPING_ID} → ${ZFS_MOUNTPOINT}"
echo "  Ignition:  ${IGN_PATH}"
echo ""

read -p "Type 'yes' to proceed: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# ── Destroy existing VM (if it exists) ───────────────────────────────────────
header "Destroying existing VM-${VMID}"

if qm status ${VMID} &>/dev/null; then
    VM_STATUS=$(qm status ${VMID} | awk '{print $2}')
    if [[ "$VM_STATUS" == "running" ]]; then
        echo "  Stopping VM-${VMID}..."
        qm stop ${VMID}
        sleep 3
    fi
    echo "  Destroying VM-${VMID}..."
    qm destroy ${VMID} --purge
    pass "VM-${VMID} destroyed"
else
    info "VM-${VMID} does not exist — nothing to destroy"
fi

# ── Create new VM ────────────────────────────────────────────────────────────
header "Creating VM-${VMID}"

echo "  Creating VM..."
qm create ${VMID} \
    --name ${VM_NAME} \
    --machine q35 \
    --cores ${VM_CORES} \
    --memory ${VM_MEMORY} \
    --net0 "virtio,bridge=vmbr0" \
    --scsihw virtio-scsi-pci

echo "  Importing CoreOS disk..."
qm set ${VMID} --scsi0 "${VM_STORAGE}:0,import-from=${QCOW}"

echo "  Growing disk by ${VM_DISK_GROW}..."
qm resize ${VMID} scsi0 +${VM_DISK_GROW}

# Cloud-init drive (Ignition delivery)
qm set ${VMID} --ide2 "${VM_STORAGE}:cloudinit"

# Boot order
qm set ${VMID} --boot order=scsi0

# Serial console
qm set ${VMID} --serial0 socket --vga serial0

# Ignition via cloud-init vendor snippet
qm set ${VMID} --cicustom "vendor=coreos:snippets/${IGN_FILE}"
qm set ${VMID} --ciupgrade 0

# Start on boot
qm set ${VMID} --onboot 1

pass "VM-${VMID} base configuration complete"

# ── Attach virtiofs — document storage ───────────────────────────────────────
header "Attaching virtiofs document storage"

qm set ${VMID} --virtiofs0 "dirid=${MAPPING_ID}"
pass "virtiofs0 attached: dirid=${MAPPING_ID}"

# ── Show final config ────────────────────────────────────────────────────────
header "VM-${VMID} configuration"
echo ""
qm config ${VMID}

# ── Start VM ─────────────────────────────────────────────────────────────────
header "Starting VM-${VMID}"

qm start ${VMID}
pass "VM-${VMID} started"

echo ""
echo "  VM-${VMID} is booting. First boot will:"
echo "    1. Apply Ignition configuration"
echo "    2. Set hostname to ${VM_NAME}"
echo "    3. Configure static IP ${VM_IP}"
echo "    4. Create virtiofs systemd mount unit"
echo "    5. Create Quadlet container definitions"
echo ""
echo "  Wait ~2-3 minutes, then run:"
echo "    ENV=${ENV} ./05-validate-vm-storage.sh"
echo ""
echo -e "${GRN}VM-${VMID} recreated successfully.${NC}"
