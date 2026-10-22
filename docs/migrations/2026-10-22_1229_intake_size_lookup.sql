-- ============================================================================
-- 2026-10-22_1229 Grease trap model lookup, part 1: the lookup table and the server rules (Trello 6t3RDVkE)
-- ============================================================================
-- THE ASK
--   Yan (Serena's thread in #new-app-issues, 2026-10-21): "Aaron had a good idea is that if we know the model of the
--   grease trap we don't need to measure it, we could give all the models measurement and have the AI fill it out
--   including the total number of gallon. Or if we have the measurement we could have the AI calculate he total number
--   as well". Fred, 2026-10-22: "we should have like both options, either to have a free text where we can put the
--   measurements ourselves, or we can put the grease trap model so we can do this lookup using AI." His picks on the
--   rendered form: pick one first (model or measurements), the lookup runs on submit, its gallons are OFFERED and a
--   person saves them, and the measurements too.
--   Spec: Building Apps/Picture Planner/docs/specs/2026-10-22-grease-trap-model-lookup-design.md (plan step 1).
-- WHAT CHANGES
--   1. NEW public.grease_trap_size_lookups: one row per (kind, text): kind 'model' or 'measurements', the AI's answer
--      (found with gallons / not_found with why / error, retried 3 times). The card's "model -> capacity reference table".
--      Written only by the edge fn intake-size-lookup (service_role; next steps). Audited (rule 8: a person may correct
--      a wrong row). RLS on, no policy; service_role only.
--   2. NEW public.fn_size_lookup_key (the one normalisation), public.fn_intake_size_inputs (a form's SHOWN, non-blank
--      model / measurements answers), public.fn_intake_size_lookups (what get_intake shows), public.fn_intake_gallons_offer
--      (THE rule: the AI's gallons, only when the collector's own Gallons is not a whole number 1 to 20,000), and
--      public.v_size_lookup_backlog (what still needs a lookup). SECURITY DEFINER, service_role only (they are called
--      from the SECURITY DEFINER client.* functions and the owner-rights view).
--   3. public.property_intake_accepts.size_lookup_id: the lookup a saved gallons number came from (NULL = the form).
--   4. Spliced from the live bodies, md5-pinned: client.get_intake (+ size_lookups), client.get_intake_compare (the
--      Gallons row offers the AI's number with 'offer'), client.accept_intake_answers (saves that number, records the
--      lookup), client.get_property_activity ("(AI lookup of ...)"; the equipment location row gets its label,
--      "Grease trap location", instead of its key: no such accept exists yet).
--   No row exists after this migration, so every reply is as before (VERIFY 2): the Planner learns to label the offer
--   (plan step 3) before anything creates rows (plan step 4).
-- RULE 8: grease_trap_size_lookups opts IN (audit_grease_trap_size_lookups). property_intake_accepts stays audited.
-- ROLLBACK: 2026-10-22_rollback_intake_size_lookup.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_functiondef('client.get_intake(bigint)'::regprocedure)) IS DISTINCT FROM 'caf56346fa29cbdf44e91e24d14aa2d0' THEN RAISE EXCEPTION 'client.get_intake(bigint) changed since this file was written: splice again'; END IF;
  IF md5(pg_get_functiondef('client.get_intake_compare(bigint)'::regprocedure)) IS DISTINCT FROM '5693cef0dd95fcc7fb8018a1d503e925' THEN RAISE EXCEPTION 'client.get_intake_compare(bigint) changed since this file was written: splice again'; END IF;
  IF md5(pg_get_functiondef('client.accept_intake_answers(bigint,text[],jsonb)'::regprocedure)) IS DISTINCT FROM '7a53d5d1ce0b6bc740afa075b897bdcf' THEN RAISE EXCEPTION 'client.accept_intake_answers(bigint,text[],jsonb) changed since this file was written: splice again'; END IF;
  IF md5(pg_get_functiondef('client.get_property_activity(bigint)'::regprocedure)) IS DISTINCT FROM '234112729b14f550df2d1ba7a76cf256' THEN RAISE EXCEPTION 'client.get_property_activity(bigint) changed since this file was written: splice again'; END IF;
END $g$;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS
  SELECT 'client.get_intake(bigint)'::text AS f, (SELECT proacl::text FROM pg_proc WHERE oid = 'client.get_intake(bigint)'::regprocedure) AS a
  UNION ALL
  SELECT 'client.get_intake_compare(bigint)'::text AS f, (SELECT proacl::text FROM pg_proc WHERE oid = 'client.get_intake_compare(bigint)'::regprocedure) AS a
  UNION ALL
  SELECT 'client.accept_intake_answers(bigint,text[],jsonb)'::text AS f, (SELECT proacl::text FROM pg_proc WHERE oid = 'client.accept_intake_answers(bigint,text[],jsonb)'::regprocedure) AS a
  UNION ALL
  SELECT 'client.get_property_activity(bigint)'::text AS f, (SELECT proacl::text FROM pg_proc WHERE oid = 'client.get_property_activity(bigint)'::regprocedure) AS a
;

-- old bodies, kept for the "nothing else moved" comparison (dropped with the session)
CREATE FUNCTION pg_temp.intake_before(p_intake_id bigint)
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
  if lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@unclogme.com' then
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
    'accepted',         v_accepted);
end $function$
;

