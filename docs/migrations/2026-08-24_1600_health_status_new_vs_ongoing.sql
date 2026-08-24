-- 2026-08-24_1600_health_status_new_vs_ongoing.sql
-- ---------------------------------------------------------------------------
-- Make a health verdict answer "is this NEW?" and "what do I DO about it?".
-- Both are channel-independent: whatever Fred picks as the alert surface (Slack, a
-- staff app, a digest) needs these, and none of it works without them.
--
-- WHY, MEASURED 2026-08-24. public.sync_log is write-only -- swept every file in the
-- workspace against a positive control (647 files mention derm_manifests, so the
-- instrument works); every sync_log hit is a doc, a migration, or a WRITER. But
-- "nobody reads it" is only half the problem, and the smaller half:
--
--   * THE SIGNAL HAS NO DEDUP. Every check re-announces the same unresolved item on
--     every run. jobber_visit_drift is 161 of the last 180 attention rows (89%), and
--     it was re-reporting ONE visit with healable=0 every 30 minutes. Across its
--     history 4,408 item-reports describe 105 distinct problems -- a 42x amplification.
--   * THE SIGNAL HAS NO SEVERITY. 'attention' means "I found and could not fix drift"
--     to jobber_visit_drift and "a compliance document is not viewable online" to
--     blackout-health. Same word, same column, same table.
--   * AND THE PAYLOAD TEXT ITSELF CAN BE WRONG. blackout-health's what_it_means claimed
--     clients "see an EMPTY DERM FOG eManifest card". They do not: the card renders
--     "On file, not available for online viewing", per Field Portal rule 8. Nor is it
--     10 clients - it is 22, because derm.v_blackout_blocked_sheets filters
--     stamp_y_pct IS NOT NULL and cannot see unstamped sheets. An alarm is a claim, and
--     a claim nobody reads is also a claim nobody CHECKS.
--   * IT IS IN THE WRONG TABLE. Health verdicts are 138 of 34,849 sync_log rows
--     (0.40%), under 21,863 Jobber poll records. sync_log is a sync JOURNAL.
--
-- ⚠ CORRECTION, recorded because I published the wrong version first: I described
--   calendar-push-health as being in attention "continuously since 2026-06-27". It is
--   NOT. It has gone 'ok' 10 times; longest attention run is 29 days, current run is 6.
--   That came from reading min(started_at) over the attention rows as the start of an
--   unbroken run. **min() of a filtered set is not a run length.** Use gaps-and-islands.
--   The corrected picture is more useful anyway: calendar-push-health is a WORKING
--   detector (3,423 item-reports over 636 distinct visits, most clearing in days), and
--   rpa-derm-health shows a clean regime change -- 26 consecutive 'ok' then 10
--   consecutive 'attention' from 2026-08-15.
--
-- WHAT THIS SHIPS, and deliberately what it does not:
--
--   1. ops.v_health_status -- one row per health check, carrying the DELTA against the
--      previous run: new_items, resolved_items, unchanged_since_last_run, and how many
--      consecutive runs the current status has held. A daily alert can then say
--      "1 new, 2 ongoing, 3 resolved" instead of re-reading the same list aloud.
--      Proven useful before it was written: the prototype immediately caught
--      blackout-health gaining a NEW sheet (ticket-833395) on 2026-08-24 that appeared
--      and cleared within hours. Nobody would ever have known.
--
--   2. log_blackout_health() now carries the per-sheet `blocker` and `what_to_do` that
--      derm.v_blackout_blocked_sheets ALREADY COMPUTES and the function was throwing
--      away. This is not cosmetic: the static text it emitted instead says "Run a
--      measurement pass", and that advice is WRONG for both currently-blocked sheets
--      and actively dangerous for one of them --
--        ticket-833049  blocker 'held_by_constraint'. DELIBERATELY frozen by
--                       page_block_extents_no_ticket_833049 because effective_page 1
--                       resolves to the physical page 2 image and five clients were
--                       served a page they do not appear on. Measuring it and inserting
--                       an extent is exactly the act that re-opens that leak.
--        window5-sheet3 blocker 'no_stamp_timestamp'. Not a measurement problem at all;
--                       every stamped row has a position but no stamp_placed_at, which
--                       fn_blackout_targets requires. It needs a re-stamp in the Studio.
--      An alarm that names the wrong remedy is worse than one nobody reads.
--
--   NO NEW WRITER, NO NEW TABLE, NO NEW CRON. A view over existing rows cannot itself
--   become another unread channel, and it needs no backfill. The four log_*_health()
--   functions keep writing to sync_log exactly as before (except blackout's richer
--   payload), so nothing that reads sync_log today changes behaviour.
--
--   THE ALERT SURFACE IS DELIBERATELY NOT CHOSEN HERE. That is Fred's call and the
--   whole point is that guessing produces another channel nobody reads. Reconnaissance
--   worth knowing when he decides: ALL 33 ops.* views are already SELECT-granted to
--   `authenticated`, so a staff-app surface needs no new grant and no edge function.
--   ⚠ Whatever is chosen must be a STAFF surface. Never the Field Portal: standing rule
--   from Yannick via Fred 2026-08-24, "on the customer-facing Field Portal, if we do not
--   have something, DO NOT SHOW IT".
--
-- Audit (Rule 8): one view and one function body. No table, no column, no grant on any
-- audited table changes. audit.logs is untouched and no audit opt-in list changes.
--
-- Grants: ops.v_health_status matches the other 33 ops views -- SELECT to authenticated
-- and service_role. It exposes operational health only: check names, counts, item keys
-- (visit ids, dump folders) and remediation text. No client PII, no addresses.
--
-- @Building Apps. Claimed in WORKING-NOW.md. No Lovable project touched.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Carry the remediation the source view already knows.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_blackout_health()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'derm', 'pg_temp'
AS $fn$
declare
  v_sheets    int := 0;
  v_clients   int := 0;
  v_manifests int := 0;
  v_oldest    interval;
  v_detail    jsonb;
  v_attn      boolean := false;
