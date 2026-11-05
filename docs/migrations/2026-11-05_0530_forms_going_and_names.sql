-- 2026-11-05_0530_forms_going_and_names
-- Fred, 2026-11-05, office training film (Trello sfD4mhwm), answered "Fix it" from before and after pictures on
--   screen 2 "Waiting cards do not say who is going" and screen 4 ""Requested by" shows a login, not a person". The Accepted history has the same problem.
--   Asked whether anyone besides Diego signs in with contact@unclogme.com, he answered "No, show Diego". It reads on 8 of 24 cards today.
-- WHAT CHANGES:
--   NEW client.fn_intake_who(bigint): the one rule. {requested_by: a person's name, going: one line of text}. SECDEF because
--       list_intake_forms is SECURITY INVOKER and fn_page_staff_name, ops tasks and audit.logs are not all open to authenticated. Picture Planner View and up only.
--   client.list_intake_forms  office rows: requested_by holds the name, plus going. Forms-only rows unchanged, byte for byte.
--   client.get_intake         office: requested_by holds the name, plus going; accepted[].actor holds the name. Forms-only unchanged except a going: null on a submitted form.
-- NOT CHANGED: client.v_intake_submissions (its readers: this list; get_page_builder_forms, which takes no requester; the Client App, which selects intake_id,
--   requested_at, expires_at); public.property_intakes.requested_by and property_intake_accepts.actor keep the login; fn_request_gate; fn_intake_assigned_to_me;
--   get_intake_link; get_property_activity and get_client_activity, which already show names.
-- going, on a waiting form only:
--   "Going: <names A to Z, comma separated>, task on <Mon D>"  the task's date read live, so a moved task shows the new day
--   "Going: <names>, task has no date" | "Nobody on the task, task on <Mon D>"
--   "No task. It was deleted." the link was set once (audit.logs) and ON DELETE SET NULL took it
--   "No task is linked to this form." never linked: the Yes path, a link that failed, or a reply nobody could read, so it does not claim no task exists
-- No person for a login: the login, lowercase (fn_page_staff_name, as the Page Builder). Free text: as typed (as get_property_activity). Measured 2026-11-05: 0 real logins unmatched.
-- Audit (rule 8): no new table and no write. A read writes no reveal row and no audit row: every function in the chain is STABLE or IMMUTABLE.
-- Checks: VERIFY below; scripts/checks/hr_app/probe_pp_forms.sql. Rehearsed with ROLLBACK before applying: no helper, the old bodies, and the new list with the
-- old page each fail this VERIFY; the new bodies pass; the rollback leaves the old md5s and the check failing again.
-- Rollback: 2026-11-05_0530_forms_going_and_names_rollback.sql.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path TO '';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('client.list_intake_forms()'::regprocedure)) <> '06aae2d63f542cc4f0f709702fe393ac' THEN RAISE EXCEPTION 'guard: list_intake_forms moved'; END IF;
  IF md5(pg_get_functiondef('client.get_intake(bigint)'::regprocedure)) <> 'c966c29cced750bcab4bd03a13156cd1' THEN RAISE EXCEPTION 'guard: get_intake moved'; END IF;
END $guard$;

