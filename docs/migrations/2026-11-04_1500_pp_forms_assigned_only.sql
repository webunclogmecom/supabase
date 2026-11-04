-- 2026-11-04_1500_pp_forms_assigned_only
-- Fred, 2026-11-04: "fix the Picture Planner app the form tab when being an Field members who opens it and shows all the
-- forms for them to only show the ones assigned to them, only office or admin people can see all the forms."
-- Reverses part of 2026-10-27_2130 (Trello AIwCYcmn), where the Field group read every submitted form.
--
-- WHAT "ASSIGNED" MEANS: the employee is an assignee of the form's Calendar task
--   (public.property_intakes.calendar_task_id -> ops.calendar_task_assignees). The reference is read live, so moving the
--   task to another person in the Calendar moves the form with it. A form with no task has no assignee and is not listed
--   for a Forms-only person (measured today: 356-MAS form 1123, filled by Grecia, has no task). The typed collector name is
--   NOT used: anyone with the link types what they like.
-- WHO: a Forms-only caller (hr.fn_pp_forms_only: See-forms switch open AND Picture Planner below View, by level).
--   Admin and Office hold Picture Planner Edit and take the unchanged branch, so they see every form.
-- WHAT CHANGES, in the three places a Forms-only person reads a form:
--   client.list_intake_forms   the list: their assigned rows only
--   client.get_intake          by the address too: another form raises 42501 'This form is not assigned to you.'
--   client.fn_intake_photo_shown  the storage gate's per-object rule: their assigned forms' photos only
--   NEW client.fn_intake_assigned_to_me(bigint), the ONE rule all three call (reads tables authenticated cannot: SECDEF).
--   hr.access_apps pp_forms: name "See submitted forms" -> "See their assigned forms" (the key stays; the HR App reads the name).
-- NOT CHANGED: public.fn_request_gate, storage_access_gate, client.v_intake_submissions (its path stays shut for Forms-only).
-- Audit (rule 8): no new table. hr.access_apps is unchanged in shape.
-- Checks: scripts/checks/hr_app/probe_pp_forms.sql. Control: on the 2026-10-27_2130 bodies its assigned-only cases FAIL.
-- Rollback: 2026-11-04_rollback_pp_forms_assigned_only.sql. App wording: Picture Planner + HR App prompts of the same date.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path TO '';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('client.list_intake_forms()'::regprocedure)) <> '7aab9579e1971065919b28b94d061d71' THEN RAISE EXCEPTION 'guard: list_intake_forms moved'; END IF;
  IF md5(pg_get_functiondef('client.get_intake(bigint)'::regprocedure)) <> '8c72963048d368ad995f48c4c08ec687' THEN RAISE EXCEPTION 'guard: get_intake moved'; END IF;
  IF md5(pg_get_functiondef('client.fn_intake_photo_shown(text)'::regprocedure)) <> 'c8f88ee4c4b67a5d5867b67afa380e0e' THEN RAISE EXCEPTION 'guard: fn_intake_photo_shown moved'; END IF;
END $guard$;

CREATE FUNCTION client.fn_intake_assigned_to_me(p_intake_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- 2026-11-04_1500 (Fred): is the signed-in employee an assignee of this form's Calendar task? The ONE rule. No caller: false.
  select exists (
    select 1 from public.property_intakes i
      join ops.calendar_task_assignees a on a.task_id = i.calendar_task_id
     where i.id = p_intake_id and a.employee_id = hr.fn_access_caller())
$function$;
REVOKE ALL ON FUNCTION client.fn_intake_assigned_to_me(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION client.fn_intake_assigned_to_me(bigint) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION client.list_intake_forms()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
-- 2026-10-27_2130 (AIwCYcmn): the Forms list for everyone, as jsonb (no embedding). Rows of client.v_intake_submissions,
-- the one completeness rule. A Forms-only caller (See submitted forms, Picture Planner below View, by level) gets
-- submitted rows without the accept counts and waiting rows with status and expiry only (Fred, Q3).
declare v_fo boolean; v jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))) then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  v_fo := hr.fn_pp_forms_only();
  if not v_fo then
    perform hr.fn_require_app('picture_planner', 'view');
  end if;
  select coalesce(jsonb_agg(
           case when not v_fo then to_jsonb(s)
                when s.submitted_at is not null then to_jsonb(s) - 'accepted_count' - 'last_accepted_at'
                else jsonb_build_object('intake_id', s.intake_id, 'state', s.state, 'property_id', s.property_id,
                       'client_id', s.client_id, 'client_code', s.client_code, 'client_name', s.client_name,
                       'address', s.address, 'city', s.city, 'property_deleted', s.property_deleted,
                       'requested_at', s.requested_at, 'expires_at', s.expires_at) end
           order by s.intake_id desc), '[]'::jsonb)
    into v
    from client.v_intake_submissions s
   where not v_fo or client.fn_intake_assigned_to_me(s.intake_id);   -- 2026-11-04_1500: a Forms-only caller lists only the forms assigned to them
  return v;
