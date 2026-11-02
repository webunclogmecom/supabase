-- 2026-11-02_1830 · Boca Raton properties: Broward -> Palm Beach (Trello iiOp4kSp)
--
-- THE ASK. Fred, 2026-11-02: *"Move all Boca Raton to Palm Beach"* (after checking what reads county). Boca Raton is
-- in Palm Beach County; the Jobber sync filed it as Broward "by convention" (webhook-jobber inferCountyFromCity), so
-- 15 of the 17 Boca Raton property rows say Broward. Plan: docs/specs/2026-11-02-permits-one-table-plan.md (County).
--
-- WHAT CHANGES: properties.county 'Broward' -> 'Palm Beach' on the 15 Boca Raton rows, pinned by id AND re-asserting
--  the city and the old county: 8 live (4 022-GRO, 53 135-BB, 62 064-TCE, 68 081-TCE, 291, 668, 1012 240-TUR,
--  1117 319-CAP) and 7 soft-deleted (563, 671, 675, 678, 820, 846, 1116), so a restored row does not come back wrong.
--  The two rows already Palm Beach (191 225-PV, 896) are untouched.
--
-- WHO READS COUNTY (both consumer maps, 2026-11-02), and the effect:
--  - Dump routing, Homestead hiding, LWT scope, the DERM queue: no change (fn_dump_county_bucket already folds
--    Palm Beach into BROWARD; LWT and fn_check_gdo_on_visit test only = 'Dade').
--  - fn_admin_review_pending (11 AM Slack): Boca Raton visits move from the "Broward" group to their city, which is
--    Diego's 2026-10-29 rule for every non-Broward client. Not changed.
--  - The pdf-service FDEP sheet prints "Palm Beach" in its County field (true). The Client App / Calendar badges read
--    "Palm Beach".
--  - Jobber: nothing is sent (trg_properties_enqueue_outbound fires only on trap size and lock box).
--  - properties is audited (audit_properties): every old value is in audit.logs; a JSON copy of the 15 rows is in the
--    workspace backups/ folder (backups/2026-11-02_boca_raton_county_before.json).
--  - New Boca Raton properties: webhook-jobber inferCountyFromCity is changed in the same cycle (edge deploy).
--
-- ROLLBACK: UPDATE public.properties SET county = 'Broward' WHERE id IN (<the 15 ids>) AND county = 'Palm Beach';

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $move$
DECLARE n int;
BEGIN
  UPDATE public.properties SET county = 'Palm Beach'
   WHERE id IN (4, 53, 62, 68, 291, 668, 1012, 1117, 563, 671, 675, 678, 820, 846, 1116)
     AND lower(btrim(city)) = 'boca raton' AND county = 'Broward';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 15 THEN RAISE EXCEPTION 'Boca Raton move: % rows, predicted 15', n; END IF;
  IF EXISTS (SELECT 1 FROM public.properties WHERE lower(btrim(city)) = 'boca raton' AND county IS DISTINCT FROM 'Palm Beach') THEN
    RAISE EXCEPTION 'Boca Raton move VERIFY: a Boca Raton property is still not Palm Beach';
  END IF;
  IF (SELECT count(*) FROM sync.outbound_queue WHERE created_at > now() - interval '1 minute' AND entity_type = 'property') > 0 THEN
    RAISE EXCEPTION 'Boca Raton move VERIFY: something was queued for Jobber';
  END IF;
END $move$;

COMMIT;
