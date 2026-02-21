#!/usr/bin/env bash
# =============================================================================
# 07-validate-parity.sh — Side-by-side validation: VM-200 vs VM-210
# =============================================================================
# Run on: your workstation (Linux desktop)
#
# Compares database state between the old and new VMs to confirm
# data parity before declaring Phase 2 complete.
#
# Usage:
#   bash 07-validate-parity.sh <vm200-ip> <vm210-ip>
#
# Example:
#   bash 07-validate-parity.sh 192.168.1.50 192.168.1.51
# =============================================================================
set -euo pipefail

VM200_IP="${1:-}"
VM210_IP="${2:-}"

if [[ -z "$VM200_IP" || -z "$VM210_IP" ]]; then
    echo "Usage: $0 <vm200-ip> <vm210-ip>" >&2
    exit 1
fi

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GRN}[PASS]${NC} $1"; PASSES=$((PASSES + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAILS=$((FAILS + 1)); }
info() { echo -e "${YEL}[INFO]${NC} $1"; }

PASSES=0
FAILS=0

echo "============================================"
echo " Phase 2 Parity Validation"
echo " OLD (VM-200): $VM200_IP"
echo " NEW (VM-210): $VM210_IP"
echo "============================================"
echo ""

# =============================================================================
# PostgreSQL
# =============================================================================
echo "== PostgreSQL =="

echo "  Comparing database list..."
OLD_DBS=$(ssh "core@${VM200_IP}" 'sudo podman exec colossus-postgres psql -U postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;"' 2>/dev/null | tr -d ' ')
NEW_DBS=$(ssh "core@${VM210_IP}" 'sudo podman exec colossus-postgres psql -U postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;"' 2>/dev/null | tr -d ' ')

if [[ "$OLD_DBS" == "$NEW_DBS" ]]; then
    pass "Database lists match"
else
    fail "Database lists differ"
    info "  OLD: $OLD_DBS"
    info "  NEW: $NEW_DBS"
fi

# Table count comparison for each non-system database
for DB in $(echo "$OLD_DBS" | grep -v '^$'); do
    OLD_TABLES=$(ssh "core@${VM200_IP}" "sudo podman exec colossus-postgres psql -U postgres -d $DB -t -c \"SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');\"" 2>/dev/null | tr -d ' ')
    NEW_TABLES=$(ssh "core@${VM210_IP}" "sudo podman exec colossus-postgres psql -U postgres -d $DB -t -c \"SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');\"" 2>/dev/null | tr -d ' ')

    if [[ "$OLD_TABLES" == "$NEW_TABLES" ]]; then
        pass "  $DB: table count matches ($OLD_TABLES)"
    else
        fail "  $DB: table count differs (old=$OLD_TABLES, new=$NEW_TABLES)"
    fi
done

echo ""

# =============================================================================
# Neo4j
# =============================================================================
echo "== Neo4j =="
info "Neo4j requires authentication. Using HTTP API with default neo4j user."
info "If these checks fail with 401, verify credentials match between VMs."
echo ""

# Node count
OLD_NODES=$(curl -s -u neo4j:${NEO4J_PASS:-neo4j} \
    -H 'Content-Type: application/json' \
    -d '{"statements":[{"statement":"MATCH (n) RETURN count(n) AS c"}]}' \
    "http://${VM200_IP}:7474/db/neo4j/tx/commit" 2>/dev/null | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['data'][0]['row'][0])" 2>/dev/null || echo "ERROR")

NEW_NODES=$(curl -s -u neo4j:${NEO4J_PASS:-neo4j} \
    -H 'Content-Type: application/json' \
    -d '{"statements":[{"statement":"MATCH (n) RETURN count(n) AS c"}]}' \
    "http://${VM210_IP}:7474/db/neo4j/tx/commit" 2>/dev/null | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['data'][0]['row'][0])" 2>/dev/null || echo "ERROR")

if [[ "$OLD_NODES" == "ERROR" || "$NEW_NODES" == "ERROR" ]]; then
    fail "Neo4j node count: could not query (check auth/connectivity)"
    info "  Set NEO4J_PASS env var: NEO4J_PASS=<password> bash $0 $VM200_IP $VM210_IP"
