-- =====================================================================
-- 2026-08-03_1900  Drift card: true drift onset, and make staleness visible
-- =====================================================================
-- WHY — both defects found by @Supabase 2 while building the "Sync from Jobber" button on this
-- card. Both are mine; both were live.
--
-- DEFECT 1 — `since` was the RUN's started_at, not the onset of the drift.
--   Every surfaced card therefore claimed the disagreement began at the last poll. Measured before
--   the fix, all three live cards read "08-03 18:30" (20 minutes ago) while the truth was:
--       043-MIL   drifting since 08-03 15:30   (3 hours)
--       241-WYN   drifting since 08-03 16:00   (2.5 hours)
--       083-SHUL  drifting since 07-16 17:00   (18 DAYS)
--   An operator triaging that list sees three equally-fresh problems and cannot tell the 18-day-old
--   one from the ones that appeared this afternoon. `since` now reports the onset of the CURRENT
--   drift episode — the earliest run in which the visit has appeared continuously since the last run
--   in which it did NOT appear. Deliberately not the all-time first sighting: a visit that drifted,
--   was resolved, and drifted again should date from the second episode.
--
-- DEFECT 2 — the card is built from ONE sync_log row and never says how old that reading is.
--   The branch reads the latest run that HAS a `surfaced_visits` key. @Supabase 2 called this a
--   disappear-on-error hazard; measured, it is slightly different and arguably worse. An errored run
--   writes `details:{error:...}` with NO `surfaced_visits` key, so it is SKIPPED rather than
--   emptying the list — the cards do not vanish, they go STALE while still looking current. There
--   have been 0 error runs in 30 days so it has not bitten yet, but nothing on the card would show
--   it if it did.
--   `observed_at` is now exposed on ops.v_calendar_push_health_by_visit so the UI can render "as of
--   HH:MM" and warn when the reading is old. Appending at the end is the only column-list change
--   CREATE OR REPLACE VIEW permits.
--
-- ⚠ WHAT THIS DOES NOT FIX: the surfaced-visits history is NOT a general ledger of Jobber values.
--   A visit only appears in `surfaced_visits` while it is drifting AND ambiguous, so the record has
--   real gaps — visit 7065 has none between 07-29 18:00Z and 07-30 21:30Z. Good enough for "when did
--   THIS drift start", not good enough to answer "what did Jobber hold at time T" for an arbitrary
--   visit. Anyone building the forward-only last-writer-wins signal on it should read that limit first.
--
-- AUDIT OPT-IN (rule #8): views only, no table change.
-- REVERSIBLE: yes. `since` reverts to `sl.started_at`; dropping `observed_at` needs DROP+CREATE
--   (CREATE OR REPLACE cannot remove a column) plus re-granting — see [[reference_drop_view_discards_grants]].
-- =====================================================================

begin;

create or replace view ops.v_calendar_push_health as
SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'push_failed'::text AS issue,
    f.reason,
    f.detail,
    f.created_at AS since
   FROM ((visit_sync_flags f
     JOIN visits v ON ((v.id = f.visit_id)))
     JOIN clients c ON ((c.id = v.client_id)))
  WHERE ((f.resolved_at IS NULL) AND (v.deleted_at IS NULL))
UNION ALL
 SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'not_in_jobber'::text AS issue,
    NULL::text AS reason,
    NULL::text AS detail,
    v.created_at AS since
   FROM (visits v
     JOIN clients c ON ((c.id = v.client_id)))
  WHERE ((v.source = ANY (ARRAY['visit-calendar'::text, 'supabase_cron'::text])) AND (v.visit_status = 'scheduled'::text) AND (v.deleted_at IS NULL) AND (v.created_at < (now() - '00:15:00'::interval)) AND fn_visit_in_jobber_scope(v.id) AND (NOT (EXISTS ( SELECT 1
           FROM entity_source_links e
          WHERE ((e.entity_type = 'visit'::text) AND (e.source_system = 'jobber'::text) AND (e.entity_id = v.id))))))
UNION ALL
 SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'skip_removal_failed'::text AS issue,
    'skipped visit still linked to Jobber (removal did not complete)'::text AS reason,
    v.sync_state AS detail,
    v.updated_at AS since
   FROM (visits v
     JOIN clients c ON ((c.id = v.client_id)))
  WHERE ((v.visit_status = 'skipped'::text) AND (v.deleted_at IS NULL) AND (EXISTS ( SELECT 1
           FROM entity_source_links e
          WHERE ((e.entity_type = 'visit'::text) AND (e.source_system = 'jobber'::text) AND (e.entity_id = v.id)))))
UNION ALL
 SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.source,
    'drift_surfaced'::text AS issue,
    (sv.sv ->> 'reason'::text) AS reason,
        CASE (sv.sv ->> 'reason'::text)
            WHEN 'jobber_date_differs'::text THEN (('Jobber has this visit on a different day ('::text || COALESCE((sv.sv ->> 'jobber_date'::text), '?'::text)) || ') than we do. Decide which is right - syncing from Jobber will move the visit.'::text)
            WHEN 'jobber_all_day_vs_our_time'::text THEN 'Same day in both, but Jobber has no set time (all-day) while we have one. Syncing from Jobber will clear the time.'::text
            WHEN 'jobber_time_differs'::text THEN 'Same day in both, but the times differ. Syncing from Jobber will use Jobber''s time.'::text
            WHEN 'audit_read_fail'::text THEN 'We could not read this visit''s edit history, so the difference was not classified. It is re-checked every run.'::text
            ELSE 'Our schedule and Jobber''s disagree and the reconciler could not resolve it safely.'::text
        END AS detail,
    onset.first_seen AS since
   FROM (((( SELECT sync_log.started_at,
            sync_log.details
           FROM sync_log
          WHERE ((sync_log.sync_source = 'jobber_visit_drift'::text) AND (sync_log.details ? 'surfaced_visits'::text))
          ORDER BY sync_log.started_at DESC
         LIMIT 1) sl
     CROSS JOIN LATERAL jsonb_array_elements((sl.details -> 'surfaced_visits'::text)) sv(sv))
     JOIN visits v ON (((v.id = ((sv.sv ->> 'id'::text))::bigint) AND (v.deleted_at IS NULL) AND (v.visit_status = 'scheduled'::text))))
     JOIN clients c ON ((c.id = v.client_id)))
     LEFT JOIN LATERAL (
       -- onset of the CURRENT drift episode: the earliest run in which this visit has appeared
       -- CONTINUOUSLY since the last run where it did NOT appear. Not the latest run time, and
       -- not the all-time first sighting either — a visit that drifted, was fixed, and drifted
       -- again should date from the SECOND episode.
       SELECT min(r.started_at) AS first_seen
         FROM sync_log r
        WHERE r.sync_source = 'jobber_visit_drift'::text
          AND (r.details ? 'surfaced_visits'::text)
          AND EXISTS (SELECT 1 FROM jsonb_array_elements((r.details -> 'surfaced_visits'::text)) e
                       WHERE ((e ->> 'id'::text))::bigint = v.id)
          AND r.started_at > COALESCE((
                SELECT max(r2.started_at) FROM sync_log r2
                 WHERE r2.sync_source = 'jobber_visit_drift'::text
                   AND (r2.details ? 'surfaced_visits'::text)
                   AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements((r2.details -> 'surfaced_visits'::text)) e2
                                    WHERE ((e2 ->> 'id'::text))::bigint = v.id)
              ), '-infinity'::timestamptz)
     ) onset ON (true);

