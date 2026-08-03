-- ============================================================================
-- 2026-08-02_2200 — Two fixes found by the post-ship smoke test
-- ============================================================================
-- Fred asked for a smoke test of the 2026-08-01 batch. An adversarial pass found
-- six issues; these are the two that are unambiguously wrong and safe to fix
-- without a business decision. (The other four are reported to Fred: the
-- RECURRING->ACTIVE regeneration churn, the service_type='GT' default on codes
-- 03/04, the vacuous fee-line invariant, and the fact that a healthy August
-- night and a totally broken generator both log generated:0.)
--
-- ---------------------------------------------------------------------------
-- FIX 1 — "Nothing to schedule — already booked through the horizon" IS A LIE
--          FOR 13 CLIENTS
-- ---------------------------------------------------------------------------
-- The scope filter drops out-of-scope jobs BEFORE `_sa_jobs` is built, so they
-- never reach the skipped list. A client with no generatable job therefore
-- returns jobs_considered=0, generated=0, skipped=[] — which the app renders as
-- the neutral "already booked through the horizon".
--
-- Measured: 12 RECURRING clients have no in-scope job at all (030-KGC,
-- 066/073/074/075/078/079/080-TCE, 107-PV, 209/212/213-TRUE), plus 112-YA which
-- has a live SA job but is hard-excluded. For all 13 the truth is "nothing will
-- EVER be generated here", not "already booked" — the opposite of reassuring.
--
-- That directly violates the rule shipped with the button: *the button must
-- never be silent, three outcomes three messages*. A confidently wrong message
-- is worse than silence, because it stops the user investigating.
--
-- Fix: return `scope_note` explaining WHY the scope was empty, so the app can
-- say it. Nothing about generation changes.
--
-- ---------------------------------------------------------------------------
-- FIX 2 — sa-visit-promote was structurally unobservable
-- ---------------------------------------------------------------------------
-- `fn_promote_sa_visits_to_jobber` logged nothing, and it calls
-- `fn_request_jobber_push` fire-and-forget — so a total pg_net failure still
-- leaves a `succeeded` row in cron.job_run_details. It is the ONLY part of the
-- 2026-08-01 work that talks to Jobber, and it was the one part with no record.
-- Verified healthy at the time of writing (745 alive future cron visits, 225 in
-- Jobber scope, 235 linked, 0 pending promotion) — but nothing would have told
-- us if it stopped. Now writes a sync_log row like every other sync.
--
-- ⚠ NOT CHANGED, ON PURPOSE: generation stays INSERT-only, the destructive
-- cleanup stays behind `p_client_id IS NULL`, and grants are untouched.
--
-- ROLLBACK: restore both functions from 2026-08-01_1450 / _1520.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- FIX 1: explain an empty scope instead of implying "already booked"
-- ---------------------------------------------------------------------------
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
  -- `on commit drop` frees these at COMMIT, not at function exit, so a second
  -- call in the SAME transaction would hit "relation already exists".
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
           coalesce((
             select sli.service_type
               from public.line_items l2
               join public.service_line_items sli
                 on sli.code = lpad(substring(btrim(l2.name) from '^([0-9]+)'), 2, '0')
              where l2.job_id = j.id and l2.invoice_id is null and sli.service_type is not null
              order by case sli.service_type when 'GT' then 1 when 'CL' then 2 when 'WD' then 3 else 4 end
              limit 1), 'GT') as service_type
      from public.jobs j
      join public.clients c on c.id = j.client_id
      left join public.line_items li on li.job_id = j.id and li.invoice_id is null
     where j.frequency_days > 0
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
            and slip.reason in ('Service Agreement','Service Call') and slip.code <> '08')
       and (p_client_id is null or c.id = p_client_id)
     group by j.id, j.job_number, j.title, j.frequency_days, j.start_at,
              c.id, c.client_code, c.name
  )
  select s.*,
         st.max_future,
         st.n_visits,
         lc.last_completed,
         case
           when st.max_future    is not null then st.max_future    + s.frequency_days
           when lc.last_completed is not null then lc.last_completed + s.frequency_days
           when s.start_at       is not null then (s.start_at at time zone 'America/New_York')::date
           else c_today + s.frequency_days
         end as anchor,
         case
           when st.max_future     is not null then 'job_scheduled+freq'
           when lc.last_completed is not null then 'client_completed+freq'
           when s.start_at        is not null then 'job_start_at'
           else 'today+freq'
         end as anchor_src
    from jobs_in_scope s
    left join lateral (
      select max(v.visit_date) filter (
               where v.visit_status = 'scheduled' and v.visit_date >= c_today) as max_future,
             count(*) as n_visits
        from public.visits v
       where v.job_id = s.job_id and v.deleted_at is null
    ) st on true
    left join lateral (
      select max(v.visit_date) as last_completed
        from public.visits v
       where v.client_id = s.client_id
         and v.visit_status = 'completed'
         and v.service_type = s.service_type
         and v.deleted_at is null
    ) lc on true;

  select count(*) into v_n_jobs from _sa_jobs;

  -- ▼▼▼ FIX 1: an EMPTY SCOPE is not the same as "already booked" ▼▼▼
  -- Jobs are filtered out before _sa_jobs exists, so they never reach the
  -- skipped list. Without this the caller cannot tell "nothing due" from
  -- "nothing can ever be generated here", and the app said the reassuring one.
  if p_client_id is not null and v_n_jobs = 0 then
    select case
             when c.id is null then 'That client does not exist.'
             when c.client_code in ('112-YA','777-YA','000-DH')
               then 'This is a test/non-serviceable account and is permanently excluded from automatic visit generation.'
             when c.client_code is null
               then 'This client has no client code, so it is excluded from automatic visit generation.'
             when c.status not in ('ACTIVE','RECURRING')
               then format('Visits are only generated for ACTIVE or RECURRING clients — this one is %s.', c.status)
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
    -- a client id that matches nothing at all
    if v_scope_note is null then v_scope_note := 'That client does not exist.'; end if;
  end if;
  -- ▲▲▲ END FIX 1 ▲▲▲

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
           'anchor', anchor, 'anchor_src', anchor_src, 'visit_date', visit_date)
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

  -- cleanup: FULL SWEEP ONLY. Never reachable from the per-client button.
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
    'scope_note',   v_scope_note,   -- ⚠ non-null = nothing can EVER generate here
    'cleaned',      v_cleaned,
    'cleanup_note', v_cleanup_note,
    'ms',           round(extract(epoch from (clock_timestamp() - v_run_started)) * 1000));
