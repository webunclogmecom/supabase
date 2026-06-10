-- ============================================================================
-- 2026-06-10b — Batch B1: status CHECKs, PK identity conversion, cleanup
-- ============================================================================
-- Second tranche of the 2026-06-10 DB protocol audit, gated on the Batch-B
-- pre-flight (workflow wf_6e9ebcbe-82c, 4 read-only investigators). Approved by
-- Fred 2026-06-10 (drop app_*; identity if scan clean; zone repoint+drop separately).
--
-- 1. CHECK constraints on the remaining status enums. The Jobber-sourced lists
--    are the LIVE-INTROSPECTED GraphQL enums (X-JOBBER-GRAPHQL-VERSION 2026-04-16
--    — natively lowercase, matching webhook-jobber's .toLowerCase()) PLUS the
--    local soft-delete values softStatusFlip writes ('closed'/'destroyed').
--    visits pin requires webhook-jobber 'canceled'->'cancelled' (fixed+deployed
--    this cycle; path never fired — 0 VISIT_DESTROY events ever) and populate.js
--    status normalization (fixed this cycle). All live data validates: every
--    live value set is a strict subset, 0 NULLs except where columns allow.
--    Drift caveat: if the Jobber GraphQL version header is ever bumped and a new
--    status appears, the webhook write fails LOUDLY into webhook_events_log.
-- 2. serial-style PKs -> GENERATED ALWAYS AS IDENTITY on the 18 remaining tables
--    (protocol form; 14 tables already identity — the pattern is proven in this
--    pipeline). Scan found no active explicit-id writer: populate.js, all Edge
--    Functions, all DB functions and crons insert without id; sandbox_refresh
--    loads via COPY (identity-exempt); Field Portal loaders already emit
--    OVERRIDING SYSTEM VALUE. The one stale Sandbox one-off
--    (backfill_sandbox_photos.js) is archived this cycle.
-- 3. Drop client_locations.contact_name/phone/email — dead repeating group
--    (0/407 populated, zero views/code/policies reference them; contacts live
--    in client_contacts).
-- 4. gdos client-consistency guard: gdos.client_id must match its
--    client_location's client_id (108/108 consistent today; the trigger prevents
--    drift until the 59 unlinked GDOs are backfilled and client_id is dropped).
-- 5. Drop the EMPTY legacy Prod mirrors app_visit_reviews/app_shift_reviews
--    (0 rows each; canonical = visit_reviews/shift_reviews since 2026-06-08,
--    live-verified twice; the actual rollback data lives in SANDBOX's app_*
--    tables, untouched). DDL preserved in schema/v2_schema.sql git history
--    (2026-06-09 snapshot, lines ~3394-3432).
-- ============================================================================

