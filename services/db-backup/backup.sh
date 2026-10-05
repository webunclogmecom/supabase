#!/usr/bin/env bash
# Own copy of the Prod database every 2 hours, plus one full copy a day, on a Railway volume.
# Fred, 2026-10-05: "Go with the 2-hour copy on Railway" (instead of PITR, which is off).
# Setup, restore and the reasons: README.md next to this file.
#
# Usage:  backup.sh loop    (Railway start command: run now, then on every 2-hour slot)
#         backup.sh once    (one run, for tests)
# Connection: the standard libpq variables PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE (login db_backup_reader).
# Options: BACKUP_DIR (/data), KEEP_2H (24), KEEP_DAILY (14), INTERVAL_HOURS (2), SLOT_MINUTE (17),
#          DAILY_AFTER_HOURS (23), HEARTBEAT (on | dry | off), DUMP_TIMEOUT (45m)
set -uo pipefail

BACKUP_DIR="${BACKUP_DIR:-/data}"
KEEP_2H="${KEEP_2H:-24}"
KEEP_DAILY="${KEEP_DAILY:-14}"
INTERVAL_HOURS="${INTERVAL_HOURS:-2}"
SLOT_MINUTE="${SLOT_MINUTE:-17}"
DAILY_AFTER_HOURS="${DAILY_AFTER_HOURS:-23}"
HEARTBEAT="${HEARTBEAT:-on}"
DUMP_TIMEOUT="${DUMP_TIMEOUT:-45m}"
export PGCONNECT_TIMEOUT=30 PGAPPNAME=db-backup PGSSLMODE="${PGSSLMODE:-require}"

# Business schemas. Not vault (secrets), auth/storage (Supabase-managed), cron/net/realtime (logs).
SCHEMAS=(public derm ops client sync raw customer hr)
# Never copied: Jobber/Samsara OAuth tokens and the client secret (the login cannot read it anyway).
EXCLUDE_TABLE=(public.webhook_tokens)
# Re-creatable bulk, left out of the 2-hour copy only: Samsara telemetry (Samsara keeps months of it)
# and two logs. The daily copy has everything, plus the audit history.
EXCLUDE_DATA_2H=(public.vehicle_telemetry_readings public.webhook_events_log public.sync_log)

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

heartbeat() { # status kind seconds bytes sha256 file message
  [ "$HEARTBEAT" = off ] && return 0
  local end=COMMIT; [ "$HEARTBEAT" = dry ] && end=ROLLBACK
  psql -X -q -v ON_ERROR_STOP=1 -v st="$1" -v kind="$2" -v secs="$3" -v bytes="$4" -v sha="$5" -v file="$6" -v msg="$7" <<SQL
begin;
insert into public.sync_log (sync_source, started_at, finished_at, duration_seconds, status, details, error_details)
values ('db_backup', now() - make_interval(secs => :'secs'::numeric), now(), :'secs'::numeric, :'st',
        jsonb_build_object('kind', :'kind', 'bytes', :'bytes'::bigint, 'sha256', :'sha', 'file', :'file'),
        case when :'msg' = '' then null else jsonb_build_object('message', :'msg') end);
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

run_once() {
  local kind=two_hourly keep=$KEEP_2H
  if [ "$(newest_age_hours "$BACKUP_DIR/daily")" -ge "$DAILY_AFTER_HOURS" ]; then kind=daily; keep=$KEEP_DAILY; fi
  local dir="$BACKUP_DIR/$kind"; mkdir -p "$dir"
  local file="$dir/prod_${kind}_$(date -u +%Y%m%dT%H%M%SZ).dump" err="$dir/.last_error"
  local args=(-Fc -Z 6 --no-password)
  for s in "${SCHEMAS[@]}"; do args+=(-n "$s"); done
  [ "$kind" = daily ] && args+=(-n audit)
  for t in "${EXCLUDE_TABLE[@]}"; do args+=(--exclude-table="$t"); done
  [ "$kind" = two_hourly ] && for t in "${EXCLUDE_DATA_2H[@]}"; do args+=(--exclude-table-data="$t"); done

  local t0; t0=$(date +%s)
  log "start $kind -> $(basename "$file")"
  if timeout "$DUMP_TIMEOUT" pg_dump "${args[@]}" -f "$file.partial" 2>"$err" \
     && pg_restore --list "$file.partial" >"$file.toc" 2>>"$err" \
     && [ "$(grep -c ' TABLE DATA ' "$file.toc")" -ge 50 ]; then
    mv -- "$file.partial" "$file"; rm -f -- "$file.toc" "$err"
    local bytes sha secs; bytes=$(stat -c %s "$file"); sha=$(sha256sum "$file" | cut -d' ' -f1)
    echo "$sha  $(basename "$file")" >"$file.sha256"
    secs=$(( $(date +%s) - t0 ))
    prune "$dir" "$keep"
    log "ok $kind bytes=$bytes secs=$secs"
    heartbeat success "$kind" "$secs" "$bytes" "$sha" "$(basename "$file")" "" || log "heartbeat failed"
  else
    local msg; msg=$(tail -c 400 "$err" 2>/dev/null | tr '\n' ' ')
    [ -z "$msg" ] && msg="dump produced fewer than 50 tables of data"
    rm -f -- "$file.partial" "$file.toc"
    log "FAILED $kind: $msg"
    heartbeat error "$kind" "$(( $(date +%s) - t0 ))" 0 "" "" "$msg" || log "heartbeat failed"
    return 1
  fi
}

seconds_to_next_slot() { # next HH:SLOT_MINUTE on an INTERVAL_HOURS grid, UTC
  local now step off next
  now=$(date +%s); step=$(( INTERVAL_HOURS * 3600 )); off=$(( SLOT_MINUTE * 60 ))
  next=$(( ( (now - off) / step + 1 ) * step + off ))
  echo $(( next - now ))
}

case "${1:-loop}" in
  once) run_once ;;
  loop) while true; do run_once; s=$(seconds_to_next_slot); log "next run in ${s}s"; sleep "$s"; done ;;
  *) echo "usage: backup.sh loop|once" >&2; exit 2 ;;
esac
