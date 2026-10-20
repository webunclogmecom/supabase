-- Rollback of 2026-10-20_1600_hr_access_watch_picture_planner: puts back the 13 client.* bodies and client.v_intake_submissions exactly as read on 2026-10-20,
-- drops hr.fn_app_open, sets picture_planner back to off. hr.access_refusals rows for picture_planner are kept (the record).
BEGIN;
SET LOCAL lock_timeout = '3s';
UPDATE hr.access_apps SET mode = 'off' WHERE app = 'picture_planner';
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
    if not public.fn_intake_answered(v_i.answers, v_key) then
      raise exception 'That question was not answered on the form, so there is nothing to save.'
        using errcode = '22023', detail = 'blocker=not_answered in client.accept_intake_answers: ' || v_key;
    end if;
    if not public.fn_intake_applicable(v_i.form_snapshot, v_i.answers, v_key) then
      raise exception 'That answer belongs to a question the collector was not shown, so it cannot be accepted.'
        using errcode = '22023',
              detail  = 'blocker=not_shown in client.accept_intake_answers: ' || v_key;
    end if;

    select f into v_field from jsonb_array_elements(v_cmp -> 'fields') f where f ->> 'key' = v_key;
    v_old := v_field -> 'ours';
    v_new := v_i.answers -> v_key -> 'value';

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
      (intake_id, property_id, question_key, target_column, old_value, new_value, actor)
    values (p_intake_id, v_i.property_id, v_key, v_col, v_old, v_new, v_actor);
    v_written := v_written || v_key;
  end loop;

  -- Reuse the gated writers rather than touching public.properties directly. They
  -- carry the allowlist, the staff gate, the error vocabulary and, for gallons and
  -- the lock box, the outbound Jobber push (which only fires because auth.uid() is
  -- not null here, i.e. because a real person pressed Save).
  if v_patch <> '{}'::jsonb then
    perform client.update_property_operational(v_i.property_id, v_patch);
  end if;
  if v_gallons is not null then
    perform client.update_property_capacity(v_i.property_id, v_gallons);
  end if;

  update public.property_intakes
     set accepted = accepted || jsonb_build_object(
           'at', to_jsonb(now()), 'by', to_jsonb(v_actor), 'keys', to_jsonb(v_written))
   where id = p_intake_id;

  return jsonb_build_object('ok', true, 'intake_id', p_intake_id,
                            'accepted', to_jsonb(v_written), 'by', v_actor);
end $function$;

CREATE OR REPLACE FUNCTION client.approve_property_page(p_page_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_page  public.property_pages;
  v_newest int;
  v_block text;
  v_map   jsonb;
  v_cur   jsonb;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.approve_property_page';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.approve_property_page';
  end if;
  if not (v_uid = any (public.fn_page_approver_ids())) then
    raise exception 'Only % can approve a page.', public.fn_page_approver_names() using errcode = '42501',
      detail = 'blocker=not_an_approver in client.approve_property_page';
  end if;

  select * into v_page from public.property_pages where id = p_page_id;
  if not found then
    raise exception 'That version of the page does not exist. Reload the Page Builder.' using errcode = 'P0002',
      detail = 'blocker=no_such_version in client.approve_property_page';
  end if;
  perform pg_advisory_xact_lock(7342, v_page.property_id::int);
  select * into v_page from public.property_pages where id = p_page_id;

  if v_page.approved_at is not null then
    raise exception 'This version is already approved.' using errcode = '22023',
      detail = 'blocker=already_approved in client.approve_property_page';
  end if;
  select max(version) into v_newest from public.property_pages where property_id = v_page.property_id;
  if v_page.version <> v_newest then
    raise exception 'A newer version of this page was submitted. Approve that one instead.' using errcode = '22023',
      detail = 'blocker=not_newest in client.approve_property_page';
  end if;
  -- A developer approval (app_config.page_self_approvers, Fred only) may approve their own version.
  if v_page.submitted_by = v_uid and not (v_uid = any (public.fn_page_self_approver_ids())) then
    raise exception 'You submitted this version, so another person has to approve it.' using errcode = '42501',
      detail = 'blocker=own_version in client.approve_property_page';
  end if;
  v_block := public.fn_page_blocker(v_page.property_id);
  if v_block is not null then
    raise exception '%', v_block using errcode = '22023', detail = 'blocker=link_would_not_open in client.approve_property_page';
  end if;

  update public.property_pages
     set approved_at = now(), approved_by = v_uid, approved_by_email = v_email
   where id = p_page_id;

  -- Since 2026-09-27 the map is drawn in the draft and reaches the property only here, when the version is
  -- approved (Fred: "Make it draft-only"), by a second person or by a developer approval (page_self_approvers). Only a version whose map came from the draft is
  -- copied: submit stores that map as an object WITHOUT rev. A version from an older builder froze the
  -- property's own map (NULL or an object WITH rev) while that builder may still be drawing on the
  -- property, so it is left alone. The revision always moves and the column is never set to NULL (a
  -- NULL restarts the revision at 0, and a stale save at that number would be accepted). The row is
  -- locked only when there is something to write.
  v_map := v_page.content -> 'site_map';
  if jsonb_typeof(v_map) = 'object' and not (v_map ? 'rev') then
    select p.site_map into v_cur from public.properties p where p.id = v_page.property_id;
    if coalesce(v_cur, '{}'::jsonb) - 'rev' is distinct from v_map then
      select p.site_map into v_cur from public.properties p where p.id = v_page.property_id for update;
      if coalesce(v_cur, '{}'::jsonb) - 'rev' is distinct from v_map then
        update public.properties
           set site_map = v_map || jsonb_build_object('rev', coalesce((v_cur ->> 'rev')::int, 0) + 1)
         where id = v_page.property_id;
      end if;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'page_id', p_page_id, 'version', v_page.version);
