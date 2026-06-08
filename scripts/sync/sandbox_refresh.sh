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
  visit_locations
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
  # Dimension/lookup tables the canonical set FKs into — added 2026-06-05 after a refresh
  # failure (clients.group_id -> client_groups was unseeded in Sandbox). gdos in particular
  # GROWS via DERM Tracker, so a stale one-time seed was a latent landmine. pg_dump --data-only
  # orders FK dependencies automatically on restore, so position here is irrelevant.
  client_groups
  zones
  client_locations
  disposal_facilities
  gdos
  service_line_items
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
echo "[1a/4] Schema parity — create canonical tables missing from Sandbox..."
# The refresh is data-only: a NEW canonical table in Prod won't exist in Sandbox,
# so the reload's COPY (or an FK from an existing canonical table) aborts the whole
# transaction. Auto-create any missing canonical table from Prod's schema. We STRIP
# triggers + RLS/policies on purpose: Sandbox has no `audit` schema (audit.log_change
# is absent) and runs an anon-permissive posture, not Prod's RLS-hardened one. Then
# grant read so Yannick's Lovable app can see the new table.
SP_MISSING=()
for t in "${CANONICAL_TABLES[@]}"; do
  ex=$(psql "$SANDBOX_DB_URL" -tAc "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='$t' LIMIT 1" 2>/dev/null)
  [ -z "$ex" ] && SP_MISSING+=("$t")