create or replace view ops.v_calendar_push_health_by_visit as
SELECT DISTINCT ON (h.visit_id) h.visit_id,
    h.client_code,
    h.client_name,
    h.visit_date,
    h.source,
    h.issue,
    h.reason,
    h.detail,
    h.since,
        CASE
            WHEN (h.issue = 'drift_surfaced'::text) THEN NULL::bigint
            ELSE fn_visit_push_duplicate_of(h.visit_id)
        END AS duplicate_of_visit_id,
    COALESCE(f.attempts, 0) AS attempts,
    f.auto_retry_state,
    f.next_attempt_at,
    ( SELECT array_agg(DISTINCT h2.issue) AS array_agg
           FROM ops.v_calendar_push_health h2
          WHERE (h2.visit_id = h.visit_id)) AS all_issues,
    (h.issue = ANY (ARRAY['not_in_jobber'::text, 'push_failed'::text])) AS is_auto_retryable,
    ( SELECT max(sl2.started_at) FROM sync_log sl2
       WHERE sl2.sync_source = 'jobber_visit_drift'::text
         AND (sl2.details ? 'surfaced_visits'::text)) AS observed_at
   FROM (ops.v_calendar_push_health h
     LEFT JOIN visit_sync_flags f ON (((f.visit_id = h.visit_id) AND (f.resolved_at IS NULL))))
  ORDER BY h.visit_id,
        CASE h.issue
            WHEN 'push_failed'::text THEN 1
            WHEN 'skip_removal_failed'::text THEN 2
            WHEN 'not_in_jobber'::text THEN 3
            WHEN 'drift_surfaced'::text THEN 4
            ELSE 5
        END;

-- ---------------------------------------------------------------------
-- ASSERTIONS
-- ---------------------------------------------------------------------
do $$
declare n int; n_same int; v_txt text;
begin
  -- observed_at must exist and be populated
  if not exists (select 1 from information_schema.columns
                  where table_schema='ops' and table_name='v_calendar_push_health_by_visit'
                    and column_name='observed_at') then
    raise exception 'observed_at was not added';
  end if;
  select count(*) into n from ops.v_calendar_push_health_by_visit
   where issue='drift_surfaced' and observed_at is null;
  if n > 0 then raise exception '% surfaced row(s) have a null observed_at', n; end if;

  -- `since` must be populated for every surfaced row
  select count(*) into n from ops.v_calendar_push_health_by_visit
   where issue='drift_surfaced' and since is null;
  if n > 0 then raise exception '% surfaced row(s) lost their since', n; end if;

  -- THE POINT OF THE CHANGE: `since` must no longer be identical to the run time on every row.
  -- Before the fix all three cards carried the same value. If they still do, the lateral is not
  -- doing anything and this migration is a no-op wearing a hat.
  select count(*) into n_same from ops.v_calendar_push_health_by_visit
   where issue='drift_surfaced' and since = observed_at;
  select count(*) into n from ops.v_calendar_push_health_by_visit where issue='drift_surfaced';
  if n > 1 and n_same = n then
    raise exception 'NEGATIVE CONTROL: all % surfaced rows still show since = run time; onset lateral did nothing', n;
  end if;

  -- and the onset must never be in the future or after the reading
  select count(*) into n from ops.v_calendar_push_health_by_visit
   where issue='drift_surfaced' and since > observed_at;
  if n > 0 then raise exception '% row(s) claim a drift onset AFTER the reading', n; end if;

  select string_agg(client_code || ' since ' ||
           to_char(since at time zone 'America/New_York','MM-DD HH24:MI'), ' | ' order by client_code)
    into v_txt
    from ops.v_calendar_push_health_by_visit where issue='drift_surfaced';
  raise notice 'DRIFT ONSET OK -> %', coalesce(v_txt,'(nothing surfaced)');
end $$;

commit;
