-- Rollback of 2026-10-27_2130_pp_forms_see_submitted (Trello AIwCYcmn). Rehearsed in a rolled-back transaction with a
-- pp_forms own setting present (2026-10-27). FIRST, if only the door must close: update hr.access_apps set mode = 'off'
-- where app = 'pp_forms' (fn_pp_forms_open reads off as closed). This file puts the three bodies, the view and the policy
-- back verbatim, deletes every pp_forms row (own settings and refusal log rows first: both reference hr.access_apps with
-- no cascade; their contents are printed as NOTICEs, and hr.access_overrides is audited), narrows the CHECK and drops the
-- three helpers. It KEEPS client.list_intake_forms (the Planner calls it for everyone) with the staff-only body.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path TO '';

DO $guard$
BEGIN
  IF pg_get_functiondef('public.fn_request_gate()'::regprocedure) NOT LIKE '%2026-10-27_2130 (Trello AIwCYcmn): the Forms door%' THEN
    RAISE EXCEPTION 'guard: the gate is not the 2026-10-27_2130 body'; END IF;
  IF pg_get_functiondef('client.get_intake(bigint)'::regprocedure) NOT LIKE '%v_forms_only := hr.fn_pp_forms_only();%' THEN
    RAISE EXCEPTION 'guard: get_intake is not the 2026-10-27_2130 body'; END IF;
  IF NOT EXISTS (SELECT 1 FROM hr.access_apps WHERE app = 'pp_forms') THEN RAISE EXCEPTION 'guard: no pp_forms row'; END IF;
  RAISE NOTICE 'rollback backup, hr.access_overrides pp_forms: %', (SELECT jsonb_agg(to_jsonb(o)) FROM hr.access_overrides o WHERE o.app = 'pp_forms');
  RAISE NOTICE 'rollback backup, hr.access_refusals pp_forms: %', (SELECT jsonb_agg(to_jsonb(f)) FROM hr.access_refusals f WHERE f.app = 'pp_forms');
END $guard$;

CREATE OR REPLACE FUNCTION client.list_intake_forms()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
-- 2026-10-27 rollback of 2026-10-27_2130: the staff-only list (Picture Planner View), kept because the Planner calls it.
declare v jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))) then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  perform hr.fn_require_app('picture_planner', 'view');
  select coalesce(jsonb_agg(to_jsonb(s) order by s.intake_id desc), '[]'::jsonb) into v from client.v_intake_submissions s;
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
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', '')))
      then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  perform hr.fn_require_app('picture_planner', 'view');   -- 2026-10-20_1600 access phase 3
  if p_intake_id is null then
    raise exception 'p_intake_id is required' using errcode = '22023';
  end if;

  select * into v_i from public.property_intakes where id = p_intake_id;
  if not found then
    raise exception 'intake % does not exist', p_intake_id using errcode = 'P0002';
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
                       'value',      case when v_submitted then v_i.answers -> q.k -> 'value' end,
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
    'accepted',         v_accepted,
    -- 2026-10-22 (Trello 6t3RDVkE): the AI lookup of the collector's grease trap model or measurements
    'size_lookups',     case when v_submitted then public.fn_intake_size_lookups(v_i.id) end);
end $function$;

CREATE OR REPLACE FUNCTION public.fn_request_gate()
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
-- 2026-10-21_0145: PostgREST pre-request gate (pgrst.db_pre_request). Access phase 6.
-- SECURITY INVOKER on purpose: current_user must be the request role (anon / authenticated / service_role);
-- inside a SECURITY DEFINER body current_user is the owner and the gate would pass everyone (caught by VERIFY).
declare v_path text; v_all_on boolean;
begin
  perform set_config('response.headers', '[{"x-access-gate": "pass"}]', true);
  if current_user is distinct from 'authenticated' then return; end if;
  v_path := coalesce(current_setting('request.path', true), '');
  if v_path in ('/rpc/get_my_access') then return; end if;
  v_all_on := coalesce((nullif(current_setting('request.headers', true), '')::jsonb)->>'x-access-rehearsal', '') in ('all-on', 'refuse-me');
  if (nullif(current_setting('request.headers', true), '')::jsonb)->>'x-access-rehearsal' = 'refuse-me' then v_all_on := null; end if;  -- 2026-10-21_0215 live negative probe
  if v_all_on is not null and hr.fn_any_app_open(v_all_on) then return; end if;
  raise exception 'You do not have access to any UnclogMe app. Ask Fred or Yannick to change it.'
    using errcode = '42501', detail = 'blocker=no_access app=any in public.fn_request_gate';
end $function$;

ALTER POLICY storage_access_gate ON storage.objects
  USING ((SELECT hr.fn_storage_open())) WITH CHECK ((SELECT hr.fn_storage_open()));

