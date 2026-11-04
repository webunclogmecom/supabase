-- Rollback of 2026-11-04_1500_pp_forms_assigned_only. Puts the three 2026-10-27_2130 bodies back verbatim (the Field group reads every submitted form
-- again), restores the switch's name and drops the helper. Rehearsed in a rolled-back transaction 2026-11-04.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path TO '';

DO $guard$
BEGIN
  IF pg_get_functiondef('client.list_intake_forms()'::regprocedure) NOT LIKE '%fn_intake_assigned_to_me%' THEN RAISE EXCEPTION 'guard: list_intake_forms is not the 2026-11-04_1500 body'; END IF;
  IF pg_get_functiondef('client.get_intake(bigint)'::regprocedure) NOT LIKE '%blocker=not_assigned%' THEN RAISE EXCEPTION 'guard: get_intake is not the 2026-11-04_1500 body'; END IF;
END $guard$;

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
    from client.v_intake_submissions s;
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
       and i.submitted_at is not null and i.cancelled_at is null)
$function$;

DROP FUNCTION client.fn_intake_assigned_to_me(bigint);
UPDATE hr.access_apps SET name = 'See submitted forms' WHERE app = 'pp_forms';

DO $verify$
BEGIN
  IF md5(pg_get_functiondef('client.list_intake_forms()'::regprocedure)) <> '7aab9579e1971065919b28b94d061d71' THEN RAISE EXCEPTION 'verify: list_intake_forms'; END IF;
  IF md5(pg_get_functiondef('client.get_intake(bigint)'::regprocedure)) <> '8c72963048d368ad995f48c4c08ec687' THEN RAISE EXCEPTION 'verify: get_intake'; END IF;
  IF md5(pg_get_functiondef('client.fn_intake_photo_shown(text)'::regprocedure)) <> 'c8f88ee4c4b67a5d5867b67afa380e0e' THEN RAISE EXCEPTION 'verify: fn_intake_photo_shown'; END IF;
END $verify$;
COMMIT;
