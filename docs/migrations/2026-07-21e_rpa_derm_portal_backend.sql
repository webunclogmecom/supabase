-- ============================================================================
-- 2026-07-21e — RPA DERM-portal bot backend: submissions table, queue views,
--               private evidence bucket
-- ============================================================================
-- WHY (Fred 2026-07-21: build the integration BEFORE replying to Jonathan):
-- Jonathan's Python RPA bot submits our Miami-Dade manifests on the county
-- DERM portal. Contract (docs/handoffs/2026-07-21_rpa_bot_reply_to_john.md):
-- the bot never touches the DB; it calls two secret-keyed edge fns —
-- rpa-derm-queue (GET, what to submit) and rpa-derm-result (POST, what
-- happened). This migration is the DB layer under those fns.
--
-- OBJECTS:
-- 1. public.derm_portal_submissions — append-only result log, one row per
--    (manifest_id, run_id) attempt. Machine-written via the result edge fn
--    only (service_role). Source-agnostic name: the business fact is "a
--    submission to the DERM portal", not "what the RPA tool did".
--    AUDIT: OPT-OUT per ADR 010 (sync-only append table written by one
--    machine path; it IS itself an audit log; no human-editable fields).
-- 2. public.v_derm_portal_fields — shared field list (grain: one row per
--    fully-complete, live, Miami-Dade manifest row). Reuses
--    derm.manifest_health (fully_complete) instead of re-deriving
--    completeness. Property/GDO/email are client-keyed first-match for v1;
--    refine to location grain when Jonathan confirms his CSV columns.
-- 3. public.v_derm_portal_queue — fields + LIFECYCLE gates (the contract's
--    queue-exit semantics):
--      a. no non-dry-run SUCCESS ever (SUCCESS is permanent);
--      b. no non-dry-run attempt in the last 20 hours (cooldown covers the
--         crash window between portal submit and result POST);
--      c. a non-retryable failure (data error, e.g. missing email) holds the
--         manifest OUT until the manifest row changes after the attempt
--         (s.attempted_at > m.updated_at blocks; an office edit bumps
--         updated_at and releases it).
-- 4. public.v_derm_portal_dryrun — fields only, manifests with a dump date
--    older than 30 days (already handled historically), for the bot's
--    ?mode=dryrun acceptance testing. No lifecycle gates; results from these
--    are stored with dry_run=true and never affect the real queue.
-- 5. storage bucket 'rpa-evidence' (PRIVATE) — portal screenshots. No RLS
--    policies on purpose: only service_role (the edge fn) reads/writes;
--    private bucket + zero policies = no anon/authenticated path at all.
--    DERM evidence never goes in a public bucket (standing rule).
--
-- GRANTS: the views expose client PII (names, addresses, emails) — SELECT is
-- granted to service_role ONLY and explicitly revoked from anon +
-- authenticated + PUBLIC. Additive cross-lane grant: service_role gets SELECT
-- on derm.manifest_health (the derm schema's default grants cover
-- anon+authenticated but NOT service_role — the 2026-07-20h lesson).
--
-- 3NF: table stores only attempt facts keyed by (manifest_id, run_id); views
-- are derived read models, nothing copied into storage.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.derm_portal_submissions (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  manifest_id               bigint NOT NULL REFERENCES public.derm_manifests(id),
  run_id                    text   NOT NULL CHECK (length(run_id) BETWEEN 1 AND 100),
  status                    text   NOT NULL CHECK (status ~ '^[A-Z0-9_]{1,64}$'),
  retryable                 boolean NOT NULL DEFAULT false,
  failure_reason            text   CHECK (failure_reason IS NULL OR length(failure_reason) <= 1000),
  portal_confirmation       text   CHECK (portal_confirmation IS NULL OR length(portal_confirmation) <= 200),
  attempted_at              timestamptz NOT NULL,
  screenshot_path           text,
  screenshot_missing_reason text   CHECK (screenshot_missing_reason IS NULL OR length(screenshot_missing_reason) <= 300),
  dry_run                   boolean NOT NULL DEFAULT false,
  created_at                timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT derm_portal_submissions_attempt_uniq UNIQUE (manifest_id, run_id),
  -- every terminal result carries evidence or an explicit reason it could not
  CONSTRAINT derm_portal_submissions_evidence CHECK (
    screenshot_path IS NOT NULL OR screenshot_missing_reason IS NOT NULL
  )
);

