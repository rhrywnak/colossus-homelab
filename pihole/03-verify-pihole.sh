#!/bin/bash
# 03-verify-pihole.sh — Validate Pi-hole deployment
# Run from: workstation (proxima-centauri)
set -e

PIHOLE_IP="${1:-10.10.100.53}"

echo "==========================================="
echo " Pi-hole Verification — ${PIHOLE_IP}"
echo "==========================================="
echo ""

PASS=0
FAIL=0
WARN=0

check_pass() { echo "  ✓ $1"; ((PASS++)); }
check_fail() { echo "  ✗ $1"; ((FAIL++)); }
check_warn() { echo "  ⚠ $1"; ((WARN++)); }

# --- DNS resolution (external domain) ---
echo "DNS Resolution:"
RESULT=$(dig @${PIHOLE_IP} google.com +short +time=5 2>/dev/null | head -1)
if [ -n "$RESULT" ]; then
    check_pass "External DNS: google.com → ${RESULT}"
else
    check_fail "External DNS: google.com — no response"
fi

# --- DNS resolution (internal record) ---
RESULT=$(dig @${PIHOLE_IP} pihole.lab +short +time=5 2>/dev/null)
if [ "$RESULT" = "${PIHOLE_IP}" ]; then
    check_pass "Internal DNS: pihole.lab → ${RESULT}"
else
    check_fail "Internal DNS: pihole.lab — got '${RESULT}' (expected ${PIHOLE_IP})"
fi

# --- Check a few more internal records ---
for RECORD in pve-1.lab pve-2.lab pve-3.lab; do
    RESULT=$(dig @${PIHOLE_IP} ${RECORD} +short +time=5 2>/dev/null)
    if [ -n "$RESULT" ]; then
        check_pass "Internal DNS: ${RECORD} → ${RESULT}"
    else
        check_warn "Internal DNS: ${RECORD} — not found (may need to add)"
    fi
done

# --- Web admin accessible ---
echo ""
echo "Web Admin:"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://${PIHOLE_IP}/admin/" 2>/dev/null)
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ]; then
    check_pass "Web admin UI accessible (HTTP ${HTTP_CODE})"
else
    check_fail "Web admin UI not accessible (HTTP ${HTTP_CODE})"
fi

# --- Ad blocking ---
echo ""
echo "Ad Blocking:"
# Test a known tracking domain
BLOCKED=$(dig @${PIHOLE_IP} analytics.google.com +short +time=5 2>/dev/null | head -1)
if echo "$BLOCKED" | grep -qE "^0\.0\.0\.0$"; then
    check_pass "Blocking active: analytics.google.com → 0.0.0.0"
elif [ -z "$BLOCKED" ]; then
    check_warn "Blocking inconclusive: analytics.google.com returned empty (may be NXDOMAIN blocking)"
else
    check_warn "Not blocking analytics.google.com (${BLOCKED}) — update gravity: pihole -g"
fi

# --- Response time ---
echo ""
echo "Performance:"
TIME=$(dig @${PIHOLE_IP} github.com +time=5 2>/dev/null | grep "Query time" | awk '{print $4}')
if [ -n "$TIME" ]; then
    if [ "$TIME" -lt 100 ]; then
        check_pass "Query time: ${TIME}ms (good)"
    else
        check_warn "Query time: ${TIME}ms (first query may be slow, retry to check cache)"
    fi
else
    check_warn "Could not measure query time"
fi

# --- Summary ---
echo ""
echo "==========================================="
echo " Results: ${PASS} passed, ${FAIL} failed, ${WARN} warnings"
echo "==========================================="
echo ""

if [ $FAIL -gt 0 ]; then
    echo "⚠  Some checks failed. Review output above."
    exit 1
else
    echo "Pi-hole is operational."
    echo ""
    echo "Web admin: http://${PIHOLE_IP}/admin/"
    echo ""
    echo "Next steps:"
    echo "  1. Log into web admin and review settings"
    echo "  2. Update gravity: pct exec 311 -- pihole -g"
    echo "  3. Switch lab VLAN DNS to ${PIHOLE_IP} in UDM"
    echo "  4. Run stability test (stop Pi-hole, verify family internet works)"
fi