CREATE FUNCTION pg_temp.compare_before(p_intake_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_i public.property_intakes;
  v_p public.properties;
  v_map jsonb := public.fn_intake_accept_map();
  v_out jsonb := '[]'::jsonb;
  v_key text;
  v_col text;
  v_ours jsonb;
  v_theirs jsonb;
  v_state text;
  v_can boolean;
  v_open boolean;
  v_gal integer;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  perform hr.fn_require_app('picture_planner', 'view');   -- 2026-10-20_1600 access phase 3

  select * into v_i from public.property_intakes where id = p_intake_id;
  if not found then
    raise exception 'intake % not found', p_intake_id using errcode = 'P0002';
  end if;
  select * into v_p from public.properties where id = v_i.property_id;

  -- distinct, non-blank requested keys in their requested order (the same normalisation as
  -- public.fn_intake_missing), so a duplicated key is never compared twice
  for v_key in select e.k from jsonb_array_elements_text(v_i.requested) with ordinality e(k, ord)
                where e.k is not null and btrim(e.k) <> ''
                group by e.k order by min(e.ord) loop
    v_col := v_map ->> v_key;
    continue when v_col is null;                       -- intake-only answer, nothing to compare

    v_theirs := v_i.answers -> v_key -> 'value';
    v_ours := case v_col
      when 'grease_trap_manhole_count' then to_jsonb(nullif(v_p.grease_trap_manhole_count, 0))
      when 'sample_port_count'         then to_jsonb(v_p.sample_port_count)
      when 'grease_trap_size_gallons'  then to_jsonb(v_p.grease_trap_size_gallons)
      when 'lock_box_key'              then to_jsonb(nullif(btrim(coalesce(v_p.lock_box_key,'')), ''))
      when 'access_schedule'           then v_p.access_schedule
      when 'grease_trap_location'      then to_jsonb(v_p.grease_trap_location)
    end;

    -- A question the collector was NOT shown (its show_if chain did not match) may still
    -- carry a stale answer typed before the parent changed. It must never be offered for
    -- accept: it would write a lock-box code the collector abandoned into the property, and
    -- on to Jobber (third review round, 2026-09-24).
    -- Gallons (form version 2, 2026-09-29) is a TEXT answer (Fred: "Gallons" and "Measurements" "both are texts").
    -- Only a plain whole number from 1 to 20,000 ("1,000", "1000 gal") can reach the property record, and it is
    -- compared as that number, so "1,000 gal" reads same against a stored 1000. Any other text is shown on the form
    -- page and never offered: state not_savable. A version 1 number answer reads exactly as before.
    v_gal := case when v_col = 'grease_trap_size_gallons' then public.fn_intake_whole_gallons(v_theirs) end;
    v_state := case
      when not public.fn_intake_applicable(v_i.form_snapshot, v_i.answers, v_key) then 'not_shown'
      when not public.fn_intake_answered(v_i.answers, v_key) then 'unanswered'
      when v_col = 'grease_trap_size_gallons' and not coalesce(v_gal between 1 and 20000, false) then 'not_savable'
      when v_ours is null or v_ours = 'null'::jsonb          then 'blank'
      when v_ours = case when v_col = 'grease_trap_size_gallons' then to_jsonb(v_gal) else v_theirs end then 'same'
      else 'differs'
    end;

    v_out := v_out || jsonb_build_object(
      'key', v_key, 'column', v_col, 'ours', v_ours, 'theirs', v_theirs, 'state', v_state);
  end loop;

  -- Page approvers only may save, on the test client until it is opened (2026-09-28); accept_intake_answers is the
  -- gate, this only tells the screen.
  v_can := coalesce(auth.uid() = any (public.fn_page_approver_ids()), false);
  v_open := coalesce((select value from public.app_config where key = 'intake_accept_all_properties'), '') = 'true'
            or exists (select 1 from public.clients c where c.id = v_p.client_id and c.client_code = '112-YA');
  return jsonb_build_object('intake_id', v_i.id, 'property_id', v_i.property_id, 'fields', v_out,
    'can_accept', v_can and v_open,
    'accept_blocker', case when not v_can then 'Only ' || public.fn_page_approver_names() || ' can save these answers to the property record.'
                           when not v_open then 'For now, answers can only be saved on the test client 112-YA.' end);
end $function$
;

CREATE FUNCTION pg_temp.activity_before(p_property_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_property_activity';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_property_activity';
  end if;
  perform hr.fn_require_any_app(array['picture_planner', 'client_app'], 'view');   -- 2026-10-21_0930 (D6): the Client App Activity reads it too
  if p_property_id is null then
    raise exception 'No property was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_property in client.get_property_activity';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'at', ev.at, 'kind', ev.kind, 'who', ev.who, 'intake_id', ev.intake_id, 'version', ev.version,
             'text', ev.what || coalesce(' by ' || ev.who, '')
                     -- a developer approval of one's own version says so (2026-09-27)
                     || case when ev.kind = 'page_approved' and exists (
                               select 1 from public.property_pages x
                                where x.property_id = p_property_id and x.version = ev.version
                                  and x.approved_by = x.submitted_by)
                             then ', who also made it (developer approval)' else '' end
                     -- what an accept changed comes after the name (2026-09-28)
                     || coalesce(ev.tail, ''))
           order by ev.at desc, ev.ord desc, ev.sub)
      from (
        -- The office asked for a site survey form (Client App, Schedule intake). requested_by is the
        -- login email; a test script writes a "[TEST] ..." label there instead, shown as it is.
        select i.requested_at as at, 1 as ord, 'form_requested'::text as kind, i.id as intake_id, null::int as version,
               'Site survey form #' || i.id || ' requested' as what,
               case when i.requested_by like '%@%' then public.fn_page_staff_name(i.requested_by)
                    else nullif(btrim(i.requested_by), '') end as who,
               null::text as tail, null::bigint as sub
          from public.property_intakes i
         where i.property_id = p_property_id
        union all
        -- Share form on the Planner shows the collector link; every reveal is logged.
        select r.revealed_at, 2, 'form_link_shown', i.id, null,
               'Link to site survey form #' || i.id || ' shown', public.fn_page_staff_name(r.revealed_email), null, null
          from public.property_intake_link_reveals r
          join public.property_intakes i on i.id = r.intake_id
         where i.property_id = p_property_id
        union all
        -- The collector's name is what they typed on the form, not a login.
        select i.submitted_at, 3, 'form_filled', i.id, null,
               'Site survey form #' || i.id || ' filled in', nullif(btrim(i.collector), ''), null, null
          from public.property_intakes i
         where i.property_id = p_property_id and i.submitted_at is not null
        union all
        select i.cancelled_at, 4, 'form_cancelled', i.id, null,
               'Site survey form #' || i.id || ' cancelled',
               public.fn_page_staff_name((
                 select l.jwt_claims ->> 'email' from audit.logs l
                  where l.table_name = 'property_intakes' and l.record_pk ->> 'id' = i.id::text
                    and l.table_schema = 'public' and l.operation = 'UPDATE'
                    and l.old_row ->> 'cancelled_at' is null and l.new_row ->> 'cancelled_at' is not null
                  order by l.changed_at desc limit 1)), null, null
          from public.property_intakes i
         where i.property_id = p_property_id and i.cancelled_at is not null
        union all
        -- "Who made the draft": the person who sent the version for approval.
        select pg.submitted_at, 5, 'page_submitted', null, pg.version,
               'Version ' || pg.version || ' of the site file submitted for approval',
               public.fn_page_staff_name(pg.submitted_by_email),
               -- a restore names its origin after the name (2026-09-29); null otherwise
               ' (restored from version ' || pg.restored_from_version || ')', null
          from public.property_pages pg
         where pg.property_id = p_property_id
        union all
        select pg.approved_at, 6, 'page_approved', null, pg.version,
               'Version ' || pg.version || ' of the site file approved',
               public.fn_page_staff_name(pg.approved_by_email), null, null
          from public.property_pages pg
         where pg.property_id = p_property_id and pg.approved_at is not null
        union all
        -- A rejection names its reason after the name (2026-10-21, Trello 1Mej1zDX).
        select pg.rejected_at, 6, 'page_rejected', null, pg.version,
               'Version ' || pg.version || ' of the site file rejected',
               public.fn_page_staff_name(pg.rejected_by_email), ': ' || pg.reject_reason, null
          from public.property_pages pg
         where pg.property_id = p_property_id and pg.rejected_at is not null
        union all
        select k.created_at, 7, 'driver_link_created', null, null, 'Site file link created',
               public.fn_page_staff_name((select u.email from auth.users u where u.id = k.created_by)), null, null
          from public.property_page_links k
         where k.property_id = p_property_id
        union all
        -- public_id is a redacted audit column, so a rotation shows as rotated_at moving. Never the link.
        select l.changed_at, 8, 'driver_link_replaced', null, null, 'Site file link replaced',
               public.fn_page_staff_name(l.jwt_claims ->> 'email'), null, null
          from audit.logs l
         where l.table_name = 'property_page_links' and l.table_schema = 'public' and l.operation = 'UPDATE'
           and l.record_pk ->> 'property_id' = p_property_id::text
           and l.old_row ->> 'rotated_at' is distinct from l.new_row ->> 'rotated_at'
        union all
        -- An approver saved a form answer to the property record (Picture Planner, 2026-09-28). One row per field;
        -- the rows of one save share accepted_at, so the ledger id keeps them in the order they were saved.
        -- The lock box code is shown: staff already see it on the property card.
        select a.accepted_at, 9, 'intake_accepted', a.intake_id, null,
               'Accepted from Site survey form #' || a.intake_id,
               public.fn_page_staff_name(a.actor),
               ': ' || case a.question_key
                         when 'access_entry.lock_box_code'   then 'Lock box code'
                         when 'access_hours.schedule'        then 'When we can come'
                         when 'grease_trap.capacity_gallons' then 'Grease trap gallons'
                         when 'grease_trap.manhole_count'    then 'Manholes'
                         when 'grease_trap.sample_ports'     then 'Sample ports'
                         else a.question_key end
                    || case when a.question_key = 'access_hours.schedule' then ' replaced'
                            else ' ' || coalesce(a.old_value #>> '{}', 'Not on file') || ' → '
                                     || coalesce(a.new_value #>> '{}', 'Not on file') end,
               a.id
          from public.property_intake_accepts a
         where a.property_id = p_property_id
      ) ev
     where ev.at is not null), '[]'::jsonb);
end $function$
;

