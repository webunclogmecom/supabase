-- 2026-08-05_0620_derm_unlock_seven_null_locked_visits.sql
--
-- WHAT: release the manual DERM lock on 7 completed visits that carry NO derm_required value,
--       then re-derive each one so the value reflects its line items.
--
-- WHY: Fred, 2026-08-05, choosing "Unlock 7, keep 1260 + 1476" from three options.
--      10 alive visits were locked with derm_required IS NULL. A locked row is exempt from
--      re-derivation forever (fn_lock_manual_derm_required's ELSIF preserves a locked value
--      against automated writers), so these 10 were frozen in an unfillable state.
--
-- 🛑 WHY 1260 AND 1476 ARE DELIBERATELY EXCLUDED. Simulated in a rolled-back transaction first:
--      both derive to FALSE, and derm_required = false is a CLIENT-VISIBILITY SWITCH -
--      customer.work_orders row-filters on COALESCE(v.derm_required, true) = true, so each would
--      have LOST ITS ENTIRE SERVICE RECORD from that client's Field Portal (1260 = 083-SHUL,
--      1476 = 133-MUT). Both have a DERM manifest ON FILE while their line items derive
--      "not required" - a genuine conflict that wants a person, not a rederive.
--      DO NOT "finish the job" by unlocking these two.
--
-- 1533 (175-PV) is also excluded: it derives to NULL, so unlocking it changes nothing.
--
-- Expected end state for the 7: derm_required = true, derm_required_locked = false.
-- No client-visible change (NULL and true are both visible; only false hides).
--
-- Statement 1 sets ONLY derm_required_locked, so trg_derm_required_lock (BEFORE UPDATE OF
-- derm_required) does NOT fire. Statement 2 runs as a non-derm caller on a now-unlocked row,
-- so neither trigger branch applies and the derived value lands.

BEGIN;

CREATE TEMP TABLE _targets (id bigint primary key);
INSERT INTO _targets VALUES (1334),(1547),(1597),(5100),(5101),(5745),(5830);

CREATE TEMP TABLE _before AS
SELECT v.id, v.derm_required, v.derm_required_locked
FROM public.visits v WHERE v.id IN (SELECT id FROM _targets);

-- PRE-ASSERTION: all 7 must be alive, completed, locked and NULL-valued. If the world moved
-- since the simulation, stop rather than write.
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.visits v
   WHERE v.id IN (SELECT id FROM _targets)
     AND v.deleted_at IS NULL AND v.visit_status = 'completed'
     AND v.derm_required IS NULL AND v.derm_required_locked IS TRUE;
  IF n <> 7 THEN
    RAISE EXCEPTION 'PRE-ASSERT FAILED: expected 7 alive/completed/locked/NULL targets, found %', n;
  END IF;
END $$;

UPDATE public.visits SET derm_required_locked = false
 WHERE id IN (SELECT id FROM _targets);

SELECT count(*) FROM (SELECT public.set_visit_derm_required(id) FROM _targets) x;

-- POST-ASSERTIONS
DO $$
DECLARE n int; m int;
BEGIN
  -- (a) all 7 landed on true, and are now unlocked
  SELECT count(*) INTO n FROM public.visits v
   WHERE v.id IN (SELECT id FROM _targets)
     AND v.derm_required IS TRUE AND v.derm_required_locked IS FALSE;
  IF n <> 7 THEN
    RAISE EXCEPTION 'POST-ASSERT FAILED: only % of 7 targets are true+unlocked', n;
  END IF;

  -- (b) the three deliberately-excluded rows are UNTOUCHED and still locked
  SELECT count(*) INTO m FROM public.visits v
   WHERE v.id IN (1260, 1476, 1533)
     AND v.derm_required_locked IS TRUE AND v.derm_required IS NULL;
  IF m <> 3 THEN
    RAISE EXCEPTION 'POST-ASSERT FAILED: 1260/1476/1533 must stay locked+NULL, only % do', m;
  END IF;

  -- (c) exactly 7 locks were released overall - nothing else moved
  SELECT count(*) INTO n FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.derm_required_locked IS TRUE;
  IF n <> 157 THEN
    RAISE EXCEPTION 'POST-ASSERT FAILED: alive locked count is %, expected 164 - 7 = 157', n;
  END IF;

  -- (d) CONTROL: the before-state really was different, so (a) is not vacuously true.
  --     Without this, a no-op migration would pass every assertion above.
  SELECT count(*) INTO n FROM _before b WHERE b.derm_required IS NULL AND b.derm_required_locked IS TRUE;
  IF n <> 7 THEN
    RAISE EXCEPTION 'CONTROL FAILED: before-state was not 7 locked+NULL rows (got %), so the post-assertions prove nothing', n;
  END IF;

  RAISE NOTICE 'OK: 7 visits unlocked and re-derived to true; 1260/1476/1533 untouched; alive locks 164 -> 157';
END $$;

COMMIT;
