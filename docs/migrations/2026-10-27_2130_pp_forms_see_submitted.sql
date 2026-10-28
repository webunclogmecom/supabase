-- 2026-10-27_2130 pp_forms_see_submitted: Picture Planner "See submitted forms" for the Field group (Trello AIwCYcmn)
--
-- Fred (Slack to Viktor, 2026-10-23): "Create a trello card for the already submitted forms in the Picture Planner,
-- where it can share a link so it can be seen too, also for the HR App, to add in the accordion of the privileges so
-- they can specifically log in in the Picture Planner App but just to see the Forms Tab. ex: the field team".
-- His answers, 2026-10-27 ~20:45 ET: the link is the form's own address, signed-in only (Q1); a Forms-only person looks
-- and shares the link, nothing else (Q2); their list shows submitted AND waiting forms, waiting ones with status and
-- expiry only (Q3); the WHOLE Field group gets it by default (Q4); no read log (Q9). Spec:
-- Building Apps/Picture Planner/docs/specs/2026-10-27-share-forms-and-forms-only.md. Decisions row f5a9ec2.
--
-- WHAT CHANGES
--  1. hr.access_apps: CHECK access_apps_needs_check widened to ('none','view','edit'); new switch row pp_forms
--     "See submitted forms" under picture_planner with needs = 'none' (the first switch that GIVES access at No access:
--     fn_access_rank('none') = 0, so fn_effective_access never turns it off for a low parent level). Group defaults:
--     office no (Picture Planner Edit already covers it), field yes (Q4).
--  2. hr.fn_pp_forms_open(): the caller's pp_forms is yes AND its row's mode is on. Reads the LEVEL; an off row reads
--     CLOSED (a switch that gives access fails closed, the opposite of fn_require_app's "off passes").
--     hr.fn_pp_forms_only(): fn_pp_forms_open() AND Picture Planner level below View. "Forms-only caller" is tested by
--     LEVEL, never through fn_require_app / fn_app_open, which pass everyone while an app is not on.
--  3. client.fn_intake_photo_shown(name): get_intake's photo rule (a live, roled photo_links row of a submitted, not
--     cancelled intake) for one storage object. SECURITY DEFINER: authenticated cannot read property_intakes.
--  4. client.v_intake_submissions: WHERE gains "OR hr.fn_pp_forms_open()" (parenthesised; columns unchanged). Read
--     directly it stays refused for a Forms-only person: the gate never opens a view path.
--  5. NEW client.list_intake_forms() returns jsonb (never SETOF: no embedding): the view's rows; for a Forms-only caller
--     submitted rows without the accept counts, waiting rows with status and expiry only. The Planner's /forms reads it
--     for everyone (one data path).
--  6. client.get_intake: Forms-only branch (three anchored edits of the live body): a submitted form without the accept
--     history and without values of questions that did not apply; a waiting form's status and expiry only; a cancelled
--     or expired form refused. Everyone else: fn_require_app('picture_planner','view') exactly as before.
--  7. public.fn_request_gate: the door, on the refusal branch only (after fn_any_app_open said no, under
--     v_all_on is not null so the refuse-me rehearsal header still refuses): /rpc/get_intake and /rpc/list_intake_forms,
--     schema header by method (GET/HEAD Accept-Profile, else Content-Profile, no fallback) = client, and
--     hr.fn_pp_forms_open(). It cannot close anything open today.
--  8. storage_access_gate (restrictive, every command, authenticated): CASE, staff stop at the first arm exactly as
--     before; a Forms-only caller reaches only intake-photos objects fn_intake_photo_shown allows (per object).
--
-- D17 (Field: no top-level View or Edit) is unchanged in code. Its stated reason, "a switch grants nothing at None",
-- stops being true for pp_forms, by Fred's decision (Q4). The 2026-10-26_1030 residual is restated: the two Forms
-- functions are now reachable through the gate by a caller with no top-level View; they test the LEVEL, not the mode.
-- Rule 8 (audit): no new table. hr.access_apps and hr.access_group_defaults are audited.
-- Locks: hr.access_apps, client.v_intake_submissions and storage.objects (ALTER POLICY) are held ACCESS EXCLUSIVE until
-- COMMIT, so only cheap checks run inside; the fixture matrix runs before (rehearsal) and after (probe_pp_forms.sql).
-- Undo, in order: (1) close the Forms door: update hr.access_apps set mode = 'off' where app = 'pp_forms';
-- (2) 2026-10-27_rollback_pp_forms_see_submitted.sql. NOT access-undo.md section 3 (its 3b bans every Forms-only sign-in).

BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path TO '';

