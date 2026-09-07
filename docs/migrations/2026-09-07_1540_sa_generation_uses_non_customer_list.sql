-- ============================================================================================
-- 2026-09-07_1540_sa_generation_uses_non_customer_list.sql
--
-- Point SA visit generation at public.non_customer_clients instead of a hardcoded list, which
-- also excludes 000-DP as Fred asked.
--
-- WHY (Fred, 2026-09-07): "not a real customer, and yes exclude 000-DP from SA generation."
--
-- The hardcoded list appeared THREE times in this function (two WHERE predicates and the
-- skip-reason CASE) and read ('112-YA','777-YA','000-DH','000-HS'). DUMP Pompano (000-DP) was
-- absent, which is the gap Fred has now closed. That gap was already raised with him in commit
-- bb3ce7d on 2026-08-03 and never answered until today.
--
-- 🛑 THIS IS A PROVABLE NO-OP ON GENERATED VISITS TODAY, and that is why it is safe to do now.
-- Measured across all seven non-customer clients, only TWO have a live SA-shaped job
-- (frequency_days > 0, non-archived, "Service Agreement%" title): 112-YA (job 765) and 777-YA
-- (job 1818). BOTH were already excluded by the old list. 000-DP, Doug Test and the two ZZ Mode
-- fixtures have ZERO, so extending the guard changes no candidate today. The VERIFY proves it by
-- evaluating the OLD and NEW predicates over the same population and requiring the difference to
-- be empty.
--
-- 🛑 THE 000-HS GUARD IS PRESERVED, and this was the main risk. `000-HS` matches no client row: it
-- was pre-staged on Fred's instruction so the guard predates the account. A membership table keyed
-- only on client_id could not hold it and repointing would have SILENTLY DELETED it. It is stored
-- as a code-only row and public.v_non_customer_clients resolves membership by client_id OR by
-- client_code, so the guard arms itself the moment such a client appears. VERIFY 4 proves the
-- code-matching path works, using an existing client rather than inserting one.
--
-- ⚠ WHAT IS DELIBERATELY NOT CHANGED: the surrounding `and c.client_code is not null` guard stays.
-- It is intentional here and the skip-reason CASE says so in words ("This client has no client
-- code, so it is excluded from automatic visit generation"). It is NOT the same thing as the
-- NULL-client_code defect that silently drops rows from dump_route_today and derm.visits, which is
-- recorded in 2026-09-07_1520 and is untouched by either migration.
--
-- ⚠ ALSO NOT CHANGED: the other four divergent predicates (v_sa_schedule_gaps, dump_route_today,
-- derm.visits, manifest_pickable_visits) and the two CHECK constraints. Repointing those is a
-- separate decision per object, because two of them SELECT dumps rather than excluding them, and a
-- partial migration means two sources of truth. This migration moves exactly one consumer, the one
-- Fred named.
--
-- BODY PROVENANCE: pulled with pg_get_functiondef and patched by whole-line anchored replacement
-- (scratchpad/patch_sa.js), never retyped. Diff against the live body: exactly 3 lines removed,
-- all three the hardcoded predicate; 5 added (the replacements plus two explanatory comments).
--
-- RULE 8: no schema change; replaces one function.
-- ============================================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_generate_sa_visits(p_client_id bigint DEFAULT NULL::bigint, p_horizon_months integer DEFAULT 6, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c_today       date := (now() at time zone 'America/New_York')::date;
  c_horizon_end date := (date_trunc('month', (now() at time zone 'America/New_York')::date)
                         + make_interval(months => p_horizon_months + 1) - interval '1 day')::date;
  c_tolerance   int  := 7;
  c_max_per_job int  := 24;
  c_max_cleanup int  := 40;
  v_planned     jsonb := '[]'::jsonb;
  v_skipped     jsonb := '[]'::jsonb;
  v_inserted    int := 0;
  v_stale_ids   bigint[];
  v_cleaned     int := 0;
  v_cleanup_note text := null;
  v_scope_note  text := null;
  v_run_started timestamptz := clock_timestamp();
  v_n_jobs      int := 0;
begin
  drop table if exists _sa_jobs;
  drop table if exists _sa_candidates;

  create temp table _sa_jobs on commit drop as
  with jobs_in_scope as (
    select j.id           as job_id,
           j.job_number,
           j.title,
           j.frequency_days,
           j.start_at,
           c.id           as client_id,
           c.client_code,
           c.name         as client_name,
           bool_or(public.fn_line_item_requires_derm(li.name)) as derm_required,
           -- The CANONICAL taxonomy. As of 2026-08-03 service_kind and
           -- service_type hold the same values, so there is nothing to convert.
           (select sli.service_type
              from public.line_items l2
              join public.service_line_items sli
                on sli.code = lpad(substring(btrim(l2.name) from '^([0-9]+)'), 2, '0')
             where l2.job_id = j.id and l2.invoice_id is null and sli.service_type is not null
             order by case sli.service_type
                        when 'Pumping' then 1 when 'Cleaning' then 2
                        when 'Warranty of Drainage' then 3 else 4 end
             limit 1) as service_kind
      from public.jobs j
      join public.clients c on c.id = j.client_id
      left join public.line_items li on li.job_id = j.id and li.invoice_id is null
     where j.frequency_days > 0
       and j.title ilike 'Service Agreement%'
       and j.title not ilike '%[OLD]%'
       and coalesce(j.job_status,'') <> 'archived'
       and c.status = 'RECURRING'
       and c.client_code is not null
       -- Was a hardcoded list; now one source of truth. See public.non_customer_clients.
       and not public.fn_is_non_customer(c.id)
       and exists (
         select 1 from public.line_items lp
          join public.service_line_items slip
            on slip.code = lpad(substring(btrim(lp.name) from '^([0-9]+)'), 2, '0')
          where lp.job_id = j.id and lp.invoice_id is null
            and slip.reason in ('Service Agreement','Service Call') and slip.code <> '08')
       and (p_client_id is null or c.id = p_client_id)
     group by j.id, j.job_number, j.title, j.frequency_days, j.start_at,
              c.id, c.client_code, c.name
  ),
  typed as (
    -- 2026-08-03: the legacy down-conversion (Pumping to GT etc., with an
    -- else-GT fallback that could mislabel) is GONE. The kind IS the type.
    select s.*, s.service_kind as service_type
      from jobs_in_scope s
  )
  select t.*,
         st.max_future,
         st.n_visits,
         lc.last_completed,
         case
           when st.max_future    is not null then st.max_future    + t.frequency_days
           when lc.last_completed is not null then lc.last_completed + t.frequency_days
           when t.start_at       is not null then (t.start_at at time zone 'America/New_York')::date
           else c_today + t.frequency_days
         end as anchor,
         case
           when st.max_future     is not null then 'job_scheduled+freq'
           when lc.last_completed is not null then 'client_completed+freq'
           when t.start_at        is not null then 'job_start_at'
           else 'today+freq'
         end as anchor_src
    from typed t
    left join lateral (
      select max(v.visit_date) filter (
               where v.visit_status = 'scheduled' and v.visit_date >= c_today) as max_future,
             count(*) as n_visits
        from public.visits v
       where v.job_id = t.job_id and v.deleted_at is null
    ) st on true
    left join lateral (
      -- same-service anchor (the 178-LG rule): a completed visit of ANOTHER
      -- service must not set this agreement's cadence. Both sides now speak
      -- the new vocabulary.
      select max(v.visit_date) as last_completed
        from public.visits v
       where v.client_id = t.client_id
         and v.visit_status = 'completed'
         and v.service_type = t.service_type
         and v.deleted_at is null
    ) lc on true;

  select count(*) into v_n_jobs from _sa_jobs;

  if p_client_id is not null and v_n_jobs = 0 then
    select case
             when c.id is null then 'That client does not exist.'
             when public.fn_is_non_customer(c.id)
               then 'This is a test/non-serviceable account and is permanently excluded from automatic visit generation.'
             when c.client_code is null
               then 'This client has no client code, so it is excluded from automatic visit generation.'
             when c.status <> 'RECURRING'
               then format('Visits are only generated for RECURRING clients — this one is %s. Set it to Recurring to schedule visits.', c.status)
             when not exists (
                    select 1 from public.jobs j
                     where j.client_id = c.id and j.job_status <> 'archived'
                       and j.title ilike 'Service Agreement%' and j.title not ilike '%[OLD]%')
               then 'This client has no open Service Agreement job, so there is nothing to generate from.'
             when not exists (
                    select 1 from public.jobs j
                     where j.client_id = c.id and j.job_status <> 'archived'
                       and j.title ilike 'Service Agreement%' and coalesce(j.frequency_days,0) > 0)
               then 'This client''s Service Agreement has no frequency set, so no cadence can be generated.'
             else 'This client''s only Service Agreement is billing-only (Warranty of Drainage), which never generates recurring visits.'
           end
      into v_scope_note
      from public.clients c where c.id = p_client_id;
    if v_scope_note is null then v_scope_note := 'That client does not exist.'; end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'job_id', job_id, 'job_number', job_number, 'title', title,
           'client_code', client_code,
           'reason', 'no start date and no visits yet — set a start date to begin scheduling')), '[]'::jsonb)
    into v_skipped
    from _sa_jobs
   where start_at is null and n_visits = 0;

  delete from _sa_jobs where start_at is null and n_visits = 0;

  create temp table _sa_candidates on commit drop as
  select j.*, d::date as visit_date
    from _sa_jobs j
    cross join lateral (
      select d, row_number() over (order by d) as rn
        from generate_series(j.anchor::timestamp,
                             c_horizon_end::timestamp,
                             make_interval(days => j.frequency_days)) as g(d)
       where d::date >= c_today
    ) s
   where s.rn <= c_max_per_job
     and not exists (
       select 1 from public.visits v
        where v.job_id = j.job_id
          and v.deleted_at is null
          and abs(v.visit_date - s.d::date) <= c_tolerance
     );

  select coalesce(jsonb_agg(jsonb_build_object(
           'job_id', job_id, 'job_number', job_number, 'client_code', client_code,
           'anchor', anchor, 'anchor_src', anchor_src, 'visit_date', visit_date,
           'service_kind', service_kind)
           order by client_code, job_number, visit_date), '[]'::jsonb)
    into v_planned
    from _sa_candidates;

  if not p_dry_run then
    insert into public.visits
      (client_id, job_id, visit_date, visit_status, source, title, service_type, derm_required, property_id)
    select c.client_id, c.job_id, c.visit_date, 'scheduled', 'supabase_cron',
           c.client_code || ' ' || c.client_name || ' - ' || c.title,
           c.service_type, c.derm_required,
           -- 2026-08-18: carry the job's property so generated visits stop being born with
           -- property_id NULL (677 future rows were; the city email then renders "Address
           -- not on file" in a regulator-facing subject). Scalar subquery on purpose: the
           -- temp tables above are untouched, so this is the smallest possible diff.
           (select j2.property_id from public.jobs j2 where j2.id = c.job_id)
      from _sa_candidates c;
    get diagnostics v_inserted = row_count;
  end if;

  -- CLEANUP — full sweep only, and deliberately still keyed on ACTIVE *or*
  -- RECURRING: it removes visits whose JOB stopped qualifying, never visits
  -- that merely belong to a client who left RECURRING. That transition is the
  -- trigger's job.
  if p_client_id is null then
    select array_agg(v.id) into v_stale_ids
      from public.visits v
     where v.source = 'supabase_cron'
       and v.deleted_at is null
       and v.visit_date >= c_today
       and not exists (
         select 1 from public.jobs j join public.clients c on c.id = j.client_id
          where j.id = v.job_id
            and j.frequency_days > 0
            and j.title ilike 'Service Agreement%'
            and j.title not ilike '%[OLD]%'
            and coalesce(j.job_status,'') <> 'archived'
            and c.status in ('ACTIVE','RECURRING')
            and c.client_code is not null
            -- Was a hardcoded list; now one source of truth. See public.non_customer_clients.
            and not public.fn_is_non_customer(c.id)
            and exists (
              select 1 from public.line_items lp
               join public.service_line_items slip
                 on slip.code = lpad(substring(btrim(lp.name) from '^([0-9]+)'), 2, '0')
               where lp.job_id = j.id and lp.invoice_id is null
                 and slip.reason in ('Service Agreement','Service Call') and slip.code <> '08'));

    v_cleaned := coalesce(array_length(v_stale_ids, 1), 0);
    if v_cleaned > c_max_cleanup then
      v_cleanup_note := format('ABORTED: %s stale > max %s — likely a bulk data issue, investigate',
                               v_cleaned, c_max_cleanup);
      v_cleaned := 0;
    elsif v_cleaned > 0 and not p_dry_run then
      update public.visits set deleted_at = now() where id = any(v_stale_ids);
    end if;
  end if;

  if not p_dry_run then
    insert into public.sync_log
      (sync_source, started_at, finished_at, rows_inserted, rows_updated,
       rows_errored, duration_seconds, status, details)
    values ('sa-visit-generation',
            v_run_started, clock_timestamp(),
            v_inserted, v_cleaned,
            case when v_cleanup_note is null then 0 else 1 end,
            round(extract(epoch from (clock_timestamp() - v_run_started))::numeric, 3),
            case when v_cleanup_note is null then 'success' else 'warning' end,
            jsonb_build_object(
              'scope',        coalesce(p_client_id::text, 'all'),
              'jobs',         v_n_jobs,
              'generated',    v_inserted,
              'skipped',      jsonb_array_length(v_skipped),
              'cleaned',      v_cleaned,
              'cleanup_note', v_cleanup_note,
              'scope_note',   v_scope_note,
              'horizon_end',  c_horizon_end));
  end if;

  return jsonb_build_object(
    'dry_run',      p_dry_run,
    'scope',        coalesce(p_client_id::text, 'all'),
    'today',        c_today,
    'horizon_end',  c_horizon_end,
    'jobs_considered', v_n_jobs,
    'generated',    case when p_dry_run then jsonb_array_length(v_planned) else v_inserted end,
    'planned',      v_planned,
    'skipped',      v_skipped,
    'scope_note',   v_scope_note,
    'cleaned',      v_cleaned,
    'cleanup_note', v_cleanup_note,
    'ms',           round(extract(epoch from (clock_timestamp() - v_run_started)) * 1000));
end;
$function$
;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_old int; v_new int; v_diff int; v_ctl int;
BEGIN
  -- 1. THE NO-OP PROOF. Evaluate the OLD list and the NEW membership over the same population of
  --    SA-shaped jobs and require the candidate sets to be identical.
  SELECT count(*) INTO v_old FROM public.jobs j JOIN public.clients c ON c.id = j.client_id
   WHERE coalesce(j.job_status,'') <> 'archived' AND coalesce(j.frequency_days,0) > 0
     AND lower(coalesce(j.title,'')) LIKE 'service agreement%'
     AND c.status IN ('ACTIVE','RECURRING') AND c.client_code IS NOT NULL
     AND c.client_code NOT IN ('112-YA','777-YA','000-DH','000-HS');
  SELECT count(*) INTO v_new FROM public.jobs j JOIN public.clients c ON c.id = j.client_id
   WHERE coalesce(j.job_status,'') <> 'archived' AND coalesce(j.frequency_days,0) > 0
     AND lower(coalesce(j.title,'')) LIKE 'service agreement%'
     AND c.status IN ('ACTIVE','RECURRING') AND c.client_code IS NOT NULL
     AND NOT public.fn_is_non_customer(c.id);
  IF v_old <> v_new THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: candidate set moved from % to %. This was supposed to be a '
                    'no-op today; investigate before shipping.', v_old, v_new;
  END IF;
  IF v_old = 0 THEN
    RAISE EXCEPTION 'VERIFY 1 CONTROL FAILED: zero SA candidates either way, so equality proves '
                    'nothing.';
  END IF;

  -- 2. The clients that were excluded before are still excluded.
  IF NOT (public.fn_is_non_customer(381) AND public.fn_is_non_customer(47)
          AND public.fn_is_non_customer(365)) THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: one of 112-YA / 777-YA / 000-DH is no longer excluded.';
  END IF;

  -- 3. 000-DP is now excluded. This is the behaviour change Fred asked for.
  IF NOT public.fn_is_non_customer(76) THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: 000-DP (DUMP Pompano) is not excluded.';
  END IF;

  -- 4. THE CODE-MATCHING PATH WORKS, which is what preserves the pre-staged 000-HS guard. Proven
  --    on an EXISTING client rather than by inserting one: drop 000-DH's client_id so the row can
  --    only match by code, assert it still resolves, then restore.
  UPDATE public.non_customer_clients SET client_id = NULL WHERE client_code = '000-DH';
  IF NOT public.fn_is_non_customer(365) THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: a code-only row does not resolve, so the pre-staged 000-HS '
                    'guard would be silently dead.';
  END IF;
  UPDATE public.non_customer_clients SET client_id = 365 WHERE client_code = '000-DH';
  IF NOT public.fn_is_non_customer(365) THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: restore did not take.';
  END IF;

  -- 5. NEGATIVE CONTROL: a real customer with a live SA job is still a candidate.
  SELECT count(*) INTO v_ctl FROM public.jobs j JOIN public.clients c ON c.id = j.client_id
   WHERE coalesce(j.job_status,'') <> 'archived' AND coalesce(j.frequency_days,0) > 0
     AND lower(coalesce(j.title,'')) LIKE 'service agreement%'
     AND c.status IN ('ACTIVE','RECURRING') AND c.client_code IS NOT NULL
     AND NOT public.fn_is_non_customer(c.id) AND c.id NOT IN (365,76,381,47,2,561,562);
  IF v_ctl = 0 THEN
    RAISE EXCEPTION 'VERIFY 5 CONTROL FAILED: no real customer remains a candidate.';
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED (candidates % unchanged, % real customers still generating)',
    v_old, v_ctl;
END
$verify$;

COMMIT;
