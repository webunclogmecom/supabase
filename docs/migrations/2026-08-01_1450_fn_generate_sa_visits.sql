-- ============================================================================
-- 2026-08-01_1450 — SA visit generation moves INTO the database
-- ============================================================================
-- ASK (Fred, 2026-08-01): "why do we need this GH cron? can't we use our own
-- cron jobs like in Supabase edge? ... Ask supabase 2 session so you both do a
-- brainstorm about it, and come up with the best solution ... just build it when
-- you both concur. And make it work on the Clients App."
--
-- CONCURRED with @Supabase 2. Two independent measurements, same conclusion:
--   * @Supabase  : 152 jobs x 2 sequential Management-API round-trips + 1 = 305
--                  HTTPS calls at ~0.5-0.7s each = the entire 150-210s runtime.
--   * @Supabase 2: the same logic as ONE SQL statement, EXPLAIN (ANALYZE,BUFFERS)
--                  = 12.688 ms, shared hit=5979, zero I/O, 151 jobs / 80 candidates.
-- ~12,000x. The script was never slow; the TRANSPORT was slow. Shipping the work
-- out to a Deno edge function would have preserved the round-trip design and
-- inherited a wall-clock question it never needed to have.
--
-- So: one plpgsql function, called two ways.
--   nightly   : pg_cron -> fn_generate_sa_visits(NULL)
--   on-demand : Client App -> client.generate_visits_for_client(client_id)
-- `generate_service_agreement_visits.js` and `sa-visit-generation.yml` are
-- retired in the same change (ONE implementation — two would drift, and this
-- workspace has paid for drift repeatedly).
--
-- ---------------------------------------------------------------------------
-- 🛑 THE FIVE RULES THIS FUNCTION EXISTS TO PRESERVE
-- ---------------------------------------------------------------------------
-- 1. ANCHOR PRECEDENCE, in this order. Each branch was a real incident:
--      (1) max scheduled future visit + frequency        -- append to the chain
--      (2) last COMPLETED visit OF THE SAME service_type + frequency
--          ⚠ same service_type is load-bearing: 178-LG was anchored on a 06-03
--            CL call instead of its 04-27 GT visit (Yan, 2026-06-25).
--      (3) the job's own start_at  -- a dated job with no history starts AT its
--          start date, not today+freq, or the date the user just set is ignored.
--      (4) today + frequency
-- 2. ±7 DAY IDEMPOTENCY. A candidate within 7 days of ANY existing live visit
--    on that job is not generated.
-- 3. THE NOT-STARTED GUARD, gated on BOTH no start_at AND no visits. Gating on
--    `start_at IS NULL` alone would silently stop 9 live jobs that have no start
--    date but are grandfathered by already having visits.
-- 4. EXCLUDED_CLIENT_CODES ('112-YA','777-YA','000-DH') can never generate, even
--    when named explicitly — a stray manual run must not touch them.
-- 5. BILLING-ONLY SAs GENERATE NOTHING. A job needs a real physical-service line
--    (reason in SA/SC, code <> '08'). Warranty of Drainage is a recurring CHARGE,
--    not a truck roll.
--
-- ---------------------------------------------------------------------------
-- WHAT CHANGED ON PURPOSE (agreed with @Supabase 2)
-- ---------------------------------------------------------------------------
-- (a) CLEANUP RUNS ONLY ON THE FULL SWEEP. In the script it was gated on the
--     `--all` CLI flag, so per-client and full-run semantics already differed BY
--     ACCIDENT OF A FLAG. Cleanup soft-deletes future visits, which fires
--     visitDelete to Jobber — a per-client button must never reach it. Now
--     explicit: cleanup happens only when p_client_id IS NULL.
-- (b) THE FUNCTION RETURNS A STRUCTURED RESULT, not void. The not-started guard
--     means "new client, fresh SA job, press Generate" legitimately produces
--     NOTHING, and a button that silently does nothing is a bug report. The app
--     must be able to say WHY: per-job skip reasons are returned.
-- (c) PROMOTE IS NOT IN HERE. trg_push_visit_insert already pushes on insert;
--     promote only re-pushes visits that have ROLLED INTO the 60-day Jobber
--     window as days pass, which is a daily concern unrelated to generation. It
--     becomes its own pg_cron (below). Dropping it removes the last HTTP call
--     from this path, which is what lets generation be ONE TRANSACTION.
-- (d) INSERT-ONLY. This function never moves an existing visit. Re-spacing after
--     a frequency change is a SEPARATE change, deliberately: generation is
--     additive and idempotent, re-spacing is DESTRUCTIVE (it moves visits already
--     pushed to Jobber, possibly already on a driver's route). Folding them
--     together would let the new per-client button silently reschedule booked work.
--
-- ---------------------------------------------------------------------------
-- OBSERVABILITY (a blocker, not a nice-to-have — both sessions agreed)
-- ---------------------------------------------------------------------------
-- The sync_log row is written IN THE SAME TRANSACTION as the inserts, so it can
-- never report success for work that rolled back. GitHub Actions cannot do that
-- (external, 90-day retention its only record) and pg_net cannot either
-- (fire-and-forget). Measured: sync_log has 14 distinct sync_source values and
-- not one of them was SA generation — the nightly run has been invisible to
-- anyone auditing pg_cron. This closes that.
--
-- 3NF / Rule 1: no new columns, no stored derivation — visits are computed from
-- jobs + line_items + existing visits at call time.
-- Audit (ADR 010): public.visits already carries its audit trigger; inserts here
-- are attributed via app_source like any other write.
--
-- ROLLBACK:
--   select cron.unschedule('sa-visit-generation');
--   select cron.unschedule('sa-visit-promote');
--   drop function public.fn_generate_sa_visits(bigint, int, boolean);
--   drop function client.generate_visits_for_client(bigint);
--   -- and re-enable .github/workflows/sa-visit-generation.yml
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. the generator
-- ---------------------------------------------------------------------------
create or replace function public.fn_generate_sa_visits(
  p_client_id       bigint  default null,   -- null = every eligible client
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
  c_tolerance   int  := 7;    -- ±7d idempotency
  c_max_per_job int  := 24;
  c_max_cleanup int  := 40;   -- refuse a mass soft-delete; a big number means a data issue
  v_planned     jsonb := '[]'::jsonb;
  v_skipped     jsonb := '[]'::jsonb;
  v_inserted    int := 0;
  v_stale_ids   bigint[];
  v_cleaned     int := 0;
  v_cleanup_note text := null;
  v_run_started timestamptz := clock_timestamp();
begin
  -- ⚠ `on commit drop` frees these at COMMIT, not at function exit — so a second
  -- call inside the SAME transaction hit `relation "_sa_jobs" already exists`.
  -- Caught by calling the function twice in one DO block before shipping. The app
  -- can legitimately call this twice (retry, or two clients in one request), and
  -- the fixture tests below call it repeatedly inside one rolled-back transaction.
  drop table if exists _sa_jobs;
  drop table if exists _sa_candidates;

  -- ==== eligible jobs + their anchor, in ONE set-based pass ================
  -- No per-job loop and no round-trips: this is the whole reason the port is
  -- worth doing. Anchor precedence is a single CASE so it stays readable.
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
       -- RULE 4: never, not even when named explicitly
       and c.client_code not in ('112-YA','777-YA','000-DH')
       -- RULE 5: a real physical-service line, not a billing-only warranty
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
         -- RULE 1: anchor precedence
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
      -- RULE 1 branch 2: same service_type, else a one-off call of another
      -- service silently sets the recurring cadence.
      select max(v.visit_date) as last_completed
        from public.visits v
       where v.client_id = s.client_id
         and v.visit_status = 'completed'
         and v.service_type = s.service_type
         and v.deleted_at is null
    ) lc on true;

  -- ==== RULE 3: the not-started guard =====================================
  -- BOTH conditions. `start_at IS NULL` alone would stop 9 live grandfathered jobs.
  select coalesce(jsonb_agg(jsonb_build_object(
           'job_id', job_id, 'job_number', job_number, 'title', title,
           'client_code', client_code,
           'reason', 'no start date and no visits yet — set a start date to begin scheduling')), '[]'::jsonb)
    into v_skipped
    from _sa_jobs
   where start_at is null and n_visits = 0;

  delete from _sa_jobs where start_at is null and n_visits = 0;

  -- ==== candidate dates ====================================================
  create temp table _sa_candidates on commit drop as
  select j.*, d::date as visit_date
    from _sa_jobs j
    cross join lateral (
      select d, row_number() over (order by d) as rn
        from generate_series(j.anchor::timestamp,
                             c_horizon_end::timestamp,
                             make_interval(days => j.frequency_days)) as g(d)
       where d::date >= c_today          -- past anchors fall forward
    ) s
   where s.rn <= c_max_per_job
     -- RULE 2: ±7d idempotency against any live visit on the job
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

  -- ==== insert =============================================================
  if not p_dry_run then
    insert into public.visits
      (client_id, job_id, visit_date, visit_status, source, title, service_type, derm_required)
    select client_id, job_id, visit_date, 'scheduled', 'supabase_cron',
           client_code || ' ' || client_name || ' - ' || title,
           service_type, derm_required
      from _sa_candidates;
    get diagnostics v_inserted = row_count;
  end if;

  -- ==== cleanup — FULL SWEEP ONLY (change (a)) =============================
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
      -- Mass-deleting visits is worse than leaving them. Refuse and report.
      v_cleanup_note := format('ABORTED: %s stale > max %s — likely a bulk data issue, investigate',
                               v_cleaned, c_max_cleanup);
      v_cleaned := 0;
    elsif v_cleaned > 0 and not p_dry_run then
      -- soft-delete fires trg_push_visit_update -> jobber-push-visit -> visitDelete
      update public.visits set deleted_at = now() where id = any(v_stale_ids);
    end if;
  end if;

  -- ==== observability, in the SAME transaction as the inserts ==============
  if not p_dry_run then
    insert into public.sync_log
      (sync_source, started_at, finished_at, rows_inserted, rows_updated,
       rows_errored, duration_seconds, status, details)
    values ('sa-visit-generation',
            v_run_started, clock_timestamp(),
            v_inserted,
            v_cleaned,                                   -- soft-deletes are updates
            case when v_cleanup_note is null then 0 else 1 end,
            round(extract(epoch from (clock_timestamp() - v_run_started))::numeric, 3),
            case when v_cleanup_note is null then 'success' else 'warning' end,
            jsonb_build_object(
              'scope',        coalesce(p_client_id::text, 'all'),
              'jobs',         (select count(*) from _sa_jobs),
              'generated',    v_inserted,
              'skipped',      jsonb_array_length(v_skipped),
              'cleaned',      v_cleaned,
              'cleanup_note', v_cleanup_note,
              'horizon_end',  c_horizon_end));
  end if;

  return jsonb_build_object(
    'dry_run',      p_dry_run,
    'scope',        coalesce(p_client_id::text, 'all'),
    'today',        c_today,
    'horizon_end',  c_horizon_end,
    'jobs_considered', (select count(*) from _sa_jobs),
    'generated',    case when p_dry_run then jsonb_array_length(v_planned) else v_inserted end,
    'planned',      v_planned,
    'skipped',      v_skipped,          -- change (b): the app can say WHY nothing happened
    'cleaned',      v_cleaned,
    'cleanup_note', v_cleanup_note,
    'ms',           round(extract(epoch from (clock_timestamp() - v_run_started)) * 1000));
end;
$fn$;

comment on function public.fn_generate_sa_visits(bigint, int, boolean) is
  'Generates Service Agreement visits. p_client_id null = full nightly sweep (and ONLY then does stale cleanup run); a client id = the Client App''s per-client "generate now", which is INSERT-only. Returns a structured result including per-job skip reasons so the caller can explain an empty run. Replaces scripts/sync/generate_service_agreement_visits.js + the sa-visit-generation GitHub workflow (2026-08-01).';

revoke all on function public.fn_generate_sa_visits(bigint, int, boolean) from public, anon;

-- ---------------------------------------------------------------------------
-- 2. the Client App's entry point — staff-gated, per client, never destructive
-- ---------------------------------------------------------------------------
create or replace function client.generate_visits_for_client(p_client_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_email text;
  v_res   jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email',''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_client_id is null then
    -- Guard the shape of the call itself: a null here would run the FULL sweep,
    -- including the destructive cleanup branch. The app must never do that.
    raise exception 'a client is required' using errcode = '22023';
  end if;

  select public.fn_generate_sa_visits(p_client_id) into v_res;
  return v_res;
end;
$fn$;

comment on function client.generate_visits_for_client(bigint) is
  'Client App: generate this client''s Service Agreement visits now instead of waiting for the nightly run. INSERT-only — never cleans up, never re-spaces existing visits. Refuses a null client_id, which would otherwise run the full destructive sweep.';

revoke all on function client.generate_visits_for_client(bigint) from public, anon, service_role;
grant execute on function client.generate_visits_for_client(bigint) to authenticated;

commit;
