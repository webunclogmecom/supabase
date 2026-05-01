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
pg_dump \
  --data-only \
  --no-owner \
  --no-privileges \
  --disable-triggers \
  "${T_FLAGS[@]}" \
  "$PROD_DB_URL" > "$DUMP_FILE"
DUMP_BYTES=$(wc -c < "$DUMP_FILE")
DUMP_LINES=$(wc -l < "$DUMP_FILE")
echo "  ✓ ${DUMP_BYTES} bytes, ${DUMP_LINES} lines"

echo
echo "[2/4] Truncate + reload Sandbox in single transaction..."
{
  echo "BEGIN;"
  echo "SET session_replication_role = replica;"  # disable triggers/FK checks during reload
  echo "$TRUNCATE_SQL"
  cat "$DUMP_FILE"
  echo "SET session_replication_role = origin;"
  echo "COMMIT;"
} | psql "$SANDBOX_DB_URL" -v ON_ERROR_STOP=1 --quiet
echo "  ✓ committed"

echo
echo "[3/4] Refresh sequence values to max(id)+1 on Sandbox..."
# RESTART IDENTITY in TRUNCATE resets sequences to 1, but we just inserted rows
# with IDs from Production. Need to bump sequences past the inserted max(id),
# else next INSERT collides on PK.
SEQ_SQL=""
for t in "${CANONICAL_TABLES[@]}"; do
  SEQ_SQL+="
SELECT setval(pg_get_serial_sequence('public.$t', 'id'),
              COALESCE((SELECT MAX(id) FROM public.$t), 1),
              (SELECT MAX(id) FROM public.$t) IS NOT NULL)
WHERE pg_get_serial_sequence('public.$t', 'id') IS NOT NULL;
"
done
echo "$SEQ_SQL" | psql "$SANDBOX_DB_URL" -v ON_ERROR_STOP=1 --quiet -t > /dev/null
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
