-- 2026-09-03_0030_derm_email_sends_include_photos.sql
--
-- WHAT: adds public.derm_email_sends.include_photos (boolean, nullable). Records whether the
--       Service Report attached to a DERM email was rendered WITH the service photos.
--
-- WHY:  Fred, 2026-09-02: *"at the DERM App at the dialog box, we don't have the checkbox of to
--       send with photos or not like at the admin review app we have, so add that."*
--
--       The switch is real, not decorative: send-derm-email called the pdf-service with
--       `include_photos: true` HARDCODED, so every report a municipality has ever received from
--       that path carried the photos whether or not anyone wanted them. Exposing the choice means
--       the send log has to be able to say which was sent, or the record of a compliance
--       submission stops matching the document that went out.
--
--       The sibling path already does this: public.visit_photo_email_sends.include_photos has
--       existed since the Admin Review dialog got its checkbox. This closes the same gap on the
--       DERM side rather than inventing a second convention.
--
-- ⚠ NULLABLE, AND NO BACKFILL. The 110 existing rows predate the choice. They were all sent with
--    photos, but writing `true` into them would be manufacturing a record of a decision nobody
--    made: NULL honestly says "this send happened before the flag existed". A reader who needs the
--    historical answer gets it from this migration, not from a value that looks like data.
--
-- RULE 8 (audit): public.derm_email_sends ALREADY carries the audit.log_change trigger (verified
--    against pg_trigger before writing this, not assumed). Adding a column to an already-audited
--    table is captured automatically in the full-row JSONB, so no trigger change is needed.
-- RULE 2/3: not derived and not copied. It records an INPUT to the send that is not recoverable
--    from anything else afterwards: the rendered PDF is not stored, so without this column there is
--    no way to tell later whether a given regulator submission included the photographs.
-- RULE 7: not a timestamp, not money. n/a.

BEGIN;

ALTER TABLE public.derm_email_sends
  ADD COLUMN IF NOT EXISTS include_photos boolean;

COMMENT ON COLUMN public.derm_email_sends.include_photos IS
  'Whether the attached Service Report was rendered with the service photos. NULL for rows written before the DERM dialog offered the choice (2026-09-03); those were all sent with photos, deliberately not backfilled so a real decision is distinguishable from a default. Mirrors public.visit_photo_email_sends.include_photos.';

DO $$
DECLARE
  v_exists boolean; v_nullable text; v_type text; v_nulls int; v_rows int; v_audited boolean;
BEGIN
  SELECT true, is_nullable, data_type INTO v_exists, v_nullable, v_type
    FROM information_schema.columns
   WHERE table_schema='public' AND table_name='derm_email_sends' AND column_name='include_photos';
  IF NOT coalesce(v_exists,false) THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: include_photos was not added';
  END IF;
  IF v_type <> 'boolean' OR v_nullable <> 'YES' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: column is % / nullable=%, expected boolean / YES', v_type, v_nullable;
  END IF;

  -- 2. every existing row is NULL. A non-null here would mean something backfilled a decision.
  SELECT count(*) FILTER (WHERE include_photos IS NULL), count(*)
    INTO v_nulls, v_rows FROM public.derm_email_sends;
  IF v_nulls <> v_rows THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % of % existing rows carry a value; history must stay NULL', v_rows - v_nulls, v_rows;
  END IF;

  -- 3. rule 8, asserted rather than asserted-in-prose: the table really is audited, so the new
  --    column rides the existing trigger.
  SELECT EXISTS (
    SELECT 1 FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_proc p ON p.oid = t.tgfoid
      JOIN pg_namespace pn ON pn.oid = p.pronamespace
     WHERE pn.nspname='audit' AND p.proname='log_change' AND NOT t.tgisinternal
       AND n.nspname='public' AND c.relname='derm_email_sends') INTO v_audited;
  IF NOT v_audited THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: derm_email_sends is NOT audited, so this column would be unrecorded';
  END IF;

  RAISE NOTICE 'OK: include_photos added, % existing rows left NULL, table audited.', v_rows;
END $$;

COMMIT;
