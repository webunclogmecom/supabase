-- 2026-10-27_rollback_stamp_record_who_completed: puts back the three bodies of 2026-10-27 17:00 ET (they record 'stamp-studio' / current_user again).
BEGIN;
SET LOCAL lock_timeout = '3s';
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
          CASE WHEN p_completed THEN coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio') END,
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
    NEW.reopened_by := coalesce(nullif(current_setting('request.jwt.claim.email', true), ''),
                                current_user);
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
         reviewed_by = CASE WHEN p_reviewed THEN coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio') END
   WHERE id = p_row_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'row % not found', p_row_id; END IF;
END $function$;

DO $v$ BEGIN
  IF md5(pg_get_functiondef('derm.set_sheet_completed(text,boolean)'::regprocedure)) IS DISTINCT FROM 'f0cc048e20cc7e20b522a40e412d5703'
  OR md5(pg_get_functiondef('derm.fn_stamp_sheet_reopen_pin()'::regprocedure)) IS DISTINCT FROM 'f84d7cfe992915234d473a58f6131805'
  OR md5(pg_get_functiondef('derm.set_row_reviewed(bigint,boolean)'::regprocedure)) IS DISTINCT FROM '8ec3cc4bca6826991af45225fee956b8' THEN
    RAISE EXCEPTION 'not restored';
  END IF;
END $v$;
COMMIT;
