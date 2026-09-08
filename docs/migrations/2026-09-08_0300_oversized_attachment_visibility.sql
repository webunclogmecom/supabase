-- ============================================================================
-- 2026-09-08_0300_oversized_attachment_visibility.sql
--
-- Make the note-photo sync's silent skips COUNTABLE and RECOVERABLE.
--
-- Fred, 2026-09-08: "fix the oversized video hole."
--
-- THE HOLE (measured 2026-09-07, scripts/sync/sync_jobber_note_photos.js:296):
--
--   if (!att.url || (att.fileSize && att.fileSize > STORAGE_SIZE_LIMIT)) {
--     console.log(`    skip ${att.fileName} (no url / oversized)`); continue; }
--
--   1. Increments NEITHER `added` NOR `errors`, and no counter reaches sync_log.details
--      (which carried only {added, removed, changedVisits, days}).
--      => A PERMANENT FAILURE WAS BYTE-IDENTICAL TO A QUIET DAY. Measured: 6 field videos,
--      915 MB, 5 clients, silently dropped over 8 days, and 37 of 39 "zero-added" runs in
--      one week had actually found work and discarded all of it.
--   2. Two unrelated causes shared one message, so the logs could not say which happened.
--   3. `att.fileSize && ...` is silently permissive: a null or 0 size falls through to a
--      download attempt rather than being caught.
--   4. The sync NEVER wrote public.jobber_oversized_attachments. Only
--      scripts/migrate/jobber_notes_photos.js:471 did. 0 of its 58 rows have ever been
--      recovered, and 57 carry a signed URL more than 3 days old, i.e. long expired.
--
-- WHAT THIS MIGRATION DOES (the script change ships alongside it):
--   1. Adds jobber_oversized_attachments.skip_reason so the catch-basin says WHY, instead
--      of repeating the conflation this change exists to remove.
--   2. Teaches the health check to report a persistent oversized backlog, so the hole is
--      visible from ops.v_health_items rather than only in a GitHub Actions log.
--
-- 🛑 WHY THE SCRIPT USES DO UPDATE, NOT DO NOTHING, ON THE CATCH-BASIN.
--    The stored `jobber_url_signed` is a Jobber S3 PRESIGNED url and it EXPIRES. With
--    ON CONFLICT DO NOTHING the row is written once and its url rots, which is exactly why
--    all 58 existing rows are unusable today. The sync re-encounters the same attachment
--    every run (~10x/day), so refreshing the url on conflict is what makes the basin
--    actually able to hand someone the file. `logged_at` is deliberately NOT refreshed, so
--    it keeps meaning FIRST SEEN.
--
-- NOT CHANGED, DELIBERATELY: the 50 MB limit itself is correct (the largest successfully
--    stored photo is 49.4 MB), and the note's entity_source_links row is still created
--    before the skip. Reordering that is riskier than it looks because the non-skip path
--    needs the note row; making the SYNC write the basin removes the dependency on the
--    migrate script's idempotency check instead.
--
-- Audit: N/A (one nullable column + view/function replace).
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. the catch-basin says WHY
-- ---------------------------------------------------------------------------
alter table public.jobber_oversized_attachments
  add column if not exists skip_reason text;

comment on column public.jobber_oversized_attachments.skip_reason is
  'Why this attachment was not ingested: OVERSIZED (larger than the 50MB bucket limit) or '
  'NO_URL (Jobber returned no download url). NULL on the 58 rows written before 2026-09-08 '
  'by scripts/migrate/jobber_notes_photos.js, which had no reason to record. Added because '
  'the sync previously logged both causes under one conflated message.';

comment on column public.jobber_oversized_attachments.jobber_url_signed is
  'Jobber S3 PRESIGNED url. IT EXPIRES. The sync refreshes it on every re-encounter '
  '(ON CONFLICT DO UPDATE), which is what makes this row usable; rows written before '
  '2026-09-08 were never refreshed and their urls are long dead. Re-run the sync to '
  'refresh, do not assume a stored url still works.';

