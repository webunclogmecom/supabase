-- ============================================================================
-- 2026-10-27_1703_stamp_record_who_completed
-- Stamp Studio: record the PERSON who marks a sheet completed, reopens it, or reviews a row. Applied 2026-10-27 17:03 ET.
-- ============================================================================
-- THE DEFECT (found 2026-10-27 while building the sheet skip, EizZ2IuY; Fred: "Do this task here")
--   derm.set_sheet_completed wrote completed_by from current_setting('request.jwt.claim.email') (SINGULAR claim).
--   PostgREST sets request.jwt.claims (PLURAL, a JSON object), so the singular one is always empty and every manual
--   completion recorded 'stamp-studio': 143 rows on 2026-10-27, never an email. Same defect class as
--   audit.logs.changed_by (Supabase CLAUDE.md). Two more functions had the same line:
--     derm.fn_stamp_sheet_reopen_pin   reopened_by (fell back to current_user, i.e. 'postgres' inside this SECDEF trigger)
--     derm.set_row_reviewed            reviewed_by (no app caller since the 2026-10-21 switch-on; fixed for consistency)
--   The person IS known: audit.logs.jwt_claims->>'email' carries it on every completion through the app since sign-in.
-- THE FIX
--   Each line now calls derm._actor(<the same default>), the one helper already used for band_set_by and
--   stamp_placed_by: the email in request.jwt.claims; a service_role caller with no email is 'stamp-studio-ai' (Fred:
--   one label for everything machine-made); no claims (direct SQL) keeps the old default. One line per function, spliced
--   from the live bodies with an md5 guard. Nothing compares these columns to a value (swept 2026-10-27): the machine
--   completers write 'stamp-studio-ai' themselves and keep an existing value; the others only clear or show them.
-- NOT CHANGED: derm.set_sheet_skipped (already reads auth.users by auth.uid()), auth.email(), derm._actor.
-- NO BACKFILL: the 143 'stamp-studio' rows stay as they are (a separate decision; the person is in audit.logs).
-- Rule 8: no table change. ROLLBACK: 2026-10-27_rollback_stamp_record_who_completed.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_functiondef('derm.set_sheet_completed(text,boolean)'::regprocedure)) IS DISTINCT FROM 'f0cc048e20cc7e20b522a40e412d5703'
  OR md5(pg_get_functiondef('derm.fn_stamp_sheet_reopen_pin()'::regprocedure)) IS DISTINCT FROM 'f84d7cfe992915234d473a58f6131805'
  OR md5(pg_get_functiondef('derm.set_row_reviewed(bigint,boolean)'::regprocedure)) IS DISTINCT FROM '8ec3cc4bca6826991af45225fee956b8' THEN
    RAISE EXCEPTION 'a function changed since this file was written: splice again';
  END IF;
END $g$;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS
  SELECT p.oid::regprocedure::text AS sig, p.proacl::text AS acl, p.prosecdef AS secdef FROM pg_proc p
   WHERE p.oid IN ('derm.set_sheet_completed(text,boolean)'::regprocedure, 'derm.fn_stamp_sheet_reopen_pin()'::regprocedure,
                   'derm.set_row_reviewed(bigint,boolean)'::regprocedure);