done
if [ ${#SP_MISSING[@]} -gt 0 ]; then
  echo "  missing in Sandbox: ${SP_MISSING[*]} — creating from Prod schema"
  SP_FLAGS=()
  for t in "${SP_MISSING[@]}"; do SP_FLAGS+=(-t "public.$t"); done
  pg_dump --schema-only --no-owner --no-privileges "${SP_FLAGS[@]}" "$PROD_DB_URL" \
    | awk '
        /^CREATE TRIGGER/ { skip=1 }
        /^CREATE POLICY/  { skip=1 }
        /ROW LEVEL SECURITY/ { next }
        skip { if ($0 ~ /;[[:space:]]*$/) skip=0; next }
        { print }
      ' \
    | psql "$SANDBOX_DB_URL" -v ON_ERROR_STOP=1 --quiet
  for t in "${SP_MISSING[@]}"; do
    psql "$SANDBOX_DB_URL" -v ON_ERROR_STOP=1 --quiet -c "GRANT SELECT ON public.\"$t\" TO anon, authenticated;"
  done
  echo "  ✓ created ${#SP_MISSING[@]} table(s) (triggers/RLS stripped, read granted)"
else
  echo "  ✓ no missing tables"
fi

echo
echo "[2a/4] Detect Production column drops + identify Yannick columns..."
# Two distinct populations of "in Sandbox but not in Production" columns:
#   1. Genuine Yannick additions (he created in Sandbox; Prod never had it).
#      → Preserve values across the TRUNCATE+RELOAD.
#   2. Production-side drops (Prod used to have it; we dropped it in a
#      migration). → Drop from Sandbox so the schemas converge.
#
# Distinguish via a small _prod_schema_baseline table in Sandbox that
# records what columns Prod had on the LAST refresh. Anything that was in
# the baseline but isn't in current Prod = Prod dropped it. Anything not
# in baseline either = genuine Yannick addition.
psql "$SANDBOX_DB_URL" -v ON_ERROR_STOP=1 --quiet <<'EOSQL'
CREATE TABLE IF NOT EXISTS _prod_schema_baseline (
  table_name  TEXT NOT NULL,
  column_name TEXT NOT NULL,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (table_name, column_name)
);
EOSQL
DROPPED_BY_PROD_COUNT=0
SNAPSHOT_SQL=""
RESTORE_SQL=""
DROP_TEMPS_SQL=""
PRESERVED_COL_COUNT=0
for t in "${CANONICAL_TABLES[@]}"; do
  # 1. PROD-DROPPED COLUMNS: was in last baseline, no longer in Prod → drop from Sandbox
  PROD_DROPPED=$(comm -23 \
    <(psql "$SANDBOX_DB_URL" -tAc "SELECT column_name FROM _prod_schema_baseline WHERE table_name='$t'" 2>/dev/null | sort -u) \
    <(psql "$PROD_DB_URL"    -tAc "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='$t'" 2>/dev/null | sort -u))
  for col in $PROD_DROPPED; do
    # Only drop from Sandbox if the column actually exists there (and only after
    # also dropping any view that depends on it — DROP COLUMN ... CASCADE is too
    # blunt; we'd lose Yannick's views. For now use IF EXISTS and skip on error.)
    EXISTS=$(psql "$SANDBOX_DB_URL" -tAc "SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='$t' AND column_name='$col' LIMIT 1" 2>/dev/null)
    [ -z "$EXISTS" ] && continue
    echo "  $t.$col: PROD dropped this — propagating to Sandbox"
    psql "$SANDBOX_DB_URL" -v ON_ERROR_STOP=0 --quiet -c "ALTER TABLE public.$t DROP COLUMN IF EXISTS $col CASCADE;" 2>&1 | grep -v "^$" || true
    DROPPED_BY_PROD_COUNT=$((DROPPED_BY_PROD_COUNT + 1))
  done

  # 1b. PROD-ADDED COLUMNS: in Prod, missing from Sandbox → ADD to Sandbox
  # before pg_dump's INSERTs hit (otherwise the INSERT names columns that
  # don't exist on Sandbox and the whole transaction rolls back).
  # Added 2026-05-22 after 8/11 refreshes failed on visits.derm_required +
  # derm_manifests.gdo_id added to Prod between refresh cycles.
  # We add as nullable regardless of Prod's NOT NULL — the dump populates
  # values from Prod rows. NOT NULL enforcement on Sandbox isn't needed
  # (Yannick reads, doesn't insert), and demanding it would force us to
  # carry defaults we may not want in Sandbox.
  PROD_ADDED=$(comm -13 \
    <(psql "$SANDBOX_DB_URL" -tAc "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='$t'" 2>/dev/null | sort -u) \
    <(psql "$PROD_DB_URL"    -tAc "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='$t'" 2>/dev/null | sort -u))
  for col in $PROD_ADDED; do
    # Pull the Prod type via udt_name (canonical short form) — falls back to
    # text if for some reason the type can't be resolved.
    COL_TYPE=$(psql "$PROD_DB_URL" -tAc "SELECT udt_name FROM information_schema.columns WHERE table_schema='public' AND table_name='$t' AND column_name='$col' LIMIT 1" 2>/dev/null | tr -d ' ')
    [ -z "$COL_TYPE" ] && COL_TYPE='text'
    # Re-map a few Postgres udt names to their SQL canonical form so
    # ALTER TABLE parses them cleanly:
    case "$COL_TYPE" in
      int2)    COL_TYPE='smallint' ;;
      int4)    COL_TYPE='integer' ;;
      int8)    COL_TYPE='bigint' ;;
      bool)    COL_TYPE='boolean' ;;
      timestamptz) COL_TYPE='timestamptz' ;;
      timestamp)   COL_TYPE='timestamp' ;;
      _text)   COL_TYPE='text[]' ;;
      _int4)   COL_TYPE='integer[]' ;;
      _int8)   COL_TYPE='bigint[]' ;;
    esac
    echo "  $t.$col: PROD added (type=$COL_TYPE) — propagating to Sandbox"
    psql "$SANDBOX_DB_URL" -v ON_ERROR_STOP=0 --quiet -c "ALTER TABLE public.$t ADD COLUMN IF NOT EXISTS $col $COL_TYPE;" 2>&1 | grep -v "^$" || true
  done

  # 2. YANNICK-ADDED COLUMNS: in Sandbox AND not in Prod NOW → preserve values
  YCOLS=$(comm -23 \
    <(psql "$SANDBOX_DB_URL" -tAc "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='$t'" 2>/dev/null | sort -u) \
    <(psql "$PROD_DB_URL"    -tAc "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='$t'" 2>/dev/null | sort -u))
  # Skip if no diff
  [ -z "$YCOLS" ] && continue
  # Skip if table has no 'id' column (junction tables — Yannick shouldn't
  # be adding columns to those anyway; junction-table-rows are wholly
  # determined by their composite key)
  HAS_ID=$(psql "$SANDBOX_DB_URL" -tAc "SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='$t' AND column_name='id' LIMIT 1" 2>/dev/null)
  [ -z "$HAS_ID" ] && continue
  YCOLS_CSV=$(echo "$YCOLS" | tr '\n' ',' | sed 's/,$//')
  echo "  $t: preserving columns [${YCOLS_CSV}]"
  # Use schema-qualified names everywhere — pg_dump's output sets
  # `search_path = ''` which makes unqualified table names invisible
  # for any statements that run after the dump body.
  SNAPSHOT_SQL+="CREATE TEMP TABLE _yannick_snap_${t} AS SELECT id, ${YCOLS_CSV} FROM public.${t};
"
  SETS=""
  for c in $YCOLS; do
    SETS+="${c}=s.${c},"
    PRESERVED_COL_COUNT=$((PRESERVED_COL_COUNT + 1))
  done
  SETS=$(echo "$SETS" | sed 's/,$//')
  RESTORE_SQL+="UPDATE public.${t} t SET ${SETS} FROM pg_temp._yannick_snap_${t} s WHERE t.id = s.id;
"
  DROP_TEMPS_SQL+="DROP TABLE pg_temp._yannick_snap_${t};
