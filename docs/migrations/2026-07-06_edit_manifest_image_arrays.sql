-- 2026-07-06_edit_manifest_image_arrays.sql
-- Fix: DERM Tracker Edit-modal image removals were SILENTLY DROPPED, so a manifest
-- (e.g. #826477) kept showing removed sheets even after refresh.
--
-- Two defects (workflow-verified on Prod):
--   A) public.edit_manifest had NO parameter for the image *arrays* — it only took
--      single p_derm_manifest_url / p_derm_address_url written as COALESCE(new, old),
--      so a ✕-remove (which shortens an extras[] or clears a primary) had no DB channel
--      and was dropped. (audit.logs: zero derm-tracker image writes since 2026-06-05.)
--   B) derm.manifests DISTINCT-unions sheets across every derm_manifests row sharing the
--      manifest number, so even a per-row removal is re-added by sibling rows.
--
-- Fix: give edit_manifest the authoritative desired image SETS per slot and write them
-- across the WHOLE (number,jurisdiction) group in its existing single atomic UPDATE.
-- Passing the reduced set to all rows drops the sheet everywhere -> the view union shrinks.
-- The manifests view is intentionally LEFT UNCHANGED (do not de-union — that re-opens the
-- split-sheets gap the 2026-07-01 union migration fixed).
--
-- Contract for the array params (both DEFAULT NULL):
--   NULL           -> leave that slot untouched (legacy behaviour; old 8-arg callers keep working)
--   '{}'           -> clear that slot entirely (primary NULL, extras {})
--   '{a,b,c}'      -> primary=a, extras={b,c}  (element 1 is the primary)
-- When the array is provided it is AUTHORITATIVE and overrides the single-url params.
-- Applied to Prod wbasvhvvismukaqdnouk via Management API.
--
-- Audit: derm_manifests is in the audited set (ADR 010) — no change to that; every group
-- UPDATE continues to log per row.

DROP FUNCTION IF EXISTS public.edit_manifest(text, text, text, text, date, bigint, text, text);

CREATE OR REPLACE FUNCTION public.edit_manifest(
  p_old_number         text,
  p_old_jurisdiction   text,
  p_new_number         text,
  p_new_jurisdiction   text,
  p_dump_date          date,
  p_disposal_facility_id bigint,
  p_derm_manifest_url  text   DEFAULT NULL,
  p_derm_address_url   text   DEFAULT NULL,
  p_derm_manifest_urls text[] DEFAULT NULL,   -- NEW: authoritative manifest sheet set (primary + extras)
  p_derm_address_urls  text[] DEFAULT NULL     -- NEW: authoritative address sheet set (primary + extras)
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
    dump_ticket_date      = p_dump_date,
    disposal_facility_id  = p_disposal_facility_id,
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

GRANT EXECUTE ON FUNCTION public.edit_manifest(text, text, text, text, date, bigint, text, text, text[], text[])
  TO anon, authenticated, service_role;
