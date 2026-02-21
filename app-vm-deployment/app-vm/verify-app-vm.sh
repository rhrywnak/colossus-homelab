#!/bin/bash
# ==============================================================================
# verify-app-vm.sh — Validate Colossus-Legal application deployment
# ==============================================================================
# Run from: workstation
# Usage: ./verify-app-vm.sh [app-vm-ip] [db-vm-ip]
# ==============================================================================
set -e

APP_IP="${1:-10.10.100.220}"
DB_IP="${2:-10.10.100.200}"

echo "==========================================="
echo " Colossus-Legal App VM Verification"
echo " App VM: ${APP_IP}"
echo " DB VM:  ${DB_IP}"
echo "==========================================="
echo ""

PASS=0
FAIL=0
WARN=0

check_pass() { echo "  ✓ $1"; ((PASS++)); }
check_fail() { echo "  ✗ $1"; ((FAIL++)); }
check_warn() { echo "  ⚠ $1"; ((WARN++)); }

# --- VM reachability ---
echo "Connectivity:"
if ping -c 1 -W 2 "$APP_IP" &>/dev/null; then
    check_pass "Ping ${APP_IP} reachable"
else
    check_fail "Ping ${APP_IP} unreachable — VM may still be booting"
    echo ""
    echo "  If first boot, wait 3-5 minutes (Python install + reboot)"
    echo "  Check: qm status 220"
    exit 1
fi

# --- SSH ---
echo ""
echo "SSH Access:"
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no core@${APP_IP} 'echo ok' &>/dev/null; then
    check_pass "SSH to core@${APP_IP}"
else
    check_fail "SSH failed — may still be in first-boot reboot"
fi

# --- Containers running ---
echo ""
echo "Containers:"
CONTAINERS=$(ssh -o ConnectTimeout=5 core@${APP_IP} 'sudo podman ps --format "{{.Names}}" 2>/dev/null' 2>/dev/null || echo "")
if echo "$CONTAINERS" | grep -q "colossus-backend"; then
    check_pass "colossus-backend container running"
else
    check_fail "colossus-backend container NOT running"
    echo "  Check: ssh core@${APP_IP} 'sudo systemctl status colossus-backend'"
    echo "  Logs:  ssh core@${APP_IP} 'sudo podman logs colossus-backend'"
fi

if echo "$CONTAINERS" | grep -q "colossus-frontend"; then
    check_pass "colossus-frontend container running"
else
    check_fail "colossus-frontend container NOT running"
    echo "  Check: ssh core@${APP_IP} 'sudo systemctl status colossus-frontend'"
    echo "  Logs:  ssh core@${APP_IP} 'sudo podman logs colossus-frontend'"
fi

# --- Backend health ---
echo ""
echo "Backend API:"
HEALTH=$(curl -sf --connect-timeout 5 "http://${APP_IP}:3403/health" 2>/dev/null || echo "")
if [ "$HEALTH" = "OK" ]; then
    check_pass "GET /health → OK"
else
    check_fail "GET /health failed (got: '${HEALTH}')"
fi

STATUS=$(curl -sf --connect-timeout 5 "http://${APP_IP}:3403/api/status" 2>/dev/null || echo "")
if echo "$STATUS" | grep -q '"status":"ok"'; then
    check_pass "GET /api/status → ok"
else
    check_fail "GET /api/status failed"
fi

# --- Backend can reach DB ---
echo ""
echo "Database Connectivity (via backend):"
CLAIMS=$(curl -sf --connect-timeout 10 "http://${APP_IP}:3403/claims" 2>/dev/null || echo "")
if [ -n "$CLAIMS" ] && [ "$CLAIMS" != "null" ]; then
    COUNT=$(echo "$CLAIMS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
    check_pass "GET /claims returned ${COUNT} records (Neo4j reachable)"
else
    check_fail "GET /claims failed — backend may not be able to reach Neo4j at ${DB_IP}:7687"
    echo "  Check backend logs: ssh core@${APP_IP} 'sudo podman logs colossus-backend'"
fi

# --- Frontend serving ---
echo ""
echo "Frontend:"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://${APP_IP}:5473/" 2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
    check_pass "Frontend accessible (HTTP ${HTTP_CODE})"
else
    check_fail "Frontend not accessible (HTTP ${HTTP_CODE})"
fi

# Check that config.js has correct API URL
CONFIG_JS=$(curl -sf --connect-timeout 5 "http://${APP_IP}:5473/config.js" 2>/dev/null || echo "")
if echo "$CONFIG_JS" | grep -q "${APP_IP}:3403"; then
    check_pass "config.js points to correct backend (${APP_IP}:3403)"
else
    check_warn "config.js may have wrong API URL"
    echo "  Got: ${CONFIG_JS}"
fi

# --- Summary ---
echo ""
echo "==========================================="
echo " Results: ${PASS} passed, ${FAIL} failed, ${WARN} warnings"
echo "==========================================="
echo ""

if [ $FAIL -gt 0 ]; then
    echo "Some checks failed. Review output above."
    echo ""
    echo "Common troubleshooting:"
    echo "  ssh core@${APP_IP} 'sudo podman ps -a'          # All containers"
    echo "  ssh core@${APP_IP} 'sudo podman logs colossus-backend'   # Backend logs"
    echo "  ssh core@${APP_IP} 'sudo podman logs colossus-frontend'  # Frontend logs"
    echo "  ssh core@${APP_IP} 'sudo systemctl list-units colossus*' # Service status"
    exit 1
else
    echo "Colossus-Legal DEV deployment is healthy!"
    echo ""
    echo "  Backend API:  http://${APP_IP}:3403"
    echo "  Frontend UI:  http://${APP_IP}:5473"
    echo "  SSH:          ssh core@${APP_IP}"
fi
