-- Reach of Send invite, run ONCE after 2026-10-26_1000_hr_send_invite.sql is applied, while hr_invites_on is off.
-- As Fred, over every ACTIVE person: the path control (record->'sign_in'->'can_invite' is a boolean for all of them, so
-- a wrong path cannot read as "0 can be invited"), can_invite true for 0 (the switch is off), and invite_reason set for
-- exactly Mark (35), Anthony (37), Michael (40) and Grecia (1), each with the switch sentence (the positive control in
-- the same instrument). Read only; it RAISEs its result, so nothing is kept.
-- usage (from Supabase/): node scripts/q.js scripts/checks/hr_app/reach_send_invite.sql <out.json>   (the result is the error message)
BEGIN;
DO $reach$
DECLARE
  c_fred constant text := json_build_object('sub','5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b','email','fred@ayache.com','role','authenticated')::text;
  e record; s jsonb; v_rows jsonb := '[]'::jsonb; v_n int := 0; v_bool int := 0; v_true int := 0; v_ids bigint[] := '{}'; v_wrong int := 0; v_ok boolean;
BEGIN
  PERFORM set_config('request.jwt.claims', c_fred, true);
  FOR e IN SELECT x.id, x.full_name FROM public.employees x WHERE x.status = 'ACTIVE' ORDER BY x.id LOOP
    s := hr.get_employee_record(e.id)->'sign_in';
    v_n := v_n + 1;
    IF jsonb_typeof(s->'can_invite') = 'boolean' THEN v_bool := v_bool + 1; END IF;
    IF s->'can_invite' = 'true'::jsonb THEN v_true := v_true + 1; END IF;
    IF s->>'invite_reason' IS NOT NULL THEN
      v_ids := v_ids || e.id;
      IF s->>'invite_reason' <> 'Invites are not switched on.' THEN v_wrong := v_wrong + 1; END IF;
    END IF;
    v_rows := v_rows || jsonb_build_array(jsonb_build_object('id', e.id, 'name', split_part(btrim(e.full_name), ' ', 1),
      'state', s->>'state', 'can_invite', s->'can_invite', 'invite_reason', s->>'invite_reason'));
  END LOOP;
  v_ok := v_n > 0 AND v_bool = v_n AND v_true = 0 AND v_ids = ARRAY[1, 35, 37, 40]::bigint[] AND v_wrong = 0;
  RAISE EXCEPTION 'REACH %', jsonb_build_object('ok', v_ok, 'active', v_n, 'can_invite_is_boolean', v_bool, 'can_invite_true', v_true,
    'reason_ids', to_jsonb(v_ids), 'reason_not_the_switch_sentence', v_wrong, 'rows', v_rows);
END $reach$;
ROLLBACK;
