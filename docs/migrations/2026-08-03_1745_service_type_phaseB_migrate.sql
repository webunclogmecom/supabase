-- =====================================================================
-- 2026-08-03_1745  PHASE B (MIGRATE) — values + every object, one transaction
-- =====================================================================
-- WHY
--   Fred, 2026-08-03: "let's go with 'pumping' 'cleaning' or 'warranty', so CL
--   is cleaning correct", "LS is pumping, follow the sheet", "Delete".
--   Plan: docs/plans/2026-08-03_service_type_vocabulary_migration_plan.md
--   Analysis: docs/reference/service-type-vs-service-kind.md
--
-- MAPPING (the sheet's column G is the authority, catalogue code 04 Lift
-- Station reads "Pumping" there, which is why LS folds into Pumping):
--   GT -> Pumping                 1,741 rows (1,398 alive)
--   CL -> Cleaning                  304 rows (  258 alive)
--   WD -> Warranty of Drainage      141 rows (    1 alive)
--   LS -> Pumping                    16 rows (   15 alive)
--   NULL -> NULL (untouched)        206 rows (   70 alive)
--
-- WHY THIS IS ONE TRANSACTION AND NOT CHUNKED
--   The audit recommended chunking the UPDATE to bound the ~5 MB audit write
--   and WAL burst. Rejected deliberately: 2,408 rows is small (the largest
--   dependent view recomputes in 216 ms), and chunking requires separate
--   COMMITs, which would leave windows where the data says 'Pumping' while a
--   view still compares to 'GT'. Those views fail by returning BLANK, not by
--   erroring. Atomicity is worth more here than bounding a 5 MB burst.
--
-- KNOWN, ACCEPTED SIDE EFFECTS
--   * 2,408 audit.logs rows (~5 MB) and 2,408 rewritten visits.updated_at.
--     Do NOT read 2026-08-03 updated_at as real activity.
--   * audit.logs now permanently mixes both vocabularies at the same jsonb
--     key. It is NOT rewritten (an audit trail records what was observed).
--     Any historical query must accept BOTH, e.g.
--       new_row->>'service_type' IN ('GT','Pumping')
--   * trg_gdo_compliance_check fires once per row. fn_check_gdo_on_visit is
--     replaced FIRST, below, so the trigger evaluates the NEW vocabulary while
--     the mass UPDATE runs.
--
-- VERIFIED SAFE — a service_type-only UPDATE does NOT push to Jobber and does
--   NOT enqueue sync_state. The two triggers reach that result by DIFFERENT
--   mechanisms, and an earlier version of this header wrongly said both used a
--   WHEN clause:
--     * trg_push_visit_update  — HAS a WHEN clause, listing visit_date,
--       start_at, end_at, title, notes, job_id, service_line_item_id,
--       line_items_rev, team_rev, deleted_at, visit_status. service_type absent.
--     * trg_mark_visit_sync_pending — has NO WHEN clause at all (tgqual IS NULL);
--       it fires on every INSERT/UPDATE and the column guard lives INSIDE
--       fn_mark_visit_sync_pending, whose change list also omits service_type.
--   Both verified via pg_get_triggerdef + pg_get_functiondef. Do not add
--   service_type to either. If you re-verify, read the FUNCTION for the second
--   one — reading only the trigger definition will look like it has no guard.
--
-- APPROVED DELTAS — folding LS into Pumping pulls 15 previously-excluded
--   visits into ops.v_calendar_visit for the first time. All are EXPECTED.
--
--   🛑 THE FIRST PUBLISHED VERSION OF THESE NUMBERS WAS WRONG. It read
--   "057-BAY 2 -> 3, 083-SHUL 57 -> 42, 168-AVA 12 -> 9". Those came from a
--   simulation that omitted the `days_since_prev BETWEEN 5 AND 200` filter the
--   live observed_cadence CTE actually carries. 057-BAY's lift-station work is
--   consecutive-day (gaps of 1-2 days), so the real CTE discards it entirely.
--   Re-measured WITH the filter, only TWO series move and neither matches the
--   original claim:
--       057-BAY   NO cadence at all -> 32 days   (n 0 -> 5 gaps)
--       083-SHUL  57 -> 42 days                  (n 3 -> 4 gaps)  [this one held]
--       168-AVA   UNCHANGED at 21 days           (does not move)
--   057-BAY is the notable one: it gains an observed cadence where it had none,
--   so the Calendar will start showing an expected date for a client that
--   previously had no computed one.
--
--   CONFIG-DERIVED COLUMNS ALSO MOVE, on the same 15 visits. Their empty LS
--   service_config is retired, so they now join the client's Pumping config and
--   inherit its numbers. THE COMPLETE measured diff over every column of
--   ops.v_calendar_visit (key-by-key via to_jsonb, not an enumerated list):
--       service_type          1672 rows      visit_updated_at     1672 rows
--       expected_date           16 rows      frequency_days         15 rows
--       amount_estimated        15 rows      sc_first_visit         15 rows
--       sc_last_visit           15 rows      service_kind           14 rows
--       last_completed_date      4 rows      equipment_size_gallons  2 rows
--       EVERY OTHER COLUMN: 0 rows — including late_status, sa_group,
--       service_label and amount.
--   Concretely: visit 1553 (083-SHUL) starts showing 1,000 gal and $1,800, and
--   the thirteen 057-BAY visits show freq 30 / $375.
--
--   ⚠ service_kind (14 rows) is the SA/SC chip, and was found ONLY by the
--   key-by-key diff — an enumerated column list missed it, as did a full
--   adversarial review. observed_job_cadence excluded LS, so those jobs had no
--   median gap and fell through to the ELSE 'SC' branch; inside the Pumping
--   series they gain one and flip to 'SA'. All 14 are completed "Lyft station
--   cleaning" visits on 057-BAY and 083-SHUL. Display-only, historical.
--   ⇒ LESSON: snapshot to_jsonb(t) and diff per key. Naming the columns you
--   expect to move is how you miss the one that actually did.
--
--   ⚠ expected_date moves on 2 rows that are NOT LS visits (6627 and 1598, both
--   057-BAY / 083-SHUL grease-trap visits). That is correct, not corruption: the
--   lateness anchor is prev_live_date, partitioned by (client, service_type), so
--   once LS visits join the Pumping series they become the previous live visit
--   for a neighbouring grease-trap visit.
--
--   WHY THIS IS ACCEPTABLE: all 15 LS visits are COMPLETED. Zero are scheduled
--   and zero are dated today or later, so nothing about future scheduling,
--   lateness or dispatch changes. amount (real line items) is untouched; only
--   amount_estimated, which is a fallback for visits without line items, moves.
--   The effect is display-only, on historical records.
--
-- RULE #6 EXCEPTION — HARD DELETE, EXPLICITLY APPROVED
--   The 7 LS service_configs rows are hard-deleted. Fred's word, 2026-08-03:
--   "Delete." There is no soft-delete path: service_configs has no deleted_at
--   and no status column (columns verified). All 7 are confirmed empty (0 of 7
--   carry a frequency, price, size, stop date, notes or material type) and all
--   7 belong to clients that ALSO hold a GT config, so 7 of 7 would violate
--   UNIQUE (client_id, service_type) once both map to 'Pumping'.
--   RECOVERY: service_configs is audited, so each DELETE is captured in
--   audit.logs.old_row and can be reinserted from there.
--
-- AUDIT OPT-IN (rule #8): no new tables. All touched tables already audited.
-- =====================================================================

begin;

set local search_path = public;
set local statement_timeout = '600s';

-- =====================================================================
-- 0. GUARD — refuse to run twice, and refuse to run before Phase A
-- =====================================================================
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'visits_service_type_chk'
                    and pg_get_constraintdef(oid) like '%Dump Offload%') then
    raise exception 'Phase A has not been applied — the widened CHECK is missing. Run 2026-08-03_1730 first.';
  end if;
  -- ⚠ The double-apply guard must NOT be "a Pumping row exists". Once the new
  --   webhook-jobber is deployed it writes the new vocabulary immediately, so
  --   Pumping rows legitimately appear BEFORE this migration runs and that
  --   guard would refuse to run at all. Guard on the thing that is actually
  --   true only after a successful run: nothing left to migrate.
  if not exists (select 1 from public.visits where service_type in ('GT','CL','WD','LS'))
     and not exists (select 1 from public.service_configs where service_type in ('GT','CL','WD','LS'))
     and not exists (select 1 from public.service_line_items where service_type in ('GT','CL','WD','LS'))
  then
    raise exception 'Nothing left to migrate — Phase B appears to have run already. Refusing to run twice.';
  end if;
