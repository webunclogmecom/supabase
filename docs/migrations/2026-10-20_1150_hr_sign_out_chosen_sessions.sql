-- 2026-10-20_1150 · HR App: sign out ONE device (or one grouped row) from the Security tab
--
-- Fred, 2026-10-20, on the "Signed in on" list: "go ahead with 1 to 4" (group identical devices into one row, name
-- the Claude desktop app's browser correctly, a Sign out button on each row, show when each sign-in started).
-- Grouping, naming and the start date are app-side; this adds the one database piece: hr.sign_out_sessions(id, ids)
-- ends the chosen sessions of that person's ONE confirmed sign-in. Same rights as hr.sign_out_devices (the person
-- themselves, or an admin; hr.fn_devices_target). Your own CURRENT session is never ended here (it is skipped and
-- said so). Recorded in hr.sign_in_changes as 'sign_out' ("1 device"). Sessions not belonging to that person are
-- ignored, never an error that would reveal them. Rule 8: no new table. Revoked from PUBLIC/anon by name.
-- Rollback: DROP FUNCTION hr.sign_out_sessions(bigint, uuid[]);
BEGIN;

CREATE FUNCTION hr.sign_out_sessions(p_employee_id bigint, p_session_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t record; v_cur text; v_n int; v_by text; v_first text; v_skipped boolean;
begin
  select * into t from hr.fn_devices_target(p_employee_id);
  select split_part(btrim(e.full_name), ' ', 1) into v_first from public.employees e where e.id = p_employee_id;
  if t.o_uid is null then
    return jsonb_build_object('ok', false, 'message', v_first || ' has no sign-in.');
  end if;
  if p_session_ids is null or cardinality(p_session_ids) = 0 then
    return jsonb_build_object('ok', false, 'message', 'Pick a device to sign out.');
  end if;
  v_cur := nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'session_id';
  v_skipped := t.o_self and v_cur is not null and v_cur::uuid = any (p_session_ids);
  delete from auth.sessions s
   where s.user_id = t.o_uid and s.id = any (p_session_ids)
     and not (t.o_self and s.id::text is not distinct from v_cur);
  get diagnostics v_n = row_count;
  if v_n > 0 then
    select u.email into v_by from auth.users u where u.id = auth.uid();
    insert into hr.sign_in_changes (employee_id, auth_user_id, action, status, reason, requested_by_email, requested_by_employee, finished_at)
    values (p_employee_id, t.o_uid, 'sign_out', 'done', case when v_n = 1 then '1 device' else v_n || ' devices' end, v_by, t.o_caller, now());
  end if;
  return jsonb_build_object('ok', true, 'signed_out', v_n,
    'message', case when v_n = 0 and v_skipped then 'That is the device you are using. Sign out from the menu instead.'
                    when v_n = 0 then 'That device was already signed out.'
                    when v_n = 1 then 'Signed out on 1 device.'
                    else 'Signed out on ' || v_n || ' devices.' end
               || case when v_n > 0 and v_skipped then ' This device stays signed in.' else '' end);
end $function$;

REVOKE ALL ON FUNCTION hr.sign_out_sessions(bigint, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.sign_out_sessions(bigint, uuid[]) TO authenticated, service_role;

DO $v$
DECLARE r jsonb; fred text := json_build_object('sub','5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b','email','fred@ayache.com','role','authenticated')::text;
  aaron text := json_build_object('sub','77d4c343-1e21-44eb-98ce-c221028d028a','email','aaron@unclogme.com','role','authenticated')::text;
  s_one uuid; s_cur uuid; n_before int;
BEGIN
  -- probe on Serena's sessions, always rolled back
  SELECT id INTO s_one FROM auth.sessions WHERE user_id = '5c5df96c-1924-410a-a996-e3e58c44e3c2' ORDER BY created_at LIMIT 1;
  SELECT count(*) INTO n_before FROM auth.sessions WHERE user_id = '5c5df96c-1924-410a-a996-e3e58c44e3c2';
  BEGIN
    PERFORM set_config('request.jwt.claims', fred, true);
    IF s_one IS NOT NULL THEN
      r := hr.sign_out_sessions(42, ARRAY[s_one]);
      IF (r->>'signed_out')::int <> 1 THEN RAISE EXCEPTION 'V1 one session %', r; END IF;
      IF (SELECT count(*) FROM auth.sessions WHERE user_id = '5c5df96c-1924-410a-a996-e3e58c44e3c2') <> n_before - 1 THEN RAISE EXCEPTION 'V2 count'; END IF;
    END IF;
    -- a session of someone else is ignored (Fred's own id passed for Serena)
    SELECT id INTO s_cur FROM auth.sessions WHERE user_id = '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b' LIMIT 1;
    r := hr.sign_out_sessions(42, ARRAY[s_cur]);
    IF (r->>'signed_out')::int <> 0 THEN RAISE EXCEPTION 'V3 foreign session touched'; END IF;
    -- your own current session is kept
    PERFORM set_config('request.jwt.claims', json_build_object('sub','5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b','email','fred@ayache.com','role','authenticated','session_id', s_cur)::text, true);
    r := hr.sign_out_sessions(2, ARRAY[s_cur]);
    IF (r->>'signed_out')::int <> 0 OR position('using' in r->>'message') = 0 THEN RAISE EXCEPTION 'V4 current session %', r; END IF;
    -- office cannot sign out someone else
    PERFORM set_config('request.jwt.claims', aaron, true);
    BEGIN PERFORM hr.sign_out_sessions(42, ARRAY[s_one]); RAISE EXCEPTION 'V5 office allowed';
    EXCEPTION WHEN sqlstate '42501' THEN NULL; END;
    RAISE EXCEPTION 'rollback_probe';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'rollback_probe' THEN RAISE; END IF; END;
  IF (SELECT count(*) FROM auth.sessions WHERE user_id = '5c5df96c-1924-410a-a996-e3e58c44e3c2') <> n_before THEN RAISE EXCEPTION 'V6 probe not rolled back'; END IF;
  IF has_function_privilege('anon', 'hr.sign_out_sessions(bigint,uuid[])', 'EXECUTE') THEN RAISE EXCEPTION 'V7 anon'; END IF;
  PERFORM set_config('request.jwt.claims', '', true);
END $v$;

COMMIT;
