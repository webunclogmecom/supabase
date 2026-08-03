-- =====================================================================
-- 2026-08-03_1730  Drift warning: say what actually differs, and stop asserting a person did it
-- =====================================================================
-- WHY
--   Fred, looking at the 241-WYN card: "didn't we set a rule of showing that kind of warning when
--   it's uncertain if the change on jobber was before or after a change done in the calendar?"
--
--   The card said: "This visit was changed in Jobber by a person and our copy disagrees. Someone
--   needs to decide which one is right - retrying would overwrite their change."
--   Both halves of that were wrong for that visit:
--     * It is NOT a date conflict. Both sides say 2026-08-07. We hold 5:00 PM ET; Jobber has it
--       all-day. It is surfaced by a deliberate guard that refuses to let a Jobber all-day flag
--       silently wipe an office-set time.
--     * NOBODY changed it in Jobber. That 5:00 PM originally CAME FROM Jobber on 07-30
--       (audit app_source='jobber', start NULL -> 21:00); the office only moved the DATE a week
--       later and carried the time along. The view printed "changed by a person" for every surfaced
--       visit without ever checking.
--   Measured the same day: of the 3 visits surfaced, only ONE (083-SHUL, DB 2027-01-01 vs Jobber
--   2026-08-04) was a genuine which-day conflict. The other two were same-date time differences.
--
-- WHAT CHANGES
--   The reconciler now emits a precise reason instead of the single catch-all
--   'jobber_value_unexpected':
--     jobber_date_differs         - genuine disagreement about the DAY
--     jobber_all_day_vs_our_time  - same day; Jobber untimed, we have a time
--     jobber_time_differs         - same day, both timed, clock times differ
--   and these views render wording that matches. 'jobber_value_unexpected' is kept as the ELSE
--   branch so rows surfaced by the OLD reconciler still read sensibly until the next run replaces
--   them (the views read only the LATEST jobber_visit_drift sync_log row).
--
-- 🛑 WHAT IS DELIBERATELY *NOT* BUILT: automatic last-writer-wins.
--   Fred asked for "whoever changed it last wins, Jobber dominates, unless it is inside the sync-lag
--   window". It is not implementable from the data we have, and building it would be actively
--   dangerous. Measured 2026-08-03:
--     * Jobber's Visit type has NO updatedAt. Introspected: completedAt, createdAt, createdBy,
--       endAt, startAt. There is no last-modified field to compare against our audit timestamp.
--     * webhook_events_log VISIT_UPDATE.occurredAt looks like the missing clock and is NOT.
--       The three surfaced visits carry 305 / 306 / 233 events against roughly 6 real schedule
--       changes each, arriving on a perfectly regular 2.5-hour cadence (17:15, 14:45, 12:15,
--       09:45, 07:15 ...) in batches of ~25 visits. It is a churn/poll signal, not a human edit.
--       A rule of "max(occurredAt) > our_edit + 5 min -> adopt" is TRUE for essentially every
--       drifted visit and would silently overwrite office edits with Jobber values - precisely the
--       auto-revert the reconciler exists to refuse.
--   A real automatic rule needs a genuine "Jobber changed at" signal, i.e. recording when the
--   OBSERVED Jobber startAt actually CHANGES between polls. That is a separate build and would only
--   work going forward, never retroactively.
--
--   Instead, the human decides in one click: edge function `adopt-visit-from-jobber` (staff-
--   authenticated, reads Jobber live, calls the existing service_role
--   public.adopt_visit_schedule_from_jobber with its optimistic-concurrency guard).
--
-- AUDIT OPT-IN (rule #8): views only, no table change.
-- REVERSIBLE: yes, both views are CREATE OR REPLACE with unchanged column lists.
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
            WHEN 'jobber_date_differs'::text THEN
              ('Jobber has this visit on a different day (' || COALESCE(sv.sv ->> 'jobber_date'::text,'?') ||
               ') than we do. Decide which is right - syncing from Jobber will move the visit.')
            WHEN 'jobber_all_day_vs_our_time'::text THEN
              'Same day in both, but Jobber has no set time (all-day) while we have one. Syncing from Jobber will clear the time.'
            WHEN 'jobber_time_differs'::text THEN
              'Same day in both, but the times differ. Syncing from Jobber will use Jobber''s time.'
            WHEN 'audit_read_fail'::text THEN
              'We could not read this visit''s edit history, so the difference was not classified. It is re-checked every run.'
            ELSE 'Our schedule and Jobber''s disagree and the reconciler could not resolve it safely.'
        END AS detail,
    sl.started_at AS since
   FROM (((( SELECT sync_log.started_at,
            sync_log.details
           FROM sync_log
          WHERE ((sync_log.sync_source = 'jobber_visit_drift'::text) AND (sync_log.details ? 'surfaced_visits'::text))
          ORDER BY sync_log.started_at DESC
         LIMIT 1) sl
     CROSS JOIN LATERAL jsonb_array_elements((sl.details -> 'surfaced_visits'::text)) sv(sv))
     JOIN visits v ON (((v.id = ((sv.sv ->> 'id'::text))::bigint) AND (v.deleted_at IS NULL) AND (v.visit_status = 'scheduled'::text))))
     JOIN clients c ON ((c.id = v.client_id)));

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
    (h.issue = ANY (ARRAY['not_in_jobber'::text, 'push_failed'::text])) AS is_auto_retryable
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
declare n int; v_detail text;
begin
  -- the false claim must be gone from BOTH views
  select count(*) into n from pg_views
   where schemaname='ops' and viewname in ('v_calendar_push_health','v_calendar_push_health_by_visit')
     and definition like '%by a person%';
  if n > 0 then
    raise exception '% view(s) still assert a person made the Jobber change', n;
  end if;

  -- both views must still return their columns and be queryable
  perform 1 from ops.v_calendar_push_health limit 1;
  perform 1 from ops.v_calendar_push_health_by_visit limit 1;

  -- the detail column must still be populated for whatever is surfaced right now
  select count(*) into n from ops.v_calendar_push_health_by_visit
   where issue = 'drift_surfaced' and (detail is null or detail = '');
  if n > 0 then
    raise exception '% surfaced row(s) have an empty detail', n;
  end if;

  -- and the wording must actually vary by reason, not be one string again
  select string_agg(distinct left(detail, 40), ' | ') into v_detail
    from ops.v_calendar_push_health where issue = 'drift_surfaced';
  raise notice 'surfaced detail variants now: %', coalesce(v_detail, '(nothing surfaced right now)');

  raise notice 'PUSH-HEALTH COPY OK - person claim removed, details populated';
end $$;

commit;