end $$;

-- =====================================================================
-- 1. fn_check_gdo_on_visit FIRST — it is the trigger that fires on every row
--    of the mass UPDATE below.
--
--    ⚠ NULL SEMANTICS ARE PRESERVED DELIBERATELY. The original reads
--    `IF NEW.service_type != 'GT' THEN RETURN NEW`. For a NULL service_type
--    that expression is NULL, which is not TRUE, so the function does NOT
--    return early — i.e. NULL visits ARE currently GDO-checked. Writing this
--    as `IS DISTINCT FROM` would silently stop checking them. The `!=` form is
--    kept for exactly that reason.
-- =====================================================================
create or replace function public.fn_check_gdo_on_visit()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  v_county  TEXT;
  v_has_gdo BOOLEAN;
BEGIN
  -- Only care about pumping visits (was GT before the 2026-08-03 rename).
  -- NOTE: `!=` not `IS DISTINCT FROM` — see the migration header. NULL
  -- service_type must keep falling through to the check.
  IF NEW.service_type != 'Pumping' THEN
    RETURN NEW;
  END IF;

  -- Per-visit opt-out (visits.derm_required, 3-state:
  --   NULL  = default-true for pumping
  --   TRUE  = explicit opt-in
  --   FALSE = ops marked "not required" via DERM Tracker)
  IF NEW.derm_required IS FALSE THEN
    RETURN NEW;
  END IF;

  -- Check county (Dade only for v1)
  SELECT p.county INTO v_county
  FROM properties p
  WHERE p.client_id = NEW.client_id
    AND p.is_primary = true
  LIMIT 1;

  IF v_county IS DISTINCT FROM 'Dade' THEN
    RETURN NEW;
  END IF;

  -- Check gdos table (ACTIVE + EXPIRED both count as "has a permit",
  -- since EXPIRED still ties to the physical trap, just needs renewal)
  SELECT EXISTS(
    SELECT 1 FROM gdos g
    WHERE g.client_id = NEW.client_id
      AND g.status IN ('ACTIVE', 'EXPIRED')
  ) INTO v_has_gdo;

  -- Fire alert if no GDO on file
  IF NOT v_has_gdo THEN
    PERFORM pg_notify(
      'gdo_compliance_alert',
      json_build_object(
        'client_id',      NEW.client_id,
        'visit_id',       NEW.id,
        'visit_date',     NEW.visit_date,
        'derm_required',  NEW.derm_required,
        'event',          'gt_visit_no_gdo'
      )::text
    );
  END IF;

  RETURN NEW;
END;
$function$;

-- =====================================================================
-- 2. DATA — order matters. The 7 LS configs must go BEFORE the value UPDATE
--    or the UPDATE aborts with 23505 on the first one.
-- =====================================================================

