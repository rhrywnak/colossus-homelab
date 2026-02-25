#!/bin/bash
# ==============================================================================
# 02-install-traefik.sh — Install and configure Traefik v3 inside CT-313
# ==============================================================================
# Run this script inside CT-313 as root.
# Prerequisites: CT-313 created and running (01-create-traefik-lxc.sh)
# ==============================================================================

set -euo pipefail

# --- Configuration ---
TRAEFIK_VERSION="v3.3.3"
ACME_EMAIL="Roman.hrywnak@gmail.com"

# Backend targets
PROD_FRONTEND="http://10.10.100.120:5473"
PROD_API="http://10.10.100.120:3403"
DEV_FRONTEND="http://10.10.100.220:5473"
DEV_API="http://10.10.100.220:3403"

# --- Pre-flight checks ---
echo "=== Pre-flight checks ==="

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Check for Cloudflare API token
if [[ -z "${CF_DNS_API_TOKEN:-}" ]]; then
    echo ""
    echo "Cloudflare API token is required for DNS-01 ACME challenge."
    echo "Create one at: https://dash.cloudflare.com/profile/api-tokens"
    echo "  Template: Edit zone DNS"
    echo "  Scope: Zone → cogmai.com only"
    echo ""
    read -rsp "Paste your Cloudflare API token: " CF_DNS_API_TOKEN
    echo ""

    if [[ -z "$CF_DNS_API_TOKEN" ]]; then
        echo "ERROR: No token provided"
        exit 1
    fi
fi

echo "All pre-flight checks passed"
echo ""

# --- System update ---
echo "=== Updating system packages ==="
apt update && apt upgrade -y
apt install -y curl wget ca-certificates
echo ""

# --- Install Traefik binary ---
echo "=== Installing Traefik ${TRAEFIK_VERSION} ==="

wget -q "https://github.com/traefik/traefik/releases/download/${TRAEFIK_VERSION}/traefik_${TRAEFIK_VERSION}_linux_amd64.tar.gz" \
    -O /tmp/traefik.tar.gz

tar -xzf /tmp/traefik.tar.gz -C /usr/local/bin/ traefik
chmod +x /usr/local/bin/traefik
rm /tmp/traefik.tar.gz

echo "Installed: $(traefik version 2>&1 | head -1)"
echo ""

# --- Create directory structure ---
echo "=== Creating directory structure ==="
mkdir -p /etc/traefik/dynamic
mkdir -p /var/log/traefik

# acme.json — Let's Encrypt cert storage (strict perms required)
touch /etc/traefik/acme.json
chmod 600 /etc/traefik/acme.json

echo "  /etc/traefik/           — config root"
echo "  /etc/traefik/dynamic/   — hot-reload configs"
echo "  /var/log/traefik/       — logs"
echo "  /etc/traefik/acme.json  — cert storage (600)"
echo ""

# --- Write Cloudflare API token ---
echo "=== Writing Cloudflare token ==="
cat > /etc/traefik/cloudflare.env << EOF
CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN}
EOF
chmod 600 /etc/traefik/cloudflare.env
echo "  /etc/traefik/cloudflare.env (600)"
echo ""

# --- Static configuration ---
echo "=== Writing static configuration (traefik.yml) ==="
cat > /etc/traefik/traefik.yml << EOF
# ==============================================================================
# Traefik v3 Static Configuration — CT-313
# ==============================================================================
# Changes to this file require: systemctl restart traefik
# ==============================================================================

api:
  dashboard: true
  insecure: true

entryPoints:
  http:
    address: ":80"
  https:
    address: ":443"
    http:
      tls: {}

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: "${ACME_EMAIL}"
      storage: /etc/traefik/acme.json
      caServer: "https://acme-v02.api.letsencrypt.org/directory"
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "1.0.0.1:53"

log:
  level: INFO
  filePath: /var/log/traefik/traefik.log

accessLog:
  filePath: /var/log/traefik/access.log
EOF
echo "  /etc/traefik/traefik.yml"
echo ""

# --- Dynamic TLS configuration ---
echo "=== Writing dynamic TLS config ==="
cat > /etc/traefik/dynamic/tls.yml << 'EOF'
# TLS options — hot-reload (no restart needed)
tls:
  options:
    default:
      minVersion: VersionTLS12
EOF
echo "  /etc/traefik/dynamic/tls.yml"
echo ""

# --- Dynamic services configuration ---
echo "=== Writing dynamic services config ==="
cat > /etc/traefik/dynamic/services.yml << EOF
# ==============================================================================
# Traefik Dynamic Configuration — Routers & Services
# ==============================================================================
# This file is hot-reloaded. No restart needed after changes.
# To add a new app: add a router + service block below.
# ==============================================================================