end $function$;

CREATE OR REPLACE FUNCTION client.get_intake(p_intake_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_i            public.property_intakes;
  v_submitted    boolean;
  v_req          text[];
  v_known        text[];
  v_orphans      text[];
  v_photos       jsonb := '{}'::jsonb;
  v_sections     jsonb;
  v_other        jsonb;
  v_other_photos jsonb;
  v_accepted     jsonb;
  v_prop         jsonb;
  v_status       text;
  v_state        text;
  v_missing      text[];
  v_applicable   int;
  v_forms_only   boolean;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', '')))
      then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  -- 2026-10-27_2130 (Trello AIwCYcmn): a "See submitted forms" person whose Picture Planner level is below View reads a
  -- submitted form without the accept history, or a waiting form's status; everyone else is checked exactly as before.
  v_forms_only := hr.fn_pp_forms_only();
  if not v_forms_only then
    perform hr.fn_require_app('picture_planner', 'view');   -- 2026-10-20_1600 access phase 3
  end if;
  if p_intake_id is null then
    raise exception 'p_intake_id is required' using errcode = '22023';
  end if;

  select * into v_i from public.property_intakes where id = p_intake_id;
  if not found then
    raise exception 'intake % does not exist', p_intake_id using errcode = 'P0002';
  end if;
  -- 2026-11-04_1500 (Fred): a Forms-only caller opens only the forms assigned to them, by the address too.
  if v_forms_only and not client.fn_intake_assigned_to_me(p_intake_id) then
    raise exception 'This form is not assigned to you.' using errcode = '42501', detail = 'blocker=not_assigned in client.get_intake';
  end if;
  if v_forms_only and (v_i.cancelled_at is not null or (v_i.submitted_at is null and v_i.expires_at <= now())) then
    raise exception 'This form is no longer available.' using errcode = 'P0002', detail = 'blocker=not_available in client.get_intake';
  end if;

  v_submitted := v_i.submitted_at is not null;
  v_state := case when v_i.cancelled_at is not null then 'cancelled'
                  when v_submitted                   then 'submitted'
                  when v_i.expires_at <= now()       then 'expired'
                  else 'awaiting' end;

  -- The same normalisation fn_intake_missing uses: distinct, no NULL, no blank. A NULL inside
  -- `x = ANY(arr)` would make every non-member test NULL and empty the unlisted lists.
  select coalesce(array_agg(distinct x) filter (where x is not null and btrim(x) <> ''), '{}') into v_req
    from jsonb_array_elements_text(v_i.requested) x;

  select coalesce(array_agg(k) filter (where k is not null and k <> ''), '{}') into v_known
    from jsonb_array_elements(coalesce(v_i.form_snapshot -> 'sections', '[]'::jsonb)) s,
         jsonb_array_elements(coalesce(s -> 'questions', '[]'::jsonb)) q,
         lateral (select case when jsonb_typeof(q) = 'string' then q #>> '{}' else q ->> 'key' end) kk(k);

  select coalesce(array_agg(r order by r), '{}') into v_orphans
    from unnest(v_req) r
   where not (r = any (v_known));

  -- Photos only for a submitted intake: the product rule. The folder is the intake id since
  -- intake-submit v7, never the token, so `path` carries no secret.
  if v_submitted then
    select coalesce(jsonb_object_agg(z.role, z.photos), '{}'::jsonb) into v_photos
      from (select pl.role,
                   jsonb_agg(jsonb_build_object(
                       'photo_id',     ph.id,
                       'bucket',       'intake-photos',
                       'path',         substr(ph.storage_path, length('intake-photos/') + 1),
                       'caption',      pl.caption,
                       'content_type', ph.content_type) order by pl.id) as photos
              from public.photo_links pl
              join public.photos ph on ph.id = pl.photo_id
             where pl.entity_type = 'property_intake'
               and pl.entity_id = v_i.id
               and pl.deleted_at is null
               and ph.storage_path like 'intake-photos/%'
               and pl.role is not null
             group by pl.role) z;
  end if;

  select coalesce(jsonb_agg(z.sec order by z.s_ord), '[]'::jsonb) into v_sections
    from (select s.ord as s_ord,
                 jsonb_build_object(
                   'id',    s.section ->> 'id',
                   'title', coalesce(s.section ->> 'title', s.section ->> 'id'),
                   'questions', jsonb_agg(jsonb_build_object(
                       'key',        q.k,
                       'label',      q.label,
                       'type',       q.typ,
                       'options',    q.opts,
                       'show_if',    q.show_if,
                       'applicable', case when v_submitted then public.fn_intake_applicable(v_i.form_snapshot, v_i.answers, q.k) end,
                       'optional',   q.opt,
                       'answered',   v_submitted and public.fn_intake_answered(v_i.answers, q.k),
                       'value',      case when v_submitted and not (v_forms_only and public.fn_intake_applicable(v_i.form_snapshot, v_i.answers, q.k) is false) then v_i.answers -> q.k -> 'value' end,
                       'photos',     coalesce(v_photos -> q.k, '[]'::jsonb)) order by q.ord)) as sec
            from jsonb_array_elements(coalesce(v_i.form_snapshot -> 'sections', '[]'::jsonb))
                   with ordinality s(section, ord)
            cross join lateral (
              select qq.ord,
                     case when jsonb_typeof(qq.q) = 'string' then qq.q #>> '{}' else qq.q ->> 'key' end as k,
                     case when jsonb_typeof(qq.q) = 'string' then qq.q #>> '{}'
                          else coalesce(qq.q ->> 'label', qq.q ->> 'key') end                     as label,
                     case when jsonb_typeof(qq.q) = 'object' then qq.q ->> 'type' end              as typ,
                     case when jsonb_typeof(qq.q) = 'object' then qq.q -> 'options' end            as opts,
                     case when jsonb_typeof(qq.q) = 'object' then qq.q ->> 'show_if' end           as show_if,
                     case when jsonb_typeof(qq.q) = 'object' then coalesce((qq.q ->> 'optional')::boolean, false)
                          else false end                                                           as opt
                from jsonb_array_elements(coalesce(s.section -> 'questions', '[]'::jsonb))
                       with ordinality qq(q, ord)
            ) q
           where q.k = any (v_req)
           group by s.ord, s.section) z;

  if cardinality(v_orphans) > 0 then
    v_sections := v_sections || jsonb_build_array(jsonb_build_object(
      'id',    '_not_in_form_definition',
      'title', 'Asked, but not in this form''s definition',
      'questions', (select jsonb_agg(jsonb_build_object(
                        'key',        o,
                        'label',      o,
                        'type',       null,
                        'options',    null,
                        'show_if',    null,
                        'applicable', case when v_submitted then true end,
                        'optional',   false,
                        'answered',   v_submitted and public.fn_intake_answered(v_i.answers, o),
                        'value',      case when v_submitted then v_i.answers -> o -> 'value' end,
                        'photos',     coalesce(v_photos -> o, '[]'::jsonb)) order by o)
                      from unnest(v_orphans) o)));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('key', e.k, 'value', e.v -> 'value') order by e.k), '[]'::jsonb)
    into v_other
    from jsonb_each(coalesce(v_i.answers, '{}'::jsonb)) e(k, v)
   where v_submitted and not (e.k = any (v_req));

  select coalesce(jsonb_agg(jsonb_build_object('role', e.key, 'photos', e.value) order by e.key), '[]'::jsonb)
    into v_other_photos
    from jsonb_each(v_photos) e
   where not (e.key = any (v_req));

  select coalesce(jsonb_agg(jsonb_build_object(
             'question_key',  a.question_key,
             'target_column', a.target_column,
             'old_value',     a.old_value,
             'new_value',     a.new_value,
             'actor',         a.actor,
             'accepted_at',   a.accepted_at) order by a.accepted_at, a.id), '[]'::jsonb)
    into v_accepted
    from public.property_intake_accepts a
   where a.intake_id = v_i.id;

  select jsonb_build_object(
           'id',          p.id,
           'address',     p.address,
           'city',        p.city,
           'deleted',     p.deleted_at is not null,
           'client_id',   c.id,
           'client_code', c.client_code,
           'client_name', c.name)
    into v_prop
    from public.properties p
    left join public.clients c on c.id = p.client_id
   where p.id = v_i.property_id;

  -- THE rule, called, not copied.
  v_missing := public.fn_intake_missing(v_i.form_snapshot, v_i.requested, v_i.answers);
  select count(*) into v_applicable from unnest(v_req) k
   where public.fn_intake_required(v_i.form_snapshot, v_i.answers, k);
  v_status := case when not v_submitted then null
                   when cardinality(v_missing) = 0 then 'Complete'
                   else 'Incomplete' end;

  if v_forms_only and not v_submitted then   -- a waiting form: its status and expiry only
    return jsonb_build_object(
      'intake_id', v_i.id, 'state', v_state, 'status', null, 'missing', null, 'property', v_prop,
      'requested_by', null, 'requested_at', v_i.requested_at, 'expires_at', v_i.expires_at, 'collector', null,
      'submitted_at', null, 'requested_count', null, 'applicable_count', null, 'sections', '[]'::jsonb,
      'unlisted_answers', '[]'::jsonb, 'unlisted_photos', '[]'::jsonb, 'accepted', '[]'::jsonb, 'size_lookups', null,
      'forms_only', true);
  end if;

  return jsonb_build_object(
    'intake_id',        v_i.id,
    'state',            v_state,
    'status',           v_status,
    'missing',          case when v_submitted then to_jsonb(v_missing) end,
    'property',         v_prop,
    'requested_by',     v_i.requested_by,
    'requested_at',     v_i.requested_at,
    'expires_at',       v_i.expires_at,
    'collector',        v_i.collector,
    'submitted_at',     v_i.submitted_at,
    'requested_count',  cardinality(v_req),
    'applicable_count', case when v_submitted then v_applicable end,
    'sections',         v_sections,
    'unlisted_answers', v_other,
    'unlisted_photos',  v_other_photos,
    'accepted',         case when v_forms_only then '[]'::jsonb else v_accepted end,
    -- 2026-10-22 (Trello 6t3RDVkE): the AI lookup of the collector's grease trap model or measurements
    'size_lookups',     case when v_submitted then public.fn_intake_size_lookups(v_i.id) end,
    'forms_only',       v_forms_only);