"
done
echo "  ✓ ${PRESERVED_COL_COUNT} Yannick column(s) will be preserved"
echo "  ✓ ${DROPPED_BY_PROD_COUNT} Production-dropped column(s) propagated to Sandbox"

echo
echo "[2a+/4] Schema parity — realign drifted CHECK constraints to Prod..."
# A CHECK whose allowed set widened in Prod (e.g. visits.source gaining
# 'visit-calendar') but not in Sandbox will reject the incoming Prod rows and abort
# the reload. Copy Prod's canonical CHECK defs into a temp table on Sandbox, then
# re-create any that differ or are missing. NOT VALID so the about-to-be-truncated
# Sandbox rows aren't re-validated; the reload's COPY enforces them on fresh data.
SP_CANON_IN=$(IFS=,; for t in "${CANONICAL_TABLES[@]}"; do echo -n "'$t',"; done | sed 's/,$//')
{
  echo "CREATE TEMP TABLE _prod_chk (tbl text, conname text, def text);"
  echo "COPY _prod_chk (tbl, conname, def) FROM stdin;"
  psql "$PROD_DB_URL" -tAc "SELECT conrelid::regclass::text||E'\t'||conname||E'\t'||pg_get_constraintdef(oid) FROM pg_constraint WHERE contype='c' AND connamespace='public'::regnamespace AND conrelid::regclass::text IN (${SP_CANON_IN})" 2>/dev/null
  echo "\\."
  cat <<'EOSQL'
DO $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT p.tbl, p.conname, p.def
    FROM _prod_chk p
    LEFT JOIN pg_constraint c
      ON c.conname = p.conname
     AND c.connamespace = 'public'::regnamespace
     AND c.conrelid::regclass::text = p.tbl
    WHERE c.oid IS NULL OR pg_get_constraintdef(c.oid) <> p.def
  LOOP
    EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT IF EXISTS %I', r.tbl, r.conname);
    EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I %s NOT VALID', r.tbl, r.conname, r.def);
    RAISE NOTICE 'realigned CHECK %.%', r.tbl, r.conname;
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'check realign: % constraint(s) updated', n;
END $$;
EOSQL
} | psql "$SANDBOX_DB_URL" -v ON_ERROR_STOP=1 --quiet
echo "  ✓ checks realigned"

echo
echo "[2b/4] Truncate + reload Sandbox in single transaction..."
# NOTE: no `SET session_replication_role = replica` — Supabase's `postgres`
# role can't toggle FK-trigger suppression. We rely on pg_dump's FK-aware
# insert order instead, and the TRUNCATE CASCADE up front clears all
# canonical rows before any insert.
{
  echo "BEGIN;"
  echo "$SNAPSHOT_SQL"
  echo "$TRUNCATE_SQL"
  cat "$DUMP_FILE"
  echo "$RESTORE_SQL"
  echo "$DROP_TEMPS_SQL"
  echo "COMMIT;"
} | psql "$SANDBOX_DB_URL" -v ON_ERROR_STOP=1 --quiet
echo "  ✓ committed (Yannick column values restored)"

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
echo "[4/4] Update _prod_schema_baseline + ANALYZE Sandbox..."
# Refresh the baseline with what Prod has RIGHT NOW. Next refresh uses this
# to detect "Prod had column X yesterday but doesn't now → drop from Sandbox."
# Single COPY for efficiency vs per-row INSERTs.
TABLES_LIST=$(IFS=,; for t in "${CANONICAL_TABLES[@]}"; do echo -n "'$t',"; done | sed 's/,$//')
{
  echo "BEGIN;"
  echo "TRUNCATE _prod_schema_baseline;"
  echo "COPY _prod_schema_baseline (table_name, column_name) FROM stdin;"
  psql "$PROD_DB_URL" -tAc "SELECT table_name||E'\t'||column_name FROM information_schema.columns WHERE table_schema='public' AND table_name IN (${TABLES_LIST})" 2>/dev/null
  echo "\\."
  echo "COMMIT;"
} | psql "$SANDBOX_DB_URL" -v ON_ERROR_STOP=1 --quiet
BASELINE_COUNT=$(psql "$SANDBOX_DB_URL" -tAc "SELECT COUNT(*) FROM _prod_schema_baseline" 2>/dev/null | tr -d ' ')
echo "  ✓ baseline updated (${BASELINE_COUNT} columns recorded across ${#CANONICAL_TABLES[@]} canonical tables)"
psql "$SANDBOX_DB_URL" -v ON_ERROR_STOP=1 --quiet -c "ANALYZE;"
echo "  ✓ analyzed"

echo
echo "===================================================================="
echo "Refresh complete $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  Sandbox now mirrors Production canonical tables as of dump time"
echo "  Yannick's app-specific tables/columns untouched"
echo "===================================================================="

# Cleanup dump file
rm -f "$DUMP_FILE"
