-- 2026-09-03_1740_jobber_drift_counters.sql
--
-- WHAT: adds 15 DRIFT COUNTERS to public.log_jobber_sync_health(). Each compares one of our columns
--       against the Jobber payload we ALREADY stage in raw.jobber_pull_*, so a disagreement between
--       the two systems stops being invisible. No new tables, no poll change, no Jobber call, no
--       app change.
--
-- WHY:  step 2 of Fred's *"we need for them to be Two-way"*. Step 1 (2026-09-03_1625) surfaced the
--       two fields that genuinely ARE two-way. This covers the fields that are not, by reading what
--       the poll already brings back: raw.jobber_pull_visits and _clients are ~3 minutes old and
--       already carry visitStatus, completedAt, startAt, endAt, assignedUsers, isArchived,
--       isCompany, companyName. Nothing new has to be fetched or stored.
--
-- 🛑 COUNT-ONLY, AND THE VERIFY BLOCK ENFORCES IT. Not one of these appends to items[], influences
--    status, or changes the return value. Fred's condition was a week of real numbers before any
--    threshold is chosen, because this estate has already lost one reporting channel to alert
--    fatigue: sync_log became unreadable when health verdicts were 0.40% of its rows, and 89% of
--    one week's attention rows were a single source repeating the same unresolvable item every
--    30 minutes. Four counters are non-zero today, so if any of them fed status the VERIFY fails.
--
-- 🛑 WHAT WAS DELIBERATELY LEFT OUT, because it matters more than what went in.
--    visits.start_at is EXCLUDED, and it was the headline finding of the audit that started this
--    work. Measured: 39 rows differ, and the last post-stage writer on ALL 39 is
--    cron_jobber_reconcile_completion, which re-queries LIVE Jobber and writes our column FROM it.
--    No app writer appears as last writer on any of them. Counting it would have put a permanently
--    non-zero, 100%-artifact number into details on day one, defended by a report calling it
--    proven - precisely the shape the count-first instruction exists to prevent.
--    end_at is 55 of 62 the same visits plus Jobber's all-day sentinel. visit_date is
--    trigger-derived from start_at by trg_aa_reconcile_operating_date and double-counts it.
--    completed_at both-set-and-differ is structurally incapable of disagreeing, because the poll
--    cursor IS completedAt. public.jobs is out entirely: its first-ever comparison returns
--    job_status 1,453 of 1,807 with a 1,114-row undiagnosed bucket, and shipping an undiagnosed
--    1,114 is worse than shipping nothing.
--
-- ⚠ THE FOUR NON-ZERO COUNTERS ARE REAL AND EACH WAS CONFIRMED BY HAND:
--    orphan_visit_shadow_match = 1          visit 7090. Jobber says completed 2026-07-11, we say
--                                           skipped, and NEITHER side carries a link to the other,
--                                           so every other check here is blind to it.
--    drift_client_inactive_not_archived_unpinned = 1
--    drift_client_class_pinned = 3          119-ME, 121-FRO, 126-YM. Deliberate overrides, counted
--                                           separately so an intended divergence is never read as a
--                                           fault - but counted, because nobody is currently TOLD.
--    drift_property_grease_trap_jobber_only = 2   properties 146 (104-PV, Jobber 320) and 340
--                                           (Jobber 1250). 🛑 This is a live loss on the estate's
--                                           ONLY two-way synced field, and step 1's shadow_conflicts
--                                           counter reads 0 for it and always will: their shadow
--                                           rows are seeded-but-never-adopted, which is a state
--                                           CONFLICT cannot describe. shadow_seeded_never_adopted
--                                           reaches the same 2 by an independent route.
--
-- ⚠ EVERY SQL BELOW WAS EXECUTED READ-ONLY AGAINST PROD BEFORE SHIPPING and reproduced its stated
--   expected value exactly, 15 of 15 with zero mismatches. The VERIFY block re-asserts all 15.
--
-- 🛑 THE FUNCTION BODY WAS NOT RETYPED. It is the live pg_get_functiondef output with three
--    anchored insertions (declarations, one SELECT, the details keys) and the coverage sentence
--    replaced. CLAUDE.md records what retyping a CREATE OR REPLACE body costs: 2026-08-06_1316
--    silently deleted seven behaviours from a resolver and raised for 3.5 hours on live Prod.
--
-- RULE 8 (audit): no table or column changes. One function replacement.
-- RULE 2/3: nothing stored or copied. Every counter is derived on read.
-- RULE 6: no deletes.

BEGIN;

