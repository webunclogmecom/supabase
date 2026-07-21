-- ============================================================================
-- 2026-07-21g — RPA bot RE-SCOPED to GDO Online Reporting (Line Item 27)
-- ============================================================================
-- WHY (Fred + Yannick, 2026-07-21): the RPA bot is NOT "file every Miami-Dade
-- manifest". It does GDO ONLINE REPORTING — Line Item 27 "GDO Online Reporting"
-- — a paid add-on that only 3 clients carry today (041-MB, 082-TFC, 111-YC).
-- The 21e/21f backend (queue + result endpoints, idempotency, dispense lease,
-- private evidence bucket, watchdog, DB backstops) is REUSED wholesale; this
-- migration only re-points the WORK UNIT and adds the app-facing status
-- surfaces + the trigger.
--
-- CONFIRMED DESIGN (Fred, 2026-07-21):
--  * Work unit = a code-27 VISIT that has been linked to a manifest and not yet
--    successfully reported. The report is per SERVICE VISIT; the linked
--    manifest is the supporting DERM evidence (docs).
--  * 48h window = TRIGGER FRESHNESS ONLY: a new manifest link fires an
--    immediate push to the bot, but eligibility PERSISTS until the report
--    succeeds (bot down / portal outage never drops a compliance report).
--  * Trigger = event-push (AFTER INSERT on manifest_visits, when the visit is
--    code-27, POST the bot's /run) PLUS the existing poll (bot GETs the queue).
--  * Bot payload = client + service info PLUS the manifest documents (signed).
--  * Status surfaces per-visit in DERM Tracker (derm.gdo_report_status) and on
--    the Field Portal (customer.gdo_reports).
--
-- WORK-KEY CHANGE: derm_portal_submissions + leases + the two edge fns move
-- from manifest_id to VISIT_ID as the primary key of a unit of work
-- (manifest_id stays as evidence context, now nullable). The tables are
-- dormant/test-only (verified 0 live rows) so this is a clean restructure.
--
-- 3NF: the code-27 flag is DERIVED (fn over line_items by name, mirroring
-- fn_line_item_requires_derm / ADR 018), never stored. AUDIT: submissions stay
-- audited; leases opted-out (ephemeral). Grants: derm.* app views ->
-- anon+authenticated (DERM Tracker signs in); customer.* -> anon (FP read-only
-- customer schema), both client-checked at the app layer as today.
-- VERIFICATION appended after deploy.
-- ============================================================================

-- ─── 1. Code-27 classifier (mirrors fn_line_item_requires_derm branch (a)) ───
CREATE OR REPLACE FUNCTION public.fn_line_item_is_gdo_reporting(p_name text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_name IS NULL OR btrim(p_name) = '' THEN false
    -- taxonomy-formatted "27 - ..." is authoritative
    WHEN btrim(p_name) ~* '^0*27\s*-\s' THEN true
    -- free-text variants seen on live jobs: "GDO Report", "GDO Report (Online)",
    -- "GDO Online Reporting"
    WHEN btrim(p_name) ~* 'gdo[^,]*report|report[^,]*gdo' THEN true
    ELSE false
  END
$$;

-- A visit carries GDO Online Reporting iff any of its line items (visit-,
-- invoice-, or job-scoped, same 3-way join as fn_visit_requires_derm) match.
CREATE OR REPLACE FUNCTION public.fn_visit_is_gdo_reporting(p_visit_id bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.visits v
    JOIN public.line_items li
      ON li.name IS NOT NULL
     AND ( li.visit_id = v.id
        OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id)
        OR (v.job_id     IS NOT NULL AND li.job_id     = v.job_id) )
    WHERE v.id = p_visit_id
      AND public.fn_line_item_is_gdo_reporting(li.name)
  )
$$;

-- ─── 2. Re-key submissions + leases to VISIT_ID ─────────────────────────────
-- Dormant/test-only tables (0 live rows) -> clean restructure.
ALTER TABLE public.derm_portal_submissions ADD COLUMN IF NOT EXISTS visit_id bigint REFERENCES public.visits(id);
ALTER TABLE public.derm_portal_submissions ALTER COLUMN manifest_id DROP NOT NULL;
-- swap idempotency key manifest_id -> visit_id
ALTER TABLE public.derm_portal_submissions DROP CONSTRAINT IF EXISTS derm_portal_submissions_attempt_uniq;
DELETE FROM public.derm_portal_submissions WHERE visit_id IS NULL;  -- no live rows; belt-and-suspenders
ALTER TABLE public.derm_portal_submissions ALTER COLUMN visit_id SET NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='derm_portal_submissions_visit_attempt_uniq') THEN
    ALTER TABLE public.derm_portal_submissions
      ADD CONSTRAINT derm_portal_submissions_visit_attempt_uniq UNIQUE (visit_id, run_id);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS derm_portal_submissions_visit_idx
  ON public.derm_portal_submissions (visit_id, dry_run, created_at DESC);

