-- ============================================================================
-- 2026-10-17_0050_stamp_one_card_per_gdo_permit
-- Stamp Studio: a client printed on several rows of a generated sheet gets ONE STAMP PER GDO
-- PERMIT, each on its own printed row, with the permit's nickname, automatically.
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-17, on https://stamp.unclogme.app/838681: "look at this manifest ... it looks so bad
--   the stamp, why? fix it. Also if it has multiple GDO why are you not applying the measurement of
--   putting multiple stamps with the respective nickname? we need to fix that."
-- WHY IT LOOKED BAD (measured)
--   Sheet 1139 page 1 prints 242-WYN Wynd 28 on rows 1 to 3 (GDO-13814 Pasta, GDO-14760 Nino Gordo,
--   GDO-16146 Pari Pari), then 116-HIK and 004-BAO. ticket-838681 held ONE card for 242-WYN (no
--   gdo_id). derm.fn_generated_page_cards refuses any page with a multi-row client ("A client on this
--   page is printed on several rows ..."), three attempts, so page 1 was never measured, its three
--   stamps have no saved band, and the Studio drew its "estimated" bands halfway between the stamps:
--   242-WYN's ran over rows 1, 2 and half of 3, 116-HIK's over the other half of Pari Pari's row.
--   Page 2 (one row per client) was measured at 16:56 on 10-14 and looks right.
-- WHY THERE WAS ONLY ONE CARD
--   The 2026-08-27 design (docs/superpowers/specs/2026-08-27-multi-gdo-permit-cards-design.md, Fred:
--   create the extra cards "automatically, at link time") was never built: no fn_ensure_permit_cards
--   exists, and every multi-permit sheet since was repaired by a hand-written migration (043-MIL
--   2026-08-27 and 2026-09-09, 009-CN 2026-08-31). The Studio already shows a permit's nickname on its
--   stamp (v_stamp_rows.gdo_label; 830714 reads "009-CN · Kitchen / Bar / Lounge"), so no app change.
-- WHAT CHANGES
--   NEW derm.fn_card_printed_row(row id): a card's printed row. One-row client = its slot's first row
--     (= fn_generated_sheet_slot, unchanged); multi-row client = the row of the permit the card is
--     bound to (permits in gdo_number order, as pdf_service/app.py prints them), NULL when unbound or
--     when today's permit count is not what the sheet printed (rows_printed is frozen; gdos is not).
--   NEW derm.fn_ensure_permit_cards(folder | NULL = all open): for an OPEN generated folder, binds the
--     machine's stamp on the client's first printed row to the first permit and adds one card per
--     other permit, ALREADY STAMPED on its own row (never via the insert trigger, which would stack
--     them on row 1). Page, image and manifest are copied from the client's card (page is shared by
--     every card of a folder: ticket-833049). Refuses, writing nothing, when: the permit count differs
--     from the sheet; the client has cards for 2 manifests, a foreign permit or 2 unbound cards; any
--     image of the ticket lacks a high-confidence sheet-number read of THIS sheet on THAT image (the
--     312433 lesson); a person moved the stamp; a permit row has no scan; the row OCR names another
--     client there. Never touches a completed or reopened sheet or a handwritten one. Idempotent.
--   derm.fn_generated_page_cards: a card's row is fn_card_printed_row, so a page whose multi-row
--     client has one bound card per permit is measured like any other; an unbound one is still
--     refused with the same sentence. Every other page returns the same refusal and cards (VERIFY).
--   public.fn_request_generated_measure (cron generated-sheet-finisher): step 0b runs
--     fn_ensure_permit_cards(NULL) before anything is measured.
--   Data: ticket-838681 gets 242-WYN Nino Gordo and Pari Pari on rows 2 and 3; its stamp on row 1 is
--     bound to Pasta. The finisher then measures page 1 and completes the sheet when every gate passes.
-- NOT DONE (on purpose)
--   No completed sheet is touched (adding a card to one reopens it). Measured: ticket-838130 (sheet
--   1134, completed by a person 2026-10-08) holds one card for 043-MIL (2 rows) and 009-CN (3 rows), so
--   their other permit rows are blacked out of their own documents; ticket-833395 stays the documented
--   2026-08-27 exception. Both are a decision for Fred.
--   Known limit: a person who REMOVES a permit card's stamp re-drops it in the Studio (the resolver
--   and the insert trigger place by manifest, i.e. on the client's first row).
-- Rule 8: derm.address_row_map is audited (audit_address_row_map); the 3 card writes land in audit.logs.
-- ROLLBACK: 2026-10-17_rollback_stamp_one_card_per_gdo_permit.sql (functions only; the cards stay, they are true).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_functiondef('derm.fn_generated_page_cards(text,integer)'::regprocedure)) IS DISTINCT FROM 'ad0d88967c661d6f49039dc3cf35879c'
     OR md5(pg_get_functiondef('public.fn_request_generated_measure()'::regprocedure)) IS DISTINCT FROM '9d8bdf9b5332c2753dff714b113d3347' THEN
    RAISE EXCEPTION 'a function changed since this file was written: splice again';
  END IF;
  IF to_regprocedure('derm.fn_ensure_permit_cards(text)') IS NOT NULL OR to_regprocedure('derm.fn_card_printed_row(bigint)') IS NOT NULL THEN
    RAISE EXCEPTION 'the new functions already exist';
  END IF;
