#!/usr/bin/env bash
# =============================================================================
# Daily Sandbox refresh — pulls fresh data from Production into Sandbox WITHOUT
# touching Yannick's app-specific tables/columns.
#
# How it works:
#   1. pg_dump the explicit list of CANONICAL tables (Production-owned) from
#      Production. --data-only, --no-owner, --no-privileges so we don't fight
#      the Sandbox's existing role grants.
#   2. Inside ONE transaction on Sandbox:
#        BEGIN
#          TRUNCATE canonical_table_list RESTART IDENTITY CASCADE
#          \i  <dump file with INSERTs / COPYs>
#        COMMIT
#      If anything fails, ROLLBACK keeps Sandbox in its prior consistent state.
#   3. ANALYZE so the query planner has fresh stats.
#
# What does NOT get touched:
#   - Any table NOT in CANONICAL_TABLES (Yannick's own tables — e.g. prospects,
#     lead_classifications, app_user_preferences). They survive every refresh.
#   - Schema (no DDL is executed). Yannick's added columns on canonical tables
#     persist; their values reset to NULL only for refreshed rows since pg_dump
#     doesn't include columns that don't exist in Production.
#
# Required env vars (or GitHub Secrets):
#   PROD_DB_URL     postgres://postgres:PWD@db.<prod-ref>.supabase.co:5432/postgres
#   SANDBOX_DB_URL  postgres://postgres:PWD@db.<sandbox-ref>.supabase.co:5432/postgres
#
# Local manual run:
#   PROD_DB_URL=... SANDBOX_DB_URL=... bash scripts/sync/sandbox_refresh.sh
# =============================================================================

set -euo pipefail

if [[ -z "${PROD_DB_URL:-}" || -z "${SANDBOX_DB_URL:-}" ]]; then
  echo "FATAL: PROD_DB_URL and SANDBOX_DB_URL must be set." >&2
  exit 1
fi

# Production-owned canonical tables — refresh order doesn't matter (pg_dump
# handles FK ordering automatically when restoring).
CANONICAL_TABLES=(
  clients
  properties
  client_contacts
  service_configs
  jobs
  visits
  visit_assignments
  invoices
  line_items
  quotes
  notes
  photos
  photo_links
  derm_manifests
  manifest_visits
  inspections
  employees
  vehicles
  vehicle_telemetry_readings
  entity_source_links
  jobber_oversized_attachments
)

# Skipped on purpose:
#   webhook_events_log  — audit log, 21K rows, not useful in Sandbox
#   webhook_tokens      — secrets, never sync
#   sync_cursors        — Sandbox should track its own (none) state
#   sync_log            — same

# Build pg_dump -t flags
T_FLAGS=()
for t in "${CANONICAL_TABLES[@]}"; do
  T_FLAGS+=(-t "public.$t")
done

# Build single TRUNCATE statement. CASCADE only matters between canonical
# tables (per LOVABLE-SYSTEM-PROMPT, Yannick's tables must NOT have real FK
# constraints to canonical — they use loose `external_<entity>_id BIGINT`).
TRUNCATE_LIST=$(IFS=,; echo "${CANONICAL_TABLES[*]}")
TRUNCATE_SQL="TRUNCATE TABLE ${TRUNCATE_LIST} RESTART IDENTITY CASCADE;"

DUMP_FILE="${TMPDIR:-/tmp}/sandbox_refresh_$(date -u +%Y%m%dT%H%M%S).sql"

echo "===================================================================="
echo "Sandbox refresh started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  ${#CANONICAL_TABLES[@]} canonical tables"
echo "  Dump file: $DUMP_FILE"
echo "===================================================================="

echo
echo "[1/4] pg_dump --data-only from Production..."
# NOTE: no --disable-triggers — Supabase's `postgres` role isn't a true
# superuser, so it can't suspend system constraint triggers. pg_dump already
# orders --data-only inserts in FK-dependency order, so this is fine.
pg_dump \
  --data-only \
  --no-owner \
  --no-privileges \
  "${T_FLAGS[@]}" \
  "$PROD_DB_URL" > "$DUMP_FILE"
DUMP_BYTES=$(wc -c < "$DUMP_FILE")
DUMP_LINES=$(wc -l < "$DUMP_FILE")
echo "  ✓ ${DUMP_BYTES} bytes, ${DUMP_LINES} lines"

echo
echo "[2/4] Truncate + reload Sandbox in single transaction..."
# NOTE: no `SET session_replication_role = replica` — Supabase's `postgres`
# role can't toggle FK-trigger suppression. We rely on pg_dump's FK-aware
# insert order instead, and the TRUNCATE CASCADE up front clears all
# canonical rows before any insert.
{
  echo "BEGIN;"
  echo "$TRUNCATE_SQL"
  cat "$DUMP_FILE"
  echo "COMMIT;"
} | psql "$SANDBOX_DB_URL" -v ON_ERROR_STOP=1 --quiet
echo "  ✓ committed"

echo
echo "[3/4] Refresh sequence values to max(id)+1 on Sandbox..."
# RESTART IDENTITY in TRUNCATE resets sequences to 1, but we just inserted rows
# with IDs from Production. Need to bump every sequence past its column's max,
# else next INSERT collides on PK.
#
# We auto-discover sequences via pg_depend so we don't have to assume each
# table has a column called "id" (e.g. visit_assignments is a junction table
# with composite key — no id column at all).
TABLES_QUOTED=$(IFS=,; for t in "${CANONICAL_TABLES[@]}"; do echo -n "'$t',"; done | sed 's/,$//')
psql "$SANDBOX_DB_URL" -v ON_ERROR_STOP=1 --quiet -t > /dev/null <<EOF
DO \$\$
DECLARE
  rec RECORD;
  v_max bigint;
BEGIN
  FOR rec IN
    SELECT
      n.nspname || '.' || s.relname AS seq_qualified,
      n.nspname || '.' || c.relname AS table_qualified,
      a.attname AS column_name
    FROM pg_class s
    JOIN pg_namespace ns ON ns.oid = s.relnamespace
    JOIN pg_depend d ON d.objid = s.oid AND d.deptype IN ('a','i')
    JOIN pg_class c ON c.oid = d.refobjid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = d.refobjsubid
    WHERE s.relkind = 'S'
      AND n.nspname = 'public'
      AND c.relname IN (${TABLES_QUOTED})
  LOOP
    EXECUTE format('SELECT MAX(%I) FROM %s', rec.column_name, rec.table_qualified) INTO v_max;
    IF v_max IS NOT NULL THEN
      EXECUTE format('SELECT setval(%L, %s, true)', rec.seq_qualified, v_max);
    END IF;
  END LOOP;
END
\$\$;
EOF
echo "  ✓ sequences advanced"

echo
echo "[4/4] ANALYZE Sandbox..."
psql "$SANDBOX_DB_URL" -v ON_ERROR_STOP=1 --quiet -c "ANALYZE;"
echo "  ✓ done"

echo
echo "===================================================================="
echo "Refresh complete $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  Sandbox now mirrors Production canonical tables as of dump time"
echo "  Yannick's app-specific tables/columns untouched"
echo "===================================================================="

# Cleanup dump file
rm -f "$DUMP_FILE"
