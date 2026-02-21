#!/usr/bin/env bash
# =============================================================================
# 07-validate-prod.sh — Validate PROD VM-110 database services
# =============================================================================
# Run on: Workstation (proxima-centauri)
#
# Checks:
#   1. SSH connectivity
#   2. virtiofs mounts with correct SELinux context
#   3. All three containers running
#   4. Service port responses
#   5. Data presence (database list, node counts, collection counts)
#   6. Optional: compare with DEV (VM-210) if second IP provided
#
# Usage:
#   bash scripts/07-validate-prod.sh [prod_ip] [dev_ip]
#
# Examples:
#   bash scripts/07-validate-prod.sh                          # PROD only
#   bash scripts/07-validate-prod.sh 10.10.100.110            # PROD only
#   bash scripts/07-validate-prod.sh 10.10.100.110 10.10.100.200  # compare
#
# Set NEO4J_PASS environment variable for Neo4j node count checks.
# =============================================================================
set -euo pipefail

PROD_IP="${1:-10.10.100.110}"
DEV_IP="${2:-}"
NEO4J_PASS="${NEO4J_PASS:-}"

GRN='\033[0;32m'
RED='\033[0;31m'
YLW='\033[0;33m'
NC='\033[0m'

ERRORS=0

pass() { echo -e "  ${GRN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; ((ERRORS++)); }
warn() { echo -e "  ${YLW}!${NC} $1"; }

echo "============================================"
echo " Colossus PROD Validation"
echo " Target: ${PROD_IP}"
[[ -n "$DEV_IP" ]] && echo " Compare: ${DEV_IP} (DEV)"
echo "============================================"
echo ""

# --- SSH connectivity --------------------------------------------------------
echo "== SSH Connectivity =="
if ssh -o ConnectTimeout=5 core@${PROD_IP} 'hostname' > /dev/null 2>&1; then
    HOSTNAME=$(ssh core@${PROD_IP} 'hostname')
    pass "SSH OK — hostname: $HOSTNAME"
else
    fail "Cannot SSH to core@${PROD_IP}"
    echo "Cannot continue without SSH. Exiting."
    exit 1
fi

# --- virtiofs mounts ---------------------------------------------------------
echo ""
echo "== virtiofs Mounts =="
MOUNTS=$(ssh core@${PROD_IP} 'mount | grep virtiofs' || true)
for svc in postgres neo4j qdrant; do
    if echo "$MOUNTS" | grep -q "/var/mnt/data/${svc}"; then
        if echo "$MOUNTS" | grep "/var/mnt/data/${svc}" | grep -q "container_file_t"; then
            pass "/var/mnt/data/${svc} mounted with container_file_t"
        else
            fail "/var/mnt/data/${svc} mounted but MISSING container_file_t context"
        fi
    else
        fail "/var/mnt/data/${svc} NOT mounted"
    fi
done

# --- Container status --------------------------------------------------------
echo ""
echo "== Container Status =="
CONTAINERS=$(ssh core@${PROD_IP} 'sudo podman ps --format "{{.Names}} {{.Status}}"' || true)
for svc in colossus-postgres colossus-neo4j colossus-qdrant; do
    if echo "$CONTAINERS" | grep -q "$svc"; then
        STATUS=$(echo "$CONTAINERS" | grep "$svc" | awk '{$1=""; print $0}' | xargs)
        pass "$svc — $STATUS"
    else
        fail "$svc — NOT RUNNING"
    fi
done

# --- PostgreSQL checks -------------------------------------------------------
echo ""
echo "== PostgreSQL =="
PG_DBS=$(ssh core@${PROD_IP} \
    'sudo podman exec colossus-postgres psql -U postgres -t -c "\l"' 2>/dev/null || echo "FAILED")
if echo "$PG_DBS" | grep -q "colossus"; then
    pass "Database 'colossus' exists"
else
    fail "Database 'colossus' not found"
fi

PG_TABLES=$(ssh core@${PROD_IP} \
    "sudo podman exec colossus-postgres psql -U postgres -d colossus -t -c \"
    SELECT count(*) FROM pg_tables
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema');\"" 2>/dev/null | xargs || echo "0")
if [[ "$PG_TABLES" -gt 0 ]] 2>/dev/null; then
    pass "Table count: $PG_TABLES"
else
    fail "No tables found in colossus database"
fi

# --- Neo4j checks ------------------------------------------------------------
echo ""
echo "== Neo4j =="
NEO4J_HTTP=$(ssh core@${PROD_IP} 'curl -sf http://localhost:7474' 2>/dev/null || echo "FAILED")
if echo "$NEO4J_HTTP" | grep -qi "neo4j"; then
    pass "HTTP endpoint responding"
else
    fail "HTTP endpoint not responding"
fi

if [[ -n "$NEO4J_PASS" ]]; then
    NEO4J_COUNT=$(curl -sf -u "neo4j:${NEO4J_PASS}" \
        -H 'Content-Type: application/json' \
        -d '{"statements":[{"statement":"MATCH (n) RETURN count(n) AS total"}]}' \
        "http://${PROD_IP}:7474/db/neo4j/tx/commit" 2>/dev/null | \
        python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['data'][0]['row'][0])" 2>/dev/null || echo "FAILED")
    if [[ "$NEO4J_COUNT" != "FAILED" && "$NEO4J_COUNT" -gt 0 ]] 2>/dev/null; then
        pass "Node count: $NEO4J_COUNT"
    else
        warn "Could not get node count (check password or wait for startup)"
    fi
else
    warn "NEO4J_PASS not set — skipping node count check"
fi

# --- Qdrant checks -----------------------------------------------------------
echo ""
echo "== Qdrant =="
QDRANT_HEALTH=$(curl -sf "http://${PROD_IP}:6333/healthz" 2>/dev/null || echo "FAILED")
if [[ "$QDRANT_HEALTH" != "FAILED" ]]; then
    pass "Health endpoint OK"
else
    fail "Health endpoint not responding"
fi

QDRANT_COLLECTIONS=$(curl -sf "http://${PROD_IP}:6333/collections" 2>/dev/null || echo "FAILED")
if [[ "$QDRANT_COLLECTIONS" != "FAILED" ]]; then
    COLLECTION_COUNT=$(echo "$QDRANT_COLLECTIONS" | \
        python3 -c "import sys,json; print(len(json.load(sys.stdin)['result']['collections']))" 2>/dev/null || echo "0")
    pass "Collections: $COLLECTION_COUNT"

    # Check paper_chunks specifically
    POINTS=$(curl -sf "http://${PROD_IP}:6333/collections/paper_chunks" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['result']['points_count'])" 2>/dev/null || echo "0")
    if [[ "$POINTS" -gt 0 ]] 2>/dev/null; then
        pass "paper_chunks: $POINTS points"
    else
        warn "paper_chunks: 0 points (may need restore)"
    fi
else
    fail "Cannot list collections"
fi

# --- DEV comparison (optional) -----------------------------------------------
if [[ -n "$DEV_IP" ]]; then
    echo ""
    echo "== DEV vs PROD Comparison =="

    # PostgreSQL table count
    DEV_PG=$(ssh core@${DEV_IP} \
        "sudo podman exec colossus-postgres psql -U postgres -d colossus -t -c \"
        SELECT count(*) FROM pg_tables
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema');\"" 2>/dev/null | xargs || echo "?")
    if [[ "$PG_TABLES" == "$DEV_PG" ]]; then
        pass "PostgreSQL tables: DEV=$DEV_PG  PROD=$PG_TABLES (match)"
    else
        fail "PostgreSQL tables: DEV=$DEV_PG  PROD=$PG_TABLES (MISMATCH)"
    fi

    # Neo4j node count
    if [[ -n "$NEO4J_PASS" ]]; then
        DEV_NEO4J=$(curl -sf -u "neo4j:${NEO4J_PASS}" \
            -H 'Content-Type: application/json' \
            -d '{"statements":[{"statement":"MATCH (n) RETURN count(n) AS total"}]}' \
            "http://${DEV_IP}:7474/db/neo4j/tx/commit" 2>/dev/null | \
            python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['data'][0]['row'][0])" 2>/dev/null || echo "?")
        if [[ "$NEO4J_COUNT" == "$DEV_NEO4J" ]]; then
            pass "Neo4j nodes: DEV=$DEV_NEO4J  PROD=$NEO4J_COUNT (match)"
        else
            fail "Neo4j nodes: DEV=$DEV_NEO4J  PROD=$NEO4J_COUNT (MISMATCH)"
        fi
    fi

    # Qdrant point count
    DEV_POINTS=$(curl -sf "http://${DEV_IP}:6333/collections/paper_chunks" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['result']['points_count'])" 2>/dev/null || echo "?")
    if [[ "$POINTS" == "$DEV_POINTS" ]]; then
        pass "Qdrant points: DEV=$DEV_POINTS  PROD=$POINTS (match)"
    else
        fail "Qdrant points: DEV=$DEV_POINTS  PROD=$POINTS (MISMATCH)"
    fi
fi

# --- Summary ------------------------------------------------------------------
echo ""
echo "============================================"
if [[ $ERRORS -eq 0 ]]; then
    echo -e " ${GRN}All checks passed.${NC}"
else
    echo -e " ${RED}${ERRORS} check(s) failed.${NC}"
fi
echo "============================================"
exit $ERRORS