-- md5 guards: the live bodies this file was built from
DO $guard$
BEGIN
  IF md5(pg_get_functiondef('public.fn_request_gate()'::regprocedure)) <> '5e32e29d438f2dac7b63659adbe47e91' THEN
    RAISE EXCEPTION 'guard: public.fn_request_gate changed since this file was written'; END IF;
  IF md5(pg_get_functiondef('client.get_intake(bigint)'::regprocedure)) <> 'ada2cdca09de8410246ad2e502f5b6c0' THEN
    RAISE EXCEPTION 'guard: client.get_intake changed since this file was written'; END IF;
  IF md5(pg_get_viewdef('client.v_intake_submissions'::regclass)) <> '9b1218af5782e2479bcb3af5172e712a' THEN
    RAISE EXCEPTION 'guard: client.v_intake_submissions changed since this file was written'; END IF;
  IF (SELECT pg_get_expr(polqual, polrelid) || '|' || pg_get_expr(polwithcheck, polrelid) FROM pg_policy
       WHERE polrelid = 'storage.objects'::regclass AND polname = 'storage_access_gate')
     IS DISTINCT FROM '( SELECT hr.fn_storage_open() AS fn_storage_open)|( SELECT hr.fn_storage_open() AS fn_storage_open)' THEN
    RAISE EXCEPTION 'guard: storage_access_gate changed since this file was written'; END IF;
  IF EXISTS (SELECT 1 FROM hr.access_apps WHERE app = 'pp_forms') THEN RAISE EXCEPTION 'guard: pp_forms already exists'; END IF;
  IF to_regprocedure('client.list_intake_forms()') IS NOT NULL THEN RAISE EXCEPTION 'guard: list_intake_forms already exists'; END IF;
END $guard$;

-- 2. helpers
CREATE FUNCTION hr.fn_pp_forms_open()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- 2026-10-27_2130 (AIwCYcmn): the caller's "See submitted forms" is yes and the row is on. Reads the LEVEL; an off row
  -- (or no caller) is closed. Never fn_require_app: it passes everyone while a row is not on.
  select coalesce((select f.level = 'yes' and f.mode = 'on'
                     from hr.fn_effective_access(hr.fn_access_caller()) f where f.app = 'pp_forms'), false)
$function$;
REVOKE ALL ON FUNCTION hr.fn_pp_forms_open() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.fn_pp_forms_open() TO authenticated, service_role, pg_read_all_data, db_backup_reader;

CREATE FUNCTION hr.fn_pp_forms_only()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- 2026-10-27_2130 (AIwCYcmn): a Forms-only caller = See submitted forms open AND Picture Planner below View, by LEVEL
  select hr.fn_pp_forms_open()
     and hr.fn_access_rank(hr.fn_app_level('picture_planner')) < hr.fn_access_rank('view')
$function$;
REVOKE ALL ON FUNCTION hr.fn_pp_forms_only() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.fn_pp_forms_only() TO authenticated, service_role;

CREATE FUNCTION client.fn_intake_photo_shown(p_name text)
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
       and i.submitted_at is not null and i.cancelled_at is null)
$function$;
REVOKE ALL ON FUNCTION client.fn_intake_photo_shown(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION client.fn_intake_photo_shown(text) TO authenticated, service_role;

-- 4. snapshot, before any view or policy DDL: the forms view and Storage counts as Fred (admin) and Diego (office)
CREATE TEMP TABLE _aiw_snap (who text, what text, val jsonb) ON COMMIT DROP;
DO $snap$
DECLARE c record; v_rows jsonb; v_st jsonb;
BEGIN
  FOR c IN SELECT * FROM (VALUES
      ('fred',  '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","role":"authenticated","email":"fred@ayache.com"}'),
      ('diego', '{"sub":"cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8","role":"authenticated","email":"contact@unclogme.com"}')) x(who, claims)
  LOOP
    PERFORM set_config('request.jwt.claims', c.claims, true);
    PERFORM set_config('role', 'authenticated', true);
    SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.intake_id), '[]') INTO v_rows FROM client.v_intake_submissions s;
    SELECT jsonb_object_agg(b, n) INTO v_st FROM (SELECT bucket_id b, count(*) n FROM storage.objects GROUP BY 1) z;
    PERFORM set_config('role', 'postgres', true);
    INSERT INTO _aiw_snap VALUES (c.who, 'view', v_rows), (c.who, 'storage', v_st);
  END LOOP;
  PERFORM set_config('request.jwt.claims', '', true);
END $snap$;

-- 4b. the view (WHERE only)
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
  WHERE ((hr.fn_app_open('picture_planner'::text, 'view'::text) OR hr.fn_pp_forms_open()) AND (i.cancelled_at IS NULL) AND ((i.submitted_at IS NOT NULL) OR (i.expires_at > now())));

-- 5. the list
CREATE FUNCTION client.list_intake_forms()
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
    from client.v_intake_submissions s;
  return v;