-- 2a. Retire the 7 empty LS service_configs (rule #6 exception, see header).
--     Asserted empty at delete time rather than trusting the earlier survey:
--     a live object can change between two reads of it.
do $$
declare
  n_ls        int;
  n_nonempty  int;
  n_deleted   int;
begin
  select count(*) into n_ls from public.service_configs where service_type = 'LS';
  select count(*) into n_nonempty from public.service_configs
   where service_type = 'LS'
     and (frequency_days is not null or price_per_visit is not null
          or equipment_size_gallons is not null or stop_date is not null
          or schedule_notes is not null or material_type is not null);

  if n_nonempty > 0 then
    raise exception 'REFUSING: % of % LS service_configs are no longer empty. They were empty when surveyed; re-check before deleting.', n_nonempty, n_ls;
  end if;

  delete from public.service_configs where service_type = 'LS';
  get diagnostics n_deleted = row_count;
  raise notice 'Retired % empty LS service_configs (expected 7)', n_deleted;
end $$;

-- 2b/2c. The value rewrite, with its own before/after check.
--
--   ⚠ COUNTS ARE ASSERTED AS DELTAS, NOT ABSOLUTES. Once the new webhook-jobber
--   is deployed it writes the new vocabulary continuously, so an absolute
--   assertion like "Pumping must equal 1757" fails the moment a single Jobber
--   visit lands between Phase A and Phase B. That would be a FALSE failure of a
--   correct migration. What must hold is: every legacy row present when this
--   statement ran is now converted, and none remain.
do $$
declare
  n_cfg_before int; n_cfg_upd int;
  n_vis_before int; n_vis_upd int;
  n_left       int;
begin
  select count(*) into n_cfg_before from public.service_configs
   where service_type in ('GT','CL','WD','LS');
  select count(*) into n_vis_before from public.visits
   where service_type in ('GT','CL','WD','LS');

  -- service_configs. LS is already retired above, so no collision is possible.
  update public.service_configs
     set service_type = case service_type
           when 'GT' then 'Pumping'
           when 'CL' then 'Cleaning'
           when 'WD' then 'Warranty of Drainage'
         end
   where service_type in ('GT','CL','WD');
  get diagnostics n_cfg_upd = row_count;

  -- visits. ALL rows including soft-deleted ones — deliberately NOT filtered on
  -- deleted_at. v_calendar_visit's three cadence CTEs have no deleted_at filter
  -- (a pre-existing defect, logged separately), so soft-deleted rows already
  -- influence every median. Migrating them uniformly keeps that defect from
  -- surfacing as an apparent cadence regression.
  update public.visits
     set service_type = case service_type
           when 'GT' then 'Pumping'
           when 'CL' then 'Cleaning'
           when 'WD' then 'Warranty of Drainage'
           when 'LS' then 'Pumping'
         end
   where service_type in ('GT','CL','WD','LS');
  get diagnostics n_vis_upd = row_count;

  if n_cfg_upd <> n_cfg_before then
    raise exception 'service_configs: saw % legacy rows but updated %', n_cfg_before, n_cfg_upd;
  end if;
  if n_vis_upd <> n_vis_before then
    raise exception 'visits: saw % legacy rows but updated %', n_vis_before, n_vis_upd;
  end if;

  -- NEGATIVE CONTROL: this migration must actually DO something. A no-op
  -- produces zero diffs everywhere and would otherwise look like a clean pass.
  if n_vis_upd = 0 then
    raise exception 'NEGATIVE CONTROL: 0 visits updated — nothing was migrated';
  end if;

  select count(*) into n_left from public.visits where service_type in ('GT','CL','WD','LS');
  if n_left > 0 then
    raise exception '% legacy visits survived the UPDATE', n_left;
  end if;

  raise notice 'Values migrated: % visits, % service_configs', n_vis_upd, n_cfg_upd;
end $$;

-- 2d. The catalogue. service_type becomes the real name, i.e. exactly
--     service_kind. Both columns now hold identical values; service_kind is
--     dropped in Phase C once its 7 readers are re-based.
--     This is also what makes create_calendar_visit / edit_calendar_visit
--     self-migrate: they derive service_type from this table.
update public.service_line_items
   set service_type = service_kind
 where service_type is distinct from service_kind;

-- =====================================================================
-- 3. ops.fn_service_group — the object a NAME-based sweep cannot see, because
--    its parameter is p_type and the string 'service_type' never appears.
--
--    ⚠ CONTRACT CHANGE: the third argument now carries location_target, NOT
--    service_type. After the value migration sli.service_type is 'Pumping' for
--    BOTH grease trap (01/02/09) and grey water / lift station (03/04/10/11),
--    so it can no longer discriminate and PUMPING_GT would be unreachable —
--    1,006 Calendar chips would silently repaint.
--    location_target LIKE 'Grease Trap%' is provably equivalent to the old
--    service_type='GT' test: no catalogue row has one without the other.
--    The parameter keeps the name p_type only because CREATE OR REPLACE
--    cannot rename parameters and both callers depend on this function.
--    BOTH call sites are updated below, in this same transaction.
-- =====================================================================
create or replace function ops.fn_service_group(p_reason text, p_kind text, p_type text)
 returns text
 language sql
 immutable
as $function$
  SELECT CASE
    -- Service Agreements only — Yannick colour-coded the SA rows (01-07); SC rows carry no fill.
    -- p_type receives location_target as of 2026-08-03; see the migration header.
    WHEN p_reason = 'Service Agreement' AND p_kind = 'Pumping'
         AND p_type LIKE 'Grease Trap%'                          THEN 'PUMPING_GT'     -- 01, 02
    WHEN p_reason = 'Service Agreement' AND p_kind = 'Pumping'    THEN 'PUMPING_OTHER'  -- 03, 04 (Grey Water, Lift Station)
    WHEN p_reason = 'Service Agreement' AND p_kind = 'Cleaning'   THEN 'CLEANING'       -- 05, 06, 07
    WHEN p_reason = 'Service Agreement' AND p_kind = 'Warranty of Drainage' THEN 'WARRANTY_OF_DRAINAGE' -- 08, uncoloured
    ELSE NULL  -- every Service Call, and anything unmapped: the app renders its existing plain chip
  END
$function$;

comment on function ops.fn_service_group(text, text, text) is
  'SA chip colour group. THIRD ARGUMENT IS location_target, not service_type (renamed 2026-08-03; the parameter name p_type is a leftover CREATE OR REPLACE cannot change). Callers: ops.v_calendar_visit, ops.client_service_options.';

-- =====================================================================
-- 4. fn_generate_sa_visits — it held BOTH halves of the trap: it down-converted
--    the catalogue kind into a legacy code, and joined the SA cadence anchor on
--    that legacy value. The whole `typed` CTE down-conversion is now deleted;
--    service_kind IS the service_type.
--    Measured before changing: only Pumping (132 jobs) and Cleaning (6) are
--    ever in scope, so removing the old `else 'GT'` fallback is behaviour-
--    identical for all 138 jobs.
-- =====================================================================
create or replace function public.fn_generate_sa_visits(p_client_id bigint default null::bigint, p_horizon_months integer default 6, p_dry_run boolean default false)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
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
      (client_id, job_id, visit_date, visit_status, source, title, service_type, derm_required)
    select client_id, job_id, visit_date, 'scheduled', 'supabase_cron',
           client_code || ' ' || client_name || ' - ' || title,
           service_type, derm_required
      from _sa_candidates;
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
$function$;

-- =====================================================================
-- 5. client.update_property_capacity — 'GT' appears in a WHERE and in an
--    INSERT. App-invisible (the Client App passes only p_property_id and
--    p_gallons), so it migrates atomically with no app coordination.
-- =====================================================================
create or replace function client.update_property_capacity(p_property_id bigint, p_gallons integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_client bigint;
  v_id     bigint;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_gallons is not null and (p_gallons < 0 or p_gallons > 20000) then
    raise exception 'Capacity must be between 0 and 20,000 gallons.' using errcode = '22023';
  end if;
  select client_id into v_client from public.properties where id = p_property_id;
  if v_client is null then
    raise exception 'property % not found', p_property_id using errcode = 'P0002';
  end if;

  -- Prefer the property-scoped Pumping config; update in place. If none exists,
  -- create a minimal Pumping row (frequency NULL — inert to the legacy
  -- due-service logic, which keys on frequency). service_configs is audited,
  -- so the edit is captured with app_source. (Was GT before 2026-08-03.)
  select id into v_id from public.service_configs
   where property_id = p_property_id and service_type = 'Pumping'
   order by id limit 1;
  if v_id is not null then
    update public.service_configs set equipment_size_gallons = p_gallons where id = v_id;
  else
    insert into public.service_configs (client_id, service_type, property_id, equipment_size_gallons)
    values (v_client, 'Pumping', p_property_id, p_gallons)
    returning id into v_id;
  end if;
  return jsonb_build_object('service_config_id', v_id, 'gallons', p_gallons);
end
$function$;

-- =====================================================================
-- 6. VIEWS. All in this same transaction as the data — each of these fails by
--    returning BLANK or by silently lying, never by erroring, so a window
--    where data and view disagree is invisible until someone notices missing
--    numbers. CREATE OR REPLACE preserves column names/types/order, so
--    dependents (client_services_flat depends on ops.v_calendar_visit) hold.
-- =====================================================================

-- 6a. client.properties — grease capacity lookup
create or replace view client.properties as
 SELECT id, client_id, name, address, city, state, zip, country, is_billing,
    created_at, updated_at, latitude, longitude, geofence_radius_meters,
    geofence_type, access_hours_start, access_hours_end, access_days,
    is_primary, notes, county, grease_trap_manhole_count, access_notes,
    default_disposal_facility_id, zone_id, sample_port_count,
    ( SELECT z.code FROM zones z WHERE (z.id = p.zone_id)) AS zone,
    (( SELECT count(*) AS count FROM jobs j WHERE (j.property_id = p.id)))::integer AS job_count,
    (EXISTS ( SELECT 1 FROM entity_source_links l
          WHERE ((l.entity_type = 'property'::text) AND (l.source_system = 'jobber'::text) AND (l.entity_id = p.id)))) AS jobber_linked,
    ( SELECT sc.equipment_size_gallons
           FROM service_configs sc
          WHERE ((sc.property_id = p.id) AND (sc.service_type = 'Pumping'::text))
          ORDER BY sc.id
         LIMIT 1) AS grease_capacity_gallons,
    access_schedule
   FROM properties p;

-- 6b. customer.clients — Field Portal, customer-facing
create or replace view customer.clients as
 SELECT customer.uuid_from_bigint(c.id) AS id,
    lower(c.client_code) AS slug,
    c.name,
    c.client_code,
    cg.name AS group_name,
    p.address AS address1,
    NULLIF(TRIM(BOTH ' ,'::text FROM concat_ws(', '::text, NULLIF(p.city, ''::text), NULLIF(concat_ws(' '::text, NULLIF(p.state, ''::text), NULLIF(p.zip, ''::text)), ''::text))), ''::text) AS address2,
        CASE
            WHEN (sc_gt.equipment_size_gallons IS NOT NULL) THEN ((sc_gt.equipment_size_gallons)::text || ' gal grease trap'::text)
            ELSE NULL::text
        END AS container_type,
        CASE
            WHEN (sc_gt.equipment_size_gallons IS NOT NULL) THEN ((sc_gt.equipment_size_gallons)::text || ' gal'::text)
            ELSE NULL::text
        END AS trap_capacity,
    sc_gt.material_type AS material,
    df.name AS disposal_facility,
    ( SELECT g.permit_document_path
           FROM gdos g
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id
         LIMIT 1) AS gdo_permit_url,
    p.access_notes,
    c.created_at,
    c.status,
    (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AS is_active,
    ( SELECT max(j.frequency_days) AS max
           FROM jobs j
          WHERE ((j.client_id = c.id) AND (j.title ~~* '%Service Agreement%'::text) AND (j.job_status <> 'archived'::text) AND (j.frequency_days > 0))) AS service_frequency_days
   FROM ((((clients c
     LEFT JOIN client_groups cg ON ((cg.id = c.group_id)))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
     LEFT JOIN service_configs sc_gt ON (((sc_gt.client_id = c.id) AND (sc_gt.service_type = 'Pumping'::text))))
     LEFT JOIN disposal_facilities df ON ((df.id = p.default_disposal_facility_id)));

-- 6c. customer.permits — Field Portal GDO Permits section, customer-facing
create or replace view customer.permits as
 SELECT customer.uuid_from_bigint(g.id) AS id,
    customer.uuid_from_bigint(g.client_id) AS client_id,
    g.gdo_number AS permit_number,
    'Grease Trap'::text AS area,
        CASE
            WHEN (g.max_frequency_days IS NULL) THEN NULL::text
            WHEN (g.max_frequency_days <= 35) THEN 'Monthly'::text
            WHEN (g.max_frequency_days <= 95) THEN 'Quarterly'::text
            WHEN (g.max_frequency_days <= 185) THEN 'Semi-annually'::text
            WHEN (g.max_frequency_days <= 380) THEN 'Annually'::text
            ELSE (('Every '::text || g.max_frequency_days) || ' days'::text)
        END AS frequency,
    g.permit_document_path AS permit_url,
    ((row_number() OVER (PARTITION BY g.client_id ORDER BY g.property_id, g.gdo_number) - 1))::integer AS "position",
    customer.uuid_from_bigint(g.property_id) AS property_id,
    g.location_label,
    g.permit_expiration,
    g.max_frequency_days,
        CASE
            WHEN (g.max_frequency_days IS NULL) THEN NULL::boolean
            ELSE COALESCE(((CURRENT_DATE - ( SELECT max(v.visit_date) AS max
               FROM (visits v
                 JOIN properties vp ON ((vp.id = v.property_id)))
              WHERE ((v.client_id = g.client_id) AND (v.visit_status = 'completed'::text) AND (v.deleted_at IS NULL) AND ((v.property_id = g.property_id) OR (lower(btrim(vp.address)) = lower(btrim(gp.address))))))) > g.max_frequency_days), true)
        END AS over_gdo_max,
    COALESCE(sc.frequency_days, jf.freq) AS our_frequency_days,
        CASE
            WHEN ((COALESCE(sc.frequency_days, jf.freq) IS NULL) OR (g.max_frequency_days IS NULL)) THEN NULL::boolean
            ELSE (COALESCE(sc.frequency_days, jf.freq) <= g.max_frequency_days)
        END AS compliant
   FROM ((((gdos g
     JOIN clients c ON ((c.id = g.client_id)))
     LEFT JOIN properties gp ON ((gp.id = g.property_id)))
     LEFT JOIN LATERAL ( SELECT s.frequency_days
           FROM (service_configs s
             JOIN properties sp ON ((sp.id = s.property_id)))
          WHERE ((s.client_id = g.client_id) AND (s.service_type = 'Pumping'::text) AND (s.frequency_days IS NOT NULL) AND ((s.property_id = g.property_id) OR (lower(btrim(sp.address)) = lower(btrim(gp.address)))))
          ORDER BY (s.property_id = g.property_id) DESC, s.id
         LIMIT 1) sc ON (true))
     LEFT JOIN LATERAL ( SELECT j.frequency_days AS freq
           FROM jobs j
          WHERE ((j.client_id = g.client_id) AND (j.frequency_days > 0))
          ORDER BY (j.property_id = g.property_id) DESC NULLS LAST, j.id DESC
         LIMIT 1) jf ON (true))
  WHERE ((g.status = 'ACTIVE'::text) AND (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])));

-- 6d. ops.v_gdo_expiry — the constant emitted in the service_type column moves
--     with the vocabulary, otherwise this view starts LYING rather than erroring
create or replace view ops.v_gdo_expiry as
 SELECT c.id, c.client_code, c.name AS client_name, c.status AS client_status,
    p_z.code AS zone, p.address, p.city, p.county,
    cc.name AS contact_name, cc.email, cc.phone,
    'Pumping'::text AS service_type,
    g.gdo_number AS permit_number,
    g.permit_expiration,
    sc.equipment_size_gallons,
    sc.frequency_days,
    (g.permit_expiration - CURRENT_DATE) AS days_until_expiry,
        CASE
            WHEN (g.permit_expiration IS NULL) THEN 'no_permit'::text
            WHEN (g.permit_expiration < CURRENT_DATE) THEN 'expired'::text
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 30) THEN 'expiring_30d'::text
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 60) THEN 'expiring_60d'::text
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 90) THEN 'expiring_90d'::text
            ELSE 'valid'::text
        END AS permit_status
   FROM (((((gdos g
     JOIN clients c ON ((c.id = g.client_id)))
     LEFT JOIN properties p ON ((p.id = g.property_id)))
     LEFT JOIN client_contacts cc ON (((cc.client_id = c.id) AND (cc.contact_role = 'primary'::text))))
     LEFT JOIN service_configs sc ON (((sc.client_id = c.id) AND (sc.service_type = 'Pumping'::text))))
     LEFT JOIN zones p_z ON ((p_z.id = p.zone_id)))
  WHERE ((g.status = 'ACTIVE'::text) AND (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])))
  ORDER BY
        CASE
            WHEN (g.permit_expiration IS NULL) THEN 2
            WHEN (g.permit_expiration < CURRENT_DATE) THEN 1
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 30) THEN 3
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 60) THEN 4
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 90) THEN 5
            ELSE 6
        END, (g.permit_expiration - CURRENT_DATE);

