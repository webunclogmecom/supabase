-- 2026-07-10_stamp_yellow_only_tickets.sql
-- Fred 2026-07-09: "Stamp is not showing the most recent manifest... it stopped at 07/06. It should
-- be showing all manifests."
--
-- ROOT CAUSE: the entire Stamp derm lane keys tickets by white_manifest_number, but the two newest
-- sheets were filed YELLOW-ONLY (white# NULL): ticket 308684 (07-07, 7 Broward/PBC clients) and
-- ticket 308792 (07-08, 7 Dade clients) — plus 1 historic (m512 Chima 010-CS, ticket 296623, 01-26).
-- 15 live yellow-only manifests total; the DERM Tracker's own derm.manifests view ALREADY groups by
-- COALESCE(white_manifest_number, yellow_ticket_number) and shows them as "Broward #<n>" — Stamp never
-- adopted that key, so: no ticket row in v_stamp_sheets, fn_card_from_link returned early (0 cards),
-- resolve/re-point triggers skipped them, add_sheet_client/file_manifest_and_link would refuse or
-- mis-file. The 07-07 adopt-sibling trigger (trg_ab_adopt_sibling_white) can't help: it adopts a white#
-- from white-keyed siblings, and these groups have NONE.
--
-- FIX: bring the Stamp lane onto the SAME group key the DERM app uses — the TICKET KEY
-- COALESCE(white_manifest_number, yellow_ticket_number) — everywhere it resolves manifests. Cards
-- (derm.address_row_map) keep storing the ticket key in their white_manifest_number column (the m679
-- precedent: that column is semantically "ticket number"). Collision-checked live: NO yellow# on a
-- white-NULL row equals any existing white# (derm_manifests or address_row_map) → key is unambiguous.
-- Both-NULL live manifests: 0.
--
-- CHANGES (all CREATE OR REPLACE — trigger bindings + grants preserved):
--   1. derm.ticket_page_images      — manifest lookups by ticket key
--   2. derm.fn_card_from_link       — card materialization works for yellow-only manifests
--   3. derm.fn_resolve_card_manifest— re-point on (re)file by ticket key
--   4. derm.fn_card_reptr_on_manifest_delete — sibling re-point by ticket key
--   5. derm.add_sheet_client        — client-manifest resolve by ticket key
--   6. derm.file_manifest_and_link  — find/inherit by ticket key + FILES the manifest under the
--      CORRECT column: if the sheet's ticket key is yellow-keyed (live yellow-only siblings exist and
--      no white-keyed manifest carries the number) the new manifest gets yellow_ticket_number=key /
--      white NULL, else white=key as before. (Previously it would have written a yellow ticket number
--      into white_manifest_number.)
--   7. derm.v_stamp_sheets          — tickets CTE + correlated subqueries by ticket key
--   8. derm.v_stamp_rows            — service_date subquery by ticket key
--   9. BACKFILL: materialize the missing cards for the 15 linked yellow-only manifests (idempotent
--      NOT EXISTS; mimics fn_card_from_link). Realtime inval on address_row_map auto-refreshes the app.
--
-- ADVERSARIAL REVIEW ADDITIONS (2-skeptic + consumer-sweep, wf_cd85b070; lens findings folded in):
--  10. trg_resolve_card_manifest firing columns +yellow_ticket_number (fn was rekeyed; its UPDATE OF
--      list wasn't — a yellow# correction would never re-point cards).
--  11. derm.v_stamp_linkage_gaps rekeyed by ticket key (HIGH: else the 15 backfilled cards instantly
--      become false "missing link" alarms — the view NOT-EXISTS'd white-keyed manifests only).
--  12. NEW invariant trigger trg_ae_ticket_key_unambiguous on derm_manifests: Dade white#s and Broward
--      yellow#s are independent 6-digit counters in one numeric space — a future white filing whose
--      number equals an existing yellow-only key (or vice versa) would SILENTLY MERGE two physical
--      tickets into one sheet (and could cross-link via find-or-create). Now RAISES instead.
--      ⚠ Restore gotcha (same class as the manifest_visits guards): replaying a backup containing a
--      colliding pair now RAISES — filter first. Fires 'ae' = after trg_ab_adopt_sibling_white, so it
--      validates post-adoption values.
--  13. public.fn_manifest_visit_one_white rekeyed to the ticket key: the one-dump-per-visit guard
--      silently no-op'd on yellow-only manifests (white NULL -> RETURN NEW) — the exact mis-link class
--      remediated 07-06/07 was unguarded for the new Broward-normal. 0 current escapes (verified).
--  14. public.file_manifest_on_shared_ticket (DERM Tracker Move/Attach RPC) rekeyed: it was white#-only
--      -> RAISED "no manifest exists on ticket X to share docs from" for EVERY yellow-only ticket (the
--      7-client co-loads it exists for). PRE-EXISTING break, fixed here since it's the same key class.
--      Param name p_white_manifest_number kept (PostgREST contract) — it now means "ticket number".
--  + file_manifest_and_link v_yellow_key gains a third clause (split-key groups: a live sibling with
--    the same yellow# but a DIFFERENT white# -> not yellow-keyed; the invariant trigger then surfaces
--    the ambiguous state instead of filing into the wrong group).
--  15. fn_manifest_visit_not_after_dump: rejection message shows the ticket # (was "ticket ?" for
--      yellow-only manifests; logic unchanged).
--  + card materialization refactored into shared derm._materialize_card(manifest_id), called by BOTH
--    trg_zz (link-time) and trg_resolve (key-entered-later) — closes the "Pending paperwork" gap: a
--    manifest visit-linked while BOTH numbers were NULL now gets its card when the number is typed in
--    (previously: never — fn_card_from_link had already no-op'd and fn_resolve only re-pointed).
--  + file_manifest_and_link sibling-inherit: soft best-documented ORDER BY (was hard derm_manifest_url
--    IS NOT NULL -> inherited NOTHING from an address-doc-only sibling like m512).
-- DEFERRED (pre-existing, cosmetic/low, follow-up chip): edit_manifest rename doesn't re-key cards;
-- derm.sheet_page_images superseded fn still white#-keyed; NULL ticket-number display in
-- v_orphan_manifests / audit_pack_client / manifest_number_proposals / manifest_detail.
--
-- ADR-010: no audited-table schema change; writes only derm.address_row_map (Stamp junction lane,
-- existing audit posture unchanged). public.derm_manifests/manifest_visits DATA untouched (backfill
-- writes cards only). Baseline snapshot: scratchpad v_stamp_sheets_before.json (95 sheets) — post-apply
-- diff must show the 95 unchanged + 3 new (ticket-296623, ticket-308684, ticket-308792).
-- Fred's display-criteria idea ("later I'll add a criteria to which manifest to show") = future filter
-- on v_stamp_sheets; this migration makes ALL tickets visible, per his current instruction.

BEGIN;

-- 1) ticket_page_images: resolve the ticket's manifests by ticket key ------------------------------
CREATE OR REPLACE FUNCTION derm.ticket_page_images(p_wm text)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_imgs    text[] := '{}';
  v_etags   text[] := '{}';
  v_m_etags text[];
  r record;
BEGIN
  -- the ticket's LIVE manifest image content set (ticket key = COALESCE(white#, yellow#))
  SELECT array_agg(DISTINCT e) INTO v_m_etags
  FROM (
    SELECT derm._img_etag(u) AS e
    FROM public.derm_manifests dm
    CROSS JOIN LATERAL unnest(
      array_remove(array_prepend(dm.derm_address_url, coalesce(dm.derm_address_extra_urls,'{}'::text[])), null)
    ) u
    WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = p_wm AND dm.deleted_at IS NULL
  ) s WHERE e IS NOT NULL;

  -- OCR pages first, appended UNCONDITIONALLY in page order (existing
  -- stamp_page indexes must never move). Per page, the image is the one MOST
  -- rows reference (mode) — not the URL-sort — so one stray synthesized card
  -- can't redefine a page. Only staleness gates a page out: when the manifests
  -- HAVE images, a page survives only if its content is still in that live set.
  FOR r IN
    SELECT p.img, derm._img_etag(p.img) AS etag
    FROM (SELECT page, mode() WITHIN GROUP (ORDER BY image_url) AS img
          FROM derm.address_row_map
          WHERE white_manifest_number = p_wm AND image_url <> 'pending'
          GROUP BY page) p
    ORDER BY p.page
  LOOP
    IF v_m_etags IS NOT NULL AND (r.etag IS NULL OR NOT (r.etag = ANY(v_m_etags))) THEN
      CONTINUE;  -- manifests are authoritative and no longer carry this content
    END IF;
    v_imgs := v_imgs || r.img;
    IF r.etag IS NOT NULL THEN v_etags := v_etags || r.etag; END IF;
  END LOOP;

  -- append LIVE manifest images whose content isn't already shown
  FOR r IN
    SELECT u AS img, derm._img_etag(u) AS etag
    FROM public.derm_manifests dm
    CROSS JOIN LATERAL unnest(
      array_remove(array_prepend(dm.derm_address_url, coalesce(dm.derm_address_extra_urls,'{}'::text[])), null)
    ) u
    WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = p_wm AND dm.deleted_at IS NULL
    GROUP BY u
    ORDER BY u
  LOOP
    IF r.etag IS NULL THEN CONTINUE; END IF;
    IF NOT (r.etag = ANY(v_etags)) THEN
      v_imgs  := v_imgs  || r.img;
      v_etags := v_etags || r.etag;
    END IF;
  END LOOP;
  RETURN v_imgs;
END $function$;

-- 2) Shared card materializer + fn_card_from_link (trg_zz_card_from_link): ticket key --------------
-- derm._materialize_card: create-or-repoint the Stamp card for a manifest's (ticket key, client).
-- ONE body shared by trg_zz (link-time) and trg_resolve (key-entered-later) so they can never drift.
CREATE OR REPLACE FUNCTION derm._materialize_card(p_manifest_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_wm text; v_cid bigint; v_folder text; v_img text; v_next int;
BEGIN
  SELECT COALESCE(white_manifest_number, yellow_ticket_number), client_id INTO v_wm, v_cid
    FROM public.derm_manifests WHERE id = p_manifest_id AND deleted_at IS NULL;
  IF v_wm IS NULL OR v_cid IS NULL THEN RETURN; END IF;

  IF EXISTS (SELECT 1 FROM derm.address_row_map r
              WHERE r.white_manifest_number = v_wm AND r.matched_client_id = v_cid) THEN
    UPDATE derm.address_row_map
       SET matched_manifest_id = p_manifest_id
     WHERE white_manifest_number = v_wm AND matched_client_id = v_cid
       AND matched_manifest_id IS NULL;
    RETURN;
  END IF;

  SELECT min(dump_folder) INTO v_folder FROM derm.address_row_map WHERE white_manifest_number = v_wm;
  v_folder := COALESCE(v_folder, 'ticket-' || v_wm);
  v_img := (derm.ticket_page_images(v_wm))[1];
  IF v_img IS NULL THEN
    SELECT derm_address_url INTO v_img FROM public.derm_manifests WHERE id = p_manifest_id;
  END IF;
  SELECT COALESCE(max(row_index), 0) + 1 INTO v_next
    FROM derm.address_row_map WHERE dump_folder = v_folder AND page = 1;

  BEGIN
    INSERT INTO derm.address_row_map
      (dump_folder, white_manifest_number, page, row_index, image_url,
       matched_client_id, matched_manifest_id, assignment_status, confidence, source, flags)
    VALUES
      (v_folder, v_wm, 1, v_next, COALESCE(v_img, 'pending'),
       v_cid, p_manifest_id, 'matched', 'high', 'derm-link', '{"card_from_link":true}'::jsonb);
  EXCEPTION WHEN unique_violation THEN
    NULL;  -- concurrent writer materialized it first; never abort the caller's write
  END;
END $function$;
REVOKE ALL ON FUNCTION derm._materialize_card(bigint) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION derm.fn_card_from_link()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
BEGIN
  PERFORM derm._materialize_card(NEW.manifest_id);
  RETURN NULL;
END $function$;

-- 3) fn_resolve_card_manifest (trg_resolve_card_manifest on derm_manifests): ticket key ------------
--    + closes the "Pending paperwork" gap: a manifest visit-linked while BOTH numbers were NULL never
--    got a card (fn_card_from_link fired at link-time with a NULL key); when the number is entered
--    later this trigger now MATERIALIZES the missing card, not just re-points existing ones.
CREATE OR REPLACE FUNCTION derm.fn_resolve_card_manifest()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_key text;
BEGIN
  v_key := COALESCE(NEW.white_manifest_number, NEW.yellow_ticket_number);
  IF NEW.deleted_at IS NULL AND v_key IS NOT NULL THEN
    UPDATE derm.address_row_map r
       SET matched_manifest_id = NEW.id
     WHERE r.white_manifest_number = v_key
       AND r.matched_client_id     = NEW.client_id
       AND ( r.matched_manifest_id IS NULL
          OR NOT EXISTS (SELECT 1 FROM public.derm_manifests m
                          WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL) );
    -- visit-linked but card-less (linked before the ticket # existed) -> create the card now
    IF EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id = NEW.id)
       AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                        WHERE r.white_manifest_number = v_key AND r.matched_client_id = NEW.client_id) THEN
      PERFORM derm._materialize_card(NEW.id);
    END IF;
  END IF;
  RETURN NULL;
