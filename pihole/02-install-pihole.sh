#!/bin/bash
# 02-install-pihole.sh — Install Pi-hole inside LXC container
# Run INSIDE the container: pct enter 311, then run this script
set -euo pipefail

echo "=== Installing Pi-hole ==="
echo ""

# --- Prerequisites ---
echo "Installing prerequisites..."
apt update && apt upgrade -y
apt install -y curl

# --- Pi-hole setup variables (unattended install) ---
echo "Writing Pi-hole configuration..."
mkdir -p /etc/pihole

cat > /etc/pihole/setupVars.conf << 'SETUPVARS'
PIHOLE_INTERFACE=eth0
PIHOLE_DNS_1=1.1.1.1
PIHOLE_DNS_2=1.0.0.1
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=false
DNS_BOGUS_PRIV=true
DNSSEC=false
REV_SERVER=false
BLOCKING_ENABLED=true
WEBPASSWORD=
SETUPVARS

# --- Install Pi-hole ---
echo ""
echo "Running Pi-hole installer (unattended)..."
echo "This takes 1-3 minutes..."
echo ""
curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended

# --- Set admin password ---
echo ""
echo "=== Pi-hole installed ==="
echo ""
echo "Set your admin password now:"
pihole -a -p

# --- Add initial local DNS records ---
echo ""
echo "Adding initial local DNS records..."

# Only add if custom.list doesn't already have entries
if [ ! -f /etc/pihole/custom.list ] || [ ! -s /etc/pihole/custom.list ]; then
    cat > /etc/pihole/custom.list << 'DNSRECORDS'
# Colossus Infrastructure — Local DNS
# Update IPs below to match your actual environment
10.10.100.3   pve-1.lab
10.10.100.4   pve-2.lab
10.10.100.5   pve-3.lab
10.10.100.110 colossus-prod-db1.lab
10.10.100.200 colossus-dev-db1.lab
10.10.100.50  colossus-db1-dev.lab
10.10.100.53  pihole.lab
DNSRECORDS

    pihole restartdns
    echo "Local DNS records added. Edit /etc/pihole/custom.list to adjust."
else
    echo "custom.list already has entries — skipping."
fi

# --- Status ---
echo ""
echo "==========================================="
echo " Pi-hole Installation Complete"
echo "==========================================="
echo ""
pihole status
echo ""
echo "Listening on:"
ss -tlnp | grep -E '(53|80)' || echo "  (check manually with: ss -tlnp)"
echo ""
echo "Web admin:  http://10.10.100.53/admin/"
echo ""
echo "Next: Exit this container and test from your workstation:"
echo "  dig @10.10.100.53 google.com +short"
echo "  dig @10.10.100.53 pihole.lab +short"
echo "  curl http://10.10.100.53/admin/"
