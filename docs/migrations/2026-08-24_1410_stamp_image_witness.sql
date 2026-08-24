-- ============================================================================
-- 2026-08-24_1410  Stamps follow their image: record WHICH image a stamp was placed
--                  on, and re-point the ordinal when the image list changes
-- ============================================================================
--
-- Fred: "we need to fix cases like this for 833395, where if i delete a page of the derm addresses
-- in the feature, it needs to keep the stamps, not disappear."
--
-- ---------------------------------------------------------------------------
-- PART 0.  THE DEFECT IN ONE SENTENCE
-- ---------------------------------------------------------------------------
--
-- derm.address_row_map.stamp_page is an ORDINAL INTO derm.ticket_page_images(white#), and that list
-- is recomputed from the ticket's live manifest images on every call. An ordinal cannot survive its
-- list changing. Delete an image in the DERM Tracker and every stamp below it keeps an index that
-- now addresses a different image, or none.
--
-- Today the ordinal is the ONLY thing recorded, so the association between a stamp and the sheet it
-- was actually placed on exists nowhere and cannot be recovered. This file records it.
--
-- ---------------------------------------------------------------------------
-- PART 1.  WHY A WITNESS AND NOT A RE-KEY
-- ---------------------------------------------------------------------------
--
-- The theoretically right fix is to stop using an ordinal at all. It is the wrong thing to ship.
-- stamp_page is `effective_page` in derm.v_stamp_row_bands, which is the primary key of
-- derm.page_block_extents and derm.page_row_rules and the image selector in
-- derm.fn_blackout_targets. Measured before deciding: 626 published documents, 122 folders with
-- extents, 620 served rows carrying manual band overrides.
--
-- 🛑 AND THE DECIDING ONE: derm.band_review, the human acceptance ledger for band geometry, HAS NO
-- PAGE COLUMN. It is keyed on the band VALUES. So a re-key would leave every human acceptance still
-- matching while the band it accepted now describes a different physical page -- converting this
-- estate's human backstop into a false all-clear. (That ledger was built on 2026-08-23, by me, and
-- I did not spot this until it was pointed out.)
--
-- The witness gets the whole benefit at none of that risk: the ordinal stays exactly what it is, and
-- gains a way to be CORRECTED when the list moves under it.
--
-- ---------------------------------------------------------------------------
-- PART 2.  ONE TRIGGER RATHER THAN FOUR REWRITTEN FUNCTIONS
-- ---------------------------------------------------------------------------
--
-- Five paths write stamp_page: derm.set_stamp_position, derm.auto_place_page,
-- derm.trg_autoplace_generated, derm.fn_resolve_generated_sheet_for_ticket, and any future one.
-- Teaching each to record the witness means five CREATE OR REPLACE bodies retyped, and
-- 2026-08-06_1316 is the standing record of what retyping a body costs here: seven silent deletions
-- in one function, three and a half hours of runtime failures.
--
-- So the witness is captured by a BEFORE trigger on the table instead. Every writer is covered,
-- including ones not written yet, and not one existing body is touched.
--
-- ⚠ THE TRIGGER MUST NOT RE-DERIVE THE WITNESS WHEN ONLY stamp_page MOVES, or the reconcile in
-- PART 5 would confirm its own answer and the witness would be worthless. It writes ONLY when a
-- stamp is newly placed (INSERT, or stamp_placed_at changes), which is the one moment the ordinal
-- is known to be right because someone or something just chose it.
--
-- ---------------------------------------------------------------------------
-- PART 3.  WHAT THE RECONCILE DELIBERATELY DOES NOT DO
-- ---------------------------------------------------------------------------
--
-- It moves stamp_page. It does NOT move derm.page_block_extents, derm.page_row_rules or
-- derm.redacted_manifest_docs, which are also keyed on effective_page.
--
-- That is a deliberate choice and the direction matters. If the geometry no longer matches the
-- page, derm.v_blackout_blocked_sheets names the folder and the Field Portal card goes BLANK until
-- a person re-measures. Auto-moving an extent onto a page nobody measured is the precise act that
-- leaked client data on 2026-08-19: an extent does not redact anything, it opens the gate onto
-- whatever bands exist. A blank card is a complaint. A wrongly-redacted card is a regulator-facing
-- document showing one client another client's line.
--
-- ⇒ Stamps follow the image automatically. Redaction geometry does not, and must not.
--
-- ---------------------------------------------------------------------------
-- ADR 010 rule 8 (audit): derm.address_row_map is ALREADY audited, and adding a column to an
-- audited table is captured automatically (full-row JSONB) with no trigger work. The backfill in
-- PART 4 therefore writes ~645 audit rows, which is correct and intended: it is a real column
-- change and audit.logs.old_row makes it reversible.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 4.  The column, and a backfill that is honest about what it means
-- ---------------------------------------------------------------------------

