-- 2026-07-20c Revert the 5 unattributed derm_required locks of 2026-07-08
--
-- WHY: ops.v_derm_human_override_conflict lists visits where a human locked derm_required=false while
-- fn_visit_requires_derm says true. The lock exists to protect REAL human decisions from the nightly
-- cron. Five of the 52 rows are not human decisions at all.
--
-- Investigated 2026-07-20 (read-only, then approved by Fred). Visits 1621, 1711, 3927, 3929, 3942 were
-- all flipped derm_required true->false AND derm_required_locked false->true inside ONE transaction,
-- txid 971926 at 2026-07-08 19:35:52.699+00, app_source='sql', db_role='postgres', request_context NULL
-- and jwt_claims NULL. Verified independently by two reviewers:
--   * these 5 are the ONLY conflicts of the 52 with ZERO app_source='derm-tracker' audit rows in their
--     entire history (47 of 52 have one; these do not);
--   * the audit window covers the column's whole life (visits audit starts 2026-05-18, the first
--     derm_required audit row is 2026-05-19, the column was created by 2026-05-19c), so "no derm-tracker
--     decision ever" is a real absence and not an artifact of audit coverage;
--   * their only prior derm_required write was the 2026-06-24 ADR-018 backfill (NULL->true);
--   * they are NOT in the 2026-07-03 restore script's source CTE (running its exact CTE returns 0 rows
--     for these 5), so they were not a re-application of an earlier human choice;
--   * ALL FIVE have a live linked manifest at the same client with BOTH derm_manifest_url and
--     derm_address_url on file. The paperwork contradicts the override.
-- No cron job produces this write (all 11 cron.job rows enumerated); it was a one-off statement.
--
-- So these five were machine-written, are unattributable to any human, and are contradicted by their own
-- manifests. Reverting them restores the ADR-018 derived truth. This is the same class of fix the
-- 2026-07-03 remediation applied to 6 visits (1707, 4836, 4901, 5028, 5841, 5842), which still holds.
--
-- ⚠ ORDER MATTERS, THIS IS THE TRAP: trg_derm_required_lock is BEFORE UPDATE **OF derm_required**.
-- Writing both columns in one UPDATE silently half-applies: the trigger reverts the VALUE but keeps the
-- CLEARED LOCK, so the row drops out of the conflict view still marked not-required, and since
-- 2026-07-07 rederive_visits_derm_required only fills derm_required IS NULL, nothing would ever repair
-- it. Two statements: clear the lock FIRST (a lock-only update does not fire the trigger), then set the
-- value, then read both columns back.
--
-- Left UNLOCKED on purpose, matching the 2026-07-03 precedent: the value should stand as the derived
-- truth, not as a new pinned override. A human can still override it in DERM Tracker later, which will
-- re-lock it legitimately.
--
-- ⚠ SEPARATE FLAG, NOT FIXED HERE: visit 3942 (227-PER) is linked to manifest 995 whose
-- dump_ticket_date (2026-05-10) is BEFORE its visit_date (2026-05-11), i.e. serviced after the dump. It
-- is one of only three such links in the database (with 1265 and 1496) and survives only on trg_ac's
-- +1-day grace. That link's validity is a separate question and is NOT resolved by this migration;
-- reverting 3942's derm_required is justified independently by its own visit-scoped Grease Trap Pumping
-- line item, not by the manifest.
--
-- AUDIT (ADR 010): public.visits is audited; these UPDATEs are captured by audit_visits with
-- app_source='sql'. Reversible: re-running the inverse restores the prior state.

BEGIN;

-- Step 1: clear the lock ONLY. Does not fire trg_derm_required_lock (it is OF derm_required).
UPDATE public.visits
   SET derm_required_locked = false
 WHERE id IN (1621, 1711, 3927, 3929, 3942)
   AND derm_required_locked = true;

-- Step 2: now the value write is not reverted, because the row is no longer locked.
UPDATE public.visits
   SET derm_required = true
 WHERE id IN (1621, 1711, 3927, 3929, 3942)
   AND derm_required IS DISTINCT FROM true;

COMMIT;

-- Verification (run and eyeball; all five must read true / false / true):
--   SELECT id, derm_required, derm_required_locked, public.fn_visit_requires_derm(id) AS derived
--     FROM public.visits WHERE id IN (1621,1711,3927,3929,3942) ORDER BY id;
--   SELECT count(*) FROM ops.v_derm_human_override_conflict;   -- expect 52 - 5 = 47
