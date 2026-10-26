-- Probe for the HR App sign-in rules and Send invite (2026-10-26_1000_hr_send_invite.sql): the same V1 to V18 as that
-- migration's VERIFY. It asserts its fixtures first (Fred, Diego, Aaron, Yannick, Mark gmail, Anthony yahoo, Michael,
-- Grecia with no email, test.agent as the never-confirmed shape, every app on) and reports ONE failing line naming what
-- changed instead of guessing. It makes its own temporary people (ids 900001 and 900002) and sets the switch
-- (public.app_config hr_invites_on) itself inside each undo block, so it does not depend on the live switch.
-- run.js wraps it in BEGIN ... ROLLBACK and it always ends by RAISE-ing PROBE_RESULT, so nothing is ever kept.
-- Note: the sign-in log ids it uses are taken from a sequence, and a sequence does not roll back (gaps only).
DO $verify$
DECLARE
  c_fred constant text := json_build_object('sub','5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b','email','fred@ayache.com','role','authenticated')::text;
  c_diego constant text := json_build_object('sub','cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8','email','contact@unclogme.com','role','authenticated')::text;
  c_aaron_uid constant uuid := '77d4c343-1e21-44eb-98ce-c221028d028a';
  c_addr constant text := 'zz.invite.probe@unclogme.com';   -- a fresh company address: no sign-in, no person (fixture)
  c_t constant bigint := 900001;                             -- temporary person at c_addr
  c_g constant bigint := 900002;                             -- temporary person at test.agent's address (the never-confirmed shape)
  s_off constant text := 'Invites are not switched on.';
  s_own constant text := 'You cannot change your own sign-in here.';
  s_d7 constant text := 'Invites are off until every app checks access.';
  s_self constant text := 'This address has a sign-in that was never confirmed. Ask Fred or Yannick to clear it first.';
  v_agent uuid; v_snap text; v_now text; v_fix text[];
  r jsonb := '[]'::jsonb; j jsonb; j2 jsonb; k jsonb; k2 jsonb; f jsonb;
  v_ok boolean; v_got text; v_det text; v_a text; v_b text; v_c text;