CREATE FUNCTION client.fn_intake_who(p_intake_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- 2026-11-05_0530 (Fred, film screens 2 and 4): who asked for this form, as a person, and who is going, from its Calendar task, read live.
  -- For Picture Planner View and up only, tested by LEVEL: anyone else, a Forms-only person included, gets {} (Fred 2026-10-27, Q3:
  -- a Forms-only person's waiting form shows status and expiry only).
  -- going: only on a waiting form. calendar_task_id is written only by save-calendar-task and goes NULL only by ON DELETE SET NULL,
  -- so a NULL with a linked row in audit.logs is a deleted task, and with none no task is linked (the Yes path, a failed link or an
  -- unknown reply, so the words must not claim that none exists). The Planner colours this line by the prefix "Going:": keep the prefix.
  select coalesce((
    select jsonb_build_object(
      'requested_by', case when i.requested_by like '%@%' then public.fn_page_staff_name(i.requested_by)
                           else nullif(btrim(i.requested_by), '') end,
      'going', case when i.submitted_at is null and i.cancelled_at is null and i.expires_at > now() then
        case when t.id is not null then
               coalesce('Going: ' || (select string_agg(btrim(e.full_name), ', ' order by btrim(e.full_name))
                                        from ops.calendar_task_assignees a
                                        join public.employees e on e.id = a.employee_id
                                       where a.task_id = t.id), 'Nobody on the task')
               || coalesce(', task on ' || to_char(t.task_date, 'Mon FMDD'), ', task has no date')
             when exists (select 1 from audit.logs l
                           where l.table_name = 'property_intakes' and l.record_pk ->> 'id' = i.id::text
                             and l.table_schema = 'public' and l.new_row ->> 'calendar_task_id' is not null)
               then 'No task. It was deleted.'
             else 'No task is linked to this form.' end end)
      from public.property_intakes i
      left join ops.calendar_tasks t on t.id = i.calendar_task_id
     where i.id = p_intake_id
       and hr.fn_access_rank(hr.fn_app_level('picture_planner')) >= hr.fn_access_rank('view')), '{}'::jsonb)
$function$;
REVOKE ALL ON FUNCTION client.fn_intake_who(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION client.fn_intake_who(bigint) TO authenticated, service_role;

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
           case when not v_fo then to_jsonb(s) || client.fn_intake_who(s.intake_id)   -- 2026-11-05_0530 (Fred, film screens 2 and 4): requested_by as a name, and going
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
end $function$
;

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
  v_who          jsonb := '{}'::jsonb;   -- 2026-11-05_0530: stays empty for a Forms-only caller
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
             'actor',         public.fn_page_staff_name(a.actor),   -- 2026-11-05_0530: a person's name, not a login
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

  if not v_forms_only then v_who := client.fn_intake_who(v_i.id); end if;   -- 2026-11-05_0530

  return jsonb_build_object(
    'intake_id',        v_i.id,
    'state',            v_state,
    'status',           v_status,
    'missing',          case when v_submitted then to_jsonb(v_missing) end,
    'property',         v_prop,
    'requested_by',     coalesce(v_who ->> 'requested_by', v_i.requested_by),
    'going',            v_who -> 'going',
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
end $function$
;

-- VERIFY (rolled back with the whole migration on any failure).
DO $verify$
DECLARE
  c_fred text := json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text;
  v_uid uuid := gen_random_uuid(); v_emp bigint := 990013; v_emp2 bigint := 990014; v_task bigint := 990013; v_task2 bigint := 990014;
  v_tag text := substr(md5(random()::text), 1, 10); c_fo text; v_mail text;
  v_wait bigint; v_sub bigint; v_acc bigint; v_reveals bigint; v_j jsonb; v_r jsonb; v_who text; v_name text;
BEGIN
  IF to_regprocedure('client.fn_intake_who(bigint)') IS NULL THEN RAISE EXCEPTION 'verify_fail: no helper'; END IF;
  IF has_function_privilege('anon', 'client.fn_intake_who(bigint)', 'EXECUTE') THEN RAISE EXCEPTION 'verify_fail: anon can run the helper'; END IF;
  IF NOT has_function_privilege('authenticated', 'client.fn_intake_who(bigint)', 'EXECUTE') THEN RAISE EXCEPTION 'verify_fail: authenticated cannot run the helper'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = 'client.fn_intake_who(bigint)'::regprocedure AND a.grantee = 0) THEN RAISE EXCEPTION 'verify_fail: PUBLIC can run the helper'; END IF;
  -- the test client only: a waiting form that never had a task, a submitted form with no task, and a form with an accept row
  SELECT max(i.id) FILTER (WHERE i.submitted_at IS NULL AND i.cancelled_at IS NULL AND i.expires_at > now() AND i.calendar_task_id IS NULL
                             AND NOT EXISTS (SELECT 1 FROM audit.logs l WHERE l.table_name = 'property_intakes' AND l.record_pk ->> 'id' = i.id::text AND l.new_row ->> 'calendar_task_id' IS NOT NULL)),
         max(i.id) FILTER (WHERE i.submitted_at IS NOT NULL AND i.cancelled_at IS NULL AND i.calendar_task_id IS NULL)
    INTO v_wait, v_sub
    FROM public.property_intakes i JOIN public.properties p ON p.id = i.property_id JOIN public.clients cl ON cl.id = p.client_id
   WHERE cl.client_code = '112-YA';
  SELECT min(a.intake_id) INTO v_acc FROM public.property_intake_accepts a;
  IF v_wait IS NULL OR v_sub IS NULL OR v_acc IS NULL THEN RAISE EXCEPTION 'verify: needs a waiting and a submitted 112-YA form with no task, and an accept row'; END IF;
  SELECT count(*) INTO v_reveals FROM public.property_intake_link_reveals;
  BEGIN
    -- office staff, the real list
    PERFORM set_config('request.jwt.claims', c_fred, true);
    SET LOCAL ROLE authenticated;
    v_j := client.list_intake_forms();
    RESET ROLE;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x WHERE jsonb_typeof(x) <> 'object') THEN RAISE EXCEPTION 'verify_fail: a null row in the list'; END IF;
    IF jsonb_array_length(v_j) <> (SELECT count(*) FROM client.v_intake_submissions) THEN RAISE EXCEPTION 'verify_fail: the list lost rows'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x JOIN public.employees e ON lower(btrim(e.email)) = lower(btrim(x ->> 'requested_by'))) THEN RAISE EXCEPTION 'verify_fail: a login where a person''s name belongs'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x WHERE x ->> 'state' = 'submitted' AND x ->> 'going' IS NOT NULL) THEN RAISE EXCEPTION 'verify_fail: going on a submitted row'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x WHERE x ->> 'state' = 'awaiting' AND coalesce(x ->> 'going', '') = '') THEN RAISE EXCEPTION 'verify_fail: a waiting row with no going'; END IF;
    IF (SELECT x ->> 'going' FROM jsonb_array_elements(v_j) x WHERE (x ->> 'intake_id')::bigint = v_wait) IS DISTINCT FROM 'No task is linked to this form.' THEN RAISE EXCEPTION 'verify_fail: never had a task'; END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(v_j -> 0)) <> 24 THEN RAISE EXCEPTION 'verify_fail: list keys %', (SELECT count(*) FROM jsonb_object_keys(v_j -> 0)); END IF;
    -- the accepted history reads a name
    v_r := client.get_intake(v_acc);
    IF (SELECT i.requested_by FROM public.property_intakes i WHERE i.id = v_acc) NOT LIKE '%@%' THEN RAISE EXCEPTION 'verify: the accept form no longer stores a login, so this cannot bite'; END IF;
    IF EXISTS (SELECT 1 FROM public.employees e WHERE lower(btrim(e.email)) = lower(btrim(v_r ->> 'requested_by'))) THEN RAISE EXCEPTION 'verify_fail: a login in get_intake requested_by'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_r -> 'accepted') x WHERE x ->> 'actor' = 'fred@ayache.com') THEN RAISE EXCEPTION 'verify_fail: a login in the accepted history'; END IF;
    IF jsonb_array_length(v_r -> 'accepted') = 0 THEN RAISE EXCEPTION 'verify: no accepted rows to read'; END IF;
    -- a task: one person, moved, a second person, no date, nobody, deleted
    v_mail := 'pfw-verify-' || v_tag || '@unclogme.com';
    INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
    VALUES ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_mail, '', now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, false);
    INSERT INTO public.employees (id, full_name, status, email, access_level, notes) OVERRIDING SYSTEM VALUE
    VALUES (v_emp, 'ZZ Verify ' || v_tag, 'ACTIVE', v_mail, 'field', 'Temporary row of a rolled-back verify'),
           (v_emp2, 'AA Verify ' || v_tag, 'ACTIVE', NULL, 'field', 'Temporary row of a rolled-back verify');
    INSERT INTO ops.calendar_tasks (id, title, task_date, minutes) OVERRIDING SYSTEM VALUE VALUES (v_task, 'ZZ verify', '2026-11-04', 540), (v_task2, 'ZZ verify 2', '2026-11-04', 540);
    INSERT INTO ops.calendar_task_assignees (task_id, employee_id) VALUES (v_task, v_emp), (v_task2, v_emp);
    UPDATE public.property_intakes SET calendar_task_id = v_task WHERE id = v_wait;
    UPDATE public.property_intakes SET calendar_task_id = v_task2 WHERE id = v_sub;
    PERFORM set_config('request.jwt.claims', c_fred, true);
    IF client.fn_intake_who(v_wait) ->> 'going' IS DISTINCT FROM 'Going: ZZ Verify ' || v_tag || ', task on Nov 4' THEN RAISE EXCEPTION 'verify_fail: one person: %', client.fn_intake_who(v_wait) ->> 'going'; END IF;
    UPDATE ops.calendar_tasks SET task_date = '2026-11-09' WHERE id = v_task;
    IF client.fn_intake_who(v_wait) ->> 'going' IS DISTINCT FROM 'Going: ZZ Verify ' || v_tag || ', task on Nov 9' THEN RAISE EXCEPTION 'verify_fail: moved'; END IF;
    INSERT INTO ops.calendar_task_assignees (task_id, employee_id) VALUES (v_task, v_emp2);
    IF client.fn_intake_who(v_wait) ->> 'going' IS DISTINCT FROM 'Going: AA Verify ' || v_tag || ', ZZ Verify ' || v_tag || ', task on Nov 9' THEN RAISE EXCEPTION 'verify_fail: two people'; END IF;
    DELETE FROM ops.calendar_task_assignees WHERE task_id = v_task AND employee_id = v_emp2;
    UPDATE ops.calendar_tasks SET task_date = NULL, minutes = NULL WHERE id = v_task;
    IF client.fn_intake_who(v_wait) ->> 'going' IS DISTINCT FROM 'Going: ZZ Verify ' || v_tag || ', task has no date' THEN RAISE EXCEPTION 'verify_fail: no date'; END IF;
    -- the Forms-only person assigned to both forms: nothing new reaches them
    c_fo := json_build_object('sub', v_uid, 'email', v_mail, 'role', 'authenticated')::text;
    PERFORM set_config('request.jwt.claims', c_fo, true);
    SET LOCAL ROLE authenticated;
    v_j := client.list_intake_forms();
    v_who := client.fn_intake_who(v_wait)::text;
    v_r := client.get_intake(v_wait);
    RESET ROLE;
    IF jsonb_array_length(v_j) <> 2 THEN RAISE EXCEPTION 'verify_fail: Forms-only list %', jsonb_array_length(v_j); END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x WHERE x ? 'going') THEN RAISE EXCEPTION 'verify_fail: going reached a Forms-only list'; END IF;
    IF (SELECT array_agg(k COLLATE "C" ORDER BY k COLLATE "C") FROM jsonb_array_elements(v_j) x, jsonb_object_keys(x) k WHERE x ->> 'state' = 'awaiting') IS DISTINCT FROM ARRAY['address','city','client_code','client_id','client_name','expires_at','intake_id','property_deleted','property_id','requested_at','state']::text[] THEN RAISE EXCEPTION 'verify_fail: the Forms-only waiting row changed'; END IF;
    IF v_who IS DISTINCT FROM '{}' THEN RAISE EXCEPTION 'verify_fail: the helper answered a Forms-only caller'; END IF;
    IF v_r ? 'going' OR v_r -> 'requested_by' IS DISTINCT FROM 'null'::jsonb THEN RAISE EXCEPTION 'verify_fail: the Forms-only form page changed'; END IF;
    PERFORM set_config('request.jwt.claims', c_fred, true);
    -- nobody on the task, then a login with no person, free text, then the task deleted
    DELETE FROM ops.calendar_task_assignees WHERE task_id = v_task;
    IF client.fn_intake_who(v_wait) ->> 'going' IS DISTINCT FROM 'Nobody on the task, task has no date' THEN RAISE EXCEPTION 'verify_fail: nobody'; END IF;
    UPDATE public.property_intakes SET requested_by = 'Nobody.Here@example.invalid' WHERE id = v_wait;
    IF client.fn_intake_who(v_wait) ->> 'requested_by' IS DISTINCT FROM 'nobody.here@example.invalid' THEN RAISE EXCEPTION 'verify_fail: a login with no person'; END IF;
    UPDATE public.property_intakes SET requested_by = '[TEST] typed text' WHERE id = v_wait;
    IF client.fn_intake_who(v_wait) ->> 'requested_by' IS DISTINCT FROM '[TEST] typed text' THEN RAISE EXCEPTION 'verify_fail: free text'; END IF;
    DELETE FROM ops.calendar_tasks WHERE id = v_task;
    IF client.fn_intake_who(v_wait) ->> 'going' IS DISTINCT FROM 'No task. It was deleted.' THEN RAISE EXCEPTION 'verify_fail: deleted: %', client.fn_intake_who(v_wait) ->> 'going'; END IF;
    v_r := client.get_intake(v_wait);
    IF v_r ->> 'going' IS DISTINCT FROM 'No task. It was deleted.' THEN RAISE EXCEPTION 'verify_fail: the form page has no going'; END IF;
    -- a read writes nothing
    IF (SELECT count(*) FROM public.property_intake_link_reveals) <> v_reveals THEN RAISE EXCEPTION 'verify_fail: a reveal row appeared'; END IF;
    RAISE EXCEPTION 'verify_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'verify_undo' THEN RAISE; END IF;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END $verify$;

COMMIT;