-- 6e. ops.v_derm_compliance
create or replace view ops.v_derm_compliance as
 WITH last_manifest AS (
         SELECT derm_manifests.client_id,
            max(derm_manifests.service_date) AS last_manifest_date,
            count(*) AS total_manifests
           FROM derm_manifests
          GROUP BY derm_manifests.client_id
        ), unmatched_visits AS (
         SELECT v.client_id,
            count(*) AS missing_manifests
           FROM visits v
          WHERE (((v.derm_required IS NULL) OR (v.derm_required = true)) AND (v.visit_status = 'completed'::text) AND (v.deleted_at IS NULL) AND (v.visit_date >= (CURRENT_DATE - '120 days'::interval)) AND (NOT (EXISTS ( SELECT 1
                   FROM derm_manifests dm
                  WHERE ((dm.client_id = v.client_id) AND (dm.service_date = v.visit_date))))))
          GROUP BY v.client_id
        )
 SELECT c.id, c.client_code, c.name AS client_name, c.status AS client_status,
    p_z.code AS zone, p.address, p.city, p.county,
    cc.name AS contact_name, cc.email, cc.phone,
    ( SELECT g.gdo_number FROM gdos g
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id LIMIT 1) AS permit_number,
    ( SELECT g.permit_expiration FROM gdos g
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id LIMIT 1) AS permit_expiration,
    sc.equipment_size_gallons,
    sc.frequency_days,
    lm.last_manifest_date,
    lm.total_manifests,
    COALESCE(uv.missing_manifests, (0)::bigint) AS missing_manifest_count,
        CASE
            WHEN (COALESCE(uv.missing_manifests, (0)::bigint) > 0) THEN true
            ELSE false
        END AS has_missing_manifests,
    (CURRENT_DATE - lm.last_manifest_date) AS days_since_last_manifest,
        CASE
            WHEN (lm.last_manifest_date IS NULL) THEN 'no_service_record'::text
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > 90) THEN 'derm_violation'::text
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90)) THEN 'overdue'::text
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14)) THEN 'due_soon'::text
            ELSE 'compliant'::text
        END AS compliance_status
   FROM ((((((clients c
     JOIN service_configs sc ON (((sc.client_id = c.id) AND (sc.service_type = 'Pumping'::text))))
     LEFT JOIN client_contacts cc ON (((cc.client_id = c.id) AND (cc.contact_role = 'primary'::text))))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
     LEFT JOIN last_manifest lm ON ((lm.client_id = c.id)))
     LEFT JOIN unmatched_visits uv ON ((uv.client_id = c.id)))
     LEFT JOIN zones p_z ON ((p_z.id = p.zone_id)))
  WHERE (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]))
  ORDER BY
        CASE
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > 90) THEN 1
            WHEN (lm.last_manifest_date IS NULL) THEN 2
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90)) THEN 3
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14)) THEN 4
            ELSE 5
        END, COALESCE(uv.missing_manifests, (0)::bigint) DESC, (CURRENT_DATE - lm.last_manifest_date) DESC NULLS LAST;