end $function$;
REVOKE ALL ON FUNCTION client.list_intake_forms() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION client.list_intake_forms() TO authenticated, service_role;

-- 6. get_intake (three anchored edits of the live body; ACL unchanged by CREATE OR REPLACE)
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

-- 7. the gate (one anchored edit: the door on the refusal branch)
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
  -- 2026-10-27_2130 (Trello AIwCYcmn): the Forms door. A "See submitted forms" person with no top-level View reaches
  -- exactly two client functions that return jsonb, never a view path (embedding would bring properties rows).
  -- The schema header is the one PostgREST uses for the method (GET/HEAD Accept-Profile, else Content-Profile), with no
  -- fallback, so a same-named function in another exposed schema can never be reached through this door.
  if v_all_on is not null and v_path in ('/rpc/get_intake', '/rpc/list_intake_forms')
     and coalesce((nullif(current_setting('request.headers', true), '')::jsonb)->>
           case when coalesce(current_setting('request.method', true), '') in ('GET', 'HEAD') then 'accept-profile' else 'content-profile' end, '') = 'client'
     and hr.fn_pp_forms_open() then
    return;
  end if;
  raise exception 'You do not have access to any UnclogMe app. Ask Fred or Yannick to change it.'
    using errcode = '42501', detail = 'blocker=no_access app=any in public.fn_request_gate';
end $function$;

-- 8. the storage gate: staff stop at the first arm; a Forms-only caller reaches the photos get_intake shows
ALTER POLICY storage_access_gate ON storage.objects
  USING (CASE WHEN (SELECT hr.fn_storage_open()) THEN true
              WHEN bucket_id = 'intake-photos' AND (SELECT hr.fn_pp_forms_open()) THEN client.fn_intake_photo_shown(name)
              ELSE false END)
  WITH CHECK (CASE WHEN (SELECT hr.fn_storage_open()) THEN true
              WHEN bucket_id = 'intake-photos' AND (SELECT hr.fn_pp_forms_open()) THEN client.fn_intake_photo_shown(name)
              ELSE false END);

-- 1. the switch (last, so hr.access_apps, read by every gate call, is locked for the shortest time)
ALTER TABLE hr.access_apps DROP CONSTRAINT access_apps_needs_check,
  ADD CONSTRAINT access_apps_needs_check CHECK (needs = ANY (ARRAY['none'::text, 'view'::text, 'edit'::text]));
INSERT INTO hr.access_apps (app, name, sort, parent, needs, mode, on_since)
VALUES ('pp_forms', 'See submitted forms', 72, 'picture_planner', 'none', 'on', now());
INSERT INTO hr.access_group_defaults (grp, app, level, recommended_level)
VALUES ('office', 'pp_forms', 'no', 'no'), ('field', 'pp_forms', 'yes', 'yes');

