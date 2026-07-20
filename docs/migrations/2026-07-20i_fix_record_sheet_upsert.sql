-- 2026-07-20i — fix derm.record_generated_address_sheet: REGENERATION was raising unique_violation
--
-- FOUND BY THE FIRST REAL GENERATION TEST (2026-07-20). The first generation of sheet 1027 worked;
-- the SECOND call for the same sheet returned HTTP 500.
--
-- BUG (mine, introduced in 20f): the upsert targeted the wrong uniqueness.
--     INSERT ... ON CONFLICT ON CONSTRAINT address_sheets_pkey DO NOTHING
-- The primary key is on `id`, which is GENERATED ALWAYS AS IDENTITY and therefore never collides,
-- so that clause was dead code. The uniqueness that actually applies is the PARTIAL index
-- address_sheets_sheet_no_live_idx (sheet_no) WHERE deleted_at IS NULL, which the clause does not
-- cover, so a regeneration raised 23505 before reaching the read-then-update fallback.
--
-- WHY IT MATTERS: regeneration is the NORMAL case, not an edge case. Every time a client is added to
-- a shared dump ticket the Section B rows change and the sheet is generated again, keeping its
-- existing number (pdf-service CLAUDE.md rule 5). A first-generation-only writer would have worked
-- exactly once per sheet and then failed forever. This is precisely what the first-generation test
-- existed to catch.
--
-- FIX: one atomic upsert targeting the real index, replacing the insert/select/insert/update dance.
-- It also removes a race: two concurrent generations of the same sheet now serialize on the index
-- instead of both taking the "not found" branch.
--
-- GATE 1 REFINEMENT (same bug class, caught while re-reading): the handwritten-evidence gate keyed
-- on "a Stamp Studio card exists for this ticket". After the FIRST successful generation the sheet's
-- own AI-stamped card exists, so a regeneration would have been refused by its own card. The gate
-- now ignores cards belonging to THIS sheet's own manifests and still refuses every genuinely
-- handwritten ticket (an uploaded photo, or a card on a ticket this sheet does not own).
--
-- GATE 2 is unchanged (never bind a manifest to a second sheet).
-- Idempotent.

BEGIN;

