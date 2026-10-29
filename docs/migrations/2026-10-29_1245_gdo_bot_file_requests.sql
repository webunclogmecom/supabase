-- ============================================================================
-- 2026-10-29 12:45 ET  "File it with the bot": log every press, and let an OLDER visit's
--                      button filing be recorded as a real one
-- ============================================================================
-- Trello xBCSvP6f. Jonathan's contract `API_CONTRACT_process_one.md` (v1, Slack thread
-- C0BD3VDPB9S/p1793048243300509). Fred, 2026-10-29: the button sends the full row, and
-- "Yes, only for button presses": an older visit (before rpa_launch_cutoff() = 2026-07-21)
-- filed through the DERM Tracker button is recorded as a REAL filing, filed by the person
-- who pressed. The hourly queue keeps the cutoff (the 2026-10-26 decision stands).
--
-- WHAT THIS ADDS
--   1. public.gdo_bot_file_requests: one row per press the bot ACCEPTED (its 202 carries
--      the run_id it minted). Written ONLY by edge fn gdo-bot-file-visit (service_role),
--      read by edge fn rpa-derm-result. Who pressed, which visit and permit, real or dry.
--   2. One new branch in trg_rpa_submission_dry_run_guard: a LIVE row on an older visit is
--      admitted when its (visit_id, run_id) is a logged LIVE press.
--
-- 🛑 THIS AMENDS THE SAME SAFETY RAIL AS 2026-08-19_1558. Why the new branch is safe, by
--    the same four points that migration made for manual rows:
--   1. v_derm_portal_queue still begins `WHERE visit_date >= rpa_launch_cutoff()`, so an
--      older visit never enters the bot's hourly queue, whatever rows it carries. A live
--      row there cannot suppress or trigger an automatic filing.
--   2. The bot cannot produce a row this branch admits on its own: it needs a ledger row,
--      and only gdo-bot-file-visit writes the ledger, after a signed-in person with Edit in
--      DERM Tracker pressed the button AND the bot answered with that run_id.
--   3. The ledger is service_role only (no grant to anon or authenticated, RLS on).
--   4. Every other row is judged exactly as before: the original body is byte-identical
--      apart from the added branch (copied from pg_get_functiondef, md5-pinned below).
--      A bot result on an older visit with no logged press is still stored as a dry run by
--      rpa-derm-result and still checked by the original branch.
--   ⚠ It does not move rpa_launch_cutoff() and must not be used to.
--
-- Rule 8 (audit): OPTED IN. The ledger decides whether a county filing is recorded as real
-- (DERM compliance), so every insert, change and delete is in audit.logs.
-- RLS: on (rls_auto_enable, 2026-10-28_1804), no policy on purpose: only service_role reads it.
-- Rollback: 2026-10-29_rollback_gdo_bot_file_requests.sql
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path = public, pg_catalog;

-- The guard body this migration was written against (2026-08-19_1558).
DO $pin$
BEGIN
  IF md5(pg_get_functiondef('public.trg_rpa_submission_dry_run_guard()'::regprocedure))
     <> '4dc9050887046081e64922b8ffcc53f8' THEN
    RAISE EXCEPTION 'trg_rpa_submission_dry_run_guard changed since this migration was written; re-read it first';
  END IF;
END $pin$;

CREATE TABLE public.gdo_bot_file_requests (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  visit_id      bigint NOT NULL REFERENCES public.visits(id),
  gdo_id        bigint NOT NULL REFERENCES public.gdos(id),
  run_id        text   NOT NULL CHECK (run_id ~ '^[A-Za-z0-9_.-]{1,100}$'),
  dry_run       boolean NOT NULL,
  requested_by  text   NOT NULL CHECK (requested_by ~ '[[:alnum:]]'),
  requested_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT gdo_bot_file_requests_visit_run_uniq UNIQUE (visit_id, run_id)
);

COMMENT ON TABLE public.gdo_bot_file_requests IS
  'One row per "File it with the bot" press the GDO bot accepted (DERM Tracker, Trello xBCSvP6f). '
  'Written only by edge fn gdo-bot-file-visit with the run_id from the bot''s 202. rpa-derm-result '
  'reads it: a result for a logged LIVE press is recorded as a real filing (also on a visit before '
  'rpa_launch_cutoff()), filed_by_email = requested_by; a result for a logged dry run is not recorded. '
  'service_role only. Migration 2026-10-29_1245.';