-- leases re-keyed to visit_id. Drop the dependent views first (recreated in §3-5).
DROP VIEW IF EXISTS public.v_rpa_derm_health;
DROP VIEW IF EXISTS public.v_derm_portal_queue;
DROP VIEW IF EXISTS public.v_derm_portal_dryrun;
DROP VIEW IF EXISTS public.v_derm_portal_fields;
DROP TABLE IF EXISTS public.derm_portal_leases;
CREATE TABLE public.derm_portal_leases (
  visit_id  bigint PRIMARY KEY REFERENCES public.visits(id),
  leased_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.derm_portal_leases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.derm_portal_leases FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.derm_portal_leases TO service_role;

-- dry_run guard now classifies by the VISIT's service date (visit_date), not
-- the manifest dump date.
CREATE OR REPLACE FUNCTION public.trg_rpa_submission_dry_run_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public' AS $$
DECLARE v_vdate date;
BEGIN
  SELECT visit_date INTO v_vdate FROM public.visits WHERE id = NEW.visit_id;
  IF v_vdate IS NOT NULL AND NEW.dry_run <> (v_vdate < public.rpa_launch_cutoff()) THEN
    RAISE EXCEPTION 'dry_run=% disagrees with visit % service-date classification (visit_date %)',
      NEW.dry_run, NEW.visit_id, v_vdate;
  END IF;
  RETURN NEW;
END $$;

-- ─── 3. Base field set: one row per code-27 visit with a live manifest link ──
DROP VIEW IF EXISTS public.v_rpa_derm_health;
DROP VIEW IF EXISTS public.v_derm_portal_queue;
DROP VIEW IF EXISTS public.v_derm_portal_dryrun;
DROP VIEW IF EXISTS public.v_derm_portal_fields;

CREATE VIEW public.v_derm_portal_fields AS
SELECT
  v.id                        AS visit_id,
  v.visit_date,
  v.client_id,
  c.client_code,
  c.name                      AS client_name,
  ce.email                    AS client_email,
  pp.address, pp.city, pp.zip, pp.county,
  gd.gdo_number,
  m.id                        AS manifest_id,
  m.white_manifest_number,
  m.dump_ticket_date,
  df.name                     AS disposal_facility,
  m.derm_address_url, m.derm_address_extra_urls,
  m.derm_manifest_url, m.derm_manifest_extra_urls,
  GREATEST(v.updated_at, mv_link.linked_at) AS updated_at,
  mv_link.linked_at
FROM public.visits v
JOIN public.clients c ON c.id = v.client_id
-- the visit's most-recent LIVE manifest link (one white# per visit by guard)
JOIN LATERAL (
  SELECT mv.manifest_id, GREATEST(m2.updated_at, m2.created_at) AS linked_at
  FROM public.manifest_visits mv
  JOIN public.derm_manifests m2 ON m2.id = mv.manifest_id AND m2.deleted_at IS NULL
  WHERE mv.visit_id = v.id
  ORDER BY m2.created_at DESC
  LIMIT 1) mv_link ON true
JOIN public.derm_manifests m ON m.id = mv_link.manifest_id
LEFT JOIN LATERAL (
  SELECT cc.email FROM public.client_contacts cc
   WHERE cc.client_id = c.id AND cc.email IS NOT NULL AND cc.email <> ''
   ORDER BY cc.id LIMIT 1) ce ON true
LEFT JOIN LATERAL (
  SELECT p.address, p.city, p.zip, p.county FROM public.properties p
   WHERE p.client_id = c.id AND p.is_primary ORDER BY p.id LIMIT 1) pp ON true
LEFT JOIN LATERAL (
  SELECT g.gdo_number FROM public.gdos g
   WHERE g.client_id = c.id AND g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$'
   ORDER BY g.id LIMIT 1) gd ON true
LEFT JOIN public.disposal_facilities df ON df.id = m.disposal_facility_id
WHERE v.deleted_at IS NULL
  AND public.fn_visit_is_gdo_reporting(v.id);

-- ─── 4. Live queue: eligibility persists until reported (no 48h cutoff) ──────
CREATE VIEW public.v_derm_portal_queue AS
SELECT f.*
FROM public.v_derm_portal_fields f
WHERE f.visit_date >= public.rpa_launch_cutoff()
  AND NOT EXISTS (  -- permanent exit: county-confirmed
        SELECT 1 FROM public.derm_portal_submissions s
         WHERE s.visit_id = f.visit_id AND NOT s.dry_run
           AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL))
  AND NOT EXISTS (  -- 20h cooldown, server clock
        SELECT 1 FROM public.derm_portal_submissions s
         WHERE s.visit_id = f.visit_id AND NOT s.dry_run
           AND s.created_at > now() - interval '20 hours')
  AND NOT EXISTS (  -- non-retryable data error holds until the visit/link changes
        SELECT 1 FROM public.derm_portal_submissions s
         WHERE s.visit_id = f.visit_id AND NOT s.dry_run
           AND NOT s.retryable AND s.status <> 'SUCCESS'
           AND s.created_at > f.updated_at)
  AND NOT EXISTS (  -- dispense lease
        SELECT 1 FROM public.derm_portal_leases l
         WHERE l.visit_id = f.visit_id AND l.leased_at > now() - interval '20 hours');