-- CONTROL: the old bodies record 'stamp-studio' for a signed-in person
DO $p$
DECLARE v_f text; v_uid uuid; v_mail text; v_row bigint; s record; v_rev text; v_res jsonb := '{}';
BEGIN
  SELECT x.dump_folder INTO v_f FROM (SELECT st.dump_folder FROM derm.stamp_sheet_status st WHERE st.completed
                                      ORDER BY st.completed_at DESC NULLS LAST LIMIT 10) x
   WHERE derm.fn_sheet_publishable(x.dump_folder) IS NULL LIMIT 1;
  SELECT u.id, u.email INTO v_uid, v_mail FROM auth.users u WHERE u.email = 'fred@ayache.com';
  SELECT m.id INTO v_row FROM derm.address_row_map m WHERE m.reviewed_at IS NULL ORDER BY m.id LIMIT 1;
  IF v_f IS NULL OR v_uid IS NULL OR v_row IS NULL THEN RAISE EXCEPTION 'probe: no fixture (% % %)', v_f, v_uid, v_row; END IF;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_mail, 'role', 'authenticated')::text, true);
    PERFORM derm.set_sheet_completed(v_f, false);
    SELECT * INTO s FROM derm.stamp_sheet_status WHERE dump_folder = v_f;
    v_res := v_res || jsonb_build_object('reopened_by', s.reopened_by);
    PERFORM derm.set_sheet_completed(v_f, true);
    SELECT * INTO s FROM derm.stamp_sheet_status WHERE dump_folder = v_f;
    v_res := v_res || jsonb_build_object('completed_by', s.completed_by);
    PERFORM derm.set_row_reviewed(v_row, true);
    SELECT reviewed_by INTO v_rev FROM derm.address_row_map WHERE id = v_row;
    v_res := v_res || jsonb_build_object('reviewed_by', v_rev);
    PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
    PERFORM derm.set_sheet_completed(v_f, false);
    PERFORM derm.set_sheet_completed(v_f, true);
    SELECT * INTO s FROM derm.stamp_sheet_status WHERE dump_folder = v_f;
    v_res := v_res || jsonb_build_object('machine', s.completed_by);
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM derm.set_sheet_completed(v_f, false);
    PERFORM derm.set_sheet_completed(v_f, true);
    SELECT * INTO s FROM derm.stamp_sheet_status WHERE dump_folder = v_f;
    v_res := v_res || jsonb_build_object('plain_sql', s.completed_by);
    RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = v_res::text;
  EXCEPTION WHEN SQLSTATE 'P0099' THEN v_res := SQLERRM::jsonb;
  END;
  IF v_res->>'completed_by' IS DISTINCT FROM 'stamp-studio' OR v_res->>'reviewed_by' IS DISTINCT FROM 'stamp-studio' THEN
    RAISE EXCEPTION 'CONTROL (old bodies) failed: %', v_res;
  END IF;
  -- undone: the sheet and the row are as they were
  IF NOT (SELECT completed FROM derm.stamp_sheet_status WHERE dump_folder = v_f)
     OR (SELECT reviewed_at FROM derm.address_row_map WHERE id = v_row) IS NOT NULL THEN
    RAISE EXCEPTION 'probe was not undone';
  END IF;
  RAISE NOTICE 'CONTROL %', v_res;
END $p$;