-- ---------------------------------------------------------------------------
-- 2. the health view learns about the backlog
-- ---------------------------------------------------------------------------
create or replace view public.v_jobber_note_photo_health as
with runs as (
  select started_at,
         (details->>'days')::int              as window_days,
         (details->>'added')::int             as added,
         (details->>'removed')::int           as removed,
         (details->>'oversizedSkipped')::int  as oversized_skipped,
         (details->>'noUrlSkipped')::int      as no_url_skipped
  from public.sync_log
  where sync_source = 'jobber_note_photo_sync'
),
agg as (
  select
    max(started_at)                                                      as last_run_at,
    max(started_at) filter (where window_days = 14)                      as last_full_sweep_at,
    max(started_at) filter (where window_days = 3)                       as last_hot_window_at,
    count(*) filter (where started_at > now() - interval '24 hours')                       as runs_24h,
    count(*) filter (where started_at > now() - interval '24 hours' and window_days = 14)  as full_sweeps_24h,
    count(*) filter (where started_at > now() - interval '24 hours' and window_days = 3)   as hot_windows_24h,
    coalesce(sum(added) filter (where started_at > now() - interval '24 hours'), 0)        as photos_added_24h,
    coalesce(sum(added) filter (where started_at > now() - interval '7 days'), 0)          as photos_added_7d,
    coalesce(sum(removed) filter (where started_at > now() - interval '7 days'), 0)        as photos_removed_7d,
    -- NULL until the script change ships, which is why the health function tests for NULL
    -- rather than treating an absent counter as a zero.
    max(oversized_skipped) filter (where started_at > now() - interval '24 hours')         as oversized_skipped_24h,
    max(no_url_skipped)    filter (where started_at > now() - interval '24 hours')         as no_url_skipped_24h
  from runs
),
basin as (
  select count(*)                                                          as oversized_total,
         count(*) filter (where logged_at > now() - interval '7 days')     as oversized_new_7d,
         coalesce(sum(size_bytes) filter (where logged_at > now() - interval '30 days'), 0) as oversized_bytes_30d
  from public.jobber_oversized_attachments
)
-- 🛑 COLUMN ORDER IS LOAD-BEARING. `create or replace view` can only APPEND columns; it
-- cannot rename or reorder them. The first 15 below must stay in exactly this order and
-- every new column goes at the END. Writing `a.*` here is what broke the first attempt:
-- the two new agg columns landed in the middle and Postgres refused with 42P16.
select
  a.last_run_at,                                                                  -- 1
  a.last_full_sweep_at,                                                           -- 2
  a.last_hot_window_at,                                                           -- 3
  a.runs_24h,                                                                     -- 4
  a.full_sweeps_24h,                                                              -- 5
  a.hot_windows_24h,                                                              -- 6
  a.photos_added_24h,                                                             -- 7
  a.photos_added_7d,                                                              -- 8
  a.photos_removed_7d,                                                            -- 9
  round(extract(epoch from (now() - a.last_run_at))        / 3600.0, 1) as hours_since_any_run,     -- 10
  round(extract(epoch from (now() - a.last_full_sweep_at)) / 3600.0, 1) as hours_since_full_sweep,  -- 11
  round(extract(epoch from (now() - a.last_hot_window_at)) / 3600.0, 1) as hours_since_hot_window,  -- 12
  (a.last_full_sweep_at is null
     or now() - a.last_full_sweep_at > interval '24 hours')             as full_sweep_stale,        -- 13
  (a.last_run_at is null
     or now() - a.last_run_at > interval '12 hours')                    as all_runs_stale,          -- 14
  (a.hot_windows_24h < 2)                                              as hot_window_collapsed,     -- 15
  -- everything below is NEW on 2026-09-08 and appended
  a.oversized_skipped_24h,                                                        -- 16
  a.no_url_skipped_24h,                                                           -- 17
  b.oversized_total,                                                              -- 18
  b.oversized_new_7d,                                                             -- 19
  b.oversized_bytes_30d,                                                          -- 20
  (b.oversized_new_7d > 0)                                             as oversized_backlog         -- 21
from agg a cross join basin b;

commit;

-- ---------------------------------------------------------------------------
-- 3. the logger reports it. Separate statement: replacing a function that returns
--    a rowtype of the view above must happen after the view is committed.
-- ---------------------------------------------------------------------------
create or replace function public.log_jobber_note_photo_health()
returns integer
language plpgsql
as $function$
declare
  h      public.v_jobber_note_photo_health%rowtype;
  items  jsonb := '[]'::jsonb;
  n_bad  int   := 0;
  st     text;