END $function$;

-- 4) fn_card_reptr_on_manifest_delete (trg_ad_card_reptr_on_delete): ticket key --------------------
CREATE OR REPLACE FUNCTION derm.fn_card_reptr_on_manifest_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
BEGIN
  UPDATE derm.address_row_map r
     SET matched_manifest_id = (
           SELECT m.id FROM public.derm_manifests m
            WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number)
                  = COALESCE(NEW.white_manifest_number, NEW.yellow_ticket_number)
              AND m.client_id = NEW.client_id
              AND m.deleted_at IS NULL
            ORDER BY m.id LIMIT 1)        -- live sibling for (ticket, client), else NULL
   WHERE r.matched_manifest_id = NEW.id;
  RETURN NULL;
END $function$;

-- 5) add_sheet_client: resolve the client's manifest for the sheet's ticket by ticket key ----------
CREATE OR REPLACE FUNCTION derm.add_sheet_client(p_dump_folder text, p_page integer, p_client_id bigint DEFAULT NULL::bigint, p_custom_code text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_wm text; v_img text; v_next int; v_fac text; v_addr text; v_id bigint; v_mid bigint;
BEGIN
  PERFORM derm._require_stamp_key();
  IF p_client_id IS NULL AND (p_custom_code IS NULL OR btrim(p_custom_code) = '') THEN
    RAISE EXCEPTION 'provide p_client_id or a non-empty p_custom_code';
  END IF;
  SELECT max(white_manifest_number) INTO v_wm FROM derm.address_row_map WHERE dump_folder = p_dump_folder;
  IF v_wm IS NULL THEN RAISE EXCEPTION 'unknown sheet %', p_dump_folder; END IF;
  SELECT min(image_url) INTO v_img FROM derm.address_row_map WHERE dump_folder = p_dump_folder AND page = p_page;
  IF v_img IS NULL THEN
    SELECT min(image_url) INTO v_img FROM derm.address_row_map WHERE dump_folder = p_dump_folder;
  END IF;
  SELECT coalesce(max(row_index), 0) + 1 INTO v_next FROM derm.address_row_map WHERE dump_folder = p_dump_folder AND page = p_page;
  IF p_client_id IS NOT NULL THEN
    SELECT c.name, (SELECT p.address FROM public.properties p WHERE p.client_id = c.id ORDER BY p.id LIMIT 1)
      INTO v_fac, v_addr FROM public.clients c WHERE c.id = p_client_id;
    IF v_fac IS NULL THEN RAISE EXCEPTION 'unknown client id %', p_client_id; END IF;
    -- resolve this client's manifest for the sheet's TICKET (white or yellow keyed), if filed
    SELECT dm.id INTO v_mid FROM public.derm_manifests dm
     WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = v_wm AND dm.client_id = p_client_id
       AND dm.deleted_at IS NULL
     LIMIT 1;
  ELSE
    v_fac := btrim(p_custom_code);
  END IF;
  INSERT INTO derm.address_row_map
    (dump_folder, white_manifest_number, page, row_index, image_url,
     facility_name_read, address_read, matched_client_id, matched_manifest_id, manual_code,
     assignment_status, confidence, source, flags, created_at, updated_at)
  VALUES
    (p_dump_folder, v_wm, p_page, v_next, v_img,
     v_fac, v_addr, p_client_id, v_mid, CASE WHEN p_client_id IS NULL THEN btrim(p_custom_code) END,
     'matched', 'high', 'stamp-studio', '{"manual_add":true}'::jsonb, now(), now())
  RETURNING id INTO v_id;
  RETURN v_id;
END $function$;

-- 6) file_manifest_and_link: ticket-key find/inherit + file under the CORRECT number column --------
CREATE OR REPLACE FUNCTION derm.file_manifest_and_link(p_row_id bigint, p_visit_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_wm text; v_cid bigint; v_vcid bigint; v_vdate date; v_mid bigint;
  v_yellow_key boolean;
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
    -- inherit shared docs from the BEST-documented ticket sibling (soft preference, matching
    -- file_manifest_on_shared_ticket — the old hard "derm_manifest_url IS NOT NULL" filter inherited
    -- NOTHING from an address-doc-only sibling like m512/ticket-296623)
    SELECT * INTO v_sib FROM public.derm_manifests
      WHERE COALESCE(white_manifest_number, yellow_ticket_number) = v_wm AND deleted_at IS NULL
      ORDER BY (derm_manifest_url IS NOT NULL) DESC, (derm_address_url IS NOT NULL) DESC, id
      LIMIT 1;

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
       v_sib.wwtp_receipt_document_path, v_sib.disposal_facility_id, v_sib.dump_ticket_date)
    RETURNING id INTO v_mid;

    UPDATE derm.address_row_map SET matched_manifest_id = v_mid WHERE id = p_row_id;
  END IF;

  INSERT INTO public.manifest_visits (manifest_id, visit_id)
    VALUES (v_mid, p_visit_id) ON CONFLICT DO NOTHING;

  RETURN v_mid;
