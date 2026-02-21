#!/bin/bash
# ==============================================================================
# 02-install-cloudflared.sh — Install cloudflared tunnel connector
# ==============================================================================
# Run INSIDE CT-312:
#   pct push 312 02-install-cloudflared.sh /root/02-install-cloudflared.sh
#   pct exec 312 -- bash /root/02-install-cloudflared.sh
#
# You will be prompted for the tunnel token from the Cloudflare dashboard.
# ==============================================================================
set -euo pipefail

echo "==========================================="
echo " cloudflared Tunnel Installation"
echo "==========================================="
echo ""

# ── Get tunnel token ─────────────────────────────────────────────────────────
if [ -z "${TUNNEL_TOKEN:-}" ]; then
    echo "Enter your Cloudflare Tunnel token"
    echo "(the long string starting with 'ey...' from the dashboard):"
    echo ""
    read -r -p "Token: " TUNNEL_TOKEN
    echo ""
fi

if [ -z "$TUNNEL_TOKEN" ]; then
    echo "ERROR: No token provided."
    exit 1
fi

# ── Install cloudflared ──────────────────────────────────────────────────────
echo "[1/3] Installing cloudflared..."
apt-get update -qq
apt-get install -y -qq curl gnupg

# Add Cloudflare GPG key and repo
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null

echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' \
    | tee /etc/apt/sources.list.d/cloudflared.list

apt-get update -qq
apt-get install -y -qq cloudflared

echo "  ✓ cloudflared $(cloudflared --version 2>&1 | head -1)"

# ── Install as systemd service ───────────────────────────────────────────────
echo ""
echo "[2/3] Configuring cloudflared service..."

cloudflared service install "$TUNNEL_TOKEN"

echo "  ✓ Service installed"

# ── Start and enable ─────────────────────────────────────────────────────────
echo ""
echo "[3/3] Starting cloudflared..."

systemctl enable cloudflared
systemctl start cloudflared

sleep 3

# ── Verify ───────────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
echo " cloudflared Installation Complete"
echo "==========================================="
echo ""

if systemctl is-active --quiet cloudflared; then
    echo "  ✓ cloudflared service is running"
else
    echo "  ✗ cloudflared service failed to start"
    echo "    Check: systemctl status cloudflared"
    echo "    Logs:  journalctl -u cloudflared --no-pager -n 50"
    exit 1
fi

echo ""
echo "Service status:"
systemctl status cloudflared --no-pager -l | head -15
echo ""
echo "Next steps:"
echo "  1. Check Cloudflare dashboard — tunnel should show 'Healthy'"
echo "  2. Test from phone (cellular): https://colossus-legal.cogmai.com"
echo "  3. Add more public hostnames in Cloudflare dashboard as needed"
echo ""
echo "Management:"
echo "  systemctl status cloudflared    # Check status"
echo "  systemctl restart cloudflared   # Restart"
echo "  journalctl -u cloudflared -f    # Tail logs"
