#!/bin/bash
# ==============================================================================
# 01-create-cloudflared-lxc.sh — Create cloudflared tunnel LXC on pve-3
# ==============================================================================
# Run on: pve-3
# ==============================================================================
set -euo pipefail

CTID=312
HOSTNAME=cloudflared
STORAGE=local-lvm
MEMORY=256
CORES=1
DISK_SIZE=4
IP="10.10.100.54/24"
GATEWAY="10.10.100.1"
BRIDGE="vmbr0"

# --- Template discovery ---
TEMPLATE=$(ls /var/lib/vz/template/cache/debian-12-standard*.tar.zst 2>/dev/null | sort -V | tail -1)

if [ -z "$TEMPLATE" ]; then
    echo "ERROR: No Debian 12 template found."
    echo "  pveam update"
    echo "  pveam download local debian-12-standard_12.12-1_amd64.tar.zst"
    exit 1
fi

TEMPLATE_REF="local:vztmpl/$(basename $TEMPLATE)"

# --- Pre-flight ---
echo "=== Creating cloudflared LXC Container ==="
echo ""
echo "  CTID:     ${CTID}"
echo "  Hostname: ${HOSTNAME}"
echo "  IP:       ${IP}"
echo "  Gateway:  ${GATEWAY}"
echo "  Memory:   ${MEMORY}MB"
echo "  Disk:     ${DISK_SIZE}GB"
echo "  Template: ${TEMPLATE_REF}"
echo ""

if pct status $CTID &>/dev/null; then
    echo "ERROR: CTID ${CTID} already exists"
    pct status $CTID
    exit 1
fi

# --- Create container ---
pct create $CTID "$TEMPLATE_REF" \
    --hostname $HOSTNAME \
    --storage $STORAGE \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --cores $CORES \
    --memory $MEMORY \
    --swap 128 \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY}" \
    --nameserver "1.1.1.1" \
    --searchdomain "local" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 0

echo ""
echo "=== Container ${CTID} created ==="
echo ""

# --- Start ---
echo "Starting container..."
pct start $CTID
sleep 3

if ! pct status $CTID | grep -q "running"; then
    echo "ERROR: Container failed to start"
    exit 1
fi

echo "Container is running."
echo ""
echo "=== Next Step ==="
echo "  pct push ${CTID} 02-install-cloudflared.sh /root/02-install-cloudflared.sh"
echo "  pct exec ${CTID} -- bash /root/02-install-cloudflared.sh"
