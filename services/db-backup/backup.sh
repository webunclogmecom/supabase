#!/usr/bin/env bash
# Own copy of the Prod database every 2 hours, plus one full copy a day, on a Railway volume.
# Fred, 2026-10-05: "Go with the 2-hour copy on Railway" (instead of PITR, which is off).
# Setup, restore and the reasons: README.md next to this file.
#
# Usage:  backup.sh loop    (Railway start command: on every 2-hour slot; at start only if no recent copy)
#         backup.sh once    (one attempt, for tests)
#         backup.sh drill   (restore the newest daily copy into a throwaway local Postgres, print row counts;
#                            also runs at start when RUN_DRILL=1)
# Connection: the standard libpq variables PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE (login db_backup_reader).
# Options: BACKUP_DIR (/data), KEEP_2H (24), KEEP_DAILY (14), INTERVAL_HOURS (2), SLOT_MINUTE (17),
#          DAILY_AFTER_HOURS (23), HEARTBEAT (on | dry | off), DUMP_TIMEOUT (45m),
#          MIN_TABLES_2H (120), MIN_TABLES_DAILY (140), REQUIRE_VOLUME (1; 0 only for local tests),
#          PGSSLROOTCERT (if set to an existing file, PGSSLMODE defaults to verify-full)
set -uo pipefail

BACKUP_DIR="${BACKUP_DIR:-/data}"
KEEP_2H="${KEEP_2H:-24}"
KEEP_DAILY="${KEEP_DAILY:-14}"
INTERVAL_HOURS="${INTERVAL_HOURS:-2}"
SLOT_MINUTE="${SLOT_MINUTE:-17}"
DAILY_AFTER_HOURS="${DAILY_AFTER_HOURS:-23}"
MIN_TABLES_2H="${MIN_TABLES_2H:-120}"
MIN_TABLES_DAILY="${MIN_TABLES_DAILY:-140}"
HEARTBEAT="${HEARTBEAT:-on}"
DUMP_TIMEOUT="${DUMP_TIMEOUT:-45m}"
REQUIRE_VOLUME="${REQUIRE_VOLUME:-1}"
if [ -n "${PGSSLROOTCERT:-}" ] && [ -f "${PGSSLROOTCERT}" ]; then export PGSSLMODE="${PGSSLMODE:-verify-full}"; fi
export PGCONNECT_TIMEOUT=30 PGAPPNAME=db-backup PGSSLMODE="${PGSSLMODE:-require}"

# A typo in a number must never turn this into a back-to-back dump loop.
for v in KEEP_2H KEEP_DAILY INTERVAL_HOURS SLOT_MINUTE DAILY_AFTER_HOURS MIN_TABLES_2H MIN_TABLES_DAILY; do
  case "${!v}" in ''|*[!0-9]*) echo "backup.sh: $v must be a whole number, got '${!v}'" >&2; exit 2 ;; esac
done
if [ "$INTERVAL_HOURS" -lt 1 ] || [ "$KEEP_2H" -lt 1 ] || [ "$KEEP_DAILY" -lt 1 ]; then echo "backup.sh: INTERVAL_HOURS, KEEP_2H and KEEP_DAILY must be at least 1" >&2; exit 2; fi

# Business schemas. Not vault (secrets), auth/storage (Supabase-managed), cron/net/realtime (logs).
SCHEMAS=(public derm ops client sync raw customer hr)
# Never copied: Jobber/Samsara OAuth tokens and the client secret (the login cannot read it anyway).
EXCLUDE_TABLE=(public.webhook_tokens)
# Re-creatable bulk, left out of the 2-hour copy only: Samsara telemetry (Samsara keeps months of it)
# and two logs. The daily copy has everything, plus the audit history.
EXCLUDE_DATA_2H=(public.vehicle_telemetry_readings public.webhook_events_log public.sync_log)

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

heartbeat() { # status kind seconds bytes sha256 file message ; the login's only write
  [ "$HEARTBEAT" = off ] && return 0
  local end=COMMIT; [ "$HEARTBEAT" = dry ] && end=ROLLBACK
  timeout 2m psql -X -q -v ON_ERROR_STOP=1 -v st="$1" -v kind="$2" -v secs="$3" -v bytes="$4" -v sha="$5" -v file="$6" -v msg="$7" <<SQL
begin transaction read write;
select public.fn_db_backup_heartbeat(:'st', :'kind', :'secs'::numeric, :'bytes'::bigint, :'sha', :'file', :'msg');
${end};
SQL
}

