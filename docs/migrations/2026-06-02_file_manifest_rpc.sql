-- 2026-06-02 — public.file_manifest(): atomic manifest filing.
--
-- Why: the DERM /upload save was two separate requests — INSERT derm_manifests, then INSERT
-- manifest_visits — so a failure between them left an ORPHAN (a live manifest with no visit link).
-- This RPC does the insert + the visit links in ONE transaction (plpgsql function = single txn),
-- so a link failure rolls the manifest insert back too — no orphans. Called once per client by the
-- /upload split-per-client save loop. Photos / url-stamping stay a separate post-step (a photo
-- failure leaves a linked manifest without a PDF url — recoverable, NOT an orphan).
--
-- Uniqueness: a live (client, number) duplicate raises 23505 on the partial unique index and the
-- whole function rolls back; the app's pre-flight dup-check + 23505 catch handle messaging. No
-- ON CONFLICT (we want it to raise, per the "block with a clear message" decision).
--
-- Applied from the Building Apps session via Management API, Fred-authorized (Supabase session busy).

CREATE OR REPLACE FUNCTION public.file_manifest(
  p_client_id           bigint,
  p_jurisdiction        text,      -- 'Miami-Dade' or 'Broward'
  p_number              text,
  p_disposal_facility_id bigint,
  p_dump_date           date,
  p_visit_ids           bigint[]
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
    SELECT v_id, vid FROM unnest(p_visit_ids) AS vid;
  END IF;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.file_manifest(bigint, text, text, bigint, date, bigint[])
  TO anon, authenticated, service_role;
