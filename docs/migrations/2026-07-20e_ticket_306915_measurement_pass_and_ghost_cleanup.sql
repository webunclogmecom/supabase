-- 2026-07-20e — ticket-306915 measurement pass (FP unblocked) + ghost sheet ticket-819788 removed
--
-- TWO Fred-approved items, both data-only (no schema change, no function change).
--
-- ============================================================================
-- PART 1 — ticket-306915 measurement pass (Fred: "yes do it, and check it visually to make sure
-- the measurements are correct")
-- ============================================================================
-- WHY IT WAS BLOCKED: the sheet was fully stamped (8/8) and completed, but derm.fn_blackout_targets
-- HARD-GATES on a measured page (JOIN derm.page_block_extents). No extent row existed, so the FP
-- served nothing for its 8 clients. That is the designed fail-closed behaviour, not a bug: without a
-- measured roster region the redactor cannot know what to black, and guessing would risk exposing a
-- neighbour's row.
--
-- HOW MEASURED (deterministic, not eyeballed): both page PNGs were decoded and the Section B table
-- rules were located by scanning the left column (x 3%..38% of width) for rows where >60% of the span
-- is dark. Detected rules, as % of page height:
--   page 1 (address_1.png, 647x502, form #404): B-header 25.50 | slot rules 27.89 33.27 38.55 43.82
--          49.20 54.58 59.96 | band below slots 61.95
--   page 2 (address_2.png, 652x485, form #403): B-header 25.15 | slot rules 27.63 33.20 38.76 44.23
--          49.69 55.26 60.82 | band below slots 62.89
-- Cross-check: the six page-2 slot MIDPOINTS (30.4 36.0 41.4 47.0 52.5 58.0) match the six real
-- hand-placed stamps (30.249 35.958 41.520 47.231 52.179 58.167) to within 0.3 pts, and the two
-- page-1 midpoints match its two stamps. So the detected grid is the true printed grid, and the
-- office placed every stamp on its correct row (client order on the paper == stamp order).
--
-- EXTENTS WRITTEN (derm.page_block_extents, source 'vision-snap-2026-07-20') — deliberately generous
-- (cover the B header line and the "Attach Additional Sheets" band) so the blackout can only ever
-- over-cover, never under-cover. Matches the convention of the FP-verified sheet ticket-830088
-- (stored 25.5/62.0, whose own detected rules are 24.97 header and ~59.7 last slot):
--   ('ticket-306915', 1, 25.5, 62.0)
--   ('ticket-306915', 2, 25.0, 63.0)
--
-- BANDS WRITTEN (derm.address_row_map.band_y0_pct/band_y1_pct, band_source 'vision-snap-2026-07-20',
-- band_set_by 'claude-measure') — line-snapped and CONTIGUOUS, i.e. each client's band is exactly its
-- printed slot, following the existing 'ocr-v2-snap' convention:
--   p1: 287-NKK 27.888-33.267 | 013-DIM 33.267-38.546
--   p2: 014-JOY 27.629-33.196 | 040-MV 33.196-38.763 | 033-LG 38.763-44.227
--       061-TCE 44.227-49.691 | 043-MIL 49.691-55.258 | 001-VIN 55.258-60.825
-- ⚠ WHY MANUAL BANDS AND NOT THE DERIVED ONES: v_stamp_row_bands derives from neighbour midpoints.
-- On page 1 (only 2 stamps) that would have started 013-DIM's band at 32.825 while its printed slot
-- starts at 33.267 — the 0.44-pt sliver would have exposed the bottom of 287-NKK's handwritten
-- address line in DIM's customer copy. Snapping to the printed rules removes that class of leak.
-- Pre-write state was captured (all 8 bands were NULL; the script aborts if any band already exists).
--
-- VERIFICATION (done, both ways):
--  * Queue drained manually (7 sweeps of fn_request_blackout_sweep, ~22s apart — the cron does 1 per
--    5 min): 8/8 redacted docs generated, derm.redacted_manifest_errors EMPTY for this ticket.
--  * VISUAL: 4 of the 8 redacted copies opened and read (014-JOY first slot, 001-VIN last slot,
--    287-NKK and 013-DIM = the page-1 pair). Each shows ONLY that client's facility name + address;
--    every other roster row is solid black. In 013-DIM's copy the neighbour row above is fully
--    covered with no sliver, which is exactly the case the snapped bands were chosen to fix.
--  * PIXEL-EXACT (all 8, scripted): for each copy, the blacked region measures 25.5-61.8% (page 1)
--    and 24.9-62.9% (page 2) = the written extents; EVERY other client's band is >=97% dark across
--    the roster width (zero leaked rows); and each client's OWN band is not blacked (they can read
--    their own row). 8/8 PASS.
--  * FP: all 8 customer.work_orders now carry derm_manifest_url, and every URL is under
--    /manifests/redacted/ (never the raw shared sheet). Receipts also present.
--  * FLEET: stamped-but-unmeasured sheets went 1 -> 0. Nothing else is waiting on a measurement pass.
--
-- ============================================================================
-- PART 2 — ghost sheet ticket-819788 deleted (Fred: "remove 819788 it's a dupe")
-- ============================================================================
-- WHAT IT WAS: 3 Stamp cards (ids 656, 657, 658) created 2026-07-13 with source 'derm-link' under
-- dump_folder 'ticket-819788'. No manifest anywhere carries the number 819788 — it is a typo of
-- 829788, and all 3 cards pointed at 829788's manifests (1351/1352/1353 = 117-BH, 214-MYK, 035-LG),
-- which already have their own correct cards (673/674/675) on the real sheet. The Studio therefore
-- listed the same paperwork twice, both showing "completed".
-- WHY IT MATTERED: fn_blackout_targets picks one card per manifest with
-- ORDER BY stamp_placed_at DESC — a later re-stamp of a ghost card would have shadowed the real
-- sheet's card and frozen/redirected 829788's redaction.
-- GUARDED DELETE: the script refused to proceed unless (a) no manifest carries 819788, (b) every
-- ghost card resolves to a manifest whose real ticket is 829788, and (c) each of those clients
-- already has a card on ticket-829788. Backup written first:
--   ..\backups\2026-07-20_ghost_ticket_819788_cards.json  (the 3 cards + sheet status + a reference
--   copy of the real sheet's cards)
-- Deleted: 3 rows from derm.address_row_map + 1 row from derm.stamp_sheet_status.
-- AFTER: ticket-819788 gone from derm.v_stamp_sheets; ticket-829788 intact with its 3 cards; its 3
-- redacted docs untouched.
--
-- Audit note (ADR 010): derm.address_row_map carries audit_address_row_map (AFTER INSERT/UPDATE/
-- DELETE), so both the band writes and the 3 deletes are in audit.logs with app_source='sql'.
--
-- This file is a LOG of data operations performed via the Management API; the statements below are
-- the exact effective writes, kept idempotent so the state can be re-asserted if needed.

-- PART 1 statements (effective form)
INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct, source, measured_at)
VALUES ('ticket-306915', 1, 25.5, 62.0, 'vision-snap-2026-07-20', now()),
       ('ticket-306915', 2, 25.0, 63.0, 'vision-snap-2026-07-20', now())
ON CONFLICT (dump_folder, effective_page) DO UPDATE
  SET top_pct = EXCLUDED.top_pct, bottom_pct = EXCLUDED.bottom_pct,
      source = EXCLUDED.source, measured_at = now();

UPDATE derm.address_row_map a
   SET band_y0_pct = v.y0, band_y1_pct = v.y1,
       band_source = 'vision-snap-2026-07-20', band_set_at = now(), band_set_by = 'claude-measure'
  FROM (VALUES (665, 27.888, 33.267), (659, 33.267, 38.546),
               (661, 27.629, 33.196), (663, 33.196, 38.763), (666, 38.763, 44.227),
               (662, 44.227, 49.691), (660, 49.691, 55.258), (664, 55.258, 60.825)
       ) AS v(id, y0, y1)
 WHERE a.id = v.id AND a.dump_folder = 'ticket-306915';

-- PART 2 statements (already executed under the precondition guards described above)
-- DELETE FROM derm.address_row_map    WHERE id IN (656,657,658) AND dump_folder = 'ticket-819788';
-- DELETE FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-819788';
