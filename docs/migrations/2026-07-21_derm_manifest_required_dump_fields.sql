-- 2026-07-21  derm_manifests: make "dump date + disposal facility" a real requirement
--
-- ============================================================================
-- WHY
-- ============================================================================
-- Fred, 2026-07-21, describing the actual paper flow:
--   "The truck driver gets the DERM address manifest, and he gives it to the city. And until he
--    gives it to the city, we don't get that DERM address manifest. After he gives it to the city,
--    Diego will read that manifest and upload it to the DERM app. Once it's there, the rest is
--    linking the visits."
--
-- So a derm_manifests row is BORN COMPLETE. The upload is the creation event and it happens LAST,
-- with the finished paper sheet in hand: the dump date and the disposal facility are printed on it.
-- Linking visits is a separate, later step against public.manifest_visits. There is therefore no
-- legitimate state in which a live manifest lacks either field.
--
-- The schema did not say any of that. Both columns were nullable and nothing enforced them.
--
-- ============================================================================
-- THE TRAP THAT ALMOST BURIED THIS (read before "verifying" anything here)
-- ============================================================================
-- A spot check says the invariant already holds: 539 live manifests, 0 NULL dump dates,
-- 0 NULL facilities. That number is WORTHLESS AS EVIDENCE. It is six days old and manufactured:
--   * 480 of the 539 live rows had their facility filled in during July 2026.
--   * 387 of those in ONE `app_source='sql'` batch on 2026-07-15.
--   * The DERM Tracker shipped a validation on 2026-07-15 whose own changelog scopes it as
--     "UI validation only, no data/RPC/Supabase change" — i.e. a browser-side check, nothing more.
-- Nothing server-side had changed. Every writer that produced those NULLs was still deployed.
-- Historically 213 INSERTs landed a NULL facility (160 sql, 32 pre-attribution, 20 derm-tracker,
-- 1 derm-stamp-studio), the most recent from the DERM Tracker itself on 2026-07-07.
--
-- Second trap: fn_derm_inherit_ticket_fields silently backfills a NULL dump date / facility from a
-- unanimous ticket sibling, so testing a random row makes any of this look harmless. It rescues
-- NOTHING when the ticket is new, when all siblings are NULL, or when siblings disagree.
-- 15 live rows are singletons on their ticket. TEST AGAINST A SINGLETON OR A FRESH TICKET NUMBER
-- or you will get a false pass. (CHECK constraints evaluate AFTER BEFORE-triggers, so the trigger
-- still gets its chance to heal a row before the constraint below judges it. That is intended.)
--
-- ============================================================================
-- WHAT WAS ACTUALLY WRITING NULLs  (all four verified against Prod before this migration)
-- ============================================================================
-- 1. webhook-airtable handleDermRecord. SEVERED separately in this same commit (ENTITY_TO_HANDLER).
--    disposal_facility_id appears ZERO times in that file and the `hasData` gate admits a row on a
--    URL alone with no dump date. It inserted exactly such rows (manifests 1245/1250/1251, 06-30).
--    Its `.update(row)` also sent null-valued keys, wiping the dump date on manifests 1061/579/999.
-- 2. public.file_manifest — the DERM Tracker /upload RPC. Bare INSERT, no guard. FIXED BELOW.
-- 3. public.file_manifest_on_shared_ticket — copies the dump fields from a sibling chosen by
--    DOCUMENT RICHNESS, so it happily copies that sibling's NULLs. 6 of 6 inserts through this RPC
--    on 2026-07-07 landed a NULL facility. FIXED BELOW.
-- 4. derm.file_manifest_and_link — same sibling-copy flaw, AND it is missing the
--    `IF sib.id IS NULL THEN RAISE` guard that its twin has, so a first-of-ticket filing inserts an
--    all-NULL sibling record outright. Latent today (0 qualifying rows) but real. FIXED BELOW.
--
-- NOT a NULL source, despite appearances: there has never been a single UPDATE that changed a
-- non-NULL disposal_facility_id to NULL. Queries that "find" some are matching DELETE audit rows,
-- where new_row is NULL by construction. Filter operation='UPDATE'. NULLs arrive at INSERT time,
-- which is why this migration guards inserts and not writes-back.
--
-- public.edit_manifest is already safe (COALESCE-guarded in 2026-07-20e) and is left untouched.
--
-- ============================================================================
-- WHAT CHANGES
-- ============================================================================
-- A. file_manifest raises a readable 22023 instead of letting a NULL through.
-- B. Both sibling-copy filers resolve the dump fields from ANY sibling on the ticket that has them,
--    independently of which sibling supplies the documents, and raise a readable 22023 if the whole
--    ticket has none. Document inheritance is UNCHANGED — still the best-documented sibling.
-- C. derm.file_manifest_and_link gains the missing no-sibling guard.
-- D. A CHECK constraint makes it structural, so a writer nobody audited cannot reintroduce it.
--
-- The order matters and is deliberate: the writers are fixed BEFORE the constraint is added.
-- Adding the constraint first would convert silent NULLs into hard 23514s in Diego's face.
--
-- ============================================================================
-- WHY `NOT VALID`
-- ============================================================================
-- NOT VALID still fully enforces every INSERT and UPDATE from here on. It only skips the scan of
-- pre-existing rows. That is what we want, because 7 soft-deleted rows (1250, 1052, 962, 300, 284,
-- 775, 530) carry a NULL facility and are historical residue, not something to rewrite. It also
-- avoids an ACCESS EXCLUSIVE full-table validation pass.
-- CONSEQUENCE, STATED PLAINLY: `ALTER TABLE ... VALIDATE CONSTRAINT` will FAIL while those 7 rows
-- exist. The constraint is intentionally parked NOT VALID. Do not "fix" that by deleting them.
--
-- ============================================================================
-- WHAT A CALLER SEES NOW
-- ============================================================================
--   via the RPCs      -> 22023 with a plain-English message (the app can surface it verbatim)
--   via a raw write   -> 23514 new row violates check constraint
--                        "derm_manifests_dump_fields_present_chk"
-- The DERM Tracker currently maps friendly errors for 23505 only. It should map 22023 too, or
-- Diego will see a raw Postgres string. Flagged to the app side, not fixed here.
--
-- NOT TOUCHED: service_date. It is left nullable DESPITE the data supporting a constraint (0 of 546
-- live rows are NULL), because its semantics are already muddled: per the documented gotcha it
-- actually holds the DUMP date, not the service date, and file_manifest sets it to p_dump_date
-- outright. Constraining a field whose meaning is disputed would cement the confusion rather than
-- fix it. Straighten out what service_date means first, then decide. Also untouched:
-- manifest_visits, edit_manifest, the existing derm_manifests_service_before_dump_chk, every view,
-- every RLS policy.
--
-- AUDIT (ADR 010): public.derm_manifests is already audited; this migration changes no trigger and
-- no audit opt-in. Function bodies change, audit behaviour does not.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- A. public.file_manifest — the primary DERM Tracker filing RPC
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.file_manifest(
  p_client_id bigint,
  p_jurisdiction text,
  p_number text,
  p_disposal_facility_id bigint,
  p_dump_date date,
  p_visit_ids bigint[]
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_id bigint;
BEGIN
  -- A manifest is only uploaded AFTER it returns from the city, so both of these are on the sheet
  -- in front of whoever is filing it. A blank here means the form was submitted incomplete, not
  -- that the value is unknowable. Raise something Diego can read rather than letting the CHECK
  -- constraint surface a raw 23514.
  IF p_dump_date IS NULL OR p_disposal_facility_id IS NULL THEN
    RAISE EXCEPTION 'Dump date and disposal facility are both required to file a manifest (they are printed on the sheet). Got dump date %, facility %.',
      coalesce(p_dump_date::text, 'blank'), coalesce(p_disposal_facility_id::text, 'blank')
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.derm_manifests
    (white_manifest_number, yellow_ticket_number, dump_ticket_date, service_date,
     disposal_facility_id, client_id)
  VALUES
    (CASE WHEN p_jurisdiction = 'Miami-Dade' THEN p_number ELSE NULL END,
     CASE WHEN p_jurisdiction = 'Broward'    THEN p_number ELSE NULL END,
     p_dump_date, p_dump_date, p_disposal_facility_id, p_client_id)
  RETURNING id INTO v_id;

  IF p_visit_ids IS NOT NULL AND array_length(p_visit_ids, 1) > 0 THEN
    INSERT INTO public.manifest_visits (manifest_id, visit_id)
    SELECT DISTINCT v_id, vid FROM unnest(p_visit_ids) AS vid
    ON CONFLICT (manifest_id, visit_id) DO NOTHING;
  END IF;

  RETURN v_id;
END; $function$;


-- ----------------------------------------------------------------------------
-- B. public.file_manifest_on_shared_ticket — the sanctioned co-loaded-ticket path
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.file_manifest_on_shared_ticket(
  p_white_manifest_number text,
  p_client_id bigint,
  p_visit_id bigint,
  OUT manifest_id bigint,
  OUT created boolean,
  OUT linked boolean
)
RETURNS record
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'derm'
AS $function$
DECLARE
  v_wm text := btrim(p_white_manifest_number);   -- the TICKET number (white, or yellow for Broward-only)
  v_vcid bigint; v_vdate date; v_vcode text; v_ccode text; v_rows int;
  v_yellow_key boolean;
  v_fac bigint; v_dump date;
  sib public.derm_manifests%ROWTYPE;
BEGIN
  IF coalesce(v_wm, '') = '' THEN
    RAISE EXCEPTION 'p_white_manifest_number required';
  END IF;
  IF p_client_id IS NULL OR p_visit_id IS NULL THEN
    RAISE EXCEPTION 'p_client_id and p_visit_id required';
  END IF;

  SELECT v.client_id, v.visit_date INTO v_vcid, v_vdate
    FROM public.visits v WHERE v.id = p_visit_id AND v.deleted_at IS NULL;
  IF v_vcid IS NULL THEN
    RAISE EXCEPTION 'visit % not found or deleted', p_visit_id;
  END IF;
  IF v_vcid <> p_client_id THEN
    SELECT client_code INTO v_vcode FROM public.clients WHERE id = v_vcid;
    SELECT client_code INTO v_ccode FROM public.clients WHERE id = p_client_id;
    RAISE EXCEPTION 'visit % belongs to % — call this RPC with that client, not %',
      p_visit_id, coalesce(v_vcode, v_vcid::text), coalesce(v_ccode, p_client_id::text);
  END IF;

  -- find-or-create the (ticket, client) row (ticket key = COALESCE(white#, yellow#))
  SELECT dm.id INTO manifest_id FROM public.derm_manifests dm
   WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = v_wm AND dm.client_id = p_client_id
     AND dm.deleted_at IS NULL
   ORDER BY dm.id LIMIT 1;
  created := manifest_id IS NULL;

  IF created THEN
    -- DOCUMENT source: unchanged. Best-documented sibling wins (the old hard
    -- "derm_manifest_url IS NOT NULL" filter inherited NOTHING from an address-doc-only sibling).
    SELECT * INTO sib FROM public.derm_manifests dm
     WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = v_wm AND dm.deleted_at IS NULL
     ORDER BY (dm.derm_manifest_url IS NOT NULL) DESC,
              (dm.derm_address_url IS NOT NULL) DESC, dm.id
     LIMIT 1;
    IF sib.id IS NULL THEN
      RAISE EXCEPTION 'no manifest exists on ticket % to share docs from — file the first manifest through the normal flow', v_wm;
    END IF;

    -- DUMP-FIELD source: resolved INDEPENDENTLY of the document source. The best-documented
    -- sibling is not necessarily a sibling that HAS these fields, and copying its NULLs is what
    -- put a NULL facility on 6 of 6 rows filed through this RPC on 2026-07-07. Take them from any
    -- sibling on the ticket that carries them (lowest id wins, deterministic).
    SELECT dm.disposal_facility_id INTO v_fac FROM public.derm_manifests dm
     WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = v_wm AND dm.deleted_at IS NULL
       AND dm.disposal_facility_id IS NOT NULL
     ORDER BY dm.id LIMIT 1;

    SELECT dm.dump_ticket_date INTO v_dump FROM public.derm_manifests dm
     WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = v_wm AND dm.deleted_at IS NULL
       AND dm.dump_ticket_date IS NOT NULL
     ORDER BY dm.id LIMIT 1;

    IF v_fac IS NULL OR v_dump IS NULL THEN
      RAISE EXCEPTION 'ticket % has no sibling carrying a dump date and disposal facility (dump date %, facility %) — fix the existing manifest on this ticket first',
        v_wm, coalesce(v_dump::text, 'missing'), coalesce(v_fac::text, 'missing')
        USING ERRCODE = '22023';
    END IF;

    -- yellow-keyed ticket (live yellow-only siblings, no white-keyed manifest, no split-key sibling)
    -- -> file with yellow_ticket_number, NOT white_manifest_number
    SELECT EXISTS (SELECT 1 FROM public.derm_manifests
                    WHERE yellow_ticket_number = v_wm AND white_manifest_number IS NULL AND deleted_at IS NULL)
       AND NOT EXISTS (SELECT 1 FROM public.derm_manifests
                    WHERE white_manifest_number = v_wm AND deleted_at IS NULL)
       AND NOT EXISTS (SELECT 1 FROM public.derm_manifests
                    WHERE yellow_ticket_number = v_wm AND white_manifest_number IS NOT NULL
                      AND white_manifest_number <> v_wm AND deleted_at IS NULL)
      INTO v_yellow_key;

    INSERT INTO public.derm_manifests
      (white_manifest_number, yellow_ticket_number, client_id, service_date,
       derm_manifest_url, derm_manifest_extra_urls,
       derm_address_url, derm_address_extra_urls,
       wwtp_receipt_document_path, disposal_facility_id, dump_ticket_date)
    VALUES
      (CASE WHEN v_yellow_key THEN NULL ELSE v_wm END,
       CASE WHEN v_yellow_key THEN v_wm ELSE NULL END,
       p_client_id, v_vdate,
       sib.derm_manifest_url, coalesce(sib.derm_manifest_extra_urls, '{}'::text[]),
       sib.derm_address_url,  coalesce(sib.derm_address_extra_urls,  '{}'::text[]),
       sib.wwtp_receipt_document_path, v_fac, v_dump)
    RETURNING id INTO manifest_id;
  END IF;

  INSERT INTO public.manifest_visits (manifest_id, visit_id)
    VALUES (manifest_id, p_visit_id) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  linked := v_rows > 0;
END $function$;


-- ----------------------------------------------------------------------------
-- C. derm.file_manifest_and_link — the Stamp Studio path
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.file_manifest_and_link(p_row_id bigint, p_visit_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_wm text; v_cid bigint; v_vcid bigint; v_vdate date; v_mid bigint;
  v_yellow_key boolean;
  v_fac bigint; v_dump date;
  v_sib public.derm_manifests%ROWTYPE;
BEGIN
  PERFORM derm._require_stamp_key();

  SELECT white_manifest_number, matched_client_id INTO v_wm, v_cid
    FROM derm.address_row_map WHERE id = p_row_id;
  IF v_wm IS NULL THEN
    RAISE EXCEPTION 'row % has no manifest number', p_row_id;
  END IF;
  IF v_cid IS NULL THEN
    RAISE EXCEPTION 'row % has no matched client — add a roster client first', p_row_id;
  END IF;

  SELECT client_id, visit_date INTO v_vcid, v_vdate
    FROM public.visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF v_vcid IS NULL THEN
    RAISE EXCEPTION 'visit % not found or deleted', p_visit_id;
  END IF;
  IF v_vcid <> v_cid THEN
    RAISE EXCEPTION 'visit % belongs to a different client than row %', p_visit_id, p_row_id;
  END IF;

  -- idempotent: reuse an existing (ticket, client) manifest if one exists (ticket key)
  SELECT id INTO v_mid FROM public.derm_manifests
    WHERE COALESCE(white_manifest_number, yellow_ticket_number) = v_wm AND client_id = v_cid AND deleted_at IS NULL
    ORDER BY id LIMIT 1;

  IF v_mid IS NULL THEN
    -- DOCUMENT source: best-documented ticket sibling (soft preference, matching
    -- file_manifest_on_shared_ticket).
    SELECT * INTO v_sib FROM public.derm_manifests
      WHERE COALESCE(white_manifest_number, yellow_ticket_number) = v_wm AND deleted_at IS NULL
      ORDER BY (derm_manifest_url IS NOT NULL) DESC, (derm_address_url IS NOT NULL) DESC, id
      LIMIT 1;

    -- ADDED 2026-07-21: the guard file_manifest_on_shared_ticket has always had and this one never
    -- did. Without it a first-of-ticket filing left v_sib as an all-NULL record and inserted
    -- NULL docs, NULL facility and NULL dump date outright. Latent (0 qualifying rows to date),
    -- real, and now impossible.
    IF v_sib.id IS NULL THEN
      RAISE EXCEPTION 'no manifest exists on ticket % to share docs from — file the first manifest through the normal flow', v_wm
        USING ERRCODE = '22023';
    END IF;

    -- DUMP-FIELD source: independent of the document source. See the note in
    -- file_manifest_on_shared_ticket — copying the doc-rich sibling's NULLs is the bug.
    SELECT disposal_facility_id INTO v_fac FROM public.derm_manifests
      WHERE COALESCE(white_manifest_number, yellow_ticket_number) = v_wm AND deleted_at IS NULL
        AND disposal_facility_id IS NOT NULL
      ORDER BY id LIMIT 1;

    SELECT dump_ticket_date INTO v_dump FROM public.derm_manifests
      WHERE COALESCE(white_manifest_number, yellow_ticket_number) = v_wm AND deleted_at IS NULL
        AND dump_ticket_date IS NOT NULL
      ORDER BY id LIMIT 1;

    IF v_fac IS NULL OR v_dump IS NULL THEN
      RAISE EXCEPTION 'ticket % has no sibling carrying a dump date and disposal facility (dump date %, facility %) — fix the existing manifest on this ticket first',
        v_wm, coalesce(v_dump::text, 'missing'), coalesce(v_fac::text, 'missing')
        USING ERRCODE = '22023';
    END IF;

    -- is this ticket YELLOW-keyed? (live yellow-only siblings carry the number, no white-keyed
    -- manifest does, and no sibling maps this yellow# to a DIFFERENT white# — a split-key group
    -- must not be silently filed into) — then file with yellow_ticket_number, NOT white#.
    SELECT EXISTS (SELECT 1 FROM public.derm_manifests
                    WHERE yellow_ticket_number = v_wm AND white_manifest_number IS NULL AND deleted_at IS NULL)
       AND NOT EXISTS (SELECT 1 FROM public.derm_manifests
                    WHERE white_manifest_number = v_wm AND deleted_at IS NULL)
       AND NOT EXISTS (SELECT 1 FROM public.derm_manifests
                    WHERE yellow_ticket_number = v_wm AND white_manifest_number IS NOT NULL
                      AND white_manifest_number <> v_wm AND deleted_at IS NULL)
      INTO v_yellow_key;

    INSERT INTO public.derm_manifests
      (white_manifest_number, yellow_ticket_number, client_id, service_date,
       derm_manifest_url, derm_address_url, derm_address_extra_urls,
       wwtp_receipt_document_path, disposal_facility_id, dump_ticket_date)
    VALUES
      (CASE WHEN v_yellow_key THEN NULL ELSE v_wm END,
       CASE WHEN v_yellow_key THEN v_wm ELSE NULL END,
       v_cid, v_vdate,
       v_sib.derm_manifest_url, v_sib.derm_address_url, coalesce(v_sib.derm_address_extra_urls, '{}'::text[]),
       v_sib.wwtp_receipt_document_path, v_fac, v_dump)
    RETURNING id INTO v_mid;

    UPDATE derm.address_row_map SET matched_manifest_id = v_mid WHERE id = p_row_id;
  END IF;

  INSERT INTO public.manifest_visits (manifest_id, visit_id)
    VALUES (v_mid, p_visit_id) ON CONFLICT DO NOTHING;

  RETURN v_mid;
END $function$;


-- ----------------------------------------------------------------------------
-- D. The structural guarantee
-- ----------------------------------------------------------------------------
-- Added LAST, after every writer above is fixed. Enforces all future INSERTs and UPDATEs.
ALTER TABLE public.derm_manifests
  ADD CONSTRAINT derm_manifests_dump_fields_present_chk
  CHECK (dump_ticket_date IS NOT NULL AND disposal_facility_id IS NOT NULL)
  NOT VALID;

COMMENT ON CONSTRAINT derm_manifests_dump_fields_present_chk ON public.derm_manifests IS
  'A DERM manifest is only uploaded AFTER the address sheet returns from the city, so the dump date '
  'and disposal facility are printed on the paper at creation time (Fred, 2026-07-21). Neither may '
  'be blank. Deliberately NOT VALID: 7 soft-deleted legacy rows carry a NULL facility, so VALIDATE '
  'CONSTRAINT will fail by design — do not delete them to make it pass. NOT VALID still enforces '
  'every INSERT and UPDATE. Callers going through file_manifest / file_manifest_on_shared_ticket / '
  'derm.file_manifest_and_link get a readable 22023 before ever reaching this constraint.';