CREATE TRIGGER audit_gdo_bot_file_requests
  AFTER INSERT OR UPDATE OR DELETE ON public.gdo_bot_file_requests
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

REVOKE ALL ON public.gdo_bot_file_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.gdo_bot_file_requests TO service_role;

CREATE OR REPLACE FUNCTION public.trg_rpa_submission_dry_run_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE v_vdate date;
BEGIN
  -- A manual filing recorded by a person is outside this guard's scope. It is marked by a
  -- run_id the bot never uses, and pre-cutoff visits are excluded from the bot's queue by
  -- date regardless, so such a row cannot change what the bot does. See the migration header.
  IF NEW.run_id LIKE 'manual-%' AND NEW.dry_run IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  -- 2026-10-29: a LIVE result of a "File it with the bot" press is a real filing, also on a
  -- pre-cutoff visit. Only gdo-bot-file-visit logs a press, after a person pressed and the bot
  -- accepted it with this run_id. See 2026-10-29_1245.
  IF NEW.dry_run IS NOT TRUE AND EXISTS (
       SELECT 1 FROM public.gdo_bot_file_requests r
        WHERE r.visit_id = NEW.visit_id AND r.run_id = NEW.run_id AND r.dry_run IS NOT TRUE) THEN
    RETURN NEW;
  END IF;

  SELECT visit_date INTO v_vdate FROM public.visits WHERE id = NEW.visit_id;
  IF v_vdate IS NOT NULL AND NEW.dry_run <> (v_vdate < public.rpa_launch_cutoff()) THEN
    RAISE EXCEPTION 'dry_run=% disagrees with visit % service-date classification (visit_date %)',
      NEW.dry_run, NEW.visit_id, v_vdate;
  END IF;
  RETURN NEW;
END $function$;

-- ---------------------------------------------------------------- VERIFY
DO $verify$
DECLARE
  v_visit bigint; v_gdo bigint; v_post_visit bigint; v_post_gdo bigint;
  v_ok boolean;
  v_body text := pg_get_functiondef('public.trg_rpa_submission_dry_run_guard()'::regprocedure);
