-- 2026-07-20e edit_manifest: COALESCE-guard dump_ticket_date and disposal_facility_id
--
-- WHY: public.edit_manifest assigned both fields bare:
--     dump_ticket_date     = p_dump_date,
--     disposal_facility_id = p_disposal_facility_id,
-- while the URL slots immediately below them already used COALESCE(p_x, dm.x). That asymmetry is the
-- tell: the guarding pattern was known and applied to the URLs, and these two were missed.
--
-- The UPDATE deliberately hits EVERY live row in the (number, jurisdiction) group, which is correct for
-- a shared dump ticket. Combined with an unguarded NULL, that is the problem: one submit carrying an
-- empty dump-date or facility field would wipe those two columns across the whole ticket group in one
-- atomic statement.
--
-- MEASURED BLAST RADIUS (2026-07-20): 85 white-number groups hold more than one live manifest, the
-- largest holds 19, and 498 of 535 live manifests (93%) sit in a multi-row group. So the typical failure
-- is not one row, it is a whole ticket.
--
-- HAS IT FIRED? No. Verified 2026-07-20: 535 live manifests, 0 with a NULL dump_ticket_date, 0 with a
-- NULL disposal_facility_id.
--
-- ⚠ THE SCOPE IS NARROWER THAN THE SOURCE SUGGESTS, AND THIS IS THE INTERESTING PART. Reading the
-- function alone says "any NULL wipes the whole group". Testing it says otherwise: the BEFORE trigger
-- trg_derm_inherit_ticket_fields (fn_derm_inherit_ticket_fields) backfills a NULL dump_ticket_date /
-- disposal_facility_id FROM A SIBLING on the same ticket number, but only when a sibling exists
-- (s.id IS DISTINCT FROM NEW.id) and the siblings agree unanimously (HAVING count(DISTINCT ...) = 1).
-- In a multi-row group each row's BEFORE trigger still sees its siblings' pre-statement values, so the
-- group heals itself and NOTHING is lost.
--
-- Proven empirically in rolled-back transactions on 2026-07-20:
--   * multi-row ticket 819643 (8 rows), NULL date + NULL facility  -> values PRESERVED (trigger rescued)
--   * SOLO ticket 812737 (manifest 776, alone on its number)       -> WIPED to NULL / NULL  <-- the bug
-- So the exposure is exactly the manifests with no sibling to inherit from: 14 solo white numbers today.
--
-- That also means the safety net is two accidents deep and both are circumstantial: the DERM Tracker
-- Edit dialog happens to re-send both columns (its own 12-column fetch), AND most tickets happen to have
-- siblings. A solo ticket edited by any caller that omits a field loses both values with no warning.
--
-- Reported by the Building Apps session 2026-07-20; independently re-verified here (function source,
-- null counts, and group sizes) before changing anything.
--
-- WHAT CHANGES: NULL now means "leave as is" for these two columns, matching how the URL slots already
-- behave. Passing a real value still overwrites, so no legitimate edit is affected.
--
-- DELIBERATE CONSEQUENCE: you can no longer NULL these two columns THROUGH THIS FUNCTION. That is the
-- intent. A DERM manifest with no dump date or no disposal facility is not a meaningful compliance
-- record (the facility also drives the FP decal and the jurisdiction display), and 0 of 535 live rows do
-- it. Clearing one is an exceptional admin action and should be an explicit statement, not a side effect
-- of an empty form field.
--
-- NOTHING ELSE IS TOUCHED: same signature, same group-wide WHERE, same number/jurisdiction swap logic,
-- same URL array handling, same exceptions.
--
-- AUDIT (ADR 010): public.derm_manifests is audited; unchanged by this migration.