end $function$;

CREATE OR REPLACE FUNCTION client.fn_intake_photo_shown(p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- 2026-10-27_2130 (AIwCYcmn): one intake-photos object is shown by client.get_intake: a live, roled photo_links row
  -- on a submitted, not cancelled intake (get_intake's own photo rule, plus "not cancelled"). p_name is the object name.
  select exists (
    select 1 from public.photos ph
      join public.photo_links pl on pl.photo_id = ph.id
      join public.property_intakes i on i.id = pl.entity_id
     where ph.storage_path = 'intake-photos/' || p_name
       and pl.entity_type = 'property_intake' and pl.deleted_at is null and pl.role is not null
       and i.submitted_at is not null and i.cancelled_at is null
       -- 2026-11-04_1500: the storage gate reaches this function only for a Forms-only caller: their assigned forms' photos
       and client.fn_intake_assigned_to_me(i.id))
$function$;

UPDATE hr.access_apps SET name = 'See their assigned forms' WHERE app = 'pp_forms';

-- VERIFY (rolled back with the whole migration on any failure). The full matrix is the standing probe.
DO $verify$
DECLARE
  v_uid uuid := gen_random_uuid(); v_emp bigint := 990012; v_task bigint := 990012; v_tag text := substr(md5(random()::text), 1, 10);
  v_form bigint; v_other bigint; c text; v_j jsonb; v_n int; v_refused text;
BEGIN
  IF has_function_privilege('anon', 'client.fn_intake_assigned_to_me(bigint)', 'EXECUTE') THEN RAISE EXCEPTION 'verify: anon can run the helper'; END IF;
  IF NOT has_function_privilege('authenticated', 'client.fn_intake_assigned_to_me(bigint)', 'EXECUTE') THEN RAISE EXCEPTION 'verify: authenticated cannot run the helper'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = 'client.fn_intake_assigned_to_me(bigint)'::regprocedure AND a.grantee = 0) THEN RAISE EXCEPTION 'verify: PUBLIC can run the helper'; END IF;
  IF (SELECT name FROM hr.access_apps WHERE app = 'pp_forms') <> 'See their assigned forms' THEN RAISE EXCEPTION 'verify: name'; END IF;
  SELECT max(i.id), min(i.id) INTO v_form, v_other FROM public.property_intakes i JOIN public.properties p ON p.id = i.property_id JOIN public.clients cl ON cl.id = p.client_id
   WHERE cl.client_code = '112-YA' AND i.submitted_at IS NOT NULL AND i.cancelled_at IS NULL AND i.calendar_task_id IS NULL;
  IF v_form IS NULL OR v_form = v_other THEN RAISE EXCEPTION 'verify: needs two submitted 112-YA forms'; END IF;
  BEGIN
    INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
    VALUES ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', 'pfa-verify-' || v_tag || '@unclogme.com', '', now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, false);
    INSERT INTO public.employees (id, full_name, status, email, access_level, notes) OVERRIDING SYSTEM VALUE
    VALUES (v_emp, 'ZZ PFA Verify ' || v_tag, 'ACTIVE', 'pfa-verify-' || v_tag || '@unclogme.com', 'field', 'Temporary row of a rolled-back verify');
    INSERT INTO ops.calendar_tasks (id, title) OVERRIDING SYSTEM VALUE VALUES (v_task, 'ZZ verify');
    INSERT INTO ops.calendar_task_assignees (task_id, employee_id) VALUES (v_task, v_emp);
    UPDATE public.property_intakes SET calendar_task_id = v_task WHERE id = v_form;
    c := json_build_object('sub', v_uid, 'email', 'pfa-verify-' || v_tag || '@unclogme.com', 'role', 'authenticated')::text;
    PERFORM set_config('request.jwt.claims', c, true);
    SET LOCAL ROLE authenticated;
    v_j := client.list_intake_forms();
    IF jsonb_array_length(v_j) <> 1 OR (v_j->0->>'intake_id')::bigint <> v_form THEN RAISE EXCEPTION 'verify_fail: list %', jsonb_array_length(v_j); END IF;
    IF client.get_intake(v_form)->>'state' <> 'submitted' THEN RAISE EXCEPTION 'verify_fail: own form'; END IF;
    BEGIN
      PERFORM client.get_intake(v_other);
      RAISE EXCEPTION 'verify_fail: another form opened';
    EXCEPTION WHEN insufficient_privilege THEN
      GET STACKED DIAGNOSTICS v_refused = PG_EXCEPTION_DETAIL;
    END;
    IF v_refused NOT LIKE 'blocker=not_assigned%' THEN RAISE EXCEPTION 'verify_fail: refusal %', v_refused; END IF;
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    v_n := jsonb_array_length(client.list_intake_forms());
    RESET ROLE;
    IF v_n <= 1 THEN RAISE EXCEPTION 'verify_fail: admin list shrank to %', v_n; END IF;
    RAISE EXCEPTION 'verify_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'verify_undo' THEN RAISE; END IF;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END $verify$;

COMMIT;
