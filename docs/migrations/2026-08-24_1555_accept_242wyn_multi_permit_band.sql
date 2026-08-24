-- ============================================================================
-- 2026-08-24_1555  Accept 242-WYN's three-slot band on ticket-833395
-- ============================================================================
--
-- Snapping ticket-833395 (2026-08-24_1320) put one new row on the band worklist:
--
--   242-WYN   ticket-833395 p1   24.309 - 47.445   edge ON_RULE / slot SPANS_MULTIPLE
--
-- **It is correct, and `SPANS_MULTIPLE` is the check meeting the permit grain for the first time.**
--
-- A generated sheet prints ONE ROW PER ACTIVE GDO PERMIT (2026-08-24_0450). 242-WYN (Wynd 28) holds
-- three, so it owns three consecutive printed slots and its band must cover all three:
--
--   slot 1   24.309 - 32.942   GDO-13814  242-WYN Wynd 28 - Pasta
--   slot 2   32.942 - 39.848   GDO-14760  242-WYN Wynd 28 - Nino Gordo
--   slot 3   39.848 - 47.445   GDO-16146  242-WYN Wynd 28 - Pari Pari
--
-- Every one of those rows is 242-WYN's own facility. Blacking two of them would hide the client's
-- own compliance record from itself. `derm.v_band_edge_check`'s `slot_verdict` assumes one printed
-- slot per client, which was true of all 635 bands before this sheet.
--
-- VERIFIED TWICE, not reasoned about:
--   * against the paper, with the detected rules drawn over the scan: both edges sit exactly on a
--     printed full-width boundary, and the two interior lines it crosses are 242-WYN's own slot
--     boundaries;
--   * against the SERVED document (`manifests/redacted/m1737-*.jpg`), opened and read: it shows
--     GDO-13814 / GDO-14760 / GDO-16146, all three labelled "242-WYN Wynd 28", and everything from
--     47.445 down -- 069-TCE and 032-LG -- is black.
--
-- ⚠ THE HONEST LIMIT, so nobody reads this as a blanket exemption for the shape: `derm.band_review`
-- is keyed on the BAND VALUES, so this acceptance covers 24.309-47.445 on this row and nothing else.
-- Move the band and it returns to the worklist. That is the property the ledger exists for and the
-- migration proves it below.
--
-- ⇒ THE STRUCTURAL FIX, NOT DONE HERE: teach `slot_verdict` the permit grain by reading
-- `derm.v_sheet_printed_rows` instead of assuming one slot per client. Then a multi-permit client's
-- band would grade ONE_CLIENT rather than SPANS_MULTIPLE and need no acceptance at all. Worth doing
-- when the next multi-permit sheet appears; a single accepted row is not yet worth changing a check
-- that 635 other bands depend on.
--
-- ADR 010 rule 8 (audit): derm.band_review already carries an audit trigger from 2026-08-23_2333.
-- ============================================================================

BEGIN;

INSERT INTO derm.band_review (row_id, band_y0_pct, band_y1_pct, verdict, reason, reviewed_by)
SELECT a.id, a.band_y0_pct, a.band_y1_pct, 'accepted',
       'CORRECT, and the first band on the fleet that spans more than one printed slot. 242-WYN '
       'holds THREE ACTIVE GDO permits (13814 Pasta, 14760 Nino Gordo, 16146 Pari Pari) so the '
       'generator printed it three consecutive rows, and all three are its own facilities. Both '
       'edges sit on detected full-width boundaries; the two interior lines the band crosses are '
       '242-WYN''s own slot boundaries. Verified against the paper with the detected rules drawn '
       'over the scan, AND against the served document m1737, which shows exactly the three '
       '242-WYN rows and blacks 069-TCE and 032-LG. SPANS_MULTIPLE is slot_verdict assuming one '
       'printed slot per client, which was true of all 635 earlier bands.',
       'claude-permit-grain-2026-08-24'
  FROM derm.address_row_map a
  JOIN public.clients c ON c.id = a.matched_client_id
 WHERE a.white_manifest_number = '833395' AND c.client_code = '242-WYN'
ON CONFLICT (row_id, band_y0_pct, band_y1_pct) DO UPDATE
  SET verdict = EXCLUDED.verdict, reason = EXCLUDED.reason,
      reviewed_by = EXCLUDED.reviewed_by, reviewed_at = now();

DO $$
DECLARE v_n int; v_reopen int;
BEGIN
  -- it must have left the worklist
  SELECT count(*) INTO v_n FROM derm.v_band_edges_off_rule WHERE dump_folder = 'ticket-833395';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'ticket-833395 still has % bands on the worklist', v_n;
  END IF;

  -- and the other two must never have been on it: if they were, the snap was wrong
  IF NOT EXISTS (SELECT 1 FROM derm.v_band_edge_check
                  WHERE dump_folder = 'ticket-833395' AND client_code = '069-TCE'
                    AND edge_verdict = 'ON_RULE' AND slot_verdict = 'ONE_SLOT') THEN
    RAISE EXCEPTION '069-TCE is not grading ON_RULE/ONE_SLOT, so the snap is not what was verified';
  END IF;

  -- 🛑 the acceptance must NOT be a standing exemption: move the band and it comes back
  UPDATE derm.address_row_map SET band_y0_pct = band_y0_pct + 1.0
   WHERE white_manifest_number = '833395'
     AND matched_client_id = (SELECT id FROM public.clients WHERE client_code = '242-WYN');
  SELECT count(*) INTO v_reopen FROM derm.v_band_edges_off_rule WHERE dump_folder = 'ticket-833395';
  IF v_reopen < 1 THEN
    RAISE EXCEPTION 'moving the reviewed band did not reopen it, so the ledger is a blanket exemption';
  END IF;
  UPDATE derm.address_row_map SET band_y0_pct = band_y0_pct - 1.0
   WHERE white_manifest_number = '833395'
     AND matched_client_id = (SELECT id FROM public.clients WHERE client_code = '242-WYN');

  -- restored exactly
  IF NOT EXISTS (SELECT 1 FROM derm.address_row_map a JOIN public.clients c ON c.id = a.matched_client_id
                  WHERE a.white_manifest_number = '833395' AND c.client_code = '242-WYN'
                    AND a.band_y0_pct = 24.309 AND a.band_y1_pct = 47.445) THEN
    RAISE EXCEPTION 'the reopen probe did not restore 242-WYN''s band';
  END IF;
  SELECT count(*) INTO v_n FROM derm.v_band_edges_off_rule WHERE dump_folder = 'ticket-833395';
  IF v_n <> 0 THEN RAISE EXCEPTION 'the folder did not leave the worklist again'; END IF;

  RAISE NOTICE 'OK: 242-WYN 3-slot band accepted, ticket-833395 clear, ledger still value-keyed';
END $$;

COMMIT;
