-- 2026-07-07_adopt_sibling_white_number.sql
-- Fred: #298064 shows 10 visits in the DERM App but only 9 cards in Stamp. NOT the
-- deleted-manifest class (all cards point at live manifests). Root cause: #298064
-- has 11 client-manifests, but m679 (144-LTG) has white_manifest_number = NULL and
-- only yellow_ticket_number = '298064', while its 10 siblings all have
-- white_manifest_number = '298064'. Stamp keys every sheet/card by white#, so m679
-- is invisible and no card ever materialized for 144-LTG. (The DERM App groups by a
-- broader key, so it shows all 10 linked visits.)
--
-- Fleet scope: exactly 2 live manifests have white# NULL —
--   * m679 (144-LTG, yellow 298064): its ticket HAS 10 white#-keyed siblings -> it's
--     a Miami-Dade white manifest just MISSING the number. FIX (this migration).
--   * m512 (010-CS Chima, yellow 296623): 0 white#-keyed siblings -> a genuine
--     Broward-only ticket with no white manifest -> correctly absent from Stamp. LEFT.
--
-- FIX (structural + data):
--   1. NEW BEFORE trigger trg_ab_adopt_sibling_white on public.derm_manifests: when a
--      manifest is filed with white# NULL but a yellow_ticket_number that MATCHES a
--      live sibling carrying a white#, adopt that white#. Auto-heals the "on a white
--      ticket but the white# wasn't captured" case for every FUTURE manifest, while
--      leaving true Broward-only tickets (no white siblings, e.g. 296623) untouched.
--      Fires before trg_derm_inherit_ticket_fields (name ab < derm) so sibling
--      inheritance sees the adopted white#.
--   2. Heal m679 -> white_manifest_number = '298064'.
--   3. Materialize the 144-LTG Stamp card on the 298064 sheet (none existed, since the
--      card-from-link/resolve triggers key on white# which was NULL). Unplaced pool
--      card matched to client 466 + m679, on the sheet's folder/image.
--
-- @Supabase (1): additive BEFORE trigger on shared public.derm_manifests (adopts a
-- white# only; composes with your trg_derm_inherit_ticket_fields, does not modify it).
-- Also fixes DERM Tracker's future filings that omit the white#. Consider capturing
-- white_manifest_number at file-time in DERM Tracker as the upstream belt.

BEGIN;

-- 1) preventive: adopt a sibling's white# when missing on a white-manifest ticket
CREATE OR REPLACE FUNCTION derm.fn_adopt_sibling_white_number()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_w text;
BEGIN
  IF NEW.white_manifest_number IS NULL AND NEW.yellow_ticket_number IS NOT NULL THEN
    SELECT s.white_manifest_number INTO v_w
      FROM public.derm_manifests s
     WHERE s.yellow_ticket_number = NEW.yellow_ticket_number
       AND s.white_manifest_number IS NOT NULL
       AND s.deleted_at IS NULL
       AND s.id IS DISTINCT FROM NEW.id
     ORDER BY s.id LIMIT 1;
    IF v_w IS NOT NULL THEN NEW.white_manifest_number := v_w; END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_ab_adopt_sibling_white ON public.derm_manifests;
CREATE TRIGGER trg_ab_adopt_sibling_white
BEFORE INSERT OR UPDATE OF white_manifest_number, yellow_ticket_number ON public.derm_manifests
FOR EACH ROW EXECUTE FUNCTION derm.fn_adopt_sibling_white_number();

-- 2) heal m679 (144-LTG on ticket 298064)
UPDATE public.derm_manifests
   SET white_manifest_number = '298064'
 WHERE id = 679 AND white_manifest_number IS NULL AND yellow_ticket_number = '298064';

-- 3) materialize the 144-LTG card on the 298064 sheet (if none exists)
INSERT INTO derm.address_row_map
  (dump_folder, white_manifest_number, page, row_index, image_url,
   matched_client_id, matched_manifest_id, assignment_status, confidence, source, flags)
SELECT 'window10-sheet4', '298064', 1,
   (SELECT COALESCE(max(row_index),0)+1 FROM derm.address_row_map WHERE dump_folder='window10-sheet4' AND page=1),
   (SELECT min(image_url) FROM derm.address_row_map WHERE white_manifest_number='298064' AND image_url <> 'pending'),
   466, 679, 'matched', 'high', 'derm-link', '{"card_from_link":true,"white_number_backfill":true}'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM derm.address_row_map WHERE white_manifest_number='298064' AND matched_client_id=466);

COMMIT;
