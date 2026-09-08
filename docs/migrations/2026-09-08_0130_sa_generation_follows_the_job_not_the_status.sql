-- ============================================================================
-- 2026-09-08_0130_sa_generation_follows_the_job_not_the_status.sql
--
-- Let the SA visit generator serve ACTIVE clients that hold a real Service Agreement,
-- by making its generation gate agree with its own cleanup gate.
--
-- Fred, 2026-09-08, on the ACTIVE clients that hold real SAs: "If they're active leave
-- them active", and then, on whether the stranded ones should be flipped the other way:
-- "we dont need recurrent, as i said is to set recurrents to active".
-- So RECURRING is being retired as a status. That settles the business call the
-- 2026-07-31_1430 header put to Fred and deliberately refused to make silently.
--
-- WHY THIS IS URGENT, MEASURED TODAY.
--    public.fn_generate_sa_visits selected jobs with a RECURRING-only client test, and it
--    is the ONLY generator: pg_cron 'sa-visit-generation' calls it, and
--    client.generate_visits_for_client is a thin wrapper over it.
--    It serves 141 jobs / 135 clients today, EVERY ONE OF THEM RECURRING.
--    => If RECURRING is retired, the generator's scope becomes ZERO and SA visit
--    generation stops for the whole business, silently.
--
-- THE BUG WAS AN INTERNAL DISAGREEMENT, AND IT ALREADY HAS VICTIMS.
--    Generation required RECURRING, but the CLEANUP branch in the same function has always
--    accepted ACTIVE as well as RECURRING. So an ACTIVE client holding a real,
--    gate-passing SA had its existing visits PROTECTED from cleanup but never TOPPED UP.
--    Its schedule ran dry with nothing anywhere to show why. Measured, 0 upcoming each:
--      084-ULT Ultra Padel Club      every 30 days   last visit 2026-08-06
--      117-BH  Food Art Catering     every 30 days   last visit 2026-07-10
--      201-ALA Aladdin Mediterranean every 70 days   last visit 2026-07-04
--      Founders Shooting Club        every 30 days   NEVER had a visit (it also has NO
--                                    client_code, which the generator separately requires,
--                                    so it stays out of scope until that is set)
--    This migration makes the generation gate agree with the cleanup gate. That is the
--    whole change.
--
-- SCOPE CHANGE, measured before shipping:
--    jobs considered  141 -> 155   (+14)
--    clients served   135 -> 149   (+14)
--    No client of any other status holds a qualifying SA job, so nothing else moves.
--    INACTIVE and PAUSED remain excluded, preserving the 2026-07-31 safety net.
--
-- ALSO FIXED: the per-client skip message told operators "Visits are only generated for
--    RECURRING clients ... Set it to Recurring to schedule visits", which is now the
--    opposite of the policy.
--
-- NOT CHANGED: the job predicate itself (frequency > 0, title Service Agreement%, not
--    [OLD], not archived, an unbilled non-08 Service Agreement / Service Call line item),
--    the cleanup branch, the cleanup abort ceiling, and dry-run gating. The SA JOB remains
--    the authority on recurrence, which is what CLAUDE.md means when it says
--    clients.status is not authoritative.
--
-- Audit: N/A (function replace, no DML). Generation itself is INSERT-only.
-- ============================================================================

begin;

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
       -- 2026-09-08: this gate was RECURRING-only. Generation and CLEANUP disagreed about
       -- client scope: the cleanup branch below already accepts ACTIVE as well as RECURRING.
       -- That disagreement WAS the bug -- an ACTIVE client holding a real Service Agreement
       -- had its visits protected from cleanup but never generated, so its schedule silently
       -- ran dry (084-ULT, 117-BH, 201-ALA, Founders Shooting Club). The SA JOB is the
       -- authority on recurrence, not clients.status, which CLAUDE.md says is not authoritative.
       and c.status in ('ACTIVE','RECURRING')
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
             when c.status not in ('ACTIVE','RECURRING')
               then format('Visits are not generated for %s clients. Set the client to Active or Recurring to schedule visits.', c.status)
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

commit;

-- ---------------------------------------------------------------------------
-- VERIFY. Uses DRY RUN only (p_dry_run := true). Dry run gates every write in this
-- function: the visits INSERT ("if not p_dry_run"), the stale soft-delete
-- ("elsif v_cleaned > 0 and not p_dry_run") and the sync_log INSERT. Confirmed by
-- reading the body before running this.
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_all jsonb; v_one jsonb; v_skip jsonb;
  v_ult bigint; v_213 bigint;
begin
  select id into v_ult from public.clients where client_code = '084-ULT';
  select id into v_213 from public.clients where client_code = '213-TRUE';
  if v_ult is null or v_213 is null then
    raise exception 'VERIFY 0 FAILED: a fixture client is missing (084-ULT / 213-TRUE)';
  end if;

  v_all := public.fn_generate_sa_visits(null, 6, true);

  -- 1. scope widened to exactly the number measured before shipping
  if (v_all->>'jobs_considered')::int <> 155 then
    raise exception 'VERIFY 1 FAILED: jobs_considered = %, expected 155 (was 141 before this change)',
      v_all->>'jobs_considered';
  end if;

  -- 2. this run must not be planning to remove anything
  if (v_all->>'cleaned')::int <> 0 then
    raise exception 'VERIFY 2 FAILED: cleanup would soft-delete % visits; expected 0', v_all->>'cleaned';
  end if;

  -- 3. a stranded client is now IN scope AND has work planned
  v_one := public.fn_generate_sa_visits(v_ult, 6, true);
  if (v_one->>'jobs_considered')::int = 0 then
    raise exception 'VERIFY 3a FAILED: 084-ULT still out of scope after widening';
  end if;
  if (v_one->>'generated')::int = 0 then
    raise exception 'VERIFY 3b FAILED: 084-ULT is in scope but plans nothing: %', v_one;
  end if;

  -- 4. NEGATIVE CONTROL, same instrument, same call shape. A client with no qualifying SA
  --    must STILL be skipped. Without this, 1 and 3 pass just as well if the gate now
  --    accepts everyone, which is the failure mode that would actually hurt.
  v_skip := public.fn_generate_sa_visits(v_213, 6, true);
  if (v_skip->>'jobs_considered')::int <> 0 then
    raise exception 'VERIFY 4 FAILED (control): 213-TRUE holds no qualifying SA yet is in scope';
  end if;

  -- 5. the stale operator message must be gone
  if pg_get_functiondef('public.fn_generate_sa_visits(bigint,integer,boolean)'::regprocedure)
       ~ 'only generated for RECURRING clients' then
    raise exception 'VERIFY 5 FAILED: the RECURRING-only skip message is still in place';
  end if;

  raise notice 'VERIFY ok: jobs_considered %, cleaned %, 084-ULT plans % visits, 213-TRUE correctly skipped',
    v_all->>'jobs_considered', v_all->>'cleaned', v_one->>'generated';
end
$verify$;