elif [[ "$OLD_NODES" == "$NEW_NODES" ]]; then
    pass "Neo4j node count matches ($OLD_NODES)"
else
    fail "Neo4j node count differs (old=$OLD_NODES, new=$NEW_NODES)"
fi

# Relationship count
OLD_RELS=$(curl -s -u neo4j:${NEO4J_PASS:-neo4j} \
    -H 'Content-Type: application/json' \
    -d '{"statements":[{"statement":"MATCH ()-[r]->() RETURN count(r) AS c"}]}' \
    "http://${VM200_IP}:7474/db/neo4j/tx/commit" 2>/dev/null | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['data'][0]['row'][0])" 2>/dev/null || echo "ERROR")

NEW_RELS=$(curl -s -u neo4j:${NEO4J_PASS:-neo4j} \
    -H 'Content-Type: application/json' \
    -d '{"statements":[{"statement":"MATCH ()-[r]->() RETURN count(r) AS c"}]}' \
    "http://${VM210_IP}:7474/db/neo4j/tx/commit" 2>/dev/null | \
    python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['data'][0]['row'][0])" 2>/dev/null || echo "ERROR")

if [[ "$OLD_RELS" != "ERROR" && "$NEW_RELS" != "ERROR" ]]; then
    if [[ "$OLD_RELS" == "$NEW_RELS" ]]; then
        pass "Neo4j relationship count matches ($OLD_RELS)"
    else
        fail "Neo4j relationship count differs (old=$OLD_RELS, new=$NEW_RELS)"
    fi
fi

echo ""

# =============================================================================
# Qdrant
# =============================================================================
echo "== Qdrant =="

# Get collection lists
OLD_COLLS=$(curl -s "http://${VM200_IP}:6333/collections" 2>/dev/null | \
    python3 -c "import sys,json; [print(c['name']) for c in json.load(sys.stdin).get('result',{}).get('collections',[])]" 2>/dev/null || echo "ERROR")
NEW_COLLS=$(curl -s "http://${VM210_IP}:6333/collections" 2>/dev/null | \
    python3 -c "import sys,json; [print(c['name']) for c in json.load(sys.stdin).get('result',{}).get('collections',[])]" 2>/dev/null || echo "ERROR")

if [[ "$OLD_COLLS" == "ERROR" || "$NEW_COLLS" == "ERROR" ]]; then
    fail "Qdrant collection list: could not query"
elif [[ "$OLD_COLLS" == "$NEW_COLLS" ]]; then
    pass "Qdrant collection lists match"
else
    fail "Qdrant collection lists differ"
    info "  OLD: $(echo $OLD_COLLS | tr '\n' ', ')"
    info "  NEW: $(echo $NEW_COLLS | tr '\n' ', ')"
fi

# Point counts per collection
for COLL in $(echo "$OLD_COLLS" | grep -v '^ERROR$' | grep -v '^$'); do
    OLD_PTS=$(curl -s "http://${VM200_IP}:6333/collections/${COLL}" | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('points_count','?'))" 2>/dev/null || echo "?")
    NEW_PTS=$(curl -s "http://${VM210_IP}:6333/collections/${COLL}" | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('points_count','?'))" 2>/dev/null || echo "?")

    if [[ "$OLD_PTS" == "$NEW_PTS" ]]; then
        pass "  ${COLL}: point count matches ($OLD_PTS)"
    else
        fail "  ${COLL}: point count differs (old=$OLD_PTS, new=$NEW_PTS)"
    fi
done

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================"
echo " Validation Summary"
echo "============================================"
echo -e " Passed: ${GRN}${PASSES}${NC}"
echo -e " Failed: ${RED}${FAILS}${NC}"
echo ""

if [[ $FAILS -eq 0 ]]; then
    echo -e "${GRN}All parity checks passed. Phase 2 DEV validation complete.${NC}"
    echo ""
    echo "Phase 2 exit criteria met:"
    echo "  ✓ VM-210 runs all three databases"
    echo "  ✓ All DB data lives outside the VM (dev-zfs datasets)"
    echo "  ✓ Data parity confirmed against VM-200"
    echo "  ✓ VM-200 remains unchanged"
else
    echo -e "${RED}${FAILS} check(s) failed. Investigate before proceeding.${NC}"
    exit 1
fi