-- ---------------------------------------------------------------------------------------------
-- PART 1. The check, with the drift counters folded in
-- ---------------------------------------------------------------------------------------------

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

  v_total := v_conflict + v_stuck + v_skipped;

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
            -- Coverage is stated on every run so a clean verdict can never be read as
            -- "the whole Jobber sync is healthy". It is not: it is two fields.
            'covers', 'This compares 13 columns of 93 across four Jobber-synced entities (visits 3 of 36, clients 4 '
                      'of 12, properties 2 of 28, jobs 0 of 17) against the payload the poll already staged, never '
                      'against live Jobber: 1,173 of 1,972 live visits are comparable at all and only 214 fall '
                      'inside the crew era floor, 462 of 473 clients, 477 of 939 properties, and 0 jobs; and '
                      'because the visits poll pages Jobber by completion time, the staged payload can only ever '
                      'contain COMPLETED visits, so a scheduled visit, any Jobber-side edit made after a visit '
                      'completed, and every job field are structurally invisible here - a zero on this report is a '
                      'zero on what it looks at, not an all-clear on the Jobber sync. ',
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

-- ---------------------------------------------------------------------------------------------
-- PART 2. VERIFY
--
-- 🛑 ELEVEN OF THE FIFTEEN COUNTERS SHIP AT ZERO. A zero is only worth reading if the instrument
--    that produced it is capable of producing something else, so every shipped zero has a control
--    below that FAILS LOUDLY if its machinery breaks. The most important is ctrl_grease_trap_naive:
--    if Jobber's custom-field configuration GID ever moves, or the poll stops selecting
--    customFields, the extraction subquery returns NULL for every row and ALL THREE grease trap
--    counters go silently to zero while looking perfectly healthy. The naive count collapsing is
--    the only signal that would fire.
-- ---------------------------------------------------------------------------------------------

