#!/usr/bin/env bash
# =============================================================================
# 03-create-vm.sh — Create Authentik CoreOS VM-316 on pve-3
# =============================================================================
# Run on: pve-3 (Proxmox host)
#
# Prerequisites:
#   - 01-create-zfs-datasets.sh completed
#   - 02-create-directory-mappings.sh completed
#   - Ignition file at /var/coreos/snippets/authentik.ign
#   - CoreOS QCOW2 image at /var/coreos/images/
#
# What this script does:
#   1. Verifies all prerequisites
#   2. Creates VM-316 with q35 machine type (required for virtiofs)
#   3. Imports the CoreOS QCOW2 as the boot disk
#   4. Attaches virtiofs directory mappings (postgres, data)
#   5. Configures Ignition delivery via cloud-init vendor snippet
#   6. Starts the VM
#
# The VM boots with:
#   - Static IP 10.10.100.58/24
#   - 3 Podman Quadlet containers (PostgreSQL, Authentik server, Authentik worker)
#   - 2 virtiofs mounts (postgres data, Authentik /data)
#   - Podman network for inter-container communication
# =============================================================================
set -euo pipefail
ERRORS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

header "Creating VM-${VMID} (${VM_NAME}) on ${PVE_NODE}"

# ── Pre-flight checks ───────────────────────────────────────────────────────

# Must be on a Proxmox host
if ! command -v qm > /dev/null 2>&1; then
    echo "ERROR: qm not found. This script must run on a Proxmox host." >&2
    exit 1
fi

# VM must not already exist
if qm status ${VMID} > /dev/null 2>&1; then
    fail "VM-${VMID} already exists. Run 00-destroy.sh first."
    exit 1
fi
pass "VMID ${VMID} is available"

# CoreOS image
QCOW=$(ls ${COREOS_IMAGE_DIR}/fedora-coreos-*.qcow2 2>/dev/null | sort -V | tail -1)
if [[ -z "$QCOW" ]]; then
    fail "No CoreOS QCOW2 image found in ${COREOS_IMAGE_DIR}"
    echo "  Download with:"
    echo "    podman run --pull=always --rm -v '${COREOS_IMAGE_DIR}:/data' -w /data \\"
    echo "      quay.io/coreos/coreos-installer:release download -s stable -p proxmoxve -f qcow2.xz --decompress"
    exit 1
fi
pass "CoreOS image: $(basename ${QCOW})"

# Ignition file
if [[ ! -f "${IGN_PATH}" ]]; then
    fail "Ignition file not found: ${IGN_PATH}"
    echo ""
    echo "  Transpile and copy from workstation:"
    echo "    podman run --rm -i quay.io/coreos/butane:release --pretty --strict \\"
    echo "      < authentik.bu > authentik.ign"
    echo "    scp authentik.ign ${PVE_HOST}:${COREOS_SNIPPET_DIR}/"
    exit 1
fi
pass "Ignition file: ${IGN_PATH}"

# Proxmox coreos storage
if ! pvesm status | awk '{print $1}' | grep -qx "${COREOS_STORE_ID}"; then
    echo "  Creating Proxmox storage '${COREOS_STORE_ID}'..."
    mkdir -p "${COREOS_STORE_PATH}"/{images,snippets}
    pvesm add dir "${COREOS_STORE_ID}" --path "${COREOS_STORE_PATH}" --content images,snippets
fi
pass "Proxmox storage: ${COREOS_STORE_ID}"

# Directory mappings
for dirid in "${MAPPING_POSTGRES}" "${MAPPING_DATA}"; do
    if pvesh get "/cluster/mapping/dir/${dirid}" > /dev/null 2>&1; then
        pass "Directory mapping '${dirid}' exists"
    else
        fail "Directory mapping '${dirid}' not found"
        echo "  Run 02-create-directory-mappings.sh first."
        exit 1
    fi
done

# ── Create VM ────────────────────────────────────────────────────────────────
header "Creating VM-${VMID}"

echo "  Creating base VM..."
qm create ${VMID} \
    --name ${VM_NAME} \
    --machine q35 \
    --cores ${VM_CORES} \
    --memory ${VM_MEMORY} \
    --net0 "virtio,bridge=${VM_BRIDGE}" \
    --scsihw virtio-scsi-pci

echo "  Importing CoreOS disk..."
qm set ${VMID} --scsi0 "${VM_STORAGE}:0,import-from=${QCOW}"

echo "  Growing disk by ${VM_DISK_GROW}..."
qm resize ${VMID} scsi0 ${VM_DISK_GROW}

# Cloud-init drive (Ignition delivery)
qm set ${VMID} --ide2 "${VM_STORAGE}:cloudinit"

# Boot order
qm set ${VMID} --boot order=scsi0

# Serial console
qm set ${VMID} --serial0 socket --vga serial0

# Ignition via cloud-init vendor snippet
qm set ${VMID} --cicustom "vendor=${COREOS_STORE_ID}:snippets/${IGN_FILE}"
qm set ${VMID} --ciupgrade 0

# Start on boot
qm set ${VMID} --onboot 1

pass "VM-${VMID} base configuration complete"

# ── Attach virtiofs shares ───────────────────────────────────────────────────
header "Attaching virtiofs storage"

qm set ${VMID} -virtiofs0 "dirid=${MAPPING_POSTGRES},cache=always"
pass "virtiofs0 attached: ${MAPPING_POSTGRES} (PostgreSQL data)"

qm set ${VMID} -virtiofs1 "dirid=${MAPPING_DATA},cache=always"
pass "virtiofs1 attached: ${MAPPING_DATA} (Authentik /data)"

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
echo "    4. Create virtiofs systemd mount units"
echo "    5. Create Podman network + Quadlet container definitions"
echo "    6. Start PostgreSQL, Authentik server, Authentik worker"
echo ""
echo "  Wait ~3-4 minutes for first boot, then verify:"
echo "    ssh core@${VM_IP}"
echo "    sudo podman ps"
echo "    curl -s http://${VM_IP}:${AUTHENTIK_HTTP_PORT}/if/flow/initial-setup/"
echo ""
echo -e "${GRN}VM-${VMID} created and started.${NC}"