end;
$fn$;

revoke all on function public.fn_generate_sa_visits(bigint, int, boolean)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- FIX 2: make promote observable
-- ---------------------------------------------------------------------------
create or replace function public.fn_promote_sa_visits_to_jobber(p_limit int default 200)
returns jsonb
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $fn$
declare
  v_ids     bigint[];
  v_n       int := 0;
  v_started timestamptz := clock_timestamp();
  v_backlog int := 0;
begin
  select array_agg(v.id order by v.visit_date)
    into v_ids
    from (
      select v.id, v.visit_date
        from public.visits v
       where v.source = 'supabase_cron'
         and v.visit_status = 'scheduled'
         and v.deleted_at is null
         and v.visit_date >= (now() at time zone 'America/New_York')::date
         and public.fn_visit_in_jobber_scope(v.id)
         and not exists (
           select 1 from public.entity_source_links esl
            where esl.entity_type = 'visit'
              and esl.entity_id = v.id
              and esl.source_system = 'jobber')
       order by v.visit_date
       limit p_limit
    ) v;

  v_n := coalesce(array_length(v_ids, 1), 0);
  if v_n > 0 then
    perform public.fn_request_jobber_push(id, 'upsert') from unnest(v_ids) as id;
  end if;

  -- How many were STILL unlinked after this pass (i.e. beyond p_limit). A
  -- backlog that never drains is the signal that pushes are failing silently —
  -- fn_request_jobber_push is fire-and-forget, so a total pg_net outage still
  -- leaves a 'succeeded' row in cron.job_run_details. This is the only part of
  -- the 2026-08-01 work that talks to Jobber, and it had NO record at all.
  select count(*) into v_backlog
    from public.visits v
   where v.source = 'supabase_cron'
     and v.visit_status = 'scheduled'
     and v.deleted_at is null
     and v.visit_date >= (now() at time zone 'America/New_York')::date
     and public.fn_visit_in_jobber_scope(v.id)
     and not exists (
       select 1 from public.entity_source_links esl
        where esl.entity_type = 'visit' and esl.entity_id = v.id
          and esl.source_system = 'jobber');

  insert into public.sync_log
    (sync_source, started_at, finished_at, rows_inserted, rows_updated,
     rows_errored, duration_seconds, status, details)
  values ('sa-visit-promote',
          v_started, clock_timestamp(),
          0, v_n, 0,
          round(extract(epoch from (clock_timestamp() - v_started))::numeric, 3),
          'success',
          jsonb_build_object('requested', v_n, 'remaining_unlinked', v_backlog, 'limit', p_limit));

  return jsonb_build_object('promoted', v_n, 'remaining_unlinked', v_backlog);
end;
$fn$;

revoke all on function public.fn_promote_sa_visits_to_jobber(int)
  from public, anon, authenticated, service_role;

commit;
