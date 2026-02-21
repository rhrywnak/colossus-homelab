#!/usr/bin/env bash
# =============================================================================
# 04-restore-postgres.sh — Restore PostgreSQL from SQL dump into VM-210
# =============================================================================
# Run on: your workstation (Linux desktop)
#
# Prerequisites:
#   - VM-210 is running
#   - colossus-postgres container is up and healthy
#   - SQL dump file exists locally
#
# Usage:
#   bash 04-restore-postgres.sh <path-to-dump> <vm210-ip>
#
# Example:
#   bash 04-restore-postgres.sh \
#     ~/colossus-db-backup/dev/postgres/postgres_dump_2026-02-06.sql \
#     192.168.1.xxx
# =============================================================================
set -euo pipefail

DUMP_FILE="${1:-}"
VM210_IP="${2:-}"

if [[ -z "$DUMP_FILE" || -z "$VM210_IP" ]]; then
    echo "Usage: $0 <path-to-sql-dump> <vm210-ip>" >&2
    echo "Example: $0 ~/colossus-db-backup/dev/postgres/postgres_dump_2026-02-06.sql 192.168.1.100" >&2
    exit 1
fi

if [[ ! -f "$DUMP_FILE" ]]; then
    echo "ERROR: Dump file not found: $DUMP_FILE" >&2
    exit 1
fi

DUMP_SIZE=$(du -h "$DUMP_FILE" | cut -f1)
echo "== PostgreSQL Restore =="
echo "  Dump file: $DUMP_FILE ($DUMP_SIZE)"
echo "  Target:    core@${VM210_IP} → colossus-postgres container"
echo ""

# --- Verify container is running on VM-210 ------------------------------------
echo "== Verifying colossus-postgres is running on VM-210 =="
ssh "core@${VM210_IP}" 'sudo podman ps --filter name=colossus-postgres --format "{{.Names}} {{.Status}}"'
echo ""

# --- Copy dump to VM-210 -----------------------------------------------------
echo "== Copying dump to VM-210:/tmp/postgres_restore.sql =="
scp "$DUMP_FILE" "core@${VM210_IP}:/tmp/postgres_restore.sql"
echo "  Done."

# --- Execute restore ----------------------------------------------------------
echo ""
echo "== Restoring into colossus-postgres =="
echo "  This may take a while depending on dump size..."
ssh "core@${VM210_IP}" 'sudo podman exec -i colossus-postgres psql -U postgres < /tmp/postgres_restore.sql'

# --- Verify -------------------------------------------------------------------
echo ""
echo "== Verification: listing databases =="
ssh "core@${VM210_IP}" 'sudo podman exec colossus-postgres psql -U postgres -c "\l"'

echo ""
echo "== Verification: table counts in colossus database =="
ssh "core@${VM210_IP}" 'sudo podman exec colossus-postgres psql -U postgres -d colossus -c "
SELECT schemaname, tablename
FROM pg_tables
WHERE schemaname NOT IN ('"'"'pg_catalog'"'"', '"'"'information_schema'"'"')
ORDER BY schemaname, tablename;
"' || echo "(colossus database may have a different name — check \l output above)"

# --- Cleanup ------------------------------------------------------------------
echo ""
echo "== Cleaning up temp file on VM-210 =="
ssh "core@${VM210_IP}" 'rm -f /tmp/postgres_restore.sql'

echo ""
echo "== PostgreSQL restore complete =="
echo "  Next: Compare table counts against VM-200 for parity validation."
