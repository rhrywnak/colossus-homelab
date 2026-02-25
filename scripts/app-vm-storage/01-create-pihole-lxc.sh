#!/bin/bash
# 01-create-pihole-lxc.sh — Create Pi-hole LXC container on pve-3
# Run on: pve-3
set -euo pipefail

CTID=311
HOSTNAME=pihole
STORAGE=local-lvm
MEMORY=512
CORES=1
DISK_SIZE=8
IP="10.10.100.53/24"
GATEWAY="10.10.100.1"
BRIDGE="vmbr0"

# --- Template discovery ---
# Find the Debian 12 template automatically
TEMPLATE=$(ls /var/lib/vz/template/cache/debian-12-standard*.tar.zst 2>/dev/null | sort -V | tail -1)

if [ -z "$TEMPLATE" ]; then
    echo "ERROR: No Debian 12 template found."
    echo "Download one with:"
    echo "  pveam update"
    echo "  pveam download local debian-12-standard_12.7-1_amd64.tar.zst"
    echo ""
    echo "Available templates:"
    pveam list local
    exit 1
fi

TEMPLATE_REF="local:vztmpl/$(basename $TEMPLATE)"
echo "Using template: ${TEMPLATE_REF}"

# --- Pre-flight ---
echo ""
echo "=== Creating Pi-hole LXC container ==="
echo "  CTID:     ${CTID}"
echo "  Hostname: ${HOSTNAME}"
echo "  IP:       ${IP}"
echo "  Gateway:  ${GATEWAY}"
echo "  Memory:   ${MEMORY}MB"
echo "  Disk:     ${DISK_SIZE}GB"
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
    --swap 256 \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY}" \
    --nameserver "1.1.1.1" \
    --searchdomain "local" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 0

echo ""
echo "=== Container created ==="
echo ""
pct config $CTID
echo ""
echo "Next steps:"
echo "  1. Start:  pct start ${CTID}"
echo "  2. Enter:  pct enter ${CTID}"
echo "  3. Then follow the Pi-hole install steps in the runbook"