END $function$;

-- 7) v_stamp_sheets: tickets by ticket key ---------------------------------------------------------
CREATE OR REPLACE VIEW derm.v_stamp_sheets AS
 WITH tickets AS (
         SELECT DISTINCT COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number) AS wm
           FROM derm_manifests
          WHERE derm_manifests.deleted_at IS NULL
            AND COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number) IS NOT NULL
        UNION
         SELECT DISTINCT address_row_map.white_manifest_number
           FROM derm.address_row_map
          WHERE address_row_map.white_manifest_number IS NOT NULL
        ), folder AS (
         SELECT address_row_map.white_manifest_number AS wm,
            min(address_row_map.dump_folder) AS f
           FROM derm.address_row_map
          WHERE address_row_map.white_manifest_number IS NOT NULL
          GROUP BY address_row_map.white_manifest_number
        ), vis AS (
         SELECT r.white_manifest_number AS wm,
            count(*) AS total,
            count(*) FILTER (WHERE r.matched_client_id IS NOT NULL OR r.manual_code IS NOT NULL) AS matched,
            count(*) FILTER (WHERE r.stamp_placed_at IS NOT NULL) AS placed
           FROM derm.address_row_map r
             LEFT JOIN clients c ON c.id = r.matched_client_id
          WHERE r.white_manifest_number IS NOT NULL AND (r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL OR r.manual_code IS NOT NULL) AND (r.stamp_placed_at IS NOT NULL OR r.manual_code IS NOT NULL OR r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
                   FROM derm_manifests m
                  WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL)))
          GROUP BY r.white_manifest_number
        )
 SELECT COALESCE(folder.f, 'ticket-'::text || t.wm) AS dump_folder,
    t.wm AS white_manifest_number,
    ( SELECT min(m.service_date) AS min
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm AND m.deleted_at IS NULL) AS service_date,
    COALESCE(array_length(spi.imgs, 1), 0)::bigint AS page_count,
    spi.imgs AS page_image_urls,
    COALESCE(vis.total, 0::bigint) AS total_rows,
    COALESCE(vis.matched, 0::bigint) AS matched_rows,
    COALESCE(vis.placed, 0::bigint) AS placed_rows,
    COALESCE(s.completed, false) AS completed,
    s.completed_at,
    COALESCE(( SELECT max(m.dump_ticket_date) AS max
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm AND m.deleted_at IS NULL), ( SELECT max(m.service_date) AS max
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = t.wm AND m.deleted_at IS NULL)) AS dump_date
   FROM tickets t
     LEFT JOIN folder ON folder.wm = t.wm
     LEFT JOIN vis ON vis.wm = t.wm
     LEFT JOIN derm.stamp_sheet_status s ON s.dump_folder = COALESCE(folder.f, 'ticket-'::text || t.wm)
     CROSS JOIN LATERAL ( SELECT derm.ticket_page_images(t.wm) AS imgs) spi;