-- VERIFY (cheap checks only; the fixture matrix is scripts/checks/hr_app/probe_pp_forms.sql)
DO $verify$
DECLARE v_rows jsonb; v_st jsonb; v_n bigint; c record;
BEGIN
  IF (SELECT count(*) FROM hr.access_apps) <> 11 THEN RAISE EXCEPTION 'VERIFY: hr.access_apps should hold 11 rows'; END IF;
  IF NOT EXISTS (SELECT 1 FROM hr.access_apps WHERE app = 'pp_forms' AND needs = 'none' AND mode = 'on' AND parent = 'picture_planner') THEN
    RAISE EXCEPTION 'VERIFY: pp_forms row'; END IF;
  IF (SELECT count(*) FROM hr.access_group_defaults WHERE app = 'pp_forms') <> 2 THEN RAISE EXCEPTION 'VERIFY: pp_forms defaults'; END IF;
  -- privileges
  IF NOT (has_function_privilege('authenticated', 'hr.fn_pp_forms_open()', 'EXECUTE')
      AND has_function_privilege('service_role', 'hr.fn_pp_forms_open()', 'EXECUTE')
      AND has_function_privilege('pg_read_all_data', 'hr.fn_pp_forms_open()', 'EXECUTE')
      AND has_function_privilege('db_backup_reader', 'hr.fn_pp_forms_open()', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'hr.fn_pp_forms_open()', 'EXECUTE')
      AND has_function_privilege('authenticated', 'hr.fn_pp_forms_only()', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'hr.fn_pp_forms_only()', 'EXECUTE')
      AND has_function_privilege('authenticated', 'client.fn_intake_photo_shown(text)', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'client.fn_intake_photo_shown(text)', 'EXECUTE')
      AND has_function_privilege('authenticated', 'client.list_intake_forms()', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'client.list_intake_forms()', 'EXECUTE')) THEN
    RAISE EXCEPTION 'VERIFY: function privileges'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE a.grantee = 0
              AND p.oid IN ('hr.fn_pp_forms_open()'::regprocedure, 'hr.fn_pp_forms_only()'::regprocedure,
                            'client.fn_intake_photo_shown(text)'::regprocedure, 'client.list_intake_forms()'::regprocedure)) THEN
    RAISE EXCEPTION 'VERIFY: PUBLIC holds EXECUTE on a new function'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'client.get_intake(bigint)'::regprocedure) <> '{postgres=X/postgres,authenticated=X/postgres}' THEN
    RAISE EXCEPTION 'VERIFY: get_intake ACL moved'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_request_gate()'::regprocedure) <> '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres,anon=X/postgres}' THEN
    RAISE EXCEPTION 'VERIFY: fn_request_gate ACL moved'; END IF;
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'client.v_intake_submissions'::regclass) <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,db_backup_reader=r/postgres}' THEN
    RAISE EXCEPTION 'VERIFY: view ACL moved'; END IF;
  -- names and shapes: the two door paths exist only in client and return jsonb
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE p.proname IN ('get_intake', 'list_intake_forms')
                AND n.nspname IN ('public', 'graphql_public', 'customer', 'derm', 'ops', 'client', 'hr')
                AND (n.nspname <> 'client' OR p.prorettype <> 'jsonb'::regtype)) THEN
    RAISE EXCEPTION 'VERIFY: a same-named function outside client, or a non-jsonb return'; END IF;
  -- the view: same columns, and the same rows as Fred and as Diego; a real read as db_backup_reader
  IF (SELECT string_agg(attname || ':' || format_type(atttypid, atttypmod), ',' ORDER BY attnum) FROM pg_attribute
       WHERE attrelid = 'client.v_intake_submissions'::regclass AND attnum > 0 AND NOT attisdropped)
     <> 'intake_id:bigint,state:text,property_id:bigint,client_id:bigint,client_code:text,client_name:text,address:text,city:text,property_deleted:boolean,requested_by:text,requested_at:timestamp with time zone,expires_at:timestamp with time zone,collector:text,submitted_at:timestamp with time zone,requested_count:integer,answered_count:integer,status:text,photo_count:integer,has_gt_pin:boolean,has_truck_pin:boolean,accepted_count:integer,last_accepted_at:timestamp with time zone,applicable_count:integer' THEN
    RAISE EXCEPTION 'VERIFY: view columns moved'; END IF;
  FOR c IN SELECT * FROM (VALUES
      ('fred',  '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","role":"authenticated","email":"fred@ayache.com"}'),
      ('diego', '{"sub":"cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8","role":"authenticated","email":"contact@unclogme.com"}')) x(who, claims)
  LOOP
    PERFORM set_config('request.jwt.claims', c.claims, true);
    PERFORM set_config('role', 'authenticated', true);
    SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.intake_id), '[]') INTO v_rows FROM client.v_intake_submissions s;
    SELECT jsonb_object_agg(b, n) INTO v_st FROM (SELECT bucket_id b, count(*) n FROM storage.objects GROUP BY 1) z;
    IF jsonb_array_length(client.list_intake_forms()) <> jsonb_array_length(v_rows) THEN
      RAISE EXCEPTION 'VERIFY: list_intake_forms differs from the view for %', c.who; END IF;
    PERFORM set_config('role', 'postgres', true);
    IF v_rows IS DISTINCT FROM (SELECT val FROM _aiw_snap WHERE who = c.who AND what = 'view') THEN
      RAISE EXCEPTION 'VERIFY: the forms view changed for %', c.who; END IF;
    IF v_st IS DISTINCT FROM (SELECT val FROM _aiw_snap WHERE who = c.who AND what = 'storage') THEN
      RAISE EXCEPTION 'VERIFY: Storage counts changed for %', c.who; END IF;
    IF jsonb_array_length(v_rows) = 0 THEN RAISE EXCEPTION 'VERIFY: control, % sees no form', c.who; END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '', true);
  -- the backup login reads the view: it needs EXECUTE on every function in its WHERE (postgres cannot SET ROLE to it,
  -- measured 2026-10-27, so the read itself is checked by privilege, as the 2026-08-25_1500 fix did)
  IF NOT (has_table_privilege('db_backup_reader', 'client.v_intake_submissions', 'SELECT')
      AND has_function_privilege('db_backup_reader', 'hr.fn_app_open(text,text)', 'EXECUTE')
      AND has_function_privilege('db_backup_reader', 'hr.fn_pp_forms_open()', 'EXECUTE')
      AND has_function_privilege('pg_read_all_data', 'hr.fn_pp_forms_open()', 'EXECUTE')) THEN
    RAISE EXCEPTION 'VERIFY: the backup login can no longer read the forms view'; END IF;
  RAISE NOTICE 'VERIFY ok';
END $verify$;

COMMIT;