CREATE INDEX IF NOT EXISTS derm_portal_submissions_manifest_idx
  ON public.derm_portal_submissions (manifest_id, dry_run, attempted_at DESC);

ALTER TABLE public.derm_portal_submissions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.derm_portal_submissions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.derm_portal_submissions TO service_role;

GRANT SELECT ON derm.manifest_health TO service_role;

CREATE OR REPLACE VIEW public.v_derm_portal_fields AS
SELECT m.id AS manifest_id,
       m.white_manifest_number,
       m.dump_ticket_date,
       m.service_date,
       c.client_code,
       c.name AS client_name,
       ce.email AS client_email,
       pp.address, pp.city, pp.zip, pp.county,
       gd.gdo_number,
       df.name AS disposal_facility,
       m.derm_address_url, m.derm_address_extra_urls,
       m.derm_manifest_url, m.derm_manifest_extra_urls,
       m.updated_at
FROM public.derm_manifests m
JOIN derm.manifest_health h ON h.id = m.id AND h.health_state = 'fully_complete'
JOIN public.clients c ON c.id = m.client_id
LEFT JOIN LATERAL (
  SELECT cc.email FROM public.client_contacts cc
   WHERE cc.client_id = c.id AND cc.email IS NOT NULL AND cc.email <> ''
   ORDER BY cc.id LIMIT 1) ce ON true
LEFT JOIN LATERAL (
  SELECT p.address, p.city, p.zip, p.county FROM public.properties p
   WHERE p.client_id = c.id AND p.is_primary
   ORDER BY p.id LIMIT 1) pp ON true
LEFT JOIN LATERAL (
  SELECT g.gdo_number FROM public.gdos g
   WHERE g.client_id = c.id AND g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$'
   ORDER BY g.id LIMIT 1) gd ON true
LEFT JOIN public.disposal_facilities df ON df.id = m.disposal_facility_id
WHERE m.deleted_at IS NULL
  AND m.white_manifest_number IS NOT NULL;

CREATE OR REPLACE VIEW public.v_derm_portal_queue AS
SELECT f.*
FROM public.v_derm_portal_fields f
  -- LAUNCH CUTOFF (found by test T4, 2026-07-21): without it the live queue
  -- is the ENTIRE historical backlog (534 fully-complete Dade manifests with
  -- no SUCCESS row) and the bot's first run would re-submit months of
  -- already-handled paper to the county. Only manifests dumped ON/AFTER the
  -- cutoff enter the queue; the backlog stays out unless Fred widens this
  -- date deliberately (one-line view change).
WHERE f.dump_ticket_date >= DATE '2026-07-21'
  AND NOT EXISTS (
        SELECT 1 FROM public.derm_portal_submissions s
         WHERE s.manifest_id = f.manifest_id AND NOT s.dry_run
           AND s.status = 'SUCCESS')
  AND NOT EXISTS (
        SELECT 1 FROM public.derm_portal_submissions s
         WHERE s.manifest_id = f.manifest_id AND NOT s.dry_run
           AND s.attempted_at > now() - interval '20 hours')
  AND NOT EXISTS (
        SELECT 1 FROM public.derm_portal_submissions s
         WHERE s.manifest_id = f.manifest_id AND NOT s.dry_run
           AND NOT s.retryable AND s.status <> 'SUCCESS'
           AND s.attempted_at > f.updated_at);

CREATE OR REPLACE VIEW public.v_derm_portal_dryrun AS
SELECT f.*
FROM public.v_derm_portal_fields f
WHERE f.dump_ticket_date < (now() AT TIME ZONE 'America/New_York')::date - 30;

REVOKE ALL ON public.v_derm_portal_fields  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.v_derm_portal_queue   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.v_derm_portal_dryrun  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_derm_portal_fields, public.v_derm_portal_queue,
                public.v_derm_portal_dryrun TO service_role;

INSERT INTO storage.buckets (id, name, public)
VALUES ('rpa-evidence', 'rpa-evidence', false)
ON CONFLICT (id) DO NOTHING;

