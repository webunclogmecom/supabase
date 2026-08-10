-- ============================================================================
-- 2026-08-10_1305: normalise access_days so STORED == DERIVED on every property
-- ============================================================================
-- Step 2b of finishing the access-hours migration. Fred, 2026-08-10:
--   "we can just do the migration for the old way of the access hours to the current
--    one, and once that is complete to do view checks on the apps, and do smoke tests
--    to also check the DB, and once that is complete we can drop the old way."
--
-- THE PLAN THIS SERVES, AND WHY IT IS CHEAPER THAN IT LOOKS.
-- The five views that expose the legacy trio will be repointed to DERIVE it from
-- access_schedule instead of reading the base columns. Every app keeps reading the
-- same three field names and NOTHING on any screen has to change -- which is what
-- makes Fred's "view checks on the apps" a check rather than a port. The base
-- columns then become droppable.
--
-- That switch is only a provable no-op if the derivation reproduces what is stored,
-- on every row. 2026-08-10_1212 (cb31b49) achieved that for the HOURS pair:
--     access_hours_start  198 of 198 match     access_hours_end  198 of 198 match
-- This migration closes the remaining gap, which is DAYS. Seven properties differ,
-- in two opposite directions.
--
-- GROUP 1 -- 5 properties hold access_days with NO hours and NO schedule.
--   521 (227-PER, 0 live visits), 157 (176-SOU, 2), 73 (140-TYO, 2),
--   362 (094-MOZ, 0), 109 (109-RAB, 1).
--   All five record ALL SEVEN DAYS. "Accessible every day" and "no access
--   restriction recorded" say the same thing, so clearing this carries no
--   information loss -- and access_schedule cannot express "these days, hours
--   unknown" at all (the RPC raises 22023 without an open/close pair), so there is
--   no lossless destination to migrate them TO.
--   ⇒ CLEARED. Derived NULL then equals stored NULL.
--
-- GROUP 2 -- 2 properties hold hours with access_days NULL.
--   6 (178-LG, 3 live visits) and 493 (112-YA, the test account).
--   The 2026-08-07 backfill wrote all seven days into their SCHEDULE, on the rule
--   that hours with no recorded day restriction mean "these hours, any day".
--   ⇒ THE SEVEN DAYS ARE WRITTEN BACK to access_days, so stored matches.
--
-- 🛑 WHY GROUP 2 IS NOT INSTEAD SOLVED BY MAKING THE DERIVATION RETURN NULL.
-- That was the tempting alternative: treat a 7-key schedule as "unrestricted" and
-- derive NULL. Measured first, and it is wrong:
--     schedules with 7 keys AND access_days storing all 7 : 169
--     schedules with 7 keys AND access_days NULL          :   2
-- 169 properties deliberately record all seven days. A rule mapping "7 keys -> NULL"
-- would blank all 169. The 2-row direction is the only consistent one.
--
-- VISIBLE EFFECT, STATED PLAINLY RATHER THAN BURIED.
-- The Visit Calendar omits its day strip when access_days is NULL, and renders a
-- full strip when all seven are listed. So:
--   - Group 1 (3 live visits across 157/73/109): an all-days strip stops rendering.
--   - Group 2 (3 live visits on property 6):     an all-days strip starts rendering.
-- Both directions move between two renderings of "no day restriction". No window,
-- no hour and no actual restriction changes anywhere. This is called out because it
-- is a real pixel change on 6 live visits, not because it is a risk.
--
-- SAFETY
-- - public.properties is audited, so all 7 writes carry old_row and are individually
--   revertible without a restore.
-- - The hourly Jobber property sweep writes address/city/state/zip/name/client_id/
--   lat/lng and touches no access column, so it cannot undo this.
-- - No hours and no schedule are read or written here. Only access_days moves.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table added or renamed, no trigger changed.
-- ============================================================================

-- PRE-STATE GUARD. If the data moved under this migration -- the parallel session, the
-- hourly poll, a Client App save -- the counts below will not match and nothing runs.
do $$
declare v_g1 int; v_g2 int;
begin
  select count(*) into v_g1 from public.properties
   where access_days is not null and access_hours_start is null and access_schedule is null;
  select count(*) into v_g2 from public.properties
   where access_schedule is not null and access_days is null;
  if v_g1 <> 5 or v_g2 <> 2 then
    raise exception 'pre-state moved: expected 5 days-only and 2 days-null, found % and %', v_g1, v_g2;
  end if;
end
$$;

-- GROUP 1: clear access_days where it is the only thing recorded.
update public.properties
   set access_days = null
 where access_days is not null
   and access_hours_start is null
   and access_schedule is null;

-- GROUP 2: adopt the schedule's days, in the canonical mon..sun order the rest of the
-- column uses (verified against 521/73/362/109, which all store that order).
update public.properties p
   set access_days = (
     select array_agg(k order by array_position(
              array['mon','tue','wed','thu','fri','sat','sun']::text[], k))
       from jsonb_object_keys(p.access_schedule) k)
 where p.access_schedule is not null
   and p.access_days is null;

do $$
declare
  v_days_mismatch int; v_days_only int; v_hours int; v_sched int;
  v_days_total int; v_orphan int; v_control int;
begin
  -- THE POINT OF THE EXERCISE: stored must now equal derived, for DAYS, on every row
  -- carrying a schedule. Compared as SETS, because access_days order is not canonical
  -- in the stored data (157 stored mon,tue,wed,thu,sun,sat,fri before this ran).
  select count(*) into v_days_mismatch from public.properties p
   where p.access_schedule is not null
     and (select array_agg(x order by x) from unnest(p.access_days) x) is distinct from
         (select array_agg(k order by k) from jsonb_object_keys(p.access_schedule) k);
  if v_days_mismatch <> 0 then
    raise exception 'stored still differs from derived on days for % rows', v_days_mismatch;
  end if;

  -- and no property may still hold days that the derivation cannot reproduce
  select count(*) into v_days_only from public.properties
   where access_days is not null and access_schedule is null;
  if v_days_only <> 0 then
    raise exception '% properties still hold access_days with no schedule', v_days_only;
  end if;

  -- DATA-LOSS CONTROLS. Every check above is satisfied by an empty column: NULL is
  -- not a mismatch and not an orphan. These assert the data is still here.
  select count(*) into v_hours from public.properties where access_hours_start is not null;
  select count(*) into v_sched from public.properties where access_schedule is not null;
  select count(*) into v_days_total from public.properties where access_days is not null;
  if v_hours <> 198 or v_sched <> 198 then
    raise exception 'hours/schedule moved: % hours, % schedules (expected 198/198)', v_hours, v_sched;
  end if;
  -- 201 - 5 cleared + 2 adopted = 198, and it must now equal the schedule count exactly
  if v_days_total <> 198 then
    raise exception 'expected 198 rows with access_days, found %', v_days_total;
  end if;

  -- every schedule has at least one key, so after this NO scheduled row may hold NULL days
  select count(*) into v_orphan from public.properties
   where access_schedule is not null and access_days is null;
  if v_orphan <> 0 then
    raise exception '% scheduled rows still hold NULL access_days', v_orphan;
  end if;

  -- POSITIVE CONTROL: a column this migration never touches must still be fully
  -- populated. If this reads 0 the instrument is broken and every check above is void.
  select count(*) into v_control from public.properties where address is not null;
  if v_control = 0 then
    raise exception 'control failed: address is empty, the probe is not measuring anything';
  end if;

  raise notice 'days normalised: 198 with schedule, 198 with days, 0 mismatches, % addresses intact', v_control;
end
$$;
