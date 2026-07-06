-- 2026-07-06_derm_clear_mislink_moves.sql
-- Second batch of the cross-client mis-link cleanup (after the Yannick cluster).
-- Fred's steer: fix the CLEAR ones that need NO new records now; flag the rest.
-- These 5 need no new manifest:
--   MOVE the borrowed visit to the true client's EXISTING manifest on the ticket:
--     #306859  v5156 (230-KRU) : m1198 (109-RAB) -> m1287 (230-KRU)
--     #821472  v1707 (035-LG)  : m652  (092-TCE) -> m286  (035-LG)
--     #824026  v3932 (212-TRUE): m987  (004-BAO) -> m991  (212-TRUE)
--   DELETE a purely spurious link (the visit is ALREADY on its correct manifest elsewhere):
--     #000195  v1430 (136-BB) was double-linked to m575 (087-BB/#000195) AND its own
--              m269 (136-BB/#818188). 087-BB is the facility on the #000195 sheet; 136-BB
--              is not. Drop the m575 link; v1430 stays on m269.
--   UN-MATCH a wrong OCR match (Fred's example): card id=497 on #814105 read
--     "Unclogme LLC (transporter info)" -> matched 033-LG. That line is the HAULER (us),
--     not a client facility. Cleared matched_client_id/matched_manifest_id.
-- Backup: backups/2026-07-06_clear_moves_backup.json
-- Verified: 0 cross-client links on the 4 tickets; each moved visit on exactly 1 correct
-- manifest; fleet cross-client links 12 -> 8.
--
-- STILL FLAGGED (need Fred's ok / decision -- not done here):
--   * 4 cross-client links whose true client has NO manifest on the ticket (would need a
--     NEW manifest filed): #824713 (215-G7), #825906 (034-LG), #826661 (214-MYK),
--     #827172 (133-MUT). Same fix pattern as the cluster (file + inherit docs + move).
--   * 4 same-address SIBLING links -- possibly one physical location under two Jobber codes:
--     #815064 + #820615 (139-LTG / 144-LTG, IDENTICAL address) and #816562 + #821038
--     (192-FRK / 193-FRK, adjacent units). Merge vs move is a business decision.
--   * 30 cards matched to an off-ticket client (facilities serviced but no manifest filed) +
--     11 unmatched cards + 12 linked-manifests-without-card + phantom client 480
--     "Bay Harborview Condo" (no client_code).

BEGIN;
DELETE FROM public.manifest_visits WHERE manifest_id=1198 AND visit_id=5156;
INSERT INTO public.manifest_visits (manifest_id, visit_id) VALUES (1287,5156) ON CONFLICT DO NOTHING;
DELETE FROM public.manifest_visits WHERE manifest_id=652 AND visit_id=1707;
INSERT INTO public.manifest_visits (manifest_id, visit_id) VALUES (286,1707) ON CONFLICT DO NOTHING;
DELETE FROM public.manifest_visits WHERE manifest_id=987 AND visit_id=3932;
INSERT INTO public.manifest_visits (manifest_id, visit_id) VALUES (991,3932) ON CONFLICT DO NOTHING;
DELETE FROM public.manifest_visits WHERE manifest_id=575 AND visit_id=1430;
UPDATE derm.address_row_map SET matched_client_id=NULL, matched_manifest_id=NULL WHERE id=497;
COMMIT;