END $g$;

CREATE TEMP TABLE pc_before ON COMMIT DROP AS
  SELECT p.dump_folder, p.page, derm.fn_generated_page_cards(p.dump_folder, p.page) AS j
    FROM (SELECT DISTINCT r.dump_folder, coalesce(r.stamp_page, r.page) AS page
            FROM derm.address_row_map r
           WHERE r.dump_folder LIKE 'ticket-%' AND r.stamp_y_pct IS NOT NULL) p;
CREATE TEMP TABLE misc_before ON COMMIT DROP AS
  SELECT to_jsonb(derm.ticket_page_images('838681')) AS imgs,
         (SELECT md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)) FROM derm.address_row_map r
           WHERE r.dump_folder <> 'ticket-838681') AS others,
         (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'derm.fn_generated_page_cards(text,integer)'::regprocedure) AS acl_pc,
         (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'public.fn_request_generated_measure()'::regprocedure) AS acl_req;

-- 1. The printed row ONE card belongs on. For a client printed on one row that is its slot's first
--    row (the same answer as derm.fn_generated_sheet_slot). For a client printed on several rows
--    (one row per ACTIVE, well-formed permit, sorted by gdo_number: pdf_service/app.py) it is the
--    row of the permit the card is bound to. NULL when that cannot be known: the card has no permit,
--    or the client's permits today do not number what the sheet printed (rows_printed is frozen at
--    generation; public.gdos is not), so the order would be a guess.
CREATE OR REPLACE FUNCTION derm.fn_card_printed_row(p_row_id bigint)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  WITH c AS (
    SELECT r.matched_client_id, r.matched_manifest_id, r.gdo_id
      FROM derm.address_row_map r
     WHERE r.id = p_row_id
  ), s AS (
    SELECT pr.first_row, pr.rows_printed
      FROM c
      JOIN public.derm_manifests m ON m.id = c.matched_manifest_id AND m.deleted_at IS NULL
      JOIN derm.address_sheet_manifests l ON l.manifest_id = m.id
      JOIN derm.address_sheets sh ON sh.id = l.sheet_id AND sh.deleted_at IS NULL
      JOIN derm.v_sheet_printed_rows pr ON pr.sheet_id = l.sheet_id AND pr.slot = l.slot AND pr.is_first_row
     ORDER BY l.slot NULLS LAST
     LIMIT 1
  ), p AS (
    SELECT g.id, row_number() OVER (ORDER BY g.gdo_number) AS k, count(*) OVER () AS n
      FROM c
      JOIN public.gdos g ON g.client_id = c.matched_client_id
     WHERE g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$'
  )
  SELECT CASE
           WHEN s.rows_printed <= 1 THEN s.first_row
           WHEN c.gdo_id IS NULL THEN NULL
           ELSE (SELECT s.first_row + p.k::int - 1 FROM p WHERE p.id = c.gdo_id AND p.n = s.rows_printed)
         END
    FROM c CROSS JOIN s;
