#!/bin/bash
# ==============================================================================
# 01-create-traefik-lxc.sh — Create CT-313 (Traefik) LXC on pve-3
# ==============================================================================
# Run this script on pve-3 as root.
# Pattern matches CT-311 (Pi-hole) and CT-312 (cloudflared) creation scripts.
# ==============================================================================

set -euo pipefail

# --- Configuration ---
CTID=313
HOSTNAME="traefik"
STORAGE="local-lvm"
MEMORY=256
SWAP=256
CORES=1
DISK_SIZE=4
IP="10.10.100.55/24"
GATEWAY="10.10.100.1"
DNS_SERVER="10.10.100.53"
BRIDGE="vmbr0"

# --- Template discovery (match whatever Debian 12 version is cached) ---
TEMPLATE=$(ls /var/lib/vz/template/cache/debian-12-standard*.tar.zst 2>/dev/null | sort -V | tail -1)

if [ -z "$TEMPLATE" ]; then
    echo "ERROR: No Debian 12 template found."
    echo "  pveam update"
    echo "  pveam download local debian-12-standard_12.12-1_amd64.tar.zst"
    exit 1
fi

TEMPLATE_REF="local:vztmpl/$(basename $TEMPLATE)"

# --- Pre-flight checks ---
echo "=== Creating CT-${CTID} (${HOSTNAME}) ==="
echo ""
echo "  CTID:     ${CTID}"
echo "  Hostname: ${HOSTNAME}"
echo "  IP:       ${IP}"
echo "  Gateway:  ${GATEWAY}"
echo "  Memory:   ${MEMORY}MB"
echo "  Disk:     ${DISK_SIZE}GB"
echo "  DNS:      ${DNS_SERVER}"
echo "  Template: ${TEMPLATE_REF}"
echo ""

if pct status "$CTID" &>/dev/null; then
    echo "ERROR: CT-${CTID} already exists"
    pct status "$CTID"
    exit 1
fi

# --- Create container ---
pct create "$CTID" "$TEMPLATE_REF" \
    --hostname "$HOSTNAME" \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY}" \
    --nameserver "$DNS_SERVER" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 0

echo ""
echo "=== CT-${CTID} created successfully ==="
echo ""

# --- Start container ---
echo "=== Starting CT-${CTID} ==="
pct start "$CTID"
sleep 3

# --- Verify ---
echo ""
echo "=== Verification ==="
pct status "$CTID"
echo ""

# Test network connectivity from inside the container
echo "Testing network connectivity..."
pct exec "$CTID" -- ping -c 2 -W 3 10.10.100.1 > /dev/null 2>&1 && \
    echo "  Gateway (10.10.100.1): OK" || \
    echo "  Gateway (10.10.100.1): FAILED"

pct exec "$CTID" -- ping -c 2 -W 3 1.1.1.1 > /dev/null 2>&1 && \
    echo "  Internet (1.1.1.1): OK" || \
    echo "  Internet (1.1.1.1): FAILED"

echo ""
echo "=== CT-${CTID} (${HOSTNAME}) ready ==="
echo ""
echo "Next step: Run 02-install-traefik.sh inside the container:"
echo "  pct enter ${CTID}"
echo "  # then run the script inside"
echo ""
echo "Or push and execute remotely:"
echo "  pct push ${CTID} 02-install-traefik.sh /root/02-install-traefik.sh"
echo "  pct exec ${CTID} -- bash /root/02-install-traefik.sh"