CREATE VIEW public.v_derm_portal_dryrun AS
SELECT f.* FROM public.v_derm_portal_fields f
WHERE f.visit_date < public.rpa_launch_cutoff();

REVOKE ALL ON public.v_derm_portal_fields, public.v_derm_portal_queue, public.v_derm_portal_dryrun
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_derm_portal_fields, public.v_derm_portal_queue, public.v_derm_portal_dryrun
  TO service_role;

-- ─── 5. Watchdog re-pointed to code-27 visits ───────────────────────────────
CREATE VIEW public.v_rpa_derm_health AS
SELECT
  (SELECT count(*) FROM public.v_derm_portal_queue)                              AS queue_depth,
  (SELECT max(created_at) FROM public.derm_portal_submissions WHERE NOT dry_run) AS last_real_attempt,
  (SELECT count(*) FROM public.derm_portal_submissions
     WHERE NOT dry_run AND status='SUCCESS' AND created_at > now() - interval '24 hours') AS success_24h,
  (SELECT count(*) FROM public.derm_portal_submissions
     WHERE NOT dry_run AND screenshot_missing_reason='STORE_FAILED')            AS store_failed_total,
  (SELECT count(*) FROM (SELECT visit_id FROM public.derm_portal_submissions
     WHERE NOT dry_run GROUP BY visit_id HAVING count(*) >= 3) q)               AS visits_ge3_attempts;
REVOKE ALL ON public.v_rpa_derm_health FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_rpa_derm_health TO service_role;