-- 6f. ops.v_service_due
create or replace view ops.v_service_due as
 WITH actual_last_visit AS (
         SELECT visits.client_id,
            max(visits.visit_date) AS last_visit_actual
           FROM v_visits_live visits
          WHERE (visits.visit_status = 'completed'::text)
          GROUP BY visits.client_id
        )
 SELECT c.id, c.client_code, c.name AS client_name, c.status AS client_status,
    p_z.code AS zone, p.address, p.city, p.county,
    p.access_hours_start, p.access_hours_end,
    cc.name AS contact_name, cc.email, cc.phone,
    sc.service_type,
    sc.frequency_days,
    sc.equipment_size_gallons,
    ( SELECT g.gdo_number FROM gdos g
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id LIMIT 1) AS permit_number,
    sc.price_per_visit,
    COALESCE(sc.last_visit, alv.last_visit_actual) AS last_service_date,
    ((COALESCE(sc.last_visit, alv.last_visit_actual) + ((sc.frequency_days || ' days'::text))::interval))::date AS scheduled_next_visit,
    (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) AS days_since_service,
        CASE
            WHEN (COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL) THEN 'never_serviced'::text
            WHEN ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90) THEN 'derm_violation'::text
            WHEN ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days) THEN 'overdue'::text
            WHEN (((COALESCE(sc.last_visit, alv.last_visit_actual) + sc.frequency_days) - CURRENT_DATE) <= 14) THEN 'due_soon'::text
            ELSE 'on_schedule'::text
        END AS service_status
   FROM (((((clients c
     JOIN service_configs sc ON (((sc.client_id = c.id) AND (sc.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text])))))
     LEFT JOIN client_contacts cc ON (((cc.client_id = c.id) AND (cc.contact_role = 'primary'::text))))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
     LEFT JOIN actual_last_visit alv ON ((alv.client_id = c.id)))
     LEFT JOIN zones p_z ON ((p_z.id = p.zone_id)))
  WHERE ((c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AND ((COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL) OR ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= (COALESCE(sc.frequency_days, 90) - 14))))
  ORDER BY
        CASE
            WHEN ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90) THEN 1
            ELSE 2
        END, p_z.code,
        CASE
            WHEN (COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL) THEN 1
            WHEN ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days) THEN 2
            ELSE 3
        END, (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) DESC NULLS LAST;

-- 6g. ops.client_service_options — the 13th object, found by a caller sweep
--     rather than a literal sweep. It calls fn_service_group TWICE and must
--     move to location_target with it. It also ships service_type + service_kind
--     inside a JSON payload the Client App reads; both now hold the real name.
create or replace view ops.client_service_options as
 SELECT c.id AS client_id,
    c.client_code,
    c.name AS client_name,
    j.id AS job_id,
    j.job_number,
        CASE
            WHEN (j.title ~~* 'Service Agreement%'::text) THEN 'SA'::text
            ELSE 'SC'::text
        END AS job_kind,
    j.title AS job_title,
    j.frequency_days,
    j.property_id,
    COALESCE(svc.services, '[]'::json) AS services,
    svc.primary_group AS job_service_group
   FROM ((jobs j
     JOIN clients c ON ((c.id = j.client_id)))
     LEFT JOIN LATERAL ( SELECT json_agg(json_build_object('service_line_item_id', sli.id, 'code', sli.code, 'title', sli.title, 'requires_derm', sli.requires_derm, 'service_type', sli.service_type, 'service_kind', sli.service_kind, 'service_group', ops.fn_service_group(sli.reason, sli.service_kind, sli.location_target), 'unit_price', li.unit_price) ORDER BY sli.code) AS services,
            (array_agg(ops.fn_service_group(sli.reason, sli.service_kind, sli.location_target) ORDER BY sli.code))[1] AS primary_group
           FROM (line_items li
             JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text))))
          WHERE ((li.job_id = j.id) AND (sli.schedulable = true))) svc ON (true))
  WHERE ((j.job_status <> 'archived'::text) AND ((j.title IS NULL) OR (j.title !~~* '%[OLD]%'::text)));

