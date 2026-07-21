-- ============================================================================
-- 2026-07-21f — RPA DERM-portal backend HARDENING (audit remediation)
-- ============================================================================
-- WHY: an independent 3-lens audit (2026-07-21) of the 21e backend found that
-- the ONE catastrophic outcome — filing a manifest to the Miami-Dade county
-- portal TWICE — is reachable not on the happy path but on the REJECTED-result
-- path. The queue re-dispenses any manifest lacking a recent submission ROW,
-- yet several branches rejected or failed to RECORD a genuine county
-- submission (bot-clock skew guard, whitespace-inflated screenshot size check,
-- crash between portal-submit and result-POST, a mis-named success token, and
-- a cutoff constant duplicated across three places). It also found the
-- compliance invariants lived only in the edge fn, not the DB, so any direct
-- writer could silently disarm the queue gates.
--
-- ROOT-CAUSE FIXES (this migration + the two edge-fn redeploys in the same
-- commit):
--  1. SINGLE-SOURCE CUTOFF: public.rpa_launch_cutoff() — both views + the
--     result fn's dry_run derivation now read ONE value; a widen-the-backlog
--     edit moves all of them together (was: 3 literals that could desync into
--     a permanent 422 -> re-queue -> double-submit).
--  2. SERVER-CLOCK QUEUE GATES: the cooldown and data-error-hold gates key off
--     the server-written created_at, never the bot-supplied attempted_at. A
--     bad/skewed attempted_at can no longer wedge a manifest out of the queue
--     nor release one prematurely. attempted_at is now display/audit only.
--  3. DISPENSE LEASE: rpa-derm-queue records a lease per served manifest;
--     the live queue holds a leased manifest for 20h even before any result
--     lands. This closes the crash-between-submit-and-POST window the 20h
--     cooldown could NOT cover (no row existed). Fails safe: a served-but-not-
--     submitted manifest is merely delayed, never double-filed.
--  4. SUCCESS-OR-CONFIRMATION permanent exit: a non-dry-run row with
--     status='SUCCESS' OR a non-null portal_confirmation permanently removes
--     the manifest. A county confirmation number is proof of filing even if
--     the bot labels the status something other than the exact 'SUCCESS'
--     literal (the bot was told to keep its own vocabulary).
--  5. DB BACKSTOP CONSTRAINTS so no writer (direct service_role, repair
--     script, future second endpoint) can violate a compliance invariant:
--       - run_id charset (it becomes a storage object key);
--       - SUCCESS requires portal_confirmation (no optimistic success);
--       - dry_run must match the manifest's cutoff classification (trigger).
--  6. WATCHDOG: v_rpa_derm_health + log_rpa_derm_health() + a pg_cron that
--     writes sync_log status='attention' when the queue is backed up with no
--     recent attempts (bot down / result POST 500ing), evidence was lost
--     (STORE_FAILED), or a manifest is stuck in a retry loop. Closes the "a
--     write outage is invisible for days" gap. GO-LIVE PREREQUISITE.
--
-- The edge fns (same commit) additionally: drop the attempted_at hard-reject,
-- whitespace-strip base64 before sizing/decoding, DERIVE dry_run server-side
-- (store the derived truth, never the bot's echoed flag), accept-and-flag
-- oversize/undecodable screenshots instead of 4xx-losing the attempt, and
-- retry the storage upload before STORE_FAILED.
--
-- 3NF: rpa_launch_cutoff is a pure function (config, not data); leases table
-- is one row per manifest (natural key manifest_id), no copied data. AUDIT:
-- derm_portal_submissions stays audited (21e); derm_portal_leases is opted
-- OUT (ephemeral dispatch bookkeeping, no compliance/PII content, self-
-- expiring; documented here per Rule 8). Views: security stays REVOKE-based
-- (service_role only) — security_invoker left off deliberately to avoid
-- breaking the service_role read path; the explicit REVOKEs are the guard.
--
-- VERIFICATION: appended after deploy (T1-T10 + new T11-T16).
-- ============================================================================

-- ─── 1. Single-source launch cutoff ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpa_launch_cutoff()
RETURNS date LANGUAGE sql IMMUTABLE AS $$ SELECT DATE '2026-07-21' $$;

-- ─── 3. Dispense-lease table ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.derm_portal_leases (
  manifest_id bigint PRIMARY KEY REFERENCES public.derm_manifests(id),
  leased_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.derm_portal_leases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.derm_portal_leases FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.derm_portal_leases TO service_role;

-- ─── 5. DB backstop constraints on submissions ──────────────────────────────
-- run_id charset (was length-only): it becomes a storage object key.
ALTER TABLE public.derm_portal_submissions
  DROP CONSTRAINT IF EXISTS derm_portal_submissions_run_id_check;
ALTER TABLE public.derm_portal_submissions
  ADD CONSTRAINT derm_portal_submissions_run_id_check
  CHECK (run_id ~ '^[A-Za-z0-9_.-]{1,100}$');

-- No optimistic success: a real SUCCESS must carry a portal confirmation.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'derm_portal_submissions_success_confirmed') THEN
    ALTER TABLE public.derm_portal_submissions
      ADD CONSTRAINT derm_portal_submissions_success_confirmed
      CHECK (status <> 'SUCCESS' OR dry_run OR portal_confirmation IS NOT NULL);
  END IF;
END $$;

-- dry_run must match the manifest's cutoff classification (queue gates all
-- filter NOT dry_run, so a mistagged live row would silently disarm them).
CREATE OR REPLACE FUNCTION public.trg_rpa_submission_dry_run_guard()
RETURNS trigger LANGUAGE plpgsql
SET search_path TO 'public' AS $$
DECLARE v_dump date;
BEGIN
  SELECT dump_ticket_date INTO v_dump FROM public.derm_manifests WHERE id = NEW.manifest_id;
  IF v_dump IS NOT NULL AND NEW.dry_run <> (v_dump < public.rpa_launch_cutoff()) THEN
    RAISE EXCEPTION 'dry_run=% disagrees with manifest % cutoff classification (dump %)',
      NEW.dry_run, NEW.manifest_id, v_dump;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_aa_rpa_submission_dry_run_guard ON public.derm_portal_submissions;