$function$;

-- 2. Give a client printed on several rows of a generated sheet one card per permit, each stamped
--    on its own printed row and bound to its permit (so the Studio shows the permit's nickname).
--    NULL = every open generated folder that needs it (the finisher's step 0). Never touches a
--    completed or reopened sheet, a handwritten sheet, or a client a person has already worked on.
--    Places a card only where the page order of the sheet is confirmed by a high-confidence sheet
--    number read on EVERY image (the 312433 lesson) and the row OCR, when there is one, does not
--    name another client on that row. Otherwise it creates nothing and says why. Idempotent.
CREATE OR REPLACE FUNCTION derm.fn_ensure_permit_cards(p_dump_folder text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  f record; t derm.address_row_map%rowtype; u derm.address_row_map%rowtype;
  v_permits bigint[]; v_imgs text[]; v_code text; v_sheet_no text; v_why text;
  v_geo record; v_img int; v_k int; v_n int; v_next int; v_new int; v_bind int;
  v_plan jsonb; e jsonb;
  v_created int := 0; v_bound int := 0; v_skipped jsonb := '[]'::jsonb;
BEGIN
  FOR f IN
    SELECT x.dump_folder, x.client_id, x.ticket, x.sheet_id, x.first_row, x.rows_printed
      FROM (SELECT DISTINCT r.dump_folder, r.matched_client_id AS client_id,
                   r.white_manifest_number AS ticket, pr.sheet_id, pr.first_row, pr.rows_printed
              FROM derm.address_row_map r
              JOIN public.derm_manifests m ON m.id = r.matched_manifest_id AND m.deleted_at IS NULL
              JOIN derm.address_sheet_manifests l ON l.manifest_id = m.id
              JOIN derm.address_sheets sh ON sh.id = l.sheet_id AND sh.deleted_at IS NULL
              JOIN derm.v_sheet_printed_rows pr ON pr.sheet_id = l.sheet_id AND pr.slot = l.slot AND pr.is_first_row
             WHERE (p_dump_folder IS NULL OR r.dump_folder = p_dump_folder)
               AND r.dump_folder LIKE 'ticket-%'
               AND r.white_manifest_number IS NOT NULL
               AND pr.rows_printed > 1) x
      LEFT JOIN derm.stamp_sheet_status st ON st.dump_folder = x.dump_folder
     WHERE NOT coalesce(st.completed, false)
       AND st.reopened_at IS NULL
       AND coalesce(derm.fn_sheet_is_generated(x.ticket), false)
       AND (SELECT count(*) FROM derm.address_row_map r2
             WHERE r2.dump_folder = x.dump_folder AND r2.matched_client_id = x.client_id) < x.rows_printed
     ORDER BY x.dump_folder, x.client_id
  LOOP
    v_why := NULL; v_plan := '[]'::jsonb;
    SELECT c.client_code INTO v_code FROM public.clients c WHERE c.id = f.client_id;
    SELECT s.sheet_no::text INTO v_sheet_no FROM derm.address_sheets s WHERE s.id = f.sheet_id;

    -- the permits, in printed order, and they must number what the sheet printed
    SELECT array_agg(g.id ORDER BY g.gdo_number) INTO v_permits
      FROM public.gdos g
     WHERE g.client_id = f.client_id AND g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$';
    IF coalesce(array_length(v_permits, 1), 0) <> f.rows_printed THEN
      v_why := format('%s has %s active permits today, the sheet printed %s rows for it',
                      v_code, coalesce(array_length(v_permits, 1), 0), f.rows_printed);
    END IF;

    -- the client's cards: one manifest, permits only from its own list, at most one unbound card
    IF v_why IS NULL AND (SELECT count(DISTINCT r.matched_manifest_id) FROM derm.address_row_map r
                           WHERE r.dump_folder = f.dump_folder AND r.matched_client_id = f.client_id) <> 1 THEN
      v_why := format('%s has cards for more than one manifest on this sheet', v_code);
    END IF;
    IF v_why IS NULL AND EXISTS (SELECT 1 FROM derm.address_row_map r
                                  WHERE r.dump_folder = f.dump_folder AND r.matched_client_id = f.client_id
                                    AND r.gdo_id IS NOT NULL AND NOT (r.gdo_id = ANY (v_permits))) THEN
      v_why := format('a card of %s is bound to a permit that was not printed', v_code);
    END IF;
    IF v_why IS NULL AND (SELECT count(*) FROM derm.address_row_map r
                           WHERE r.dump_folder = f.dump_folder AND r.matched_client_id = f.client_id
                             AND r.gdo_id IS NULL) > 1 THEN
      v_why := format('%s has more than one card without a permit', v_code);
    END IF;

    -- the page order must be confirmed by a high-confidence sheet-number read on every image
    IF v_why IS NULL THEN
      v_imgs := derm.ticket_page_images(f.ticket);
      IF coalesce(array_length(v_imgs, 1), 0) = 0 OR EXISTS (
           SELECT 1 FROM generate_subscripts(v_imgs, 1) i
            WHERE NOT EXISTS (SELECT 1 FROM derm.address_sheet_scan_reads sr
                               WHERE sr.dump_folder = f.dump_folder AND sr.page = i
                                 AND sr.confidence = 'high'
                                 AND sr.image_url = v_imgs[i]
                                 AND split_part(sr.sheet_no_read, '-', 1) = v_sheet_no)) THEN
        v_why := 'the page order of this sheet is not confirmed by a sheet-number read yet';
      END IF;
    END IF;

    -- the unbound card, if any, must be the machine's stamp on the client's first printed row
    u := NULL;
    IF v_why IS NULL THEN
      SELECT * INTO u FROM derm.address_row_map r
       WHERE r.dump_folder = f.dump_folder AND r.matched_client_id = f.client_id AND r.gdo_id IS NULL;
      IF u.id IS NOT NULL THEN
        SELECT * INTO v_geo FROM derm.fn_generated_row_geometry(f.first_row);
        IF u.stamp_placed_at IS NULL OR u.stamp_placed_by IS DISTINCT FROM 'stamp-studio-ai'
           OR u.stamp_page IS DISTINCT FROM derm.fn_sheet_image_position(f.dump_folder, v_geo.o_page)
           OR u.stamp_y_pct IS DISTINCT FROM round(v_geo.o_y_pct, 3) THEN
          v_why := format('the stamp of %s is not where the machine placed it, so a person decides its permit', v_code);
        ELSIF EXISTS (SELECT 1 FROM derm.address_row_map r
                       WHERE r.dump_folder = f.dump_folder AND r.gdo_id = v_permits[1]) THEN
          v_why := format('the first permit of %s is already held by another card', v_code);
        END IF;
      END IF;
    END IF;

    -- every missing permit's row must be placeable before anything is written
    IF v_why IS NULL THEN
      FOR v_k IN 1 .. f.rows_printed LOOP
        CONTINUE WHEN v_k = 1 AND u.id IS NOT NULL;
        CONTINUE WHEN EXISTS (SELECT 1 FROM derm.address_row_map r
                               WHERE r.dump_folder = f.dump_folder AND r.gdo_id = v_permits[v_k]);
        v_n := f.first_row + v_k - 1;
        SELECT * INTO v_geo FROM derm.fn_generated_row_geometry(v_n);
        v_img := derm.fn_sheet_image_position(f.dump_folder, v_geo.o_page);
        IF v_img IS NULL OR v_geo.o_y_pct IS NULL THEN
          v_why := format('printed row %s of %s has no scan on file', v_n, v_code); EXIT;
        END IF;
        IF derm.fn_row_read_confirms(f.dump_folder, v_img, ((v_n - 1) % 5) + 1, v_code) IS FALSE THEN
          v_why := format('the scan names another client on printed row %s', v_n); EXIT;
        END IF;
        v_plan := v_plan || jsonb_build_object('gdo_id', v_permits[v_k], 'img', v_img,
                                               'x', round(v_geo.o_x_pct, 3), 'y', round(v_geo.o_y_pct, 3));
      END LOOP;
    END IF;

    IF v_why IS NOT NULL THEN
      v_skipped := v_skipped || jsonb_build_object('folder', f.dump_folder, 'client', v_code, 'why', v_why);
      CONTINUE;
    END IF;

    -- write: bind the existing stamp, add the others already stamped (never let the insert trigger
    -- place them: it would stack every permit on the first row). One subtransaction per client.
    <<client_write>>
    BEGIN
      v_bind := 0; v_new := 0;
      IF u.id IS NOT NULL THEN
        UPDATE derm.address_row_map SET gdo_id = v_permits[1] WHERE id = u.id;
        v_bind := 1;
      END IF;
      -- the template: page, image and manifest are copied, never derived (page is shared by every
      -- card of a folder; a card claiming another page re-points the image list: ticket-833049)
      SELECT * INTO t FROM derm.address_row_map r
       WHERE r.dump_folder = f.dump_folder AND r.matched_client_id = f.client_id
       ORDER BY r.id LIMIT 1;
      FOR e IN SELECT * FROM jsonb_array_elements(v_plan) LOOP
        SELECT coalesce(max(r.row_index), 0) + 1 INTO v_next
          FROM derm.address_row_map r WHERE r.dump_folder = f.dump_folder AND r.page = t.page;
        INSERT INTO derm.address_row_map
          (dump_folder, white_manifest_number, page, row_index, image_url,
           matched_client_id, matched_manifest_id, gdo_id, assignment_status, confidence, source, flags,
           stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, stamp_placed_by)
        VALUES
          (t.dump_folder, t.white_manifest_number, t.page, v_next, t.image_url,
           t.matched_client_id, t.matched_manifest_id, (e->>'gdo_id')::bigint, 'matched', 'high',
           'permit-card', '{"permit_card":true}'::jsonb,
           (e->>'img')::int, (e->>'x')::numeric, (e->>'y')::numeric, now(), 'stamp-studio-ai');
        v_new := v_new + 1;
      END LOOP;
      v_bound := v_bound + v_bind; v_created := v_created + v_new;
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped || jsonb_build_object('folder', f.dump_folder, 'client', v_code,
                                                   'why', 'write failed: ' || SQLERRM);
    END client_write;
  END LOOP;

  RETURN jsonb_build_object('created', v_created, 'bound', v_bound, 'skipped', v_skipped);
END $function$;

REVOKE ALL ON FUNCTION derm.fn_card_printed_row(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION derm.fn_ensure_permit_cards(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_card_printed_row(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION derm.fn_ensure_permit_cards(text) TO service_role;
COMMENT ON FUNCTION derm.fn_card_printed_row(bigint) IS 'The printed row a Stamp Studio card belongs on: its slot''s first row for a client printed on one row, the row of its bound permit (gdo_number order) for a client printed on several; NULL when that cannot be known. Migration 2026-10-17_0050.';
COMMENT ON FUNCTION derm.fn_ensure_permit_cards(text) IS 'One card per GDO permit for a client printed on several rows of an OPEN generated sheet (Fred, 2026-10-17): binds the machine stamp on the first row, adds the others already stamped on their rows; refuses (writes nothing, returns why) unless the page order is confirmed by sheet-number reads. NULL = every open folder; run by the generated-sheet finisher step 0b. Migration 2026-10-17_0050.';

CREATE OR REPLACE FUNCTION derm.fn_generated_page_cards(p_dump_folder text, p_page integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_ticket text; v_refusal text; v_detail text; v_cards jsonb; v_n int;
BEGIN
  SELECT r.white_manifest_number INTO v_ticket
    FROM derm.address_row_map r
   WHERE r.dump_folder = p_dump_folder AND r.white_manifest_number IS NOT NULL
   LIMIT 1;
  IF v_ticket IS NULL OR NOT coalesce(derm.fn_sheet_is_generated(v_ticket), false) THEN
    RETURN jsonb_build_object(
      'refusal', 'This sheet was not printed by us, so it cannot be measured automatically. Measure it with Draw the bands.',
      'detail', 'no generated-sheet link for ' || coalesce(v_ticket, p_dump_folder),
      'ticket', v_ticket, 'cards', '[]'::jsonb);
  END IF;

  WITH c AS (
    SELECT r.id, r.matched_client_id, r.stamp_y_pct, r.stamp_placed_at, s.slot, pr.prow,
           CASE WHEN pr.prow IS NULL THEN NULL ELSE ((pr.prow - 1) / 5) + 1 END AS printed_page,
           CASE WHEN pr.prow IS NULL THEN NULL ELSE ((pr.prow - 1) % 5) + 1 END AS row_on_page,
           (SELECT max(sc.rows_printed)
              FROM derm.address_sheet_manifests l
              JOIN derm.address_sheet_clients sc ON sc.sheet_id = l.sheet_id AND sc.slot = l.slot
             WHERE l.manifest_id = r.matched_manifest_id) AS rows_printed
      FROM derm.address_row_map r
      CROSS JOIN LATERAL (SELECT derm.fn_generated_sheet_slot(r.matched_manifest_id) AS slot) s
      CROSS JOIN LATERAL (SELECT derm.fn_card_printed_row(r.id) AS prow) pr
     WHERE r.dump_folder = p_dump_folder
       AND coalesce(r.stamp_page, r.page) = p_page
       AND r.stamp_y_pct IS NOT NULL
  )
  SELECT count(*),
         CASE
           WHEN count(*) = 0 THEN
             'Nothing has been stamped on this page yet.'
           WHEN bool_or(stamp_placed_at IS NULL) THEN
             'A stamp on this page has a position but was never actually placed. Place it again.'
           WHEN bool_or(slot IS NULL) THEN
             'A client on this page is not on the printed list of this sheet, so its row cannot be found automatically. A person needs to check this page in Draw the bands.'
           -- 2026-10-17: a client printed on several rows is measured once each of its cards is bound
           -- to one of its permits (derm.fn_ensure_permit_cards): the card's row is its permit's row
           -- (derm.fn_card_printed_row). Until then any such client was refused here.
           WHEN bool_or(prow IS NULL) THEN
             'A client on this page is printed on several rows. Give it one card per permit and place each stamp on its own row, then measure the page with Draw the bands.'
           WHEN bool_or(derm.fn_sheet_image_position(p_dump_folder, printed_page) IS DISTINCT FROM p_page) THEN
             'A client on this page is printed on a different page of this sheet. A person needs to check this page in Draw the bands.'
           WHEN count(*) > count(DISTINCT row_on_page) THEN
             'Two stamps on this page sit on the same printed row. Place them again.'
         END,
         format('%s stamped cards, %s clients, %s without a printed slot, %s multi-row, %s without a permit row',
                count(*), count(DISTINCT matched_client_id),
                count(*) FILTER (WHERE slot IS NULL), count(*) FILTER (WHERE rows_printed > 1),
                count(*) FILTER (WHERE slot IS NOT NULL AND prow IS NULL)),
         jsonb_agg(jsonb_build_object('row_id', id, 'client_id', matched_client_id,
                                      'row', row_on_page, 'y', stamp_y_pct)
                   ORDER BY row_on_page, id)
    INTO v_n, v_refusal, v_detail, v_cards
    FROM c;

  RETURN jsonb_build_object('refusal', v_refusal, 'detail', v_detail, 'ticket', v_ticket,
                            'cards', coalesce(v_cards, '[]'::jsonb));
END $function$;

CREATE OR REPLACE FUNCTION public.fn_request_generated_measure()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_key text; t record; f record;
BEGIN
  -- 0. (2026-09-14, Step A) place the cards a late sheet-number read left unplaced, only where
  --    the row OCR confirms the client on that printed row. No HTTP.
  PERFORM derm.fn_place_cards_awaiting_page_map(20);

  -- 0b. (2026-10-17) a client printed on several rows gets one card per permit, each stamped on its
  --     own printed row and bound to its permit, before anything is measured. No HTTP.
  PERFORM derm.fn_ensure_permit_cards(NULL);

  -- 1. completion first: no HTTP, and a generated sheet a person measured by hand completes here
  FOR f IN SELECT dump_folder FROM derm.v_generated_complete_backlog WHERE blocker IS NULL LOOP
    PERFORM derm.fn_complete_generated_sheet(f.dump_folder);
  END LOOP;

  -- 2. measurement requests, budgeted
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';
  IF v_key IS NULL THEN
    RAISE WARNING 'edge_invoke_service_key vault secret missing; skipping generated-sheet measure';
    RETURN;
  END IF;
  FOR t IN SELECT * FROM derm.fn_generated_measure_targets(2) LOOP
    INSERT INTO derm.generated_measure_attempts (dump_folder, page, image_url, source_etag, attempts, last_outcome)
    VALUES (t.dump_folder, t.page, t.image_url, t.source_etag, 1, 'requested')
    ON CONFLICT (dump_folder, page) DO UPDATE
       SET attempts = CASE
                        WHEN derm.generated_measure_attempts.image_url IS DISTINCT FROM EXCLUDED.image_url
                          OR derm.generated_measure_attempts.source_etag IS DISTINCT FROM EXCLUDED.source_etag
                        THEN 1                                            -- new scan, fresh budget
                        ELSE derm.generated_measure_attempts.attempts + 1
                      END,
           image_url = EXCLUDED.image_url, source_etag = EXCLUDED.source_etag,
           last_outcome = 'requested', last_attempt_at = now();
    PERFORM net.http_post(
      url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/measure-generated-page',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
      body := jsonb_build_object('dump_folder', t.dump_folder, 'ticket', t.ticket, 'page', t.page, 'image_url', t.image_url),
      timeout_milliseconds := 120000);
  END LOOP;
END $function$;

DO $v$
DECLARE r1 jsonb; r2 jsonb; n int; n_ctl int; v_cards jsonb; v_p1 jsonb; v_p2 jsonb; v_list text;
BEGIN
  r1 := derm.fn_ensure_permit_cards(NULL);
  IF (r1->>'created')::int <> 2 OR (r1->>'bound')::int <> 1 OR jsonb_array_length(r1->'skipped') <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1: expected 2 created, 1 bound, nothing skipped, got %', r1;
  END IF;
  -- 242-WYN on ticket-838681: three cards, permits in printed order, rows 1 to 3 of image 1
  SELECT jsonb_agg(jsonb_build_object('gdo', g.gdo_number, 'y', r.stamp_y_pct, 'pg', r.stamp_page,
                                      'row', derm.fn_card_printed_row(r.id), 'by', r.stamp_placed_by)
                   ORDER BY r.stamp_y_pct)
    INTO v_cards
    FROM derm.address_row_map r JOIN public.gdos g ON g.id = r.gdo_id
   WHERE r.dump_folder = 'ticket-838681' AND r.matched_client_id = 233;
  IF v_cards IS DISTINCT FROM '[{"gdo":"GDO-13814","y":29.8,"pg":1,"row":1,"by":"stamp-studio-ai"},{"gdo":"GDO-14760","y":37.72,"pg":1,"row":2,"by":"stamp-studio-ai"},{"gdo":"GDO-16146","y":44.48,"pg":1,"row":3,"by":"stamp-studio-ai"}]'::jsonb
     OR (SELECT count(*) FROM derm.address_row_map WHERE dump_folder = 'ticket-838681' AND matched_client_id = 233) <> 3 THEN
    RAISE EXCEPTION 'VERIFY 2: 242-WYN cards are %', v_cards;
  END IF;
  -- nothing else moved: the image list and every other folder's cards are byte-identical
  IF to_jsonb(derm.ticket_page_images('838681')) IS DISTINCT FROM (SELECT imgs FROM misc_before) THEN
    RAISE EXCEPTION 'VERIFY 3: the image list of 838681 changed';
  END IF;
  IF (SELECT md5(string_agg(to_jsonb(r)::text, ',' ORDER BY r.id)) FROM derm.address_row_map r
       WHERE r.dump_folder <> 'ticket-838681') IS DISTINCT FROM (SELECT others FROM misc_before) THEN
    RAISE EXCEPTION 'VERIFY 4: a card outside ticket-838681 changed';
  END IF;
  -- the finisher now accepts both pages of 838681, rows 1 to 5 each
  v_p1 := derm.fn_generated_page_cards('ticket-838681', 1);
  v_p2 := derm.fn_generated_page_cards('ticket-838681', 2);
  IF v_p1->>'refusal' IS NOT NULL OR v_p2->>'refusal' IS NOT NULL
     OR (SELECT jsonb_agg(c->'row' ORDER BY (c->>'row')::int) FROM jsonb_array_elements(v_p1->'cards') c) IS DISTINCT FROM '[1,2,3,4,5]'::jsonb THEN
    RAISE EXCEPTION 'VERIFY 5: page cards p1 % / p2 %', v_p1, v_p2;
  END IF;
  -- a page with no multi-row client: the same refusal and the same cards as before
  SELECT count(*) INTO n
    FROM pc_before b
    CROSS JOIN LATERAL (SELECT derm.fn_generated_page_cards(b.dump_folder, b.page) AS j) a
   WHERE coalesce((regexp_match(b.j->>'detail', '([0-9]+) multi-row$'))[1]::int, 0) = 0
     AND (b.j->'refusal', b.j->'cards') IS DISTINCT FROM (a.j->'refusal', a.j->'cards');
  -- the pages whose answer changed are exactly the permit-carded ones: 838681 p1, and three pages of
  -- COMPLETED sheets that were refused although their permit cards sit on the right rows (Casa Neos
  -- on 312433, 043-MIL on 832194, whose 2nd permit is page 2 row 1). Completed = never measured again.
  SELECT string_agg(b.dump_folder || ' p' || b.page, ', ' ORDER BY b.dump_folder, b.page) INTO v_list
    FROM pc_before b
    CROSS JOIN LATERAL (SELECT derm.fn_generated_page_cards(b.dump_folder, b.page) AS j) a
   WHERE (b.j->'refusal') IS DISTINCT FROM (a.j->'refusal');
  IF n <> 0 OR v_list IS DISTINCT FROM 'ticket-312433 p1, ticket-832194 p1, ticket-832194 p2, ticket-838681 p1'
     OR (SELECT count(*) FROM pc_before) < 90
     OR EXISTS (SELECT 1 FROM derm.stamp_sheet_status s
                 WHERE s.dump_folder IN ('ticket-312433', 'ticket-832194') AND NOT s.completed) THEN
    RAISE EXCEPTION 'VERIFY 6: % one-row pages changed, changed set [%], % pages compared', n, v_list, (SELECT count(*) FROM pc_before);
  END IF;
  -- a one-row client's card keeps exactly the slot it always had (fleet), with a non-empty control
  SELECT count(*) FILTER (WHERE derm.fn_card_printed_row(r.id) IS DISTINCT FROM derm.fn_generated_sheet_slot(r.matched_manifest_id)),
         count(*) FILTER (WHERE derm.fn_generated_sheet_slot(r.matched_manifest_id) IS NOT NULL)
    INTO n, n_ctl
    FROM derm.address_row_map r
   WHERE NOT EXISTS (SELECT 1 FROM derm.address_sheet_manifests l
                       JOIN derm.address_sheet_clients sc ON sc.sheet_id = l.sheet_id AND sc.slot = l.slot
                      WHERE l.manifest_id = r.matched_manifest_id AND sc.rows_printed > 1);
  IF n <> 0 OR n_ctl < 100 THEN RAISE EXCEPTION 'VERIFY 7: % one-row cards moved row (% compared)', n, n_ctl; END IF;
  -- idempotent
  r2 := derm.fn_ensure_permit_cards(NULL);
  IF (r2->>'created')::int <> 0 OR (r2->>'bound')::int <> 0 THEN RAISE EXCEPTION 'VERIFY 8: second run %', r2; END IF;
  -- privileges: the new functions are machine-only; the replaced ones keep theirs
  IF has_function_privilege('anon', 'derm.fn_ensure_permit_cards(text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'derm.fn_ensure_permit_cards(text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'derm.fn_card_printed_row(bigint)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'derm.fn_ensure_permit_cards(text)', 'EXECUTE')
     OR (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'derm.fn_generated_page_cards(text,integer)'::regprocedure) IS DISTINCT FROM (SELECT acl_pc FROM misc_before)
     OR (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'public.fn_request_generated_measure()'::regprocedure) IS DISTINCT FROM (SELECT acl_req FROM misc_before) THEN
    RAISE EXCEPTION 'VERIFY 9: privileges';
  END IF;
  RAISE NOTICE 'VERIFY passed: %', r1;
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
