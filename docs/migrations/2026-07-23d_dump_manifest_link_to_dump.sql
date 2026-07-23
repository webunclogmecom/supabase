-- 2026-07-23d  DUMP: link OLDER VISITS to a specific dump (pick-a-dump flow)
--
-- WHY (Fred 2026-07-23): when a driver documents older undocumented visits from VIEW ADDRESSES ->
-- OLDER VISITS, they now pick WHICH dump those pickups were dumped on, so the visit is linked to that
-- dump (not left unattached) and the Slack alert can name the dump. This is the batch writer the OLDER
-- VISITS "ADD TO MANIFEST" step calls after the driver picks a dump.
--
-- dump_manifest_link(driver, dump_visit_id, visit_ids[]) upserts each genuinely-outstanding visit into
-- the ledger with dump_visit_id = the chosen dump (source 'addresses'), and returns the linked clients so
-- the edge fn can build the "added to the [dump] manifest" alert. p_dump_visit_id must be a LIVE dump
-- visit (client 365/76, not soft-deleted) — otherwise it's a no-op (returns nothing).
--
-- Reuses the same ledger + guards as dump_manifest_mark / _confirm; the only new thing is that the mark
-- carries a real dump_visit_id instead of NULL. AUDIT: dump_manifest_handout is already audited.
-- service_role-only (the edge fn); anon stays read-only.

CREATE OR REPLACE FUNCTION public.dump_manifest_link(p_driver_id bigint, p_dump_visit_id bigint, p_visit_ids bigint[])
 RETURNS TABLE(visit_id bigint, client_code text, client_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_ids bigint[] := COALESCE(p_visit_ids, ARRAY[]::bigint[]);
BEGIN
  -- the target must be a live dump visit; otherwise link nothing
  IF NOT EXISTS (
    SELECT 1 FROM public.visits v
    WHERE v.id = p_dump_visit_id AND v.client_id IN (365, 76) AND v.deleted_at IS NULL
  ) THEN
    RETURN;
  END IF;

  -- link each genuinely-outstanding ticked visit to this dump
  INSERT INTO public.dump_manifest_handout (visit_id, dump_visit_id, driver_id, source, handed_at)
  SELECT o.visit_id, p_dump_visit_id, p_driver_id, 'addresses', now()
  FROM public.dump_outstanding_visits o
  WHERE o.visit_id = ANY (v_ids)
  ON CONFLICT (visit_id) DO UPDATE
    SET dump_visit_id = p_dump_visit_id, driver_id = p_driver_id, source = 'addresses', handed_at = now();

  RETURN QUERY
  SELECT o.visit_id, o.client_code, o.client_name
  FROM public.dump_outstanding_visits o
  JOIN public.dump_manifest_handout h ON h.visit_id = o.visit_id AND h.dump_visit_id = p_dump_visit_id
  WHERE o.visit_id = ANY (v_ids)
  ORDER BY o.completed_at DESC NULLS LAST;
END;
$function$;

REVOKE ALL ON FUNCTION public.dump_manifest_link(bigint, bigint, bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dump_manifest_link(bigint, bigint, bigint[]) TO service_role;