-- 6h. ops.v_calendar_visit — the Calendar's whole cadence/lateness/chip surface.
--     Three CTE filters move vocabulary; four fn_service_group call sites move
--     to location_target. Generated from the LIVE definition with asserted
--     replacement counts (3 and 4), not hand-transcribed.
create or replace view ops.v_calendar_visit as
WITH last_completed AS (
         SELECT v_1.id AS visit_id,
            ( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE ((prev.client_id = v_1.client_id) AND (prev.service_type = v_1.service_type) AND (prev.visit_status = 'completed'::text) AND (prev.visit_date < v_1.visit_date))) AS last_completed_date
           FROM visits v_1
        ), prev_live AS (
         SELECT v_1.id AS visit_id,
            ( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE ((prev.client_id = v_1.client_id) AND (prev.service_type = v_1.service_type) AND (prev.visit_status = ANY (ARRAY['completed'::text, 'scheduled'::text])) AND (prev.deleted_at IS NULL) AND (prev.visit_date < v_1.visit_date))) AS prev_live_date
           FROM visits v_1
        ), observed_cadence AS (
         SELECT gaps.client_id,
            gaps.service_type,
            (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((gaps.days_since_prev)::double precision)))::integer AS median_gap_days
           FROM ( SELECT visits.client_id,
                    visits.service_type,
                    (visits.visit_date - lag(visits.visit_date) OVER (PARTITION BY visits.client_id, visits.service_type ORDER BY visits.visit_date)) AS days_since_prev
                   FROM visits
                  WHERE ((visits.visit_status = 'completed'::text) AND (visits.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text])))) gaps
          WHERE ((gaps.days_since_prev >= 5) AND (gaps.days_since_prev <= 200))
          GROUP BY gaps.client_id, gaps.service_type
        ), observed_price AS (
         SELECT v_1.client_id,
            v_1.service_type,
            (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((li.total_price)::double precision)))::numeric(12,2) AS median_line_price
           FROM (visits v_1
             JOIN line_items li ON ((li.invoice_id = v_1.invoice_id)))
          WHERE ((v_1.invoice_id IS NOT NULL) AND (v_1.visit_status = 'completed'::text) AND (v_1.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text])) AND (li.total_price > (0)::numeric))
          GROUP BY v_1.client_id, v_1.service_type
        ), observed_job_cadence AS (
         SELECT gaps.job_id,
            (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((gaps.days_since_prev)::double precision)))::integer AS median_gap_days
           FROM ( SELECT visits.job_id,
                    (visits.visit_date - lag(visits.visit_date) OVER (PARTITION BY visits.job_id ORDER BY visits.visit_date)) AS days_since_prev
                   FROM visits
                  WHERE ((visits.visit_status = 'completed'::text) AND (visits.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text])))) gaps
          WHERE ((gaps.days_since_prev >= 5) AND (gaps.days_since_prev <= 200))
          GROUP BY gaps.job_id
        )
 SELECT v.id,
    v.public_id,
    v.client_id,
    v.property_id,
    effv.vehicle_id,
    v.job_id,
    v.visit_date,
    v.visit_status,
    v.service_type,
    v.start_at,
    v.end_at,
    v.completed_at,
    COALESCE(v.duration_minutes, ((EXTRACT(epoch FROM (v.end_at - v.start_at)) / (60)::numeric))::integer) AS duration_minutes,
    v.title,
    v.derm_required,
    v.is_gps_confirmed,
    v.manhole_count,
    v.ticket_number,
    v.created_at AS visit_created_at,
    v.updated_at AS visit_updated_at,
    (COALESCE(NULLIF(( SELECT sum(li.total_price) AS sum
           FROM line_items li
          WHERE (li.visit_id = v.id)), (0)::numeric),
        CASE
            WHEN ((v.invoice_id IS NOT NULL) AND (( SELECT count(*) AS count
               FROM visits v2
              WHERE ((v2.invoice_id = v.invoice_id) AND (v2.deleted_at IS NULL))) = 1)) THEN ( SELECT sum(li.total_price) AS sum
               FROM line_items li
              WHERE (li.invoice_id = v.invoice_id))
            ELSE NULL::numeric
        END, ( SELECT sum(li.total_price) AS sum
           FROM line_items li
          WHERE ((li.job_id = v.job_id) AND (li.visit_id IS NULL) AND (li.invoice_id IS NULL))), ( SELECT sum(li.total_price) AS sum
           FROM line_items li
          WHERE (li.visit_id = v.id))))::numeric(12,2) AS amount,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    c.group_id AS client_group_id,
    COALESCE(pz.code, ppz.code) AS zone,
    COALESCE(prop.address, primary_prop.address) AS address,
    COALESCE(prop.city, primary_prop.city) AS city,
    COALESCE(prop.state, primary_prop.state) AS state,
    COALESCE(prop.zip, primary_prop.zip) AS zip,
    COALESCE(prop.county, primary_prop.county) AS county,
    COALESCE(prop.access_hours_start, primary_prop.access_hours_start) AS access_hours_start,
    COALESCE(prop.access_hours_end, primary_prop.access_hours_end) AS access_hours_end,
    COALESCE(prop.access_days, primary_prop.access_days) AS access_days,
    COALESCE(prop.latitude, primary_prop.latitude) AS latitude,
    COALESCE(prop.longitude, primary_prop.longitude) AS longitude,
    COALESCE(prop.grease_trap_manhole_count, primary_prop.grease_trap_manhole_count) AS manholes,
        CASE
            WHEN (c.client_code ~~ '000-%'::text) THEN NULLIF(jb.frequency_days, 0)
            ELSE COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days)
        END AS frequency_days,
    sc.equipment_size_gallons,
    sc.first_visit AS sc_first_visit,
    sc.last_visit AS sc_last_visit,
    sc.stop_date AS sc_stop_date,
    sc.material_type,
    g.gdo_number,
    g.permit_expiration AS gdo_expiration,
    g.max_frequency_days AS gdo_max_frequency_days,
    g.permit_document_path AS gdo_document_path,
    g.status AS gdo_status,
    veh.name AS truck_name,
    veh.status AS vehicle_status,
    veh.grease_tank_capacity_gallons,
    veh.fuel_tank_capacity_gallons,
    COALESCE(emp.id, asg.id) AS driver_id,
    COALESCE(emp.full_name, asg.full_name) AS driver_name,
    COALESCE(emp.role, asg.role) AS driver_role,
        CASE
            WHEN (v.visit_status = 'skipped'::text) THEN NULL::text
            WHEN (v.visit_status = 'completed'::text) THEN NULL::text
            WHEN (pl.prev_live_date IS NULL) THEN NULL::text
            WHEN (COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days) IS NULL) THEN NULL::text
            WHEN (((pl.prev_live_date + ((COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days))::double precision * '1 day'::interval)))::date < CURRENT_DATE) THEN 'late'::text
            WHEN (((pl.prev_live_date + ((COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days))::double precision * '1 day'::interval)))::date < v.visit_date) THEN 'will_be_late'::text
            ELSE 'on_time'::text
        END AS late_status,
    lc.last_completed_date,
    v.assigned_driver_id,
    asg.full_name AS assigned_driver_name,
    COALESCE(sc.price_per_visit, op.median_line_price) AS amount_estimated,
    ((v.start_at IS NULL) OR ((((v.start_at AT TIME ZONE 'America/New_York'::text))::time without time zone = '00:00:00'::time without time zone) AND (v.end_at IS NOT NULL) AND ((v.end_at - v.start_at) >= '23:00:00'::interval))) AS is_all_day,
        CASE
            WHEN (c.client_code ~~ '000-%'::text) THEN 'SC'::text
            WHEN (NULLIF(jb.frequency_days, 0) > 0) THEN 'SA'::text
            WHEN ((lower(jb.title) ~~ '%service call%'::text) OR (lower(jb.title) ~~ '%emergency%'::text)) THEN 'SC'::text
            WHEN ((ojc.median_gap_days > 0) OR (lower(jb.title) ~~ '%grease%'::text) OR (lower(jb.title) ~~ '%grey water%'::text) OR (lower(jb.title) ~~ '%service agreement%'::text)) THEN 'SA'::text
            ELSE 'SC'::text
        END AS service_kind,
    v.notes,
    v.sync_state,
    v.skip_reason,
    sagrp.sa_group,
        CASE
            WHEN (c.client_code ~~ '000-%'::text) THEN NULL::date
            WHEN (pl.prev_live_date IS NULL) THEN NULL::date
            WHEN (COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days) IS NULL) THEN NULL::date
            ELSE ((pl.prev_live_date + ((COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days))::double precision * '1 day'::interval)))::date
        END AS expected_date,
        CASE
            WHEN (emp.id IS NOT NULL) THEN emp.color_hex
            ELSE asg.color_hex
        END AS driver_color,
    COALESCE(( SELECT (array_agg(sli.service_kind ORDER BY (NOT sli.schedulable), sli.code) FILTER (WHERE (sli.service_kind IS NOT NULL)))[1] AS array_agg
           FROM (line_items li
             JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text))))
          WHERE (li.visit_id = v.id)), ( SELECT (array_agg(sli.service_kind ORDER BY (NOT sli.schedulable), sli.code) FILTER (WHERE (sli.service_kind IS NOT NULL)))[1] AS array_agg
           FROM (line_items li
             JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text))))
          WHERE ((li.job_id = v.job_id) AND (li.visit_id IS NULL) AND (li.invoice_id IS NULL))),
        CASE
            WHEN (v.derm_required IS TRUE) THEN 'Pumping'::text
            ELSE NULL::text
        END) AS service_label,
    v.vehicle_id AS assigned_vehicle_id,
        CASE
            WHEN (v.vehicle_id IS NOT NULL) THEN 'assigned'::text
            WHEN (effv.vehicle_id IS NOT NULL) THEN 'default'::text
            ELSE 'none'::text
        END AS vehicle_source
   FROM ((((((((((((((((((((visits v
     JOIN clients c ON ((c.id = v.client_id)))
     LEFT JOIN properties prop ON ((prop.id = v.property_id)))
     LEFT JOIN properties primary_prop ON (((primary_prop.client_id = v.client_id) AND (primary_prop.is_primary = true))))
     LEFT JOIN zones pz ON ((pz.id = prop.zone_id)))
     LEFT JOIN zones ppz ON ((ppz.id = primary_prop.zone_id)))
     LEFT JOIN service_configs sc ON (((sc.client_id = v.client_id) AND (sc.service_type = v.service_type))))
     LEFT JOIN LATERAL ( SELECT fn_resolve_gdo_id(v.client_id, v.property_id, v.id) AS gdo_id) r ON (true))
     LEFT JOIN gdos g ON ((g.id = r.gdo_id)))
     LEFT JOIN LATERAL ( SELECT COALESCE(v.vehicle_id, ( SELECT min(sli.default_vehicle_id) AS min
                   FROM (line_items li2
                     JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text))))
                  WHERE (li2.visit_id = v.id)), ( SELECT min(sli.default_vehicle_id) AS min
                   FROM (line_items li2
                     JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text))))
                  WHERE ((li2.job_id = v.job_id) AND (li2.visit_id IS NULL) AND (li2.invoice_id IS NULL)))) AS vehicle_id) effv ON (true))
     LEFT JOIN vehicles veh ON ((veh.id = effv.vehicle_id)))
     LEFT JOIN LATERAL ( SELECT COALESCE(( SELECT min(e.id) AS min
                   FROM (visit_assignments va
                     JOIN employees e ON ((e.id = va.employee_id)))
                  WHERE ((va.visit_id = v.id) AND (e.status = 'ACTIVE'::text))), ( SELECT min(va.employee_id) AS min
                   FROM visit_assignments va
                  WHERE (va.visit_id = v.id)), ( SELECT e.id
                   FROM (inspections i
                     JOIN employees e ON ((e.id = i.employee_id)))
                  WHERE ((i.vehicle_id = v.vehicle_id) AND (i.shift_date >= (v.visit_date - 1)) AND (i.shift_date <= (v.visit_date + 1)))
                  ORDER BY (i.shift_date = v.visit_date) DESC, (e.status = 'ACTIVE'::text) DESC, (abs((i.shift_date - v.visit_date))), e.id
                 LIMIT 1)) AS employee_id) fa ON (true))
     LEFT JOIN employees emp ON ((emp.id = fa.employee_id)))
     LEFT JOIN employees asg ON ((asg.id = v.assigned_driver_id)))
     LEFT JOIN last_completed lc ON ((lc.visit_id = v.id)))
     LEFT JOIN prev_live pl ON ((pl.visit_id = v.id)))
     LEFT JOIN observed_cadence oc ON (((oc.client_id = v.client_id) AND (oc.service_type = v.service_type))))
     LEFT JOIN observed_price op ON (((op.client_id = v.client_id) AND (op.service_type = v.service_type))))
     LEFT JOIN jobs jb ON ((jb.id = v.job_id)))
     LEFT JOIN observed_job_cadence ojc ON ((ojc.job_id = v.job_id)))
     LEFT JOIN LATERAL ( SELECT COALESCE(( SELECT (array_agg(ops.fn_service_group(sli.reason, sli.service_kind, sli.location_target) ORDER BY sli.code) FILTER (WHERE (ops.fn_service_group(sli.reason, sli.service_kind, sli.location_target) IS NOT NULL)))[1] AS grp
                   FROM (line_items li3
                     JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li3.name), '^([0-9]+)'::text), 2, '0'::text))))
                  WHERE ((li3.visit_id = v.id) AND (sli.schedulable = true))), ( SELECT (array_agg(ops.fn_service_group(sli.reason, sli.service_kind, sli.location_target) ORDER BY sli.code) FILTER (WHERE (ops.fn_service_group(sli.reason, sli.service_kind, sli.location_target) IS NOT NULL)))[1] AS grp
                   FROM (line_items li3
                     JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li3.name), '^([0-9]+)'::text), 2, '0'::text))))
                  WHERE ((li3.job_id = v.job_id) AND (li3.visit_id IS NULL) AND (li3.invoice_id IS NULL) AND (sli.schedulable = true)))) AS sa_group) sagrp ON (true))
  WHERE (v.deleted_at IS NULL);