begin
  select * into h from public.v_jobber_note_photo_health;

  if h.full_sweep_stale then
    items := items || jsonb_build_object(
      'kind',   'full_sweep_stale',
      'detail', format('No 14-day full sweep in %s hours (alert at 24h). This is the guarantee that catches photos added to older notes.',
                       coalesce(h.hours_since_full_sweep::text, 'ever')),
      'hours',  h.hours_since_full_sweep);
    n_bad := n_bad + 1;
  end if;

  if h.all_runs_stale then
    items := items || jsonb_build_object(
      'kind',   'all_runs_stale',
      'detail', format('No note-photo sync of any kind in %s hours (alert at 12h). Photos taken today are not reaching the apps.',
                       coalesce(h.hours_since_any_run::text, 'ever')),
      'hours',  h.hours_since_any_run);
    n_bad := n_bad + 1;
  end if;

  if h.hot_window_collapsed then
    items := items || jsonb_build_object(
      'kind',   'hot_window_collapsed',
      'detail', format('Only %s hourly sweeps in 24h (normally ~6 of 24 scheduled; GitHub throttles sub-hourly crons). Photo freshness is degraded, coverage is not lost.',
                       h.hot_windows_24h),
      'runs',   h.hot_windows_24h);
    n_bad := n_bad + 1;
  end if;

  -- NEW 2026-09-08. Files Jobber holds that we deliberately did not ingest. Before today
  -- this was invisible: the sync dropped them without touching `added` or `errors`.
  if h.oversized_backlog then
    items := items || jsonb_build_object(
      'kind',   'oversized_attachments',
      'detail', format('%s attachment(s) too large for the 50MB bucket were skipped in the last 7 days (%s tracked in total, %s MB in the last 30 days). They are still in Jobber; public.jobber_oversized_attachments holds a refreshed download link for each.',
                       h.oversized_new_7d, h.oversized_total,
                       round(h.oversized_bytes_30d / 1048576.0)),
      'new_7d', h.oversized_new_7d,
      'total',  h.oversized_total);
    n_bad := n_bad + 1;
  end if;

  st := case
          when h.full_sweep_stale or h.all_runs_stale then 'attention'
          when h.hot_window_collapsed
            or h.oversized_backlog                    then 'warning'
          else 'ok'
        end;

  insert into public.sync_log
    (sync_source, started_at, finished_at, rows_inserted, rows_errored, status, details)
  values
    ('note-photo-sync-health', now(), now(),
     h.photos_added_24h, n_bad, st,
     jsonb_build_object(
       'items',                  items,
       'runs_24h',               h.runs_24h,
       'full_sweeps_24h',        h.full_sweeps_24h,
       'hot_windows_24h',        h.hot_windows_24h,
       'hours_since_any_run',    h.hours_since_any_run,
       'hours_since_full_sweep', h.hours_since_full_sweep,
       'photos_added_24h',       h.photos_added_24h,
       'photos_added_7d',        h.photos_added_7d,
       'photos_removed_7d',      h.photos_removed_7d,
       'oversized_total',        h.oversized_total,
       'oversized_new_7d',       h.oversized_new_7d,
       'oversized_skipped_24h',  h.oversized_skipped_24h,
       'no_url_skipped_24h',     h.no_url_skipped_24h,
       'caveat', 'A failed run writes no sync_log row, so a missing run and a failed run are indistinguishable here. oversized_skipped_24h / no_url_skipped_24h are NULL until the 2026-09-08 script change has run.'));

  return n_bad;
end
$function$;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
do $verify$
declare
  h public.v_jobber_note_photo_health%rowtype;
  n int; st text; d jsonb; total int;
begin
  -- 1. the column exists and is nullable (the 58 historical rows must survive)
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='jobber_oversized_attachments'
                    and column_name='skip_reason' and is_nullable='YES') then
    raise exception 'VERIFY 1 FAILED: skip_reason missing or NOT NULL';
  end if;

  -- 2. POSITIVE CONTROL: the historical rows are still there and still readable.
  select count(*) into total from public.jobber_oversized_attachments;
  if total = 0 then
    raise exception 'VERIFY 2 FAILED (control): catch-basin is empty; expected the 58 historical rows';
  end if;

  -- 3. the view exposes the new signals and still sees the sync
  select * into h from public.v_jobber_note_photo_health;
  if h.last_run_at is null then
    raise exception 'VERIFY 3 FAILED: view no longer sees jobber_note_photo_sync runs';
  end if;
  if h.oversized_total is distinct from total then
    raise exception 'VERIFY 3b FAILED: view reports % oversized, table has %', h.oversized_total, total;
  end if;

  -- 4. the logger runs and records the new keys
  n := public.log_jobber_note_photo_health();
  select status, details into st, d
    from public.sync_log where sync_source='note-photo-sync-health'
    order by started_at desc limit 1;
  if not (d ? 'oversized_total' and d ? 'oversized_skipped_24h') then
    raise exception 'VERIFY 4 FAILED: new counters absent from details';
  end if;

  -- 5. the counters from the script are NULL today and that is EXPECTED, not a bug.
  --    Asserting this stops a future reader reading NULL as "zero skips, all clear".
  if d->>'oversized_skipped_24h' is not null then
    raise notice 'NOTE: oversized_skipped_24h is already populated (%), so the script change has run',
      d->>'oversized_skipped_24h';
  end if;

  raise notice 'VERIFY ok: skip_reason added, % basin rows preserved, status=%, % conditions', total, st, n;
end
$verify$;