-- 8) v_stamp_rows: service_date by ticket key ------------------------------------------------------
CREATE OR REPLACE VIEW derm.v_stamp_rows AS
 SELECT r.id,
    r.dump_folder,
    r.white_manifest_number,
    r.page,
    r.row_index,
    r.image_url,
    r.facility_name_read,
    r.address_read,
    COALESCE(c.client_code, r.manual_code) AS client_code,
    COALESCE(c.name, r.manual_code) AS client_name,
    ( SELECT min(m.service_date) AS min
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = r.white_manifest_number AND m.deleted_at IS NULL) AS service_date,
    r.assignment_status,
    r.confidence,
    r.stamp_x_pct,
    r.stamp_y_pct,
    r.stamp_page,
    6.0 AS guess_x_pct,
    round(40::numeric + (r.row_index::numeric - 0.5) * (52.0 / NULLIF(r.mx, 0)::numeric), 3) AS guess_y_pct,
    r.stamp_placed_at IS NOT NULL AS placed,
    r.source = 'stamp-studio'::text AS is_manual,
    r.matched_client_id,
    r.matched_manifest_id,
    r.band_y0_pct,
    r.band_y1_pct,
    r.band_source,
    r.reviewed_at IS NOT NULL AS reviewed,
    r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
           FROM manifest_visits mv
          WHERE mv.manifest_id = r.matched_manifest_id)) AS visit_linked,
    ( SELECT count(*) AS count
           FROM manifest_visits mv
          WHERE mv.manifest_id = r.matched_manifest_id) AS linked_visit_count
   FROM ( SELECT a.id,
            a.dump_folder,
            a.white_manifest_number,
            a.page,
            a.row_index,
            a.image_url,
            a.facility_name_read,
            a.address_read,
            a.matched_client_id,
            a.assignment_status,
            a.confidence,
            a.agent_agreement,
            a.flags,
            a.source,
            a.reviewed_by,
            a.reviewed_at,
            a.created_at,
            a.updated_at,
            a.stamp_x_pct,
            a.stamp_y_pct,
            a.stamp_page,
            a.stamp_placed_at,
            a.stamp_placed_by,
            a.manual_code,
            a.matched_manifest_id,
            a.band_y0_pct,
            a.band_y1_pct,
            a.band_source,
            a.band_set_at,
            a.band_set_by,
            max(a.row_index) OVER (PARTITION BY a.dump_folder, a.page) AS mx
           FROM derm.address_row_map a) r
     LEFT JOIN clients c ON c.id = r.matched_client_id
  WHERE r.white_manifest_number IS NOT NULL AND (r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL OR r.manual_code IS NOT NULL) AND (r.stamp_placed_at IS NOT NULL OR r.manual_code IS NOT NULL OR r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
           FROM derm_manifests m
          WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL)));

