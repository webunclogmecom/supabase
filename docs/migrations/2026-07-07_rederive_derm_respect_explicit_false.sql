-- 2026-07-07_rederive_derm_respect_explicit_false.sql
-- Incident (audited read-only by the Supabase 1 session, 4 investigators + 2
-- skeptics; handed to Supabase 2 to deploy): cleared "not required" visits from
-- Jan–April re-appeared as "Missing Docs". Root cause = the nightly cron
-- rederive_visits_derm_required's promotion guard `derm_required IS NOT TRUE`,
-- which matches an explicit FALSE exactly like an unknown NULL — so on any UNLOCKED
-- visit it silently re-promotes a human/prior "not required" back to required
-- whenever line items change (e.g. the 07-06 $0 "Grease Trap Pumping" backfill flip).
-- The 2026-07-03 `derm_required_locked` lock only protects visits cleared in the
-- DERM app AFTER that date; older cleared decisions were never locked.
--
-- FIX (verified, unanimous across the audit + a live dry-run): tighten the guard
-- `derm_required IS NOT TRUE` -> `derm_required IS NULL`. The cron then fills only
-- genuine UNKNOWNS and NEVER overrides an explicit false (or true), lock or no lock —
-- closing the whole recurrence class with NO row backfill. `IS DISTINCT FROM d.derived`
-- + the lock guard are unchanged; `IS NULL` already never demotes a TRUE.
--
-- IMPACT (dry-run on live data before deploy): OLD predicate updates 0 rows right
-- now, NEW updates 0 rows right now — purely PREVENTIVE, zero immediate change. It
-- only differs on FUTURE nights when a line-item change would make an explicit-false
-- visit derive true; NEW leaves that explicit decision intact.
--
-- REJECTED (audit): blanket-locking the ~167 unlocked-false visits — 0 of them
-- derive true, 0 were human decisions, and locking machine-set falses creates silent
-- compliance blind-spots.
--
-- ⚠ SIBLING TO FIX SEPARATELY: public.set_visit_derm_required(bigint) has the
-- IDENTICAL `derm_required IS NOT TRUE` predicate on the per-visit (handleVisit /
-- Calendar RPC) path. Same one-word fix applies, but it's on the webhook path
-- (session-1 lane) — flagged for coordinated change, not touched here.
--
-- Audit (Rule 8): CREATE OR REPLACE of an existing function; no schema/trigger change.

CREATE OR REPLACE FUNCTION public.rederive_visits_derm_required()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE n integer;
BEGIN
  WITH d AS (
    SELECT id, public.fn_visit_requires_derm(id) AS derived
    FROM public.visits
    WHERE deleted_at IS NULL
  )
  UPDATE public.visits v
     SET derm_required = d.derived
    FROM d
   WHERE d.id = v.id
     AND d.derived IS NOT NULL
     AND v.derm_required IS NULL                 -- fill unknowns ONLY; never override an explicit false/true
     AND v.derm_required IS DISTINCT FROM d.derived
     AND v.derm_required_locked IS NOT TRUE;     -- (redundant now, kept for defense-in-depth)
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$function$;