end $function$;

CREATE OR REPLACE FUNCTION client.cancel_intake(p_intake_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_i     record;
  v_at    timestamptz;
begin
  if v_uid is null then
    raise exception 'Please sign in again.'
      using errcode = '28000', detail = 'blocker=not_signed_in in client.cancel_intake';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.'
      using errcode = '42501', detail = 'blocker=not_staff in client.cancel_intake';
  end if;
  if p_intake_id is null then
    raise exception 'No form was chosen. Go back to the forms and try again.'
      using errcode = '22023', detail = 'blocker=no_intake in client.cancel_intake';
  end if;

  -- The row lock makes a cancel and a collector's submit take turns (see the trigger below).
  select i.id, i.submitted_at, i.cancelled_at
    into v_i
    from public.property_intakes i
   where i.id = p_intake_id
   for update;
  if not found then
    raise exception 'This form does not exist.'
      using errcode = 'P0002', detail = 'blocker=not_found in client.cancel_intake';
  end if;
  if v_i.cancelled_at is not null then
    raise exception 'This form was already cancelled. Its link no longer opens.'
      using errcode = '22023', detail = 'blocker=already_cancelled in client.cancel_intake';
  end if;
  if v_i.submitted_at is not null then
    raise exception 'This form was already submitted, so it stays as a record and cannot be cancelled.'
      using errcode = '22023', detail = 'blocker=submitted in client.cancel_intake';
  end if;

  -- Guarded write: race-safe on its own under READ COMMITTED, the lock above is belt and braces.
  update public.property_intakes
     set cancelled_at = now()
   where id = v_i.id and submitted_at is null and cancelled_at is null
  returning cancelled_at into v_at;
  if not found then
    raise exception 'This form changed a moment ago. Reload the forms to see its state.'
      using errcode = '22023', detail = 'blocker=changed in client.cancel_intake';
  end if;

  return jsonb_build_object('ok', true, 'intake_id', v_i.id, 'cancelled_at', v_at);
end
$function$;

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
end $function$;

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
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;

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
end $function$;

CREATE OR REPLACE FUNCTION client.get_intake_link(p_intake_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_i     record;
  v_deleted boolean;
  v_url   text;
begin
  if v_uid is null then
    raise exception 'Please sign in again.'
      using errcode = '28000', detail = 'blocker=not_signed_in in client.get_intake_link';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.'
      using errcode = '42501', detail = 'blocker=not_staff in client.get_intake_link';
  end if;
  if p_intake_id is null then
    raise exception 'No form was chosen. Go back to the forms and try again.'
      using errcode = '22023', detail = 'blocker=no_intake in client.get_intake_link';
  end if;

  -- Everything but the token first: every refusal is decided before the token is read.
  select i.id, i.property_id, i.expires_at, i.submitted_at, i.cancelled_at
    into v_i
    from public.property_intakes i
   where i.id = p_intake_id;
  if not found then
    raise exception 'This form does not exist.'
      using errcode = 'P0002', detail = 'blocker=not_found in client.get_intake_link';
  end if;
  if v_i.cancelled_at is not null then
    raise exception 'This form was cancelled, so its link no longer opens.'
      using errcode = '22023', detail = 'blocker=cancelled in client.get_intake_link';
  end if;
  if v_i.submitted_at is not null then
    raise exception 'This form was already submitted, so its link cannot take answers any more. To collect again, schedule a new intake from the property in the Client App.'
      using errcode = '22023', detail = 'blocker=submitted in client.get_intake_link';
  end if;
  if v_i.expires_at <= now() then
    raise exception 'This link has expired. Schedule a new intake from the property in the Client App to get a new link.'
      using errcode = '22023', detail = 'blocker=expired in client.get_intake_link';
  end if;
  select (p.deleted_at is not null) into v_deleted from public.properties p where p.id = v_i.property_id;
  if coalesce(v_deleted, true) then
    raise exception 'This property was removed, so its form should not be filled any more.'
      using errcode = '22023', detail = 'blocker=property_removed in client.get_intake_link';
  end if;

  -- The link, built in ONE place, public.fn_intake_link_url (2026-09-25_1705). It returns NULL for a
  -- token that does not look like one (the collector endpoint accepts ^[A-Za-z0-9_-]{8,64}$); the token
  -- itself never appears in a message.
  select public.fn_intake_link_url(i.token)
    into v_url
    from public.property_intakes i
   where i.id = v_i.id;
  if v_url is null then
    raise exception 'This form''s link cannot be shown. Ask for help.'
      using errcode = '22023', detail = 'blocker=bad_token in client.get_intake_link';
  end if;

  insert into public.property_intake_link_reveals (intake_id, revealed_by, revealed_email)
  values (v_i.id, v_uid, v_email);

  return jsonb_build_object('ok', true, 'intake_id', v_i.id, 'url', v_url, 'expires_at', v_i.expires_at);
end
$function$;

CREATE OR REPLACE FUNCTION client.get_page_builder(p_property_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_p     record;
  v_live  public.property_pages;
  v_pend  public.property_pages;
  v_newest int;
  v_out   jsonb;
  v_block text;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_page_builder';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_page_builder';
  end if;
  if p_property_id is null then
    raise exception 'No property was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_property in client.get_page_builder';
  end if;

  select p.id, p.client_id, p.name, p.address, p.city, p.latitude, p.longitude, p.site_map,
         p.is_billing, p.deleted_at, c.client_code, c.name as client_name
    into v_p
    from public.properties p join public.clients c on c.id = p.client_id
   where p.id = p_property_id;
  if not found or v_p.deleted_at is not null then
    raise exception 'This property is not active any more.' using errcode = 'P0002',
      detail = 'blocker=property_retired in client.get_page_builder';
  end if;
  if coalesce(v_p.is_billing, false) then
    raise exception 'This is a billing address, not a place we service.' using errcode = '22023',
      detail = 'blocker=billing_property in client.get_page_builder';
  end if;

  select max(version) into v_newest from public.property_pages where property_id = p_property_id;
  select * into v_live from public.property_pages
   where property_id = p_property_id and approved_at is not null order by version desc limit 1;
  select * into v_pend from public.property_pages
   where property_id = p_property_id and approved_at is null and version > coalesce(v_live.version, 0)
   order by version desc limit 1;

  v_block := case
    when v_pend.id is null then 'There is nothing waiting for approval.'
    when not (v_uid = any (public.fn_page_approver_ids())) then
      'Only ' || public.fn_page_approver_names() || ' can approve a page.'
    when v_pend.submitted_by = v_uid and not (v_uid = any (public.fn_page_self_approver_ids()))
      then 'You submitted this version, so another person has to approve it.'
    else public.fn_page_blocker(p_property_id) end;

  with owned as (
    select o.*, q.label from public.fn_page_photo_ids(p_property_id) o
      left join client.v_intake_questions q on q.question_key = o.question_key),
  item as (
    select o.photo_id, jsonb_build_object(
             'photo_id', o.photo_id, 'kind', o.kind, 'bucket', o.bucket, 'path', o.path,
             'visit_id', case when o.kind = 'visit' then o.entity_id end,
             'intake_id', case when o.kind = 'intake' then o.entity_id end,
             'visit_date', o.visit_date, 'question_key', o.question_key,
             'label', coalesce(o.label, o.question_key), 'caption', o.caption,
             'rotation_deg', o.rotation_deg, 'content_type', o.content_type) as j,
           o.kind, o.entity_id, o.visit_date
      from owned o),
  recent_visits as (
    select entity_id from owned where kind = 'visit'
     group by entity_id order by max(visit_date) desc, entity_id desc limit 12),
  -- Every version's photos, not only the live and waiting ones (2026-09-29, Restore): a restored version can hold a
  -- photo that is in neither of them nor in the pool's 12 newest visits, and the builder needs its bucket and path to
  -- show it, or owned=false to leave it out (the validator would refuse it: blocker=content).
  refd as (
    select distinct (ph ->> 'photo_id')::bigint as photo_id
      from public.property_pages pg,
           jsonb_array_elements(case when jsonb_typeof(pg.content -> 'photos') = 'array' then pg.content -> 'photos' else '[]'::jsonb end) ph
     where pg.property_id = p_property_id)
  select jsonb_build_object(
    'property', jsonb_build_object(
        'id', v_p.id, 'client_id', v_p.client_id, 'client_code', v_p.client_code,
        'client_name', v_p.client_name, 'name', nullif(btrim(v_p.name), ''),
        'address', v_p.address, 'city', v_p.city, 'lat', v_p.latitude, 'lng', v_p.longitude,
        'site_map', v_p.site_map, 'site_map_rev', coalesce((v_p.site_map ->> 'rev')::int, 0),
        -- The map is no longer a page source (fn_page_source), but the builder from before 2026-09-27
        -- compares it in its "Nothing changed" check and sends it back as its baseline; submit strips it.
        'source', public.fn_page_source(p_property_id) || jsonb_build_object('site_map', v_p.site_map - 'rev'),
        'driver_link_blocker', public.fn_page_blocker(p_property_id)),
    'intake', (select jsonb_build_object('intake_id', i.id, 'submitted_at', i.submitted_at, 'collector', i.collector)
                 from public.property_intakes i
                where i.property_id = p_property_id and i.submitted_at is not null and i.cancelled_at is null
                order by i.submitted_at desc limit 1),
    'pool', coalesce((select jsonb_agg(it.j order by it.kind, it.visit_date desc nulls last, it.photo_id)
                        from item it
                       where it.kind = 'intake' or it.entity_id in (select entity_id from recent_visits)), '[]'::jsonb),
    'referenced', coalesce((select jsonb_agg(case when it.photo_id is null
                    then jsonb_build_object('photo_id', r.photo_id, 'owned', false)
                    else it.j || jsonb_build_object('owned', true) end)
                  from refd r left join item it on it.photo_id = r.photo_id), '[]'::jsonb),
    -- People only (a name or a role), per D7 "unknown stays unknown"; the client-record label
    -- ("Business - 123-AB") is offered separately as the main line, never as a person.
    'contacts', coalesce((select jsonb_agg(jsonb_build_object(
                  'name', nullif(btrim(concat_ws(' ', cc.first_name, cc.last_name)), ''),
                  'phone', nullif(btrim(cc.phone), ''),
                  'role', coalesce(nullif(btrim(cc.person_role_other), ''), nullif(btrim(cc.person_role), '')))
                  order by cc.property_id nulls last, cc.id)
                from public.client_contacts cc
               where cc.client_id = v_p.client_id and cc.contact_role = 'primary'
                 and (cc.property_id is null or cc.property_id = p_property_id)
                 and (nullif(btrim(concat_ws(' ', cc.first_name, cc.last_name)), '') is not null
                      or nullif(btrim(cc.person_role), '') is not null
                      or nullif(btrim(cc.person_role_other), '') is not null)), '[]'::jsonb),
    'main_line', (select jsonb_build_object(
                    'name', regexp_replace(v_p.client_name, '\s*-\s*' || coalesce(v_p.client_code, '') || '\s*$', ''),
                    'phone', nullif(btrim(cc.phone), ''), 'role', 'Main line')
                    from public.client_contacts cc
                   where cc.client_id = v_p.client_id and cc.contact_role = 'primary'
                     and nullif(btrim(cc.phone), '') is not null
                   order by cc.property_id = p_property_id desc nulls last, cc.id limit 1),
    'newest_version', coalesce(v_newest, 0),
    'live', case when v_live.id is null then null else jsonb_build_object(
              'page_id', v_live.id, 'version', v_live.version, 'content', v_live.content,
              'source', v_live.source, 'submitted_at', v_live.submitted_at,
              'submitted_by_name', public.fn_page_staff_name(v_live.submitted_by_email),
              'approved_at', v_live.approved_at,
              'approved_by_name', public.fn_page_staff_name(v_live.approved_by_email)) end,
    'pending', case when v_pend.id is null then null else jsonb_build_object(
              'page_id', v_pend.id, 'version', v_pend.version, 'content', v_pend.content,
              'source', v_pend.source, 'submitted_at', v_pend.submitted_at,
              'submitted_by_name', public.fn_page_staff_name(v_pend.submitted_by_email),
              'mine', v_pend.submitted_by = v_uid) end,
    'link', (select jsonb_build_object('public_id', l.public_id, 'created_at', l.created_at, 'rotated_at', l.rotated_at)
               from public.property_page_links l where l.property_id = p_property_id),
    'can_approve', v_block is null,
    'approve_blocker', v_block,
    'approvers', public.fn_page_approver_names(),
    -- true only for a developer approval login (Fred): the builder's Submit confirm then says they can approve it.
    'can_self_approve', v_uid = any (public.fn_page_self_approver_ids()) and v_uid = any (public.fn_page_approver_ids()))
  into v_out;
  return v_out;
end $function$;

CREATE OR REPLACE FUNCTION client.get_page_builder_forms(p_property_id bigint)
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
    raise exception 'Please sign in again.'
      using errcode = '28000', detail = 'blocker=not_signed_in in client.get_page_builder_forms';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.'
      using errcode = '42501', detail = 'blocker=not_staff in client.get_page_builder_forms';
  end if;
  if p_property_id is null then
    raise exception 'No property was chosen. Go back to the list and pick one.'
      using errcode = '22023', detail = 'blocker=no_property in client.get_page_builder_forms';
  end if;

  return coalesce((
    with pool as materialized (
      -- The photos submit accepts for this property (D8), intake ones only. Captions are already NULL here.
      select o.photo_id, o.entity_id, o.question_key, o.path
        from public.fn_page_photo_ids(p_property_id) o
       where o.kind = 'intake'
    )
    select jsonb_agg(jsonb_build_object(
             'intake_id',        s.intake_id,
             'submitted_at',     s.submitted_at,
             'collector',        s.collector,
             'status',           s.status,
             'answered_count',   s.answered_count,
             'applicable_count', s.applicable_count,
             'not_shown_count',  a.not_shown,
             'answers',          a.answers,
             'photos',           ph.photos)
           order by s.submitted_at desc, s.intake_id desc)
      from client.v_intake_submissions s
      join public.property_intakes i on i.id = s.intake_id
      -- Rule 14: an answer is offered only when its question was requested, SHOWN and answered.
      -- A 'photos' question (by the snapshot's own type) is not an answer here: its photos come as ids.
      cross join lateral (
        select coalesce(jsonb_object_agg(e.k, e.val) filter (where e.shown and not e.is_photos), '{}'::jsonb) as answers,
               count(*) filter (where not e.shown)::int as not_shown
          from (select x.key as k, x.value -> 'value' as val,
                       public.fn_intake_applicable(i.form_snapshot, i.answers, x.key) as shown,
                       exists (select 1
                                 from jsonb_array_elements(coalesce(i.form_snapshot -> 'sections', '[]'::jsonb)) sec,
                                      jsonb_array_elements(coalesce(sec -> 'questions', '[]'::jsonb)) q
                                where jsonb_typeof(q) = 'object' and q ->> 'key' = x.key and q ->> 'type' = 'photos') as is_photos
                  from jsonb_each(i.answers) x
                 where i.requested ? x.key
                   and public.fn_intake_answered(i.answers, x.key)) e
      ) a
      -- A photo is offered only when its question was requested and SHOWN, and its path is in that
      -- question's SUBMITTED answer (which also means the question was answered).
      cross join lateral (
        select coalesce(jsonb_agg(jsonb_build_object('photo_id', p.photo_id, 'question_key', p.question_key)
                                  order by p.photo_id), '[]'::jsonb) as photos
          from pool p
         where p.entity_id = i.id
           and i.requested ? p.question_key
           and public.fn_intake_applicable(i.form_snapshot, i.answers, p.question_key)
           and coalesce((i.answers -> p.question_key -> 'value') ? p.path, false)
      ) ph
     where s.property_id = p_property_id
       and s.state = 'submitted'), '[]'::jsonb);
end
$function$;

CREATE OR REPLACE FUNCTION client.get_page_versions(p_property_id bigint)
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
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_page_versions';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_page_versions';
  end if;
  if p_property_id is null then
    raise exception 'No property was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_property in client.get_page_versions';
  end if;

  -- ponytail: every version's whole content in one reply (about 2 KB each today); page it if a property ever keeps hundreds.
  return coalesce((
    with v as (
      select pg.*,
             max(pg.version) over () as newest,
             max(pg.version) filter (where pg.approved_at is not null) over () as live_version
        from public.property_pages pg
       where pg.property_id = p_property_id)
    select jsonb_agg(jsonb_build_object(
             'page_id', v.id, 'version', v.version, 'status', s.status, 'content', v.content,
             'submitted_at', v.submitted_at, 'submitted_by_name', public.fn_page_staff_name(v.submitted_by_email),
             'approved_at', v.approved_at, 'approved_by_name', public.fn_page_staff_name(v.approved_by_email),
             'self_approved', coalesce(v.approved_by = v.submitted_by, false),
             'replaced_by_version', r.version, 'replaced_at', r.at,
             'restored_from_version', v.restored_from_version, 'source', v.source)
           order by v.version desc)
      from v
      cross join lateral (select case
               when v.approved_at is not null and v.version = v.live_version then 'live'
               when v.approved_at is not null then 'replaced'
               when v.version = v.newest then 'waiting'
               else 'superseded' end as status) s
      -- replaced: the next APPROVED version and when it was approved; superseded: the next version and when it was submitted
      left join lateral (
        select n.version, case when v.approved_at is not null then n.approved_at else n.submitted_at end as at
          from public.property_pages n
         where s.status in ('replaced', 'superseded')
           and n.property_id = v.property_id and n.version > v.version
           and (v.approved_at is null or n.approved_at is not null)
         order by n.version
         limit 1) r on true), '[]'::jsonb);
end $function$;

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
end $function$;

CREATE OR REPLACE FUNCTION client.page_builder_list()
 RETURNS TABLE(property_id bigint, client_id bigint, client_code text, client_name text, property_name text, address text, city text, intake_status text, intake_id bigint, live_version integer, live_approved_at timestamp with time zone, live_approved_by_name text, pending_version integer, pending_submitted_at timestamp with time zone, pending_submitted_by_name text, property_changed_since_live boolean, photos_no_longer_available integer, has_link boolean, link_blocker text, last_opened_at timestamp with time zone, last_open_was_staff boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.page_builder_list';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.page_builder_list';
  end if;
  return query
  select pi.property_id,
         pi.client_id,
         c.client_code::text,
         c.name::text,
         nullif(btrim(p.name), '')::text,
         p.address::text,
         p.city::text,
         pi.intake_status::text,
         pi.intake_id,
         lv.version,
         lv.approved_at,
         case when lv.id is null then null else public.fn_page_staff_name(lv.approved_by_email) end,
         pv.version,
         pv.submitted_at,
         case when pv.id is null then null else public.fn_page_staff_name(pv.submitted_by_email) end,
         (lv.id is not null and (lv.source - 'site_map') is distinct from public.fn_page_source(p.id)),
         case when lv.id is null then 0 else (
           select count(*)::int from jsonb_array_elements(lv.content -> 'photos') ph
            where not exists (select 1 from public.fn_page_photo_ids(p.id) o
                               where o.photo_id = (ph ->> 'photo_id')::bigint)) end,
         (l.property_id is not null),
         public.fn_page_blocker(p.id),
         lo.opened_at,
         lo.staff
    from client.v_property_intake pi
    join public.properties p on p.id = pi.property_id
    join public.clients c    on c.id = pi.client_id
    left join lateral (select x.* from public.property_pages x
                        where x.property_id = p.id and x.approved_at is not null
                        order by x.version desc limit 1) lv on true
    left join lateral (select x.* from public.property_pages x
                        where x.property_id = p.id and x.approved_at is null
                          and x.version > coalesce(lv.version, 0)
                        order by x.version desc limit 1) pv on true
    left join lateral (select o.opened_at, o.staff from public.property_page_opens o
                        where o.property_id = p.id order by o.opened_at desc limit 1) lo on true
    left join public.property_page_links l on l.property_id = p.id
   where nullif(btrim(c.client_code), '') is not null
   order by c.client_code, p.id;
end $function$;

CREATE OR REPLACE FUNCTION client.rotate_driver_link(p_property_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_new   text;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.rotate_driver_link';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.rotate_driver_link';
  end if;
  update public.property_page_links
     set public_id = public.gen_short_id(22), rotated_at = now(), rotated_by = v_uid
   where property_id = p_property_id
  returning public_id into v_new;
  if v_new is null then
    raise exception 'This page has no site file link yet. It gets one when it is first submitted.' using errcode = 'P0002',
      detail = 'blocker=no_link in client.rotate_driver_link';
  end if;
  return jsonb_build_object('ok', true, 'public_id', v_new);
end $function$;

CREATE OR REPLACE FUNCTION client.submit_property_page(p_property_id bigint, p_content jsonb, p_expected_version integer, p_expected_map_rev integer, p_expected_source jsonb, p_restored_from_version integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid     uuid := auth.uid();
  v_email   text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_p       record;
  v_newest  int;
  v_problem text;
  v_block   text;
  v_source  jsonb;
  v_in      jsonb;
  v_content jsonb;
  v_bad     text;
  v_id      bigint;
  v_map     jsonb;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.submit_property_page';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.submit_property_page';
  end if;
  if p_property_id is null or p_expected_version is null or p_expected_map_rev is null or p_expected_source is null then
    raise exception 'The page could not be sent. Reload the Page Builder and try again.' using errcode = '22023',
      detail = 'blocker=expected_version_required in client.submit_property_page';
  end if;

  -- One submit at a time per property, so the version check below is exact.
  perform pg_advisory_xact_lock(7342, p_property_id::int);

  v_block := public.fn_page_blocker(p_property_id);
  if v_block is not null then
    raise exception '%', v_block using errcode = '22023', detail = 'blocker=link_would_not_open in client.submit_property_page';
  end if;

  -- FOR SHARE: the map check and the frozen map copy come from this one read.
  select p.id, p.site_map into v_p from public.properties p where p.id = p_property_id for share;

  select coalesce(max(version), 0) into v_newest from public.property_pages where property_id = p_property_id;
  if v_newest <> p_expected_version then
    raise exception 'Someone submitted a newer version of this page since you opened it. Reload to see it before you submit.'
      using errcode = '40001', detail = format('blocker=version_clash in client.submit_property_page (you had %s, newest is %s)', p_expected_version, v_newest);
  end if;
  -- A restore (2026-09-29, Fred: "i want like a go back way ... without removing the version 4"): the draft started
  -- from an older version, recorded as restored_from_version. Only a REPLACED version (approved, below the live one):
  -- the live one is already what drivers see, and a waiting or superseded one was never approved. The content
  -- is not compared with it: Fred adjusts the draft before sending, and everything below checks it as usual.
  if p_restored_from_version is not null and not exists (
       select 1 from public.property_pages r
        where r.property_id = p_property_id and r.version = p_restored_from_version and r.approved_at is not null
          and r.version < (select max(l.version) from public.property_pages l
                            where l.property_id = p_property_id and l.approved_at is not null)) then
    raise exception 'Only a version that was live before can be restored. Reload the Page Builder and try again.'
      using errcode = '22023', detail = format('blocker=not_restorable in client.submit_property_page (version %s)', p_restored_from_version);
  end if;
  -- Since 2026-09-27 the site map is part of the DRAFT (Fred: "Make it draft-only"). A builder that sends
  -- content.site_map gets THAT map checked and frozen below, and the property's map is not read, so this
  -- revision check does not apply to it. A builder that does not send the key (the Planner before this
  -- change, which saves the map to the property as it is drawn) still freezes the property's map, guarded
  -- by its revision exactly as before.
  if not (p_content ? 'site_map')
     and (coalesce((v_p.site_map ->> 'rev')::int, 0) <> p_expected_map_rev
          -- The revision alone repeats after a clear (update_property_site_map clears to NULL, rev 0),
          -- so the map is also compared by content, as fn_page_source did before it lost the map.
          or (jsonb_typeof(p_expected_source) = 'object' and p_expected_source ? 'site_map'
              and nullif(p_expected_source -> 'site_map', 'null'::jsonb) is distinct from (v_p.site_map - 'rev'))) then
    raise exception 'The site map changed since you opened this page. Reload to see it before you submit.'
      using errcode = '40001', detail = 'blocker=map_changed in client.submit_property_page';
  end if;
  v_source := public.fn_page_source(p_property_id);
  -- fn_page_source stopped carrying the map on 2026-09-27; a builder from before still sends it in its
  -- baseline, so it is ignored here rather than refused (the older builder's map check is above).
  if v_source is distinct from (case when jsonb_typeof(p_expected_source) = 'object'
                                     then p_expected_source - 'site_map' else p_expected_source end) then
    raise exception 'The property''s details changed since you opened this page (hours, lock box, capacity, counts or notes). Reload to see them before you submit.'
      using errcode = '40001', detail = 'blocker=source_changed in client.submit_property_page';
  end if;

  -- The server owns site_map and each photo's rot: strip them so a stored version can be sent
  -- back as it is (the freeze below adds them again).
  v_in := p_content - 'site_map';
  if jsonb_typeof(v_in -> 'photos') = 'array' then
    v_in := v_in || jsonb_build_object('photos', (
      select coalesce(jsonb_agg(case when jsonb_typeof(ph) = 'object' then ph - 'rot' else ph end order by e.ord), '[]'::jsonb)
        from jsonb_array_elements(v_in -> 'photos') with ordinality e(ph, ord)));
  end if;

  -- The draft's map: rounded first (as client.update_property_site_map does), then validated. A pin far from the
  -- property's address is NOT refused (2026-09-29, Fred: "at most it should be a warning that we can continue"):
  -- the Page Builder warns under the map and in its Submit confirm. A draft map is ALWAYS stored as an object
  -- without rev ({} when it has no pin and no arrow): that shape is what tells approve the version's map
  -- came from the draft. An older builder's version holds the property's map (NULL, or an object WITH rev).
  if p_content ? 'site_map' then
    begin
      v_map := public.fn_site_map_round(nullif(p_content -> 'site_map', 'null'::jsonb));
    exception when others then
      v_map := p_content -> 'site_map';   -- a text lat cannot be rounded: let the validator name the problem
    end;
    v_problem := public.fn_site_map_problem(v_map);
    if v_problem is not null then
      raise exception 'The site map could not be sent (%). Reload the Page Builder and try again.', v_problem
        using errcode = '22023', detail = 'blocker=site_map in client.submit_property_page';
    end if;
    v_map := coalesce(v_map, '{}'::jsonb) - 'rev';
    if coalesce(v_map -> 'pins', '{}'::jsonb) = '{}'::jsonb and coalesce(v_map -> 'arrows', '[]'::jsonb) = '[]'::jsonb then
      v_map := '{}'::jsonb;
    end if;
  else
    v_map := v_p.site_map;
  end if;

  v_problem := public.fn_page_content_problem(p_property_id, v_in);
  if v_problem is not null then
    select ph ->> 'photo_id' into v_bad
      from jsonb_array_elements(case when jsonb_typeof(v_in -> 'photos') = 'array' then v_in -> 'photos' else '[]'::jsonb end) ph
     where (ph ->> 'photo_id') ~ '^[1-9][0-9]{0,11}$'
       and not exists (select 1 from public.fn_page_photo_ids(p_property_id) o where o.photo_id = (ph ->> 'photo_id')::bigint)
     limit 1;
    raise exception '%', v_problem using errcode = '22023',
      detail = 'blocker=content in client.submit_property_page' || coalesce(' photo_id=' || v_bad, '');
  end if;

  -- Freeze: the site map (the draft's, or the property's for an older builder), and each photo's
  -- rotation at submit (to remap marks later).
  v_content := v_in
    || jsonb_build_object('site_map', v_map)
    || jsonb_build_object('photos', coalesce((
         select jsonb_agg(ph || jsonb_build_object('rot', ph2.rotation_deg) order by e.ord)
           from jsonb_array_elements(v_in -> 'photos') with ordinality e(ph, ord)
           join public.photos ph2 on ph2.id = (ph ->> 'photo_id')::bigint), '[]'::jsonb));

  insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email, restored_from_version)
  values (p_property_id, v_newest + 1, v_content, v_source, v_uid, v_email, p_restored_from_version)
  returning id into v_id;

  insert into public.property_page_links (property_id, created_by)
  values (p_property_id, v_uid)
  on conflict (property_id) do nothing;

  return jsonb_build_object('ok', true, 'page_id', v_id, 'version', v_newest + 1);
end $function$;

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
            ELSE (pr.n_app - cardinality(fn_intake_missing(i.form_snapshot, i.requested, i.answers)))
        END AS answered_count,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::text
            WHEN (cardinality(fn_intake_missing(i.form_snapshot, i.requested, i.answers)) = 0) THEN 'Complete'::text
            ELSE 'Incomplete'::text
        END AS status,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::integer
            ELSE ( SELECT (count(*))::integer AS count
               FROM photo_links pl
              WHERE ((pl.entity_type = 'property_intake'::text) AND (pl.entity_id = i.id) AND (pl.deleted_at IS NULL) AND ((NOT (i.requested ? pl.role)) OR (fn_intake_applicable(i.form_snapshot, i.answers, pl.role) AND fn_intake_answered(i.answers, pl.role)))))
        END AS photo_count,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::boolean
            ELSE (fn_intake_answered(i.answers, 'site_map.gt_location'::text) AND fn_intake_applicable(i.form_snapshot, i.answers, 'site_map.gt_location'::text))
        END AS has_gt_pin,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::boolean
            ELSE (fn_intake_answered(i.answers, 'site_map.truck_parking'::text) AND fn_intake_applicable(i.form_snapshot, i.answers, 'site_map.truck_parking'::text))
        END AS has_truck_pin,
    ( SELECT (count(*))::integer AS count
           FROM property_intake_accepts a
          WHERE (a.intake_id = i.id)) AS accepted_count,
    ( SELECT max(a.accepted_at) AS max
           FROM property_intake_accepts a
          WHERE (a.intake_id = i.id)) AS last_accepted_at,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::integer
            ELSE pr.n_app
        END AS applicable_count
   FROM (((property_intakes i
     JOIN properties p ON ((p.id = i.property_id)))
     LEFT JOIN clients c ON ((c.id = p.client_id)))
     CROSS JOIN LATERAL ( SELECT (count(*))::integer AS n_req,
            (count(*) FILTER (WHERE fn_intake_required(i.form_snapshot, i.answers, r.k)))::integer AS n_app
           FROM ( SELECT DISTINCT x.value AS k
                   FROM jsonb_array_elements_text(i.requested) x(value)
                  WHERE ((x.value IS NOT NULL) AND (btrim(x.value) <> ''::text))) r) pr)
  WHERE ((i.cancelled_at IS NULL) AND ((i.submitted_at IS NOT NULL) OR (i.expires_at > now())));
DROP FUNCTION hr.fn_app_open(text, text);
DO $v$ BEGIN
  if md5(pg_get_functiondef('client.accept_intake_answers'::regproc)) <> '23764655cb20fc2ec677d53f913a49c6' then raise exception 'client.accept_intake_answers not restored'; end if;
  if md5(pg_get_functiondef('client.approve_property_page'::regproc)) <> 'cad8783dda41a9c0d60d96dff2be7daf' then raise exception 'client.approve_property_page not restored'; end if;
  if md5(pg_get_functiondef('client.cancel_intake'::regproc)) <> '38f1363503525ae9ff088c7180215c72' then raise exception 'client.cancel_intake not restored'; end if;
  if md5(pg_get_functiondef('client.get_intake'::regproc)) <> 'b97250b9b1e8cc97311370f864539669' then raise exception 'client.get_intake not restored'; end if;
  if md5(pg_get_functiondef('client.get_intake_compare'::regproc)) <> 'a9ba0bb0fa10bcb24a3909e1e6b2db31' then raise exception 'client.get_intake_compare not restored'; end if;
  if md5(pg_get_functiondef('client.get_intake_link'::regproc)) <> 'dc1055b106672049878f836616d65255' then raise exception 'client.get_intake_link not restored'; end if;
  if md5(pg_get_functiondef('client.get_page_builder'::regproc)) <> 'ce9db6597271ef02a8aca7a8827e2444' then raise exception 'client.get_page_builder not restored'; end if;
  if md5(pg_get_functiondef('client.get_page_builder_forms'::regproc)) <> 'db346e623f1bd88627f13335c0df9702' then raise exception 'client.get_page_builder_forms not restored'; end if;
  if md5(pg_get_functiondef('client.get_page_versions'::regproc)) <> '76e3d591a20216989245a5337fd2dd0e' then raise exception 'client.get_page_versions not restored'; end if;
  if md5(pg_get_functiondef('client.get_property_activity'::regproc)) <> '5714277500f072a658a2678c483c1f98' then raise exception 'client.get_property_activity not restored'; end if;
  if md5(pg_get_functiondef('client.page_builder_list'::regproc)) <> '456c1999866c7c8e6b94f9261523f5bf' then raise exception 'client.page_builder_list not restored'; end if;
  if md5(pg_get_functiondef('client.rotate_driver_link'::regproc)) <> '1ad6e96d0e598a34446c8534b424a5a5' then raise exception 'client.rotate_driver_link not restored'; end if;
  if md5(pg_get_functiondef('client.submit_property_page'::regproc)) <> 'af196291989fc3359beb5a6417bded0f' then raise exception 'client.submit_property_page not restored'; end if;
END $v$;
COMMIT;