-- 9) BACKFILL: materialize the missing cards for linked yellow-only manifests ----------------------
-- Mimics fn_card_from_link (which fired before this fix and returned early). Idempotent via NOT EXISTS.
WITH targets AS (
  SELECT DISTINCT ON (COALESCE(m.white_manifest_number, m.yellow_ticket_number), m.client_id)
         m.id AS manifest_id, m.client_id,
         COALESCE(m.white_manifest_number, m.yellow_ticket_number) AS key
  FROM public.derm_manifests m
  WHERE m.deleted_at IS NULL
    AND m.white_manifest_number IS NULL AND m.yellow_ticket_number IS NOT NULL
    AND EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id = m.id)
    AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                     WHERE r.white_manifest_number = COALESCE(m.white_manifest_number, m.yellow_ticket_number)
                       AND r.matched_client_id = m.client_id)
  ORDER BY COALESCE(m.white_manifest_number, m.yellow_ticket_number), m.client_id, m.id
)
INSERT INTO derm.address_row_map
  (dump_folder, white_manifest_number, page, row_index, image_url,
   matched_client_id, matched_manifest_id, assignment_status, confidence, source, flags)
SELECT COALESCE((SELECT min(r.dump_folder) FROM derm.address_row_map r WHERE r.white_manifest_number = t.key),
                'ticket-' || t.key),
       t.key, 1,
       COALESCE((SELECT max(r2.row_index) FROM derm.address_row_map r2
                  WHERE r2.white_manifest_number = t.key AND r2.page = 1), 0)
         + row_number() OVER (PARTITION BY t.key ORDER BY t.manifest_id),
       COALESCE((derm.ticket_page_images(t.key))[1],
                (SELECT dm.derm_address_url FROM public.derm_manifests dm WHERE dm.id = t.manifest_id),
                'pending'),
       t.client_id, t.manifest_id, 'matched', 'high', 'derm-link',
       '{"card_from_link":true,"backfill":"2026-07-10_yellow_only_tickets"}'::jsonb
