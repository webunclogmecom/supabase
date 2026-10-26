-- 2026-10-26_1425 · Send invite phase 7: the test person "ZZ Invite Test" (plan phase 7 step 3)
-- Field, active, no role (stays out of the DUMP picker: role <> 'Technician'), no colour, a note. Soft delete only:
-- clean-up sets it Inactive in the HR App, the row and the sign-in stay. No Jobber link on purpose (a test row).
-- After it: $0 visit and $0 shift bonus on its Pay rates card (HR App), with the "no amount" control before and after.
BEGIN;
DO $d$
DECLARE v_id bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM public.employees WHERE lower(email) = 'webunclogme@gmail.com' OR full_name = 'ZZ Invite Test') THEN
    RAISE EXCEPTION 'guard: a ZZ Invite Test / webunclogme@gmail.com row already exists';
  END IF;
  INSERT INTO public.employees (full_name, email, status, access_level, role, color_hex, notes)
  VALUES ('ZZ Invite Test', 'webunclogme@gmail.com', 'ACTIVE', 'field', NULL, NULL,
          'Send invite phase 7 test person (plan 2026-10-26). Not a real employee; set Inactive after the test.')
  RETURNING id INTO v_id;
  IF (SELECT count(*) FROM public.employees WHERE lower(email) = 'webunclogme@gmail.com' AND status = 'ACTIVE') <> 1 THEN
    RAISE EXCEPTION 'verify: expected 1 active test row';
  END IF;
  RAISE NOTICE 'ZZ Invite Test is employee %', v_id;
END $d$;
COMMIT;