DO $$
DECLARE v bigint; v_elig bigint; v_n int; v_status text; d jsonb;
BEGIN
  RAISE NOTICE 'CONTROLS:';
  SELECT (WITH crew AS (SELECT v.id, count(*) FILTER (WHERE n.value IS NOT NULL) AS j_mentions, coalesce(array_agg(DISTINCT el.entity_id) FILTER (WHERE el.entity_id IS NOT NULL), '{}') AS j_ids, coalesce((SELECT array_agg(DISTINCT t.employee_id ORDER BY t.employee_id) FROM public.visit_team t WHERE t.visit_id = v.id), '{}') AS our_ids FROM raw.jobber_pull_visits r JOIN public.entity_source_links l ON l.entity_type='visit' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.visits v ON v.id = l.entity_id LEFT JOIN LATERAL jsonb_array_elements(coalesce(r.data->'assignedUsers'->'nodes','[]'::jsonb)) n ON true LEFT JOIN public.entity_source_links el ON el.entity_type='employee' AND el.source_system='jobber' AND el.source_id = n->>'id' WHERE v.deleted_at IS NULL AND (r.data->>'completedAt') IS NOT NULL AND v.visit_date >= date '2026-08-01' GROUP BY v.id) SELECT count(*) FROM crew WHERE true) INTO v_elig;

  SELECT (SELECT count(*) FROM raw.jobber_pull_properties r JOIN public.entity_source_links l ON l.entity_type='property' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.properties p ON p.id = l.entity_id WHERE p.deleted_at IS NULL AND l.source_id NOT LIKE '%\_billing' AND p.grease_trap_size_gallons IS DISTINCT FROM (SELECT nullif(cf->>'valueNumeric','')::numeric FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvbk51bWVyaWMvMzA2MTExMQ==')::integer) INTO v;
  RAISE NOTICE '  ctrl_grease_trap_naive = %', v;
  IF v < 300 THEN RAISE EXCEPTION 'CONTROL ctrl_grease_trap_naive FAILED (got %): the Jobber custom-field config GID moved or the poll stopped selecting customFields - ALL THREE grease trap counters are now silently zero', v; END IF;

  SELECT (SELECT count(*) FROM raw.jobber_pull_visits r JOIN public.entity_source_links l ON l.entity_type='visit' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.visits v2 ON v2.id = l.entity_id WHERE v2.deleted_at IS NULL AND v2.completed_at IS NOT NULL AND nullif(r.data->>'completedAt','') IS NULL AND v2.visit_date < date '2026-05-05') INTO v;
  RAISE NOTICE '  ctrl_lost_completion_fossils = %', v;
  IF v <> 44 THEN RAISE EXCEPTION 'CONTROL ctrl_lost_completion_fossils FAILED (got %): the lost-completion shape is no longer detectable, so drift_visit_completion_lost = 0 proves nothing', v; END IF;

  SELECT (SELECT count(*) FROM public.entity_source_links l WHERE l.entity_type='property' AND l.source_system='jobber' AND l.source_id LIKE '%\_billing') INTO v;
  RAISE NOTICE '  ctrl_billing_links_excluded = %', v;
  IF v < 400 THEN RAISE EXCEPTION 'CONTROL ctrl_billing_links_excluded FAILED (got %): the _billing suffix convention changed; without the NOT LIKE filter every property counter reports the whole fleet as drifting', v; END IF;

  SELECT (SELECT count(*) FROM public.entity_source_links l WHERE l.entity_type='property' AND l.source_system='jobber' AND l.source_id LIKE '%\_billing' AND EXISTS (SELECT 1 FROM raw.jobber_pull_properties r WHERE r.data->>'id' = l.source_id)) INTO v;
  RAISE NOTICE '  ctrl_billing_links_matched = %', v;
  IF v <> 0 THEN RAISE EXCEPTION 'CONTROL ctrl_billing_links_matched FAILED (got %): a billing link now matches a staged Jobber property, which should be impossible - the GID comparison has been loosened', v; END IF;

  SELECT (SELECT count(*) FROM sync.source_field_shadow s WHERE jsonb_typeof(s.our_value) = 'null') INTO v;
  RAISE NOTICE '  ctrl_shadow_jsonb_null = %', v;
  IF v < 500 THEN RAISE EXCEPTION 'CONTROL ctrl_shadow_jsonb_null FAILED (got %): the shadow our_value representation changed; shadow_seeded_never_adopted may be reading the wrong kind of null', v; END IF;

  SELECT (SELECT count(*) FROM sync.source_field_shadow s WHERE s.our_value IS NULL) INTO v;
  RAISE NOTICE '  ctrl_shadow_sql_null = %', v;
  IF v <> 0 THEN RAISE EXCEPTION 'CONTROL ctrl_shadow_sql_null FAILED (got %): shadow our_value now holds SQL NULL as well as JSON null, so a predicate written with IS NULL would return a confident wrong answer', v; END IF;

  SELECT (SELECT count(*) FROM raw.jobber_pull_visits r WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(r.data->'assignedUsers'->'nodes','[]'::jsonb)) n WHERE NOT EXISTS (SELECT 1 FROM public.entity_source_links el WHERE el.entity_type='employee' AND el.source_system='jobber' AND el.source_id = n->>'id'))) INTO v;
  RAISE NOTICE '  ctrl_unresolvable_user_staged_all = %', v;
  IF v < 50 THEN RAISE EXCEPTION 'CONTROL ctrl_unresolvable_user_staged_all FAILED (got %): the unresolvable-user machinery can no longer return non-zero, so unresolvable_jobber_user_90d = 0 is an untested instrument', v; END IF;

  SELECT (SELECT count(*) FROM public.clients c JOIN public.entity_source_links l ON l.entity_type='client' AND l.source_system='jobber' AND l.entity_id = c.id JOIN raw.jobber_pull_clients r ON r.data->>'id' = l.source_id WHERE (r.data->>'isArchived')::boolean IS TRUE AND c.status <> 'ACTIVE') INTO v;
  RAISE NOTICE '  ctrl_client_archived_not_active = %', v;
  IF v < 5 THEN RAISE EXCEPTION 'CONTROL ctrl_client_archived_not_active FAILED (got %): the client join or the isArchived read has broken, so drift_client_archived_not_inactive = 0 means nothing', v; END IF;

  SELECT (WITH crew AS (SELECT v.id, count(*) FILTER (WHERE n.value IS NOT NULL) AS j_mentions, coalesce(array_agg(DISTINCT el.entity_id) FILTER (WHERE el.entity_id IS NOT NULL), '{}') AS j_ids, coalesce((SELECT array_agg(DISTINCT t.employee_id ORDER BY t.employee_id) FROM public.visit_team t WHERE t.visit_id = v.id), '{}') AS our_ids FROM raw.jobber_pull_visits r JOIN public.entity_source_links l ON l.entity_type='visit' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.visits v ON v.id = l.entity_id LEFT JOIN LATERAL jsonb_array_elements(coalesce(r.data->'assignedUsers'->'nodes','[]'::jsonb)) n ON true LEFT JOIN public.entity_source_links el ON el.entity_type='employee' AND el.source_system='jobber' AND el.source_id = n->>'id' WHERE v.deleted_at IS NULL AND (r.data->>'completedAt') IS NOT NULL AND v.visit_date >= date '2026-08-01' GROUP BY v.id) SELECT count(*) FROM crew WHERE (j_mentions + 1) <> coalesce(array_length(our_ids,1),0) OR (SELECT array_agg(x ORDER BY x) FROM unnest(j_ids || array[-1]) x) IS DISTINCT FROM our_ids) INTO v;
  RAISE NOTICE '  ctrl_crew_mutated = %', v;
  IF v <> v_elig THEN RAISE EXCEPTION 'CONTROL ctrl_crew_mutated FAILED (got %): the crew CTE, the visit_team join or the era floor has broken, so drift_visit_crew = 0 is an untested instrument', v; END IF;

  -- The check still runs, and every counter reproduces the value measured before shipping.
  v_n := public.log_jobber_sync_health();
  SELECT status, details INTO v_status, d FROM public.sync_log
   WHERE sync_source = 'jobber-sync-health' ORDER BY started_at DESC LIMIT 1;

  IF (d ->> 'drift_visit_completion_lost')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'COUNTER drift_visit_completion_lost = %, expected 0 (measured against Prod before shipping)', d ->> 'drift_visit_completion_lost'; END IF;
  IF (d ->> 'drift_visit_crew')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'COUNTER drift_visit_crew = %, expected 0 (measured against Prod before shipping)', d ->> 'drift_visit_crew'; END IF;
  IF (d ->> 'unresolvable_jobber_user_90d')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'COUNTER unresolvable_jobber_user_90d = %, expected 0 (measured against Prod before shipping)', d ->> 'unresolvable_jobber_user_90d'; END IF;
  IF (d ->> 'orphan_visit_shadow_match')::int IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'COUNTER orphan_visit_shadow_match = %, expected 1 (measured against Prod before shipping)', d ->> 'orphan_visit_shadow_match'; END IF;
  IF (d ->> 'drift_client_archived_not_inactive')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'COUNTER drift_client_archived_not_inactive = %, expected 0 (measured against Prod before shipping)', d ->> 'drift_client_archived_not_inactive'; END IF;
  IF (d ->> 'drift_client_inactive_not_archived_unpinned')::int IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'COUNTER drift_client_inactive_not_archived_unpinned = %, expected 1 (measured against Prod before shipping)', d ->> 'drift_client_inactive_not_archived_unpinned'; END IF;
  IF (d ->> 'drift_client_inactive_not_archived_pinned')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'COUNTER drift_client_inactive_not_archived_pinned = %, expected 0 (measured against Prod before shipping)', d ->> 'drift_client_inactive_not_archived_pinned'; END IF;
  IF (d ->> 'drift_client_class_unpinned')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'COUNTER drift_client_class_unpinned = %, expected 0 (measured against Prod before shipping)', d ->> 'drift_client_class_unpinned'; END IF;
  IF (d ->> 'drift_client_class_pinned')::int IS DISTINCT FROM 3 THEN RAISE EXCEPTION 'COUNTER drift_client_class_pinned = %, expected 3 (measured against Prod before shipping)', d ->> 'drift_client_class_pinned'; END IF;
  IF (d ->> 'drift_client_name')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'COUNTER drift_client_name = %, expected 0 (measured against Prod before shipping)', d ->> 'drift_client_name'; END IF;
  IF (d ->> 'drift_property_grease_trap_jobber_only')::int IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'COUNTER drift_property_grease_trap_jobber_only = %, expected 2 (measured against Prod before shipping)', d ->> 'drift_property_grease_trap_jobber_only'; END IF;
  IF (d ->> 'drift_property_grease_trap_both_set')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'COUNTER drift_property_grease_trap_both_set = %, expected 0 (measured against Prod before shipping)', d ->> 'drift_property_grease_trap_both_set'; END IF;
  IF (d ->> 'drift_property_grease_trap_ours_only')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'COUNTER drift_property_grease_trap_ours_only = %, expected 0 (measured against Prod before shipping)', d ->> 'drift_property_grease_trap_ours_only'; END IF;
  IF (d ->> 'drift_property_lock_box')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'COUNTER drift_property_lock_box = %, expected 0 (measured against Prod before shipping)', d ->> 'drift_property_lock_box'; END IF;
  IF (d ->> 'shadow_seeded_never_adopted')::int IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'COUNTER shadow_seeded_never_adopted = %, expected 2 (measured against Prod before shipping)', d ->> 'shadow_seeded_never_adopted'; END IF;

  -- 🛑 COUNT-ONLY. The drift counters must not be able to raise an alert. Four of them are non-zero
  --    right now, so if any of them fed status, items[] or the return value, one of these fails.
  IF v_status <> 'ok' THEN
    RAISE EXCEPTION 'COUNT-ONLY VIOLATED: status is %, drift must not influence it', v_status;
  END IF;
  IF jsonb_array_length(d -> 'items') <> 0 THEN
    RAISE EXCEPTION 'COUNT-ONLY VIOLATED: items[] has % entries, drift must not append', jsonb_array_length(d -> 'items');
  END IF;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'COUNT-ONLY VIOLATED: the check returned %, drift must not change the return value', v_n;
  END IF;

  RAISE NOTICE 'OK: 15 drift counters live, 9 controls fired, status still ok and items[] still empty.';
END $$;

COMMIT;