CREATE OR REPLACE FUNCTION public.log_rpa_derm_health()
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE h record; reasons jsonb := '[]'::jsonb; attn boolean := false;
BEGIN
  SELECT * INTO h FROM public.v_rpa_derm_health;
  IF h.queue_depth > 0 AND (h.last_real_attempt IS NULL OR h.last_real_attempt < now() - interval '26 hours') THEN
    attn := true; reasons := reasons || jsonb_build_object('kind','no_recent_attempts','queue_depth',h.queue_depth,'last_real_attempt',h.last_real_attempt);
  END IF;
  IF h.store_failed_total > 0 THEN attn := true; reasons := reasons || jsonb_build_object('kind','evidence_lost_store_failed','count',h.store_failed_total); END IF;
  IF h.visits_ge3_attempts > 0 THEN attn := true; reasons := reasons || jsonb_build_object('kind','retry_loop_visits','count',h.visits_ge3_attempts); END IF;
  INSERT INTO public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  VALUES ('rpa-derm-health', now(), now(), COALESCE(h.queue_depth,0),
          CASE WHEN attn THEN 'attention' ELSE 'ok' END,
          jsonb_build_object('queue_depth',h.queue_depth,'last_real_attempt',h.last_real_attempt,
                             'success_24h',h.success_24h,'store_failed_total',h.store_failed_total,
                             'visits_ge3_attempts',h.visits_ge3_attempts,'reasons',reasons));
  RETURN CASE WHEN attn THEN 1 ELSE 0 END;
END $$;

-- ─── 6. App-facing status surfaces ──────────────────────────────────────────
-- DERM Tracker (authenticated): per code-27 visit, the report state.
CREATE OR REPLACE VIEW derm.gdo_report_status AS
SELECT
  v.id                         AS visit_id,
  v.client_id,
  c.client_code,
  c.name                       AS client_name,
  v.visit_date,
  last.manifest_id,
  last.status,
  last.portal_confirmation,
  last.failure_reason,
  last.last_attempt_at,
  CASE
    WHEN last.status = 'SUCCESS' OR last.portal_confirmation IS NOT NULL THEN 'reported'
    WHEN last.status IS NULL THEN 'pending'
    WHEN NOT last.retryable THEN 'failed'
    ELSE 'pending'
  END                          AS report_state
FROM public.visits v
JOIN public.clients c ON c.id = v.client_id
LEFT JOIN LATERAL (
  SELECT s.manifest_id, s.status, s.portal_confirmation, s.failure_reason,
         s.retryable, s.created_at AS last_attempt_at
  FROM public.derm_portal_submissions s
  WHERE s.visit_id = v.id AND NOT s.dry_run
  ORDER BY (s.status='SUCCESS' OR s.portal_confirmation IS NOT NULL) DESC, s.created_at DESC
  LIMIT 1) last ON true
WHERE v.deleted_at IS NULL
  AND public.fn_visit_is_gdo_reporting(v.id);
GRANT SELECT ON derm.gdo_report_status TO anon, authenticated;

-- Field Portal (customer-facing, anon read-only, client-checked at the app):
-- surface only the positive "filed" fact + date; no internal failure detail.
CREATE OR REPLACE VIEW customer.gdo_reports AS
SELECT
  v.id            AS visit_id,
  v.client_id,
  v.visit_date,
  (s.visit_id IS NOT NULL) AS reported,
  s.created_at    AS reported_at,
  s.portal_confirmation AS confirmation
FROM public.visits v
LEFT JOIN LATERAL (
  SELECT s.visit_id, s.created_at, s.portal_confirmation
  FROM public.derm_portal_submissions s
  WHERE s.visit_id = v.id AND NOT s.dry_run
    AND (s.status='SUCCESS' OR s.portal_confirmation IS NOT NULL)
  ORDER BY s.created_at DESC LIMIT 1) s ON true