CREATE OR REPLACE FUNCTION public.edit_manifest(
  p_old_number text,
  p_old_jurisdiction text,
  p_new_number text,
  p_new_jurisdiction text,
  p_dump_date date,
  p_disposal_facility_id bigint,
  p_derm_manifest_url text DEFAULT NULL::text,
  p_derm_address_url text DEFAULT NULL::text,
  p_derm_manifest_urls text[] DEFAULT NULL::text[],
  p_derm_address_urls text[] DEFAULT NULL::text[]
)
RETURNS SETOF derm_manifests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_old_dade boolean := position('dade' in lower(coalesce(p_old_jurisdiction, ''))) > 0;
  v_new_dade boolean := position('dade' in lower(coalesce(p_new_jurisdiction, ''))) > 0;
  -- Normalize provided arrays: drop NULL/blank entries, preserve order (element 1 = primary).
  v_man_arr  text[] := CASE WHEN p_derm_manifest_urls IS NULL THEN NULL
                            ELSE COALESCE((SELECT array_agg(u ORDER BY ord)
                                             FROM unnest(p_derm_manifest_urls) WITH ORDINALITY AS t(u, ord)
                                            WHERE nullif(btrim(u), '') IS NOT NULL), ARRAY[]::text[]) END;
  v_addr_arr text[] := CASE WHEN p_derm_address_urls IS NULL THEN NULL
                            ELSE COALESCE((SELECT array_agg(u ORDER BY ord)
                                             FROM unnest(p_derm_address_urls) WITH ORDINALITY AS t(u, ord)
                                            WHERE nullif(btrim(u), '') IS NOT NULL), ARRAY[]::text[]) END;
BEGIN
  IF coalesce(p_old_number, '') = '' OR coalesce(p_new_number, '') = '' THEN
    RAISE EXCEPTION 'edit_manifest: manifest number is required' USING ERRCODE = '22023';
  END IF;

  -- Update every live row in the OLD (number, jurisdiction) group, in one atomic statement.
  RETURN QUERY
  UPDATE public.derm_manifests dm SET
    white_manifest_number = CASE WHEN v_new_dade THEN p_new_number ELSE NULL END,
    yellow_ticket_number  = CASE WHEN v_new_dade THEN NULL ELSE p_new_number END,
    -- ⚠ COALESCE, not a bare assignment: this UPDATE spans the whole ticket group (up to 19 rows), so an
    -- empty form field here would wipe the dump date / facility across every manifest on the ticket.
    -- NULL means "leave as is", exactly like the URL slots below. Do NOT "simplify" these back.
    dump_ticket_date      = COALESCE(p_dump_date, dm.dump_ticket_date),
    disposal_facility_id  = COALESCE(p_disposal_facility_id, dm.disposal_facility_id),
    -- MANIFEST slot: authoritative array wins; else legacy single-url COALESCE, extras untouched.
    derm_manifest_url = CASE
        WHEN p_derm_manifest_urls IS NOT NULL THEN v_man_arr[1]
        ELSE COALESCE(p_derm_manifest_url, dm.derm_manifest_url) END,
    derm_manifest_extra_urls = CASE
        WHEN p_derm_manifest_urls IS NOT NULL THEN v_man_arr[2:cardinality(v_man_arr)]
        ELSE dm.derm_manifest_extra_urls END,
    -- ADDRESS slot
    derm_address_url = CASE
        WHEN p_derm_address_urls IS NOT NULL THEN v_addr_arr[1]
        ELSE COALESCE(p_derm_address_url, dm.derm_address_url) END,
    derm_address_extra_urls = CASE
        WHEN p_derm_address_urls IS NOT NULL THEN v_addr_arr[2:cardinality(v_addr_arr)]
        ELSE dm.derm_address_extra_urls END
  WHERE dm.deleted_at IS NULL
    AND ( (v_old_dade     AND dm.white_manifest_number = p_old_number)
       OR (NOT v_old_dade AND dm.yellow_ticket_number  = p_old_number) )
  RETURNING dm.*;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'edit_manifest: no live manifest found for % #%', p_old_jurisdiction, p_old_number
      USING ERRCODE = 'P0002';
  END IF;

EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'edit_manifest: a manifest numbered % is already filed for one of these clients', p_new_number
      USING ERRCODE = '23505';
END;
$function$;