CREATE OR REPLACE FUNCTION derm.record_generated_address_sheet(
  p_sheet_no bigint, p_bucket text, p_path text, p_manifest_ids bigint[])
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'derm','public' AS $fn$
DECLARE v_sheet_id bigint; v_bad text; v_other bigint;
BEGIN
  IF p_sheet_no IS NULL OR p_bucket IS NULL OR btrim(coalesce(p_path,'')) = ''
     OR p_manifest_ids IS NULL OR array_length(p_manifest_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'record_generated_address_sheet: all arguments are required (sheet=%, bucket=%, path=%)',
      p_sheet_no, p_bucket, p_path;
  END IF;

  -- GATE 1: never claim a ticket that already carries handwritten evidence. A card that belongs to
  -- THIS sheet (i.e. its manifests are already linked to sheet p_sheet_no) is our own AI stamp from
  -- a previous generation and must not block a regeneration.
  SELECT string_agg(DISTINCT k, ', ') INTO v_bad
  FROM (
    SELECT COALESCE(m.white_manifest_number, m.yellow_ticket_number) AS k
      FROM public.derm_manifests m
     WHERE m.id = ANY (p_manifest_ids) AND m.deleted_at IS NULL
       AND (
         m.derm_address_url IS NOT NULL
         OR (
           EXISTS (SELECT 1 FROM derm.address_row_map a
                    WHERE a.white_manifest_number = COALESCE(m.white_manifest_number, m.yellow_ticket_number))
           AND NOT EXISTS (SELECT 1 FROM derm.address_sheet_manifests l2
                             JOIN derm.address_sheets s2 ON s2.id = l2.sheet_id AND s2.deleted_at IS NULL
                            WHERE l2.manifest_id = m.id AND s2.sheet_no = p_sheet_no)
         )
       )
  ) q;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'refusing: ticket(s) % already carry handwritten evidence (uploaded sheet photo or Stamp Studio card)', v_bad;
  END IF;

  -- GATE 2: never bind a manifest to a second sheet.
  SELECT s.sheet_no INTO v_other
    FROM derm.address_sheet_manifests l
    JOIN derm.address_sheets s ON s.id = l.sheet_id AND s.deleted_at IS NULL
   WHERE l.manifest_id = ANY (p_manifest_ids) AND s.sheet_no <> p_sheet_no
   LIMIT 1;
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION 'refusing to renumber: one of these manifests already belongs to sheet %', v_other;
  END IF;

  -- THE FIX: one atomic upsert on the index that actually enforces uniqueness.
  INSERT INTO derm.address_sheets (sheet_no, pdf_bucket, pdf_path)
  VALUES (p_sheet_no, p_bucket, p_path)
  ON CONFLICT (sheet_no) WHERE deleted_at IS NULL
  DO UPDATE SET pdf_bucket = EXCLUDED.pdf_bucket,
                pdf_path   = EXCLUDED.pdf_path,
                last_generated_at = now()
  RETURNING id INTO v_sheet_id;

  INSERT INTO derm.address_sheet_manifests (sheet_id, manifest_id)
  SELECT v_sheet_id, unnest(p_manifest_ids)
  ON CONFLICT DO NOTHING;

  RETURN v_sheet_id;
END $fn$;

COMMIT;

-- ============================================================================
-- FIRST REAL GENERATED DERM ADDRESS SHEET — full result (2026-07-20, Fred-authorised)
--
-- Client 002-41 "41 Pizza and Bakery" (single ACTIVE permit GDO-09852, one service property),
-- scratch manifest 1374 on ticket 999001 with NO photo and NO card. Sheet number 1027 assigned.
--
-- THE QUESTION THIS TEST EXISTED TO ANSWER (does the Studio's row_index -> slot mapping match what
-- the generator actually prints?) — ANSWERED, EXACTLY:
--   * The generated PDF prints Section B row 1 at y = 453.0 pt on a 792x612 landscape page
--     = 25.980% from the top, with the GDO chip cell at x 24..80 pt (centre 54 pt = 6.82%).
--   * derm.fn_generated_row_geometry(1) predicts y = 25.98%, x = 6.82%, page 1.
--   * The Studio card auto-stamped at y = 25.980%, x = 6.820%. Delta 0.000 on BOTH axes.
--   Also verified on the same sheet: auto-completed by 'stamp-studio-ai', is_generated true in
--   v_stamp_sheets and v_stamp_rows, guess_confidence 'generated' (so no review banner), and
--   fn_blackout_targets stayed 0 (a generated sheet has no photo to redact).
--   ⚠ This confirms the SINGLE-GDO case only. Multi-GDO clients (009-CN 3 rows, 043-MIL 2,
--     148-MOR 2, 242-WYN 3) emit several Section B rows per client and are still UNVERIFIED.
--
-- THE PROTECTION HELD AT EVERY STEP: public.derm_manifests.derm_address_url stayed NULL on the
-- scratch manifest through three generations, and all 535 real manifests kept their photos
-- (535/535 before and after). Under the pre-20f code the very first request would have overwritten
-- one.
--
-- THREE BUGS FOUND, ALL BY THIS TEST, ALL FIXED BEFORE IT PASSED:
--   1. 20g — both new RPCs lived in `derm`, but the pdf-service builds a plain create_client(), so
--      supabase-py resolved them against the default (public) schema and every call 404'd.
--      Fixed with public wrappers (the ops.* wrapper precedent).
--   2. 20h — the two readers were INVOKER-rights SQL functions over the new tables, and the derm
--      schema's default grants covered anon and authenticated but NOT service_role, so the
--      pdf-service got 42501 permission denied. Fixed by making both SECURITY DEFINER.
--      ⚠ Live apps were never affected (verified by SET LOCAL ROLE probes for anon, authenticated
--      and service_role against v_stamp_rows, v_stamp_sheets and derm.manifests) — but the 20f
--      no-op oracle ran as postgres and so could not have caught this. Role-scoped probes are now
--      part of the checklist for anything a service calls.
--   3. 20i (this file) — the regeneration bug above, plus the gate refinement: after the first
--      generation the sheet's own AI-stamped card would have blocked its own regeneration.
--
-- EVERY FAILURE WAS FAIL-CLOSED. Each 500 left the photo untouched, recorded nothing, and (for the
-- first two) did not even consume a sheet number.
--
-- TEARDOWN: all scratch data removed and verified back to baseline (manifests 553, cards 552,
-- address_sheets 0, links 0, redacted docs 527, photos 535/535, blackout targets 0, no ghost rows
-- in v_stamp_sheets, 0 storage objects left under derm/sheets/). The three generated PDFs were
-- deleted from the PUBLIC bucket because they carry a real client's facility name and address under
-- a fake ticket number. Backup: ..ackups6-07-20_first_generation_test_scratch_data.json.
-- A review copy of the sheet is at the workspace root:
-- 2026-07-20_first_generated_DERM_address_sheet_1027.pdf.
--
-- ONE PERMANENT, INTENDED SIDE EFFECT: derm_address_seq advanced 1026 -> 1027. Sheet number 1027
-- was really consumed by this test and its record is gone, so 1027 is now a permanent gap and the
-- first production sheet will be 1028. Gaps are expected by design (previews consume numbers too)
-- and the sequence must never be reset — a previewed or tested number may exist on printed paper.
--
-- STILL GATED ON FRED: no "Generate address PDF" button is wired anywhere. The endpoint remains
-- reachable only by service_role, and the first PRODUCTION sheet should be a single-GDO client
-- exactly like this test until the multi-GDO row-order question above is settled.
-- ============================================================================