ALTER TABLE derm.address_row_map
  ADD COLUMN IF NOT EXISTS stamp_image_url text;

COMMENT ON COLUMN derm.address_row_map.stamp_image_url IS
  'WITNESS: the image URL this stamp was placed on, captured at placement time by '
  'trg_ac_stamp_witness. stamp_page is only an ordinal into derm.ticket_page_images(), which moves '
  'when an address image is added or removed; this is what lets derm.fn_reconcile_stamp_pages() '
  'put the ordinal back. NULL means "no opinion", never "verified". Never re-derive it from '
  'ticket_page_images()[stamp_page] on a folder that is not known clean -- that launders a broken '
  'ordinal into the witness. See docs/migrations/2026-08-24_1410_stamp_image_witness.sql.';

-- 🛑 THIS BACKFILL FREEZES THE CURRENT BELIEF. IT DOES NOT VERIFY IT.
-- For 645 already-placed stamps the ordinal is the only record that exists, so the witness can only
-- be read back out of it. That is sound ONLY because the fleet is known to have zero stamps
-- addressing a missing image right now (derm.v_stamp_placement_health severity 1 is empty, asserted
-- in PART 7 BEFORE this runs). On a broken folder the same expression would write the wrong image
-- and make the defect permanent and invisible. If severity 1 is ever non-empty, repair first.
UPDATE derm.address_row_map a
   SET stamp_image_url = i.imgs[a.stamp_page]
  FROM (SELECT wm, derm.ticket_page_images(wm) AS imgs
          FROM (SELECT DISTINCT white_manifest_number AS wm
                  FROM derm.address_row_map
                 WHERE stamp_placed_at IS NOT NULL) t) i
 WHERE i.wm = a.white_manifest_number
   AND a.stamp_placed_at IS NOT NULL
   AND a.stamp_page IS NOT NULL
   AND a.stamp_image_url IS NULL;

-- ---------------------------------------------------------------------------
-- PART 5.  Capture the witness on every future placement
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION derm.fn_stamp_witness()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
begin
  -- a cleared stamp has no image
  if NEW.stamp_placed_at is null then
    NEW.stamp_image_url := null;

  -- ONLY on a fresh placement. If stamp_placed_at is unchanged then something is correcting the
  -- ordinal (fn_reconcile_stamp_pages), and re-deriving here would make the witness agree with
  -- whatever the ordinal now says -- which is exactly the circularity the witness exists to break.
  elsif TG_OP = 'INSERT' or NEW.stamp_placed_at is distinct from OLD.stamp_placed_at then
    if NEW.stamp_page is not null and NEW.white_manifest_number is not null then
      NEW.stamp_image_url := (derm.ticket_page_images(NEW.white_manifest_number))[NEW.stamp_page];
    else
      NEW.stamp_image_url := null;
    end if;
  end if;
  return NEW;
end $function$;

-- Name sorts AFTER trg_ab_autoplace_generated (which sets NEW.stamp_page on INSERT) and BEFORE
-- trg_address_row_map_updated_at. Row triggers fire alphabetically, so renaming this is a breaking
-- change: placed before trg_ab_ it would read a stamp_page that has not been assigned yet.
DROP TRIGGER IF EXISTS trg_ac_stamp_witness ON derm.address_row_map;
CREATE TRIGGER trg_ac_stamp_witness
  BEFORE INSERT OR UPDATE ON derm.address_row_map
  FOR EACH ROW EXECUTE FUNCTION derm.fn_stamp_witness();