FROM targets t;

-- 10) trg_resolve_card_manifest: extend the firing columns to yellow_ticket_number ------------------
DROP TRIGGER IF EXISTS trg_resolve_card_manifest ON public.derm_manifests;
CREATE TRIGGER trg_resolve_card_manifest
  AFTER INSERT OR UPDATE OF deleted_at, white_manifest_number, yellow_ticket_number, client_id
  ON public.derm_manifests FOR EACH ROW EXECUTE FUNCTION derm.fn_resolve_card_manifest();

-- 11) v_stamp_linkage_gaps: gap-detect by ticket key (else the 15 backfilled cards = false alarms) --
CREATE OR REPLACE VIEW derm.v_stamp_linkage_gaps AS
 SELECT DISTINCT r.white_manifest_number,
    r.matched_client_id,
    c.client_code,
    c.name AS client_name,
    r.matched_manifest_id,
    r.matched_manifest_id IS NULL AS no_manifest_row
   FROM derm.address_row_map r
     JOIN clients c ON c.id = r.matched_client_id
  WHERE r.matched_client_id IS NOT NULL AND r.white_manifest_number IS NOT NULL AND NOT (EXISTS ( SELECT 1
           FROM derm_manifests m
             JOIN manifest_visits mv ON mv.manifest_id = m.id
             JOIN visits v ON v.id = mv.visit_id
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = r.white_manifest_number AND v.client_id = r.matched_client_id));

