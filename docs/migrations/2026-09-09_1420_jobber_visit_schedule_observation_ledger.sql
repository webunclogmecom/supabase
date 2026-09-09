-- =====================================================================================
-- 2026-09-09_1420  The Jobber visit-schedule OBSERVATION LEDGER
--   sync.jobber_visit_schedule_observed  + sync.jobber_visit_schedule_changes
--   sync.fn_record_visit_schedule_observations   (recorder)
--   public.fn_record_visit_schedule_observations (PostgREST wrapper)
--   public.fn_jobber_visit_schedule_interval     (the (lo, hi] reader)
-- =====================================================================================
-- WHY ---------------------------------------------------------------------------------
-- Fred, 2026-09-09, on the Calendar's "Same day in both, but the times differ" banner:
--   "Jobber is not authoritative, the Calendar App + Jobber, is a two-way partnership, where who
--    ever gets the latest change wins... if i changed a visit at Jobber at 9:30AM but at the
--    calendar i made a change at 9:31AM then Jobber adopts Calendar, same thing vice versa."
--   and, for the case where we cannot tell them apart: "the Calendar Wins, so you need to push the
--   Calendar on Jobber."
--
-- Last-writer-wins needs two clocks. We have ours (audit.logs.changed_at) and Jobber does not
-- publish one. Measured live 2026-09-09 against the Jobber API, not inferred: the GraphQL `Visit`
-- type exposes 31 fields with includeDeprecated:true and there is NO `updatedAt`; its time-bearing
-- fields are completedAt, createdAt, endAt, startAt, time, timeSheetEntries. `VisitsSortableFields`
-- offers only CREATED_AT / START_AT / CLIENT_PRIMARY_NAME / STATUS.
--
-- So Jobber's change time has to be OBSERVED. This table is that observation.
--
-- The same conclusion is already written down in adopt-visit-from-jobber/index.ts (2026-08-03):
-- "A real automatic rule needs a genuine 'Jobber changed at' signal, which would mean recording when
-- the OBSERVED Jobber startAt actually changes, and would only work going forward." This is that
-- recording. It is the documented next step, not a new idea.
--
-- THE LEDGER YIELDS AN INTERVAL, NOT AN INSTANT, AND THAT IS THE WHOLE POINT -----------
--   Witnessing a new Jobber value at `hi`, when the previous witness at `lo` held a different one,
--   proves only:   Jobber changed at some instant in (lo, hi].
--   Our own change time T is a known instant. The decision is interval-vs-instant:
--       T <= lo      -> Jobber is strictly newer   -> ADOPT
--       T >  hi      -> we are strictly newer      -> PUSH
--       lo < T <= hi -> undecidable                -> PUSH  (Fred's rule: the Calendar wins)
--   A naive instant compare treating `hi` as "when Jobber changed" would hand Fred's own 9:30/9:31
--   example to Jobber: a 30-minute poll would not witness the 09:30 Jobber edit until 10:00, and
--   10:00 looks newer than the 09:31 Calendar edit. The interval is what makes the rule correct.
--
-- THE PUSH ACK IS THE MOST VALUABLE OBSERVATION AND IT IS FREE ------------------------
--   jobber-push-visit issues visitEditSchedule, throws on any userErrors, and only then pushes
--   "schedule" into `did`. A clean return is an attested statement that JOBBER HELD OUR VALUE at
--   that instant, at millisecond resolution.
--   Measured over the 30 visits that produced all 1,078 `jobber_time_differs` banner appearances in
--   45 days: a push ACK sits strictly between the office edit and the first surfacing in 29 of 30
--   (median lag 0.779s, min 0.005s, max 5.17s). The 30th, visit 7814, confirms in the SAME
--   transaction via the `edit_calendar_visit_verified` saga, so it is a second ACK shape, not an
--   exception.
--   With the ACK as `lo`, T <= lo holds and those episodes decide ADOPT. The historical oracle
--   agrees: of the 30 episodes the value that actually stuck was JOBBER's in 19, OURS in 0, a third
--   value in 8, and 3 were never written (19 = 15 written by jobber-daily-completion-reconcile plus
--   4 human adopt clicks). WITHOUT the ACK the identical rule decides PUSH on all 30 and is wrong on
--   all 30. That is why the recorder ships before the decision does.
--
-- THE TRANSITION TEST IS ON `start_at` ALONE. DELIBERATE, DO NOT "IMPROVE" IT TO A TRIPLE ---------
--   sync-jobber-visit-drift's isDrift() compares only startAt, and its poll query is
--   `{ id startAt endAt }` with NO `allDay`. The webhook path DOES carry allDay. Comparing a triple
--   would make the first poll observation after any webhook observation look like a transition and
--   manufacture a change every 30 minutes. end_at and all_day are stored as ANNOTATIONS only.
--
-- AN ABSENT NODE IS NO OBSERVATION, NOT AN EMPTY ONE ----------------------------------
--   The same rule sync-jobber-billing-observe states, for the same reason: coercing a missing answer
--   into a value is the defect that armed a mass archive in sync-jobber-job-drift. A row with
--   outcome <> 'hit' advances last_attempt_at / last_outcome and touches NOTHING else: not the
--   value, not last_seen_at, not the interval. This is load-bearing because read failures are not
--   rare: 730 across 566 of 2,154 runs in 45 days. A missing observation must never read as
--   "unchanged", or the interval silently widens with nothing to show for it.
--
-- WHY NOT sync.source_field_shadow ----------------------------------------------------
-- It is the obvious candidate and it is the wrong one. Two reasons sync-jobber-billing-observe
-- already measured in rolled-back probes when it made the same call:
--   1. fn_record_shadow with p_adopted_to=NULL re-baselines source_value on an ADOPT verdict, so a
--      finding vanishes after one pass.
--   2. CONFLICT_FROZEN (P0001) raises forever once conflict_at is set, so one conflicting row would
--      abort the whole run.
-- Three more specific to this ledger:
--   3. source_value and our_value are both NOT NULL, but this ledger MUST record a read failure,
--      where there is no source value at all.
--   4. It carries no prev-value witness, which is the entire mechanism here: `lo` is "when we last
--      saw the PREVIOUS value", and nothing in that table records it.
--   5. Write pattern: 967 slow-moving property-custom-field rows there, versus ~246 rows rewritten
--      ~48 times a day here. One relation serving both would need two fillfactor/autovacuum answers.
--
-- `sync` IS NOT A PostgREST-EXPOSED SCHEMA --------------------------------------------
--   supabase-js `.from('sync...')` resolves only in the exposed schemas and returns a SILENT 200
--   WITHOUT WRITING. sync-jobber-billing-observe hit exactly this on its first live run and left a
--   comment saying so. Every edge function must go through the public wrapper below.
--
-- RULE 8 (audit opt-in/opt-out): **OPT OUT**, both tables, and the arithmetic is the reason.
--   246 candidates x 47.9 runs/day = 11,783 observations/day = 4.30M/year. The September audit
--   partition measures 11,023 rows in 17 MB = 1,617 bytes/row, so an audit trigger here would write
--   ~6.95 GB/year into a database that is currently 804 MB. These are sync-only observation tables
--   with no human-editable field, which is the documented default for opt-out, and they touch no
--   customer.*, billing, DERM-compliance or webhook-secret data, so the hard rule does not apply.
--   sync.jobber_visit_schedule_changes IS the provenance record for this data and is append-only.
--
-- GRANTS: service_role only, mirroring sync.source_field_shadow ({postgres=arwdDxtm,
--   service_role=arwd}). NOT `authenticated`, NOT `anon`. Note that public's default ACL carries a
--   supabase_admin entry granting anon=arwdDxtm, which is one more reason these live in `sync`.
--
-- REVERSIBLE: yes, fully. Drop the three functions, then the two tables. Nothing references them
--   until the writers ship, so this migration ALONE changes no behaviour anywhere. It is inert.
-- =====================================================================================

begin;

-- ------------------------------------------------------------------------------------
-- 1. The shadow: one row per visit, updated in place.
-- ------------------------------------------------------------------------------------
create table if not exists sync.jobber_visit_schedule_observed (
  visit_id                bigint      primary key,
  jobber_gid              text,

  -- the CURRENT observed Jobber value. start_at is the only field the transition test reads.
  start_at                timestamptz,
  end_at                  timestamptz,
  all_day                 boolean,

  -- hi: the first instant at which we witnessed the CURRENT value.
  value_first_seen_at     timestamptz not null,
  -- the most recent instant at which we re-witnessed the CURRENT value.
  last_seen_at            timestamptz not null,

  -- lo: the last instant at which we witnessed the value this one REPLACED.
  -- NULL means we have never witnessed a transition for this visit, so the interval is unbounded
  -- on the left and no ADOPT may be derived from it.
  prev_start_at           timestamptz,
  prev_last_seen_at       timestamptz,

  -- provenance of the newest observation, and of the newest ATTEMPT (which may have failed).
  last_source             text        not null,
  last_outcome            text        not null,
  last_attempt_at         timestamptz not null,
  observations            bigint      not null default 0,
  transitions             bigint      not null default 0,
  updated_at              timestamptz not null default now(),

  constraint jvso_source_chk  check (last_source  in ('poll','push_ack','webhook','heal_readback','adopt_readback')),
  constraint jvso_outcome_chk check (last_outcome in ('hit','read_fail','gid_absent')),
  -- lo must precede hi whenever both exist. A malformed interval would silently widen the
  -- undecidable band, so refuse it at write time instead of reasoning about it later.
  constraint jvso_interval_chk check (prev_last_seen_at is null or prev_last_seen_at <= value_first_seen_at)
)
with (fillfactor = 70);   -- ~11,783 in-place UPDATEs/day over ~246 rows

comment on table sync.jobber_visit_schedule_observed is
  'Observed Jobber visit schedules. Yields the interval (prev_last_seen_at, value_first_seen_at] in which Jobber last changed. Written by the drift poll, the push ACK and the webhook fetch. Rule 8: audit OPT-OUT, see migration 2026-09-09_1420.';

create index if not exists jvso_last_attempt_idx on sync.jobber_visit_schedule_observed (last_attempt_at desc);

-- ------------------------------------------------------------------------------------
-- 2. The change log: appended ONLY on a witnessed transition.
-- ------------------------------------------------------------------------------------
create table if not exists sync.jobber_visit_schedule_changes (
  id                bigserial   primary key,
  visit_id          bigint      not null,
  -- the interval this transition was witnessed in: Jobber changed within (lo_at, hi_at].
  lo_at             timestamptz,          -- last witness of the old value; NULL = unbounded
  hi_at             timestamptz not null, -- first witness of the new value
  from_start_at     timestamptz,
  to_start_at       timestamptz,
  source            text        not null,
  created_at        timestamptz not null default now()
);

comment on table sync.jobber_visit_schedule_changes is
  'Append-only witnessed transitions of a Jobber visit start time. This is the provenance record that justifies the rule-8 audit opt-out on the shadow. See migration 2026-09-09_1420.';

create index if not exists jvsc_visit_idx on sync.jobber_visit_schedule_changes (visit_id, hi_at desc);

-- ------------------------------------------------------------------------------------
-- 3. The recorder. ONE writer for the transition logic so the three callers cannot diverge.
-- ------------------------------------------------------------------------------------
create or replace function sync.fn_record_visit_schedule_observations(p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path to 'sync', 'public', 'pg_temp'
as $function$
declare
  r            jsonb;
  v_visit_id   bigint;
  v_obs_at     timestamptz;
  v_outcome    text;
  v_source     text;
  v_start      timestamptz;
  v_end        timestamptz;
  v_allday     boolean;
  v_gid        text;
  cur          sync.jobber_visit_schedule_observed%rowtype;
  n            integer := 0;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    return 0;
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_visit_id := nullif(r->>'visit_id','')::bigint;
    v_source   := coalesce(nullif(r->>'source',''), 'poll');
    v_outcome  := coalesce(nullif(r->>'outcome',''), 'hit');
    v_obs_at   := coalesce(nullif(r->>'observed_at','')::timestamptz, now());
    v_start    := nullif(r->>'start_at','')::timestamptz;
    v_end      := nullif(r->>'end_at','')::timestamptz;
    v_allday   := nullif(r->>'all_day','')::boolean;
    v_gid      := nullif(r->>'jobber_gid','');

    if v_visit_id is null then continue; end if;
    -- A 'hit' must carry a value. Coercing a missing answer into a value is the defect this
    -- ledger's header names, so refuse it here rather than record a NULL as an observed schedule.
    if v_outcome = 'hit' and v_start is null then continue; end if;

    select * into cur from sync.jobber_visit_schedule_observed where visit_id = v_visit_id;

    -- ---------------- no row yet: FIRST observation. Record only, never decide from it. ----------
    if not found then
      if v_outcome <> 'hit' then continue; end if;   -- do not create a row from a failure
      insert into sync.jobber_visit_schedule_observed
        (visit_id, jobber_gid, start_at, end_at, all_day,
         value_first_seen_at, last_seen_at, prev_start_at, prev_last_seen_at,
         last_source, last_outcome, last_attempt_at, observations, transitions)
      values
        (v_visit_id, v_gid, v_start, v_end, v_allday,
         v_obs_at, v_obs_at, null, null,
         v_source, v_outcome, v_obs_at, 1, 0);
      n := n + 1;
      continue;
    end if;

    -- ---------------- a failed / absent read: advance the ATTEMPT only. -------------------------
    if v_outcome <> 'hit' then
      update sync.jobber_visit_schedule_observed
         set last_outcome    = v_outcome,
             last_source     = v_source,
             last_attempt_at = greatest(last_attempt_at, v_obs_at),
             updated_at      = now()
       where visit_id = v_visit_id;
      n := n + 1;
      continue;
    end if;

    -- ---------------- MONOTONICITY: drop a stale or duplicate witness. -------------------------
    -- Webhook deliveries duplicate (55.0% of genuine VISIT_UPDATE deliveries collapse onto the same
    -- (itemId, occurredAt) pair) and can arrive out of order against the poll. An observation no
    -- newer than our newest witness of the current value tells us nothing we do not already know,
    -- and applying it could move value_first_seen_at BACKWARDS, widening the interval.
    if v_obs_at <= cur.last_seen_at then
      continue;
    end if;

    if cur.start_at is not distinct from v_start then
      -- ------------- same value, later witness: extend last_seen_at. -----------------------------
      -- This is what makes `lo` sharp. A push ACK landing here is the attestation that Jobber held
      -- our value at that instant, which is what turns PUSH into ADOPT on the measured population.
      update sync.jobber_visit_schedule_observed
         set last_seen_at    = v_obs_at,
             end_at          = coalesce(v_end, end_at),
             all_day         = coalesce(v_allday, all_day),
             jobber_gid      = coalesce(v_gid, jobber_gid),
             last_source     = v_source,
             last_outcome    = 'hit',
             last_attempt_at = greatest(last_attempt_at, v_obs_at),
             observations    = observations + 1,
             updated_at      = now()
       where visit_id = v_visit_id;
    else
      -- ------------- TRANSITION: Jobber changed inside (cur.last_seen_at, v_obs_at]. -------------
      update sync.jobber_visit_schedule_observed
         set prev_start_at       = cur.start_at,
             prev_last_seen_at   = cur.last_seen_at,
             start_at            = v_start,
             end_at              = v_end,
             all_day             = v_allday,
             jobber_gid          = coalesce(v_gid, jobber_gid),
             value_first_seen_at = v_obs_at,
             last_seen_at        = v_obs_at,
             last_source         = v_source,
             last_outcome        = 'hit',
             last_attempt_at     = greatest(last_attempt_at, v_obs_at),
             observations        = observations + 1,
             transitions         = transitions + 1,
             updated_at          = now()
       where visit_id = v_visit_id;

      insert into sync.jobber_visit_schedule_changes
        (visit_id, lo_at, hi_at, from_start_at, to_start_at, source)
      values
        (v_visit_id, cur.last_seen_at, v_obs_at, cur.start_at, v_start, v_source);
    end if;

    n := n + 1;
  end loop;

  return n;
end;
$function$;

-- ------------------------------------------------------------------------------------
-- 4. The PostgREST wrapper. Edge functions call THIS; `sync` is not an exposed schema.
-- ------------------------------------------------------------------------------------
create or replace function public.fn_record_visit_schedule_observations(p_rows jsonb)
returns integer
language sql
security definer
set search_path to 'public', 'sync', 'pg_temp'
as $function$
  select sync.fn_record_visit_schedule_observations(p_rows);
$function$;

-- ------------------------------------------------------------------------------------
-- 5. The reader the decision rule consults.
--    Returns the interval (lo, hi] plus enough context for the caller to refuse to decide.
-- ------------------------------------------------------------------------------------
create or replace function public.fn_jobber_visit_schedule_interval(p_visit_id bigint)
returns table (
  jobber_start_at   timestamptz,
  jobber_end_at     timestamptz,
  jobber_all_day    boolean,
  lo_at             timestamptz,
  hi_at             timestamptz,
  last_seen_at      timestamptz,
  last_outcome      text,
  last_source       text,
  observations      bigint,
  transitions       bigint,
  decidable         boolean
)
language sql
stable
security definer
set search_path to 'public', 'sync', 'pg_temp'
as $function$
  select o.start_at, o.end_at, o.all_day,
         o.prev_last_seen_at, o.value_first_seen_at,
         o.last_seen_at, o.last_outcome, o.last_source,
         o.observations, o.transitions,
         -- A witnessed TRANSITION is what makes an interval; a single observation is not one.
         (o.prev_last_seen_at is not null and o.transitions > 0) as decidable
    from sync.jobber_visit_schedule_observed o
   where o.visit_id = p_visit_id;
$function$;

-- ------------------------------------------------------------------------------------
-- 6. Grants. service_role only, matching sync.source_field_shadow.
-- ------------------------------------------------------------------------------------
revoke all on sync.jobber_visit_schedule_observed from public;
revoke all on sync.jobber_visit_schedule_changes  from public;
grant select, insert, update, delete on sync.jobber_visit_schedule_observed to service_role;
grant select, insert, update, delete on sync.jobber_visit_schedule_changes  to service_role;
grant usage, select on sequence sync.jobber_visit_schedule_changes_id_seq to service_role;

revoke all on function sync.fn_record_visit_schedule_observations(jsonb)   from public;
revoke all on function public.fn_record_visit_schedule_observations(jsonb) from public;
revoke all on function public.fn_jobber_visit_schedule_interval(bigint)    from public;
grant execute on function sync.fn_record_visit_schedule_observations(jsonb)   to service_role;
grant execute on function public.fn_record_visit_schedule_observations(jsonb) to service_role;
grant execute on function public.fn_jobber_visit_schedule_interval(bigint)    to service_role;

commit;