-- ---------------------------------------------------------------------------
-- PART 6.  Put the ordinal back when the image list moves
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION derm.fn_reconcile_stamp_pages(p_white text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
declare v_imgs text[]; v_unknown int; v_moved int := 0;
begin
  if p_white is null then return 0; end if;
  v_imgs := derm.ticket_page_images(p_white);

  -- ALL OR NOTHING. If any placed stamp cannot be located in the new list -- no witness, or its
  -- image is gone -- change NOTHING and let derm.v_stamp_placement_health report the folder.
  -- Moving the ones we can while leaving the rest would produce a half-consistent folder, which is
  -- harder to reason about than a wholly broken one and reads as healthy to a per-row check.
  select count(*) into v_unknown
    from derm.address_row_map a
   where a.white_manifest_number = p_white
     and a.stamp_placed_at is not null
     and (a.stamp_image_url is null or array_position(v_imgs, a.stamp_image_url) is null);
  if v_unknown > 0 then
    return 0;
  end if;

  update derm.address_row_map a
     set stamp_page = array_position(v_imgs, a.stamp_image_url)
   where a.white_manifest_number = p_white
     and a.stamp_placed_at is not null
     and a.stamp_page is distinct from array_position(v_imgs, a.stamp_image_url);
  get diagnostics v_moved = row_count;
  return v_moved;
end $function$;

REVOKE ALL ON FUNCTION derm.fn_reconcile_stamp_pages(text) FROM PUBLIC;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON FUNCTION derm.fn_reconcile_stamp_pages(text) FROM anon';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'REVOKE ALL ON FUNCTION derm.fn_reconcile_stamp_pages(text) FROM authenticated';
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION derm.fn_reconcile_stamp_pages(text) TO service_role;

-- Fire it when the DERM Tracker changes a ticket's address images. This is an AFTER trigger and it
-- calls the RECONCILE, never the resolver: it only re-points stamps that already exist, so it can
-- never place a stamp on a row nobody stamped.
CREATE OR REPLACE FUNCTION derm.trg_reconcile_stamp_pages()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
begin
  perform derm.fn_reconcile_stamp_pages(coalesce(NEW.white_manifest_number, NEW.yellow_ticket_number));
  return null;
end $function$;

DROP TRIGGER IF EXISTS trg_zv_reconcile_stamp_pages ON public.derm_manifests;
CREATE TRIGGER trg_zv_reconcile_stamp_pages
  AFTER UPDATE OF derm_address_url, derm_address_extra_urls, deleted_at
  ON public.derm_manifests
  FOR EACH ROW EXECUTE FUNCTION derm.trg_reconcile_stamp_pages();

-- ---------------------------------------------------------------------------
-- PART 7.  VERIFY
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_n int; v_moved int; v_before text; v_after text; v_wit text; v_sev1 int;
  c_a1 CONSTANT text := 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1735/address_1.jpg';
  c_a2 CONSTANT text := 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1735/address_2.jpg';
BEGIN
  ------------------------------------------------------------------------
  -- 7.1  The backfill's own precondition, asserted after the fact. If any stamp
  --      addressed a missing image, PART 4 wrote a wrong witness and this file
  --      must not be committed.
  ------------------------------------------------------------------------
  SELECT count(*) INTO v_sev1 FROM derm.v_stamp_placement_health WHERE severity = 1;
  IF v_sev1 <> 0 THEN
    RAISE EXCEPTION 'severity 1 is not empty, so the backfill laundered a broken ordinal into % folders', v_sev1;
  END IF;

  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE stamp_placed_at IS NOT NULL AND stamp_image_url IS NULL;
  IF v_n <> 0 THEN
    RAISE EXCEPTION '% placed stamps still have no witness', v_n;
  END IF;

  -- and the witness must actually agree with the ordinal it was read from
  SELECT count(*) INTO v_n
    FROM derm.address_row_map a
    JOIN (SELECT wm, derm.ticket_page_images(wm) AS imgs
            FROM (SELECT DISTINCT white_manifest_number AS wm FROM derm.address_row_map
                   WHERE stamp_placed_at IS NOT NULL) t) i ON i.wm = a.white_manifest_number
   WHERE a.stamp_placed_at IS NOT NULL
     AND i.imgs[a.stamp_page] IS DISTINCT FROM a.stamp_image_url;
  IF v_n <> 0 THEN
    RAISE EXCEPTION '% witnesses disagree with their own ordinal', v_n;
  END IF;

  ------------------------------------------------------------------------
  -- 7.2  END-TO-END: replay FRED'S EXACT ACTION on 833395 and require the stamps
  --      to survive it. Rolled back in a subtransaction.
  --
  --      Today the ticket has one image (address_2) with all three stamps on it.
  --      Re-attach address_1 so the ticket has two, then delete address_2 -- the
  --      page WITHOUT stamps in the original incident was the one deleted, so this
  --      replays the shape that broke: an image disappears from under the ordinal.
  ------------------------------------------------------------------------
  BEGIN
    BEGIN
      -- put the ticket back to TWO images, with the stamped one at position 2,
      -- exactly as it stood before Fred's deletion
      UPDATE derm.address_row_map SET image_url = c_a1 WHERE white_manifest_number = '833395';
      UPDATE public.derm_manifests SET derm_address_url = c_a1,
             derm_address_extra_urls = ARRAY[c_a2]
       WHERE coalesce(white_manifest_number, yellow_ticket_number) = '833395';
      PERFORM derm.fn_reconcile_stamp_pages('833395');

      SELECT string_agg(DISTINCT stamp_page::text, ',') INTO v_before
        FROM derm.address_row_map WHERE white_manifest_number = '833395';
      SELECT DISTINCT stamp_image_url INTO v_wit
        FROM derm.address_row_map WHERE white_manifest_number = '833395';

      -- now Fred deletes the first page in the DERM Tracker
      UPDATE public.derm_manifests SET derm_address_url = c_a2, derm_address_extra_urls = NULL
       WHERE coalesce(white_manifest_number, yellow_ticket_number) = '833395';

      SELECT string_agg(DISTINCT stamp_page::text, ',') INTO v_after
        FROM derm.address_row_map WHERE white_manifest_number = '833395';
      SELECT count(*) INTO v_n FROM derm.v_stamp_placement_health
       WHERE dump_folder = 'ticket-833395' AND severity = 1;

      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;

    -- the witness must have tracked the stamped image, not the ordinal
    IF v_wit IS DISTINCT FROM c_a2 THEN
      RAISE EXCEPTION 'the witness moved off the stamped image (got %)', coalesce(v_wit, 'NULL');
    END IF;
    -- with two images the stamped one sat at position 2 ...
    IF v_before IS DISTINCT FROM '2' THEN
      RAISE EXCEPTION 'setup failed: expected all stamps at page 2 with two images, got %', coalesce(v_before, 'NULL');
    END IF;
    -- ... and after the deletion the trigger must have followed it back to 1
    IF v_after IS DISTINCT FROM '1' THEN
      RAISE EXCEPTION 'THE FIX DOES NOT WORK: after deleting a page the stamps are at page %, not 1', coalesce(v_after, 'NULL');
    END IF;
    IF v_n <> 0 THEN
      RAISE EXCEPTION 'the folder is still reported broken after the reconcile';
    END IF;
    RAISE NOTICE 'END-TO-END OK: deleting an address image moved the stamps 2 -> 1 automatically and left the folder healthy';
  END;

  ------------------------------------------------------------------------
  -- 7.3  CONTROL. Without the witness the same deletion must BREAK the folder.
  --      7.2 alone proves nothing: the stamps might have been at page 1 anyway.
  ------------------------------------------------------------------------
  BEGIN
    BEGIN
      UPDATE derm.address_row_map SET image_url = c_a1 WHERE white_manifest_number = '833395';
      UPDATE public.derm_manifests SET derm_address_url = c_a1,
             derm_address_extra_urls = ARRAY[c_a2]
       WHERE coalesce(white_manifest_number, yellow_ticket_number) = '833395';
      PERFORM derm.fn_reconcile_stamp_pages('833395');

      -- blind the reconcile, which is what the world looked like before this file
      UPDATE derm.address_row_map SET stamp_image_url = NULL WHERE white_manifest_number = '833395';

      UPDATE public.derm_manifests SET derm_address_url = c_a2, derm_address_extra_urls = NULL
       WHERE coalesce(white_manifest_number, yellow_ticket_number) = '833395';

      SELECT string_agg(DISTINCT stamp_page::text, ',') INTO v_after
        FROM derm.address_row_map WHERE white_manifest_number = '833395';
      SELECT count(*) INTO v_n FROM derm.v_stamp_placement_health
       WHERE dump_folder = 'ticket-833395' AND severity = 1;
      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;

    IF v_after IS DISTINCT FROM '2' THEN
      RAISE EXCEPTION 'CONTROL FAILED: without a witness the stamps still ended at page %, so 7.2 proved nothing', coalesce(v_after, 'NULL');
    END IF;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'CONTROL FAILED: the witness-less break was not reported as severity 1';
    END IF;
    RAISE NOTICE 'CONTROL OK: without the witness the same deletion strands the stamps at page 2 and the detector flags it';
  END;

  ------------------------------------------------------------------------
  -- 7.4  Both probes must have left nothing behind.
  ------------------------------------------------------------------------
  IF EXISTS (SELECT 1 FROM public.derm_manifests
              WHERE coalesce(white_manifest_number, yellow_ticket_number) = '833395'
                AND (derm_address_url IS DISTINCT FROM c_a2
                     OR coalesce(derm_address_extra_urls, '{}') <> '{}')) THEN
    RAISE EXCEPTION 'a rolled-back probe leaked a manifest URL change';
  END IF;
  IF EXISTS (SELECT 1 FROM derm.address_row_map
              WHERE white_manifest_number = '833395'
                AND (stamp_page <> 1 OR image_url IS DISTINCT FROM c_a2
                     OR stamp_image_url IS DISTINCT FROM c_a2)) THEN
    RAISE EXCEPTION 'a rolled-back probe leaked a card change';
  END IF;

  ------------------------------------------------------------------------
  -- 7.5  The witness must NOT be re-derived when only the ordinal moves, or it
  --      would confirm whatever the ordinal says and be worthless.
  ------------------------------------------------------------------------
  BEGIN
    BEGIN
      UPDATE derm.address_row_map SET stamp_page = 7 WHERE white_manifest_number = '833395';
      SELECT DISTINCT stamp_image_url INTO v_wit
        FROM derm.address_row_map WHERE white_manifest_number = '833395';
      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;
    IF v_wit IS DISTINCT FROM c_a2 THEN
      RAISE EXCEPTION 'the witness followed a bare stamp_page change (now %), so it is circular', coalesce(v_wit, 'NULL');
    END IF;
    RAISE NOTICE 'OK: the witness ignores a bare ordinal change';
  END;

  ------------------------------------------------------------------------
  -- 7.6  A cleared stamp must lose its witness.
  ------------------------------------------------------------------------
  BEGIN
    BEGIN
      UPDATE derm.address_row_map
         SET stamp_placed_at = NULL, stamp_page = NULL, stamp_x_pct = NULL, stamp_y_pct = NULL
       WHERE white_manifest_number = '833395';
      SELECT count(*) INTO v_n FROM derm.address_row_map
       WHERE white_manifest_number = '833395' AND stamp_image_url IS NOT NULL;
      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;
    IF v_n <> 0 THEN
      RAISE EXCEPTION '% cleared stamps kept a witness', v_n;
    END IF;
    RAISE NOTICE 'OK: clearing a stamp clears its witness';
  END;

  RAISE NOTICE 'ALL OK: 645-odd witnesses recorded, deletion now re-points stamps automatically';
END $$;

COMMIT;
