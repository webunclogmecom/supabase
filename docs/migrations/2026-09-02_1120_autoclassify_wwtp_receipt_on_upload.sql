-- 2026-09-02_1120_autoclassify_wwtp_receipt_on_upload.sql
--
-- WHY
-- The Field Portal "Disposal Receipt" (customer.work_orders.wwtp_receipt_url) is gated on
--   CASE WHEN derm.receipt_doc_class.class = 'receipt' THEN dm.derm_manifest_url ELSE NULL END
-- receipt_doc_class was only ever written by hand-authored migrations (last 2026-08-26_1710), and
-- nothing ran that pass on a schedule. So every newly-uploaded receipt stayed unclassified and the
-- Field Portal rendered nothing under "Disposal Receipt". The 315-cap visit vSAfOz48KN (manifest
-- 1773, url .../derm/1771/manifest_1.jpg) is the reported symptom; the silent backlog on 2026-09-02
-- was 5 distinct URLs / 16 manifests / 16 clients (2026-08-27 -> 2026-09-01, growing).
--
-- DECISION (Fred, 2026-09-02): Option A1 - "we trust at the moment of upload", KEEPING THE LEVER.
--   * A receipt uploaded via the DERM Tracker (a write to derm_manifests.derm_manifest_url) is
--     auto-classified 'receipt' the instant it is written, so the Field Portal shows it immediately.
--   * The gate is NOT removed. customer.work_orders is unchanged. receipt_doc_class stays the
--     override lever: if a bad document (a multi-client roster, or the wrong file) ever lands in the
--     receipt slot, a human FLIPS or DELETES that one row and the receipt hides again. ON CONFLICT
--     DO NOTHING means the trigger never clobbers a human decision already recorded for that URL.
--   * Observed risk this is trading against: the 2026-07-10 vision pass read 97/97 receipt-slot
--     images as clean receipts (0 rosters, 0 wrong docs). The slot has never once held a non-receipt.
--
-- WHAT THIS DOES
--   1. derm.fn_autoclassify_receipt_on_upload() - SECURITY DEFINER trigger fn. Upserts a
--      receipt_doc_class row (class='receipt') for NEW.derm_manifest_url, ON CONFLICT (url) DO NOTHING.
--   2. trg_zc_autoclassify_receipt on public.derm_manifests - AFTER INSERT OR UPDATE OF
--      derm_manifest_url, WHEN NEW.derm_manifest_url IS NOT NULL.
--   3. One-time backfill of every already-uploaded-but-unclassified derm_manifest_url (the 5 URLs).
--
-- WHY SECURITY DEFINER (load-bearing, not preference)
--   The DERM Tracker writes derm_manifests as `anon` (MVP auth), and anon/authenticated have NO grant
--   on derm.receipt_doc_class (deliberately - see 2026-07-10_wwtp_receipt_class_gate.sql). A plain
--   (invoker-rights) AFTER trigger would raise "permission denied for table receipt_doc_class" and
--   ABORT the upload. SECURITY DEFINER (owner = postgres, which holds the grant) lets the trusted
--   trigger write the classification on the app's behalf WITHOUT granting any app direct write access.
--   search_path is pinned to '' and every object is schema-qualified.
--
-- 3NF: no schema shape change. receipt_doc_class stays (url PK) -> (class, note, classified_at); the
--   trigger only automates a write that was previously manual. No new columns, no denormalization.
--
-- AUDIT: receipt_doc_class is deliberately NOT audited (a system-maintained classification lookup,
--   append-mostly, and every write it receives mirrors a derm_manifests upload that IS audited by
--   audit_derm_manifests). The new trigger writes ONLY receipt_doc_class, so it adds no audit rows and
--   cannot recurse into derm_manifests.
--
-- VERIFICATION (run after apply; see 2026-09-02_1120_verify.js):
--   * backfill inserts exactly 5 rows; receipt_doc_class 129 -> 134, all class='receipt';
--     0 unclassified live receipt URLs remain (was 5 - positive control for the absence assertion).
--   * customer.work_orders WHERE id='vSAfOz48KN' -> wwtp_receipt_url = .../derm/1771/manifest_1.jpg
--     (was NULL).
--   * Trigger-creates + anon-can-still-write proof (self-healing, on the 1-row manifest 1768):
--     delete its classification (as postgres), no-op UPDATE derm_manifest_url AS ROLE anon, confirm
--     the row was re-created by the trigger -> proves the SECURITY DEFINER path works for an anon
--     invoker AND that anon writes to derm_manifests still succeed with the trigger present.

CREATE OR REPLACE FUNCTION derm.fn_autoclassify_receipt_on_upload()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO derm.receipt_doc_class (url, class, note, classified_at)
  VALUES (NEW.derm_manifest_url, 'receipt', 'auto: trusted at upload (A1)', now())
  ON CONFLICT (url) DO NOTHING;
  RETURN NULL;  -- AFTER trigger; return value ignored
END;
$$;

DROP TRIGGER IF EXISTS trg_zc_autoclassify_receipt ON public.derm_manifests;
CREATE TRIGGER trg_zc_autoclassify_receipt
  AFTER INSERT OR UPDATE OF derm_manifest_url ON public.derm_manifests
  FOR EACH ROW
  WHEN (NEW.derm_manifest_url IS NOT NULL)
  EXECUTE FUNCTION derm.fn_autoclassify_receipt_on_upload();

-- One-time backfill: trust every receipt already uploaded but never classified.
INSERT INTO derm.receipt_doc_class (url, class, note, classified_at)
SELECT DISTINCT dm.derm_manifest_url, 'receipt', 'backfill: trusted at upload (A1) 2026-09-02', now()
FROM public.derm_manifests dm
LEFT JOIN derm.receipt_doc_class rc ON rc.url = dm.derm_manifest_url
WHERE dm.derm_manifest_url IS NOT NULL
  AND rc.url IS NULL
  AND dm.deleted_at IS NULL
ON CONFLICT (url) DO NOTHING;
