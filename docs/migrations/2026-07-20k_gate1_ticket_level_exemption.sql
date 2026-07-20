-- 2026-07-20k — gate 1: exempt the sheet's OWN ticket, not just already-linked manifests
--
-- FOUND BY SMOKE CAMPAIGN ROUND A, scenario S7 (regen-append). Adding a NEW client to an existing
-- generated ticket and regenerating returned HTTP 500:
--   * first generation: BUB alone -> sheet recorded, card auto-stamped. Fine.
--   * append BAO's manifest to the same ticket -> regenerate -> REFUSED
--     "ticket(s) 999010 already carry handwritten evidence".
--
-- CAUSE: the 20i refinement exempted "manifests already linked to THIS sheet" from the
-- card-evidence check. A newly APPENDED manifest is not yet linked, and the ticket already has
-- cards (the sheet's own AI stamps from the first generation), so the new manifest tripped the
-- handwritten-evidence clause. Appending a client and regenerating is the NORMAL shared-ticket
-- flow, so this made every generated ticket effectively frozen after its first card.
--
-- FIX: the exemption belongs at TICKET level. Cards on a ticket count as handwritten evidence only
-- when NO live sibling of that ticket is linked to THIS sheet number. If any sibling is linked, the
-- ticket IS this sheet, its cards are ours, and any of its manifests (old or newly appended) may be
-- recorded.
--
-- SECURITY UNCHANGED, argued explicitly: the exemption cannot be bootstrapped onto a real
-- handwritten ticket. Its first record call sees cards + zero links to the target sheet -> refused
-- (exactly as before; re-verified below against real sheets). Links to a sheet exist only if a
-- previous record call succeeded, which for a carded ticket requires the exemption... which
-- requires a prior link. The only entry path remains a ticket with NO cards and NO photos — a
-- genuinely born-digital one. The photo check stays per-manifest and unconditional.
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

  -- GATE 1: refuse tickets carrying handwritten evidence. A photo always refuses. Cards refuse
  -- only when the ticket is NOT already this sheet (no live sibling linked to p_sheet_no).
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
           AND NOT EXISTS (
             SELECT 1
               FROM public.derm_manifests m2
               JOIN derm.address_sheet_manifests l2 ON l2.manifest_id = m2.id
               JOIN derm.address_sheets s2 ON s2.id = l2.sheet_id AND s2.deleted_at IS NULL
              WHERE COALESCE(m2.white_manifest_number, m2.yellow_ticket_number)
                    = COALESCE(m.white_manifest_number, m.yellow_ticket_number)
                AND m2.deleted_at IS NULL
                AND s2.sheet_no = p_sheet_no
           )
         )
       )
  ) q;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'refusing: ticket(s) % already carry handwritten evidence (uploaded sheet photo or Stamp Studio card)', v_bad;
  END IF;

  -- GATE 2 unchanged: never bind a manifest to a second sheet.
  SELECT s.sheet_no INTO v_other
    FROM derm.address_sheet_manifests l
    JOIN derm.address_sheets s ON s.id = l.sheet_id AND s.deleted_at IS NULL
   WHERE l.manifest_id = ANY (p_manifest_ids) AND s.sheet_no <> p_sheet_no
   LIMIT 1;
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION 'refusing to renumber: one of these manifests already belongs to sheet %', v_other;
  END IF;

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
-- SMOKE CAMPAIGN RESULTS (2026-07-20, Fred: "smoke tests for multiple scenarios and multiple
-- times"). 20 scenarios, 2 rounds + a phase-2 simulation. ALL PASS after the fix above.
--
-- ROUND A (10) + ROUND B (9), different clients per round, every scenario torn down to an
-- identical baseline before the next:
--   S1  single client / single GDO ......................... PASS x2 (005-BUB; 008-CV)
--   S2  solo multi-GDO client .............................. PASS x2 (009-CN 3 rows; 148-MOR 2)
--   S3  order inversion (single BEFORE multi) .............. PASS x2
--   S4  exact-5 boundary (page 1 exactly full) ............. PASS x2
--   S5  overflow to page 2 ................................. PASS x2
--   S6  zero-permit client (blank GDO row) ................. PASS x2 (007-CC; 010-CS)
--   S7  regen after APPENDING a client ..................... PASS x2 (same number, no seq burn,
--       existing stamp untouched, new client on its row) — THIS scenario found the gate bug fixed
--       above; before 20k every generated ticket froze after its first card.
--   S8  regen after REMOVING a sibling ..................... PASS (stale-stamp drift is DETECTABLE
--       via stamp_y_pct <> guess_y_pct on generated cards, and clear + auto_place_page heals it;
--       the removed client's card is repointed by trg_ad as designed). Standing tripwire query:
--         SELECT count(*) FROM derm.address_row_map a JOIN derm.v_stamp_rows g ON g.id=a.id
--          WHERE a.stamp_placed_by='stamp-studio-ai' AND a.stamp_y_pct <> g.guess_y_pct;
--   S9  concurrent duplicate generation .................... PASS x2. Both interleavings observed:
--       500/200 (loser refused by gate 2) and 200/200 (loser resolved into the regeneration path).
--       Invariant held both times: EXACTLY ONE live sheet bound to the ticket.
--   S10 gate regression .................................... PASS x2 (photo-carrying ticket
--       refused; renumbering refused) + 3/3 real carded sheets still refused post-20k.
--
-- S11 PHASE-2 SIMULATION (the returned photo, on sanctioned test client 112-YA): generated sheet
-- 1050 -> card auto-stamped 25.980% -> synthetic "driver photo" filed into derm_address_url ->
-- the sheet gained its page automatically -> REAL calendar visit created + linked (all link
-- guards passed) -> extent measured -> fn_blackout_targets returned the manifest -> ONE sweep
-- generated the redacted doc -> pixel check: own band 3% dark (visible), decoy neighbour row
-- 100% black, county section + header visible. Visit soft-deleted afterwards (sync confirmed =
-- Jobber cleaned); every count back to baseline.
--
-- Sheets 1031-1050 consumed by the campaign (documented gaps). FIRST PRODUCTION SHEET = 1051.
-- Campaign runner + verifier kept in the session scratchpad (campaign.js / verify_pdf.py /
-- s11.js); reports campaign_roundA/B_report.json.
-- ============================================================================

-- ============================================================================
-- PRODUCTION DRESS REHEARSAL (2026-07-20, on Fred's 3 REAL prior production sheets:
-- 308684, 829322, 829201 — read-only on the real sheets; replays on scratch tickets).
--
-- TEST A — the 3 real client COMPOSITIONS replayed through the generator: ALL PASS.
--   308684: 7 clients, ALL Broward (zero Dade permits) -> 7 blank-GDO rows over 2 pages (sheet 1051)
--   829322: 7 single-permit clients -> 7 rows over 2 pages (sheet 1052)
--   829201: 10 clients (8 single + 2 zero-permit) -> 10 rows = EXACTLY two full pages (sheet 1053,
--           a page boundary no synthetic scenario had hit)
--   Every client printed and auto-stamped on its predicted page/row; torn down to baseline.
--   Review copies of all 3 rehearsal PDFs at the workspace root (2026-07-20_replay_of_*.pdf).
--
-- TEST B — the real RETURNED PHOTOS (6 pages) measured against template geometry:
--   * Human stamps (ground truth of where rows ARE on real photos) sit within mean 2.3 / max 3.68
--     percentage points of the template slot positions. A printed row is ~7-8% tall, so template
--     pre-positions land ON (or at the edge of) the correct row even on real driver photos/scans.
--   * Framing consistency: across all 6 pages the Section B region's detected top edge stays within
--     ~±2-3% of its clean-scan position — drivers/office consistently capture the form full-frame.
--   * HONEST CAVEAT: these photos are of the county PAD form, whose grid has SIX rows (~4.4-5.4%
--     pitch) vs our generated form's FIVE (~7.8% pitch) — so per-row deltas here are indicative,
--     not exact. The transferable facts are the framing consistency and the stamp-to-slot bound.
--     A returned GENERATED sheet is a photo of OUR OWN 5-row form, so its rows will sit within the
--     same ±2-3% framing envelope of the template positions the AI stamps already use.
--   * The backstops are unchanged either way: redaction hard-gates on a per-photo measured extent,
--     and the office reviews at measurement time.
--
-- Sheets 1051-1053 consumed by the rehearsal. FIRST PRODUCTION SHEET = 1054.
-- ============================================================================