CREATE OR REPLACE VIEW client.v_intake_submissions AS
 SELECT i.id AS intake_id,
        CASE
            WHEN (i.submitted_at IS NOT NULL) THEN 'submitted'::text
            ELSE 'awaiting'::text
        END AS state,
    i.property_id,
    p.client_id,
    c.client_code,
    c.name AS client_name,
    p.address,
    p.city,
    (p.deleted_at IS NOT NULL) AS property_deleted,
    i.requested_by,
    i.requested_at,
    i.expires_at,
    i.collector,
    i.submitted_at,
    pr.n_req AS requested_count,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::integer
            ELSE (pr.n_app - cardinality(public.fn_intake_missing(i.form_snapshot, i.requested, i.answers)))
        END AS answered_count,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::text
            WHEN (cardinality(public.fn_intake_missing(i.form_snapshot, i.requested, i.answers)) = 0) THEN 'Complete'::text
            ELSE 'Incomplete'::text
        END AS status,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::integer
            ELSE ( SELECT (count(*))::integer AS count
               FROM public.photo_links pl
              WHERE ((pl.entity_type = 'property_intake'::text) AND (pl.entity_id = i.id) AND (pl.deleted_at IS NULL) AND ((NOT (i.requested ? pl.role)) OR (public.fn_intake_applicable(i.form_snapshot, i.answers, pl.role) AND public.fn_intake_answered(i.answers, pl.role)))))
        END AS photo_count,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::boolean
            ELSE (public.fn_intake_answered(i.answers, 'site_map.gt_location'::text) AND public.fn_intake_applicable(i.form_snapshot, i.answers, 'site_map.gt_location'::text))
        END AS has_gt_pin,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::boolean
            ELSE (public.fn_intake_answered(i.answers, 'site_map.truck_parking'::text) AND public.fn_intake_applicable(i.form_snapshot, i.answers, 'site_map.truck_parking'::text))
        END AS has_truck_pin,
    ( SELECT (count(*))::integer AS count
           FROM public.property_intake_accepts a
          WHERE (a.intake_id = i.id)) AS accepted_count,
    ( SELECT max(a.accepted_at) AS max
           FROM public.property_intake_accepts a
          WHERE (a.intake_id = i.id)) AS last_accepted_at,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::integer
            ELSE pr.n_app
        END AS applicable_count
   FROM (((public.property_intakes i
     JOIN public.properties p ON ((p.id = i.property_id)))
     LEFT JOIN public.clients c ON ((c.id = p.client_id)))
     CROSS JOIN LATERAL ( SELECT (count(*))::integer AS n_req,
            (count(*) FILTER (WHERE public.fn_intake_required(i.form_snapshot, i.answers, r.k)))::integer AS n_app
           FROM ( SELECT DISTINCT x.value AS k
                   FROM jsonb_array_elements_text(i.requested) x(value)
                  WHERE ((x.value IS NOT NULL) AND (btrim(x.value) <> ''::text))) r) pr)
  WHERE (hr.fn_app_open('picture_planner'::text, 'view'::text) AND (i.cancelled_at IS NULL) AND ((i.submitted_at IS NOT NULL) OR (i.expires_at > now())));

DELETE FROM hr.access_overrides WHERE app = 'pp_forms';
DELETE FROM hr.access_refusals WHERE app = 'pp_forms';
DELETE FROM hr.access_group_defaults WHERE app = 'pp_forms';
DELETE FROM hr.access_apps WHERE app = 'pp_forms';
ALTER TABLE hr.access_apps DROP CONSTRAINT access_apps_needs_check,
  ADD CONSTRAINT access_apps_needs_check CHECK (needs = ANY (ARRAY['view'::text, 'edit'::text]));
DROP FUNCTION client.fn_intake_photo_shown(text);
DROP FUNCTION hr.fn_pp_forms_only();
DROP FUNCTION hr.fn_pp_forms_open();

DO $verify$
BEGIN
  IF md5(pg_get_functiondef('public.fn_request_gate()'::regprocedure)) <> '5e32e29d438f2dac7b63659adbe47e91' THEN RAISE EXCEPTION 'VERIFY: gate body'; END IF;
  IF md5(pg_get_functiondef('client.get_intake(bigint)'::regprocedure)) <> 'ada2cdca09de8410246ad2e502f5b6c0' THEN RAISE EXCEPTION 'VERIFY: get_intake body'; END IF;
  IF md5(pg_get_viewdef('client.v_intake_submissions'::regclass)) <> '9b1218af5782e2479bcb3af5172e712a' THEN RAISE EXCEPTION 'VERIFY: view body'; END IF;
  IF (SELECT pg_get_expr(polqual, polrelid) || '|' || pg_get_expr(polwithcheck, polrelid) FROM pg_policy
       WHERE polrelid = 'storage.objects'::regclass AND polname = 'storage_access_gate')
     IS DISTINCT FROM '( SELECT hr.fn_storage_open() AS fn_storage_open)|( SELECT hr.fn_storage_open() AS fn_storage_open)' THEN
    RAISE EXCEPTION 'VERIFY: storage policy'; END IF;
  IF (SELECT count(*) FROM hr.access_apps) <> 10 THEN RAISE EXCEPTION 'VERIFY: 10 access rows'; END IF;
  IF to_regprocedure('hr.fn_pp_forms_open()') IS NOT NULL OR to_regprocedure('client.fn_intake_photo_shown(text)') IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY: helpers still exist'; END IF;
  RAISE NOTICE 'VERIFY ok';
END $verify$;

COMMIT;
