-- ============================================================================
-- 2026-08-02_2300 — Generation is RECURRING-only, and classifies by service_kind
-- ============================================================================
-- Fred, answering the two smoke-test findings:
--   #1 "Leaving the Recurring status stop regeneration, and it should wipe the
--       upcoming visits."
--   #3 "Change the service_type to 'pumping', 'cleaning' or 'warranty' — those
--       are the real 3 types of services ... do a complete backfill."
--
-- ---------------------------------------------------------------------------
-- #1 — GENERATION NOW REQUIRES status = 'RECURRING'
-- ---------------------------------------------------------------------------
-- Was `c.status in ('ACTIVE','RECURRING')`, inherited verbatim from the retired
-- JS generator. That fought the cleanup trigger: leaving RECURRING for ACTIVE
-- wiped the client's upcoming SA visits (pushing visitDelete to Jobber), and
-- then the next nightly REBUILT the chain at different dates and pushed the
-- creates back. Both halves did what they were asked; together they churned.
-- Blast radius had it fired: 132 RECURRING clients / 685 future SA visits.
--
-- ⚠ CLEANUP IS DELIBERATELY *NOT* NARROWED TO MATCH. The two predicates were
-- deliberately identical so they could not drift, so breaking that symmetry
-- needs its reason recorded:
--   * The wipe-on-leaving-RECURRING is already handled by
--     trg_clients_cleanup_sa_visits_on_status, at the moment of the transition.
--     That is Fred's rule, and it is precise.
--   * If cleanup ALSO required RECURRING, the next full sweep would find the
--     54 future visits belonging to the 12 ACTIVE clients that are generating
--     today and try to soft-delete them — 54 > MAX_CLEANUP (40), so it would
--     ABORT every night rather than delete, turning a data question into a
--     nightly warning. Worse, if the cap were ever raised it would silently
--     push 54 visitDeletes to Jobber for clients nobody decided to stop serving.
--   * So: the TRIGGER handles the transition (wipe), the SCOPE handles the
--     future (no regeneration), and CLEANUP keeps its wider predicate so it
--     only ever removes visits whose JOB stopped qualifying.
--
-- ⚠ CONSEQUENCE FRED MUST SEE (surfaced, not silently absorbed): 12 ACTIVE
-- clients hold 54 future generated visits and stop receiving NEW ones from
-- tonight — 037-LB, 114-CI, 140-TYO, 147-OST, 178-LG, 180-PV, 226-JER, 231-CHE,
-- 232-AC, 233-AH, 241-WYN, 242-WYN. Their existing visits are untouched. The
-- fix is to set those clients to RECURRING (which Fred already asked for in the
-- 2026-07-31 batch: "ACTIVE clients with open SA jobs should be Recurring").
--
-- ---------------------------------------------------------------------------
-- #3 — CLASSIFY BY service_kind, THE CANONICAL TAXONOMY
-- ---------------------------------------------------------------------------
-- ⚠ NO BACKFILL IS NEEDED, AND A service_type REWRITE WOULD HAVE BROKEN THINGS.
-- The three real types Fred named already exist as
-- `public.service_line_items.service_kind` — populated from HIS OWN SHEET
-- (19ArflSwdhcpnu1U6Lii5q2VFmDLjwskurDCghN0aanE col G) and already correct on
-- every code, including the ones this bug was about:
--        03 Grey Water            service_kind = Pumping              (service_type NULL)
--        04 Lift Station          service_kind = Pumping              (service_type NULL)
--        08 Warranty of Drainage  service_kind = Warranty of Drainage (service_type NULL)
-- The bug was that THIS FUNCTION read the legacy `service_type` and fell back to
-- a hard-coded 'GT' when it was NULL. It never needed a data change.
--
-- 🛑 And `visits.service_type` must NOT be rewritten to Pumping/Cleaning/Warranty:
-- it is load-bearing in ops.v_calendar_visit for the per-(client, service_type)
-- cadence and lateness anchor and for the service_configs join. Rewriting the
-- vocabulary breaks those silently. So: DERIVE from service_kind (correct), and
-- STORE the legacy code (compatible). Mapping, per Fred's three types:
--        Pumping -> GT      Cleaning -> CL      Warranty of Drainage -> WD
--
-- Measured effect on today's data: exactly ONE job changes what it would store —
-- 081-TCE #99901010 (Warranty of Drainage) would store 'WD' instead of the
-- defaulted 'GT' — and that job is warranty-only so it never generates. Every
-- generated visit is byte-identical. This is a correctness fix, not a behaviour
-- change, which is why it is safe to ship with #1.
--
-- ROLLBACK: restore fn_generate_sa_visits from 2026-08-02_2200.
-- ============================================================================

begin;

create or replace function public.fn_generate_sa_visits(
  p_client_id       bigint  default null,
  p_horizon_months  int     default 6,
  p_dry_run         boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $fn$
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
           -- #3: the CANONICAL taxonomy. service_kind is populated for every
           -- catalogue code; the legacy service_type is NULL on 03/04/08, which
           -- is what made the old code fall back to a hard-coded 'GT'.
           (select sli.service_kind
              from public.line_items l2
              join public.service_line_items sli
                on sli.code = lpad(substring(btrim(l2.name) from '^([0-9]+)'), 2, '0')
             where l2.job_id = j.id and l2.invoice_id is null and sli.service_kind is not null
             order by case sli.service_kind
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
       -- ▼ #1: RECURRING ONLY. Was ('ACTIVE','RECURRING') — see the header.
       and c.status = 'RECURRING'
       and c.client_code is not null
       and c.client_code not in ('112-YA','777-YA','000-DH')
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
    -- Store the LEGACY code for compatibility (ops.v_calendar_visit cadence +
    -- lateness anchor and the service_configs join key off it). Derived, not guessed.
    select s.*,
           case s.service_kind
             when 'Pumping'              then 'GT'
             when 'Cleaning'             then 'CL'
             when 'Warranty of Drainage' then 'WD'
             else 'GT'
           end as service_type
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
      -- service must not set this agreement's cadence.
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
             when c.client_code in ('112-YA','777-YA','000-DH')
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
      (client_id, job_id, visit_date, visit_status, source, title, service_type, derm_required)
    select client_id, job_id, visit_date, 'scheduled', 'supabase_cron',
           client_code || ' ' || client_name || ' - ' || title,
           service_type, derm_required
      from _sa_candidates;
    get diagnostics v_inserted = row_count;
  end if;

  -- CLEANUP — full sweep only, and deliberately still keyed on ACTIVE *or*
  -- RECURRING (see header): it removes visits whose JOB stopped qualifying,
  -- never visits that merely belong to a client who left RECURRING. That
  -- transition is the trigger's job.
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
            and c.client_code not in ('112-YA','777-YA','000-DH')
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
$fn$;

revoke all on function public.fn_generate_sa_visits(bigint, int, boolean)
  from public, anon, authenticated, service_role;

commit;
