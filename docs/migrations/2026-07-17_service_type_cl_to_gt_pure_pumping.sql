-- 2026-07-17 — correct 9 mislabeled visits.service_type CL -> GT (pure grease-trap pumping)
--
-- WHY: legacy visits.service_type (GT/CL/WD/LS) is the coarse pre-ADR-018 classifier and is
-- unreliable (handleVisit defaults GT). Yannick's TCE/PV export surfaced 186-PV visit 5843 as
-- service_type='CL' though its line items are codes 02+04 = Pumping. Audit found 13 live visits with
-- service_type='CL' but a Pumping line item; 9 are PURE pumping (no other physical service) and were
-- corrected to GT so the Calendar's per-(client,service_type) cadence / lateness anchor / service_configs
-- join stop grouping them under a phantom CL series. NOT changed (flagged for Fred, ambiguous):
--   5854 057-BAY  code 04 Lift Station (should be LS, not GT)
--   5127 223-CHA  Pumping + Camera Inspection (co-service)
--   5125 223-CHA  Pumping + Cleaning + Camera + Assessment (co-service)
--   6989 168-AVA  Pumping + Unclogging + Labor (one-off SC)
-- The 281 GT visits with non-pumping line items are the coarse GT-default and are NOT rewritten (the
-- report + apps should read the line-item service_kind; service_type is deprecated, not authoritative).
--
-- SAFE: service_type is NOT a Jobber-push field (verified: not in trg_push_visit_update /
-- fn_mark_visit_sync_pending watched columns; sync_state stays 'confirmed', no drift-reconciler pickup,
-- no ripple). All 9 are completed visits; the only service_type-reactive trigger (fn_check_gdo_on_visit)
-- just pg_notify's. Lateness re-bucketing verified: only 2 scheduled visits changed and both are
-- corrections (053-PV stayed on_time; 224-MP null->will_be_late once its GT cadence could compute).
-- Canonical service is line-item derived (service_line_items.service_kind), not this field — see the
-- audit doc.
--
-- AUDIT (ADR-010): visits IS audited; these 9 UPDATEs are captured in audit.logs (app_source='sql').
-- BACKUP / ROLLBACK: backups/2026-07-17_service_type_CL_to_GT_before.json (pre-flip service_type per id).

UPDATE public.visits SET service_type = 'GT'
WHERE id IN (1242, 4619, 5131, 5157, 5139, 5734, 5736, 5830, 5843)
  AND service_type = 'CL';
