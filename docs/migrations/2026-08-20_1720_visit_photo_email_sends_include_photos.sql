-- ============================================================================
-- 2026-08-20_1720  visit_photo_email_sends: record whether photos were sent
-- ============================================================================
--
-- Admin Review is getting a "Send email with photos" checkbox, checked by default.
-- When it is cleared, the PDF attached to the regulator email carries no site photos.
--
-- WHY A COLUMN RATHER THAN INFERRING IT. `photo_count` already goes to 0 on such a
-- send, but 0 ALSO means "this visit had no photos", and until today that second case
-- was refused outright by the no_photos gate. Once a deliberate photo-less send is
-- possible the two become indistinguishable in the log, and this log is the audit trail
-- for what was sent to a municipality. Guessing is not good enough there.
--
-- DEFAULT TRUE IS THE HISTORICALLY CORRECT VALUE, not a convenience: every send before
-- today included the photos, because there was no way not to. Backfilling true is a
-- statement of fact about the 60+ existing rows, not a placeholder.
--
-- Rule 8 (audit trail): OPT-OUT, unchanged from the table's own migration
-- (2026-08-15_0626). This is an append-only send log written by one SECURITY DEFINER
-- edge function; it IS the audit record for this feature, and an audit trigger on an
-- audit log is noise. RLS stays on with no policies, service_role only.

BEGIN;

ALTER TABLE public.visit_photo_email_sends
  ADD COLUMN IF NOT EXISTS include_photos boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.visit_photo_email_sends.include_photos IS
  'False when the sender cleared "Send email with photos" and the attached Job Completion Report was rendered without the before/after photo sections. True for every send before 2026-08-20, when photos could not be omitted.';

DO $$
DECLARE v_col int; v_null int; v_default text;
BEGIN
  SELECT count(*) INTO v_col FROM information_schema.columns
   WHERE table_schema='public' AND table_name='visit_photo_email_sends' AND column_name='include_photos';
  IF v_col <> 1 THEN RAISE EXCEPTION 'include_photos was not added'; END IF;

  -- every historical row must read true, or the trail misrepresents what was sent
  SELECT count(*) INTO v_null FROM public.visit_photo_email_sends WHERE include_photos IS NOT TRUE;
  IF v_null <> 0 THEN RAISE EXCEPTION '% existing rows are not true', v_null; END IF;

  SELECT column_default INTO v_default FROM information_schema.columns
   WHERE table_schema='public' AND table_name='visit_photo_email_sends' AND column_name='include_photos';
  IF v_default IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'default is % not true', v_default; END IF;

  RAISE NOTICE 'OK: include_photos added, % existing rows read true', (SELECT count(*) FROM public.visit_photo_email_sends);
END $$;

COMMIT;