WHERE v.deleted_at IS NULL
  AND public.fn_visit_is_gdo_reporting(v.id);
GRANT SELECT ON customer.gdo_reports TO anon, authenticated;

-- ─── 7. Event-push trigger (DORMANT until John's /run URL is configured) ─────
-- When a code-27 visit is linked to a manifest, ping the bot's /run so it
-- reports promptly (the poll is the backup). Reads the endpoint+key from
-- public.app_config; NO-OPs while unset, so this ships safe/dark today and is
-- flipped on by inserting the config once John's endpoint is live.
CREATE TABLE IF NOT EXISTS public.app_config (
  key text PRIMARY KEY,
  value text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON public.app_config FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.app_config TO service_role;

CREATE OR REPLACE FUNCTION public.trg_gdo_reporting_notify_bot()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_url text; v_key text;
BEGIN
  IF NOT public.fn_visit_is_gdo_reporting(NEW.visit_id) THEN RETURN NULL; END IF;
  SELECT value INTO v_url FROM public.app_config WHERE key = 'rpa_run_url';
  SELECT value INTO v_key FROM public.app_config WHERE key = 'rpa_run_key';
  IF v_url IS NULL OR v_key IS NULL THEN RETURN NULL; END IF;  -- dormant until wired
  PERFORM net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type','application/json','x-run-key', v_key),
    body    := jsonb_build_object('reason','gdo_reporting_link','visit_id', NEW.visit_id));
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_zz_gdo_reporting_notify ON public.manifest_visits;
CREATE TRIGGER trg_zz_gdo_reporting_notify
  AFTER INSERT ON public.manifest_visits
  FOR EACH ROW EXECUTE FUNCTION public.trg_gdo_reporting_notify_bot();

-- ============================================================================
-- VERIFICATION RECORD — 2026-07-21, T0-T11 ALL PASS
-- (29 REAL historical code-27 visits used for read paths; 1 synthetic LIVE
-- 112-YA visit dated 2027-01-01 with visits+manifest_visits triggers
-- suppressed for the write/lease paths; backup
-- ..\backups\2026-07-21_gdo_reporting_test_rows.json; cleaned via exact-id +
-- 2027-01-01 proof, real dryrun set intact at 29, all triggers re-enabled)
-- ============================================================================
-- T0  classifier: "27 - ..." true, pumping false, "GDO Report" true.
-- T1  auth 401 on both fns.
-- T2  dryrun serves the 29 REAL code-27 visits (capped 25/batch), keyed by
--     visit_id, with signed doc URLs — the views populate from real data.
-- T3  synthetic live code-27 visit enters the live queue (client 112-YA, its
--     linked manifest as context) + gets leased.
-- T4  dispense lease (now visit-keyed) holds a served visit 20h; re-queues after.
-- T5  result endpoint keyed on VISIT_ID: unknown field 400, unknown visit 422,
--     record 201, dedupe 200, manifest_id kept as context, private bucket.
-- T6  derm.gdo_report_status: pending (retryable error) -> reported (SUCCESS
--     with confirmation) — the DERM Tracker surface.
-- T7  customer.gdo_reports: reported=true + confirmation after success — the
--     Field Portal surface.
-- T8  a reported visit permanently leaves the queue.
-- T9  DB backstops on visit_id rows: SUCCESS-needs-confirmation + dry_run
--     (derived from visit_date) correctness both reject bad direct writes.
-- T10 event-push trigger DORMANT (no app_config rpa_run_url/key) — the earlier
--     manifest_visits link insert fired it with no error and no HTTP.
-- T11 watchdog log_rpa_derm_health() writes sync_log (status 'ok' dormant).
-- NOTE: synthetic visits inherit source DEFAULT 'visit-calendar'; the teardown
-- safety guard correctly refused to delete on source alone — cleanup keyed on
-- the exact id + the unique 2027-01-01 service date instead.
-- ============================================================================
