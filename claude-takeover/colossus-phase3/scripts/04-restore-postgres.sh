#!/usr/bin/env bash
# =============================================================================
# 04-restore-postgres.sh — Restore PostgreSQL from SQL dump
# =============================================================================
# Run on: Workstation (proxima-centauri)
# Target: VM-110 (colossus-prod-db1) at 10.10.100.110
#
# Usage:
#   bash scripts/04-restore-postgres.sh <dump_file> [vm_ip]
#
# Example:
#   bash scripts/04-restore-postgres.sh \
#     ~/colossus-db-backup/dev/postgres/postgres_dump_2026-02-06.sql \
#     10.10.100.110
# =============================================================================
set -euo pipefail

DUMP_FILE="${1:?Usage: $0 <dump_file> [vm_ip]}"
VM_IP="${2:-10.10.100.110}"

if [[ ! -f "$DUMP_FILE" ]]; then
    echo "ERROR: Dump file not found: $DUMP_FILE" >&2
    exit 1
fi

echo "== PostgreSQL Restore =="
echo "  Dump: $DUMP_FILE"
echo "  Target: core@${VM_IP} (colossus-postgres)"
echo ""

# Verify container is running
echo "Checking container status..."
ssh core@${VM_IP} \
    'sudo podman ps --filter name=colossus-postgres --format "{{.Names}} {{.Status}}"'
echo ""

# Copy dump to VM
echo "Copying dump to VM..."
scp "$DUMP_FILE" core@${VM_IP}:/tmp/postgres_restore.sql

# Restore
echo "Restoring..."
ssh core@${VM_IP} \
    'sudo podman exec -i colossus-postgres psql -U postgres < /tmp/postgres_restore.sql'

# Verify
echo ""
echo "== Verification =="
echo "Databases:"
ssh core@${VM_IP} \
    'sudo podman exec colossus-postgres psql -U postgres -c "\l"'

echo ""
echo "Tables in colossus database:"
ssh core@${VM_IP} \
    "sudo podman exec colossus-postgres psql -U postgres -d colossus -c \"
    SELECT schemaname, tablename
    FROM pg_tables
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
    ORDER BY schemaname, tablename;\""

echo ""
echo "Table count:"
ssh core@${VM_IP} \
    "sudo podman exec colossus-postgres psql -U postgres -d colossus -c \"
    SELECT count(*) FROM pg_tables
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema');\""

# Cleanup
ssh core@${VM_IP} 'rm -f /tmp/postgres_restore.sql'

echo ""
echo "PostgreSQL restore complete."