begin
  select count(*),
         coalesce(sum(clients_blocked), 0),
         coalesce(sum(manifests_blocked), 0),
         max(blocked_for)
    into v_sheets, v_clients, v_manifests, v_oldest
    from derm.v_blackout_blocked_sheets;

  v_attn := v_sheets > 0;

  -- blocker + what_to_do are the point of this change. The view computes a DIFFERENT
  -- remedy per sheet and the old payload replaced all of them with one static line.
  select coalesce(jsonb_agg(jsonb_build_object(
           'dump_folder',       b.dump_folder,
           'blocker',           b.blocker,
           'what_to_do',        b.what_to_do,
           'stamped_rows',      b.stamped_rows,
           'stamped_pages',     b.stamped_pages,
           'rows_ready',        b.rows_ready,
           'rows_no_stamp_ts',  b.rows_no_stamp_ts,
           'clients_blocked',   b.clients_blocked,
           'manifests_blocked', b.manifests_blocked,
           'blocked_for',       b.blocked_for::text) order by b.last_stamp_at), '[]'::jsonb)
    into v_detail
    from derm.v_blackout_blocked_sheets b;

  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('blackout-health', now(), now(), v_sheets,
          case when v_attn then 'attention' else 'ok' end,
          jsonb_build_object(
            'blocked_sheets',    v_sheets,
            'clients_blocked',   v_clients,
            'manifests_blocked', v_manifests,
            'oldest_blocked_for', v_oldest::text,
            'sheets',            v_detail,
            'what_it_means',     case when v_attn
              then 'These address sheets are stamped but produce no redacted sheet, so those clients have no DERM FOG eManifest. READ THE PER-SHEET blocker AND what_to_do: the remedy differs by sheet and is NOT always a measurement pass. blocker=held_by_constraint means the sheet is DELIBERATELY frozen and measuring it would re-open a cross-client leak; blocker=no_stamp_timestamp needs a re-stamp in the Studio, not a measurement.'
              else 'Every stamped address-sheet page has a measured extent.' end));

  return v_sheets;
