#!/bin/bash
# ==============================================================================
# create-vm-120.sh — Create Colossus PROD Application VM on pve-1
# ==============================================================================
# Run on: pve-1
#
# Prerequisites:
#   - CoreOS QCOW2 image at /var/coreos/images/
#   - Ignition file at /var/coreos/snippets/colossus-prod-app1.ign
# ==============================================================================
set -euo pipefail

VMID=120
NAME="colossus-prod-app1"
STORAGE="local-lvm"
CORES=2
MEMORY=4096
DISK_GROW="20G"

# CoreOS image
QCOW=$(ls /var/coreos/images/fedora-coreos-*.qcow2 2>/dev/null | sort -V | tail -1)
IGN="/var/coreos/snippets/colossus-prod-app1.ign"

# ── Pre-flight checks ───────────────────────────────────────────────────────
echo "=== Creating Colossus PROD Application VM ==="
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
    echo "    < colossus-prod-app1.bu > colossus-prod-app1.ign"
    echo "  scp colossus-prod-app1.ign root@pve-1:/var/coreos/snippets/"
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

echo "Importing CoreOS disk..."
qm set $VMID --scsi0 "${STORAGE}:0,import-from=${QCOW}"

echo "Growing disk by ${DISK_GROW}..."
qm resize $VMID scsi0 +${DISK_GROW}

qm set $VMID --ide2 "${STORAGE}:cloudinit"
qm set $VMID --boot order=scsi0
qm set $VMID --serial0 socket --vga serial0
qm set $VMID --cicustom "vendor=coreos:snippets/colossus-prod-app1.ign"
qm set $VMID --ciupgrade 0
qm set $VMID --onboot 1

echo ""
echo "=== VM ${VMID} created ==="
echo ""
qm config $VMID
echo ""

echo "Starting VM..."
qm start $VMID

echo ""
echo "VM ${VMID} is starting. Wait ~3-5 minutes, then:"
echo "  ssh core@10.10.100.120"
echo ""
echo "Verify containers:"
echo "  ssh core@10.10.100.120 'sudo podman ps'"
echo ""
echo "Test endpoints:"
echo "  curl http://10.10.100.120:3403/health"
echo "  curl http://10.10.100.120:3403/api/status"
echo "  Open http://10.10.100.120:5473 in browser"