http:
  # ============================================================
  # MIDDLEWARES
  # ============================================================
  middlewares:
    # Redirect HTTP to HTTPS (LAN browsers only — see priority notes)
    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true

  # ============================================================
  # ROUTERS
  # ============================================================
  routers:

    # --- HTTP catch-all: redirect LAN browsers to HTTPS ---
    # Priority 1 (lowest) — named routers on specific entrypoints take precedence
    http-catchall:
      rule: "HostRegexp(\`.+\`)"
      entryPoints:
        - http
      middlewares:
        - redirect-to-https
      service: noop@internal
      priority: 1

    # --- HTTP routers for Cloudflare Tunnel traffic (no redirect) ---
    # Tunnel sends HTTP to port 80. Without these, the catch-all would
    # redirect to HTTPS, creating an infinite loop.
    colossus-legal-frontend-http:
      rule: "Host(\`colossus-legal.cogmai.com\`)"
      entryPoints:
        - http
      service: colossus-legal-frontend
      priority: 10

    colossus-legal-api-http:
      rule: "Host(\`colossus-legal-api.cogmai.com\`)"
      entryPoints:
        - http
      service: colossus-legal-api
      priority: 10

    # --- Colossus-Legal Frontend (PROD) ---
    colossus-legal-frontend:
      rule: "Host(\`colossus-legal.cogmai.com\`)"
      entryPoints:
        - https
      service: colossus-legal-frontend
      tls:
        certResolver: letsencrypt
        domains:
          - main: "*.cogmai.com"
            sans:
              - "cogmai.com"

    # --- Colossus-Legal API (PROD) ---
    colossus-legal-api:
      rule: "Host(\`colossus-legal-api.cogmai.com\`)"
      entryPoints:
        - https
      service: colossus-legal-api
      tls:
        certResolver: letsencrypt
        domains:
          - main: "*.cogmai.com"
            sans:
              - "cogmai.com"

    # --- Colossus-Legal Frontend (DEV) ---
    colossus-legal-dev:
      rule: "Host(\`colossus-legal-dev.cogmai.com\`)"
      entryPoints:
        - https
      service: colossus-legal-dev
      tls:
        certResolver: letsencrypt
        domains:
          - main: "*.cogmai.com"
            sans:
              - "cogmai.com"

    # --- Colossus-Legal API (DEV) ---
    colossus-legal-api-dev:
      rule: "Host(\`colossus-legal-api-dev.cogmai.com\`)"
      entryPoints:
        - https
      service: colossus-legal-api-dev
      tls:
        certResolver: letsencrypt
        domains:
          - main: "*.cogmai.com"
            sans:
              - "cogmai.com"

    # --- Traefik Dashboard (HTTPS via LAN) ---
    traefik-dashboard:
      rule: "Host(\`traefik.cogmai.com\`)"
      entryPoints:
        - https
      service: api@internal
      tls:
        certResolver: letsencrypt
        domains:
          - main: "*.cogmai.com"
            sans:
              - "cogmai.com"

  # ============================================================
  # SERVICES (backend targets)
  # ============================================================
  services:
    colossus-legal-frontend:
      loadBalancer:
        servers:
          - url: "${PROD_FRONTEND}"

    colossus-legal-api:
      loadBalancer:
        servers:
          - url: "${PROD_API}"

    colossus-legal-dev:
      loadBalancer:
        servers:
          - url: "${DEV_FRONTEND}"

    colossus-legal-api-dev:
      loadBalancer:
        servers:
          - url: "${DEV_API}"
EOF
echo "  /etc/traefik/dynamic/services.yml"
echo ""

# --- Systemd service ---
echo "=== Creating systemd service ==="
cat > /etc/systemd/system/traefik.service << 'EOF'
[Unit]
Description=Traefik Reverse Proxy
Documentation=https://doc.traefik.io/traefik/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=/etc/traefik/cloudflare.env
ExecStart=/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/traefik/acme.json /var/log/traefik

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable traefik
echo "  /etc/systemd/system/traefik.service (enabled)"
echo ""

# --- Start Traefik ---
echo "=== Starting Traefik ==="
systemctl start traefik
sleep 5

# --- Verification ---
echo ""
echo "=== Verification ==="

# Service status
if systemctl is-active --quiet traefik; then
    echo "  Service: RUNNING"
else
    echo "  Service: FAILED"
    echo ""
    echo "Check logs with: journalctl -u traefik --no-pager -n 50"
    exit 1
fi

# Dashboard reachable
if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/api/overview | grep -q "200"; then
    echo "  Dashboard API: OK (port 8080)"
else
    echo "  Dashboard API: NOT RESPONDING (may need a moment for startup)"
fi

# Certificate status (may take 10-30 seconds for first request)
ACME_SIZE=$(stat -c%s /etc/traefik/acme.json 2>/dev/null || echo "0")
if [[ "$ACME_SIZE" -gt 100 ]]; then
    echo "  Certificate: OBTAINED (acme.json = ${ACME_SIZE} bytes)"
else
    echo "  Certificate: PENDING (acme.json = ${ACME_SIZE} bytes)"
    echo "    This is normal — cert request takes 10-30 seconds."
    echo "    Monitor with: journalctl -u traefik -f | grep -i acme"
fi

echo ""
echo "============================================================"
echo "  CT-313 Traefik installation complete!"
echo "============================================================"
echo ""
echo "  Dashboard: http://10.10.100.55:8080"
echo ""
echo "  Next steps (see execution runbook):"
echo "    1. Wait for Let's Encrypt certificate (check logs)"
echo "    2. Update Pi-hole DNS records → 10.10.100.55"
echo "    3. Test internal HTTPS access"
echo "    4. Update Cloudflare Tunnel routes"
echo "    5. Test external access"
echo ""
echo "  Key commands:"
echo "    systemctl status traefik"
echo "    journalctl -u traefik -f"
echo "    cat /var/log/traefik/traefik.log"
echo ""