CREATE OR REPLACE FUNCTION derm.set_sheet_completed(p_dump_folder text, p_completed boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_block text;
BEGIN
  perform hr.fn_check_app('stamp_studio', 'edit', 'mark a sheet completed');   -- 2026-10-20_1700 access phase 4
  PERFORM derm._require_stamp_key();

  -- 🛑 COMPLETION IS A STATEMENT ABOUT THE GEOMETRY. A sheet that cannot be blacked out must not
  -- be markable complete (Fred, 2026-09-03: "if it's marked as complete then after 5 min it needs a
  -- blackout. period, if not then it can't be marked as complete").
  IF p_completed THEN
    v_block := derm.fn_sheet_publishable(p_dump_folder);
    IF v_block IS NOT NULL THEN
      -- 2026-09-14 (Fred): what an operator reads must be plain language with no technical words.
      -- The blocker CODE and the folder go to DETAIL, which the app never shows; the MESSAGE is the
      -- same page-aware sentence the header banner already shows, so the two never disagree.
      RAISE EXCEPTION 'This sheet cannot be marked complete yet. %',
        COALESCE(derm.fn_sheet_publishable_detail(p_dump_folder)->>'message', derm.fn_publishable_hint(v_block))
        USING DETAIL = 'blocker=' || v_block || ' folder=' || p_dump_folder;
    END IF;
  END IF;
  INSERT INTO derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
  VALUES (p_dump_folder, p_completed,
          CASE WHEN p_completed THEN now() END,
          CASE WHEN p_completed THEN derm._actor('stamp-studio') END,   -- 2026-10-27: the signed-in person (derm._actor)
          now())
  ON CONFLICT (dump_folder) DO UPDATE SET
    completed    = EXCLUDED.completed,
    completed_at = CASE WHEN EXCLUDED.completed THEN now() ELSE NULL END,
    completed_by = CASE WHEN EXCLUDED.completed THEN EXCLUDED.completed_by ELSE NULL END,
    updated_at   = now();
END $function$;

CREATE OR REPLACE FUNCTION derm.fn_stamp_sheet_reopen_pin()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
begin
  if OLD.completed and not NEW.completed then
    NEW.reopened_at := now();
    NEW.reopened_by := derm._actor(current_user);   -- 2026-10-27: the signed-in person (derm._actor)
  elsif NEW.completed then
    -- the review has been answered, so re-arm auto-completion
    NEW.reopened_at := null;
    NEW.reopened_by := null;
  end if;
  return NEW;
end $function$;

CREATE OR REPLACE FUNCTION derm.set_row_reviewed(p_row_id bigint, p_reviewed boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
BEGIN
  PERFORM derm._require_stamp_key();
  UPDATE derm.address_row_map
     SET reviewed_at = CASE WHEN p_reviewed THEN now() END,
         reviewed_by = CASE WHEN p_reviewed THEN derm._actor('stamp-studio') END
   WHERE id = p_row_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'row % not found', p_row_id; END IF;
END $function$;

-- VERIFY: the person, the machine label and the plain-SQL default
DO $p$
DECLARE v_f text; v_uid uuid; v_mail text; v_row bigint; s record; v_rev text; v_res jsonb := '{}';
BEGIN
  SELECT x.dump_folder INTO v_f FROM (SELECT st.dump_folder FROM derm.stamp_sheet_status st WHERE st.completed
                                      ORDER BY st.completed_at DESC NULLS LAST LIMIT 10) x
   WHERE derm.fn_sheet_publishable(x.dump_folder) IS NULL LIMIT 1;
  SELECT u.id, u.email INTO v_uid, v_mail FROM auth.users u WHERE u.email = 'fred@ayache.com';
  SELECT m.id INTO v_row FROM derm.address_row_map m WHERE m.reviewed_at IS NULL ORDER BY m.id LIMIT 1;
  IF v_f IS NULL OR v_uid IS NULL OR v_row IS NULL THEN RAISE EXCEPTION 'probe: no fixture (% % %)', v_f, v_uid, v_row; END IF;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_mail, 'role', 'authenticated')::text, true);
    PERFORM derm.set_sheet_completed(v_f, false);
    SELECT * INTO s FROM derm.stamp_sheet_status WHERE dump_folder = v_f;
    v_res := v_res || jsonb_build_object('reopened_by', s.reopened_by);
    PERFORM derm.set_sheet_completed(v_f, true);
    SELECT * INTO s FROM derm.stamp_sheet_status WHERE dump_folder = v_f;
    v_res := v_res || jsonb_build_object('completed_by', s.completed_by);
    PERFORM derm.set_row_reviewed(v_row, true);
    SELECT reviewed_by INTO v_rev FROM derm.address_row_map WHERE id = v_row;
    v_res := v_res || jsonb_build_object('reviewed_by', v_rev);
    PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
    PERFORM derm.set_sheet_completed(v_f, false);
    PERFORM derm.set_sheet_completed(v_f, true);
    SELECT * INTO s FROM derm.stamp_sheet_status WHERE dump_folder = v_f;
    v_res := v_res || jsonb_build_object('machine', s.completed_by);
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM derm.set_sheet_completed(v_f, false);
    PERFORM derm.set_sheet_completed(v_f, true);
    SELECT * INTO s FROM derm.stamp_sheet_status WHERE dump_folder = v_f;
    v_res := v_res || jsonb_build_object('plain_sql', s.completed_by);
    RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = v_res::text;
  EXCEPTION WHEN SQLSTATE 'P0099' THEN v_res := SQLERRM::jsonb;
  END;
  IF v_res IS DISTINCT FROM jsonb_build_object('reopened_by', v_mail, 'completed_by', v_mail, 'reviewed_by', v_mail,
                                          'machine', 'stamp-studio-ai', 'plain_sql', 'stamp-studio') THEN
    RAISE EXCEPTION 'VERIFY (new bodies) failed: %', v_res;
  END IF;
  -- undone: the sheet and the row are as they were
  IF NOT (SELECT completed FROM derm.stamp_sheet_status WHERE dump_folder = v_f)
     OR (SELECT reviewed_at FROM derm.address_row_map WHERE id = v_row) IS NOT NULL THEN
    RAISE EXCEPTION 'probe was not undone';
  END IF;
  RAISE NOTICE 'VERIFY %', v_res;
END $p$;

DO $v$ BEGIN
  IF EXISTS (SELECT 1 FROM acl_before b JOIN pg_proc p ON p.oid = b.sig::regprocedure
              WHERE p.proacl::text IS DISTINCT FROM b.acl OR p.prosecdef <> b.secdef) THEN
    RAISE EXCEPTION 'VERIFY: privileges changed';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'derm' AND p.prokind = 'f' AND p.proname <> '_actor'
                AND pg_get_functiondef(p.oid) LIKE '%current_setting(''request.jwt.claim.email''%') THEN
    RAISE EXCEPTION 'VERIFY: a derm function still reads request.jwt.claim.email';
  END IF;
END $v$;
COMMIT;
