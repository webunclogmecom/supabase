-- 2026-07-10_fp_blackout_redaction.sql   ⚠ REQUIRES 2026-07-10_stamp_row_bands_stamp_page.sql FIRST
-- FP BLACKOUT (Fred-approved design): customer-safe REDACTED copies of shared DERM address sheets,
-- driven by Stamp Studio bands; delivered to FP via customer.work_orders.derm_manifest_url (which
-- previously carried 531 BLANK pypdf FOG-eManifest template PDFs — dead artifact, card parked at
-- "Coming soon"). Image work: edge fn supabase/functions/redact-manifest-sheet.
--
-- SAFETY MODEL (rev 2 — 3-lens adversarial review wf_511c398b; NO_GO findings folded in):
--  • WHITELIST: visible = form header [0, min band y0 on the page, capped 30%] + the client's own
--    band; ALL else solid black. Server-side derivative (manifests bucket is public; CSS = fake).
--  • TARGETS ONLY FROM FULLY-BANDED SHEETS — every address_row_map row of the sheet (matched or not)
--    must have a band. Blocker fix: midpoint bands on partial sheets swallow unstamped neighbor rows,
--    and unmatched OCR rows above min-band-y0 would ride the "header". ~373 of 507 pairs ship now;
--    the rest unlock as Stamp Studio finishes those sheets (the sweep picks them up automatically).
--  • ORDER-CONSISTENCY GATE: an OCR card whose stamp rank (by y) contradicts its OCR row rank on the
--    same page is excluded (possible stamp-on-wrong-row) and left for a Stamp Studio audit.
--  • PAGE-IDENTITY GUARD: the image at pages[effective_page] must content-match the OCR page image
--    when OCR rows exist for that page (ticket_page_images can gate stale pages OUT and shift
--    indexes; never redact the wrong image).
--  • Staleness FINGERPRINT md5(source-etag|y0|y1|header): band edits / re-uploads regenerate; the
--    edge fn DELETES the superseded public object (no stale wider-band copies linger).
--  • Retry ledger derm.redacted_manifest_errors: poison targets back off exponentially (≤48h) so the
--    queue always drains. Heartbeat derm.blackout_sweep_log: one row per run (observability).
--  • ADR-010: redacted_manifest_docs / _errors / sweep_log are audit OPT-OUT — machine-generated,
--    regenerable derivative cache + ops logs, no human edits; sources (manifests, bands) are audited.
--    Opt-out presented to Fred in the 2026-07-10 ship report (per the DERM-adjacent sign-off rule).
--  • customer.work_orders rd JOIN carries AND rd.client_id = v.client_id (cross-client belt).
--  ⚠ FLAGGED TO FRED, NOT CHANGED HERE: (a) customer.* is anon-enumerable by design (FP model) — this
--    adds redacted-doc URLs to that surface (strictly milder than the raw white-form photos already
--    on it); RPC-gating the customer schema is the proper close, Fred to decide. (b) wwtp_receipt_url
--    still maps the UNREDACTED white-form photo (section B can name co-clients) — pre-existing,
--    needs its own redaction pass or a repoint to wwtp_receipt_document_path; Fred to steer.

BEGIN;