BEGIN
  -- Fixtures first: every case below leans on these real rows. A change here is reported, never worked around.
  SELECT u.id INTO v_agent FROM auth.users u WHERE lower(btrim(u.email)) = 'test.agent@ayache.com';
  v_fix := array_remove(ARRAY[
    CASE WHEN NOT EXISTS (SELECT 1 FROM public.employees e JOIN auth.users u ON lower(btrim(u.email)) = lower(btrim(e.email))
                           WHERE e.id = 2 AND e.status = 'ACTIVE' AND e.access_level = 'admin' AND u.id = '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b' AND u.email_confirmed_at IS NOT NULL) THEN 'Fred (2, admin, confirmed)' END,
    CASE WHEN NOT EXISTS (SELECT 1 FROM public.employees e JOIN auth.users u ON lower(btrim(u.email)) = lower(btrim(e.email))
                           WHERE e.id = 28 AND e.status = 'ACTIVE' AND e.access_level = 'office' AND u.id = 'cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8' AND u.email_confirmed_at IS NOT NULL) THEN 'Diego (28, office, confirmed)' END,
    CASE WHEN NOT EXISTS (SELECT 1 FROM public.employees e JOIN auth.users u ON lower(btrim(u.email)) = lower(btrim(e.email))
                           WHERE e.id = 26 AND e.status = 'ACTIVE' AND e.access_level = 'office' AND u.id = c_aaron_uid AND u.email_confirmed_at IS NOT NULL
                             AND nullif(u.encrypted_password, '') IS NULL AND (u.banned_until IS NULL OR u.banned_until <= now())) THEN 'Aaron (26, office, Google only, on)' END,
    CASE WHEN NOT EXISTS (SELECT 1 FROM public.employees e JOIN auth.users u ON lower(btrim(u.email)) = lower(btrim(e.email))
                           WHERE e.id = 27 AND e.status = 'ACTIVE' AND e.access_level = 'admin' AND u.email_confirmed_at IS NOT NULL) THEN 'Yannick (27, admin)' END,
    CASE WHEN NOT EXISTS (SELECT 1 FROM public.employees e WHERE e.id = 35 AND e.status = 'ACTIVE' AND split_part(lower(e.email), '@', 2) = 'gmail.com' AND split_part(btrim(e.full_name), ' ', 1) = 'Mark'
                             AND NOT EXISTS (SELECT 1 FROM auth.users u WHERE lower(btrim(u.email)) = lower(btrim(e.email)))) THEN 'Mark (35, gmail, no sign-in)' END,
    CASE WHEN NOT EXISTS (SELECT 1 FROM public.employees e WHERE e.id = 37 AND e.status = 'ACTIVE' AND split_part(lower(e.email), '@', 2) = 'yahoo.com' AND split_part(btrim(e.full_name), ' ', 1) = 'Anthony'
                             AND NOT EXISTS (SELECT 1 FROM auth.users u WHERE lower(btrim(u.email)) = lower(btrim(e.email)))) THEN 'Anthony (37, yahoo, no sign-in)' END,
    CASE WHEN NOT EXISTS (SELECT 1 FROM public.employees e WHERE e.id = 40 AND e.status = 'ACTIVE' AND split_part(btrim(e.full_name), ' ', 1) = 'Michael'
                             AND NOT EXISTS (SELECT 1 FROM auth.users u WHERE lower(btrim(u.email)) = lower(btrim(e.email)))) THEN 'Michael (40, no sign-in)' END,
    CASE WHEN NOT EXISTS (SELECT 1 FROM public.employees e WHERE e.id = 1 AND e.status = 'ACTIVE' AND nullif(btrim(e.email), '') IS NULL AND split_part(btrim(e.full_name), ' ', 1) = 'Grecia') THEN 'Grecia (1, no email)' END,
    CASE WHEN (SELECT count(*) FROM auth.users u WHERE lower(btrim(u.email)) = 'test.agent@ayache.com'
                 AND u.email_confirmed_at IS NULL AND u.invited_at IS NULL AND nullif(u.encrypted_password, '') IS NOT NULL) <> 1
           OR (SELECT count(*) FROM auth.users u WHERE lower(btrim(u.email)) = 'test.agent@ayache.com') <> 1
           OR EXISTS (SELECT 1 FROM public.employees e WHERE lower(btrim(e.email)) = 'test.agent@ayache.com') THEN 'test.agent (one unconfirmed self sign-up, password, never invited, no person)' END,
    CASE WHEN EXISTS (SELECT 1 FROM auth.users u WHERE lower(btrim(u.email)) LIKE 'zz.invite.probe%' OR lower(btrim(u.email)) = 'zz.mark.probe@gmail.com')
           OR EXISTS (SELECT 1 FROM public.employees e WHERE lower(btrim(e.email)) LIKE 'zz.invite.probe%' OR e.id IN (c_t, c_g) OR e.full_name IN ('ZZprobe Invite Person', 'ZZagent Invite Person'))
         THEN 'the probe address, ids or names are taken' END,
    CASE WHEN EXISTS (SELECT 1 FROM hr.access_apps a WHERE a.parent IS NULL AND a.mode <> 'on') OR (SELECT count(*) FROM hr.access_apps a WHERE a.parent IS NULL) < 7
         THEN 'not every app is on' END
  ], NULL);
  IF cardinality(v_fix) > 0 THEN
    RAISE EXCEPTION 'PROBE_RESULT %', jsonb_build_array(jsonb_build_object('t', 'fixtures (Fred, Diego, Aaron, Yannick, Mark, Anthony, Michael, Grecia, test.agent, the probe address, every app on)', 'ok', false, 'got', 'changed: ' || array_to_string(v_fix, ', ')));
  END IF;
  v_now := to_char((now() AT TIME ZONE 'America/New_York')::date, 'YYYY-MM-DD');
  -- What V18 compares against: nothing below may leave a trace (hashes only, never printed).
  v_snap := concat_ws('|',
    (SELECT count(*) || ':' || coalesce(md5(string_agg(c.id || c.status, ',' ORDER BY c.id)), '-') FROM hr.sign_in_changes c),
    (SELECT count(*) || ':' || md5(string_agg(e.id || coalesce(e.status, '') || coalesce(e.email, ''), ',' ORDER BY e.id)) FROM public.employees e),
    (SELECT md5(concat_ws(',', u.invited_at, u.encrypted_password, u.banned_until, u.email_confirmed_at)) FROM auth.users u WHERE u.id = v_agent),
    (SELECT count(*) FILTER (WHERE u.banned_until > now()) || '/' || count(*) FROM auth.users u),
    (SELECT string_agg(a.app || '=' || a.mode, ',' ORDER BY a.app) FROM hr.access_apps a),
    (SELECT coalesce(max(c.value), '<missing>') FROM public.app_config c WHERE c.key = 'hr_invites_on'));

  -- V1 grants: the new rule is owner only; the request, the finish and the readers keep their grants; the CHECK takes invite
  v_ok := false; v_got := NULL;
  BEGIN
    INSERT INTO hr.sign_in_changes (employee_id, action, status) VALUES (2, 'invite', 'refused');
    INSERT INTO hr.sign_in_changes (employee_id, action, status) VALUES (2, 'sign_out', 'done');
    v_ok := NOT has_function_privilege('public', 'hr.fn_invite_refusal(bigint,bigint)', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'hr.fn_invite_refusal(bigint,bigint)', 'EXECUTE')
        AND NOT has_function_privilege('authenticated', 'hr.fn_invite_refusal(bigint,bigint)', 'EXECUTE')
        AND NOT has_function_privilege('service_role', 'hr.fn_invite_refusal(bigint,bigint)', 'EXECUTE')
        AND has_function_privilege('authenticated', 'hr.request_sign_in_action(bigint,text)', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'hr.request_sign_in_action(bigint,text)', 'EXECUTE')
        AND has_function_privilege('service_role', 'hr.finish_sign_in_action(bigint,boolean,text)', 'EXECUTE')
        AND NOT has_function_privilege('authenticated', 'hr.finish_sign_in_action(bigint,boolean,text)', 'EXECUTE')
        AND has_function_privilege('authenticated', 'hr.get_employee_record(bigint)', 'EXECUTE')
        AND has_function_privilege('authenticated', 'hr.update_employee(bigint,jsonb)', 'EXECUTE')
        AND NOT has_function_privilege('authenticated', 'hr.fn_sign_in_summary(bigint)', 'EXECUTE')
        AND NOT has_function_privilege('authenticated', 'hr.trg_status_sign_in()', 'EXECUTE')
        AND NOT has_table_privilege('authenticated', 'hr.sign_in_changes', 'SELECT');
    v_got := 'grants ' || v_ok;
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V1 grants: fn_invite_refusal owner only, request/finish/readers unchanged, CHECK takes invite and sign_out', 'ok', v_ok, 'got', v_got));

  -- V2 switch off (missing key): can_invite false with the switch sentence; the request is refused and logged
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    DELETE FROM public.app_config WHERE key = 'hr_invites_on';
    INSERT INTO public.employees (id, full_name, status, email, access_level) OVERRIDING SYSTEM VALUE VALUES (c_t, 'ZZprobe Invite Person', 'ACTIVE', c_addr, 'field');
    j := hr.get_employee_record(c_t)->'sign_in';
    k := hr.request_sign_in_action(c_t, 'invite');
    v_ok := j->'can_invite' = 'false'::jsonb AND j->>'invite_reason' = s_off AND k->>'ok' = 'false' AND k->>'message' = s_off
        AND EXISTS (SELECT 1 FROM hr.sign_in_changes c WHERE c.employee_id = c_t AND c.action = 'invite' AND c.status = 'refused' AND c.reason = s_off);
    v_got := concat_ws(' | ', j->>'can_invite', j->>'invite_reason', k::text);
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V2 switch off: can_invite false, "Invites are not switched on.", request refused and logged', 'ok', v_ok, 'got', v_got));

  -- V3 switch on, an active person at a fresh company address: can_invite true, the request goes, then the 15-minute sentence
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    INSERT INTO public.app_config (key, value) VALUES ('hr_invites_on', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
    INSERT INTO public.employees (id, full_name, status, email, access_level) OVERRIDING SYSTEM VALUE VALUES (c_t, 'ZZprobe Invite Person', 'ACTIVE', c_addr, 'field');
    j := hr.get_employee_record(c_t)->'sign_in';
    k := hr.request_sign_in_action(c_t, 'invite');
    j2 := hr.get_employee_record(c_t)->'sign_in';
    v_ok := j->'can_invite' = 'true'::jsonb AND j->>'invite_reason' IS NULL
        AND k->>'ok' = 'true' AND k->>'email' = c_addr AND k->'auth_user_id' = 'null'::jsonb AND k->>'log_id' IS NOT NULL AND k->>'action' = 'invite'
        AND k->>'first_name' = 'ZZprobe' AND k->>'name' = 'ZZprobe Invite Person'
        AND EXISTS (SELECT 1 FROM hr.sign_in_changes c WHERE c.id = (k->>'log_id')::bigint AND c.status = 'pending' AND c.action = 'invite' AND c.auth_user_id IS NULL)
        AND j2->'can_invite' = 'false'::jsonb AND j2->>'invite_reason' = 'An invite went to ZZprobe less than 15 minutes ago. Try again later.';
    v_got := concat_ws(' | ', j->>'can_invite', j->>'invite_reason', k - 'log_id', j2->>'can_invite', j2->>'invite_reason');
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V3 switch on, temp person: can_invite true, request ok (first invite, no user id), then the 15-minute sentence', 'ok', v_ok, 'got', v_got));

  -- V4 a second invite within 15 minutes is refused and a refused row is written
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    INSERT INTO public.app_config (key, value) VALUES ('hr_invites_on', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
    INSERT INTO public.employees (id, full_name, status, email, access_level) OVERRIDING SYSTEM VALUE VALUES (c_t, 'ZZprobe Invite Person', 'ACTIVE', c_addr, 'field');
    k := hr.request_sign_in_action(c_t, 'invite');
    k2 := hr.request_sign_in_action(c_t, 'invite');
    v_ok := k->>'ok' = 'true' AND k2->>'ok' = 'false' AND k2->>'message' = 'An invite went to ZZprobe less than 15 minutes ago. Try again later.'
        AND (SELECT count(*) FROM hr.sign_in_changes c WHERE c.employee_id = c_t AND c.status = 'refused') = 1;
    v_got := concat_ws(' | ', k->>'ok', k2::text);
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V4 second invite within 15 minutes: refused, one refused row', 'ok', v_ok, 'got', v_got));

  -- V5 personal addresses (Mark gmail, Anthony yahoo), through the sign-up rule itself
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    INSERT INTO public.app_config (key, value) VALUES ('hr_invites_on', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
    k := hr.request_sign_in_action(35, 'invite');
    k2 := hr.request_sign_in_action(37, 'invite');
    j := hr.get_employee_record(35)->'sign_in';
    v_ok := k->>'message' = 'Invites go to company addresses only (@unclogme.com or @ayache.com). Mark''s email is a personal address.'
        AND k2->>'message' = 'Invites go to company addresses only (@unclogme.com or @ayache.com). Anthony''s email is a personal address.'
        AND j->'can_invite' = 'false'::jsonb AND j->>'invite_reason' = k->>'message';
    v_got := concat_ws(' | ', k->>'message', k2->>'message', j->>'invite_reason');
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V5 Mark (gmail) and Anthony (yahoo): the personal-address sentence, request and record', 'ok', v_ok, 'got', v_got));

  -- V6 Grecia has no email
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    INSERT INTO public.app_config (key, value) VALUES ('hr_invites_on', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
    k := hr.request_sign_in_action(1, 'invite');
    j := hr.get_employee_record(1)->'sign_in';
    v_ok := k->>'message' = 'Grecia has no email in the HR App. Add their company email first.' AND j->>'invite_reason' = k->>'message' AND j->'can_invite' = 'false'::jsonb;
    v_got := concat_ws(' | ', k->>'message', j->>'invite_reason');
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V6 Grecia: the no-email sentence', 'ok', v_ok, 'got', v_got));

  -- V7 an inactive person
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    INSERT INTO public.app_config (key, value) VALUES ('hr_invites_on', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
    INSERT INTO public.employees (id, full_name, status, email, access_level) OVERRIDING SYSTEM VALUE VALUES (c_t, 'ZZprobe Invite Person', 'INACTIVE', c_addr, 'field');
    k := hr.request_sign_in_action(c_t, 'invite');
    v_ok := k->>'message' = 'ZZprobe is not active. Only an active person can get a sign-in.';
    v_got := k->>'message';
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V7 temp person Inactive: the not-active sentence', 'ok', v_ok, 'got', v_got));

  -- V8 Fred's own page: refused, and the record carries no reason (decision 4)
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    INSERT INTO public.app_config (key, value) VALUES ('hr_invites_on', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
    k := hr.request_sign_in_action(2, 'invite');
    j := hr.get_employee_record(2)->'sign_in';
    v_ok := k->>'message' = s_own AND j->>'invite_reason' IS NULL AND j->'can_invite' = 'false'::jsonb;
    v_got := concat_ws(' | ', k->>'message', j->>'can_invite', coalesce(j->>'invite_reason', 'reason null'));
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V8 Fred''s own page: request refused, record invite_reason null, can_invite false', 'ok', v_ok, 'got', v_got));

  -- V9 Aaron already has a confirmed sign-in: refused, and the record carries no reason
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    INSERT INTO public.app_config (key, value) VALUES ('hr_invites_on', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
    k := hr.request_sign_in_action(26, 'invite');
    j := hr.get_employee_record(26)->'sign_in';
    v_ok := k->>'message' = 'Aaron already has a sign-in. If they never chose a password, use Send password reset.'
        AND j->>'invite_reason' IS NULL AND j->'can_invite' = 'false'::jsonb;
    v_got := concat_ws(' | ', k->>'message', j->>'can_invite', coalesce(j->>'invite_reason', 'reason null'));
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V9 Aaron (confirmed): request refused, record invite_reason null, can_invite false', 'ok', v_ok, 'got', v_got));

  -- V10 the never-confirmed shape (test.agent: unconfirmed, a password, never invited) behind a temp person
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    INSERT INTO public.app_config (key, value) VALUES ('hr_invites_on', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
    INSERT INTO public.employees (id, full_name, status, email, access_level) OVERRIDING SYSTEM VALUE VALUES (c_g, 'ZZagent Invite Person', 'ACTIVE', 'test.agent@ayache.com', 'field');
    k := hr.request_sign_in_action(c_g, 'invite');
    j := hr.get_employee_record(c_g)->'sign_in';
    v_ok := k->>'message' = s_self AND j->>'invite_reason' = s_self AND j->'can_invite' = 'false'::jsonb;
    v_got := concat_ws(' | ', k->>'message', j->>'invite_reason');
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V10 the never-confirmed shape: "never confirmed" sentence, request and record', 'ok', v_ok, 'got', v_got));

  -- V11 resend: invited, no password, on -> goes with that user id; a password -> refused; banned -> withdrawn;
  --     never invited and no password -> refused (only our own pending invite can be resent)
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    INSERT INTO public.app_config (key, value) VALUES ('hr_invites_on', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
    INSERT INTO public.employees (id, full_name, status, email, access_level) OVERRIDING SYSTEM VALUE VALUES (c_g, 'ZZagent Invite Person', 'ACTIVE', 'test.agent@ayache.com', 'field');
    UPDATE auth.users SET invited_at = now(), encrypted_password = '', banned_until = NULL WHERE id = v_agent;
    k := hr.request_sign_in_action(c_g, 'invite');
    UPDATE auth.users SET encrypted_password = 'zz-probe-not-a-hash' WHERE id = v_agent;
    v_a := hr.request_sign_in_action(c_g, 'invite')->>'message';
    UPDATE auth.users SET encrypted_password = '', banned_until = now() + interval '1 day' WHERE id = v_agent;
    v_b := hr.request_sign_in_action(c_g, 'invite')->>'message';
    UPDATE auth.users SET invited_at = NULL, banned_until = NULL WHERE id = v_agent;
    v_c := hr.request_sign_in_action(c_g, 'invite')->>'message';
    v_ok := k->>'ok' = 'true' AND k->>'auth_user_id' = v_agent::text AND k->>'email' = 'test.agent@ayache.com'
        AND v_a = s_self AND v_b = 'ZZagent''s invite was withdrawn. Turn the sign-in back on first.' AND v_c = s_self;
    v_got := concat_ws(' | ', 'resend ok=' || (k->>'ok'), 'same user=' || (k->>'auth_user_id' = v_agent::text), v_a, v_b, v_c);
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V11 resend: invited no password goes (same user); password refused; banned withdrawn; never invited refused', 'ok', v_ok, 'got', v_got));

  -- V12 one app back in watch: invites are off (D7)
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    INSERT INTO public.app_config (key, value) VALUES ('hr_invites_on', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
    INSERT INTO public.employees (id, full_name, status, email, access_level) OVERRIDING SYSTEM VALUE VALUES (c_t, 'ZZprobe Invite Person', 'ACTIVE', c_addr, 'field');
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    k := hr.request_sign_in_action(c_t, 'invite');
    j := hr.get_employee_record(c_t)->'sign_in';
    v_ok := k->>'message' = s_d7 AND j->'can_invite' = 'false'::jsonb AND j->>'invite_reason' = s_d7;
    v_got := concat_ws(' | ', k->>'message', j->>'can_invite');
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V12 stamp_studio in watch: "Invites are off until every app checks access."', 'ok', v_ok, 'got', v_got));

  -- V13 Diego (office): the request raises 42501 before anything is logged; his record view carries no invite
  v_ok := false; v_got := NULL;
  BEGIN
    INSERT INTO public.app_config (key, value) VALUES ('hr_invites_on', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
    INSERT INTO public.employees (id, full_name, status, email, access_level) OVERRIDING SYSTEM VALUE VALUES (c_t, 'ZZprobe Invite Person', 'ACTIVE', c_addr, 'field');
    PERFORM set_config('request.jwt.claims', c_diego, true);
    v_a := 'no error';
    BEGIN
      PERFORM hr.request_sign_in_action(c_t, 'invite');
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL; v_a := SQLSTATE || ' ' || coalesce(v_det, '');
    END;
    j := hr.get_employee_record(c_t)->'sign_in';
    v_ok := v_a = '42501 blocker=level in hr access'
        AND NOT EXISTS (SELECT 1 FROM hr.sign_in_changes c WHERE c.employee_id = c_t)
        AND j->'can_invite' = 'false'::jsonb AND j->>'invite_reason' IS NULL;
    v_got := concat_ws(' | ', v_a, j->>'can_invite', coalesce(j->>'invite_reason', 'reason null'));
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V13 Diego: 42501 level, no row, can_invite false and invite_reason null in his view', 'ok', v_ok, 'got', v_got));

  -- V14 the email lock: a pending invite, or any sign-in at the address, locks the email; control: Mark's email still changes
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    INSERT INTO public.app_config (key, value) VALUES ('hr_invites_on', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
    INSERT INTO public.employees (id, full_name, status, email, access_level) OVERRIDING SYSTEM VALUE VALUES (c_t, 'ZZprobe Invite Person', 'ACTIVE', c_addr, 'field');
    INSERT INTO public.employees (id, full_name, status, email, access_level) OVERRIDING SYSTEM VALUE VALUES (c_g, 'ZZagent Invite Person', 'ACTIVE', 'test.agent@ayache.com', 'field');
    -- the sign-in half first, so it reports on its own even where the invite half cannot run
    v_b := 'saved';
    BEGIN PERFORM hr.update_employee(c_g, '{"email": "zz.invite.probe3@unclogme.com"}');
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL; v_b := SQLSTATE || ' ' || coalesce(v_det, '') || ' ' || SQLERRM;
    END;
    v_c := 'refused';
    BEGIN v_c := CASE WHEN (hr.update_employee(35, '{"email": "zz.mark.probe@gmail.com"}')->>'noop')::boolean THEN 'noop' ELSE 'saved' END;
    EXCEPTION WHEN OTHERS THEN v_c := 'error ' || SQLSTATE || ' ' || SQLERRM;
    END;
    v_a := 'saved';
    BEGIN
      k := hr.request_sign_in_action(c_t, 'invite');
      IF k->>'ok' IS DISTINCT FROM 'true' THEN v_a := 'invite not requested: ' || k::text; END IF;
      PERFORM hr.update_employee(c_t, '{"email": "zz.invite.probe2@unclogme.com"}');
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL; v_a := SQLSTATE || ' ' || coalesce(v_det, '') || ' ' || SQLERRM;
    END;
    v_ok := v_a = '22023 blocker=email_has_invite An invite was sent to this email. Changing it is a separate task. Nothing was saved.'
        AND v_b LIKE '22023 blocker=email_has_invite %' AND v_c = 'saved';
    v_got := concat_ws(' | ', 'pending invite: ' || v_a, 'unconfirmed sign-in: ' || v_b, 'Mark: ' || v_c);
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V14 email lock (pending invite, unconfirmed sign-in) with Mark as the control', 'ok', v_ok, 'got', v_got));

  -- V15 Inactive bans an invited, never-clicked sign-in and Active unbans it; Turn off and Turn on reach it too
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    INSERT INTO public.employees (id, full_name, status, email, access_level) OVERRIDING SYSTEM VALUE VALUES (c_g, 'ZZagent Invite Person', 'ACTIVE', 'test.agent@ayache.com', 'field');
    UPDATE auth.users SET invited_at = now(), encrypted_password = '', banned_until = NULL WHERE id = v_agent;
    UPDATE public.employees SET status = 'INACTIVE' WHERE id = c_g;
    v_a := coalesce((SELECT (u.banned_until > now())::text FROM auth.users u WHERE u.id = v_agent), 'not banned')
        || '/' || (SELECT count(*) FROM hr.sign_in_changes c WHERE c.employee_id = c_g AND c.action = 'turn_off' AND c.status = 'done' AND c.reason = 'Set to Inactive' AND c.auth_user_id = v_agent);
    UPDATE public.employees SET status = 'ACTIVE' WHERE id = c_g;
    v_b := coalesce((SELECT (u.banned_until > now())::text FROM auth.users u WHERE u.id = v_agent), 'not banned')
        || '/' || (SELECT count(*) FROM hr.sign_in_changes c WHERE c.employee_id = c_g AND c.action = 'turn_on' AND c.status = 'done' AND c.auth_user_id = v_agent);
    k := hr.request_sign_in_action(c_g, 'turn_off');
    UPDATE auth.users SET banned_until = now() + interval '876000 hours' WHERE id = v_agent;
    k2 := hr.request_sign_in_action(c_g, 'turn_on');
    v_ok := v_a = 'true/1' AND v_b = 'not banned/1'
        AND k->>'ok' = 'true' AND k->>'auth_user_id' = v_agent::text AND k2->>'ok' = 'true' AND k2->>'auth_user_id' = v_agent::text;
    v_got := concat_ws(' | ', 'inactive ' || v_a, 'active ' || v_b, 'turn_off ok=' || (k->>'ok'), 'turn_on ok=' || (k2->>'ok'), coalesce(k->>'message', ''), coalesce(k2->>'message', ''));
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V15 Inactive bans an invited sign-in, Active unbans it, Turn off / Turn on match it', 'ok', v_ok, 'got', v_got));

  -- V16 invited_on and method none (state stays unconfirmed); Activity "Invite sent to"; finish says ban when the person went Inactive
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    INSERT INTO public.app_config (key, value) VALUES ('hr_invites_on', 'true') ON CONFLICT (key) DO UPDATE SET value = 'true';
    INSERT INTO public.employees (id, full_name, status, email, access_level) OVERRIDING SYSTEM VALUE VALUES (c_t, 'ZZprobe Invite Person', 'ACTIVE', c_addr, 'field');
    INSERT INTO public.employees (id, full_name, status, email, access_level) OVERRIDING SYSTEM VALUE VALUES (c_g, 'ZZagent Invite Person', 'ACTIVE', 'test.agent@ayache.com', 'field');
    UPDATE auth.users SET invited_at = now(), encrypted_password = '', banned_until = NULL WHERE id = v_agent;
    -- the summary half first, so it reports on its own even where the invite half cannot run
    j := hr.get_employee_record(c_g)->'sign_in';
    f := NULL; v_a := NULL; v_b := NULL; v_c := NULL;
    BEGIN
      k := hr.request_sign_in_action(c_t, 'invite');
      f := hr.finish_sign_in_action((k->>'log_id')::bigint, true, NULL);
      v_a := (SELECT string_agg(ch->>'new', ',') FROM jsonb_array_elements(hr.get_employee_record(c_t)->'activity') a, jsonb_array_elements(a->'changes') ch
               WHERE a->>'operation' = 'SIGN_IN');
      k2 := hr.request_sign_in_action(c_g, 'invite');
      UPDATE public.employees SET status = 'INACTIVE' WHERE id = c_g;
      v_b := (hr.finish_sign_in_action((k2->>'log_id')::bigint, true, NULL))->>'ban';
      RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
    EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_c := 'invite half: error ' || SQLSTATE || ': ' || SQLERRM; END IF;
    END;
    v_ok := j->>'state' = 'unconfirmed' AND j->>'method' = 'none' AND j->>'invited_on' = v_now
        AND v_c IS NULL AND v_a = 'Invite sent to ' || c_addr
        AND f->'ban' = 'false'::jsonb AND f ? 'person' AND f ? 'by' AND f ? 'other_admins'
        AND v_b = 'true';
    v_got := concat_ws(' | ', 'state ' || coalesce(j->>'state', '-'), 'method ' || coalesce(j->>'method', '-'), 'invited_on ' || coalesce(j->>'invited_on', 'missing'),
                       v_a, 'ban when active=' || (f->>'ban'), 'ban after Inactive=' || v_b, v_c);
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V16 invited_on, method none, Activity "Invite sent to", finish ban flag', 'ok', v_ok, 'got', v_got));

  -- V17 controls, unchanged by this migration: reset, turn off, turn on, sign out, the return shape, the record's sign-in block
  v_ok := false; v_got := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    v_a := concat_ws(' / ',
      hr.request_sign_in_action(26, 'reset_email')->>'message',
      hr.request_sign_in_action(40, 'reset_email')->>'message',
      hr.request_sign_in_action(27, 'turn_off')->>'message',
      hr.request_sign_in_action(26, 'turn_on')->>'message');
    k := hr.request_sign_in_action(26, 'turn_off');
    INSERT INTO hr.sign_in_changes (employee_id, action, status) VALUES (26, 'sign_out', 'done');
    j := hr.get_employee_record(26);
    v_ok := v_a = 'Aaron signs in with Google, so there is no password to reset. / Michael has no sign-in. / An admin''s sign-in cannot be turned off. Change the group first. / Aaron''s sign-in is already on.'
        AND k->>'ok' = 'true' AND k->>'auth_user_id' = c_aaron_uid::text AND k->>'action' = 'turn_off'
        AND (SELECT array_agg(x ORDER BY x) FROM jsonb_object_keys(k) x) = ARRAY['action', 'auth_user_id', 'email', 'first_name', 'log_id', 'name', 'ok']
        AND j->'viewer'->'can_manage_sign_in' = 'true'::jsonb AND j->'sign_in'->>'state' = 'active' AND j->'sign_in'->>'method' = 'google';
    v_got := concat_ws(' | ', v_a, 'turn_off ok=' || (k->>'ok'), j->'sign_in'->>'state', j->'sign_in'->>'method');
    RAISE EXCEPTION 'undo' USING errcode = 'UNDO0';
  EXCEPTION WHEN OTHERS THEN IF SQLSTATE <> 'UNDO0' THEN v_ok := false; v_got := 'error ' || SQLSTATE || ': ' || SQLERRM; END IF;
  END;
  r := r || jsonb_build_array(jsonb_build_object('t', 'V17 controls: reset, turn off, turn on, sign out and the return shape unchanged', 'ok', v_ok, 'got', v_got));

  -- V18 nothing left behind
  PERFORM set_config('request.jwt.claims', '', true);
  v_ok := v_snap = concat_ws('|',
    (SELECT count(*) || ':' || coalesce(md5(string_agg(c.id || c.status, ',' ORDER BY c.id)), '-') FROM hr.sign_in_changes c),
    (SELECT count(*) || ':' || md5(string_agg(e.id || coalesce(e.status, '') || coalesce(e.email, ''), ',' ORDER BY e.id)) FROM public.employees e),
    (SELECT md5(concat_ws(',', u.invited_at, u.encrypted_password, u.banned_until, u.email_confirmed_at)) FROM auth.users u WHERE u.id = v_agent),
    (SELECT count(*) FILTER (WHERE u.banned_until > now()) || '/' || count(*) FROM auth.users u),
    (SELECT string_agg(a.app || '=' || a.mode, ',' ORDER BY a.app) FROM hr.access_apps a),
    (SELECT coalesce(max(c.value), '<missing>') FROM public.app_config c WHERE c.key = 'hr_invites_on'));
  r := r || jsonb_build_array(jsonb_build_object('t', 'V18 nothing left behind (sign-in log, people, test.agent, auth bans, app modes, the switch)', 'ok', v_ok,
    'got', 'sign_in_changes rows ' || (SELECT count(*) FROM hr.sign_in_changes)));

  RAISE EXCEPTION 'PROBE_RESULT %', r;
END $verify$;
