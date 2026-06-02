-- 2026-06-02 — file_manifest(): dedup visit_ids so a repeated visit can't fake a "duplicate manifest" error.
-- Applied via Mgmt API from the Building Apps session (Fred-authorized; Supabase session busy).
-- Audit: function change only (no data); the RPC stays SECURITY DEFINER, grants unchanged (anon/authenticated/service_role).
--
-- BUG (diagnosed from a real report — Fred filing #825906 got "Manifest 825906 is already filed for this client"):
--   The /upload save calls file_manifest(), which INSERTs the derm_manifests row then INSERTs the manifest_visits
--   links via `SELECT v_id, vid FROM unnest(p_visit_ids)` — with NO de-dup. If p_visit_ids contains the same
--   visit_id twice (the matcher can list a visit more than once / selection state can repeat it), the second link
--   row violates manifest_visits_pkey (manifest_id, visit_id) -> 23505. file_manifest is atomic, so the WHOLE txn
--   rolls back (the manifest never persists — confirmed: #825906 has ZERO rows AND zero audit.logs history).
--   The frontend catch maps ANY 23505 to "Manifest {n} is already filed for this client" — so a duplicate VISIT
--   masquerades as a duplicate NUMBER. Misleading + blocks a legitimate filing.
--
-- FIX: dedup the array (DISTINCT) and add ON CONFLICT DO NOTHING (defensive). The derm_manifests unique indexes
--   (client_id, white/yellow number) WHERE deleted_at IS NULL are untouched, so a GENUINE duplicate number still
--   raises 23505 from the derm_manifests INSERT (correct "already filed"). Only the spurious dup-visit_id 23505 is removed.
--
-- Verified with rolled-back DO-block tests (RAISE EXCEPTION -> zero residue):
--   * before: file_manifest(..., ARRAY[1511,1511]) -> 23505 on manifest_visits_pkey (1167,1511).
--   * after:  file_manifest(..., ARRAY[1511,1511]) -> success, links=1 (deduped).
--   * after:  file_manifest(214-MYK client, '825560', ...) where that client already has a LIVE 825560
--             -> still 23505 on derm_manifests_client_wm_unique (real-dup protection preserved).

CREATE OR REPLACE FUNCTION public.file_manifest(
  p_client_id bigint, p_jurisdiction text, p_number text,
  p_disposal_facility_id bigint, p_dump_date date, p_visit_ids bigint[]
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO public.derm_manifests (
    white_manifest_number, yellow_ticket_number,
    dump_ticket_date, service_date, disposal_facility_id, client_id
  ) VALUES (
    CASE WHEN p_jurisdiction = 'Miami-Dade' THEN p_number ELSE NULL END,
    CASE WHEN p_jurisdiction = 'Broward'    THEN p_number ELSE NULL END,
    p_dump_date, p_dump_date, p_disposal_facility_id, p_client_id
  )
  RETURNING id INTO v_id;

  IF p_visit_ids IS NOT NULL AND array_length(p_visit_ids, 1) > 0 THEN
    INSERT INTO public.manifest_visits (manifest_id, visit_id)
    SELECT DISTINCT v_id, vid FROM unnest(p_visit_ids) AS vid
    ON CONFLICT (manifest_id, visit_id) DO NOTHING;
  END IF;

  RETURN v_id;
END;
$function$;