-- 12) Invariant: the ticket key must stay unambiguous (white#s and yellow#s are independent 6-digit
--     counters — a cross-collision would silently merge two physical tickets into one sheet).
CREATE OR REPLACE FUNCTION public.fn_derm_ticket_key_unambiguous()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  IF NEW.deleted_at IS NULL THEN
    IF NEW.white_manifest_number IS NOT NULL AND EXISTS (
         SELECT 1 FROM public.derm_manifests m WHERE m.deleted_at IS NULL AND m.white_manifest_number IS NULL
           AND m.yellow_ticket_number = NEW.white_manifest_number AND m.id IS DISTINCT FROM NEW.id) THEN
      RAISE EXCEPTION 'white manifest # % collides with an existing yellow-only ticket key (two physical tickets would merge into one Stamp sheet). If they ARE the same ticket, set the yellow-only rows'' white# instead.', NEW.white_manifest_number;
    END IF;
    IF NEW.white_manifest_number IS NULL AND NEW.yellow_ticket_number IS NOT NULL AND EXISTS (
         SELECT 1 FROM public.derm_manifests m WHERE m.deleted_at IS NULL
           AND m.white_manifest_number = NEW.yellow_ticket_number AND m.id IS DISTINCT FROM NEW.id) THEN
      RAISE EXCEPTION 'yellow ticket # % collides with an existing white manifest key (two physical tickets would merge into one Stamp sheet). If they ARE the same ticket, file with the white# too.', NEW.yellow_ticket_number;
    END IF;
  END IF;
  RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS trg_ae_ticket_key_unambiguous ON public.derm_manifests;
CREATE TRIGGER trg_ae_ticket_key_unambiguous
  BEFORE INSERT OR UPDATE OF white_manifest_number, yellow_ticket_number, deleted_at
  ON public.derm_manifests FOR EACH ROW EXECUTE FUNCTION public.fn_derm_ticket_key_unambiguous();
-- 'ae' sorts after trg_ab_adopt_sibling_white -> validates POST-adoption values. ~1.3k-row table, the
-- EXISTS probes are cheap without new indexes. ⚠ backup replays containing a colliding pair now RAISE.

-- 13) fn_manifest_visit_one_white -> one TICKET KEY per visit (guard was hollow for yellow-only) ----
CREATE OR REPLACE FUNCTION public.fn_manifest_visit_one_white()
 RETURNS trigger
 LANGUAGE plpgsql
AS $fn$
DECLARE v_new_wm text; v_other_wm text; v_vcode text;
BEGIN
  SELECT COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) INTO v_new_wm
    FROM public.derm_manifests dm WHERE dm.id = NEW.manifest_id AND dm.deleted_at IS NULL;
  IF v_new_wm IS NULL THEN RETURN NEW; END IF;
  SELECT COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) INTO v_other_wm
    FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL
         AND COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) IS NOT NULL
   WHERE mv.visit_id = NEW.visit_id AND mv.manifest_id <> NEW.manifest_id
     AND COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) <> v_new_wm LIMIT 1;
  IF v_other_wm IS NULL THEN RETURN NEW; END IF;
  SELECT client_code INTO v_vcode FROM public.clients WHERE id = (SELECT client_id FROM public.visits WHERE id = NEW.visit_id);
  RAISE EXCEPTION USING errcode='P0001',
    message = format('one-ticket-per-visit violated: visit %s (%s) is already linked to ticket # %s; refusing to also link ticket # %s (manifest_id %s). One visit = one dump = one ticket number.', NEW.visit_id, coalesce(v_vcode,'?'), v_other_wm, v_new_wm, NEW.manifest_id),
    hint = 'If mis-linked, unlink the wrong manifest first. If two nights were dumped, they are two separate visits, each linked to its own ticket number.';
