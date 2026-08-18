-- ============================================================================
-- 2026-08-18_1520 - visits carry their property: one-time backfill + the generator fix
-- ============================================================================
-- From the August photo audit review. 99 of 166 August visits (59.6%) had property_id
-- NULL, and every city email for one renders "Address not on file" IN THE SUBJECT of a
-- regulator-facing message. 1,269 visits fleet-wide are backfillable from their job.
--
-- 🛑 THE NULL FACTORY IS THE SA GENERATOR, NOT handleVisit. fn_generate_sa_visits'
-- INSERT column list simply omitted property_id, and it manufactures the visit horizon
-- nightly: 677 of the 1,269 are FUTURE rows it created. A backfill without the generator
-- fix regrows the problem every night. (Found by the adversarial plan review; the draft
-- plan had named handleVisit.)
--
-- SAFETY, measured not assumed (also from the review):
--   * jobs.property_id has ZERO non-null-to-non-null changes in its entire audit history
--     (all 49 changes are null->value backfills), so copying it onto historical visits
--     cannot write a "today's property" that differs from the visit-day property.
--   * The backfill UPDATE is inert against every trigger on visits: jobber-push and
--     sync-pending gate on columns it does not touch, operating-date is UPDATE OF
--     start_at/visit_date, the line-item freeze requires a status transition, the GDO
--     check at worst emits pg_notify.
--   * Visits where property_id is ALREADY set are untouched (pinned to NULL only), so
--     the 25 known visit-vs-job property disagreements are preserved, not overwritten.
--   * NO fallback guessing here: a visit whose job has no property stays NULL, and the
--     city email keeps saying "Address not on file" - honest beats plausible-but-wrong
--     (the client-primary fallback was reviewed and rejected for multi-property clients).
--
-- THE GENERATOR BODY BELOW IS THE LIVE pg_get_functiondef OUTPUT, patched
-- programmatically: anchors asserted, diff asserted to touch exactly the INSERT (5 lines
-- out). Everything else is byte-identical to what was running.
--
-- AUDIT (rule 8): public.visits is audited, so all backfill rows are captured. The
-- backfill labels itself 'photo-audit-property-backfill' via the request header so it is
-- distinguishable from ordinary sql writes.
-- ============================================================================

select set_config('request.headers', '{"x-app-source":"photo-audit-property-backfill"}', false);

do $backfill$
declare v_n int;
begin
  update public.visits v
     set property_id = j.property_id
    from public.jobs j
   where j.id = v.job_id
     and v.property_id is null
     and j.property_id is not null
     -- soft-deleted visits are excluded from every read surface; writing property onto
     -- them is pointless audit noise. The guard below fired at 1,603 without this line
     -- (the 1,269 measurement was deleted_at-filtered; the first draft of the UPDATE was
     -- not), which is exactly what the corridor check exists to catch.
     and v.deleted_at is null;
  get diagnostics v_n = row_count;
  if v_n < 1200 or v_n > 1350 then
    raise exception 'backfill touched % rows, expected ~1,269 - re-measure before proceeding', v_n;
  end if;
  raise notice 'backfilled % visits', v_n;
end
$backfill$;

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
       and c.client_code not in ('112-YA','777-YA','000-DH','000-HS')
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
             when c.client_code in ('112-YA','777-YA','000-DH','000-HS')
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
            and c.client_code not in ('112-YA','777-YA','000-DH','000-HS')
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


-- ============================================================================
-- VERIFY
-- ============================================================================
do $verify$
declare fail text := ''; v_def text; v_res jsonb;
begin
  -- 1. no backfillable rows remain
  if exists (select 1 from public.visits v join public.jobs j on j.id=v.job_id
              where v.property_id is null and j.property_id is not null and v.deleted_at is null) then
    fail := fail || 'backfillable rows remain; ';
  end if;

  -- 2. the generator now writes property_id (read the live body, not this file)
  v_def := pg_get_functiondef('public.fn_generate_sa_visits(bigint,integer,boolean)'::regprocedure);
  if v_def not like '%derm_required, property_id%' then
    fail := fail || 'generator INSERT does not carry property_id; ';
  end if;

  -- 3. EXERCISE the generator (dry run): plpgsql is not parsed at CREATE, so only a call
  --    proves the new body runs. Dry run plans without inserting.
  begin
    v_res := public.fn_generate_sa_visits(null, 6, true);
    if v_res is null then fail := fail || 'generator dry-run returned null; '; end if;
  exception when others then
    fail := fail || format('generator dry-run raised: %s; ', sqlerrm);
  end;

  -- 4. August specifically: the city-email population is healed
  if (select count(*) from public.visits v join public.jobs j on j.id = v.job_id
       where v.deleted_at is null and v.visit_date >= '2026-08-01' and v.visit_date < '2026-09-01'
         and v.property_id is null and j.property_id is not null) <> 0 then
    fail := fail || 'August visits with a backfillable property remain; ';
  end if;

  if fail <> '' then raise exception 'VERIFY FAILED: %', fail; end if;
  raise notice 'backfill complete, generator carries property_id, dry-run exercises the new body';
end
$verify$;

select (select count(*) from public.visits where deleted_at is null
         and visit_date >= '2026-08-01' and visit_date < '2026-09-01'
         and property_id is null)                                                  as august_still_null,
       (select count(*) from public.visits where deleted_at is null
         and property_id is null)                                                  as fleet_still_null,
       (select count(*) from public.visits where property_id is not null
         and deleted_at is null)                                                   as with_property;