-- 1) Status CHECK constraints ------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'jobs_job_status_chk') THEN
    ALTER TABLE public.jobs ADD CONSTRAINT jobs_job_status_chk
      CHECK (job_status = ANY (ARRAY[
        'requires_invoicing','archived','late','today','upcoming','action_required',
        'on_hold','unscheduled','active','expiring_within_30_days',  -- JobStatusTypeEnum (live introspection 2026-06-10)
        'closed','destroyed']));                                     -- local softStatusFlip values
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'invoices_invoice_status_chk') THEN
    ALTER TABLE public.invoices ADD CONSTRAINT invoices_invoice_status_chk
      CHECK (invoice_status = ANY (ARRAY[
        'draft','awaiting_payment','paid','past_due','bad_debt','sent_not_due',  -- InvoiceStatusTypeEnum
        'destroyed']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'quotes_quote_status_chk') THEN
    ALTER TABLE public.quotes ADD CONSTRAINT quotes_quote_status_chk
      CHECK (quote_status = ANY (ARRAY[
        'draft','awaiting_response','archived','approved','converted','changes_requested',  -- QuoteStatusTypeEnum
        'destroyed']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'clients_status_chk') THEN
    ALTER TABLE public.clients ADD CONSTRAINT clients_status_chk
      CHECK (status = ANY (ARRAY['ACTIVE','RECURRING','PAUSED','INACTIVE']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'visits_visit_status_chk') THEN
    ALTER TABLE public.visits ADD CONSTRAINT visits_visit_status_chk
      CHECK (visit_status = ANY (ARRAY['scheduled','completed','cancelled']));
  END IF;
END $$;

-- 2) serial-style PK -> GENERATED ALWAYS AS IDENTITY (18 tables) --------------
DO $$
DECLARE
  t text;
  seqname text;
  nextid bigint;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'clients','derm_manifests','employees','gdos','inspections','invoices',
    'jobber_oversized_attachments','jobs','line_items','notes','photo_links',
    'photos','properties','quotes','service_configs','sync_log','vehicles','visits']
  LOOP
    -- idempotent: skip tables already converted
    IF EXISTS (
      SELECT 1 FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = t
        AND a.attname = 'id' AND a.attidentity = '' AND a.atthasdef
    ) THEN
      seqname := pg_get_serial_sequence('public.' || quote_ident(t), 'id');
      EXECUTE format('SELECT COALESCE(max(id), 0) + 1 FROM public.%I', t) INTO nextid;
      EXECUTE format('ALTER TABLE public.%I ALTER COLUMN id DROP DEFAULT', t);
      IF seqname IS NOT NULL THEN
        EXECUTE format('DROP SEQUENCE IF EXISTS %s', seqname);
      END IF;
      EXECUTE format(
        'ALTER TABLE public.%I ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (START WITH %s)',
        t, nextid);
      RAISE NOTICE 'identity: % (start %)', t, nextid;
    END IF;
  END LOOP;
END $$;

-- 3) Dead contact repeating-group on client_locations -------------------------
ALTER TABLE public.client_locations
  DROP COLUMN IF EXISTS contact_name,
  DROP COLUMN IF EXISTS contact_phone,
  DROP COLUMN IF EXISTS contact_email;

-- 4) gdos client/location consistency guard -----------------------------------
CREATE OR REPLACE FUNCTION public.fn_gdos_client_consistency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $fn$
BEGIN
  IF NEW.client_location_id IS NOT NULL THEN
    IF NEW.client_id IS DISTINCT FROM
       (SELECT cl.client_id FROM public.client_locations cl WHERE cl.id = NEW.client_location_id) THEN
      RAISE EXCEPTION 'gdos.client_id (%) does not match client_locations.client_id for location % — keep them consistent until gdos.client_id is dropped',
        NEW.client_id, NEW.client_location_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS gdos_client_consistency_trg ON public.gdos;
CREATE TRIGGER gdos_client_consistency_trg
  BEFORE INSERT OR UPDATE OF client_id, client_location_id ON public.gdos
  FOR EACH ROW EXECUTE FUNCTION public.fn_gdos_client_consistency();

-- 5) Repoint inspections_with_review off the legacy table, then drop ----------
-- LATENT BUG FIX: the 2026-06-08 cutover repointed visits_with_review to canonical
-- but MISSED this view — it still read app_shift_reviews, which is EMPTY on Prod,
-- so shift_review_status always showed 'pending' here even after a review was
-- saved to canonical shift_reviews. Identical columns; external_employee_id -> employee_id.
CREATE OR REPLACE VIEW public.inspections_with_review
WITH (security_invoker = true) AS
 SELECT i.id,
    i.vehicle_id,
    i.employee_id,
    i.shift_date,
    i.inspection_type,
    i.submitted_at,
    i.sludge_gallons,
    i.water_gallons,
    i.gas_level,
    i.is_valve_closed,
    i.has_issue,
    i.issue_note,
    i.created_at,
    i.updated_at,
    COALESCE(asr.review_status, 'pending'::text) AS shift_review_status,
    asr.reviewed_at AS shift_reviewed_at,
    asr.reviewed_by AS shift_reviewed_by,
    COALESCE(asr.bonus_status, 'pending'::text) AS shift_bonus_status,
    asr.bonus_decided_at AS shift_bonus_decided_at,
    asr.bonus_decided_by AS shift_bonus_decided_by,
    asr.bonus_denial_note AS shift_bonus_denial_note,
    asr.shift_quality_note
   FROM inspections i
     LEFT JOIN shift_reviews asr
       ON asr.employee_id = i.employee_id AND asr.shift_date = i.shift_date;

-- Drop empty legacy Prod mirrors (rollback data lives in SANDBOX app_*)
DROP TABLE IF EXISTS public.app_visit_reviews;
DROP TABLE IF EXISTS public.app_shift_reviews;
