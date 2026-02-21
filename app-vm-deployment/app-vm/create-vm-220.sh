#!/bin/bash
# ==============================================================================
# create-vm-220.sh — Create Colossus DEV Application VM on pve-2
# ==============================================================================
# Run on: pve-2
#
# Prerequisites:
#   - CoreOS QCOW2 image at /var/coreos/images/
#   - Ignition file at /var/coreos/snippets/colossus-dev-app1.ign
#   - Butane transpiled: butane --pretty --strict < colossus-dev-app1.bu > colossus-dev-app1.ign
# ==============================================================================
set -euo pipefail

VMID=220
NAME="colossus-dev-app1"
STORAGE="local-lvm"
CORES=2
MEMORY=4096
DISK_GROW="20G"

# CoreOS image — adjust version as needed
QCOW=$(ls /var/coreos/images/fedora-coreos-*.qcow2 2>/dev/null | sort -V | tail -1)
IGN="/var/coreos/snippets/colossus-dev-app1.ign"

# ── Pre-flight checks ───────────────────────────────────────────────────────
echo "=== Creating Colossus DEV Application VM ==="
echo ""
echo "  VMID:     ${VMID}"
echo "  Name:     ${NAME}"
echo "  Cores:    ${CORES}"
echo "  Memory:   ${MEMORY} MiB"
echo "  Disk:     base + ${DISK_GROW}"
echo ""

if [ -z "$QCOW" ]; then
    echo "ERROR: No CoreOS QCOW2 image found in /var/coreos/images/"
    echo "Download from: https://fedoraproject.org/coreos/download?stream=stable"
    exit 1
fi
echo "CoreOS image: ${QCOW}"

if [ ! -f "$IGN" ]; then
    echo "ERROR: Ignition file not found: ${IGN}"
    echo ""
    echo "Transpile with:"
    echo "  podman run --rm -i quay.io/coreos/butane:release --pretty --strict \\"
    echo "    < colossus-dev-app1.bu > colossus-dev-app1.ign"
    echo "  scp colossus-dev-app1.ign root@pve-2:/var/coreos/snippets/"
    exit 1
fi
echo "Ignition:   ${IGN}"
echo ""

if qm status $VMID &>/dev/null; then
    echo "ERROR: VMID ${VMID} already exists"
    qm status $VMID
    exit 1
fi

# ── Create VM ────────────────────────────────────────────────────────────────
echo "Creating VM..."
qm create $VMID \
    --name $NAME \
    --machine q35 \
    --cores $CORES \
    --memory $MEMORY \
    --net0 "virtio,bridge=vmbr0" \
    --scsihw virtio-scsi-pci

# Import CoreOS disk
echo "Importing CoreOS disk..."
qm set $VMID --scsi0 "${STORAGE}:0,import-from=${QCOW}"

# Grow disk
echo "Growing disk by ${DISK_GROW}..."
qm resize $VMID scsi0 +${DISK_GROW}

# Cloud-init drive (Ignition delivery)
qm set $VMID --ide2 "${STORAGE}:cloudinit"

# Boot order
qm set $VMID --boot order=scsi0

# Serial console
qm set $VMID --serial0 socket --vga serial0

# Ignition via cloud-init vendor snippet
qm set $VMID --cicustom "vendor=coreos:snippets/colossus-dev-app1.ign"
qm set $VMID --ciupgrade 0

# Enable start on boot
qm set $VMID --onboot 1

echo ""
echo "=== VM ${VMID} created ==="
echo ""
qm config $VMID
echo ""

# ── Start VM ────────────────────────────────────────────────────────────────
echo "Starting VM..."
qm start $VMID

echo ""
echo "VM ${VMID} is starting. First boot will:"
echo "  1. Apply Ignition config (network, users, container definitions)"
echo "  2. Install Python via rpm-ostree (triggers one reboot)"
echo "  3. Pull container images from ghcr.io"
echo "  4. Start colossus-backend and colossus-frontend services"
echo ""
echo "Wait ~3 minutes for first boot + reboot, then:"
echo "  ssh core@10.10.100.220"
echo ""
echo "Verify containers:"
echo "  ssh core@10.10.100.220 'sudo podman ps'"
echo "  ssh core@10.10.100.220 'sudo systemctl status colossus-backend colossus-frontend'"
echo ""
echo "Test endpoints:"
echo "  curl http://10.10.100.220:3403/health"
echo "  curl http://10.10.100.220:3403/api/status"
echo "  Open http://10.10.100.220:5473 in browser"