end $fn$;

COMMENT ON FUNCTION public.log_blackout_health() IS
  'Daily blackout health verdict into public.sync_log. Carries the per-sheet blocker and what_to_do from derm.v_blackout_blocked_sheets: the remedy differs by sheet and the previous static text ("run a measurement pass") was wrong for both blocked sheets as of 2026-08-24, and would have re-opened a cross-client leak on ticket-833049. See 2026-08-19_2355 PART 5.';

-- ---------------------------------------------------------------------------
-- 2. The delta view: is this NEW, or the same thing we said yesterday?
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW ops.v_health_status AS
WITH runs AS (
  SELECT l.id, l.sync_source, l.status, l.started_at, l.rows_errored, l.details,
         row_number() OVER (PARTITION BY l.sync_source ORDER BY l.started_at DESC) AS rn,
         -- Each check names its item array differently. Normalise to one shape.
         -- ⚠ A new health check MUST be added here or it silently reports 0 items and
         --   every run looks "unchanged". Adding a check is a two-line change, not a
         --   free one.
         CASE l.sync_source
           WHEN 'calendar-push-health'  THEN coalesce(l.details->'items',   '[]'::jsonb)
           WHEN 'blackout-health'       THEN coalesce(l.details->'sheets',  '[]'::jsonb)
           WHEN 'rpa-derm-health'       THEN coalesce(l.details->'reasons', '[]'::jsonb)
           WHEN 'sa-schedule-gap-check' THEN coalesce(l.details->'sample',  '[]'::jsonb)
           ELSE '[]'::jsonb
         END AS raw_items
  FROM public.sync_log l
  WHERE l.sync_source IN ('calendar-push-health','blackout-health','rpa-derm-health','sa-schedule-gap-check')
),
keyed AS (
  SELECT r.*,
         coalesce((
           SELECT jsonb_agg(DISTINCT
             coalesce(i->>'visit_id', i->>'dump_folder', i->>'kind', i->>'client_code', i::text))
           FROM jsonb_array_elements(r.raw_items) i), '[]'::jsonb) AS item_keys
  FROM runs r
  WHERE r.rn <= 2
),
-- How long has the CURRENT status held? Gaps-and-islands, because min(started_at)
-- over the filtered rows is NOT a run length -- that mistake is what produced the
-- false "continuously since 2026-06-27" claim this migration corrects.
streak AS (
  SELECT sync_source, status, count(*) AS runs_in_streak,
         min(started_at) AS streak_started_at
  FROM (
    SELECT l.sync_source, l.status, l.started_at,
           row_number() OVER (PARTITION BY l.sync_source ORDER BY l.started_at DESC)
         - row_number() OVER (PARTITION BY l.sync_source, l.status ORDER BY l.started_at DESC) AS grp
    FROM public.sync_log l
    WHERE l.sync_source IN ('calendar-push-health','blackout-health','rpa-derm-health','sa-schedule-gap-check')
  ) g
  GROUP BY sync_source, status, grp
  HAVING max(started_at) = (SELECT max(l2.started_at) FROM public.sync_log l2
                             WHERE l2.sync_source = g.sync_source)
),
cur  AS (SELECT * FROM keyed WHERE rn = 1),
prev AS (SELECT * FROM keyed WHERE rn = 2)
SELECT
  c.sync_source                                                     AS check_name,
  c.status,
  c.started_at                                                      AS last_run_at,
  -- ⚠ item_count is the length of the normalised item array, NOT sync_log.rows_errored.
  --   rows_errored means something different in every check: for rpa-derm-health it is
  --   queue_depth, which was 0 on 2026-08-24 while the check was firing on 1 reason.
  --   Binding a dashboard to rows_errored shows "0 items" on a live alarm.
  jsonb_array_length(c.item_keys)                                   AS item_count,
  coalesce(jsonb_array_length(p.item_keys), 0)                      AS item_count_previous_run,
  c.rows_errored                                                    AS rows_errored_raw,
  -- present now, absent last run
  (SELECT coalesce(jsonb_agg(k), '[]'::jsonb)
     FROM jsonb_array_elements(c.item_keys) k
    WHERE NOT (coalesce(p.item_keys, '[]'::jsonb) @> jsonb_build_array(k)))  AS new_items,
  -- present last run, absent now
  (SELECT coalesce(jsonb_agg(k), '[]'::jsonb)
     FROM jsonb_array_elements(coalesce(p.item_keys, '[]'::jsonb)) k
    WHERE NOT (c.item_keys @> jsonb_build_array(k)))                        AS resolved_items,
  -- the whole point: suppress this from a daily alert, keep it in a weekly digest
  (c.item_keys = coalesce(p.item_keys, '[]'::jsonb))                 AS unchanged_since_last_run,
  s.runs_in_streak                                                   AS consecutive_runs_same_status,
  s.streak_started_at                                                AS status_since,
  c.details