-- ============================================================================
-- VERIFICATION RECORD — 2026-07-21, T1-T10 ALL PASS (live deployed edge fns,
-- synthetic arena 112-YA ticket 999906; backup at
-- ..\backups\2026-07-21_rpa_backend_test_rows.json, then removed; teardown
-- via Storage API — direct storage.objects DELETE is blocked by
-- storage.protect_delete, noted for future teardowns)
-- ============================================================================
-- T1  wrong x-rpa-key -> 401 on both fns.
-- T2  live queue 200, respects cap; count=0 pre-launch (cutoff working).
-- T3  ?mode=dryrun serves 25 historical manifests, dry_run:true, docs come
--     back as /object/sign/ URLs and HEAD 200.
-- T4  synthetic fully-complete Dade manifest (dump=today) entered the live
--     queue with correct client/property/GDO joins. THE CUTOFF ITSELF WAS
--     FOUND BY THIS TEST's first run: without it the live queue was the
--     entire 534-manifest historical backlog — the bot's first run would
--     have re-submitted months of already-handled paper to the county.
-- T5  validation: lowercase status 400; unknown field 400; missing
--     screenshot+reason 400; unknown manifest 422.
-- T6  valid result 201; identical retry 200 {deduped:true}; screenshot in
--     rpa-evidence with public HEAD 400 (bucket private).
-- T7  fresh attempt removes the manifest (cooldown); attempt backdated 21h
--     -> retryable failure re-queues.
-- T8  non-retryable failure (attempt after manifest.updated_at) holds the
--     manifest out even with cooldown expired; touching the manifest
--     releases it. (Test isolation needed a brief single-transaction
--     trigger-disable to age updated_at — trigger-managed column.)
-- T9  SUCCESS removes permanently (still absent 25h later).
-- T10 dry_run:true result recorded + flagged, no effect on the live queue.
-- Teardown: 0 residue (submissions/manifests/evidence objects/blackout
-- targets all 0; live queue back to 0).

-- ============================================================================
-- ADDENDUM 2026-07-21 (post-review hardening; review findings 9, 12, 13)
-- ============================================================================
-- 9.  Dryrun upper bound: without it, from 2026-08-20 the rolling 30-day
--     window would start serving POST-launch never-submitted manifests as
--     "already handled" test data. Dryrun is now strictly pre-cutoff, which
--     also makes dry_run derivable server-side in rpa-derm-result.
CREATE OR REPLACE VIEW public.v_derm_portal_dryrun AS
SELECT f.*
FROM public.v_derm_portal_fields f
WHERE f.dump_ticket_date < DATE '2026-07-21';

REVOKE ALL ON public.v_derm_portal_dryrun FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_derm_portal_dryrun TO service_role;

-- 12. Bucket hardening: assert privacy even if the bucket pre-existed, and
--     add bucket-level size/MIME caps as defense-in-depth under the fn checks.
UPDATE storage.buckets
   SET public = false,
       file_size_limit = 5242880,
       allowed_mime_types = ARRAY['image/jpeg']
 WHERE id = 'rpa-evidence';

-- 13. AUDIT: opted IN after all (CLAUDE.md Rule 8 hard rule: no table touching
--     DERM compliance skips audit; opting in is simpler than a sign-off and
--     the write volume is trivial). Supersedes the opt-out in the header.
DROP TRIGGER IF EXISTS audit_derm_portal_submissions ON public.derm_portal_submissions;
CREATE TRIGGER audit_derm_portal_submissions
  AFTER INSERT OR UPDATE OR DELETE ON public.derm_portal_submissions
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- POST-REVIEW VERIFICATION (2026-07-21): a dedicated code-review agent audited
-- both edge fns + this migration; 4 HIGH + 6 MEDIUM + 3 LOW findings, ALL
-- fixed same cycle (pre-decode size guard, run_id charset, server-derived
-- dry_run cross-check, STORE_FAILED last-resort acceptance, SUCCESS-requires-
-- portal_confirmation, attempted_at clock-skew guard, deterministic
-- screenshot key + upsert, throw-safe URL parse/sign, dryrun upper bound,
-- bucket privacy assert + size/MIME caps, audit opt-IN). Full suite re-run
-- after the fixes: T1-T10 PASS including 4 new validation paths (T5e-h);
-- teardown clean (0 residue, live queue back to 0).