-- 1. the one normalisation of a typed model or measurement
CREATE FUNCTION public.fn_size_lookup_key(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select lower(regexp_replace(public.fn_intake_trim(coalesce(p, '')), '[[:space:]]+', ' ', 'g'));
$function$;

-- 2. the lookups
CREATE TABLE public.grease_trap_size_lookups (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind         text NOT NULL CHECK (kind IN ('model', 'measurements')),
  input_text   text NOT NULL CHECK (length(input_text) BETWEEN 1 AND 4000),
  input_key    text NOT NULL,
  status       text NOT NULL CHECK (status IN ('found', 'not_found', 'error')),
  gallons      integer CHECK (gallons BETWEEN 1 AND 20000),
  summary      text CHECK (summary IS NULL OR (length(summary) <= 300 AND summary !~ '[[:cntrl:]]')),
  brand        text CHECK (brand IS NULL OR length(brand) <= 100),
  model        text CHECK (model IS NULL OR length(model) <= 100),
  dimensions   text CHECK (dimensions IS NULL OR length(dimensions) <= 200),
  source_url   text CHECK (source_url IS NULL OR (source_url ~ '^https?://' AND length(source_url) <= 2000)),
  details      jsonb,
  ai_model     text,
  attempts     integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error   text CHECK (last_error IS NULL OR length(last_error) <= 1000),
  looked_up_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT grease_trap_size_lookups_key_matches CHECK (input_key <> '' AND input_key = public.fn_size_lookup_key(input_text)),
  CONSTRAINT grease_trap_size_lookups_found_has_gallons CHECK ((status = 'found') = (gallons IS NOT NULL)),
  CONSTRAINT grease_trap_size_lookups_model_has_source CHECK (NOT (status = 'found' AND kind = 'model' AND source_url IS NULL)),
  CONSTRAINT grease_trap_size_lookups_one_per_text UNIQUE (kind, input_key)
);
COMMENT ON TABLE public.grease_trap_size_lookups IS
  'The AI lookup of a grease trap''s gallons from the model or the measurements a collector typed on a site survey form, one row per (kind, text). Written by edge fn intake-size-lookup; offered to a person on the Picture Planner''s Property record tab (public.fn_intake_gallons_offer), never written to a property by itself. 2026-10-22, Trello 6t3RDVkE.';
CREATE TRIGGER set_updated_at_grease_trap_size_lookups BEFORE UPDATE ON public.grease_trap_size_lookups
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER audit_grease_trap_size_lookups AFTER INSERT OR UPDATE OR DELETE ON public.grease_trap_size_lookups
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();
ALTER TABLE public.grease_trap_size_lookups ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.grease_trap_size_lookups FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.grease_trap_size_lookups TO service_role;

-- 3. a form's shown, non-blank model / measurements answers
CREATE FUNCTION public.fn_intake_size_inputs(p_intake_id bigint)
 RETURNS TABLE (question_key text, kind text, input_text text, input_key text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select k.question_key, k.kind, public.fn_intake_trim(i.answers -> k.question_key ->> 'value'),
         public.fn_size_lookup_key(i.answers -> k.question_key ->> 'value')
    from public.property_intakes i
    cross join (values ('grease_trap.model', 'model'), ('grease_trap.capacity_measure', 'measurements')) k(question_key, kind)
   where i.id = p_intake_id
     and i.submitted_at is not null and i.cancelled_at is null
     and coalesce(i.requested ? k.question_key, false)
     and jsonb_typeof(i.answers -> k.question_key -> 'value') = 'string'
     and public.fn_intake_trim(i.answers -> k.question_key ->> 'value') <> ''
     and public.fn_intake_applicable(i.form_snapshot, i.answers, k.question_key);
$function$;

-- what get_intake shows under those answers: found / not_found / waiting (no answer yet, or a failed call that will be
-- tried again) / failed (3 failed calls)
CREATE FUNCTION public.fn_intake_size_lookups(p_intake_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', x.question_key, 'kind', x.kind, 'input_text', x.input_text,
           'status', case when g.id is null then 'waiting'
                          when g.status = 'error' and g.attempts >= 3 then 'failed'
                          when g.status = 'error' then 'waiting'
                          else g.status end,
           'gallons', g.gallons, 'summary', g.summary, 'brand', g.brand, 'model', g.model,
           'dimensions', g.dimensions, 'source_url', g.source_url, 'looked_up_at', g.looked_up_at)
         order by x.question_key), '[]'::jsonb)
    from public.fn_intake_size_inputs(p_intake_id) x
    left join public.grease_trap_size_lookups g on g.kind = x.kind and g.input_key = x.input_key;
$function$;