CREATE TRIGGER trg_aa_rpa_submission_dry_run_guard
  BEFORE INSERT OR UPDATE ON public.derm_portal_submissions
  FOR EACH ROW EXECUTE FUNCTION public.trg_rpa_submission_dry_run_guard();

-- ─── 2 + 4 + 3. Rebuild the queue view: server-clock gates, success-or-
--               confirmation exit, single-source cutoff, lease honoring ──────
CREATE OR REPLACE VIEW public.v_derm_portal_queue AS
SELECT f.*
FROM public.v_derm_portal_fields f
WHERE f.dump_ticket_date >= public.rpa_launch_cutoff()
  -- permanent exit: confirmed by the county (exact SUCCESS OR any confirmation)
  AND NOT EXISTS (
        SELECT 1 FROM public.derm_portal_submissions s
         WHERE s.manifest_id = f.manifest_id AND NOT s.dry_run
           AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL))
  -- 20h cooldown on the SERVER clock (created_at), not the bot's attempted_at
  AND NOT EXISTS (
        SELECT 1 FROM public.derm_portal_submissions s
         WHERE s.manifest_id = f.manifest_id AND NOT s.dry_run
           AND s.created_at > now() - interval '20 hours')
  -- non-retryable data error holds until the manifest row changes (server clock)
  AND NOT EXISTS (
        SELECT 1 FROM public.derm_portal_submissions s
         WHERE s.manifest_id = f.manifest_id AND NOT s.dry_run
           AND NOT s.retryable AND s.status <> 'SUCCESS'
           AND s.created_at > f.updated_at)
  -- dispense lease: a served manifest is held 20h even before any result lands
  AND NOT EXISTS (
        SELECT 1 FROM public.derm_portal_leases l
         WHERE l.manifest_id = f.manifest_id
           AND l.leased_at > now() - interval '20 hours');

CREATE OR REPLACE VIEW public.v_derm_portal_dryrun AS
SELECT f.*
FROM public.v_derm_portal_fields f
WHERE f.dump_ticket_date < public.rpa_launch_cutoff();

REVOKE ALL ON public.v_derm_portal_queue  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.v_derm_portal_dryrun FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_derm_portal_queue, public.v_derm_portal_dryrun TO service_role;

-- ─── 6. Watchdog ────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.v_rpa_derm_health AS
SELECT
  (SELECT count(*) FROM public.v_derm_portal_queue)                                 AS queue_depth,
  (SELECT max(created_at) FROM public.derm_portal_submissions WHERE NOT dry_run)    AS last_real_attempt,
  (SELECT count(*) FROM public.derm_portal_submissions
     WHERE NOT dry_run AND status = 'SUCCESS' AND created_at > now() - interval '24 hours') AS success_24h,
  (SELECT count(*) FROM public.derm_portal_submissions
     WHERE NOT dry_run AND screenshot_missing_reason = 'STORE_FAILED')             AS store_failed_total,
  (SELECT count(*) FROM (
     SELECT manifest_id FROM public.derm_portal_submissions
      WHERE NOT dry_run GROUP BY manifest_id HAVING count(*) >= 3) q)              AS manifests_ge3_attempts;