BEGIN
  -- V1 grants: nobody but service_role, RLS on, audited.
  IF has_table_privilege('anon', 'public.gdo_bot_file_requests', 'SELECT')
     OR has_table_privilege('authenticated', 'public.gdo_bot_file_requests', 'SELECT')
     OR has_table_privilege('authenticated', 'public.gdo_bot_file_requests', 'INSERT') THEN
    RAISE EXCEPTION 'V1: anon or authenticated holds a grant on gdo_bot_file_requests';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.gdo_bot_file_requests'::regclass) THEN
    RAISE EXCEPTION 'V1: RLS is off on gdo_bot_file_requests';
  END IF;

  -- V2 nothing else in the guard moved: the new body minus the added branch is the old body.
  IF md5(replace(v_body, $b$
  -- 2026-10-29: a LIVE result of a "File it with the bot" press is a real filing, also on a
  -- pre-cutoff visit. Only gdo-bot-file-visit logs a press, after a person pressed and the bot
  -- accepted it with this run_id. See 2026-10-29_1245.
  IF NEW.dry_run IS NOT TRUE AND EXISTS (
       SELECT 1 FROM public.gdo_bot_file_requests r
        WHERE r.visit_id = NEW.visit_id AND r.run_id = NEW.run_id AND r.dry_run IS NOT TRUE) THEN
    RETURN NEW;
  END IF;
$b$, '')) <> '4dc9050887046081e64922b8ffcc53f8' THEN
    RAISE EXCEPTION 'V2: the guard body differs from the old one by more than the added branch';
  END IF;

  -- A pre-cutoff visit with a permit, and a post-cutoff one (fixtures only, everything rolls back).
  SELECT r.visit_id, r.gdo_id INTO v_visit, v_gdo FROM derm.visit_gdo_our_record r
   WHERE r.visit_date < public.rpa_launch_cutoff() AND r.gdo_id IS NOT NULL ORDER BY r.visit_id LIMIT 1;
  SELECT r.visit_id, r.gdo_id INTO v_post_visit, v_post_gdo FROM derm.visit_gdo_our_record r
   WHERE r.visit_date >= public.rpa_launch_cutoff() AND r.gdo_id IS NOT NULL ORDER BY r.visit_id LIMIT 1;
  IF v_visit IS NULL OR v_post_visit IS NULL THEN RAISE EXCEPTION 'VERIFY: no fixture visits'; END IF;

  -- V3 a live row on an older visit with NO logged press is still refused.
  v_ok := false;
  BEGIN
    INSERT INTO public.derm_portal_submissions (visit_id, gdo_id, run_id, status, retryable, attempted_at, screenshot_missing_reason, dry_run)
    VALUES (v_visit, v_gdo, 'verify-1245-a', 'ERROR_VERIFY', true, now(), 'verify', false);
  EXCEPTION WHEN others THEN
    v_ok := SQLERRM LIKE 'dry_run=f disagrees%';
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'V3: a live row on an older visit with no logged press was not refused'; END IF;

  -- V4 with a logged LIVE press it is admitted (rolled back by the custom exception).
  v_ok := false;
  BEGIN
    INSERT INTO public.gdo_bot_file_requests (visit_id, gdo_id, run_id, dry_run, requested_by)
    VALUES (v_visit, v_gdo, 'verify-1245-b', false, 'fred@ayache.com');
    INSERT INTO public.derm_portal_submissions (visit_id, gdo_id, run_id, status, retryable, attempted_at, screenshot_missing_reason, dry_run)
    VALUES (v_visit, v_gdo, 'verify-1245-b', 'ERROR_VERIFY', true, now(), 'verify', false);
    RAISE EXCEPTION 'verify-1245-rollback';
  EXCEPTION WHEN others THEN
    v_ok := SQLERRM = 'verify-1245-rollback';
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'V4: a live row with a logged live press was refused'; END IF;

  -- V5 a logged DRY press does not admit a live row.
  v_ok := false;
  BEGIN
    INSERT INTO public.gdo_bot_file_requests (visit_id, gdo_id, run_id, dry_run, requested_by)
    VALUES (v_visit, v_gdo, 'verify-1245-c', true, 'fred@ayache.com');
    INSERT INTO public.derm_portal_submissions (visit_id, gdo_id, run_id, status, retryable, attempted_at, screenshot_missing_reason, dry_run)
    VALUES (v_visit, v_gdo, 'verify-1245-c', 'ERROR_VERIFY', true, now(), 'verify', false);
    RAISE EXCEPTION 'verify-1245-rollback';
  EXCEPTION WHEN others THEN
    v_ok := SQLERRM LIKE 'dry_run=f disagrees%';
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'V5: a logged dry press admitted a live row'; END IF;

  -- V6 a press logged for ANOTHER visit does not admit this one (the key is visit + run).
  v_ok := false;
  BEGIN
    INSERT INTO public.gdo_bot_file_requests (visit_id, gdo_id, run_id, dry_run, requested_by)
    VALUES (v_post_visit, v_post_gdo, 'verify-1245-d', false, 'fred@ayache.com');
    INSERT INTO public.derm_portal_submissions (visit_id, gdo_id, run_id, status, retryable, attempted_at, screenshot_missing_reason, dry_run)
    VALUES (v_visit, v_gdo, 'verify-1245-d', 'ERROR_VERIFY', true, now(), 'verify', false);
    RAISE EXCEPTION 'verify-1245-rollback';
  EXCEPTION WHEN others THEN
    v_ok := SQLERRM LIKE 'dry_run=f disagrees%';
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'V6: a press on another visit admitted this one'; END IF;

  -- V7 the post-cutoff rules are unchanged: a dry row there is still refused, press or not.
  v_ok := false;
  BEGIN
    INSERT INTO public.gdo_bot_file_requests (visit_id, gdo_id, run_id, dry_run, requested_by)
    VALUES (v_post_visit, v_post_gdo, 'verify-1245-e', false, 'fred@ayache.com');
    INSERT INTO public.derm_portal_submissions (visit_id, gdo_id, run_id, status, retryable, attempted_at, screenshot_missing_reason, dry_run)
    VALUES (v_post_visit, v_post_gdo, 'verify-1245-e', 'ERROR_VERIFY', true, now(), 'verify', true);
    RAISE EXCEPTION 'verify-1245-rollback';
  EXCEPTION WHEN others THEN
    v_ok := SQLERRM LIKE 'dry_run=t disagrees%';
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'V7: a dry row on a post-cutoff visit was admitted'; END IF;

  -- V8 nothing was left behind by the checks.
  IF EXISTS (SELECT 1 FROM public.gdo_bot_file_requests)
     OR EXISTS (SELECT 1 FROM public.derm_portal_submissions WHERE run_id LIKE 'verify-1245-%') THEN
    RAISE EXCEPTION 'V8: verify rows were left behind';
  END IF;
END $verify$;

COMMIT;