-- THE rule for the AI's gallons on a form: nothing when the collector's own Gallons (shown) is a whole number 1 to
-- 20,000 (the collector read the plate); else the found lookup of the shown model, then of the shown measurements.
CREATE FUNCTION public.fn_intake_gallons_offer(p_intake_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case
           when coalesce(public.fn_intake_whole_gallons(i.answers -> 'grease_trap.capacity_gallons' -> 'value') between 1 and 20000, false)
                and public.fn_intake_applicable(i.form_snapshot, i.answers, 'grease_trap.capacity_gallons') then null
           else (select jsonb_build_object('gallons', g.gallons, 'lookup_id', g.id, 'kind', g.kind,
                          'input_text', x.input_text, 'summary', g.summary, 'source_url', g.source_url)
                   from public.fn_intake_size_inputs(i.id) x
                   join public.grease_trap_size_lookups g
                     on g.kind = x.kind and g.input_key = x.input_key and g.status = 'found'
                  order by case x.kind when 'model' then 1 else 2 end
                  limit 1)
         end
    from public.property_intakes i
   where i.id = p_intake_id;
$function$;

-- what still needs a lookup: one row per text, the oldest form first; a failed call waits 20 minutes and gets 3 tries
CREATE VIEW public.v_size_lookup_backlog AS
  select distinct on (x.kind, x.input_key)
         x.kind, x.input_key, x.input_text, i.id as intake_id, g.id as lookup_id, coalesce(g.attempts, 0) as attempts
    from public.property_intakes i
    cross join lateral public.fn_intake_size_inputs(i.id) x
    left join public.grease_trap_size_lookups g on g.kind = x.kind and g.input_key = x.input_key
   where i.submitted_at is not null and i.cancelled_at is null
     and (g.id is null
          or (g.status = 'error' and g.attempts < 3 and coalesce(g.looked_up_at, '-infinity') < now() - interval '20 minutes'))
   order by x.kind, x.input_key, i.submitted_at, i.id;
REVOKE ALL ON public.v_size_lookup_backlog FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_size_lookup_backlog TO service_role;

REVOKE ALL ON FUNCTION public.fn_size_lookup_key(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_intake_size_inputs(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_intake_size_lookups(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_intake_gallons_offer(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_size_lookup_key(text), public.fn_intake_size_inputs(bigint),
  public.fn_intake_size_lookups(bigint), public.fn_intake_gallons_offer(bigint) TO service_role;

-- 4. which lookup a saved number came from
ALTER TABLE public.property_intake_accepts
  ADD COLUMN size_lookup_id bigint REFERENCES public.grease_trap_size_lookups(id);
COMMENT ON COLUMN public.property_intake_accepts.size_lookup_id IS
  'The AI lookup (public.grease_trap_size_lookups) the saved gallons came from; NULL when the value is the collector''s own answer. 2026-10-22.';

-- 5. the spliced bodies
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
  if lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@unclogme.com' then
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
end $function$
;

CREATE OR REPLACE FUNCTION client.get_intake_compare(p_intake_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_i public.property_intakes;
  v_p public.properties;
  v_map jsonb := public.fn_intake_accept_map();
  v_out jsonb := '[]'::jsonb;
  v_key text;
  v_col text;
  v_ours jsonb;
  v_theirs jsonb;
  v_state text;
  v_can boolean;
  v_open boolean;
  v_gal integer;
  v_offer jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  perform hr.fn_require_app('picture_planner', 'view');   -- 2026-10-20_1600 access phase 3

  select * into v_i from public.property_intakes where id = p_intake_id;
  if not found then
    raise exception 'intake % not found', p_intake_id using errcode = 'P0002';
  end if;
  select * into v_p from public.properties where id = v_i.property_id;

  -- distinct, non-blank requested keys in their requested order (the same normalisation as
  -- public.fn_intake_missing), so a duplicated key is never compared twice
  for v_key in select e.k from jsonb_array_elements_text(v_i.requested) with ordinality e(k, ord)
                where e.k is not null and btrim(e.k) <> ''
                group by e.k order by min(e.ord) loop
    v_col := v_map ->> v_key;
    continue when v_col is null;                       -- intake-only answer, nothing to compare

    v_theirs := v_i.answers -> v_key -> 'value';
    v_ours := case v_col
      when 'grease_trap_manhole_count' then to_jsonb(nullif(v_p.grease_trap_manhole_count, 0))
      when 'sample_port_count'         then to_jsonb(v_p.sample_port_count)
      when 'grease_trap_size_gallons'  then to_jsonb(v_p.grease_trap_size_gallons)
      when 'lock_box_key'              then to_jsonb(nullif(btrim(coalesce(v_p.lock_box_key,'')), ''))
      when 'access_schedule'           then v_p.access_schedule
      when 'grease_trap_location'      then to_jsonb(v_p.grease_trap_location)
    end;

    -- A question the collector was NOT shown (its show_if chain did not match) may still
    -- carry a stale answer typed before the parent changed. It must never be offered for
    -- accept: it would write a lock-box code the collector abandoned into the property, and
    -- on to Jobber (third review round, 2026-09-24).
    -- Gallons (form version 2, 2026-09-29) is a TEXT answer (Fred: "Gallons" and "Measurements" "both are texts").
    -- Only a plain whole number from 1 to 20,000 ("1,000", "1000 gal") can reach the property record, and it is
    -- compared as that number, so "1,000 gal" reads same against a stored 1000. Any other text is shown on the form
    -- page and never offered: state not_savable. A version 1 number answer reads exactly as before.
    -- 2026-10-22 (Trello 6t3RDVkE): gallons the AI looked up from the collector's grease trap model or measurements.
    -- public.fn_intake_gallons_offer is THE rule (accept_intake_answers calls it too): it offers a number only when the
    -- collector's own Gallons is not a whole number from 1 to 20,000, and the row then compares that number and carries
    -- 'offer' (what was looked up, the summary, the source page) so the screen can say where it came from.
    v_offer := case when v_col = 'grease_trap_size_gallons' then public.fn_intake_gallons_offer(v_i.id) end;
    if v_offer is not null then
      v_theirs := v_offer -> 'gallons';
    end if;
    v_gal := case when v_col = 'grease_trap_size_gallons' then public.fn_intake_whole_gallons(v_theirs) end;
    v_state := case
      when v_offer is null and not public.fn_intake_applicable(v_i.form_snapshot, v_i.answers, v_key) then 'not_shown'
      when v_offer is null and not public.fn_intake_answered(v_i.answers, v_key) then 'unanswered'
      when v_col = 'grease_trap_size_gallons' and not coalesce(v_gal between 1 and 20000, false) then 'not_savable'
      when v_ours is null or v_ours = 'null'::jsonb          then 'blank'
      when v_ours = case when v_col = 'grease_trap_size_gallons' then to_jsonb(v_gal) else v_theirs end then 'same'
      else 'differs'
    end;

    v_out := v_out || (jsonb_build_object(
      'key', v_key, 'column', v_col, 'ours', v_ours, 'theirs', v_theirs, 'state', v_state)
      || case when v_offer is not null then jsonb_build_object('offer', v_offer) else '{}'::jsonb end);
  end loop;

  -- Page approvers only may save, on the test client until it is opened (2026-09-28); accept_intake_answers is the
  -- gate, this only tells the screen.
  v_can := coalesce(auth.uid() = any (public.fn_page_approver_ids()), false);
  v_open := coalesce((select value from public.app_config where key = 'intake_accept_all_properties'), '') = 'true'
            or exists (select 1 from public.clients c where c.id = v_p.client_id and c.client_code = '112-YA');
  return jsonb_build_object('intake_id', v_i.id, 'property_id', v_i.property_id, 'fields', v_out,
    'can_accept', v_can and v_open,
    'accept_blocker', case when not v_can then 'Only ' || public.fn_page_approver_names() || ' can save these answers to the property record.'
                           when not v_open then 'For now, answers can only be saved on the test client 112-YA.' end);
end $function$
;

CREATE OR REPLACE FUNCTION client.accept_intake_answers(p_intake_id bigint, p_keys text[], p_expected jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_i public.property_intakes;
  v_map jsonb := public.fn_intake_accept_map();
  v_actor text := auth.jwt() ->> 'email';
  v_patch jsonb := '{}'::jsonb;
  v_keys text[];
  v_key text;
  v_col text;
  v_new jsonb;
  v_old jsonb;
  v_gallons integer;
  v_offer jsonb;
  v_written text[] := array[]::text[];
  v_cmp jsonb;
  v_field jsonb;
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.'
      using errcode = '28000', detail = 'blocker=not_signed_in in client.accept_intake_answers';
  end if;
  if lower(coalesce(v_actor,'')) not like '%@ayache.com'
     and lower(coalesce(v_actor,'')) not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.'
      using errcode = '42501', detail = 'blocker=not_staff in client.accept_intake_answers';
  end if;
  perform hr.fn_check_app('picture_planner', 'edit', 'accept intake answers');   -- 2026-10-20_1600 access phase 3
  -- Page approvers only (Fred, 2026-09-28: "it should be only the ones that are page approvers"): the list that
  -- approves a driver page. get_intake_compare tells the screen in advance (can_accept / accept_blocker).
  if not (auth.uid() = any (public.fn_page_approver_ids())) then
    raise exception 'Only % can save these answers to the property record.', public.fn_page_approver_names()
      using errcode = '42501', detail = 'blocker=not_an_approver in client.accept_intake_answers';
  end if;

  -- A repeated key is taken once, where it first appears (it used to write two ledger rows).
  v_keys := array(select u.k from unnest(p_keys) with ordinality u(k, o)
                   where u.k is not null group by u.k order by min(u.o));
  if cardinality(v_keys) = 0 then
    raise exception 'Tick at least one row to save.'
      using errcode = '22023', detail = 'blocker=no_keys in client.accept_intake_answers';
  end if;
  if p_expected is null or jsonb_typeof(p_expected) <> 'object' then
    raise exception 'The page did not send what it showed. Reload the page and try again.'
      using errcode = '22023', detail = 'blocker=no_expected in client.accept_intake_answers';
  end if;

  select * into v_i from public.property_intakes where id = p_intake_id;
  if not found then
    raise exception 'This form does not exist.'
      using errcode = 'P0002', detail = 'blocker=not_found in client.accept_intake_answers';
  end if;
  if v_i.submitted_at is null then
    raise exception 'This form has not been submitted yet, so nothing can be saved from it.'
      using errcode = '22023', detail = 'blocker=not_submitted in client.accept_intake_answers';
  end if;
  -- The test client first, until Fred opens it (app_config intake_accept_all_properties = 'true'): the same first
  -- step the Calendar's Jobber push took. A build defect then cannot reach a real client's record or Jobber.
  if coalesce((select value from public.app_config where key = 'intake_accept_all_properties'), '') <> 'true'
     and not exists (select 1 from public.properties p join public.clients c on c.id = p.client_id
                      where p.id = v_i.property_id and c.client_code = '112-YA') then
    raise exception 'For now, answers can only be saved on the test client 112-YA.'
      using errcode = '42501', detail = 'blocker=test_only in client.accept_intake_answers';
  end if;

  v_cmp := client.get_intake_compare(p_intake_id);

  foreach v_key in array v_keys loop
    v_col := v_map ->> v_key;
    if v_col is null then
      raise exception 'That answer has no place on the property record, so it cannot be saved there.'
        using errcode = '22023', detail = 'blocker=no_property_field in client.accept_intake_answers: ' || v_key;
    end if;
    -- Only a question this form asked (flow doc 13.2 item 27).
    if not coalesce(v_i.requested ? v_key, false) then
      raise exception 'That question was not on this form, so it cannot be saved from it.'
        using errcode = '22023', detail = 'blocker=not_requested in client.accept_intake_answers: ' || v_key;
    end if;
    -- 2026-10-22 (Trello 6t3RDVkE): the gallons the AI looked up, when the collector's own Gallons is not a whole number
    -- (public.fn_intake_gallons_offer, the rule get_intake_compare shows). The client never sends the number.
    v_offer := case when v_col = 'grease_trap_size_gallons' then public.fn_intake_gallons_offer(p_intake_id) end;
    if v_offer is null and not public.fn_intake_answered(v_i.answers, v_key) then
      raise exception 'That question was not answered on the form, so there is nothing to save.'
        using errcode = '22023', detail = 'blocker=not_answered in client.accept_intake_answers: ' || v_key;
    end if;
    if v_offer is null and not public.fn_intake_applicable(v_i.form_snapshot, v_i.answers, v_key) then
      raise exception 'That answer belongs to a question the collector was not shown, so it cannot be accepted.'
        using errcode = '22023',
              detail  = 'blocker=not_shown in client.accept_intake_answers: ' || v_key;
    end if;

    select f into v_field from jsonb_array_elements(v_cmp -> 'fields') f where f ->> 'key' = v_key;
    v_old := v_field -> 'ours';
    v_new := coalesce(v_offer -> 'gallons', v_i.answers -> v_key -> 'value');

    -- Stale screen (2026-09-28): p_expected holds, per key, the "ours" the tab showed. If the property changed since
    -- (another tab, the Client App, the Jobber sync), refuse before anything is written.
    if coalesce(v_old, 'null'::jsonb) is distinct from coalesce(p_expected -> v_key, 'null'::jsonb) then
      raise exception 'The property record changed since you opened this form. Reload to see it.'
        using errcode = '22023', detail = 'blocker=stale in client.accept_intake_answers: ' || v_key;
    end if;

    -- Refuse, in words, a value the writer cannot take (fifth review), before anything is written.
    -- intake-submit refuses the numbers at submit (v11) and the lock box shape (v12) too; this guards
    -- whatever reached the raw record another way.
    if v_col in ('grease_trap_size_gallons', 'grease_trap_manhole_count', 'sample_port_count') then
      -- Gallons (form version 2, 2026-09-29) is a text answer: "1,000" and "1000 gal" are that whole number, read by
      -- public.fn_intake_whole_gallons exactly as get_intake_compare offers it. Anything else meets the refusals below.
      if v_col = 'grease_trap_size_gallons' and public.fn_intake_whole_gallons(v_new) is not null then
        v_new := to_jsonb(public.fn_intake_whole_gallons(v_new));
      end if;
      if jsonb_typeof(v_new) not in ('number', 'string')
         or public.fn_intake_trim(v_new #>> '{}') !~ '^[0-9]{1,6}$' then
        raise exception 'That answer is not a whole number, so it cannot be accepted.'
          using errcode = '22023', detail = 'blocker=not_whole_number in client.accept_intake_answers: ' || v_key;
      end if;
      v_new := to_jsonb(public.fn_intake_trim(v_new #>> '{}')::integer);
      if v_col = 'grease_trap_size_gallons' and not ((v_new #>> '{}')::integer between 1 and 20000) then
        raise exception 'Capacity must be between 1 and 20,000 gallons. A 0 means nobody knows it, so it is not accepted.'
          using errcode = '22023', detail = 'blocker=gallons_out_of_range in client.accept_intake_answers: ' || v_key;
      end if;
      if v_col = 'grease_trap_manhole_count' and not ((v_new #>> '{}')::integer between 0 and 50) then
        raise exception 'A manhole count must be between 0 and 50.'
          using errcode = '22023', detail = 'blocker=manholes_out_of_range in client.accept_intake_answers: ' || v_key;
      end if;
    elsif v_col = 'lock_box_key' then
      if jsonb_typeof(v_new) <> 'string'
         or public.fn_intake_trim(v_new #>> '{}') ~ '[[:cntrl:]]'
         or length(public.fn_intake_trim(v_new #>> '{}')) > 100 then
        raise exception 'The lock box code has a line break, a control character or more than 100 characters, so it cannot be accepted as it is.'
          using errcode = '22023', detail = 'blocker=lock_box_shape in client.accept_intake_answers: ' || v_key;
      end if;
      v_new := to_jsonb(public.fn_intake_trim(v_new #>> '{}'));
    elsif v_col = 'grease_trap_location' then
      -- 2026-10-16_1815: the equipment location answer (Inside / Outside / Inside and Outside), the values the
      -- property column takes. The writer refuses anything else too; this says it in words first.
      if jsonb_typeof(v_new) <> 'string'
         or public.fn_intake_trim(v_new #>> '{}') not in ('Inside', 'Outside', 'Inside and Outside') then
        raise exception 'The equipment location on the form is not Inside, Outside or Inside and Outside, so it cannot be saved.'
          using errcode = '22023', detail = 'blocker=location_shape in client.accept_intake_answers: ' || v_key;
      end if;
      v_new := to_jsonb(public.fn_intake_trim(v_new #>> '{}'));
    elsif v_col = 'access_schedule' then
      -- The writer's own check, in words (its text is technical): an object keyed mon..sun, each {open, close} "HH:MM".
      -- CASE keeps jsonb_each away from a value that is not an object; the parentheses keep PL/pgSQL from reading
      -- the CASE's THEN as the IF's.
      if (case when jsonb_typeof(v_new) <> 'object' then true
               else exists (select 1 from jsonb_each(v_new) d(k, v)
                             where d.k <> all (array['mon','tue','wed','thu','fri','sat','sun'])
                                or jsonb_typeof(d.v) <> 'object'
                                or coalesce(d.v ->> 'open', '')  !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
                                or coalesce(d.v ->> 'close', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$') end) then
        raise exception 'The hours on the form are not in a shape the property record can take, so they cannot be saved.'
          using errcode = '22023', detail = 'blocker=hours_shape in client.accept_intake_answers: ' || v_key;
      end if;
    end if;

    if v_col = 'grease_trap_size_gallons' then
      v_gallons := (v_new #>> '{}')::integer;          -- capacity has its own RPC
    else
      v_patch := v_patch || jsonb_build_object(v_col, v_new);
    end if;

    insert into public.property_intake_accepts
      (intake_id, property_id, question_key, target_column, old_value, new_value, actor, size_lookup_id)
    values (p_intake_id, v_i.property_id, v_key, v_col, v_old, v_new, v_actor, (v_offer ->> 'lookup_id')::bigint);
    v_written := v_written || v_key;
  end loop;

  -- Reuse the gated writers rather than touching public.properties directly. They
  -- carry the allowlist, the staff gate, the error vocabulary and, for gallons and
  -- the lock box, the outbound Jobber push (which only fires because auth.uid() is
  -- not null here, i.e. because a real person pressed Save).
  if v_patch <> '{}'::jsonb then
    perform set_config('unclogme.intake_accept', 'on', true); perform client.update_property_operational(v_i.property_id, v_patch); perform set_config('unclogme.intake_accept', '', true);
  end if;
  if v_gallons is not null then
    perform set_config('unclogme.intake_accept', 'on', true); perform client.update_property_capacity(v_i.property_id, v_gallons); perform set_config('unclogme.intake_accept', '', true);
  end if;

  update public.property_intakes
     set accepted = accepted || jsonb_build_object(
           'at', to_jsonb(now()), 'by', to_jsonb(v_actor), 'keys', to_jsonb(v_written))
   where id = p_intake_id;

  return jsonb_build_object('ok', true, 'intake_id', p_intake_id,
                            'accepted', to_jsonb(v_written), 'by', v_actor);
end $function$
;

CREATE OR REPLACE FUNCTION client.get_property_activity(p_property_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_property_activity';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_property_activity';
  end if;
  perform hr.fn_require_any_app(array['picture_planner', 'client_app'], 'view');   -- 2026-10-21_0930 (D6): the Client App Activity reads it too
  if p_property_id is null then
    raise exception 'No property was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_property in client.get_property_activity';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'at', ev.at, 'kind', ev.kind, 'who', ev.who, 'intake_id', ev.intake_id, 'version', ev.version,
             'text', ev.what || coalesce(' by ' || ev.who, '')
                     -- a developer approval of one's own version says so (2026-09-27)
                     || case when ev.kind = 'page_approved' and exists (
                               select 1 from public.property_pages x
                                where x.property_id = p_property_id and x.version = ev.version
                                  and x.approved_by = x.submitted_by)
                             then ', who also made it (developer approval)' else '' end
                     -- what an accept changed comes after the name (2026-09-28)
                     || coalesce(ev.tail, ''))
           order by ev.at desc, ev.ord desc, ev.sub)
      from (
        -- The office asked for a site survey form (Client App, Schedule intake). requested_by is the
        -- login email; a test script writes a "[TEST] ..." label there instead, shown as it is.
        select i.requested_at as at, 1 as ord, 'form_requested'::text as kind, i.id as intake_id, null::int as version,
               'Site survey form #' || i.id || ' requested' as what,
               case when i.requested_by like '%@%' then public.fn_page_staff_name(i.requested_by)
                    else nullif(btrim(i.requested_by), '') end as who,
               null::text as tail, null::bigint as sub
          from public.property_intakes i
         where i.property_id = p_property_id
        union all
        -- Share form on the Planner shows the collector link; every reveal is logged.
        select r.revealed_at, 2, 'form_link_shown', i.id, null,
               'Link to site survey form #' || i.id || ' shown', public.fn_page_staff_name(r.revealed_email), null, null
          from public.property_intake_link_reveals r
          join public.property_intakes i on i.id = r.intake_id
         where i.property_id = p_property_id
        union all
        -- The collector's name is what they typed on the form, not a login.
        select i.submitted_at, 3, 'form_filled', i.id, null,
               'Site survey form #' || i.id || ' filled in', nullif(btrim(i.collector), ''), null, null
          from public.property_intakes i
         where i.property_id = p_property_id and i.submitted_at is not null
        union all
        select i.cancelled_at, 4, 'form_cancelled', i.id, null,
               'Site survey form #' || i.id || ' cancelled',
               public.fn_page_staff_name((
                 select l.jwt_claims ->> 'email' from audit.logs l
                  where l.table_name = 'property_intakes' and l.record_pk ->> 'id' = i.id::text
                    and l.table_schema = 'public' and l.operation = 'UPDATE'
                    and l.old_row ->> 'cancelled_at' is null and l.new_row ->> 'cancelled_at' is not null
                  order by l.changed_at desc limit 1)), null, null
          from public.property_intakes i
         where i.property_id = p_property_id and i.cancelled_at is not null
        union all
        -- "Who made the draft": the person who sent the version for approval.
        select pg.submitted_at, 5, 'page_submitted', null, pg.version,
               'Version ' || pg.version || ' of the site file submitted for approval',
               public.fn_page_staff_name(pg.submitted_by_email),
               -- a restore names its origin after the name (2026-09-29); null otherwise
               ' (restored from version ' || pg.restored_from_version || ')', null
          from public.property_pages pg
         where pg.property_id = p_property_id
        union all
        select pg.approved_at, 6, 'page_approved', null, pg.version,
               'Version ' || pg.version || ' of the site file approved',
               public.fn_page_staff_name(pg.approved_by_email), null, null
          from public.property_pages pg
         where pg.property_id = p_property_id and pg.approved_at is not null
        union all
        -- A rejection names its reason after the name (2026-10-21, Trello 1Mej1zDX).
        select pg.rejected_at, 6, 'page_rejected', null, pg.version,
               'Version ' || pg.version || ' of the site file rejected',
               public.fn_page_staff_name(pg.rejected_by_email), ': ' || pg.reject_reason, null
          from public.property_pages pg
         where pg.property_id = p_property_id and pg.rejected_at is not null
        union all
        select k.created_at, 7, 'driver_link_created', null, null, 'Site file link created',
               public.fn_page_staff_name((select u.email from auth.users u where u.id = k.created_by)), null, null
          from public.property_page_links k
         where k.property_id = p_property_id
        union all
        -- public_id is a redacted audit column, so a rotation shows as rotated_at moving. Never the link.
        select l.changed_at, 8, 'driver_link_replaced', null, null, 'Site file link replaced',
               public.fn_page_staff_name(l.jwt_claims ->> 'email'), null, null
          from audit.logs l
         where l.table_name = 'property_page_links' and l.table_schema = 'public' and l.operation = 'UPDATE'
           and l.record_pk ->> 'property_id' = p_property_id::text
           and l.old_row ->> 'rotated_at' is distinct from l.new_row ->> 'rotated_at'
        union all
        -- An approver saved a form answer to the property record (Picture Planner, 2026-09-28). One row per field;
        -- the rows of one save share accepted_at, so the ledger id keeps them in the order they were saved.
        -- The lock box code is shown: staff already see it on the property card.
        select a.accepted_at, 9, 'intake_accepted', a.intake_id, null,
               'Accepted from Site survey form #' || a.intake_id,
               public.fn_page_staff_name(a.actor),
               ': ' || case a.question_key
                         when 'access_entry.lock_box_code'   then 'Lock box code'
                         when 'access_hours.schedule'        then 'When we can come'
                         when 'grease_trap.capacity_gallons' then 'Grease trap gallons'
                         when 'grease_trap.manhole_count'    then 'Manholes'
                         when 'grease_trap.sample_ports'     then 'Sample ports'
                         when 'access_entry.equipment_where' then 'Grease trap location'
                         else a.question_key end
                    || case when a.question_key = 'access_hours.schedule' then ' replaced'
                            else ' ' || coalesce(a.old_value #>> '{}', 'Not on file') || ' → '
                                     || coalesce(a.new_value #>> '{}', 'Not on file') end
                    -- 2026-10-22: a number the AI looked up says so
                    || coalesce(' (AI lookup of ' || case when g.id is null then null when g.kind = 'model' then g.input_text else 'the measurements' end || ')', ''),
               a.id
          from public.property_intake_accepts a
          left join public.grease_trap_size_lookups g on g.id = a.size_lookup_id
         where a.property_id = p_property_id
      ) ev
     where ev.at is not null), '[]'::jsonb);
end $function$
;

-- ============================================================================
-- VERIFY
-- ============================================================================
DO $v$
DECLARE
  r record; n int := 0; v_fred uuid; v_a jsonb; v_b jsonb; v_row jsonb;
BEGIN
  -- V1 grants: the four spliced functions keep their ACLs; the new objects are service_role only
  FOR r IN SELECT f, a FROM acl_before LOOP
    IF r.a IS DISTINCT FROM (SELECT proacl::text FROM pg_proc WHERE oid = r.f::regprocedure) THEN
      RAISE EXCEPTION 'V1: % ACL changed', r.f;
    END IF;
  END LOOP;
  IF has_table_privilege('authenticated', 'public.grease_trap_size_lookups', 'SELECT')
     OR has_table_privilege('anon', 'public.grease_trap_size_lookups', 'SELECT')
     OR has_table_privilege('authenticated', 'public.v_size_lookup_backlog', 'SELECT')
     OR has_function_privilege('authenticated', 'public.fn_intake_gallons_offer(bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_intake_size_inputs(bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_intake_size_lookups(bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.fn_size_lookup_key(text)', 'EXECUTE')
     OR NOT has_table_privilege('service_role', 'public.grease_trap_size_lookups', 'INSERT')
     OR NOT has_table_privilege('service_role', 'public.v_size_lookup_backlog', 'SELECT') THEN
    RAISE EXCEPTION 'V1: new object grants wrong';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.grease_trap_size_lookups'::regclass AND tgname = 'audit_grease_trap_size_lookups') THEN
    RAISE EXCEPTION 'V1: no audit trigger';
  END IF;

  -- V2 nothing else moved (no lookup row exists): every form and every property with a form reads as before, as Fred
  SELECT id INTO v_fred FROM auth.users WHERE lower(email) = 'fred@ayache.com';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  IF EXISTS (SELECT 1 FROM public.grease_trap_size_lookups) THEN RAISE EXCEPTION 'V2: rows already exist'; END IF;
  FOR r IN SELECT id, property_id, submitted_at FROM public.property_intakes ORDER BY id LOOP
    IF (client.get_intake(r.id) - 'size_lookups') IS DISTINCT FROM pg_temp.intake_before(r.id) THEN
      RAISE EXCEPTION 'V2: get_intake(%) moved', r.id;
    END IF;
    IF r.submitted_at IS NOT NULL AND client.get_intake_compare(r.id) IS DISTINCT FROM pg_temp.compare_before(r.id) THEN
      RAISE EXCEPTION 'V2: get_intake_compare(%) moved', r.id;
    END IF;
    n := n + 1;
  END LOOP;
  FOR r IN SELECT DISTINCT property_id FROM public.property_intakes LOOP
    IF client.get_property_activity(r.property_id) IS DISTINCT FROM pg_temp.activity_before(r.property_id) THEN
      RAISE EXCEPTION 'V2: get_property_activity(%) moved', r.property_id;
    END IF;
  END LOOP;
  -- the one real measurement today (form 1047) is waiting for its lookup, and is in the backlog
  IF (client.get_intake(1047) -> 'size_lookups') IS DISTINCT FROM
     jsonb_build_array(jsonb_build_object('key', 'grease_trap.capacity_measure', 'kind', 'measurements',
       'input_text', public.fn_intake_trim((SELECT answers -> 'grease_trap.capacity_measure' ->> 'value' FROM public.property_intakes WHERE id = 1047)),
       'status', 'waiting', 'gallons', null, 'summary', null, 'brand', null, 'model', null, 'dimensions', null,
       'source_url', null, 'looked_up_at', null)) THEN
    RAISE EXCEPTION 'V2: form 1047 size_lookups %', client.get_intake(1047) -> 'size_lookups';
  END IF;
  IF (SELECT count(*) FROM public.v_size_lookup_backlog) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.v_size_lookup_backlog WHERE intake_id = 1047 AND kind = 'measurements') THEN
    RAISE EXCEPTION 'V2: backlog %', (SELECT json_agg(b) FROM public.v_size_lookup_backlog b);
  END IF;

  -- V3 the rule, on synthetic forms of [TEST] property 162 (112-YA), rolled back by the sentinel
  BEGIN
    DECLARE
      s jsonb := '{"version": 99, "sections": [{"id": "grease_trap", "title": "Grease trap", "questions": [
        {"key": "grease_trap.systems_count", "type": "number", "label": "How many grease trap systems?"},
        {"key": "grease_trap.size_from", "type": "choice", "label": "How can you give us its size?", "options": ["Model on the plate", "Measurements"], "show_if": "grease_trap.systems_count>0", "optional": true},
        {"key": "grease_trap.model", "type": "text", "label": "Grease trap model", "show_if": "grease_trap.size_from=Model on the plate", "optional": true},
        {"key": "grease_trap.capacity_measure", "type": "text", "label": "Measurements", "show_if": "grease_trap.size_from=Measurements", "optional": true},
        {"key": "grease_trap.capacity_gallons", "type": "text", "label": "Gallons", "show_if": "grease_trap.systems_count>0", "optional": true}]}]}';
      req jsonb := '["grease_trap.systems_count","grease_trap.size_from","grease_trap.model","grease_trap.capacity_measure","grease_trap.capacity_gallons"]';
      f1 bigint; f2 bigint; f3 bigint; f4 bigint; l1 bigint; l4 bigint; v_gal int;
    BEGIN
      INSERT INTO public.property_intakes (property_id, form_snapshot, requested, requested_by, collector, answers, submitted_at)
      VALUES (162, s, req, '[TEST] model lookup verify', '[TEST]', '{"grease_trap.systems_count": {"value": 1}, "grease_trap.size_from": {"value": "Model on the plate"}, "grease_trap.model": {"value": "  Test  Model ZX-1 "}}', now())
      RETURNING id INTO f1;
      INSERT INTO public.property_intakes (property_id, form_snapshot, requested, requested_by, collector, answers, submitted_at)
      VALUES (162, s, req, '[TEST] model lookup verify', '[TEST]', '{"grease_trap.systems_count": {"value": 1}, "grease_trap.size_from": {"value": "Model on the plate"}, "grease_trap.model": {"value": "test model zx-1"}, "grease_trap.capacity_gallons": {"value": "250"}}', now())
      RETURNING id INTO f2;
      INSERT INTO public.property_intakes (property_id, form_snapshot, requested, requested_by, collector, answers, submitted_at)
      VALUES (162, s, req, '[TEST] model lookup verify', '[TEST]', '{"grease_trap.systems_count": {"value": 1}, "grease_trap.size_from": {"value": "Measurements"}, "grease_trap.model": {"value": "Test Model ZX-1"}}', now())
      RETURNING id INTO f3;
      INSERT INTO public.property_intakes (property_id, form_snapshot, requested, requested_by, collector, answers, submitted_at)
      VALUES (162, s, req, '[TEST] model lookup verify', '[TEST]', '{"grease_trap.systems_count": {"value": 1}, "grease_trap.size_from": {"value": "Measurements"}, "grease_trap.capacity_measure": {"value": "48 x 24 x 30"}}', now())
      RETURNING id INTO f4;

      -- V3a the inputs: f1 model (trimmed, key normalised), f3 nothing (its model was not shown), f4 measurements
      IF (SELECT json_agg(json_build_object('k', kind, 't', input_text, 'key', input_key)) FROM public.fn_intake_size_inputs(f1))::text
         IS DISTINCT FROM '[{"k" : "model", "t" : "Test  Model ZX-1", "key" : "test model zx-1"}]' THEN
        RAISE EXCEPTION 'V3a: inputs f1 %', (SELECT json_agg(x) FROM public.fn_intake_size_inputs(f1) x);
      END IF;
      IF EXISTS (SELECT 1 FROM public.fn_intake_size_inputs(f3)) THEN RAISE EXCEPTION 'V3a: a model not shown counted'; END IF;
      IF (SELECT count(*) FROM public.fn_intake_size_inputs(f4) WHERE kind = 'measurements') <> 1 THEN RAISE EXCEPTION 'V3a: f4'; END IF;
      -- one backlog row per TEXT: f1 and f2 share the model
      IF (SELECT count(*) FROM public.v_size_lookup_backlog WHERE kind = 'model' AND input_key = 'test model zx-1') <> 1
         OR (SELECT intake_id FROM public.v_size_lookup_backlog WHERE kind = 'model' AND input_key = 'test model zx-1') <> f1 THEN
        RAISE EXCEPTION 'V3a: backlog %', (SELECT json_agg(b) FROM public.v_size_lookup_backlog b);
      END IF;

      -- V3b no lookup yet: the Gallons row is as before (unanswered, no offer); get_intake says waiting
      v_row := (SELECT f FROM jsonb_array_elements(client.get_intake_compare(f1) -> 'fields') f WHERE f ->> 'key' = 'grease_trap.capacity_gallons');
      IF v_row ->> 'state' <> 'unanswered' OR v_row ? 'offer' THEN RAISE EXCEPTION 'V3b: %', v_row; END IF;
      IF client.get_intake(f1) #>> '{size_lookups,0,status}' <> 'waiting' THEN RAISE EXCEPTION 'V3b: get_intake %', client.get_intake(f1) -> 'size_lookups'; END IF;

      -- V3c failed calls: 1 recent = not in the backlog, 1 old = back in it, 3 = never again
      INSERT INTO public.grease_trap_size_lookups (kind, input_text, input_key, status, attempts, looked_up_at, last_error)
      VALUES ('model', 'Test Model ZX-1', public.fn_size_lookup_key('Test Model ZX-1'), 'error', 1, now(), 'test') RETURNING id INTO l1;
      IF EXISTS (SELECT 1 FROM public.v_size_lookup_backlog WHERE lookup_id = l1) THEN RAISE EXCEPTION 'V3c: retried at once'; END IF;
      UPDATE public.grease_trap_size_lookups SET looked_up_at = now() - interval '1 hour' WHERE id = l1;
      IF NOT EXISTS (SELECT 1 FROM public.v_size_lookup_backlog WHERE lookup_id = l1) THEN RAISE EXCEPTION 'V3c: not retried'; END IF;
      UPDATE public.grease_trap_size_lookups SET attempts = 3 WHERE id = l1;
      IF EXISTS (SELECT 1 FROM public.v_size_lookup_backlog WHERE lookup_id = l1) THEN RAISE EXCEPTION 'V3c: a 4th try'; END IF;
      IF client.get_intake(f1) #>> '{size_lookups,0,status}' <> 'failed' THEN RAISE EXCEPTION 'V3c: failed status'; END IF;

      -- V3d found: the Gallons row offers 92 against 162's 30, get_intake shows it, the old body would not
      UPDATE public.grease_trap_size_lookups SET status = 'found', gallons = 92, attempts = 1, last_error = null,
             summary = 'Test Model ZX-1: liquid capacity 92 gallons.', source_url = 'https://example.com/zx-1.pdf',
             dimensions = '46 x 25 x 21 in', looked_up_at = now() WHERE id = l1;
      v_row := (SELECT f FROM jsonb_array_elements(client.get_intake_compare(f1) -> 'fields') f WHERE f ->> 'key' = 'grease_trap.capacity_gallons');
      IF v_row -> 'theirs' IS DISTINCT FROM '92'::jsonb OR v_row ->> 'state' <> 'differs' OR v_row -> 'ours' IS DISTINCT FROM '30'::jsonb
         OR (v_row #>> '{offer,lookup_id}')::bigint IS DISTINCT FROM l1 OR v_row #>> '{offer,kind}' <> 'model'
         OR v_row #>> '{offer,input_text}' <> 'Test  Model ZX-1' OR v_row #>> '{offer,source_url}' <> 'https://example.com/zx-1.pdf' THEN
        RAISE EXCEPTION 'V3d: %', v_row;
      END IF;
      v_b := (SELECT f FROM jsonb_array_elements(pg_temp.compare_before(f1) -> 'fields') f WHERE f ->> 'key' = 'grease_trap.capacity_gallons');
      IF v_b ->> 'state' <> 'unanswered' OR v_b ? 'offer' THEN RAISE EXCEPTION 'V3d control: the old body offers %', v_b; END IF;
      IF client.get_intake(f1) #>> '{size_lookups,0,status}' <> 'found' OR (client.get_intake(f1) #>> '{size_lookups,0,gallons}')::int <> 92 THEN
        RAISE EXCEPTION 'V3d: get_intake %', client.get_intake(f1) -> 'size_lookups';
      END IF;
      IF EXISTS (SELECT 1 FROM public.v_size_lookup_backlog WHERE lookup_id = l1) THEN RAISE EXCEPTION 'V3d: found still waits'; END IF;

      -- V3e the collector's own whole number wins (f2), a model not shown offers nothing (f3)
      v_row := (SELECT f FROM jsonb_array_elements(client.get_intake_compare(f2) -> 'fields') f WHERE f ->> 'key' = 'grease_trap.capacity_gallons');
      IF v_row ? 'offer' OR v_row -> 'theirs' IS DISTINCT FROM '"250"'::jsonb THEN RAISE EXCEPTION 'V3e: f2 %', v_row; END IF;
      IF public.fn_intake_gallons_offer(f3) IS NOT NULL THEN RAISE EXCEPTION 'V3e: f3 offered'; END IF;

      -- V3f measurements (f4)
      INSERT INTO public.grease_trap_size_lookups (kind, input_text, input_key, status, gallons, summary, attempts, looked_up_at, details)
      VALUES ('measurements', '48 x 24 x 30', public.fn_size_lookup_key('48 x 24 x 30'), 'found', 150, '48 x 24 x 30 in: 150 gallons.', 1, now(), '{"tanks": [[48, 24, 30]]}')
      RETURNING id INTO l4;
      IF public.fn_intake_gallons_offer(f4) ->> 'kind' <> 'measurements' OR (public.fn_intake_gallons_offer(f4) ->> 'gallons')::int <> 150 THEN
        RAISE EXCEPTION 'V3f: %', public.fn_intake_gallons_offer(f4);
      END IF;

      -- V3g accept saves the AI's 92, records the lookup, and Activity says so; a client cannot send its own number
      PERFORM client.accept_intake_answers(f1, ARRAY['grease_trap.capacity_gallons'], '{"grease_trap.capacity_gallons": 30}'::jsonb);
      SELECT grease_trap_size_gallons INTO v_gal FROM public.properties WHERE id = 162;
      IF v_gal IS DISTINCT FROM 92 THEN RAISE EXCEPTION 'V3g: property 162 gallons %', v_gal; END IF;
      IF NOT EXISTS (SELECT 1 FROM public.property_intake_accepts WHERE intake_id = f1 AND size_lookup_id = l1 AND new_value = '92'::jsonb AND old_value = '30'::jsonb) THEN
        RAISE EXCEPTION 'V3g: accept row %', (SELECT json_agg(a) FROM public.property_intake_accepts a WHERE intake_id = f1);
      END IF;
      IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(client.get_property_activity(162)) e
                      WHERE e ->> 'kind' = 'intake_accepted' AND e ->> 'intake_id' = f1::text
                        AND e ->> 'text' LIKE '%Grease trap gallons 30 → 92 (AI lookup of Test Model ZX-1)') THEN
        RAISE EXCEPTION 'V3g: activity %', (SELECT json_agg(e ->> 'text') FROM jsonb_array_elements(client.get_property_activity(162)) e WHERE e ->> 'intake_id' = f1::text);
      END IF;
      -- the form's own number is recorded without a lookup (f2, 250)
      PERFORM client.accept_intake_answers(f2, ARRAY['grease_trap.capacity_gallons'], '{"grease_trap.capacity_gallons": 92}'::jsonb);
      IF NOT EXISTS (SELECT 1 FROM public.property_intake_accepts WHERE intake_id = f2 AND size_lookup_id IS NULL AND new_value = '250'::jsonb) THEN
        RAISE EXCEPTION 'V3g: f2 accept row';
      END IF;
      -- f3 has nothing to save (its model was not shown, its Gallons blank): refused as before
      BEGIN
        PERFORM client.accept_intake_answers(f3, ARRAY['grease_trap.capacity_gallons'], '{"grease_trap.capacity_gallons": 250}'::jsonb);
        RAISE EXCEPTION 'V3g: f3 accepted';
      EXCEPTION WHEN sqlstate '22023' THEN
        IF SQLERRM NOT LIKE '%not answered%' THEN RAISE EXCEPTION 'V3g: f3 refused with %', SQLERRM; END IF;
      END;
      RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = 'sentinel';
    END;
  EXCEPTION WHEN sqlstate 'P0099' THEN NULL;
  END;
  IF EXISTS (SELECT 1 FROM public.grease_trap_size_lookups) OR (SELECT grease_trap_size_gallons FROM public.properties WHERE id = 162) <> 30 THEN
    RAISE EXCEPTION 'V3: the fixtures did not roll back';
  END IF;
  RAISE NOTICE 'VERIFY ok: % forms read as before', n;
END $v$;

COMMIT;