FROM cur c
LEFT JOIN prev   p ON p.sync_source = c.sync_source
LEFT JOIN streak s ON s.sync_source = c.sync_source AND s.status = c.status;

COMMENT ON VIEW ops.v_health_status IS
  'One row per health check with the DELTA against its previous run. new_items / resolved_items / unchanged_since_last_run exist because the raw sync_log signal has no dedup: every check re-announces the same unresolved item on every run (jobber_visit_drift produced 4,408 item-reports describing 105 distinct problems). consecutive_runs_same_status is computed gaps-and-islands, not from min(started_at) over filtered rows, which is what produced a false "continuously since" claim on 2026-08-24. ⚠ A new health check must be added to the CASE in this view or it silently reports 0 items and always looks unchanged. Added 2026-08-24.';

GRANT SELECT ON ops.v_health_status TO authenticated, service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- VERIFY (run after applying; every assertion must hold)
--
-- 1. the view returns one row per health check, and all four are present
--    select check_name, status, item_count, unchanged_since_last_run,
--           consecutive_runs_same_status from ops.v_health_status order by 1;
--    -- expect 4 rows: blackout-health, calendar-push-health, rpa-derm-health,
--    --                sa-schedule-gap-check
--
-- 2. POSITIVE CONTROL, so an all-quiet is not a broken instrument. The delta must be
--    able to SEE a change. On 2026-08-24 blackout-health went from 2 sheets to 3
--    (ticket-833395 appeared, then cleared), so run it against that pair explicitly:
--    select sync_source, (started_at at time zone 'America/New_York')::text,
--           jsonb_array_length(details->'sheets') from public.sync_log
--     where sync_source='blackout-health' order by started_at desc limit 3;
--    -- expect the counts to differ across runs; if every run has the same count,
--    -- pick another source before trusting a "no change" result.
--
-- 3. MUTATION TEST the normaliser. A check whose sync_source is not in the CASE
--    reports 0 items and therefore ALWAYS looks unchanged -- the exact false all-clear
--    this view exists to prevent. Confirm every source the crons write is covered:
--    select distinct sync_source from public.sync_log
--     where sync_source ~ 'health|gap-check'
--       and sync_source not in ('calendar-push-health','blackout-health',
--                               'rpa-derm-health','sa-schedule-gap-check');
--    -- expect 0 rows. If this ever returns one, that check is invisible to the view.
--
-- 4. the blackout payload now carries the per-sheet remedy
--    select jsonb_pretty(details->'sheets') from public.sync_log
--     where sync_source='blackout-health' order by started_at desc limit 1;
--    -- expect every element to have BOTH 'blocker' and 'what_to_do'
--    -- ⚠ only true after the next cron run (0 12 * * *) or an explicit
--    --   select public.log_blackout_health(); the existing rows are unchanged.
--
-- 5. grants match the other ops views, and no anon
--    select grantee, privilege_type from information_schema.role_table_grants
--     where table_schema='ops' and table_name='v_health_status' order by 1;
--    -- expect authenticated + service_role SELECT; no anon