newest_age_hours() { # dir -> hours since the newest .dump (9999 when none)
  local f; f=$(ls -1t "$1"/*.dump 2>/dev/null | head -1)
  [ -z "$f" ] && { echo 9999; return; }
  echo $(( ( $(date +%s) - $(stat -c %Y "$f") ) / 3600 ))
}

prune() { # dir keep
  ls -1t "$1"/*.dump 2>/dev/null | tail -n +$(( $2 + 1 )) | while read -r f; do rm -f -- "$f" "$f.sha256"; log "pruned $(basename "$f")"; done
}

run_once() { # [kind]  (default: daily when the newest daily is DAILY_AFTER_HOURS old, else two_hourly)
  local got="${RAILWAY_VOLUME_MOUNT_PATH:-}"
  if [ "$REQUIRE_VOLUME" = 1 ] && [ "${got%/}" != "${BACKUP_DIR%/}" ]; then
    local m="no Railway volume mounted at $BACKUP_DIR (Railway reports RAILWAY_VOLUME_MOUNT_PATH='${got:-unset}'); copies would be lost on the next deploy"
    log "FAILED: $m"
    heartbeat error setup 0 0 "" "" "$m" || log "heartbeat failed"
    return 2
  fi
  # Leftovers of a dump killed by a redeploy (Railway never mounts one volume into two live deployments).
  rm -f -- "$BACKUP_DIR"/*/*.partial "$BACKUP_DIR"/*/*.toc

  local kind="${1:-}"
  if [ -z "$kind" ]; then
    kind=two_hourly; [ "$(newest_age_hours "$BACKUP_DIR/daily")" -ge "$DAILY_AFTER_HOURS" ] && kind=daily
  fi
  local keep=$KEEP_2H min=$MIN_TABLES_2H
  [ "$kind" = daily ] && { keep=$KEEP_DAILY; min=$MIN_TABLES_DAILY; }
  local dir="$BACKUP_DIR/$kind"; mkdir -p "$dir"
  prune "$dir" $(( keep - 1 ))   # make room first, so a full disk can recover
  local file="$dir/prod_${kind}_$(date -u +%Y%m%dT%H%M%SZ).dump" err="$dir/.last_error"
  local args=(-Fc -Z 6 --no-password --strict-names --lock-wait-timeout=60s)
  for s in "${SCHEMAS[@]}"; do args+=(-n "$s"); done
  [ "$kind" = daily ] && args+=(-n audit)
  for t in "${EXCLUDE_TABLE[@]}"; do args+=(--exclude-table="$t"); done
  [ "$kind" = two_hourly ] && for t in "${EXCLUDE_DATA_2H[@]}"; do args+=(--exclude-table-data="$t"); done

  local t0 rc tables=0; t0=$(date +%s)
  log "start $kind -> $(basename "$file")"
  timeout -k 1m "$DUMP_TIMEOUT" pg_dump "${args[@]}" -f "$file.partial" 2>"$err"; rc=$?
  if [ "$rc" -eq 0 ] && pg_restore --list "$file.partial" >"$file.toc" 2>>"$err"; then
    tables=$(grep -c ' TABLE DATA ' "$file.toc")
  fi
  if [ "$rc" -eq 0 ] && [ "$tables" -ge "$min" ]; then
    mv -- "$file.partial" "$file"; rm -f -- "$file.toc" "$err"
    local bytes sha secs; bytes=$(stat -c %s "$file"); sha=$(sha256sum "$file" | cut -d' ' -f1)
    echo "$sha  $(basename "$file")" >"$file.sha256"
    secs=$(( $(date +%s) - t0 ))
    log "ok $kind bytes=$bytes tables=$tables secs=$secs"
    heartbeat success "$kind" "$secs" "$bytes" "$sha" "$(basename "$file")" "" || log "heartbeat failed"
  else
    local msg; msg=$(tail -c 400 "$err" 2>/dev/null | tr '\n' ' ')
    [ "$rc" -eq 124 ] && msg="pg_dump timed out after $DUMP_TIMEOUT. $msg"
    [ -z "$msg" ] && { [ "$rc" -ne 0 ] && msg="pg_dump exit $rc" || msg="only $tables tables of data, expected at least $min"; }
    rm -f -- "$file.partial" "$file.toc"
    log "FAILED $kind: $msg"
    heartbeat error "$kind" "$(( $(date +%s) - t0 ))" 0 "" "" "$msg" || log "heartbeat failed"
    return 1
  fi
}

attempt() { # a due daily that fails must not also cost the 2-hour copy (not retried on a setup error)
  run_once; local rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 2 ] && return 1
  [ "$(newest_age_hours "$BACKUP_DIR/daily")" -ge "$DAILY_AFTER_HOURS" ] && run_once two_hourly
}

drill() { # restore the newest daily copy into a throwaway local Postgres; print per-table row counts
  local f D=/tmp/drill port=5499 errs
  f=$(ls -1t "$BACKUP_DIR"/daily/*.dump 2>/dev/null | head -1)
  [ -z "$f" ] && { log "DRILL: no daily copy to restore"; return 1; }
  ( cd "$(dirname "$f")" && sha256sum -c "$(basename "$f").sha256" >/dev/null ) || { log "DRILL: checksum mismatch for $(basename "$f")"; return 1; }
  rm -rf "$D"; mkdir -p "$D"; chown postgres:postgres "$D"
  su-exec postgres initdb -D "$D/pg" -A trust -U postgres >/dev/null || { log "DRILL: initdb failed"; return 1; }
  su-exec postgres pg_ctl -D "$D/pg" -l "$D/pg.log" -o "-k $D -c listen_addresses='' -p $port" -w start >/dev/null || { log "DRILL: server did not start"; return 1; }
  local P=(psql -X -q -h "$D" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=0)
  # Stand-ins for what a Supabase project already has, so table definitions and policies can be created.
  "${P[@]}" >/dev/null 2>&1 <<'SQL'
do $$ declare r text; begin
  foreach r in array array['anon','authenticated','service_role','supabase_admin','supabase_auth_admin','supabase_storage_admin','authenticator','dashboard_user','yannick_readonly','db_backup_reader'] loop
    if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I nologin', r); end if;
  end loop; end $$;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists pg_trgm with schema extensions;
create schema if not exists auth;
create or replace function auth.uid() returns uuid language sql stable as 'select null::uuid';
create or replace function auth.role() returns text language sql stable as 'select null::text';
create or replace function auth.email() returns text language sql stable as 'select null::text';
create or replace function auth.jwt() returns jsonb language sql stable as 'select null::jsonb';
SQL
  local t0; t0=$(date +%s)
  pg_restore --no-owner --no-privileges -h "$D" -p "$port" -U postgres -d postgres "$f" 2>"$D/restore.err"
  errs=$(grep -c '^pg_restore: error' "$D/restore.err")
  log "DRILL restored $(basename "$f") in $(( $(date +%s) - t0 ))s, pg_restore errors: $errs (first ones below)"
  grep '^pg_restore: error' "$D/restore.err" | cut -c1-200 | head -8 | while read -r l; do log "DRILL err: $l"; done
  # One line per table of data in the dump: schema.table rows
  pg_restore --list "$f" | awk '$4=="TABLE" && $5=="DATA" {print $6"."$7}' | sort -u | while read -r tb; do
    n=$("${P[@]}" -At -c "select count(*) from $tb" 2>/dev/null || echo MISSING)
    echo "DRILL_ROWS $tb $n"
  done
  log "DRILL done"
  su-exec postgres pg_ctl -D "$D/pg" -m fast stop >/dev/null; rm -rf "$D"
}

seconds_to_next_slot() { # next HH:SLOT_MINUTE on an INTERVAL_HOURS grid, UTC
  local now step off next
  now=$(date +%s); step=$(( INTERVAL_HOURS * 3600 )); off=$(( SLOT_MINUTE * 60 ))
  next=$(( ( (now - off) / step + 1 ) * step + off ))
  echo $(( next - now ))
}

case "${1:-loop}" in
  once) attempt ;;
  drill) drill ;;
  loop)
    # A redeploy restarts the container: copy at start only when no recent copy exists.
    a=$(newest_age_hours "$BACKUP_DIR/two_hourly"); b=$(newest_age_hours "$BACKUP_DIR/daily")
    if [ "$(( a < b ? a : b ))" -ge "$INTERVAL_HOURS" ] || [ "$b" -ge "$DAILY_AFTER_HOURS" ]; then attempt; else log "recent copy found, waiting for the next slot"; fi
    [ "${RUN_DRILL:-0}" = 1 ] && { drill || log "DRILL failed"; }
    while true; do
      s=$(seconds_to_next_slot); [ "${s:-0}" -gt 0 ] 2>/dev/null || s=3600
      log "next run in ${s}s"; sleep "$s"; attempt
    done ;;
  *) echo "usage: backup.sh loop|once" >&2; exit 2 ;;
esac