REVOKE ALL ON public.v_rpa_derm_health FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_rpa_derm_health TO service_role;

CREATE OR REPLACE FUNCTION public.log_rpa_derm_health()
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE h record; reasons jsonb := '[]'::jsonb; attn boolean := false;
BEGIN
  SELECT * INTO h FROM public.v_rpa_derm_health;
  -- bot down / result POST failing: queue backed up but nothing landing
  IF h.queue_depth > 0 AND (h.last_real_attempt IS NULL OR h.last_real_attempt < now() - interval '26 hours') THEN
    attn := true; reasons := reasons || jsonb_build_object('kind','no_recent_attempts',
      'queue_depth', h.queue_depth, 'last_real_attempt', h.last_real_attempt);
  END IF;
  IF h.store_failed_total > 0 THEN
    attn := true; reasons := reasons || jsonb_build_object('kind','evidence_lost_store_failed',
      'count', h.store_failed_total);
  END IF;
  IF h.manifests_ge3_attempts > 0 THEN
    attn := true; reasons := reasons || jsonb_build_object('kind','retry_loop_manifests',
      'count', h.manifests_ge3_attempts);
  END IF;
  INSERT INTO public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  VALUES ('rpa-derm-health', now(), now(),
          COALESCE(h.queue_depth,0),
          CASE WHEN attn THEN 'attention' ELSE 'ok' END,
          jsonb_build_object('queue_depth', h.queue_depth, 'last_real_attempt', h.last_real_attempt,
                             'success_24h', h.success_24h, 'store_failed_total', h.store_failed_total,
                             'manifests_ge3_attempts', h.manifests_ge3_attempts, 'reasons', reasons));
  RETURN CASE WHEN attn THEN 1 ELSE 0 END;
END $$;

-- Scheduled a few hours after a nightly bot run would post. Safe while the bot
-- is dormant: queue_depth is 0 pre-launch (cutoff), so it logs 'ok'.
SELECT cron.schedule('rpa-derm-health-check', '0 9 * * *', $cmd$ SELECT public.log_rpa_derm_health(); $cmd$);

-- ============================================================================
-- VERIFICATION RECORD — 2026-07-21, T1-T18 ALL PASS (live deployed fns +
-- migration; synthetic arena 112-YA ticket 999906; backup at
-- ..\backups\2026-07-21_rpa_hardening_test_rows.json; teardown clean, 0 residue)
-- ============================================================================
-- T1-T3   auth 401; live queue shape/cap; dryrun signed URL 200.
-- T4      live fetch queues + LEASES the manifest; a dryrun fetch leases nothing.
-- T11     dispense lease holds a served manifest 20h even with NO submission
--         row (crash-before-POST window closed); re-queues after the lease ages.
-- T5      structural 4xx retained (status/field/evidence/unknown-manifest/
--         run_id charset/success-needs-confirmation).
-- T12     a +5h future attempted_at is ACCEPTED (no skew reject); the queue
--         cooldown keys off server created_at, so a skewed bot clock cannot
--         wedge or prematurely release the queue.
-- T13     a non-'SUCCESS' status carrying a portal_confirmation permanently
--         dequeues (county confirmation = proof of filing).
-- T14     MIME-wrapped (newline) 4MB base64 is stored, not false-rejected
--         (whitespace stripped before sizing).
-- T15     an oversize screenshot is ACCEPTED-AND-FLAGGED (SCREENSHOT_TOO_LARGE),
--         the attempt recorded, not 4xx-lost.
-- T16     DB backstops reject bad DIRECT writes: SUCCESS w/o confirmation,
--         bad run_id charset, dry_run disagreeing with the cutoff.
-- T17     dry_run is DERIVED server-side; a bot lying dry_run=true on a live
--         SUCCESS is stored false and the manifest still leaves the queue.
-- T6/T8/T9 idempotency + private bucket; data-error hold (server clock);
--         SUCCESS permanent.
-- T18     log_rpa_derm_health() writes sync_log (status 'ok' while dormant).
-- ============================================================================