-- 1) ledger + retry + heartbeat ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS derm.redacted_manifest_docs (
  manifest_id    bigint PRIMARY KEY REFERENCES public.derm_manifests(id) ON DELETE CASCADE,
  client_id      bigint NOT NULL,
  url            text   NOT NULL,
  fingerprint    text   NOT NULL,
  band_y0        numeric NOT NULL,
  band_y1        numeric NOT NULL,
  header_y       numeric,
  effective_page int    NOT NULL,
  source_url     text   NOT NULL,
  generated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS derm.redacted_manifest_errors (
  manifest_id   bigint PRIMARY KEY,
  attempts      int NOT NULL DEFAULT 1,
  last_error    text,
  next_retry_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS derm.blackout_sweep_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ran_at timestamptz NOT NULL DEFAULT now(),
  processed int NOT NULL, generated int NOT NULL, error_count int NOT NULL, errors jsonb
);
ALTER TABLE derm.redacted_manifest_docs   ENABLE ROW LEVEL SECURITY;
ALTER TABLE derm.redacted_manifest_errors ENABLE ROW LEVEL SECURITY;
ALTER TABLE derm.blackout_sweep_log       ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON derm.redacted_manifest_docs, derm.redacted_manifest_errors, derm.blackout_sweep_log
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON derm.redacted_manifest_docs, derm.redacted_manifest_errors,
  derm.blackout_sweep_log TO service_role;

-- 2) targets RPC (service_role-only) ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_blackout_targets(p_limit int DEFAULT 3)
RETURNS TABLE (manifest_id bigint, client_id bigint, ticket_key text, source_url text,
               effective_page int, band_y0 numeric, band_y1 numeric, header_y numeric,
               fingerprint text, old_url text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $fn$
  WITH cards AS (
    SELECT r.id AS card_id, r.dump_folder, r.page AS ocr_page, r.row_index, r.source,
           r.stamp_placed_at, r.matched_manifest_id AS mid, r.matched_client_id AS cid,
           r.white_manifest_number AS tkey, b.band_y0_pct, b.band_y1_pct, b.effective_page
    FROM derm.address_row_map r
    JOIN derm.v_stamp_row_bands b ON b.id = r.id
    WHERE r.matched_manifest_id IS NOT NULL AND r.matched_client_id IS NOT NULL
      AND r.stamp_placed_at IS NOT NULL
      -- FULLY-BANDED SHEET GATE (blocker fix): every row of the sheet, matched or not, has a band
      AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r2
                      LEFT JOIN derm.v_stamp_row_bands b2 ON b2.id = r2.id
                      WHERE r2.dump_folder = r.dump_folder AND b2.id IS NULL)
      -- ORDER-CONSISTENCY GATE: OCR cards stamped on their own OCR page must keep OCR row order
      AND NOT EXISTS (
        SELECT 1 FROM (
          SELECT c2.id,
                 rank() OVER (PARTITION BY c2.dump_folder, c2.page ORDER BY c2.stamp_y_pct)  AS yr,
                 rank() OVER (PARTITION BY c2.dump_folder, c2.page ORDER BY c2.row_index)    AS rr
          FROM derm.address_row_map c2
          WHERE c2.dump_folder = r.dump_folder AND c2.source = 'claude-vision-v1'
            AND c2.stamp_y_pct IS NOT NULL AND c2.stamp_page = c2.page AND c2.page = r.page
        ) o WHERE o.id = r.id AND o.yr <> o.rr)
  ), best AS (          -- one card per manifest (latest placement wins)
    SELECT DISTINCT ON (mid) * FROM cards
    ORDER BY mid, stamp_placed_at DESC NULLS LAST, card_id DESC
  ), live AS (          -- manifest live, same client, customer-visible (linked to a live visit)
    SELECT b.* FROM best b
    JOIN public.derm_manifests dm ON dm.id = b.mid AND dm.deleted_at IS NULL AND dm.client_id = b.cid
    WHERE EXISTS (SELECT 1 FROM public.manifest_visits mv
                  JOIN public.visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL
                  WHERE mv.manifest_id = b.mid)
  ), geo AS (
    SELECT l.mid, l.cid, l.tkey, l.dump_folder,
           (derm.ticket_page_images(l.tkey))[l.effective_page] AS src,
           l.effective_page, l.band_y0_pct AS y0, l.band_y1_pct AS y1,
           LEAST((SELECT min(b3.band_y0_pct) FROM derm.v_stamp_row_bands b3
                  WHERE b3.dump_folder = l.dump_folder AND b3.effective_page = l.effective_page),
                 30::numeric) AS header_y   -- sheet is fully banded (gate above); cap 30% belt+braces
    FROM live l
    WHERE l.effective_page >= 1
      AND l.effective_page <= COALESCE(array_length(derm.ticket_page_images(l.tkey), 1), 0)
  ), ok AS (            -- PAGE-IDENTITY GUARD: src must content-match the OCR page image, if any
    SELECT g.* FROM geo g
    WHERE g.src IS NOT NULL AND g.y1 > g.y0
      AND NOT EXISTS (
        SELECT 1 FROM (
          SELECT mode() WITHIN GROUP (ORDER BY r5.image_url) AS ocr_img
          FROM derm.address_row_map r5
          WHERE r5.dump_folder = g.dump_folder AND r5.page = g.effective_page
            AND r5.image_url <> 'pending' AND r5.source = 'claude-vision-v1'
        ) oi
        WHERE oi.ocr_img IS NOT NULL
          AND derm._img_etag(oi.ocr_img) IS DISTINCT FROM derm._img_etag(g.src))
  ), fp AS (
    SELECT o.*, md5(coalesce(derm._img_etag(o.src), 'noetag') || '|' || o.y0 || '|' || o.y1 || '|' ||
                    coalesce(o.header_y::text, 'x')) AS fprint
    FROM ok o
  )
  SELECT f.mid, f.cid, f.tkey, f.src, f.effective_page, f.y0, f.y1, f.header_y, f.fprint, t.url
  FROM fp f
  LEFT JOIN derm.redacted_manifest_docs t ON t.manifest_id = f.mid
  LEFT JOIN derm.redacted_manifest_errors e ON e.manifest_id = f.mid
  WHERE (t.manifest_id IS NULL OR t.fingerprint IS DISTINCT FROM f.fprint)
    AND (e.manifest_id IS NULL OR e.next_retry_at <= now())
  ORDER BY e.next_retry_at NULLS FIRST, f.mid
  LIMIT p_limit;