-- 6i. public.client_services_flat — the GT/CL/WD pivot. 16 literals: 6 + 5 + 5,
--     each count asserted. This view fails by going BLANK, never by erroring,
--     which is why the assertions below check for non-null values and not just
--     for "no exception".
create or replace view public.client_services_flat as
SELECT c.id,
    c.name,
    c.client_code,
    p.address,
    p.city,
    p_z.code AS zone,
    c.status,
    max(
        CASE
            WHEN (s.service_type = 'Pumping'::text) THEN s.equipment_size_gallons
            ELSE NULL::numeric
        END) AS gt_size_gallons,
    max(
        CASE
            WHEN (s.service_type = 'Pumping'::text) THEN s.frequency_days
            ELSE NULL::integer
        END) AS gt_frequency_days,
    max(
        CASE
            WHEN (s.service_type = 'Pumping'::text) THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS gt_price_per_visit,
    max(
        CASE
            WHEN (s.service_type = 'Pumping'::text) THEN s.last_visit
            ELSE NULL::date
        END) AS gt_last_visit,
    max(
        CASE
            WHEN (s.service_type = 'Pumping'::text) THEN ((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date
            ELSE NULL::date
        END) AS gt_next_visit,
    max(
        CASE
            WHEN (s.service_type = 'Pumping'::text) THEN
            CASE
                WHEN ((s.last_visit IS NULL) OR (s.frequency_days IS NULL)) THEN 'UNKNOWN'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date < CURRENT_DATE) THEN 'OVERDUE'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS gt_status,
    max(
        CASE
            WHEN (s.service_type = 'Cleaning'::text) THEN s.frequency_days
            ELSE NULL::integer
        END) AS cl_frequency_days,
    max(
        CASE
            WHEN (s.service_type = 'Cleaning'::text) THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS cl_price_per_visit,
    max(
        CASE
            WHEN (s.service_type = 'Cleaning'::text) THEN s.last_visit
            ELSE NULL::date
        END) AS cl_last_visit,
    max(
        CASE
            WHEN (s.service_type = 'Cleaning'::text) THEN ((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date
            ELSE NULL::date
        END) AS cl_next_visit,
    max(
        CASE
            WHEN (s.service_type = 'Cleaning'::text) THEN
            CASE
                WHEN ((s.last_visit IS NULL) OR (s.frequency_days IS NULL)) THEN 'UNKNOWN'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date < CURRENT_DATE) THEN 'OVERDUE'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS cl_status,
    max(
        CASE
            WHEN (s.service_type = 'Warranty of Drainage'::text) THEN s.frequency_days
            ELSE NULL::integer
        END) AS wd_frequency_days,
    max(
        CASE
            WHEN (s.service_type = 'Warranty of Drainage'::text) THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS wd_price_per_visit,
    max(
        CASE
            WHEN (s.service_type = 'Warranty of Drainage'::text) THEN s.last_visit
            ELSE NULL::date
        END) AS wd_last_visit,
    max(
        CASE
            WHEN (s.service_type = 'Warranty of Drainage'::text) THEN ((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date
            ELSE NULL::date
        END) AS wd_next_visit,
    max(
        CASE
            WHEN (s.service_type = 'Warranty of Drainage'::text) THEN
            CASE
                WHEN ((s.last_visit IS NULL) OR (s.frequency_days IS NULL)) THEN 'UNKNOWN'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date < CURRENT_DATE) THEN 'OVERDUE'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS wd_status,
    max(nve.nve) AS next_visit_expected
   FROM ((((clients c
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
     LEFT JOIN service_configs s ON ((s.client_id = c.id)))
     LEFT JOIN zones p_z ON ((p_z.id = p.zone_id)))
     LEFT JOIN ( SELECT v_calendar_visit.client_id,
            min(v_calendar_visit.expected_date) AS nve
           FROM ops.v_calendar_visit
          WHERE ((v_calendar_visit.visit_status = 'scheduled'::text) AND (v_calendar_visit.visit_date >= CURRENT_DATE) AND (v_calendar_visit.expected_date IS NOT NULL))
          GROUP BY v_calendar_visit.client_id) nve ON ((nve.client_id = c.id)))
  GROUP BY c.id, p.address, p.city, p_z.code;

-- =====================================================================
-- 7. ASSERTIONS. These run INSIDE the transaction: any failure raises and
--    rolls the entire migration back. The failure mode for this change is
--    BLANK OUTPUT, not an exception, so every check below asserts a
--    NON-EMPTY / NON-NULL result rather than merely "no error was raised".
-- =====================================================================
do $$
declare
  n_legacy_v   int; n_legacy_c int; n_legacy_s int;
  n_pump       int; n_clean int; n_warr int;
  n_cfg        int;
  n_obj_legacy int; n_ctrl int;
  n_flat       int; n_cal int; n_grp int;
  v_grp        text;
begin
  -- 7a. ZERO legacy values may survive in any of the three tables
  select count(*) into n_legacy_v from public.visits
   where service_type in ('GT','CL','WD','LS');
  select count(*) into n_legacy_c from public.service_configs
   where service_type in ('GT','CL','WD','LS');
  select count(*) into n_legacy_s from public.service_line_items
   where service_type in ('GT','CL','WD','LS');
  if n_legacy_v + n_legacy_c + n_legacy_s > 0 then
    raise exception 'legacy values survived: visits=% service_configs=% catalogue=%',
      n_legacy_v, n_legacy_c, n_legacy_s;
  end if;

  -- 7b. Counts. Asserted as FLOORS, not equalities: the new webhook-jobber
  --     writes the new vocabulary continuously, so exact totals drift upward
  --     legitimately between Phase A and here. The exact conversion is already
  --     proven by the delta check in section 2b/2c; this is a sanity floor.
  --     Baseline at authoring time: 1741 GT + 16 LS = 1757 Pumping, 304
  --     Cleaning, 141 Warranty of Drainage.
  select count(*) filter (where service_type = 'Pumping'),
         count(*) filter (where service_type = 'Cleaning'),
         count(*) filter (where service_type = 'Warranty of Drainage')
    into n_pump, n_clean, n_warr
    from public.visits;
  if n_pump < 1757 then
    raise exception 'visits Pumping = %, expected at least 1757 (1741 GT + 16 LS)', n_pump;
  end if;
  if n_clean < 304 then
    raise exception 'visits Cleaning = %, expected at least 304', n_clean;
  end if;
  if n_warr < 141 then
    raise exception 'visits Warranty of Drainage = %, expected at least 141', n_warr;
  end if;

  -- 7c. service_configs: 270 - 7 retired LS = 263. Nothing writes this table on
  --     a timer, so an equality is safe here (the Client App capacity RPC is the
  --     only writer and it is user-driven).
  select count(*) into n_cfg from public.service_configs;
  if n_cfg <> 263 then
    raise exception 'service_configs = % rows, expected 263 (270 less the 7 retired LS)', n_cfg;
  end if;

  -- 7d. NO object definition may still compare to a legacy literal.
  --     Value-based sweep (the name-based one cannot see ops.fn_service_group),
  --     WITH a positive control: a 0-row sweep is an untested instrument.
  with defs as (
    select n.nspname||'.'||p.proname as obj, pg_get_functiondef(p.oid) d
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname not in ('pg_catalog','information_schema')
       and p.prokind in ('f','p')   -- procedures too, not just functions
    union all
    select schemaname||'.'||viewname, definition from pg_views
     where schemaname not in ('pg_catalog','information_schema')
  )
  select count(*) filter (where d ~ '''(GT|CL|WD|LS)'''),
         count(*) filter (where d ~ 'service_type')
    into n_obj_legacy, n_ctrl
    from defs;
  if n_ctrl = 0 then
    raise exception 'CONTROL FAILED: the object sweep found 0 objects naming service_type — the sweep itself is broken, not the schema';
  end if;
  if n_obj_legacy > 0 then
    raise exception '% object(s) still compare to a legacy GT/CL/WD/LS literal', n_obj_legacy;
  end if;

  -- 7e. client_services_flat must return DATA, not just "no error". This view
  --     degrades to all-NULL columns when the pivot literals stop matching,
  --     which is precisely the silent failure this migration risks.
  select count(*) into n_flat from public.client_services_flat
   where gt_frequency_days is not null;
  if n_flat = 0 then
    raise exception 'client_services_flat returned 0 rows with a non-null gt_frequency_days — the pivot is blank';
  end if;

  -- 7f. v_calendar_visit must still produce rows
  select count(*) into n_cal from ops.v_calendar_visit;
  if n_cal = 0 then
    raise exception 'ops.v_calendar_visit returned 0 rows';
  end if;

  -- 7g. PUMPING_GT must still be REACHABLE. This is the blocker the audit
  --     found: if fn_service_group loses its discriminator, every Pumping row
  --     silently collapses to PUMPING_OTHER and ~1,006 chips repaint with no
  --     error anywhere. Assert both the function and the live view.
  select ops.fn_service_group('Service Agreement','Pumping','Grease Trap & Tank Cleaning')
    into v_grp;
  if v_grp is distinct from 'PUMPING_GT' then
    raise exception 'fn_service_group no longer returns PUMPING_GT for a grease-trap SA row (got %)', v_grp;
  end if;
  if ops.fn_service_group('Service Agreement','Pumping','Lift Station & Tank Cleaning')
     is distinct from 'PUMPING_OTHER' then
    raise exception 'fn_service_group no longer separates PUMPING_OTHER — the discriminator is dead';
  end if;
  select count(*) into n_grp from ops.v_calendar_visit where sa_group = 'PUMPING_GT';
  if n_grp = 0 then
    raise exception 'ops.v_calendar_visit produced 0 PUMPING_GT chips — the discriminator is unreachable in the live view';
  end if;

  raise notice 'PHASE B OK — visits: % Pumping / % Cleaning / % Warranty; configs %; PUMPING_GT chips %',
    n_pump, n_clean, n_warr, n_cfg, n_grp;
end $$;

commit;
