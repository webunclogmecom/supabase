-- ============================================================================================
-- 2026-09-07_1440_billing_observation_health_counts.sql
--
-- COUNT-ONLY billing observation numbers in log_jobber_sync_health(). Completes phase A.
--
-- 🛑 IT CANNOT ALERT, AND THAT IS THE POINT. Nothing is appended to `items` and nothing is added
-- to v_total, so this cannot raise an alert, change the check's status, or mail anyone. Three
-- reasons, in order of weight:
--   1. EVERY PHASE-A FINDING IS UNRESOLVABLE BY CONSTRUCTION. The only writer of these columns is
--      fn_record_client_job, and the operator's obvious response (re-save in the Client App)
--      derives billing from the job TITLE and pushes OUR value over Jobber's. An alert with no safe
--      button is how calendar-task-poll re-reported one item 3,008 times in 11 days. Phase B has to
--      answer "who is authoritative" before a finding has anywhere to go.
--   2. Fred set this precedent on 2026-09-03 for the 15 drift counters: a week of numbers before
--      any threshold. A threshold chosen before there is data is a guess.
--   3. Measured drift is ZERO across 483 observed jobs, so the first thing an alert reported would
--      also be the thing that calibrated it.
--
-- ⚠ WHEN AN ALERT ITEM IS EVENTUALLY ADDED it must be keyed `billing_drift:<job_id>:<field>`.
--   ops.v_health_items derives item_key from
--   COALESCE(visit_id, dump_folder, kind, client_code, value::text), so a FLAT kind collapses every
--   drifted job into ONE item and fixing one job would read as resolving all of them. And a
--   DUPLICATE item_key raises 21000 inside the view, which would silently kill the daily escalation
--   email for ALL FIVE health checks, not just this one.
--
-- TWO COMPARISON RULES, both measured, both easy to get wrong:
--   * Compare the periodic CLASS, not the label. 'monthly_last_day' and 'custom' are both PERIODIC
--     to Jobber, and save-client-job legitimately accepts 'custom' carrying the month-end rule, so
--     a label comparison manufactures drift. KNOWN BLIND SPOT, accepted: a pure label divergence is
--     therefore invisible to this check.
--   * Canonicalise BOTH rrules. Our stored bytes are Jobber's own part order and are NOT canonical
--     (24 live rows differ by order alone), so a raw compare reports false drift on all of them.
--
-- 🛑 NO_EVIDENCE IS READ FIRST AND UNCONDITIONALLY, and the counts are scoped to the job ids the
-- last SUCCESSFUL run actually observed. Without both, a frozen or empty observation table would
-- report a comforting zero, which is silence from an instrument that never ran.
--
-- BODY PROVENANCE: pulled with pg_get_functiondef and patched by anchored insertion
-- (scratchpad/patch_health.js), never retyped. Diff against the live body: PURELY ADDITIVE,
-- zero lines removed.
--
-- RULE 8: no schema change; replaces one SECURITY DEFINER function.
-- ============================================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.log_jobber_sync_health()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'sync', 'pg_temp'
AS $function$
declare
  v_items    jsonb := '[]'::jsonb;
  v_conflict int := 0;
  v_stuck    int := 0;
  v_skipped  int := 0;
  v_total    int := 0;
  v_drift_visit_completion_lost      int := 0;
  v_drift_visit_crew                 int := 0;
  v_unresolvable_jobber_user_90d     int := 0;
  v_orphan_visit_shadow_match        int := 0;
  v_drift_client_archived_not_inactive int := 0;
  v_drift_client_inactive_not_archived_unpinned int := 0;
  v_drift_client_inactive_not_archived_pinned int := 0;
  v_drift_client_class_unpinned      int := 0;
  v_drift_client_class_pinned        int := 0;
  v_drift_client_name                int := 0;
  v_drift_property_grease_trap_jobber_only int := 0;
  v_drift_property_grease_trap_both_set int := 0;
  v_drift_property_grease_trap_ours_only int := 0;
  v_drift_property_lock_box          int := 0;
  v_shadow_seeded_never_adopted      int := 0;
  v_ss_failed  int := 0;
  v_ss_stalled int := 0;
  v_ss_stuck   int := 0;
  v_ss_crash   int := 0;
  v_bill_verdict   text;
  v_bill_observed  int := 0;
  v_bill_drift     int := 0;
  v_bill_unmapped  int := 0;
  v_bill_neverconf int := 0;
  v_bill_ids       bigint[] := '{}';