$fn$;
REVOKE ALL ON FUNCTION derm.fn_blackout_targets(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_blackout_targets(int) TO service_role;

-- 3) customer.work_orders: derm_manifest_url <- redacted derivative (client-checked join) ------------
--    Full def re-stated from live pg_get_viewdef; ONLY the derm_manifest_url expression + one LEFT
--    JOIN changed. Same columns/order/types -> FP contract unchanged.
CREATE OR REPLACE VIEW customer.work_orders AS
 SELECT v.public_id AS id,
    customer.uuid_from_bigint(v.client_id) AS client_id,
    v.visit_date,
        CASE
            WHEN v.start_at IS NOT NULL THEN to_char((v.start_at AT TIME ZONE 'America/New_York'::text), 'FMHH12:MI AM'::text)
            ELSE NULL::text
        END AS visit_time,
    COALESCE(( SELECT string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS string_agg
           FROM visit_assignments va
             JOIN employees e ON e.id = va.employee_id
          WHERE va.visit_id = v.id), ( SELECT string_agg(e2.full_name, ', '::text ORDER BY e2.full_name) AS string_agg
           FROM visit_team vt
             JOIN employees e2 ON e2.id = vt.employee_id
          WHERE vt.visit_id = v.id)) AS driver,
    veh.name AS truck,
    veh.decal_number AS decal,
    COALESCE(v.manhole_count, NULLIF(prop.grease_trap_manhole_count, 0), NULLIF(( SELECT prim.grease_trap_manhole_count
           FROM properties prim
          WHERE prim.client_id = v.client_id AND prim.is_primary = true
         LIMIT 1), 0)) AS manholes,
    v.manhole_breakdown,
    v.ticket_number,
    v.trap_condition_notes AS trap_condition,
    row_number() OVER (PARTITION BY v.client_id, (EXTRACT(year FROM v.visit_date)) ORDER BY v.visit_date)::integer AS visit_num,
    ( SELECT
                CASE
                    WHEN sc.frequency_days IS NULL OR sc.frequency_days <= 0 THEN NULL::integer
                    ELSE GREATEST(1::numeric, round(365.0 / sc.frequency_days::numeric))::integer
                END AS "greatest"
           FROM service_configs sc
          WHERE sc.client_id = v.client_id AND sc.service_type = v.service_type
         LIMIT 1) AS visit_total,
    v.title AS notes,
    dm.white_manifest_number AS derm_manifest_number,
    rd.url AS derm_manifest_url,
    COALESCE(dm.wwtp_receipt_number, dm.white_manifest_number, dm.yellow_ticket_number) AS wwtp_receipt_number,
    dm.derm_manifest_url AS wwtp_receipt_url,
    dm.wwtp_ticket_number,
    v.created_at,
    COALESCE(v.completed_at, v.created_at) AS updated_at,
    COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS manifest_number,
        CASE
            WHEN dm.white_manifest_number IS NOT NULL THEN 'dade'::text
            WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'::text
            ELSE NULL::text
        END AS manifest_jurisdiction,
    dm.id AS manifest_id,
    COALESCE(NULLIF(prop.sample_port_count, 0), NULLIF(( SELECT prim.sample_port_count
           FROM properties prim
          WHERE prim.client_id = v.client_id AND prim.is_primary = true
         LIMIT 1), 0)) AS sample_ports,
    ( SELECT df.name
           FROM disposal_facilities df
          WHERE df.id = dm.disposal_facility_id) AS disposal_facility,
    COALESCE(( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE li.visit_id = v.id AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text), ARRAY[]::text[]) AS services
   FROM visits v
     LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
     LEFT JOIN properties prop ON prop.id = v.property_id
     LEFT JOIN LATERAL ( SELECT dm_inner.id,
            dm_inner.client_id,
            dm_inner.service_date,
            dm_inner.dump_ticket_date,
            dm_inner.white_manifest_number,
            dm_inner.yellow_ticket_number,
            dm_inner.sent_to_client,
            dm_inner.sent_to_city,
            dm_inner.created_at,
            dm_inner.updated_at,
            dm_inner.wwtp_receipt_number,
            dm_inner.wwtp_receipt_document_path,
            dm_inner.wwtp_ticket_number,
            dm_inner.disposal_facility_id,
            dm_inner.derm_manifest_url,
            dm_inner.derm_address_url,
            dm_inner.fog_manifest_url,
            dm_inner.gdo_id
           FROM derm_manifests dm_inner
             JOIN manifest_visits mv ON mv.manifest_id = dm_inner.id
          WHERE mv.visit_id = v.id AND dm_inner.deleted_at IS NULL
          ORDER BY dm_inner.service_date DESC NULLS LAST
         LIMIT 1) dm ON true
     LEFT JOIN derm.redacted_manifest_docs rd ON rd.manifest_id = dm.id AND rd.client_id = v.client_id
  WHERE v.visit_status = 'completed'::text AND v.client_id IS NOT NULL AND COALESCE(v.derm_required, true) = true AND v.deleted_at IS NULL;

-- 4) cron plumbing ------------------------------------------------------------------------------------
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'edge_invoke_service_key') THEN
    PERFORM vault.create_secret(
      (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'jobber_push_service_key'),
      'edge_invoke_service_key');
  END IF;
END $do$;

CREATE OR REPLACE FUNCTION public.fn_request_blackout_sweep()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE v_key text;
BEGIN
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';
  IF v_key IS NULL THEN
    RAISE WARNING 'edge_invoke_service_key vault secret missing; skipping blackout sweep';
    RETURN;
  END IF;
  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/redact-manifest-sheet',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body    := jsonb_build_object('limit', 3),
    timeout_milliseconds := 120000);
END; $fn$;
REVOKE ALL ON FUNCTION public.fn_request_blackout_sweep() FROM PUBLIC, anon, authenticated, service_role;

-- every 10 min, 3/run (edge CPU cap ~2s/request makes small batches mandatory; ~18/h steady-state)
SELECT cron.schedule('redact-manifest-sweep', '*/10 * * * *', 'SELECT public.fn_request_blackout_sweep()');

COMMIT;