END $fn$;

-- 14) file_manifest_on_shared_ticket (DERM Tracker Move/Attach): ticket-key find/inherit + correct
--     number column on create. Was white#-only -> RAISED on every yellow-only ticket.
CREATE OR REPLACE FUNCTION public.file_manifest_on_shared_ticket(p_white_manifest_number text, p_client_id bigint, p_visit_id bigint, OUT manifest_id bigint, OUT created boolean, OUT linked boolean)
 RETURNS record
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'derm'
AS $fn$
DECLARE
  v_wm text := btrim(p_white_manifest_number);   -- the TICKET number (white, or yellow for Broward-only)
  v_vcid bigint; v_vdate date; v_vcode text; v_ccode text; v_rows int;
  v_yellow_key boolean;
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
    SELECT * INTO sib FROM public.derm_manifests dm
     WHERE COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) = v_wm AND dm.deleted_at IS NULL
     ORDER BY (dm.derm_manifest_url IS NOT NULL) DESC,
              (dm.derm_address_url IS NOT NULL) DESC, dm.id
     LIMIT 1;
    IF sib.id IS NULL THEN
      RAISE EXCEPTION 'no manifest exists on ticket % to share docs from — file the first manifest through the normal flow', v_wm;
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
       sib.wwtp_receipt_document_path, sib.disposal_facility_id, sib.dump_ticket_date)
    RETURNING id INTO manifest_id;
  END IF;

  INSERT INTO public.manifest_visits (manifest_id, visit_id)
    VALUES (manifest_id, p_visit_id) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  linked := v_rows > 0;
END $fn$;

-- 15) fn_manifest_visit_not_after_dump: report the TICKET number in the rejection (logic unchanged —
--     it keys off dump_ticket_date; only the operator-facing message showed "ticket ?" for yellow-only).
CREATE OR REPLACE FUNCTION public.fn_manifest_visit_not_after_dump()
 RETURNS trigger
 LANGUAGE plpgsql
AS $fn$
DECLARE v_dump date; v_wm text; v_vdate date; v_vcid bigint; v_code text;
BEGIN
  SELECT dm.dump_ticket_date, COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) INTO v_dump, v_wm
    FROM public.derm_manifests dm WHERE dm.id = NEW.manifest_id;
  IF v_dump IS NULL THEN RETURN NEW; END IF;               -- dump unknown -> allow

  SELECT v.visit_date, v.client_id INTO v_vdate, v_vcid
    FROM public.visits v WHERE v.id = NEW.visit_id;
  IF v_vdate IS NULL THEN RETURN NEW; END IF;

  IF v_vdate > v_dump + 1 THEN                              -- +1 day grace
    SELECT client_code INTO v_code FROM public.clients WHERE id = v_vcid;
    RAISE EXCEPTION USING
      errcode = 'P0001',
      message = format(
        'link rejected: visit %s (%s, serviced %s) is dated after ticket %s''s dump %s — grease is pumped before the dump, so this visit cannot be on that load',
        NEW.visit_id, coalesce(v_code, v_vcid::text), v_vdate, coalesce(v_wm, '?'), v_dump),
      hint = 'Link this visit to the client''s manifest on a LATER ticket (the first dump on/after the service date), or file that manifest.';
  END IF;
  RETURN NEW;
END $fn$;

COMMIT;

-- VERIFY (post-apply):
--   SELECT dump_folder, dump_date, page_count, total_rows FROM derm.v_stamp_sheets
--    WHERE dump_folder IN ('ticket-308684','ticket-308792','ticket-296623');
--   -> 3 sheets, page_count > 0, total_rows 7/7/1; sheet count 95 -> 98; the 95 pre-existing
--   sheets byte-identical to scratchpad v_stamp_sheets_before.json.