begin
  -- 1. A conflict the sync recorded and nobody has decided. This is the whole point of the
  --    mechanism: both sides moved, so it refused to guess. Refusing to guess is correct;
  --    refusing to guess in silence is the defect.
  with c as (
    select jsonb_build_object(
             'kind',   'shadow_conflict:' || s.entity_type || ':' || s.entity_id::text || ':' || coalesce(s.field_label, s.field_key),
             'issue',  'shadow_conflict',
             'reason', 'Both we and Jobber changed ' || coalesce(s.field_label, s.field_key) ||
                       ' on ' || s.entity_type || ' ' || s.entity_id::text ||
                       ' since the last sync, so neither value was copied. Ours reads ' ||
                       coalesce(s.conflict_our_value #>> '{}', 'null') || ', Jobber reads ' ||
                       coalesce(s.conflict_source_value #>> '{}', 'null') ||
                       '. Nothing is blocked and the app still works; the two systems will simply stay '
                       'different until someone makes them agree, which releases it automatically.',
             'entity_type',   s.entity_type,
             'entity_id',     s.entity_id,
             'field',         coalesce(s.field_label, s.field_key),
             'our_value',     s.conflict_our_value,
             'jobber_value',  s.conflict_source_value,
             'conflict_at',   s.conflict_at,
             'conflict_count', s.conflict_count) as item
      from sync.source_field_shadow s
     where s.conflict_at is not null
  )
  select coalesce(jsonb_agg(item), '[]'::jsonb), count(*) into v_items, v_conflict from c;

  -- 2. A push to Jobber that did not land. Deliberately NOT keyed on one status string: the only
  --    status this table has ever held is 'done', so hard-coding a failure name would be guessing
  --    at a value that has never occurred. Anything that is neither done nor a deliberate skip and
  --    is older than 30 minutes has missed 15 cycles of a */2 cron, and anything carrying an error
  --    or 3+ attempts is reported whatever its status says.
  with q as (
    select jsonb_build_object(
             'kind',   'outbound_stuck:' || o.id::text,
             'issue',  'outbound_stuck',
             'reason', 'A ' || coalesce(o.field_label, o.field_key) || ' change for ' || o.entity_type ||
                       ' ' || o.entity_id::text || ' has not reached Jobber. Status ' || o.status ||
                       ', ' || o.attempts::text || ' attempt(s), queued ' ||
                       round(extract(epoch from (now() - o.created_at)) / 60.0)::text || ' minutes ago' ||
                       case when o.last_error is not null then '. Last error: ' || left(o.last_error, 200) else '' end ||
                       '. Jobber still holds the old value.',
             'queue_id',    o.id,
             'entity_type', o.entity_type,
             'entity_id',   o.entity_id,
             'field',       coalesce(o.field_label, o.field_key),
             'status',      o.status,
             'attempts',    o.attempts,
             'last_error',  o.last_error,
             'queued_minutes', round(extract(epoch from (now() - o.created_at)) / 60.0)) as item
      from sync.outbound_queue o
     where o.status not in ('done', 'skipped')
       and ( o.created_at < now() - interval '30 minutes'
             or o.last_error is not null
             or coalesce(o.attempts, 0) >= 3 )
  )
  select v_items || coalesce(jsonb_agg(item), '[]'::jsonb), count(*) into v_items, v_stuck from q;

  -- 3. A deliberate skip that a person still needs to know about. Clearing a lock box here does
  --    NOT blank it in Jobber (blanking a field from an unattended process is the most destructive
  --    write this path can make), so the driver keeps seeing a code that no longer applies. The
  --    row is recorded as skipped rather than dropped precisely so it can be surfaced here.
  with s as (
    select jsonb_build_object(
             'kind',   'outbound_skipped_clear:' || o.id::text,
             'issue',  'outbound_skipped_clear',
             'reason', coalesce(o.field_label, o.field_key) || ' was CLEARED here for ' || o.entity_type ||
                       ' ' || o.entity_id::text || ', and a clear is deliberately never pushed, so '
                       'Jobber still shows the old value to a driver. Clear it in Jobber too, or put '
                       'the value back here.',
             'queue_id',    o.id,
             'entity_type', o.entity_type,
             'entity_id',   o.entity_id,
             'field',       coalesce(o.field_label, o.field_key),
             'skipped_at',  o.processed_at) as item
      from sync.outbound_queue o
     where o.status = 'skipped'
  )
  select v_items || coalesce(jsonb_agg(item), '[]'::jsonb), count(*) into v_items, v_skipped from s;

  -- STEP 2 DRIFT COUNTERS. One statement, 15 scalar subqueries, each executed read-only
  -- against Prod before shipping and each reproducing its stated expected value exactly.
  -- 🛑 COUNT-ONLY. None of these appends to v_items and none influences v_total, so none can
  --    make this check alert. Fred asked for a week of numbers before any threshold is set.
  select
    (SELECT count(*) FROM raw.jobber_pull_visits r JOIN public.entity_source_links l ON l.entity_type='visit' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.visits v ON v.id = l.entity_id WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.completed_at IS NOT NULL AND (nullif(r.data->>'completedAt','') IS NULL OR r.data->>'visitStatus' <> 'COMPLETED') AND v.visit_date >= date '2026-05-05'),
    (WITH crew AS (SELECT v.id, count(*) FILTER (WHERE n.value IS NOT NULL) AS j_mentions, coalesce(array_agg(DISTINCT el.entity_id) FILTER (WHERE el.entity_id IS NOT NULL), '{}') AS j_ids, coalesce((SELECT array_agg(DISTINCT t.employee_id ORDER BY t.employee_id) FROM public.visit_team t WHERE t.visit_id = v.id), '{}') AS our_ids FROM raw.jobber_pull_visits r JOIN public.entity_source_links l ON l.entity_type='visit' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.visits v ON v.id = l.entity_id LEFT JOIN LATERAL jsonb_array_elements(coalesce(r.data->'assignedUsers'->'nodes','[]'::jsonb)) n ON true LEFT JOIN public.entity_source_links el ON el.entity_type='employee' AND el.source_system='jobber' AND el.source_id = n->>'id' WHERE v.deleted_at IS NULL AND (r.data->>'completedAt') IS NOT NULL AND v.visit_date >= date '2026-08-01' GROUP BY v.id) SELECT count(*) FROM crew WHERE j_mentions <> coalesce(array_length(our_ids,1),0) OR (SELECT array_agg(x ORDER BY x) FROM unnest(j_ids) x) IS DISTINCT FROM our_ids),
    (SELECT count(*) FROM raw.jobber_pull_visits r WHERE nullif(r.data->>'startAt','') IS NOT NULL AND (r.data->>'startAt')::timestamptz >= now() - interval '90 days' AND EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(r.data->'assignedUsers'->'nodes','[]'::jsonb)) n WHERE NOT EXISTS (SELECT 1 FROM public.entity_source_links el WHERE el.entity_type='employee' AND el.source_system='jobber' AND el.source_id = n->>'id'))),
    (SELECT count(*) FROM raw.jobber_pull_visits r JOIN public.entity_source_links cl ON cl.entity_type='client' AND cl.source_system='jobber' AND cl.source_id = r.data->'client'->>'id' JOIN public.visits v ON v.client_id = cl.entity_id AND v.deleted_at IS NULL AND nullif(r.data->>'startAt','') IS NOT NULL AND v.start_at IS NOT NULL AND abs(extract(epoch FROM (v.start_at - nullif(r.data->>'startAt','')::timestamptz))) < 3600 WHERE NOT EXISTS (SELECT 1 FROM public.entity_source_links l2 JOIN public.visits v2 ON v2.id = l2.entity_id AND v2.deleted_at IS NULL WHERE l2.entity_type='visit' AND l2.source_system='jobber' AND l2.source_id = r.data->>'id') AND NOT EXISTS (SELECT 1 FROM public.entity_source_links l3 WHERE l3.entity_type='visit' AND l3.source_system='jobber' AND l3.entity_id = v.id)),
    (SELECT count(*) FROM public.clients c JOIN public.entity_source_links l ON l.entity_type='client' AND l.source_system='jobber' AND l.entity_id = c.id JOIN raw.jobber_pull_clients r ON r.data->>'id' = l.source_id WHERE (r.data->>'isArchived')::boolean IS TRUE AND c.status <> 'INACTIVE'),
    (SELECT count(*) FROM public.clients c JOIN public.entity_source_links l ON l.entity_type='client' AND l.source_system='jobber' AND l.entity_id = c.id JOIN raw.jobber_pull_clients r ON r.data->>'id' = l.source_id WHERE c.status = 'INACTIVE' AND (r.data->>'isArchived')::boolean IS FALSE AND coalesce(c.status_source,'') <> 'manual'),
    (SELECT count(*) FROM public.clients c JOIN public.entity_source_links l ON l.entity_type='client' AND l.source_system='jobber' AND l.entity_id = c.id JOIN raw.jobber_pull_clients r ON r.data->>'id' = l.source_id WHERE c.status = 'INACTIVE' AND (r.data->>'isArchived')::boolean IS FALSE AND coalesce(c.status_source,'') = 'manual'),
    (SELECT count(*) FROM public.clients c JOIN public.entity_source_links l ON l.entity_type='client' AND l.source_system='jobber' AND l.entity_id = c.id JOIN raw.jobber_pull_clients r ON r.data->>'id' = l.source_id WHERE c.client_class IS DISTINCT FROM (CASE WHEN (r.data->>'isCompany')::boolean THEN 'commercial' ELSE 'residential' END) AND coalesce(c.client_class_source,'') <> 'manual'),
    (SELECT count(*) FROM public.clients c JOIN public.entity_source_links l ON l.entity_type='client' AND l.source_system='jobber' AND l.entity_id = c.id JOIN raw.jobber_pull_clients r ON r.data->>'id' = l.source_id WHERE c.client_class IS DISTINCT FROM (CASE WHEN (r.data->>'isCompany')::boolean THEN 'commercial' ELSE 'residential' END) AND coalesce(c.client_class_source,'') = 'manual'),
    (SELECT count(*) FROM public.clients c JOIN public.entity_source_links l ON l.entity_type='client' AND l.source_system='jobber' AND l.entity_id = c.id JOIN raw.jobber_pull_clients r ON r.data->>'id' = l.source_id WHERE c.name IS DISTINCT FROM (SELECT CASE WHEN v ~ '^(.*)\s+-\s+[0-9]{2,3}\s*-\s*[A-Za-z0-9&]+\s*$' THEN btrim(regexp_replace(v,'^(.*?)\s+-\s+[0-9]{2,3}\s*-\s*[A-Za-z0-9&]+\s*$','\1')) WHEN v ~ '^(.*)[([]\s*[0-9]{2,3}\s*-\s*[A-Za-z0-9&]+\s*[)\]]\s*$' THEN btrim(regexp_replace(v,'^(.*?)\s*[([]\s*[0-9]{2,3}\s*-\s*[A-Za-z0-9&]+\s*[)\]]\s*$','\1')) WHEN v ~ '^\s*[0-9]{2,3}\s*-\s*[A-Za-z0-9&]+[\s,:-]+.+$' THEN btrim(regexp_replace(v,'^\s*[0-9]{2,3}\s*-\s*[A-Za-z0-9&]+[\s,:-]+(.+)$','\1')) WHEN v ~ '^\s*[0-9]{3}-\s+' THEN btrim(regexp_replace(v,'^\s*[0-9]{3}-\s+','')) ELSE btrim(v) END FROM (SELECT coalesce(nullif(btrim(CASE WHEN (r.data->>'isCompany')::boolean THEN coalesce(r.data->>'companyName','') ELSE btrim(coalesce(r.data->>'firstName','')||' '||coalesce(r.data->>'lastName','')) END),''), nullif(r.data->>'companyName','')) AS v) q)),
    (SELECT count(*) FROM raw.jobber_pull_properties r JOIN public.entity_source_links l ON l.entity_type='property' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.properties p ON p.id = l.entity_id WHERE p.deleted_at IS NULL AND l.source_id NOT LIKE '%\_billing' AND p.grease_trap_size_gallons IS NULL AND coalesce((SELECT nullif(cf->>'valueNumeric','')::numeric FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvbk51bWVyaWMvMzA2MTExMQ=='),0) <> 0),
    (SELECT count(*) FROM raw.jobber_pull_properties r JOIN public.entity_source_links l ON l.entity_type='property' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.properties p ON p.id = l.entity_id WHERE p.deleted_at IS NULL AND l.source_id NOT LIKE '%\_billing' AND p.grease_trap_size_gallons IS NOT NULL AND coalesce((SELECT nullif(cf->>'valueNumeric','')::numeric FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvbk51bWVyaWMvMzA2MTExMQ=='),0) <> 0 AND p.grease_trap_size_gallons::numeric <> (SELECT nullif(cf->>'valueNumeric','')::numeric FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvbk51bWVyaWMvMzA2MTExMQ==')),
    (SELECT count(*) FROM raw.jobber_pull_properties r JOIN public.entity_source_links l ON l.entity_type='property' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.properties p ON p.id = l.entity_id WHERE p.deleted_at IS NULL AND l.source_id NOT LIKE '%\_billing' AND coalesce(p.grease_trap_size_gallons,0) <> 0 AND (SELECT nullif(cf->>'valueNumeric','')::numeric FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvbk51bWVyaWMvMzA2MTExMQ==') = 0),
    (SELECT count(*) FROM raw.jobber_pull_properties r JOIN public.entity_source_links l ON l.entity_type='property' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.properties p ON p.id = l.entity_id WHERE p.deleted_at IS NULL AND l.source_id NOT LIKE '%\_billing' AND (SELECT nullif(btrim(cf->>'valueText'),'') FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvblRleHQvMzA2MTExMg==') IS NOT NULL AND (SELECT nullif(btrim(cf->>'valueText'),'') FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvblRleHQvMzA2MTExMg==') <> 'N/A' AND coalesce(p.lock_box_key,'') <> (SELECT nullif(btrim(cf->>'valueText'),'') FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvblRleHQvMzA2MTExMg==')),
    (SELECT count(*) FROM sync.source_field_shadow s JOIN public.properties p ON p.id = s.entity_id AND p.deleted_at IS NULL WHERE s.adopted_at IS NULL AND s.conflict_at IS NULL AND jsonb_typeof(s.our_value) = 'null' AND jsonb_typeof(s.source_value) IS DISTINCT FROM 'null' AND s.source_value::text NOT IN ('0','""','"N/A"'))
  into
    v_drift_visit_completion_lost,
    v_drift_visit_crew,
    v_unresolvable_jobber_user_90d,
    v_orphan_visit_shadow_match,
    v_drift_client_archived_not_inactive,
    v_drift_client_inactive_not_archived_unpinned,
    v_drift_client_inactive_not_archived_pinned,
    v_drift_client_class_unpinned,
    v_drift_client_class_pinned,
    v_drift_client_name,
    v_drift_property_grease_trap_jobber_only,
    v_drift_property_grease_trap_both_set,
    v_drift_property_grease_trap_ours_only,
    v_drift_property_lock_box,
    v_shadow_seeded_never_adopted;

  -- ==========================================================================================
  -- SYNC SURFACE HEALTH (added 2026-09-07)
  --
  -- WHY: everything above this line compares FIELD VALUES. None of it asks whether the syncs that
  -- produce those values are still running. They were not: sync-jobber-job-drift died on 30 of its
  -- last 671 runs over 14 days and nothing could tell anyone, because ops.v_health_items watches
  -- five sources and no Jobber sync surface was one of them.
  --
  -- 🛑 'attention' IS NOT A FAILURE. It means the check ran and FOUND something. jobber_visit_drift
  --    reads 'attention' on 70% of runs because it is finding drift, which is it working. The real
  --    failure statuses are 'partial' and 'error'. Testing status <> 'success' conflates the two and
  --    would report the healthiest reconciler in the estate as the sickest.
  --
  -- Thresholds are measured, not chosen. Over the 14 days to 2026-09-06, worst single day of
  -- partial/error: job_drift 8, upcoming_visits 13, poll 2, note_photo 1. A bare count >= 2 would
  -- fire on the poll's 2-of-288 (0.7%), which is noise, so the rate arm is what excludes it while
  -- still catching job_drift at 8-of-48 (17%).
  with watched(src, stale_after) as (values
      ('jobber_poll_pgcron',            interval '25 minutes'),
      ('jobber_upcoming_visits_pgcron', interval '50 minutes'),
      ('jobber_job_drift',              interval '95 minutes'),
      ('jobber_visit_drift',            interval '95 minutes'),
      ('calendar-task-poll',            interval '25 minutes'),
      -- ⚠ These two run irregularly by design (max observed gap 731 and 724 minutes), so a staleness
      --    window would be a guess. NULL means "watch it for failures, never for lateness".
      ('jobber_note_photo_sync',        null::interval),
      ('jobber_token_keepalive',        null::interval)
  ),
  agg as (
    select w.src, w.stale_after,
           count(*) filter (where l.started_at > now() - interval '24 hours')            as runs_24h,
           count(*) filter (where l.started_at > now() - interval '24 hours'
                              and l.status in ('partial','error'))                       as fails_24h,
           count(*) filter (where l.started_at > now() - interval '24 hours'
                              and coalesce(l.details->'error_samples'->>0, '')
                                  ilike '%Cannot read properties of undefined%')         as crash_24h,
           max(l.started_at)                                                             as last_run
      from watched w
      left join public.sync_log l
        on l.sync_source = w.src and l.started_at > now() - interval '30 days'
     group by w.src, w.stale_after
  ),
  grp as (
    select l.sync_source, l.status, l.started_at,
           row_number() over (partition by l.sync_source order by l.started_at desc)
         - row_number() over (partition by l.sync_source, l.status order by l.started_at desc) as g
      from public.sync_log l join watched w on w.src = l.sync_source
     where l.started_at > now() - interval '30 days'
  ),
  cur as (
    select sync_source, status, count(*) as runs, min(started_at) as since, max(started_at) as until
      from grp group by sync_source, status, g
  ),
  stuck as (
    -- The CURRENT streak only, and only if it is still the newest run for that source. A source that
    -- was stuck last week and recovered is not a finding.
    select c.* from cur c
     where c.status <> 'success'
       and c.until = (select max(l3.started_at) from public.sync_log l3 where l3.sync_source = c.sync_source)
       and now() - c.since >= interval '72 hours'
  ),
  findings as (
    select jsonb_build_object(
             'kind',   'sync_failed:' || a.src, 'issue', 'sync_failed', 'source', a.src,
             'fails_24h', a.fails_24h, 'runs_24h', a.runs_24h,
             'reason', 'The ' || a.src || ' sync failed ' || a.fails_24h || ' of its ' || a.runs_24h ||
                       ' runs in the last 24 hours (status partial or error). Those runs did not '
                       'reconcile anything, so whatever drifted during them is still drifted.') as item
      from agg a
     where a.runs_24h > 0 and a.fails_24h >= 2 and a.fails_24h::numeric >= 0.02 * a.runs_24h
    union all
    select jsonb_build_object(
             'kind',   'sync_stalled:' || a.src, 'issue', 'sync_stalled', 'source', a.src,
             'last_run', a.last_run,
             'reason', 'The ' || a.src || ' sync has not run since ' ||
                       coalesce(to_char(a.last_run at time zone 'America/New_York', 'YYYY-MM-DD HH24:MI') || ' ET',
                                'never in the last 30 days') ||
                       ', which is past its expected interval. It is not merely slow, it has stopped.')
      from agg a
     where a.stale_after is not null and (a.last_run is null or now() - a.last_run > a.stale_after)
    union all
    select jsonb_build_object(
             'kind',   'sync_crash_regression:' || a.src, 'issue', 'sync_crash_regression', 'source', a.src,
             'occurrences_24h', a.crash_24h,
             'reason', 'The ' || a.src || ' sync logged the undefined-dereference crash signature ' ||
                       a.crash_24h || ' time(s) in 24 hours. This is the exact defect fixed on '
                       '2026-09-06 (a missing Jobber answer read as data), so treat it as a regression '
                       'and re-check the content-type and data-key guards in that function''s gql().')
      from agg a where a.crash_24h > 0
    union all
    select jsonb_build_object(
             'kind',   'sync_stuck:' || s.sync_source, 'issue', 'sync_stuck', 'source', s.sync_source,
             'streak_runs', s.runs, 'since', s.since,
             'reason', 'The ' || s.sync_source || ' sync has reported ''' || s.status || ''' on every one of '
                       'its last ' || s.runs || ' runs, continuously since ' ||
                       to_char(s.since at time zone 'America/New_York', 'YYYY-MM-DD HH24:MI') || ' ET. '
                       'It is running fine and reporting the same unresolved item over and over, which '
                       'nobody sees, because sync_log has no dedup. Resolve the item or it repeats forever.')
      from stuck s
  )
  select v_items || coalesce(jsonb_agg(f.item), '[]'::jsonb),
         count(*) filter (where f.item->>'issue' = 'sync_failed'),
         count(*) filter (where f.item->>'issue' = 'sync_stalled'),
         count(*) filter (where f.item->>'issue' = 'sync_stuck'),
         count(*) filter (where f.item->>'issue' = 'sync_crash_regression')
    into v_items, v_ss_failed, v_ss_stalled, v_ss_stuck, v_ss_crash
    from findings f;

  -- ==========================================================================================
  -- BILLING OBSERVATION (added 2026-09-07). COUNT-ONLY, BY DESIGN.
  -- Nothing here is appended to v_items or added to v_total, so it cannot alert, cannot change
  -- this check's status and cannot mail anyone. Fred's precedent for the 15 drift counters was a
  -- week of numbers before any threshold, and every phase-A finding is unresolvable by
  -- construction anyway: the only writer of those columns is fn_record_client_job, and the
  -- operator's obvious move (re-save in the Client App) derives billing from the job TITLE and
  -- pushes OUR value over Jobber's.
  --
  -- 🛑 THE VERDICT IS READ FIRST AND UNCONDITIONALLY. If the observer has never succeeded this
  --    reports NO_EVIDENCE rather than a comforting zero. A drift count taken from an empty or
  --    frozen observation table is silence from an instrument that never ran, which is this
  --    estate's single most-repeated defect.
  select f.verdict, coalesce(f.observed_job_ids, '{}')
    into v_bill_verdict, v_bill_ids
    from sync.v_billing_observation_freshness f;

  if v_bill_verdict is distinct from 'NO_EVIDENCE' then
    select
      count(*),
      count(*) filter (where not o.norm_ok),
      count(*) filter (where o.norm_ok and j.billing_type is null),
      count(*) filter (where o.norm_ok and j.billing_type is not null and (
             o.norm_billing_type is distinct from j.billing_type
          -- Compare the periodic CLASS, not the label. 'monthly_last_day' and 'custom' are both
          -- PERIODIC to Jobber, so comparing labels manufactures drift on a rule we ourselves
          -- accept. The cost is a known blind spot: a pure label divergence is invisible.
          or o.norm_periodic_class is distinct from case j.invoice_frequency
               when 'per_visit' then 'PER_VISIT' when 'once_closed' then 'ON_COMPLETION'
               when 'as_needed' then 'NEVER' else 'PERIODIC' end
          -- BOTH sides canonicalised: our stored bytes are Jobber's own part order and are NOT
          -- canonical, so a raw compare reports false drift on 24 live rows.
          or sync.fn_canonical_rrule(o.norm_invoice_rrule)
             is distinct from sync.fn_canonical_rrule(j.invoice_rrule)))
      into v_bill_observed, v_bill_unmapped, v_bill_neverconf, v_bill_drift
      from sync.jobber_billing_observed o
      join public.jobs j on j.id = o.job_id
     -- Only rows the LAST SUCCESSFUL run actually saw. A stale row is not evidence, and this is
     -- what stops a half-drained sweep leaving old observations to be read as current.
     where o.job_id = any(v_bill_ids);
  end if;

  v_total := v_conflict + v_stuck + v_skipped + v_ss_failed + v_ss_stalled + v_ss_stuck + v_ss_crash;

  -- ðŸ›‘ clock_timestamp(), NOT now(). now() is the TRANSACTION timestamp, so two runs inside one
  --    transaction get identical started_at values and ops.v_health_items' DISTINCT ON ... ORDER BY
  --    started_at DESC ties between them, silently returning the wrong run. That is not theoretical:
  --    this migration's own positive control hit it and reported "the conflict did not reach
  --    ops.v_health_items", which reads exactly like a missed registration site. The siblings use
  --    now() only because cron calls them once per transaction. The ordering key has to be able to
  --    tell two runs apart.
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('jobber-sync-health', clock_timestamp(), clock_timestamp(), v_total,
          case when v_total > 0 then 'attention' else 'ok' end,
          jsonb_build_object(
            'shadow_conflicts',       v_conflict,
            'outbound_stuck',         v_stuck,
            'outbound_skipped_clear', v_skipped,
            'items',                  v_items,
            'drift_visit_completion_lost',  v_drift_visit_completion_lost,
            'drift_visit_crew',         v_drift_visit_crew,
            'unresolvable_jobber_user_90d',  v_unresolvable_jobber_user_90d,
            'orphan_visit_shadow_match',  v_orphan_visit_shadow_match,
            'drift_client_archived_not_inactive',  v_drift_client_archived_not_inactive,
            'drift_client_inactive_not_archived_unpinned',  v_drift_client_inactive_not_archived_unpinned,
            'drift_client_inactive_not_archived_pinned',  v_drift_client_inactive_not_archived_pinned,
            'drift_client_class_unpinned',  v_drift_client_class_unpinned,
            'drift_client_class_pinned',  v_drift_client_class_pinned,
            'drift_client_name',        v_drift_client_name,
            'drift_property_grease_trap_jobber_only',  v_drift_property_grease_trap_jobber_only,
            'drift_property_grease_trap_both_set',  v_drift_property_grease_trap_both_set,
            'drift_property_grease_trap_ours_only',  v_drift_property_grease_trap_ours_only,
            'drift_property_lock_box',  v_drift_property_lock_box,
            'shadow_seeded_never_adopted',  v_shadow_seeded_never_adopted,
            'sync_surface_failed',    v_ss_failed,
            'sync_surface_stalled',   v_ss_stalled,
            'sync_surface_stuck',     v_ss_stuck,
            'sync_surface_crash',     v_ss_crash,
            -- Count-only. Deliberately NOT in items and NOT in v_total: see the block above.
            'billing_observation',     v_bill_verdict,
            'billing_observed',        v_bill_observed,
            'billing_drift',           v_bill_drift,
            'billing_unmappable',      v_bill_unmapped,
            'billing_never_confirmed', v_bill_neverconf,
            -- Coverage is stated on every run so a clean verdict can never be read as
            -- "the whole Jobber sync is healthy". It is not: it is two fields.
            'covers', 'This compares 13 columns of 93 across four Jobber-synced entities (visits 3 of 36, clients 4 '
                      'of 12, properties 2 of 28, jobs 0 of 17) against the payload the poll already staged, never '
                      'against live Jobber: 1,173 of 1,972 live visits are comparable at all and only 214 fall '
                      'inside the crew era floor, 462 of 473 clients, 477 of 939 properties, and 0 jobs; and '
                      'because the visits poll pages Jobber by completion time, the staged payload can only ever '
                      'contain COMPLETED visits, so a scheduled visit, any Jobber-side edit made after a visit '
                      'completed, and every job field are structurally invisible here - a zero on this report is a '
                      'zero on what it looks at, not an all-clear on the Jobber sync. '
                      'SEPARATELY it now also watches whether seven Jobber sync surfaces are still '
                      'RUNNING (failed / stalled / stuck / crash-signature). That half is about the '
                      'pipes, not the values, and it is deliberately blind to any sync surface not '
                      'named in its watched list. ',
            'what_it_means', case when v_total > 0
              then 'Something in the two-way sync needs a person. A shadow_conflict means both sides '
                   'changed and neither value was copied - nothing is blocked, the app works, the two '
                   'systems just stay different until someone makes them agree. An outbound_stuck '
                   'means a change made here never reached Jobber. An outbound_skipped_clear means a '
                   'field was emptied here and Jobber still shows the old value.'
              else 'No unresolved conflicts, no stuck pushes, no skipped clears on the two two-way fields.' end));

  return v_total;
end $function$
;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_ret int;
  d     jsonb;
BEGIN
  -- 1. It RUNS. PL/pgSQL is not parsed at creation, so "applied" says nothing about "executes".
  v_ret := public.log_jobber_sync_health();
  SELECT details INTO d FROM public.sync_log WHERE sync_source='jobber-sync-health'
   ORDER BY started_at DESC LIMIT 1;

  -- 2. The billing keys are present and reflect the live observation lane.
  IF NOT (d ? 'billing_observation' AND d ? 'billing_drift' AND d ? 'billing_observed') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: billing count keys missing from details';
  END IF;
  IF (d->>'billing_observation') = 'NO_EVIDENCE' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: reports NO_EVIDENCE, but successful observation runs exist. '
                    'The freshness read is not reaching the view.';
  END IF;
  IF (d->>'billing_observed')::int = 0 THEN
    RAISE EXCEPTION 'VERIFY 2 CONTROL FAILED: observed=0, so every other billing number here is '
                    'meaningless and a zero drift count would prove nothing.';
  END IF;

  -- 3. THE LOAD-BEARING ASSERTION: this must not have become an alerting path. If billing ever
  --    contributes an item, the count-only contract is broken and a per-job stream has begun
  --    without the item_key shape that makes it safe.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(d->'items','[]'::jsonb)) i
              WHERE i.value->>'issue' LIKE 'billing%' OR i.value->>'kind' LIKE 'billing%') THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: billing contributed an ITEM. This check is count-only.';
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED (% findings; billing % observed=% drift=% unmappable=% never_confirmed=%)',
    v_ret, d->>'billing_observation', d->>'billing_observed', d->>'billing_drift',
    d->>'billing_unmappable', d->>'billing_never_confirmed';
END
$verify$;

COMMIT;
