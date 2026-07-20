-- 2026-07-20d Visit 1297 (009-CN Casa Neos, 2026-01-19): DERM manifest lost, marked not required
--
-- WHY: Diego (DERM owner), relayed by Fred 2026-07-20: "The DERM was lost, so we don't have it so let it
-- be not required." This is the oldest outstanding item in public.manifest_pickable_visits at 182 days
-- and the only violation of the 2-week rule.
--
-- ⚠ WHAT THIS ROW ACTUALLY MEANS, STATED PLAINLY SO NOBODY LATER MISREADS IT:
-- this visit DID require DERM. It carries visit-scoped line item '01 - Service Agreement - Pumping -
-- Grease Trap' ($1,400 = 4 x $350) AND '27 - GDO Online Reporting', it has 18 photos, driver Kevis Bell,
-- truck David, and paid invoice #1888. fn_visit_requires_derm(1297) returns true and will continue to.
-- derm_required=false here records an OPERATIONAL decision that the paperwork is unrecoverable, NOT a
-- finding that the service was exempt. Do not cite this row as evidence that a grease-trap pump-out does
-- not need a manifest.
--
-- Investigation established (2026-07-20) that this visit had NEVER been set not-required before: exactly
-- one derm_required write existed in its whole history, the 2026-06-24 ADR-018 backfill (NULL->true), and
-- ZERO app_source='derm-tracker' writes ever touched it. The flip-flopping Diego remembers was a
-- DIFFERENT Casa Neos visit, 1454 (2026-03-07): derm-tracker false 06-29 -> cron true 06-30 ->
-- derm-tracker false 06-30 -> cron true 07-01 -> restore false+lock 07-03. That loop was closed by the
-- 2026-07-07 migration (cron now fills only derm_required IS NULL); no cron re-promotion has occurred
-- since. 1454 is stable and is NOT touched here.
--
-- ⚠ ORDER MATTERS, AND IT IS THE OPPOSITE OF 2026-07-20c: trg_derm_required_lock reverts a derm_required
-- change when the row is ALREADY locked (it tests OLD.derm_required_locked). 1297 is currently unlocked,
-- so the value write lands. The lock must therefore be set SECOND, as its own statement. Setting the lock
-- first would cause the trigger to revert the value and leave a locked TRUE, the exact opposite of the
-- intent. (In 2026-07-20c the row was already locked, so there the lock had to be cleared FIRST.)
--
-- The lock is what makes it stick: both public.rederive_visits_derm_required (nightly cron) and
-- public.set_visit_derm_required (called by webhook-jobber on every visit ingest) carry
-- `derm_required_locked IS NOT TRUE`, so a locked false survives both.
--
-- AUDIT (ADR 010): public.visits is audited; both writes are captured with app_source='sql'. Reversible.

BEGIN;

-- Step 1: the value (allowed, because the row is not locked yet).
UPDATE public.visits
   SET derm_required = false
 WHERE id = 1297
   AND derm_required_locked IS NOT TRUE;

-- Step 2: the lock, as its own statement so the trigger cannot revert step 1.
UPDATE public.visits
   SET derm_required_locked = true
 WHERE id = 1297;

COMMIT;

-- Verification (expect false / true / true, and 1297 gone from the backlog):
--   SELECT id, derm_required, derm_required_locked, public.fn_visit_requires_derm(id) AS derived
--     FROM public.visits WHERE id = 1297;
--   SELECT count(*) FROM public.manifest_pickable_visits;          -- expect 16 - 1 = 15
--   SELECT count(*) FROM ops.v_derm_human_override_conflict;       -- expect 47 + 1 = 48, BY DESIGN:
--     this visit is genuinely a locked-false against a derived-true. It SHOULD sit in the review queue
--     as a known, deliberate, attributable exception rather than disappear silently.
