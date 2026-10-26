-- ============================================================================
-- ROLLBACK of 2026-10-26_2000_staff_email_rule.sql
-- ============================================================================
-- Restores the 42 previous bodies (copied verbatim from the live definitions on 2026-10-26, each md5-pinned) and drops
-- public.fn_is_staff_email. Run the edge-function and sign-up-rule rollbacks first if those steps have shipped.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $r$
DECLARE d text;
BEGIN
  -- client.generate_visits_for_client(bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.generate_visits_for_client(p_client_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_email text;
  v_res   jsonb;
begin
  perform hr.fn_check_app('client_app', 'edit', 'generate visits');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email',''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_client_id is null then
    -- Guard the shape of the call itself: a null here would run the FULL sweep,
    -- including the destructive cleanup branch. The app must never do that.
    raise exception 'a client is required' using errcode = '22023';
  end if;

  select public.fn_generate_sa_visits(p_client_id) into v_res;
  return v_res;
end;
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '640f1c7ce92d00f416d76f40a6ed8f43' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.generate_visits_for_client(bigint)'; END IF;
  IF md5(pg_get_functiondef('client.generate_visits_for_client(bigint)'::regprocedure)) <> '715d35e03b9e3a4cde792270d4aabcb1' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.generate_visits_for_client(bigint)'; END IF;
  EXECUTE d;
  -- client.update_property_site_map(bigint,jsonb,integer)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.update_property_site_map(p_property_id bigint, p_site_map jsonb, p_expected_rev integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_problem text;
  v_cur     jsonb;
  v_cur_rev integer;
  v_next    jsonb;
  v_lat     numeric;
  v_lng     numeric;
  v_far     int;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_property_id is null then
    raise exception 'p_property_id is required' using errcode = '22023';
  end if;

  select site_map, latitude, longitude into v_cur, v_lat, v_lng
    from public.properties
   where id = p_property_id and deleted_at is null
   for update;   -- 2026-09-27: an approval committing between this read and the UPDATE must not be overwritten
  if not found then
    raise exception 'property % is not a live property', p_property_id using errcode = 'P0002';
  end if;

  v_cur_rev := coalesce((v_cur ->> 'rev')::integer, 0);
  -- Optimistic lock. Cheap insurance rather than a measured contention problem: two
  -- office people building maps at once has not been observed, and Fred's decision 8b
  -- is explicitly that a silent last-write-wins is not acceptable.
  if p_expected_rev is not null and p_expected_rev <> v_cur_rev then
    raise exception 'the site map changed since you opened it (you had revision %, stored revision is %)',
      p_expected_rev, v_cur_rev using errcode = '40001';
  end if;

  if p_site_map is null then                      -- clearing the map is legal
    update public.properties set site_map = null where id = p_property_id;
    return jsonb_build_object('ok', true, 'cleared', true, 'rev', v_cur_rev);
  end if;

  -- Round FIRST, then validate, so precision cannot push a legal map over the cap.
  v_next := public.fn_site_map_round(p_site_map);
  v_problem := public.fn_site_map_problem(v_next);
  if v_problem is not null then
    raise exception '%', v_problem using errcode = '22023';
  end if;

  -- Sanity bound against the property's own geocode. ⚠ THIS DOES NOT CATCH A PIN ON
  -- THE WRONG BUILDING OF THE SAME CLIENT: the six-property client's buildings are
  -- metres apart. It catches a grossly wrong pin, the wrong city or a swapped
  -- lat/lng, and that is all it claims.
  if v_lat is not null and v_lng is not null then
    select count(*) into v_far
      from jsonb_each(coalesce(v_next->'pins','{}'::jsonb)) e(k,v)
     where abs((v->>'lat')::numeric - v_lat) > 0.05
        or abs((v->>'lng')::numeric - v_lng) > 0.05;
    if v_far > 0 then
      raise exception '% pin(s) are more than about 5 km from this property''s address; check the map is on the right property',
        v_far using errcode = '22023';
    end if;
  end if;

  v_next := v_next || jsonb_build_object('rev', v_cur_rev + 1);
  -- updated_at is set by trg_properties_updated_at; never set it here.
  update public.properties set site_map = v_next where id = p_property_id;

  return jsonb_build_object('ok', true, 'rev', v_cur_rev + 1, 'site_map', v_next);
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '49d321a16d09cf4a96f0e37efb38a428' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.update_property_site_map(bigint,jsonb,integer)'; END IF;
  IF md5(pg_get_functiondef('client.update_property_site_map(bigint,jsonb,integer)'::regprocedure)) <> 'a9ec8b23aaf7338aae60e24d150d4037' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.update_property_site_map(bigint,jsonb,integer)'; END IF;
  EXECUTE d;
  -- client.get_intake_link(bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.get_intake_link(p_intake_id bigint)
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
  perform hr.fn_check_app('picture_planner', 'edit', 'show a collector link');   -- 2026-10-20_1600 access phase 3
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
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'bad7be13927c08904fa986a602fb5b9a' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.get_intake_link(bigint)'; END IF;
  IF md5(pg_get_functiondef('client.get_intake_link(bigint)'::regprocedure)) <> '0281ae89d4546602a287ba495af952d3' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.get_intake_link(bigint)'; END IF;
  EXECUTE d;
  -- client.get_page_builder_forms(bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.get_page_builder_forms(p_property_id bigint)
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
  perform hr.fn_require_app('picture_planner', 'view');   -- 2026-10-20_1600 access phase 3
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
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '0fddbf3de8aff35149919d1fc93f8e3f' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.get_page_builder_forms(bigint)'; END IF;
  IF md5(pg_get_functiondef('client.get_page_builder_forms(bigint)'::regprocedure)) <> 'd12b8a55532b550592f8b0f4266f071a' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.get_page_builder_forms(bigint)'; END IF;
  EXECUTE d;
  -- client.update_client_contact(bigint,jsonb)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.update_client_contact(p_contact_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed  text[] := array['first_name','last_name','email','phone','contact_role','property_id'];
  v_roles    text[] := array['primary','accounting'];
  v_bad      text[];
  v_row      public.client_contacts;
  v_first    text;
  v_last     text;
  v_email    text;
  v_phone    text;
  v_role     text;
  v_prop     bigint;
  v_prop_txt text;
  v_jobber   boolean;
  v_name     text;
  v_out      public.client_contacts;
begin
  perform hr.fn_check_app('client_app', 'edit', 'edit a contact');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_contact_id is null then
    raise exception 'p_contact_id is required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for a contact: %. Allowed: %', v_bad, v_allowed
      using errcode = '22023';
  end if;

  select * into v_row from public.client_contacts where id = p_contact_id;
  if not found then
    raise exception 'contact % not found', p_contact_id using errcode = 'P0002';
  end if;

  -- The ownership boundary (see header).
  v_jobber := v_row.property_id is null and v_row.contact_role = 'primary';
  if v_jobber then
    raise exception 'This is the client''s main contact. Its email and phone are saved through the save-client-contact edge function, which pushes to Jobber first and verifies — a direct write here would be overwritten by the next Jobber poll.'
      using errcode = '42501';
  end if;

  v_first := case when p_patch ? 'first_name'
                  then nullif(btrim(coalesce(p_patch->>'first_name','')),'') else v_row.first_name end;
  v_last  := case when p_patch ? 'last_name'
                  then nullif(btrim(coalesce(p_patch->>'last_name','')),'')  else v_row.last_name end;
  v_email := case when p_patch ? 'email'
                  then nullif(btrim(coalesce(p_patch->>'email','')),'')      else v_row.email end;
  v_phone := case when p_patch ? 'phone'
                  then nullif(btrim(coalesce(p_patch->>'phone','')),'')      else v_row.phone end;
  v_role  := case when p_patch ? 'contact_role'
                  then lower(nullif(btrim(coalesce(p_patch->>'contact_role','')),''))
                  else v_row.contact_role end;

  if p_patch ? 'property_id' then
    v_prop_txt := nullif(btrim(coalesce(p_patch->>'property_id','')), '');
    if v_prop_txt is null then
      v_prop := null;
    else
      if v_prop_txt !~ '^[0-9]+$' then
        raise exception 'property_id must be a positive integer, got %', v_prop_txt
          using errcode = '22023';
      end if;
      v_prop := v_prop_txt::bigint;
      if not exists (select 1 from public.properties p
                     where p.id = v_prop and p.client_id = v_row.client_id) then
        raise exception 'Property % does not belong to this client.', v_prop
          using errcode = '22023';
      end if;
    end if;
  else
    v_prop := v_row.property_id;
  end if;

  -- Same required set as create: a name, and at least one contact method.
  if v_first is null then
    raise exception 'First name is required.' using errcode = '22023';
  end if;
  if v_email is null and v_phone is null then
    raise exception 'Enter at least a phone number or an email address.' using errcode = '22023';
  end if;
  if v_role is null or v_role <> all (v_roles) then
    if v_role = 'city' then
      raise exception 'The City role has been retired. City email addresses now live on the location itself, under City email.'
        using errcode = '22023',
              detail  = 'blocker=contact_role_city_retired value=city';
    end if;
    raise exception 'Pick a role for this contact: Main contact, or Accounting.'
      using errcode = '22023',
            detail  = 'blocker=contact_role_unknown value=' || coalesce(v_role, '(null)');
  end if;
  if v_email is not null and v_email not like '%_@_%.__%' then
    raise exception '% is not a valid email address.', v_email using errcode = '22023';
  end if;

  -- ⚠ Moving a contact TO client-level primary would collide with the
  -- Jobber-synced row (UNIQUE NULLS NOT DISTINCT) or, worse, become one.
  if v_prop is null and v_role = 'primary' then
    raise exception 'This client already has a client-level main contact and there can only be one. Pick a location, or use the accounting role.'
      using errcode = '22023';
  end if;

  v_name := btrim(concat_ws(' ', v_first, v_last));

  begin
    update public.client_contacts set
      first_name   = v_first,
      last_name    = v_last,
      email        = v_email,
      phone        = v_phone,
      contact_role = v_role,
      property_id  = v_prop,
      -- keep the display value coherent; `name` is what existing readers use
      name         = case when v_name = '' then name else v_name end
    where id = p_contact_id
    returning * into v_out;
  exception when unique_violation then
    raise exception 'That property already has a % contact. Edit that one instead.', v_role
      using errcode = '23505';
  end;

  return to_jsonb(v_out);
end
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '83feb14c5dd3df0e57c3cc2642921bca' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.update_client_contact(bigint,jsonb)'; END IF;
  IF md5(pg_get_functiondef('client.update_client_contact(bigint,jsonb)'::regprocedure)) <> '04f1fb460b208bfa0de9adc0a48fffd0' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.update_client_contact(bigint,jsonb)'; END IF;
  EXECUTE d;
  -- hr.get_person_bonus_amounts(bigint[])
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION hr.get_person_bonus_amounts(p_employee_ids bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-19_1200: each person's own bonus amounts, every dated row (newest first), so Admin Review can price a visit or
-- shift on its own date. Same gate as hr.get_bonus_amounts (any staff sign-in). A person with no row earns $0.
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
begin
  if auth.uid() is null or v_email is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in hr.get_person_bonus_amounts';
  end if;
  if not (v_email like '%@unclogme.com' or v_email like '%@ayache.com') then
    raise exception 'This is for UnclogMe staff accounts only.' using errcode = '42501', detail = 'blocker=not_staff in hr.get_person_bonus_amounts';
  end if;
  -- 2026-10-20_1400 (phase 2): amounts follow the HR "See bonus amounts" setting
  if hr.fn_access_rank(hr.fn_app_level('hr_bonus')) < 1 then
    raise exception 'You cannot see bonus amounts. Ask Fred or Yannick to change it.'
      using errcode = '42501', detail = 'blocker=no_access app=hr_bonus in hr.get_person_bonus_amounts';
  end if;
  if p_employee_ids is null or cardinality(p_employee_ids) > 200 then
    raise exception 'Ask for up to 200 people at a time.' using errcode = '22023', detail = 'blocker=ids in hr.get_person_bonus_amounts';
  end if;
  return coalesce((
    select jsonb_object_agg(e.id::text, jsonb_build_object(
             'per_visit_bonus', coalesce((select jsonb_agg(jsonb_build_object('effective_from', p.effective_from, 'amount', p.amount)
                                                           order by p.effective_from desc, p.id desc)
                                            from (select distinct on (p2.effective_from) p2.* from hr.pay_rates p2
                                                   where p2.employee_id = e.id and p2.kind = 'per_visit_bonus' and not hr.fn_rate_superseded(p2.id, p2.employee_id, p2.kind, p2.effective_from)
                                                   order by p2.effective_from, p2.id desc) p), '[]'::jsonb),
             'per_shift_bonus', coalesce((select jsonb_agg(jsonb_build_object('effective_from', p.effective_from, 'amount', p.amount)
                                                           order by p.effective_from desc, p.id desc)
                                            from (select distinct on (p2.effective_from) p2.* from hr.pay_rates p2
                                                   where p2.employee_id = e.id and p2.kind = 'per_shift_bonus' and not hr.fn_rate_superseded(p2.id, p2.employee_id, p2.kind, p2.effective_from)
                                                   order by p2.effective_from, p2.id desc) p), '[]'::jsonb)))
      from public.employees e where e.id = any(p_employee_ids)), '{}'::jsonb);
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'a78e629d34912c2c30a859b5899d6bdf' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'hr.get_person_bonus_amounts(bigint[])'; END IF;
  IF md5(pg_get_functiondef('hr.get_person_bonus_amounts(bigint[])'::regprocedure)) <> 'd43f684eb0006b83cc711e1eb3288467' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'hr.get_person_bonus_amounts(bigint[])'; END IF;
  EXECUTE d;
  -- client.get_intake(bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.get_intake(p_intake_id bigint)
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
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '98a0368262201490e0d0c0999608b943' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.get_intake(bigint)'; END IF;
  IF md5(pg_get_functiondef('client.get_intake(bigint)'::regprocedure)) <> 'ada2cdca09de8410246ad2e502f5b6c0' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.get_intake(bigint)'; END IF;
  EXECUTE d;
  -- client.get_page_builder(bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.get_page_builder(p_property_id bigint)
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
  perform hr.fn_require_app('picture_planner', 'view');   -- 2026-10-20_1600 access phase 3
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
  -- The builder edits the newest version still waiting: not approved, not rejected, submitted after the live one. Older
  -- waiting versions are decided from Activity (2026-10-21).
  select * into v_pend from public.property_pages
   where property_id = p_property_id and approved_at is null and rejected_at is null and version > coalesce(v_live.version, 0)
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
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'b2a20853d380b920417e7a4848955a68' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.get_page_builder(bigint)'; END IF;
  IF md5(pg_get_functiondef('client.get_page_builder(bigint)'::regprocedure)) <> '886c391e5e710a5a2d4ae2cd26881f0a' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.get_page_builder(bigint)'; END IF;
  EXECUTE d;
  -- client.update_property_capacity(bigint,integer)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.update_property_capacity(p_property_id bigint, p_gallons integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_client bigint;
begin
  if coalesce(current_setting('unclogme.intake_accept', true), '') = 'on' then   -- 2026-10-21_0620: reached through accept_intake_answers<<CR>>
    perform hr.fn_check_app('picture_planner', 'edit', 'edit property capacity');<<CR>>
  else<<CR>>
    perform hr.fn_check_app('client_app', 'edit', 'edit property capacity');<<CR>>
  end if;
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_gallons is not null and (p_gallons < 0 or p_gallons > 20000) then
    raise exception 'Capacity must be between 0 and 20,000 gallons.' using errcode = '22023';
  end if;

  -- 🛑 Writes public.properties, NOT service_configs. The previous body looked up service_configs by
  -- property and INSERTed when it found none, which violated UNIQUE(client_id, service_type) for any
  -- client that already had a Pumping config on a different property (209 properties, 184 clients).
  -- A single UPDATE on the property has no uniqueness to violate.
  update public.properties
     set grease_trap_size_gallons = p_gallons
   where id = p_property_id
  returning client_id into v_client;

  if v_client is null then
    raise exception 'property % not found', p_property_id using errcode = 'P0002';
  end if;

  return jsonb_build_object('property_id', p_property_id, 'gallons', p_gallons);
end
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '1a08a7ea703301541a7abce2da5db064' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.update_property_capacity(bigint,integer)'; END IF;
  IF md5(pg_get_functiondef('client.update_property_capacity(bigint,integer)'::regprocedure)) <> '06ce39fc754f289742e2b21d4db81428' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.update_property_capacity(bigint,integer)'; END IF;
  EXECUTE d;
  -- client.rotate_driver_link(bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.rotate_driver_link(p_property_id bigint)
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
  perform hr.fn_check_app('picture_planner', 'edit', 'get a new site file link');   -- 2026-10-20_1600 access phase 3
  update public.property_page_links
     set public_id = public.gen_short_id(22), rotated_at = now(), rotated_by = v_uid
   where property_id = p_property_id
  returning public_id into v_new;
  if v_new is null then
    raise exception 'This page has no site file link yet. It gets one when it is first submitted.' using errcode = 'P0002',
      detail = 'blocker=no_link in client.rotate_driver_link';
  end if;
  return jsonb_build_object('ok', true, 'public_id', v_new);
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '528a1e615cf6e96894cfe91dee8246eb' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.rotate_driver_link(bigint)'; END IF;
  IF md5(pg_get_functiondef('client.rotate_driver_link(bigint)'::regprocedure)) <> '33a03d0157ceb6df869f76411df0a5a9' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.rotate_driver_link(bigint)'; END IF;
  EXECUTE d;
  -- client.approve_property_page(bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.approve_property_page(p_page_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_page  public.property_pages;
  v_live  int;
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
  perform hr.fn_check_app('picture_planner', 'edit', 'approve a site file');   -- 2026-10-20_1600 access phase 3
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
  if v_page.rejected_at is not null then
    raise exception 'This version was rejected, so it cannot be approved. Submit a new version.' using errcode = '22023',
      detail = 'blocker=rejected in client.approve_property_page';
  end if;
  -- Any version submitted after the live one is waiting and can be decided, not only the newest (Fred, 2026-10-21: "all
  -- that are pending can be waiting for approval, but only the ones that were submitted after an approved version").
  -- One below the live version was passed over and cannot.
  select max(version) into v_live from public.property_pages where property_id = v_page.property_id and approved_at is not null;
  if v_page.version < coalesce(v_live, 0) then
    raise exception 'A later version of this page is already live, so this one can no longer be approved.' using errcode = '22023',
      detail = 'blocker=superseded in client.approve_property_page';
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
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '33b9b43d7c8e0349397f3947f49b114b' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.approve_property_page(bigint)'; END IF;
  IF md5(pg_get_functiondef('client.approve_property_page(bigint)'::regprocedure)) <> '46fa450b4365a5f552208bf7ae37d857' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.approve_property_page(bigint)'; END IF;
  EXECUTE d;
  -- client.get_intake_compare(bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.get_intake_compare(p_intake_id bigint)
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
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '874df89236419cd32d4dc76d8c37738b' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.get_intake_compare(bigint)'; END IF;
  IF md5(pg_get_functiondef('client.get_intake_compare(bigint)'::regprocedure)) <> 'ded16ded3733b1468f0becb58dc1feaf' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.get_intake_compare(bigint)'; END IF;
  EXECUTE d;
  -- hr.get_review_bonuses(bigint[],jsonb)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION hr.get_review_bonuses(p_visit_ids bigint[], p_shifts jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-19_1815: what Admin Review needs to show a bonus the way HR pays it. Per visit: the Calendar crew (who is paid)
-- and, once the bonus is approved, the amounts HR recorded. Per shift ("<employee_id>|<YYYY-MM-DD>"): the recorded amount.
-- Same gate as hr.get_person_bonus_amounts (any staff sign-in).
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
  v_see boolean;
begin
  if auth.uid() is null or v_email is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in hr.get_review_bonuses';
  end if;
  if not (v_email like '%@unclogme.com' or v_email like '%@ayache.com') then
    raise exception 'This is for UnclogMe staff accounts only.' using errcode = '42501', detail = 'blocker=not_staff in hr.get_review_bonuses';
  end if;
  if p_visit_ids is null or cardinality(p_visit_ids) > 2000
     or p_shifts is null or jsonb_typeof(p_shifts) <> 'array' or jsonb_array_length(p_shifts) > 500 then
    raise exception 'Ask for up to 2,000 visits and 500 shifts at a time.' using errcode = '22023', detail = 'blocker=size in hr.get_review_bonuses';
  end if;
  -- 2026-10-20_1400 (phase 2): the crew always, the amounts only with the HR "See bonus amounts" setting
  v_see := hr.fn_access_rank(hr.fn_app_level('hr_bonus')) >= 1;
  return jsonb_build_object(
    'amounts_hidden', not v_see,
    -- 2026-10-20 (Trello bZvoo91Z): may this person set a custom amount (hr.set_visit_bonus would let them)
    'can_set_amounts', v_see and coalesce(hr.fn_caller_level() in ('admin', 'office'), false)
                       and case when hr.fn_app_mode('hr_pay') = 'on' then hr.fn_access_rank(hr.fn_app_level('hr_pay')) >= 1
                                else hr.fn_caller_level() = 'admin' end
                       and (hr.fn_app_mode('admin_review') <> 'on' or hr.fn_access_rank(hr.fn_app_level('admin_review')) >= 2),
    'visits', coalesce((
      select jsonb_object_agg(v.id::text, jsonb_build_object(
               'crew', coalesce((select jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', e.full_name) order by e.full_name)
                                   from public.visit_team vt join public.employees e on e.id = vt.employee_id
                                  where vt.visit_id = v.id), '[]'::jsonb),
               'recorded', case when not v_see then null else (select jsonb_agg(jsonb_build_object('employee_id', g.employee_id, 'amount', g.amount) order by g.employee_id)
                              from hr.bonus_events g
                             where g.kind = 'visit_bonus' and g.visit_id = v.id and g.reverses_id is null
                               and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)) end,
               -- 2026-10-20 (Trello bZvoo91Z): custom amounts for this visit, per crew member ("employee_id": {...})
               'custom', case when not v_see then null else (
                 select jsonb_object_agg(o.employee_id::text, jsonb_build_object('amount', o.amount, 'reason', o.reason,
                          'set_by', hr.fn_person_label(o.created_by_email),
                          'set_on', (o.created_at at time zone 'America/New_York')::date))
                   from (select distinct on (x.employee_id) x.* from hr.visit_bonus_overrides x
                          where x.visit_id = v.id order by x.employee_id, x.id desc) o
                  where o.amount is not null) end))
        from (select distinct unnest(p_visit_ids) as id) v), '{}'::jsonb),
    'shifts', case when not v_see then '{}'::jsonb else coalesce((
      select jsonb_object_agg((x->>'employee_id') || '|' || (x->>'shift_date'), g.amount)
        from jsonb_array_elements(p_shifts) x
        join hr.bonus_events g on g.kind = 'shift_bonus' and g.employee_id = (x->>'employee_id')::bigint
                              and g.work_date = (x->>'shift_date')::date and g.reverses_id is null
                              and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)), '{}'::jsonb) end,
    -- 2026-10-21 (Fred): custom shift amounts, "<employee_id>|<YYYY-MM-DD>": {amount, reason, set_by, set_on}
    'shifts_custom', case when not v_see then '{}'::jsonb else coalesce((
      select jsonb_object_agg(o.employee_id || '|' || to_char(o.shift_date, 'YYYY-MM-DD'),
               jsonb_build_object('amount', o.amount, 'reason', o.reason, 'set_by', hr.fn_person_label(o.created_by_email),
                                  'set_on', (o.created_at at time zone 'America/New_York')::date))
        from (select distinct on (x.employee_id, x.shift_date) x.*
                from hr.shift_bonus_overrides x
                join jsonb_array_elements(p_shifts) q on (q->>'employee_id')::bigint = x.employee_id
                                                      and (q->>'shift_date')::date = x.shift_date
               order by x.employee_id, x.shift_date, x.id desc) o
       where o.amount is not null), '{}'::jsonb) end);
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '531b8658b32b2572f0efb02c554c57e1' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'hr.get_review_bonuses(bigint[],jsonb)'; END IF;
  IF md5(pg_get_functiondef('hr.get_review_bonuses(bigint[],jsonb)'::regprocedure)) <> 'f76c01ce1aff59ee2a78bd5d0af06669' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'hr.get_review_bonuses(bigint[],jsonb)'; END IF;
  EXECUTE d;
  -- derm_unlink_visit(bigint,bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION public.derm_unlink_visit(p_manifest_id bigint, p_visit_id bigint)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-20_1700 access phase 4: a DERM Tracker write that the browser made directly on the table, now behind
-- DERM Tracker's own checked action (Edit). SECURITY DEFINER widens nothing: authenticated already holds this
-- write with an unrestricted policy (measured 2026-10-20). Every table trigger still fires as before.
declare v_n integer;
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in public.derm_unlink_visit';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@ayache.com' and lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in public.derm_unlink_visit';
  end if;
  perform hr.fn_check_app('derm_tracker', 'edit', 'unlink a visit from a manifest');
  delete from public.manifest_visits where manifest_id = p_manifest_id and visit_id = p_visit_id;
  get diagnostics v_n = row_count;
  return v_n;
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '39bd40ac7cd824195826a31e12bcdfc6' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'derm_unlink_visit(bigint,bigint)'; END IF;
  IF md5(pg_get_functiondef('derm_unlink_visit(bigint,bigint)'::regprocedure)) <> '57ac4153c091d48384d5e938bc0cff19' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'derm_unlink_visit(bigint,bigint)'; END IF;
  EXECUTE d;
  -- client.get_property_activity(bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.get_property_activity(p_property_id bigint)
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
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'b528ac274d4ffb0c33bb2cd825042c76' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.get_property_activity(bigint)'; END IF;
  IF md5(pg_get_functiondef('client.get_property_activity(bigint)'::regprocedure)) <> '72e7d1834663ae7d3154a6d3614bcaee' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.get_property_activity(bigint)'; END IF;
  EXECUTE d;
  -- client.update_property_operational(bigint,jsonb)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.update_property_operational(p_property_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array[
    'zone_id','county','access_hours_start','access_hours_end','access_days',
    'access_notes','notes','grease_trap_manhole_count','sample_port_count',
    -- 2026-09-02. Lock Box/Key. Jobber holds this as an ALL_PROPERTIES text custom field
    -- (config 3061112) and it is mirrored into public.lock_box_key by the same shadow sync
    -- that carries the grease trap size. EDITABLE HERE ON PURPOSE (Fred, 2026-09-02), with
    -- the same consequence the capacity field already has: outbound push to Jobber does not
    -- exist, so an edit made here stays here until somebody edits it in Jobber, which then
    -- wins. That is a known, accepted divergence, not an oversight.
    'lock_box_key',
    -- RETIRED 2026-08-07 (Fred: "remove the Default disposal facility, we don't need that").
    -- Deliberately STILL ACCEPTED so a cached bundle that keeps sending the key is not
    -- refused mid-save; it is simply no longer WRITTEN (see the UPDATE list below).
    -- Measured before removing it: 0 of 856 properties ever carried a value.
    'default_disposal_facility_id',
    'access_schedule',  -- NEW 2026-07-30_2103: per-day windows
    'grease_trap_location'  -- NEW 2026-10-16_1530: Inside / Outside (Serena's indoor-trap list)
  ];
  -- The ONLY vocabulary public.properties.access_days uses (verified: 201 rows,
  -- 0 non-conforming). Long names are accepted as ALIASES and normalised down,
  -- so a stale client cannot introduce a second vocabulary.
  v_days     text[] := array['mon','tue','wed','thu','fri','sat','sun'];
  v_bad      text[];
  v_row      public.properties;
  v_in       text[];
  v_norm     text[];
  v_d        text;
  v_sched    jsonb;
  v_k        text;
  v_open     text;
  v_close    text;
begin
  if coalesce(current_setting('unclogme.intake_accept', true), '') = 'on' then   -- 2026-10-21_0620: reached through accept_intake_answers<<CR>>
    perform hr.fn_check_app('picture_planner', 'edit', 'edit property details');<<CR>>
  else<<CR>>
    perform hr.fn_check_app('client_app', 'edit', 'edit property details');<<CR>>
  end if;
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_property_id is null then
    raise exception 'p_property_id is required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for properties: %. Wave 1 allows only %. Address fields are Jobber-owned and geofence/lat/long are Samsara-owned; both would be reverted by the inbound sync.',
      v_bad, v_allowed using errcode = '22023';
  end if;

  if p_patch ? 'grease_trap_manhole_count'
     and nullif(p_patch->>'grease_trap_manhole_count','') is null then
    raise exception 'grease_trap_manhole_count cannot be null' using errcode = '22023';
  end if;

  -- ⚠ BUG 1 FIX. Type check first, then VALUE check. The old version stopped at
  -- the type check, which is how ["Monday","Tuesday"] was accepted.
  if p_patch ? 'access_days' then
    if jsonb_typeof(p_patch->'access_days') not in ('array','null') then
      raise exception 'access_days must be a JSON array of day codes (got %)',
        jsonb_typeof(p_patch->'access_days') using errcode = '22023';
    end if;
    if jsonb_typeof(p_patch->'access_days') = 'array' then
      select array_agg(x) into v_in from jsonb_array_elements_text(p_patch->'access_days') x;
      v_norm := array[]::text[];
      foreach v_d in array coalesce(v_in, array[]::text[]) loop
        -- ⚠ A JSON null becomes SQL NULL here, and `NULL <> all(v_days)` evaluates
        -- to NULL rather than true, so the check below would NOT fire and the NULL
        -- would land in the text[]. Caught by the fix's own test run. Reject first.
        if v_d is null then
          raise exception 'access_days cannot contain a null entry' using errcode = '22023';
        end if;
        v_d := lower(btrim(v_d));
        -- accept the long form as an alias, store the canonical short code
        v_d := case v_d
                 when 'monday' then 'mon' when 'tuesday'   then 'tue'
                 when 'wednesday' then 'wed' when 'thursday' then 'thu'
                 when 'friday' then 'fri' when 'saturday'  then 'sat'
                 when 'sunday' then 'sun' else v_d end;
        if v_d <> all (v_days) then
          raise exception 'access_days: % is not a valid day. Use %', v_d, v_days
            using errcode = '22023';
        end if;
        if v_d <> all (v_norm) then v_norm := v_norm || v_d; end if;  -- de-dup
      end loop;
    end if;
  end if;


  -- NEW: access_schedule validation. Object; keys in mon..sun; values
  -- {open:"HH:MM", close:"HH:MM"} 24h. Overnight open>close is legal (into the
  -- next morning), exactly like the legacy single window.
  if p_patch ? 'access_schedule' then
    if jsonb_typeof(p_patch->'access_schedule') = 'null' then
      v_sched := null;
    elsif jsonb_typeof(p_patch->'access_schedule') <> 'object' then
      raise exception 'access_schedule must be an object keyed by day (mon..sun)'
        using errcode = '22023';
    else
      v_sched := p_patch->'access_schedule';
      for v_k in select jsonb_object_keys(v_sched) loop
        if v_k <> all (v_days) then
          raise exception 'access_schedule: % is not a valid day key. Use %', v_k, v_days
            using errcode = '22023';
        end if;
        v_open  := v_sched->v_k->>'open';
        v_close := v_sched->v_k->>'close';
        if v_open is null or v_close is null
           or v_open  !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
           or v_close !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
          raise exception 'access_schedule.%: open/close must be 24h "HH:MM" strings', v_k
            using errcode = '22023';
        end if;
      end loop;
    end if;
  end if;

  -- A patch that carries the legacy access keys but NO access_schedule can no
  -- longer be honoured: there is nowhere to put it. Silently ignoring it would show
  -- the user "saved" while discarding the edit, so it raises. Only reachable from a
  -- browser tab cached from before access_schedule shipped (2026-07-30); the live
  -- Client App always sends all four keys together (verified in the published bundle).
  if (p_patch ? 'access_hours_start' or p_patch ? 'access_hours_end' or p_patch ? 'access_days')
     and not (p_patch ? 'access_schedule') then
    raise exception 'access hours are now set through access_schedule -- reload the app'
      using errcode = '22023';
  end if;

  -- 2026-10-16_1530, 1745. Inside / Outside / Inside and Outside or empty (stored NULL). Refused here in words; the column CHECK is the backstop.
  if p_patch ? 'grease_trap_location'
     and coalesce(nullif(btrim(p_patch->>'grease_trap_location'),''), 'Inside') not in ('Inside','Outside','Inside and Outside') then
    raise exception 'grease_trap_location must be Inside, Outside, Inside and Outside or empty' using errcode = '22023';
  end if;

  update public.properties p set
    zone_id = case when p_patch ? 'zone_id'
                   then nullif(p_patch->>'zone_id','')::bigint else p.zone_id end,
    county = case when p_patch ? 'county'
                  then nullif(nullif(btrim(p_patch->>'county'),''), 'None')
                  else p.county end,
    -- access_hours_start / access_hours_end / access_days were DROPPED by this
    -- migration. The keys remain ACCEPTED above (removing one makes this RPC refuse
    -- the whole patch, breaking every save from a cached bundle) and are now ignored;
    -- access_schedule is the single store. A legacy-ONLY patch is rejected loudly by
    -- the guard above rather than silently discarded.
    access_schedule = case when p_patch ? 'access_schedule' then v_sched
                           else p.access_schedule end,
    access_notes = case when p_patch ? 'access_notes'
                        then nullif(p_patch->>'access_notes','') else p.access_notes end,
    notes = case when p_patch ? 'notes'
                 then nullif(p_patch->>'notes','') else p.notes end,
    grease_trap_manhole_count = case when p_patch ? 'grease_trap_manhole_count'
                                     then (p_patch->>'grease_trap_manhole_count')::integer
                                     else p.grease_trap_manhole_count end,
    sample_port_count = case when p_patch ? 'sample_port_count'
                             then nullif(p_patch->>'sample_port_count','')::integer
                             else p.sample_port_count end,
    -- btrim then nullif: a field cleared to spaces in the UI stores NULL, not '   ',
    -- so "no lock box" has exactly one representation.
    lock_box_key = case when p_patch ? 'lock_box_key'
                        then nullif(btrim(p_patch->>'lock_box_key'),'')
                        else p.lock_box_key end,
    grease_trap_location = case when p_patch ? 'grease_trap_location'
                                then nullif(btrim(p_patch->>'grease_trap_location'),'')
                                else p.grease_trap_location end
  where p.id = p_property_id
  returning p.* into v_row;

  if not found then
    raise exception 'property % not found', p_property_id using errcode = 'P0002';
  end if;
  return to_jsonb(v_row);
end;
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'b73c8f580efe00d68b5ad3d549b7c783' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.update_property_operational(bigint,jsonb)'; END IF;
  IF md5(pg_get_functiondef('client.update_property_operational(bigint,jsonb)'::regprocedure)) <> '0a0ddfb36a728e48087f109078312b01' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.update_property_operational(bigint,jsonb)'; END IF;
  EXECUTE d;
  -- client.upsert_gdo_permit(bigint,bigint,jsonb)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.upsert_gdo_permit(p_gdo_id bigint, p_client_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array[
    'gdo_number','nickname','location_label','permit_expiration','max_frequency_days',
    'permit_document_path','status','notes','property_id','client_location_id'
  ];
  v_bad         text[];
  v_row         public.gdos;
  v_wanted      text;
  v_out         jsonb;
  v_old_status  text;
  v_old_notes   text;
  v_old_client  bigint;
  v_new_notes   text;
  v_marked      boolean;
  v_prop        bigint;
  v_freq        integer;
begin
  perform hr.fn_check_app('client_app', 'edit', 'save a GDO permit');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for gdos: %. Wave 1 allows only %',
      v_bad, v_allowed using errcode = '22023';
  end if;

  v_wanted := nullif(btrim(coalesce(p_patch->>'status','')),'');

  if p_patch ? 'gdo_number'
     and nullif(btrim(coalesce(p_patch->>'gdo_number','')),'') is null then
    raise exception 'gdo_number cannot be blank' using errcode = '22023';
  end if;
  if p_patch ? 'status' and v_wanted is null then
    raise exception 'status cannot be blank; expected ACTIVE, EXPIRED or INACTIVE'
      using errcode = '22023';
  end if;
  if v_wanted is not null and v_wanted <> all (array['ACTIVE','EXPIRED','INACTIVE']) then
    raise exception 'status must be one of ACTIVE, EXPIRED, INACTIVE (got %)', v_wanted
      using errcode = '22023';
  end if;
  if p_patch ? 'property_id'
     and nullif(btrim(coalesce(p_patch->>'property_id','')),'') is null then
    raise exception 'property_id cannot be blank; a permit is bound to a location'
      using errcode = '22023';
  end if;
  if p_patch ? 'permit_expiration'
     and nullif(p_patch->>'permit_expiration','') is not null
     and p_patch->>'permit_expiration' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'permit_expiration must be a bare date YYYY-MM-DD, never a timestamp (got %)',
      p_patch->>'permit_expiration' using errcode = '22023';
  end if;

  -- ⚠ BUG 3 FIX. Upper bound. This column drives customer.permits.over_gdo_max
  -- and `compliant`, which the Field Portal shows to the CLIENT, so an inflated
  -- ceiling silently reports a non-compliant site as compliant. Real values are
  -- 30/60/90; 365 is a generous ceiling that still catches 900-for-90.
  if p_patch ? 'max_frequency_days' then
    v_freq := nullif(btrim(coalesce(p_patch->>'max_frequency_days','')),'')::integer;
    if v_freq is not null and (v_freq < 1 or v_freq > 365) then
      raise exception 'max_frequency_days must be between 1 and 365 days (got %). This is the DERM permit ceiling; typical values are 30, 60 or 90.',
        v_freq using errcode = '22023';
    end if;
  end if;

  v_prop := nullif(btrim(coalesce(p_patch->>'property_id','')),'')::bigint;

  if p_gdo_id is null then
    -- ---- ADD ----
    if p_client_id is null then
      raise exception 'p_client_id is required when creating a permit' using errcode = '22023';
    end if;
    if nullif(btrim(coalesce(p_patch->>'gdo_number','')),'') is null then
      raise exception 'gdo_number is required when creating a permit' using errcode = '22023';
    end if;
    if v_prop is null then
      raise exception 'property_id is required when creating a permit (a GDO is issued to a location, not a business)'
        using errcode = '22023';
    end if;
    -- 2026-09-22, Fred: "we cannot have a GDO number without having the GDO file."
    if nullif(btrim(coalesce(p_patch->>'permit_document_path','')),'') is null then
      raise exception 'Attach the permit document before saving. A GDO number cannot be recorded without its permit file.'
        using errcode = '22023';
    end if;
    if not exists (select 1 from public.properties pr
                   where pr.id = v_prop and pr.client_id = p_client_id) then
      raise exception 'property % does not belong to client %', v_prop, p_client_id
        using errcode = '23503';
    end if;
    -- Readable duplicate message. The bare 23505 from gdos_client_gdo_unique was
    -- being rendered verbatim to the user, and it is highly reachable in the
    -- PDF-first flow because re-uploading a permit the client already holds hits it.
    if exists (select 1 from public.gdos g
               where g.client_id = p_client_id
                 and g.gdo_number = btrim(p_patch->>'gdo_number')) then
      raise exception 'This client already has permit %. Edit the existing permit instead of adding it again.',
        btrim(p_patch->>'gdo_number') using errcode = '23505';
    end if;

    insert into public.gdos (
      client_id, gdo_number, nickname, location_label, permit_expiration,
      max_frequency_days, permit_document_path, status, notes, property_id, client_location_id
    ) values (
      p_client_id,
      btrim(p_patch->>'gdo_number'),
      nullif(p_patch->>'nickname',''),
      nullif(p_patch->>'location_label',''),
      nullif(p_patch->>'permit_expiration','')::date,
      v_freq,
      nullif(p_patch->>'permit_document_path',''),
      coalesce(v_wanted, 'ACTIVE'),
      nullif(p_patch->>'notes',''),
      v_prop,
      nullif(p_patch->>'client_location_id','')::bigint
    )
    returning * into v_row;
  else
    -- ---- EDIT ----
    select g.status, g.notes, g.client_id
      into v_old_status, v_old_notes, v_old_client
    from public.gdos g where g.id = p_gdo_id for update;
    if not found then
      raise exception 'gdo % not found', p_gdo_id using errcode = 'P0002';
    end if;
    if p_client_id is not null and p_client_id <> v_old_client then
      raise exception 'p_client_id % does not match this permit''s client %', p_client_id, v_old_client
        using errcode = '22023';
    end if;
    if v_prop is not null and not exists (
         select 1 from public.properties pr where pr.id = v_prop and pr.client_id = v_old_client) then
      raise exception 'property % does not belong to client %', v_prop, v_old_client
        using errcode = '23503';
    end if;
    if p_patch ? 'gdo_number' and exists (
         select 1 from public.gdos g
         where g.client_id = v_old_client
           and g.gdo_number = btrim(p_patch->>'gdo_number')
           and g.id <> p_gdo_id) then
      raise exception 'This client already has permit %. Two permits for one client cannot share a number.',
        btrim(p_patch->>'gdo_number') using errcode = '23505';
    end if;

    -- ⚠⚠ BUG 2 FIX — ONE RULE THAT CLOSES ALL THREE BYPASSES.
    -- On a row whose notes carry DEMOTED/DEDUP evidence:
    --   (i)  notes are APPEND-ONLY  -> closes route B (notes-only disarm) and
    --        route C (5-char "DEDUP" replacing 431 chars of evidence), because
    --        containment of the old text is what the error message already promises;
    --   (ii) any transition TO ACTIVE needs a real append, REGARDLESS of the
    --        current status -> closes route A (INACTIVE->EXPIRED->ACTIVE), which
    --        mattered most because parse-gdo-permit derives EXPIRED for a lapsed
    --        permit and so performed hop 1 automatically.
    v_marked := coalesce(v_old_notes,'') ~* '(DEMOTED|DEDUP)';
    if v_marked then
      v_new_notes := case when p_patch ? 'notes'
                          then nullif(btrim(coalesce(p_patch->>'notes','')),'') end;

      if p_patch ? 'notes' and position(btrim(coalesce(v_old_notes,'')) in coalesce(v_new_notes,'')) = 0 then
        raise exception 'This permit was demoted with recorded evidence, so its notes are append-only. Keep the existing text and add your reason at the end. (The evidence is what stops a wrong permit being silently reactivated.)'
          using errcode = '22023';
      end if;

      if v_wanted = 'ACTIVE' then
        if v_new_notes is null or btrim(coalesce(v_old_notes,'')) = v_new_notes then
          raise exception 'Permit % was demoted with recorded evidence. To reactivate it deliberately, keep the existing notes and append your reason in the same save.',
            p_gdo_id using errcode = '22023';
        end if;
      end if;
    end if;

    update public.gdos g set
      gdo_number = case when p_patch ? 'gdo_number'
                        then btrim(p_patch->>'gdo_number') else g.gdo_number end,
      nickname = case when p_patch ? 'nickname'
                      then nullif(p_patch->>'nickname','') else g.nickname end,
      location_label = case when p_patch ? 'location_label'
                            then nullif(p_patch->>'location_label','') else g.location_label end,
      permit_expiration = case when p_patch ? 'permit_expiration'
                               then nullif(p_patch->>'permit_expiration','')::date
                               else g.permit_expiration end,
      max_frequency_days = case when p_patch ? 'max_frequency_days'
                                then v_freq else g.max_frequency_days end,
      permit_document_path = case when p_patch ? 'permit_document_path'
                                  then nullif(p_patch->>'permit_document_path','')
                                  else g.permit_document_path end,
      status = case when p_patch ? 'status'
                    then v_wanted else g.status end,
      notes = case when p_patch ? 'notes'
                   then nullif(p_patch->>'notes','') else g.notes end,
      property_id = case when p_patch ? 'property_id'
                         then v_prop else g.property_id end,
      client_location_id = case when p_patch ? 'client_location_id'
                                then nullif(p_patch->>'client_location_id','')::bigint
                                else g.client_location_id end
    where g.id = p_gdo_id
    returning g.* into v_row;

    -- The warn-only DB trigger can still rewrite NEW.status; report that honestly
    -- rather than claiming a success the row does not reflect.
    if v_wanted is not null and v_row.status <> v_wanted then
      v_out := to_jsonb(v_row) || jsonb_build_object(
        'status_change_refused', true,
        'requested_status', v_wanted,
        'message', 'A database guard refused this status change because the permit was demoted with recorded evidence.');
      return v_out;
    end if;
  end if;

  return to_jsonb(v_row);
end;
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'c049407fdc52ef3c598eeb15b46ca76e' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.upsert_gdo_permit(bigint,bigint,jsonb)'; END IF;
  IF md5(pg_get_functiondef('client.upsert_gdo_permit(bigint,bigint,jsonb)'::regprocedure)) <> 'af1cca9b28b89453e2705d4da81f133b' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.upsert_gdo_permit(bigint,bigint,jsonb)'; END IF;
  EXECUTE d;
  -- client.create_client_contact(bigint,jsonb)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.create_client_contact(p_client_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed  text[] := array['property_id','first_name','last_name','contact_role','email','phone'];
  v_roles    text[] := array['primary','accounting'];
  v_bad      text[];
  v_first    text;
  v_last     text;
  v_role     text;
  v_email    text;
  v_phone    text;
  v_prop     bigint;
  v_name     text;
  v_row      public.client_contacts;
begin
  perform hr.fn_check_app('client_app', 'edit', 'add a contact');   -- 2026-10-21_0900 access phase 5
  -- Identity, then staff domain. The ROLE is not the identity: an `authenticated`
  -- token with no `sub` claim would otherwise pass. Mirrors public.set_visit_status.
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;

  if p_client_id is null then
    raise exception 'p_client_id is required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for a contact: %. Allowed: %',
      v_bad, v_allowed using errcode = '22023';
  end if;

  if not exists (select 1 from public.clients c where c.id = p_client_id) then
    raise exception 'client % does not exist', p_client_id using errcode = '23503';
  end if;

  v_first := nullif(btrim(coalesce(p_patch->>'first_name','')), '');
  v_last  := nullif(btrim(coalesce(p_patch->>'last_name','')),  '');
  v_email := nullif(btrim(coalesce(p_patch->>'email','')),      '');
  v_phone := nullif(btrim(coalesce(p_patch->>'phone','')),      '');
  v_role  := lower(nullif(btrim(coalesce(p_patch->>'contact_role','')), ''));

  -- Guarded cast: a bare ::bigint on junk raises 22P02 ("invalid input syntax for
  -- type bigint"), which surfaces in the UI as an unreadable Postgres string. The
  -- error mapper only passes through the codes it knows, so give it a 22023.
  declare v_prop_txt text := nullif(btrim(coalesce(p_patch->>'property_id','')), '');
  begin
    if v_prop_txt is not null then
      if v_prop_txt !~ '^[0-9]+$' then
        raise exception 'property_id must be a positive integer, got %', v_prop_txt
          using errcode = '22023';
      end if;
      v_prop := v_prop_txt::bigint;
    end if;
  end;

  -- Fred's required set: Name, Property, and either Phone or Email.
  if v_first is null then
    raise exception 'First name is required.' using errcode = '22023';
  end if;
  if v_prop is null then
    raise exception 'A property must be selected for the contact.' using errcode = '22023';
  end if;
  if v_email is null and v_phone is null then
    raise exception 'Enter at least a phone number or an email address.'
      using errcode = '22023';
  end if;

  -- The property must belong to THIS client. Without this check the RPC would happily
  -- attach a contact to another client's property -- the same cross-client hole the
  -- wave-1 review caught on gdos.property_id.
  if not exists (select 1 from public.properties p
                 where p.id = v_prop and p.client_id = p_client_id) then
    raise exception 'Property % does not belong to client %', v_prop, p_client_id
      using errcode = '22023';
  end if;

  -- contact_role is NOT NULL on the table; default to the app's own default.
  v_role := coalesce(v_role, 'primary');
  if v_role <> all (v_roles) then
    if v_role = 'city' then
      raise exception 'The City role has been retired. City email addresses now live on the location itself, under City email.'
        using errcode = '22023',
              detail  = 'blocker=contact_role_city_retired value=city';
    end if;
    raise exception 'Pick a role for this contact: Main contact, or Accounting.'
      using errcode = '22023',
            detail  = 'blocker=contact_role_unknown value=' || coalesce(v_role, '(null)');
  end if;

  if v_email is not null and v_email not like '%_@_%.__%' then
    raise exception '% is not a valid email address.', v_email using errcode = '22023';
  end if;

  -- `name` stays the display value every existing reader already uses
  -- (send-derm-email, the app list). Composed here, never stored redundantly split.
  v_name := btrim(concat_ws(' ', v_first, v_last));

  begin
    insert into public.client_contacts
      (client_id, property_id, contact_role, name, first_name, last_name, email, phone)
    values
      (p_client_id, v_prop, v_role, v_name, v_first, v_last, v_email, v_phone)
    returning * into v_row;
  exception when unique_violation then
    raise exception 'This property already has a % contact. Edit that contact instead of adding a second one.',
      v_role using errcode = '23505';
  end;

  return to_jsonb(v_row);
end
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '1ab778dfaaa21f87ce60d66548925556' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.create_client_contact(bigint,jsonb)'; END IF;
  IF md5(pg_get_functiondef('client.create_client_contact(bigint,jsonb)'::regprocedure)) <> 'be32c51a158ef7e9e7e312667a9f86a3' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.create_client_contact(bigint,jsonb)'; END IF;
  EXECUTE d;
  -- client.accept_intake_answers(bigint,text[],jsonb)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.accept_intake_answers(p_intake_id bigint, p_keys text[], p_expected jsonb)
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
    -- 2026-10-23: several grease traps. Their offer is the TOTAL or nothing; never fall back to the trap 1 answer.
    if v_offer ? 'traps' and jsonb_typeof(v_offer -> 'gallons') is distinct from 'number' then
      raise exception 'Not every grease trap has its gallons yet, so the total cannot be saved. Type it on the property by hand.'
        using errcode = '22023', detail = 'blocker=traps_incomplete in client.accept_intake_answers: ' || v_key;
    end if;
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
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'a72a08a0d2bb168b93a72c0137b2af9f' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.accept_intake_answers(bigint,text[],jsonb)'; END IF;
  IF md5(pg_get_functiondef('client.accept_intake_answers(bigint,text[],jsonb)'::regprocedure)) <> 'd867976bd432b742b718ce3c8df45898' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.accept_intake_answers(bigint,text[],jsonb)'; END IF;
  EXECUTE d;
  -- client.update_client_status(bigint,text,text)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.update_client_status(p_client_id bigint, p_status text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_old    text;
  v_row    public.clients;
  v_before int;
  v_after  int;
  v_removed int;
  v_email  text;
  v_change_id bigint;   -- 2026-09-16: the ledger row, so the app can attach reason photos to it
begin
  perform hr.fn_check_app('client_app', 'edit', 'change client status');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email',''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  -- PAUSED added 2026-07-31 (Fred). All four states are now settable.
  if p_status is null or p_status not in ('ACTIVE','RECURRING','INACTIVE','PAUSED') then
    raise exception 'status must be ACTIVE, RECURRING, INACTIVE or PAUSED (got %)', p_status
      using errcode = '22023';
  end if;
  -- The proof is the point: no reason, no change.
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a reason is required when changing a client''s status'
      using errcode = '22023';
  end if;
  if length(btrim(p_reason)) > 500 then
    raise exception 'reason is too long (500 characters max)' using errcode = '22023';
  end if;

  -- 2026-09-18: a client deleted in the Jobber UI has no Jobber record to serve it; it stays as
  -- history and only ever moves to INACTIVE. Create the client again instead (a new GID, a new row).
  if p_status <> 'INACTIVE' and exists (
       select 1 from public.client_status_changes s
        where s.client_id = p_client_id and s.event = 'deleted_in_jobber') then
    raise exception 'This client was deleted in Jobber, so it cannot be reactivated here. Create the client again instead; this record stays as history.'
      using errcode = '22023', detail = 'blocker=deleted_in_jobber client_id=' || p_client_id;
  end if;

  select c.status into v_old from public.clients c where c.id = p_client_id;
  if v_old is null then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;
  if v_old = p_status then
    select c.* into v_row from public.clients c where c.id = p_client_id;
    return jsonb_build_object('client', to_jsonb(v_row), 'visits_removed', 0, 'noop', true, 'status_change_id', null);
  end if;

  -- ▼▼▼ ADDED 2026-08-01 — THE ONLY CHANGE ▼▼▼
  -- RECURRING requires a current-format SA job that can actually generate
  -- visits. Without one the client sits in RECURRING forever with an empty
  -- schedule and nothing reports it. Checked AFTER the no-op branch so that
  -- re-saving an already-RECURRING client can never be blocked by it.
  if p_status = 'RECURRING' then
    if not exists (
      select 1 from public.jobs j
      where j.client_id = p_client_id
        and j.job_status NOT IN ('archived', 'destroyed')
        and client.fn_is_current_sa_job(j.id)
    ) then
      raise exception
        'cannot set RECURRING: this client has no open Service Agreement job in the current format. Create one, or reopen a closed current-format agreement first.'
        using errcode = '23514';
    end if;
  end if;
  -- ▲▲▲ END OF ADDED BLOCK ▲▲▲

  select count(*) into v_before
    from public.visits v
   where v.client_id = p_client_id and v.deleted_at is null
     and v.visit_status = 'scheduled' and v.visit_date >= current_date;

  update public.clients c set status = p_status, status_source = 'manual'
   where c.id = p_client_id
  returning c.* into v_row;          -- AFTER trigger performs the SA cleanup

  select count(*) into v_after
    from public.visits v
   where v.client_id = p_client_id and v.deleted_at is null
     and v.visit_status = 'scheduled' and v.visit_date >= current_date;
  v_removed := greatest(v_before - v_after, 0);

  insert into public.client_status_changes
    (client_id, old_status, new_status, reason, changed_by, changed_by_email, visits_removed)
  values (p_client_id, v_old, p_status, btrim(p_reason), auth.uid(), v_email, v_removed)
  returning id into v_change_id;

  return jsonb_build_object(
    'client', to_jsonb(v_row),
    'previous_status', v_old,
    'visits_removed', v_removed,
    'status_change_id', v_change_id,
    'note', case when p_status = 'RECURRING'
                 then 'SA visits are generated by the nightly run at 06:00 ET, not on save.'
                 else null end);
end;
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '7821e887a36119cdad6ed4622cbc9535' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.update_client_status(bigint,text,text)'; END IF;
  IF md5(pg_get_functiondef('client.update_client_status(bigint,text,text)'::regprocedure)) <> 'a63e8edda289611f3ca24be7154b7d5d' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.update_client_status(bigint,text,text)'; END IF;
  EXECUTE d;
  -- client.save_contact_settings(text,bigint,jsonb)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.save_contact_settings(p_source text, p_contact_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array['person_role','person_role_other','communication'];
  v_types   text[] := array['invoice','quote_approval','service_report','city_report'];
  v_bad text[]; v_client bigint; v_email text; v_label text; v_deleted timestamptz;
  v_role text; v_other text; v_comm jsonb; v_item jsonb; v_t text;
  v_prop bigint; v_prop_txt text; v_holder text; v_out jsonb;
begin
  perform hr.fn_check_app('client_app', 'edit', 'change contact settings');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_source is null or p_source <> all (array['ours','jobber']) then
    raise exception 'p_source must be ''ours'' or ''jobber''.' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object.' using errcode = '22023';
  end if;
  select array_agg(k) into v_bad from jsonb_object_keys(p_patch) k where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s): %. Allowed: %', v_bad, v_allowed using errcode = '22023';
  end if;

  if p_source = 'ours' then
    select cc.client_id, cc.email,
           coalesce(nullif(btrim(concat_ws(' ', cc.first_name, cc.last_name)),''), cc.name, 'This contact'),
           cc.person_role, cc.person_role_other
      into v_client, v_email, v_label, v_role, v_other
      from public.client_contacts cc where cc.id = p_contact_id;
  else
    select jc.client_id, jc.email,
           coalesce(nullif(btrim(jc.name),''),
                    nullif(btrim(concat_ws(' ', jc.first_name, jc.last_name)),''), 'This contact'),
           jc.person_role, jc.person_role_other, jc.deleted_at
      into v_client, v_email, v_label, v_role, v_other, v_deleted
      from public.client_jobber_contacts jc where jc.id = p_contact_id;
  end if;
  if v_client is null then
    raise exception 'That contact no longer exists.'
      using errcode = 'P0002', detail = 'blocker=contact_not_found id=' || p_contact_id;
  end if;
  if v_deleted is not null then
    raise exception '% has been removed in Jobber, so its settings cannot be changed here.', v_label
      using errcode = '22023', detail = 'blocker=jobber_contact_removed id=' || p_contact_id;
  end if;

  ---- role ------------------------------------------------------------------------------
  if p_patch ? 'person_role' then
    v_role := lower(nullif(btrim(coalesce(p_patch->>'person_role','')),''));
  end if;
  if p_patch ? 'person_role_other' then
    v_other := nullif(btrim(coalesce(p_patch->>'person_role_other','')),'');
  end if;
  if v_role is not null and v_role <> all (array['store_manager','accounting','owner','other']) then
    raise exception 'Unknown role "%".', v_role
      using errcode = '22023', detail = 'blocker=person_role_unknown value=' || coalesce(v_role,'(null)');
  end if;
  if v_role = 'other' and v_other is null then
    raise exception 'Say what the role is, or pick one from the list.'
      using errcode = '22023', detail = 'blocker=person_role_other_blank';
  end if;
  if v_role is distinct from 'other' then v_other := null; end if;   -- never keep stale free text

  if p_patch ? 'person_role' or p_patch ? 'person_role_other' then
    if p_source = 'ours' then
      update public.client_contacts
         set person_role = v_role, person_role_other = v_other where id = p_contact_id;
    else
      update public.client_jobber_contacts
         set person_role = v_role, person_role_other = v_other where id = p_contact_id;
    end if;
  end if;

  ---- communication ---------------------------------------------------------------------
  if p_patch ? 'communication' then
    v_comm := p_patch->'communication';
    if jsonb_typeof(v_comm) <> 'array' then
      raise exception 'communication must be a list.' using errcode = '22023';
    end if;

    -- replace-the-set: unticking is a delete that leaves no row behind
    delete from public.client_communication_prefs
     where (p_source = 'ours'   and contact_id        = p_contact_id)
        or (p_source = 'jobber' and jobber_contact_id = p_contact_id);

    -- 🛑 AN EMPTY EMAIL CLEARS THE SET, IT DOES NOT RAISE. The modal lets you remove an address
    -- from a contact that holds boxes, and warns that the boxes go with it. If this raised, that
    -- save would be impossible and the warning would be a lie. So the guard sits AFTER the
    -- delete and only fires when something is being TICKED.
    if coalesce(btrim(v_email),'') = '' and jsonb_array_length(v_comm) > 0 then
      raise exception '% has no email address, so it cannot be set to receive anything. Add an email first.', v_label
        using errcode = '22023', detail = 'blocker=contact_has_no_email id=' || p_contact_id;
    end if;

    for v_item in select * from jsonb_array_elements(v_comm) loop
      v_t := lower(nullif(btrim(coalesce(v_item->>'type','')),''));
      if v_t is null or v_t <> all (v_types) then
        raise exception 'Unknown communication type "%".', coalesce(v_t,'')
          using errcode = '22023', detail = 'blocker=communication_type_unknown value=' || coalesce(v_t,'(null)');
      end if;
      -- 🛑 the comma-bag guard, in the DATABASE and not only in the UI. Rows holding several
      -- addresses in one field exist; Resend would send to a single malformed address and
      -- report success.
      if v_email like '%,%' then
        raise exception '% holds several addresses in one field ("%"). Split them into separate contacts before ticking anything.', v_label, v_email
          using errcode = '22023', detail = 'blocker=contact_email_is_a_list id=' || p_contact_id;
      end if;

      v_prop_txt := nullif(btrim(coalesce(v_item->>'property_id','')),'');
      if v_prop_txt is not null then
        if v_prop_txt !~ '^[0-9]+$' then   -- a bare ::bigint on junk raises an unreadable 22P02
          raise exception 'property_id must be a positive integer, got %', v_prop_txt using errcode = '22023';
        end if;
        v_prop := v_prop_txt::bigint;
      else
        v_prop := null;
      end if;

      if v_t = 'city_report' then
        if v_prop is null then
          raise exception 'City report is set per location. Pick which location % is told about.', v_label
            using errcode = '22023', detail = 'blocker=city_report_needs_location';
        end if;
        if not exists (select 1 from public.properties p
                        where p.id = v_prop and p.client_id = v_client and p.deleted_at is null) then
          raise exception 'That location does not belong to this client.'
            using errcode = '22023', detail = 'blocker=location_not_on_this_client property_id=' || v_prop;
        end if;
      elsif v_prop is not null then
        raise exception 'That communication covers the whole client, not one location.'
          using errcode = '22023', detail = 'blocker=communication_is_client_wide type=' || coalesce(v_t,'(null)');
      end if;

      -- ✅ TAKE-OVER RETIRED 2026-09-23. All four communications are now MULTI-HOLDER, so
      -- ticking one on a second person no longer deletes it from the first. The two DELETEs that
      -- used to sit here (invoice client-wide, city_report per property) were the real enforcement;
      -- the two partial unique indexes dropped in this migration were only the backstop, and
      -- dropping those ALONE would have looked fixed while still silently overwriting.
      -- Why: Jobber's defaultEmails(INVOICE_SENT) is an ARRAY and already holds more than one
      -- address on real clients (measured: of 34 read, 25 hold one, 8 hold two, 1 holds three -
      -- accounts@ + admin@, gaston@ + invoices@, and so on). An invoice genuinely goes to several
      -- people, so a record that can name only one could not express the truth, and the take-over
      -- destroyed the first name while trying. City report is a CC on an email WE send, and
      -- send-derm-email already resolves it into a de-duplicated Set - it was built for many all
      -- along. service_report and quote_approval were already multi-holder and are unchanged.

      begin
        insert into public.client_communication_prefs
          (client_id, comm_type, contact_id, jobber_contact_id, property_id)
        values (v_client, v_t,
                case when p_source = 'ours'   then p_contact_id end,
                case when p_source = 'jobber' then p_contact_id end,
                v_prop);
      exception when unique_violation then
        -- 🛑 name the holder. A raw 23505 in front of a person is the error this catch exists
        -- to stop, and the sentence is the operator-message rule: plain language in MESSAGE.
        select coalesce(
          (select coalesce(nullif(btrim(concat_ws(' ', c2.first_name, c2.last_name)),''), c2.name)
             from public.client_communication_prefs q
             join public.client_contacts c2 on c2.id = q.contact_id
            where q.client_id = v_client and q.comm_type = v_t
              and (v_t <> 'city_report' or q.property_id = v_prop)),
          (select coalesce(nullif(btrim(j2.name),''),
                           nullif(btrim(concat_ws(' ', j2.first_name, j2.last_name)),''))
             from public.client_communication_prefs q
             join public.client_jobber_contacts j2 on j2.id = q.jobber_contact_id
            where q.client_id = v_client and q.comm_type = v_t
              and (v_t <> 'city_report' or q.property_id = v_prop)),
          'Another contact') into v_holder;
        if v_t = 'invoice' then
          -- 🛑 OUR RULE, NOT JOBBER'S. Never "receives", never "only one person can receive".
          raise exception 'Only one contact can be marked as the invoice contact, and % already is. Untick it there first.', v_holder
            using errcode = '23505', detail = 'blocker=invoice_already_held';
        elsif v_t = 'city_report' then
          raise exception 'Only one contact is told per location when we email the city, and % already is for this location. Untick it there first.', v_holder
            using errcode = '23505', detail = 'blocker=city_report_already_held';
        else
          raise exception '% already has that ticked.', v_holder
          using errcode = '23505', detail = 'blocker=duplicate_in_one_submission type=' || coalesce(v_t,'(null)');
        end if;
      end;
    end loop;
  end if;

  if p_source = 'ours' then
    select to_jsonb(v) into v_out from client.client_contacts v where v.id = p_contact_id;
  else
    select to_jsonb(v) into v_out from client.jobber_contacts  v where v.id = p_contact_id;
  end if;
  return v_out;
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '74ae15a2387d6d7d2da7f176ff6a5e27' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.save_contact_settings(text,bigint,jsonb)'; END IF;
  IF md5(pg_get_functiondef('client.save_contact_settings(text,bigint,jsonb)'::regprocedure)) <> 'bafae1ec02cde85a52b1ed7e71a29501' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.save_contact_settings(text,bigint,jsonb)'; END IF;
  EXECUTE d;
  -- derm_delete_manifests(bigint[])
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION public.derm_delete_manifests(p_manifest_ids bigint[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-20_1700 access phase 4: a DERM Tracker write that the browser made directly on the table, now behind
-- DERM Tracker's own checked action (Edit). SECURITY DEFINER widens nothing: authenticated already holds this
-- write with an unrestricted policy (measured 2026-10-20). Every table trigger still fires as before.
declare v_n integer;
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in public.derm_delete_manifests';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@ayache.com' and lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in public.derm_delete_manifests';
  end if;
  perform hr.fn_check_app('derm_tracker', 'edit', 'delete a manifest');
  update public.derm_manifests set deleted_at = now() where id = any (coalesce(p_manifest_ids, '{}'::bigint[]));
  get diagnostics v_n = row_count;
  return v_n;
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'a4d896cff104ccfe8eaa2f96e511b947' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'derm_delete_manifests(bigint[])'; END IF;
  IF md5(pg_get_functiondef('derm_delete_manifests(bigint[])'::regprocedure)) <> '80df507b5b7af25962cbcfff024856a3' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'derm_delete_manifests(bigint[])'; END IF;
  EXECUTE d;
  -- client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.submit_property_page(p_property_id bigint, p_content jsonb, p_expected_version integer, p_expected_map_rev integer, p_expected_source jsonb, p_restored_from_version integer DEFAULT NULL::integer)
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
  perform hr.fn_check_app('picture_planner', 'edit', 'submit a site file');   -- 2026-10-20_1600 access phase 3
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
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '0d07ff9a86420c2cee6c3e6af03cc222' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)'; END IF;
  IF md5(pg_get_functiondef('client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)'::regprocedure)) <> '642e703ba0d020532b97e428f88dab14' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)'; END IF;
  EXECUTE d;
  -- client.fn_reason_photo_path_ok(text)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.fn_reason_photo_path_ok(p_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_m     text[];
  v_email text;
begin
  if auth.uid() is null then return false; end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then return false; end if;
  -- client-app/<entity_type>/<entity_id>/<uuid>.<jpg|jpeg|png|webp>
  v_m := regexp_match(p_name,
    '^client-app/([a-z_]+)/([0-9]{1,18})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})[.](jpg|jpeg|png|webp)$');
  if v_m is null then return false; end if;
  return client.fn_reason_photo_target_exists(v_m[1], v_m[2]::bigint);
end;
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '2486c77e2793494b460a456661e413d6' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.fn_reason_photo_path_ok(text)'; END IF;
  IF md5(pg_get_functiondef('client.fn_reason_photo_path_ok(text)'::regprocedure)) <> '60a172cf31b58c42e3d7f41d9d012916' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.fn_reason_photo_path_ok(text)'; END IF;
  EXECUTE d;
  -- client.get_client_activity(bigint,boolean,integer,jsonb)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.get_client_activity(p_client_id bigint, p_include_system boolean DEFAULT false, p_limit integer DEFAULT NULL::integer, p_cursor jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(key text, at timestamp with time zone, area text, area_label text, subject text, title text, actor_label text, actor_kind text, is_system boolean, changes jsonb, status_card jsonb, cadence_card jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_cid   text := p_client_id::text;
  v_inc   boolean := coalesce(p_include_system, false);
begin
  perform hr.fn_require_app('client_app', 'view');   -- 2026-10-21_0900 access phase 5
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_client_activity';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_client_activity';
  end if;
  if p_client_id is null then
    raise exception 'No client was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_client in client.get_client_activity';
  end if;

  return query
  with
  -- every job the client has or had, so line items of a deleted or moved job still count
  job_ids as (
    select j.id::text as id from public.jobs j where j.client_id = p_client_id
    union
    select l.record_pk ->> 'id' from audit.logs l
     where l.table_schema = 'public' and l.table_name = 'jobs'
       and (l.new_row ->> 'client_id' = v_cid or l.old_row ->> 'client_id' = v_cid)
  ),
  cfg as (
    select c.table_name, c.column_name,
           -- the Calendar's clients labels stay as they are for get_record_history; this reader says it in full
           case when c.table_name = 'clients' and c.column_name = 'client_code' then 'Client code' else c.label end,
           case when c.table_name = 'visits' and c.column_name = 'visit_status' then 'enum' else c.render_type end,
           c.fk_table, c.fk_label_col, c.sort_order, c.is_system
      from audit.entity_render_config c
     -- visits since 2026-10-15 (Fred: "I said to not put the Visits there in the history because each app has their own
     -- activity history, but add it"): the Calendar's visit fields, the Calendar's own labels
     where c.table_name in ('clients','properties','jobs','gdos','client_contacts','client_jobber_contacts',
                            'client_locations','invoices','line_items','visits')
    union all
    -- rendered by the function, never a config row: get_record_history('clients') renders every clients row
    select 'clients', 'primary_contact_ref', 'Primary contact', 'contact_ref', null, null, 70, false
  ),
  -- 1. the audit rows of this client. An explicit table list: never "every row with a client_id".
  --    Every arm stays on this client's rows; nothing below joins back to all of audit.logs.
  raw as (
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public' and l.table_name = 'clients' and l.record_pk ->> 'id' = v_cid
    union all
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public'
       and l.table_name in ('properties','jobs','gdos','client_contacts','client_jobber_contacts','client_locations',
                            'client_communication_prefs','invoices')
       and (l.new_row ->> 'client_id' = v_cid or l.old_row ->> 'client_id' = v_cid)
    union all
    -- visits by id (logs_table_record_changed_idx): a client_id filter over every visit row costs a full scan
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public' and l.table_name = 'visits'
       and l.record_pk ->> 'id' in (select vi.id::text from public.visits vi where vi.client_id = p_client_id)
       and coalesce(l.new_row, l.old_row) ->> 'client_id' = v_cid
    union all
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public' and l.table_name in ('client_status_changes','job_frequency_changes')
       and l.operation = 'INSERT' and l.new_row ->> 'client_id' = v_cid
    union all
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public' and l.table_name = 'line_items'
       and coalesce(l.new_row, l.old_row) ->> 'job_id' in (select ji.id from job_ids ji)
       and coalesce(l.new_row, l.old_row) ->> 'visit_id' is null
       and coalesce(l.new_row, l.old_row) ->> 'invoice_id' is null
    union all
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public' and l.table_name = 'property_intake_accepts' and l.operation = 'INSERT'
       and l.new_row ->> 'property_id' in (select pr.id::text from public.properties pr where pr.client_id = p_client_id)
  ),
  -- the Client App creation ledger (not audited): matched by client_id, or by the Jobber gid when client_id is empty
  creation as (
    select a.requested_by from public.client_create_attempts a
     where a.status = 'created'
       and (a.client_id = p_client_id
            or (a.client_id is null and exists (
                  select 1 from public.entity_source_links e
                   where e.entity_type = 'client' and e.source_system = 'jobber'
                     and e.entity_id = p_client_id and e.source_id = a.jobber_client_gid)))
     order by a.created_at limit 1
  ),
  src as (
    select r.id, r.table_name as tbl, r.operation as op, r.old_row as o, r.new_row as n,
           coalesce(r.new_row, r.old_row) as rec, r.changed_at as at, coalesce(r.txid, -r.id) as tx,
           coalesce(r.app_source, '') as app, r.request_context ->> 'path' as path,
           -- who: the JWT email; the intent row's email; actor_name only behind service_role (a free header otherwise);
           -- the creation ledger's requester for the client INSERT
           coalesce(
             nullif(btrim(r.jwt_claims ->> 'email'), ''),
             case when r.table_name in ('client_status_changes','job_frequency_changes') then nullif(btrim(r.new_row ->> 'changed_by_email'), '')
                  when r.table_name = 'property_intake_accepts' then nullif(btrim(r.new_row ->> 'actor'), '') end,
             case when r.jwt_claims ->> 'role' = 'service_role' and coalesce(r.app_source, '') <> 'jobber'
                  then nullif(btrim(r.request_context ->> 'actor_name'), '') end,
             case when r.table_name = 'clients' and r.operation = 'INSERT' then (select cr.requested_by from creation cr) end
           ) as person,
           case when r.app_source = 'jobber' then nullif(btrim(r.request_context ->> 'actor_name'), '') end as jobber_name,
           coalesce(r.app_source, '') in ('jobber','jobber-custom-field-sync') as is_jobber,
           coalesce(r.app_source, '') ~ '(backfill|import|probe|migration|revert|uitest|smoke)' as is_script,
           (coalesce(r.app_source, '') in ('','sql') and r.request_context ->> 'path' is null) as is_direct_sql
      from raw r
  ),
  -- 2. replace-style saves cancel (rule 3.3.1): a DELETE and an INSERT of equal rows, minus id / created_at /
  --    updated_at (and total_price on line items), paired one to one inside a transaction
  di as (
    select s.id, s.tbl, s.op, s.tx, s.at, s.person, s.rec ->> 'job_id' as job_key,
           s.rec - array['id','created_at','updated_at','total_price']::text[] as body
      from src s
     where s.op in ('INSERT','DELETE')
       and s.tbl in ('properties','jobs','gdos','client_contacts','client_jobber_contacts','client_locations',
                     'client_communication_prefs','line_items','invoices')
  ),
  di_rank as (
    select d.*, row_number() over (partition by d.tbl, d.tx, md5(d.body::text), d.op order by d.id) as rn from di d
  ),
  cancelled as (
    select a.id from di_rank a
      join di_rank b on b.tbl = a.tbl and b.tx = a.tx and b.body = a.body and b.op <> a.op and b.rn = a.rn
    union
    -- line items also cancel across transactions: the Jobber sync rewrites them in separate requests
    select a.id from di a
      join di b on a.tbl = 'line_items' and b.tbl = 'line_items' and b.job_key = a.job_key and b.body = a.body
             and b.op <> a.op and b.tx <> a.tx and a.person is null and b.person is null
             and b.at between a.at - interval '2 minutes' and a.at + interval '2 minutes'
  ),
  -- what is left of a line-item replace that DID change something pairs up into one "changed" row
  li_left as (
    select d.*, row_number() over (partition by d.tx, d.job_key, d.body ->> 'name', d.op order by d.id) as rn
      from di d where d.tbl = 'line_items' and d.id not in (select c.id from cancelled c)
  ),
  li_pairs as (
    select del.id as del_id, ins.id as ins_id
      from li_left del
      join li_left ins on del.op = 'DELETE' and ins.op = 'INSERT' and ins.tx = del.tx and ins.job_key = del.job_key
                      and ins.body ->> 'name' = del.body ->> 'name' and ins.rn = del.rn
  ),
  members as (
    select s.id, s.tbl,
           case when lp.ins_id is not null then 'UPDATE' else s.op end as op,
           case when lp.ins_id is not null then dd.rec else s.o end as o,
           s.n, s.rec, s.at, s.tx, s.app, s.path, s.person, s.jobber_name, s.is_jobber, s.is_script, s.is_direct_sql,
           (s.tbl = 'invoices' and s.op = 'UPDATE' and s.o ->> 'client_id' is null and s.n ->> 'client_id' is not null) as is_inv_created
      from src s
      left join li_pairs lp on lp.ins_id = s.id
      left join src dd on dd.id = lp.del_id
     where s.id not in (select c.id from cancelled c)
       and s.id not in (select lp2.del_id from li_pairs lp2)
  ),
  -- a person-less writer that touched 20 or more clients in the hour around this row is bookkeeping
  burst as (
    select m.id from members m
     where m.person is null and m.op <> 'DELETE' and not m.is_script and not m.is_direct_sql
       and m.tbl not in ('client_status_changes','job_frequency_changes','property_intake_accepts')
       and (select count(distinct case l.table_name
                                    when 'clients' then l.record_pk ->> 'id'
                                    when 'line_items' then (select jj.client_id::text from public.jobs jj
                                                             where jj.id = (coalesce(l.new_row, l.old_row) ->> 'job_id')::bigint)
                                    else coalesce(l.new_row, l.old_row) ->> 'client_id' end)
              from audit.logs l
             where l.table_name = m.tbl
               and l.changed_at between m.at - interval '30 minutes' and m.at + interval '30 minutes'
               and coalesce(l.app_source, '') = m.app
               and coalesce(l.request_context ->> 'path', '') = coalesce(m.path, '')) >= 20
  ),
  -- 3. field changes of UPDATE rows (composites compare all their columns)
  upd as (
    select m.id as mid, f.column_name as col, f.label, f.render_type, f.fk_table, f.fk_label_col, f.sort_order,
           coalesce(f.is_system, false) as cfg_sys,
           case f.render_type
             when 'address'  then jsonb_build_array(m.o -> 'address', m.o -> 'city', m.o -> 'zip')
             when 'pin'      then jsonb_build_array(m.o -> 'latitude', m.o -> 'longitude')
             when 'geofence' then jsonb_build_array(m.o -> 'geofence_type', m.o -> 'geofence_radius_meters')
             when 'role'     then jsonb_build_array(m.o -> 'person_role', m.o -> 'person_role_other')
             else m.o -> f.column_name end as ov,
           case f.render_type
             when 'address'  then jsonb_build_array(m.n -> 'address', m.n -> 'city', m.n -> 'zip')
             when 'pin'      then jsonb_build_array(m.n -> 'latitude', m.n -> 'longitude')
             when 'geofence' then jsonb_build_array(m.n -> 'geofence_type', m.n -> 'geofence_radius_meters')
             when 'role'     then jsonb_build_array(m.n -> 'person_role', m.n -> 'person_role_other')
             else m.n -> f.column_name end as nv
      from members m join cfg f on f.table_name = m.tbl
     where m.op = 'UPDATE'
  ),
  ch0 as (
    select u.*, m.tbl, m.at, m.person, m.rec
      from upd u join members m on m.id = u.mid
     where audit.fn_activity_norm(u.ov) is distinct from audit.fn_activity_norm(u.nv)
       -- the status card carries the same move with its reason and person
       and not (m.tbl = 'clients' and u.col = 'status' and exists (
             select 1 from public.client_status_changes c
              where c.client_id = p_client_id and c.changed_at between m.at - interval '10 seconds' and m.at + interval '10 seconds'))
       -- the cadence card carries the same change (the client.job_activity rule)
       and not (m.tbl = 'jobs' and u.col = 'frequency_days' and exists (
             select 1 from public.job_frequency_changes f
              where f.job_id = (m.rec ->> 'id')::bigint and f.changed_at between m.at - interval '10 seconds' and m.at + interval '10 seconds'))
  ),
  -- 4. job status chains (rule 3.3.4): person-less legs on one job, each within 2 minutes of the last, become
  --    one net change on the first leg; a chain that ends where it began disappears
  js as (
    select c.mid, c.at, c.rec ->> 'id' as job_id, c.ov, c.nv,
           case when lag(c.at) over w is null or c.at - lag(c.at) over w > interval '2 minutes' then 1 else 0 end as brk
      from ch0 c where c.tbl = 'jobs' and c.col = 'job_status' and c.person is null
    window w as (partition by c.rec ->> 'id' order by c.at, c.mid)
  ),
  js2 as (select js.*, sum(js.brk) over (partition by js.job_id order by js.at, js.mid) as chain from js),
  js3 as (
    select js2.mid, js2.job_id, js2.chain,
           first_value(js2.ov) over cw as chain_ov, last_value(js2.nv) over cw as chain_nv,
           row_number() over (partition by js2.job_id, js2.chain order by js2.at, js2.mid) as leg
      from js2
    window cw as (partition by js2.job_id, js2.chain order by js2.at, js2.mid rows between unbounded preceding and unbounded following)
  ),
  ch as (
    select c.mid, c.col, c.label, c.render_type, c.fk_table, c.fk_label_col, c.sort_order, c.cfg_sys,
           coalesce(j.chain_ov, c.ov) as ov, coalesce(j.chain_nv, c.nv) as nv
      from ch0 c
      left join js3 j on j.mid = c.mid and c.col = 'job_status' and c.tbl = 'jobs'
     where j.mid is null
        or (j.leg = 1 and audit.fn_activity_norm(j.chain_ov) is distinct from audit.fn_activity_norm(j.chain_nv))
  ),
  -- 5. each change rendered, and whether it is bookkeeping (rule 3.4)
  crow as (
    select c.mid, c.col, c.label, c.sort_order, c.render_type,
           audit.fn_activity_value(c.ov, c.render_type, c.fk_table, c.fk_label_col) as old_txt,
           audit.fn_activity_value(c.nv, c.render_type, c.fk_table, c.fk_label_col) as new_txt,
           c.col in ('notes','access_notes') as long,
           c.ov #>> '{}' as ov_s, c.nv #>> '{}' as nv_s,
           case
             when m.person is not null then false
             -- never background: key moves of a job, invoice key events, the creation of an invoice
             when m.tbl = 'jobs' and c.col = 'job_status'
                  and (coalesce(c.ov #>> '{}', '') in ('archived','closed','destroyed','active')
                       or coalesce(c.nv #>> '{}', '') in ('archived','closed','destroyed','active')) then false
             when m.tbl = 'invoices' and c.col = 'invoice_status'
                  and (c.nv #>> '{}' in ('paid','voided','bad_debt','destroyed')
                       or (c.nv #>> '{}' = 'awaiting_payment' and coalesce(c.ov #>> '{}', 'draft') = 'draft')) then false
             when m.is_inv_created and c.col in ('invoice_status','total') then false
             when m.is_script or m.is_direct_sql or m.id in (select b.id from burst b) then true
             when c.cfg_sys then true
             when m.tbl = 'jobs' and c.col = 'job_status'
                  and c.ov #>> '{}' in ('upcoming','today','late','action_required','requires_invoicing')
                  and c.nv #>> '{}' in ('upcoming','today','late','action_required','requires_invoicing') then true
             when m.tbl = 'invoices' and c.col = 'invoice_status' then true
             when m.tbl = 'invoices' and m.o ->> 'invoice_status' = 'draft' and m.n ->> 'invoice_status' = 'draft' then true
             else false
           end as sys
      from ch c join members m on m.id = c.mid
     where c.render_type <> 'removed'
  ),
  rem as (
    select c.mid, audit.fn_activity_norm(c.nv) is not null as removed_now from ch c where c.render_type = 'removed'
  ),
  cagg as (
    select c.mid, count(*) as n_ch,
           (array_agg(c.label order by c.sort_order))[1] as first_label,
           (array_agg(c.long order by c.sort_order))[1] as first_long,
           (array_agg(c.old_txt is null order by c.sort_order))[1] as first_old_empty,
           (array_agg(c.render_type order by c.sort_order))[1] as first_type,
           (array_agg(c.col order by c.sort_order))[1] as first_col,
           max(c.nv_s) filter (where c.col = 'job_status') as js_new,
           max(c.ov_s) filter (where c.col = 'job_status') as js_old,
           bool_and(c.sys) as all_sys
      from crow c group by c.mid
  ),
  pia as (
    select m.id, m.at, m.tx, m.n ->> 'property_id' as property_id, (m.n ->> 'intake_id')::bigint as intake_id
      from members m where m.tbl = 'property_intake_accepts'
  ),
  -- 6. one row per kept record change: area, subject, title, bookkeeping flag
  mrow as (
    select m.id as mid, m.tbl, m.op, m.at, m.tx, m.app, m.person, m.jobber_name, m.is_jobber,
           case when m.tbl in ('clients','client_status_changes') then 'client'
                when m.tbl = 'properties' then 'property'
                when m.tbl in ('jobs','line_items','job_frequency_changes') then 'job'
                when m.tbl = 'gdos' then 'gdo'
                when m.tbl = 'invoices' then 'invoice'
                when m.tbl = 'visits' then 'visit'
                else 'contacts' end as area,
           case m.tbl when 'client_status_changes' then 1 when 'jobs' then 2 when 'line_items' then 2 when 'visits' then 2
                      when 'job_frequency_changes' then 2 when 'properties' then 3 when 'client_contacts' then 4
                      when 'client_jobber_contacts' then 4 when 'client_communication_prefs' then 4
                      when 'client_locations' then 4 when 'gdos' then 5 when 'invoices' then 6 else 7 end as rank,
           case when m.tbl = 'client_communication_prefs'
                then 'contact:' || coalesce(m.rec ->> 'contact_id', 'j' || (m.rec ->> 'jobber_contact_id'), m.id::text)
                else m.tbl || ':' || coalesce(case when m.tbl = 'line_items' then m.rec ->> 'job_id' else m.rec ->> 'id' end, m.id::text)
           end as rec_key,
           case
             when m.tbl = 'clients' then null
             when m.tbl = 'client_status_changes' then null
             when m.tbl = 'properties' then coalesce(nullif(btrim(m.rec ->> 'address'), ''), nullif(btrim(m.rec ->> 'name'), ''), 'Property #' || (m.rec ->> 'id'))
                                            || coalesce(' (' || nullif(btrim(m.rec ->> 'name'), '') || ')', '')
             when m.tbl = 'jobs' then '#' || coalesce(m.rec ->> 'job_number', m.rec ->> 'id') || coalesce(' ' || nullif(btrim(m.rec ->> 'title'), ''), '')
             when m.tbl in ('line_items','job_frequency_changes') then (
                    select '#' || coalesce(jj.job_number, jj.id::text) || coalesce(' ' || nullif(btrim(jj.title), ''), '')
                      from public.jobs jj where jj.id = (m.rec ->> 'job_id')::bigint)
             when m.tbl = 'gdos' then coalesce(nullif(btrim(m.rec ->> 'gdo_number'), ''), 'GDO permit #' || (m.rec ->> 'id'))
             when m.tbl = 'invoices' then 'Invoice #' || coalesce(m.rec ->> 'invoice_number', m.rec ->> 'id')
             when m.tbl = 'visits' then 'Visit ' || coalesce(to_char((m.rec ->> 'visit_date')::date, 'Mon FMDD, YYYY'), 'with no date')
                                        || ' (#' || (m.rec ->> 'id') || ')'
             when m.tbl in ('client_contacts','client_jobber_contacts') then coalesce(nullif(btrim(m.rec ->> 'name'), ''), m.rec ->> 'email', 'Contact #' || (m.rec ->> 'id'))
             when m.tbl = 'client_locations' then coalesce(nullif(btrim(m.rec ->> 'name'), ''), 'Location #' || (m.rec ->> 'id'))
             when m.tbl = 'client_communication_prefs' then coalesce(
                    (select coalesce(nullif(btrim(cc.name), ''), cc.email) from public.client_contacts cc where cc.id = (m.rec ->> 'contact_id')::bigint),
                    (select coalesce(nullif(btrim(jc.name), ''), jc.email) from public.client_jobber_contacts jc where jc.id = (m.rec ->> 'jobber_contact_id')::bigint),
                    'A contact no longer on file')
           end as subject,
           case
             when m.tbl = 'client_status_changes' then
               case m.n ->> 'event' when 'archived' then 'Client archived' when 'archived_here_only' then 'Client archived here only'
                                    when 'deleted_in_jobber' then 'Client deleted in Jobber' else 'Status changed' end
             when m.tbl = 'job_frequency_changes' then 'Frequency changed'
             when m.tbl = 'client_communication_prefs' then 'Who receives what changed'
             when m.op = 'INSERT' then
               case m.tbl when 'clients' then 'Client created' when 'properties' then 'Property added' when 'jobs' then 'Job added'
                          when 'gdos' then 'GDO permit added' when 'client_locations' then 'Location added'
                          when 'line_items' then 'Line item added' when 'invoices' then 'Invoice created'
                          when 'visits' then 'Visit added' else 'Contact added' end
             when m.op = 'DELETE' then
               case m.tbl when 'clients' then 'Client removed' when 'properties' then 'Property removed' when 'jobs' then 'Job removed'
                          when 'gdos' then 'GDO permit removed' when 'client_locations' then 'Location removed'
                          when 'line_items' then 'Line item removed' when 'invoices' then 'Invoice removed'
                          when 'visits' then 'Visit removed' else 'Contact removed' end
             when r.mid is not null then
               case m.tbl when 'properties' then 'Property' when 'client_jobber_contacts' then 'Contact' else 'Record' end
               || case when r.removed_now then ' removed' else ' restored' end
             when m.is_inv_created then 'Invoice created'
             when m.tbl = 'properties' and pa.intake_id is not null then 'Accepted from Site survey form #' || pa.intake_id
             when m.tbl = 'invoices' and a.js_new is null and (m.o ->> 'invoice_status') is distinct from (m.n ->> 'invoice_status') then
               case when m.n ->> 'invoice_status' = 'paid' then 'Invoice paid'
                    when m.n ->> 'invoice_status' = 'awaiting_payment' and coalesce(m.o ->> 'invoice_status', 'draft') = 'draft' then 'Invoice sent'
                    when m.n ->> 'invoice_status' = 'voided' then 'Invoice voided'
                    when m.n ->> 'invoice_status' = 'bad_debt' then 'Invoice marked bad debt'
                    when m.n ->> 'invoice_status' = 'destroyed' then 'Invoice deleted in Jobber'
                    else 'Invoice status changed' end
             when a.js_new is not null then
               case when a.js_new = 'archived' then 'Archived' when a.js_new = 'closed' then 'Closed'
                    when a.js_new = 'destroyed' then 'Deleted in Jobber'
                    when a.js_old in ('archived','closed','destroyed') then 'Reopened'
                    else 'Status changed' end
             when m.tbl = 'line_items' and m.op = 'UPDATE' then 'Line item changed'
             -- a visit's key moves get their own title (the change lines still say every field)
             when m.tbl = 'visits' and m.o ->> 'deleted_at' is null and m.n ->> 'deleted_at' is not null then 'Visit deleted'
             when m.tbl = 'visits' and m.o ->> 'deleted_at' is not null and m.n ->> 'deleted_at' is null then 'Visit restored'
             when m.tbl = 'visits' and (m.o ->> 'visit_status') is distinct from (m.n ->> 'visit_status') then
               case when m.n ->> 'visit_status' = 'completed' then 'Visit completed'
                    when m.n ->> 'visit_status' = 'cancelled' then 'Visit cancelled'
                    when m.n ->> 'visit_status' = 'skipped' then 'Visit skipped'
                    when m.o ->> 'visit_status' in ('completed','cancelled','skipped') then 'Visit reopened'
                    else 'Visit status changed' end
             when a.n_ch = 1 and a.first_type = 'changed' then a.first_label || case when a.first_col = 'permit_document_path' then ' replaced' else ' changed' end
             when a.n_ch = 1 then a.first_label || case when a.first_long then ' edited' when a.first_old_empty then ' set' else ' changed' end
             else case m.tbl when 'clients' then 'Client' when 'properties' then 'Property' when 'jobs' then 'Job'
                             when 'gdos' then 'GDO permit' when 'client_locations' then 'Location' when 'invoices' then 'Invoice'
                             when 'visits' then 'Visit' else 'Contact' end || ' details changed'
           end as title,
           -- bookkeeping at the record level
           case
             when m.tbl in ('client_status_changes','job_frequency_changes') then false
             when m.op = 'DELETE' then false
             when r.mid is not null then false
             when m.is_inv_created then false
             when m.op = 'INSERT' then
               case when m.tbl in ('clients','invoices') then false
                    when m.person is not null then false
                    when m.tbl = 'client_jobber_contacts' then true
                    when m.is_script or m.is_direct_sql or m.id in (select b.id from burst b) then true
                    else false end
             else coalesce(a.all_sys, true)
           end as member_sys,
           case when m.tbl = 'client_status_changes' then (
             select jsonb_build_object('id', sc.id, 'event', sc.event, 'old_status', sc.old_status, 'new_status', sc.new_status,
                                       'reason', sc.reason, 'visits_removed', sc.visits_removed, 'photo_count', sc.photo_count,
                                       'changed_by_label', case when sc.changed_by_email is null then 'Jobber'
                                                                when public.fn_page_staff_name(sc.changed_by_email) like '%@%' then 'Staff (no name on file)'
                                                                else public.fn_page_staff_name(sc.changed_by_email) end)
               from client.status_changes sc where sc.id = (m.n ->> 'id')::bigint) end as status_card,
           case when m.tbl = 'job_frequency_changes' then (
             select jsonb_build_object('id', fc.id, 'job_id', fc.job_id, 'old_frequency_days', fc.old_frequency_days,
                                       'new_frequency_days', fc.new_frequency_days, 'reason', fc.reason, 'proof_count', fc.proof_count,
                                       'changed_by_label', case when fc.changed_by_email is null then 'System'
                                                                when public.fn_page_staff_name(fc.changed_by_email) like '%@%' then 'Staff (no name on file)'
                                                                else public.fn_page_staff_name(fc.changed_by_email) end)
               from client.job_frequency_changes fc where fc.id = (m.n ->> 'id')::bigint) end as cadence_card,
           a.n_ch
      from members m
      left join cagg a on a.mid = m.id
      left join rem r on r.mid = m.id
      left join lateral (
        select p.intake_id from pia p
         where m.tbl = 'properties' and m.op = 'UPDATE' and p.property_id = m.rec ->> 'id'
           and (p.tx = m.tx or p.at between m.at - interval '10 seconds' and m.at + interval '10 seconds')
         order by p.id limit 1) pa on true
     where m.tbl <> 'property_intake_accepts'
       -- an UPDATE with nothing left to show is not an entry (a card, an insert, a delete or a removal always is)
       and (m.op <> 'UPDATE' or m.tbl in ('client_status_changes','job_frequency_changes')
            or coalesce(a.n_ch, 0) > 0 or r.mid is not null or m.is_inv_created)
  ),
  -- the card rows exist through their audit INSERT, so the live card must still be there
  mrow_live as (
    select * from mrow mr
     where not (mr.tbl = 'client_status_changes' and mr.status_card is null)
       and not (mr.tbl = 'job_frequency_changes' and mr.cadence_card is null)
  ),
  -- 7. the change lines: field changes, plus one summary line for an insert or a delete
  lines as (
    select c.mid, c.sort_order as ord, c.sys, c.label, mr.subject,
           jsonb_build_object('subject', mr.subject, 'label', c.label,
                              'old', case when c.render_type = 'changed' then null else coalesce(c.old_txt, 'Not set') end,
                              'new', case when c.render_type = 'changed' then null else coalesce(c.new_txt, 'Not set') end,
                              'is_system', c.sys, 'long', c.long) as line,
           c.old_txt, c.new_txt, mr.tbl, c.col
      from crow c join mrow_live mr on mr.mid = c.mid
     where mr.op = 'UPDATE'
    union all
    select mr.mid, 0, mr.member_sys,
           case when mr.tbl = 'client_communication_prefs' then case mr.op when 'INSERT' then 'Now receives' else 'No longer receives' end
                else case mr.tbl when 'clients' then 'Client' when 'properties' then 'Property' when 'jobs' then 'Job'
                                 when 'gdos' then 'GDO permit' when 'client_locations' then 'Location' when 'line_items' then 'Line item'
                                 when 'invoices' then 'Invoice' when 'visits' then 'Visit' else 'Contact' end end,
           mr.subject,
           jsonb_build_object('subject', mr.subject,
             'label', case when mr.tbl = 'client_communication_prefs' then case mr.op when 'INSERT' then 'Now receives' else 'No longer receives' end
                           else case mr.tbl when 'clients' then 'Client' when 'properties' then 'Property' when 'jobs' then 'Job'
                                            when 'gdos' then 'GDO permit' when 'client_locations' then 'Location' when 'line_items' then 'Line item'
                                            when 'invoices' then 'Invoice' when 'visits' then 'Visit' else 'Contact' end end,
             'old', case when mr.op = 'DELETE' then sm.summary end,
             'new', case when mr.op = 'INSERT' then sm.summary end,
             'is_system', mr.member_sys, 'long', false),
           null::text, null::text, mr.tbl, null::text
      from mrow_live mr
      join members m on m.id = mr.mid
      cross join lateral (
        select case mr.tbl
                 when 'clients' then concat_ws(' ', m.rec ->> 'client_code', m.rec ->> 'name')
                 when 'properties' then concat_ws(', ', nullif(btrim(m.rec ->> 'address'), ''), nullif(btrim(m.rec ->> 'city'), ''))
                 when 'jobs' then concat_ws(' ', '#' || (m.rec ->> 'job_number'), m.rec ->> 'title')
                 when 'gdos' then concat_ws(' ', m.rec ->> 'gdo_number', nullif(btrim(m.rec ->> 'location_label'), ''))
                 when 'client_locations' then m.rec ->> 'name'
                 when 'line_items' then concat(m.rec ->> 'name', ' (', coalesce(m.rec ->> 'quantity', '1'), ' x ',
                                               coalesce(audit.render_value(m.rec -> 'unit_price', 'money', null, null), '$0.00'), ')')
                 when 'client_communication_prefs' then
                   case m.rec ->> 'comm_type' when 'invoice' then 'Invoices' when 'quote_approval' then 'Quote approvals'
                                              when 'service_report' then 'Service reports' when 'city_report' then 'City reports'
                                              else m.rec ->> 'comm_type' end
                   || coalesce(' (' || (select coalesce(nullif(btrim(pp.address), ''), pp.name) from public.properties pp
                                         where pp.id = (m.rec ->> 'property_id')::bigint) || ')', '')
                 when 'invoices' then concat_ws(' ', 'Invoice #' || (m.rec ->> 'invoice_number'))
                 when 'visits' then concat_ws(' · ', to_char((m.rec ->> 'visit_date')::date, 'Mon FMDD, YYYY'), nullif(btrim(m.rec ->> 'title'), ''))
                 else concat_ws(' · ', nullif(btrim(m.rec ->> 'name'), ''), nullif(btrim(m.rec ->> 'email'), ''), nullif(btrim(m.rec ->> 'phone'), ''))
               end as summary) sm
     where mr.op in ('INSERT','DELETE')
       -- a status or cadence card is the whole entry: no summary line under it
       and mr.tbl not in ('client_status_changes','job_frequency_changes')
  ),
  -- 8. one save is one entry (rule 3.3.2): a transaction is a group; groups of the same writer starting within
  --    5 s of each other chain; two groups naming different people never chain
  g as (
    select mr.tx, min(mr.at) as start, min(mr.app) as app,
           (array_agg(mr.person order by mr.at, mr.mid) filter (where mr.person is not null))[1] as person,
           min(mr.mid) as first_mid
      from mrow_live mr group by mr.tx
  ),
  g1 as (
    select g.*, lag(g.start) over o as prev_start, lag(g.app) over o as prev_app
      from g window o as (order by g.start, g.first_mid)
  ),
  g2 as (
    select g1.*, sum(case when g1.prev_start is null or g1.app <> g1.prev_app or g1.start - g1.prev_start > interval '5 seconds'
                          then 1 else 0 end) over (order by g1.start, g1.first_mid) as tchain
      from g1
  ),
  g3 as (
    select g2.*, array_remove(array_agg(g2.person) over (partition by g2.tchain order by g2.start, g2.first_mid
                                                         rows between unbounded preceding and 1 preceding), null) as prev_persons
      from g2
  ),
  g4 as (
    select g3.tx, g3.tchain, g3.person,
           sum(case when g3.person is not null and g3.prev_persons is not null and cardinality(g3.prev_persons) > 0
                         and g3.prev_persons[cardinality(g3.prev_persons)] <> g3.person then 1 else 0 end)
             over (partition by g3.tchain order by g3.start, g3.first_mid) as sub
      from g3
  ),
  ent_of as (select g4.tx, g4.tchain || '.' || g4.sub as eid from g4),
  -- the same zone move on several properties of one entry reads "on N sites" (rule 3.3.5)
  lines_e as (
    select e.eid, l.*,
           count(*) over (partition by e.eid, l.tbl, l.col, l.old_txt, l.new_txt) as same_n,
           row_number() over (partition by e.eid, l.tbl, l.col, l.old_txt, l.new_txt order by l.mid) as same_rn
      from lines l join mrow_live mr on mr.mid = l.mid join ent_of e on e.tx = mr.tx
  ),
  lines_z as (
    select le.eid, le.mid, le.ord, le.sys,
           case when le.tbl = 'properties' and le.col = 'zone_id' and le.same_n > 1
                then jsonb_set(jsonb_set(le.line, '{new}', to_jsonb(coalesce(le.new_txt, 'Not set') || ' on ' || le.same_n || ' sites')),
                               '{subject}', 'null'::jsonb)
                else le.line end as line
      from lines_e le
     where not (le.tbl = 'properties' and le.col = 'zone_id' and le.same_n > 1 and le.same_rn > 1)
  ),
  ent as (
    select e.eid,
           min(mr.at) as at,
           (array_agg(case when mr.tbl = 'client_status_changes' then 'csc:' || (mr.status_card ->> 'id')
                           when mr.tbl = 'job_frequency_changes' then 'jfc:' || (mr.cadence_card ->> 'id')
                           else 'a:' || mr.mid end order by mr.at, mr.mid))[1] as key,
           (array_agg(mr.area order by mr.member_sys, mr.rank, mr.at, mr.mid))[1] as area,
           (array_agg(mr.subject order by mr.member_sys, mr.rank, mr.at, mr.mid))[1] as subject1,
           (array_agg(mr.title order by mr.member_sys, mr.rank, mr.at, mr.mid))[1] as title,
           count(distinct mr.rec_key) filter (where v_inc or not mr.member_sys) as n_records,
           (array_agg(mr.person order by mr.at, mr.mid) filter (where mr.person is not null))[1] as person,
           bool_or(mr.is_jobber) as any_jobber,
           max(mr.jobber_name) as jobber_name,
           (array_agg(mr.app order by mr.at, mr.mid) filter (where mr.app in ('client-app','picture-planner')))[1] as app_nobody,
           bool_and(mr.member_sys) as is_system,
           (array_agg(mr.status_card order by mr.at, mr.mid) filter (where mr.status_card is not null))[1] as status_card,
           (array_agg(mr.cadence_card order by mr.at, mr.mid) filter (where mr.cadence_card is not null))[1] as cadence_card
      from mrow_live mr join ent_of e on e.tx = mr.tx
     group by e.eid
  ),
  ent_lines as (
    select lz.eid, jsonb_agg(lz.line order by mr.member_sys, mr.rank, mr.at, lz.mid, lz.ord) as changes
      from lines_z lz join mrow_live mr on mr.mid = lz.mid
     where v_inc or not lz.sys
     group by lz.eid
  ),
  audit_entries as (
    select en.key, en.at, en.area,
           en.subject1 || case when en.n_records > 1 then ' and ' || (en.n_records - 1) || ' more' else '' end as subject,
           en.title,
           case when en.person is not null then
                  case when public.fn_page_staff_name(en.person) like '%@%' then 'Staff (no name on file)' else public.fn_page_staff_name(en.person) end
                when en.any_jobber then 'Jobber' || coalesce(' · ' || en.jobber_name, '')
                when en.app_nobody = 'client-app' then 'Client App (person not recorded)'
                when en.app_nobody = 'picture-planner' then 'Picture Planner (person not recorded)'
                else 'System' end as actor_label,
           case when en.person is not null then 'person' when en.any_jobber then 'jobber'
                when en.app_nobody is not null then 'app' else 'system' end as actor_kind,
           en.is_system, coalesce(el.changes, '[]'::jsonb) as changes, en.status_card, en.cadence_card
      from ent en left join ent_lines el on el.eid = en.eid
  ),
  -- 9. property events (forms, site file) from the property reader; an accepted answer is already the property diff
  prop_events as (
    select 'pe:' || pr.id || ':' || (ev ->> 'kind') || ':' || coalesce(ev ->> 'intake_id', ev ->> 'version', '') || ':' || (ev ->> 'at') as key,
           (ev ->> 'at')::timestamptz as at, 'property' as area,
           coalesce(nullif(btrim(pr.address), ''), nullif(btrim(pr.name), ''), 'Property #' || pr.id) as subject,
           case ev ->> 'kind'
             when 'form_requested' then 'Site survey form #' || (ev ->> 'intake_id') || ' requested'
             when 'form_link_shown' then 'Link to site survey form #' || (ev ->> 'intake_id') || ' shown'
             when 'form_filled' then 'Site survey form #' || (ev ->> 'intake_id') || ' filled in'
             when 'form_cancelled' then 'Site survey form #' || (ev ->> 'intake_id') || ' cancelled'
             when 'page_submitted' then 'Version ' || (ev ->> 'version') || ' of the site file submitted for approval'
             when 'page_approved' then 'Version ' || (ev ->> 'version') || ' of the site file approved'
             when 'driver_link_created' then 'Site file link created'
             when 'driver_link_replaced' then 'Site file link replaced'
             else ev ->> 'text' end as title,
           case when ev ->> 'kind' = 'form_filled' then coalesce(nullif(btrim(ev ->> 'who'), ''), 'Someone') || ' (name typed on the form)'
                when nullif(btrim(ev ->> 'who'), '') is null then 'System'
                when ev ->> 'who' like '%@%' then 'Staff (no name on file)'
                else ev ->> 'who' end as actor_label,
           case when ev ->> 'kind' = 'form_filled' then 'form'
                when nullif(btrim(ev ->> 'who'), '') is null then 'system' else 'person' end as actor_kind,
           (ev ->> 'kind') = 'form_link_shown' as is_system,
           '[]'::jsonb as changes, null::jsonb as status_card, null::jsonb as cadence_card
      from public.properties pr
      cross join lateral jsonb_array_elements(client.get_property_activity(pr.id)) ev
     where pr.client_id = p_client_id and ev ->> 'kind' <> 'intake_accepted'
  ),
  -- 10. notes not tied to a visit (Jobber), at their own date
  note_entries as (
    select 'note:' || nt.id as key, coalesce(nt.note_date, nt.created_at) as at, 'note' as area, null::text as subject,
           'Note added' as title, 'Jobber' || coalesce(' · ' || nullif(btrim(nt.author_name), ''), '') as actor_label,
           'jobber' as actor_kind, false as is_system,
           case when nullif(btrim(nt.body), '') is null then '[]'::jsonb
                -- a note is new text, never "edited": long stays false and the app wraps it
                else jsonb_build_array(jsonb_build_object('subject', null, 'label', 'Note', 'old', null, 'new', nt.body,
                                                          'is_system', false, 'long', false)) end as changes,
           null::jsonb as status_card, null::jsonb as cadence_card
      from public.notes nt
     where nt.client_id = p_client_id and nt.visit_id is null
  ),
  -- 11. one "on record" entry per record that existed before its own history began (Fred, 2026-10-15: "did you also
  --     added when a job was created since early entry? and so on with other data from the client too?" then "yes
  --     build it that way"). A record whose FIRST audit row is not its INSERT (or that has none) has no "added" entry, so
  --     its story would start mid-way. The entry sits at the record's created_at (when it reached our database) and shows
  --     the EARLIEST state we hold: the old row of its first audit row, else the row as it is now (no row: never changed).
  --     A record created before its table's history began adds "Changes recorded from: <date>", so the entry never
  --     claims more than we know. Old visits and invoices are background (about 3,200 across all clients would bury the
  --     rest); clients, properties, jobs and contacts show. The Client App draws "Start of this record. Nothing earlier."
  --     under any entry whose key starts with 'start:'. Replaces the frequency-only "Starting frequency" entry
  --     (2026-10-15_1257 / _1343): a job's entry carries its frequency. Lines never repeat the subject.
  start_recs as (
    select 'clients'::text as tbl, c.id, c.created_at, to_jsonb(c) as cur from public.clients c where c.id = p_client_id
    union all select 'properties', p.id, p.created_at, to_jsonb(p) from public.properties p where p.client_id = p_client_id
    union all select 'jobs', j.id, j.created_at, to_jsonb(j) from public.jobs j where j.client_id = p_client_id
    union all select 'client_contacts', cc.id, cc.created_at, to_jsonb(cc) from public.client_contacts cc where cc.client_id = p_client_id
    union all select 'visits', vi.id, vi.created_at, to_jsonb(vi) from public.visits vi where vi.client_id = p_client_id
    union all select 'invoices', i.id, i.created_at, to_jsonb(i) from public.invoices i where i.client_id = p_client_id
  ),
  start_hist as (
    select t.tbl, (select min(l.changed_at) from audit.logs l where l.table_schema = 'public' and l.table_name = t.tbl) as since
      from (values ('clients'), ('properties'), ('jobs'), ('client_contacts'), ('visits'), ('invoices')) t(tbl)
  ),
  start_snap as (
    select r.tbl, r.id, r.created_at, coalesce(fa.old_row, r.cur) as s, h.since
      from start_recs r
      join start_hist h on h.tbl = r.tbl
      left join lateral (
        select l.operation as op, l.old_row from audit.logs l
         where l.table_schema = 'public' and l.table_name = r.tbl and l.record_pk ->> 'id' = r.id::text
         order by l.changed_at, l.id limit 1) fa on true
     where fa.op is distinct from 'INSERT' and r.created_at is not null
  ),
  start_entries as (
    select 'start:' || ss.tbl || ':' || ss.id as key, ss.created_at as at,
           case ss.tbl when 'clients' then 'client' when 'properties' then 'property' when 'jobs' then 'job'
                       when 'visits' then 'visit' when 'invoices' then 'invoice' else 'contacts' end as area,
           case ss.tbl
             when 'clients' then null
             when 'properties' then coalesce(nullif(btrim(ss.s ->> 'address'), ''), nullif(btrim(ss.s ->> 'name'), ''), 'Property #' || ss.id)
                                    || coalesce(' (' || nullif(btrim(ss.s ->> 'name'), '') || ')', '')
             when 'jobs' then '#' || coalesce(ss.s ->> 'job_number', ss.id::text) || coalesce(' ' || nullif(btrim(ss.s ->> 'title'), ''), '')
             when 'visits' then 'Visit ' || coalesce(to_char((ss.s ->> 'visit_date')::date, 'Mon FMDD, YYYY'), 'with no date') || ' (#' || ss.id || ')'
             when 'invoices' then 'Invoice #' || coalesce(ss.s ->> 'invoice_number', ss.id::text)
             else coalesce(nullif(btrim(ss.s ->> 'name'), ''), ss.s ->> 'email', 'Contact #' || ss.id)
           end as subject,
           case ss.tbl when 'clients' then 'Client on record' when 'properties' then 'Property on record' when 'jobs' then 'Job on record'
                       when 'visits' then 'Visit on record' when 'invoices' then 'Invoice on record' else 'Contact on record' end as title,
           'System' as actor_label, 'system' as actor_kind, ss.tbl in ('visits','invoices') as is_system,
           coalesce(ln.lines, '[]'::jsonb) as changes, null::jsonb as status_card, null::jsonb as cadence_card
      from start_snap ss
      cross join lateral (
        select jsonb_agg(jsonb_build_object('subject', null, 'label', x.l, 'old', null, 'new', x.v,
                                            'is_system', ss.tbl in ('visits','invoices'), 'long', false) order by x.o) as lines
          from (values
            (1,  'Client code', case when ss.tbl = 'clients' then ss.s ->> 'client_code' end),
            (2,  'Name', case when ss.tbl = 'clients' then ss.s ->> 'name' end),
            (3,  'Address', case when ss.tbl = 'properties' then concat_ws(', ', nullif(btrim(ss.s ->> 'address'), ''), nullif(btrim(ss.s ->> 'city'), '')) end),
            (4,  'Email', case when ss.tbl = 'client_contacts' then ss.s ->> 'email' end),
            (5,  'Phone', case when ss.tbl = 'client_contacts' then ss.s ->> 'phone' end),
            (8,  'Date', case when ss.tbl = 'visits' then to_char((ss.s ->> 'visit_date')::date, 'Mon FMDD, YYYY') end),
            (10, 'Status', case ss.tbl when 'clients' then audit.fn_activity_sentence(ss.s ->> 'status')
                                       when 'jobs' then audit.fn_activity_sentence(ss.s ->> 'job_status')
                                       when 'visits' then audit.fn_activity_sentence(ss.s ->> 'visit_status')
                                       when 'invoices' then audit.fn_activity_sentence(ss.s ->> 'invoice_status') end),
            (11, 'Frequency', case when ss.tbl = 'jobs' and coalesce((ss.s ->> 'frequency_days')::int, 0) > 0
                                   then audit.fn_activity_value(ss.s -> 'frequency_days', 'days', null, null) end),
            (12, 'Truck', case when ss.tbl = 'visits' then (select ve.name from public.vehicles ve where ve.id = (ss.s ->> 'vehicle_id')::bigint) end),
            (13, 'Total', case when ss.tbl = 'invoices' and ss.s ? 'total' then audit.render_value(ss.s -> 'total', 'money', null, null) end),
            (14, 'Changes recorded from', case when ss.since is not null and ss.created_at < ss.since
                                               then to_char(ss.since at time zone 'America/New_York', 'Mon FMDD, YYYY') end)
          ) x(o, l, v)
         where nullif(btrim(x.v), '') is not null) ln
  ),
  all_entries as (
    select ae.key, ae.at, ae.area, ae.subject, ae.title, ae.actor_label, ae.actor_kind, ae.is_system, ae.changes, ae.status_card, ae.cadence_card
      from audit_entries ae
    union all
    select pe.key, pe.at, pe.area, pe.subject, pe.title, pe.actor_label, pe.actor_kind, pe.is_system, pe.changes, pe.status_card, pe.cadence_card
      from prop_events pe
    union all
    select ne.key, ne.at, ne.area, ne.subject, ne.title, ne.actor_label, ne.actor_kind, ne.is_system, ne.changes, ne.status_card, ne.cadence_card
      from note_entries ne
    union all
    select se.key, se.at, se.area, se.subject, se.title, se.actor_label, se.actor_kind, se.is_system, se.changes, se.status_card, se.cadence_card
      from start_entries se
  )
  select x.key, x.at, x.area,
         case x.area when 'client' then 'Client' when 'property' then 'Property' when 'job' then 'Job' when 'contacts' then 'Contacts'
                     when 'gdo' then 'GDO permit' when 'invoice' then 'Invoice' when 'note' then 'Note' else initcap(x.area) end,
         x.subject, x.title, x.actor_label, x.actor_kind, x.is_system, x.changes, x.status_card, x.cadence_card
    from all_entries x
   where (v_inc or not x.is_system)
     and (p_cursor is null or (x.at, x.key) < ((p_cursor ->> 'at')::timestamptz, p_cursor ->> 'key'))
   order by x.at desc, x.key desc
   limit p_limit;
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '80fc2de59c0b529a6169e704c87ff923' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.get_client_activity(bigint,boolean,integer,jsonb)'; END IF;
  IF md5(pg_get_functiondef('client.get_client_activity(bigint,boolean,integer,jsonb)'::regprocedure)) <> '2ce0d107e8db3342f760ddd57ed8d617' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.get_client_activity(bigint,boolean,integer,jsonb)'; END IF;
  EXECUTE d;
  -- client.fn_reason_photo_object_removable(text)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.fn_reason_photo_object_removable(p_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_email text;
begin
  if auth.uid() is null then return false; end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then return false; end if;
  if p_name !~ '^client-app/[a-z_]+/[0-9]{1,18}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$' then return false; end if;
  return not exists (
    select 1
      from public.photo_links pl
      join public.photos p on p.id = pl.photo_id
     where p.storage_path = p_name
       and pl.role = 'reason_photo'
       and pl.deleted_at is null);
end;
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '6a7235d425d17fec30b29b5d1a3c722e' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.fn_reason_photo_object_removable(text)'; END IF;
  IF md5(pg_get_functiondef('client.fn_reason_photo_object_removable(text)'::regprocedure)) <> '7189a0958f30a4076752b76c032c3e73' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.fn_reason_photo_object_removable(text)'; END IF;
  EXECUTE d;
  -- client.attach_reason_photo(text,bigint,text,text,integer,integer)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.attach_reason_photo(p_entity_type text, p_entity_id bigint, p_storage_path text, p_file_name text DEFAULT NULL::text, p_width_px integer DEFAULT NULL::integer, p_height_px integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_email   text;
  v_uid     uuid;
  v_m       text[];
  v_obj     record;
  v_live    integer;
  v_max     integer := client.reason_photo_max();
  v_photo   bigint;
  v_link    bigint;
  v_emp     bigint;
  v_size    bigint;
  v_mime    text;
  v_out     jsonb;
begin
  perform hr.fn_check_app('client_app', 'edit', 'add a reason photo');   -- 2026-10-21_0900 access phase 5
  -- the same gate every client.* RPC uses
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;

  -- the target
  if not client.fn_reason_photo_target_exists(p_entity_type, p_entity_id) then
    raise exception 'The change this image belongs to could not be found. Save the change first, then add the image.'
      using errcode = 'P0002', detail = 'blocker=target_missing entity_type=' || coalesce(p_entity_type,'') || ' entity_id=' || coalesce(p_entity_id::text,'');
  end if;

  -- the path must be THIS record's: no attaching an object uploaded for another change
  v_m := regexp_match(coalesce(p_storage_path, ''),
    '^client-app/([a-z_]+)/([0-9]{1,18})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})[.](jpg|jpeg|png|webp)$');
  if v_m is null or v_m[1] <> p_entity_type or v_m[2]::bigint <> p_entity_id then
    raise exception 'This image was uploaded for a different change and cannot be attached here.'
      using errcode = '22023', detail = 'blocker=path_mismatch storage_path=' || coalesce(p_storage_path,'');
  end if;

  -- serialise per record so two concurrent attaches cannot both pass the cap
  perform pg_advisory_xact_lock(hashtext('reason_photo:' || p_entity_type || ':' || p_entity_id::text));

  -- idempotent: the same object attached twice returns the existing link (rule 5)
  select pl.id, pl.photo_id into v_link, v_photo
    from public.photo_links pl
    join public.photos p on p.id = pl.photo_id
   where p.storage_path = p_storage_path
     and pl.entity_type = p_entity_type and pl.entity_id = p_entity_id
     and pl.role = 'reason_photo' and pl.deleted_at is null;
  if v_link is null then
    select count(*) into v_live
      from public.photo_links pl
     where pl.entity_type = p_entity_type and pl.entity_id = p_entity_id
       and pl.role = 'reason_photo' and pl.deleted_at is null;
    if v_live >= v_max then
      raise exception 'This change already has % images. Remove one before adding another.', v_max
        using errcode = '23514', detail = 'blocker=cap live=' || v_live || ' max=' || v_max;
    end if;

    -- the object: it must exist in THIS bucket, uploaded by THIS caller, and be an image.
    -- size and mimetype come from the object's own metadata, never from the caller.
    select o.owner_id, o.metadata into v_obj
      from storage.objects o
     where o.bucket_id = 'reason-photos' and o.name = p_storage_path;
    if not found or v_obj.owner_id is null then
      raise exception 'The image did not finish uploading. Try adding it again.'
        using errcode = 'P0002', detail = 'blocker=object_missing storage_path=' || p_storage_path;
    end if;
    if v_obj.owner_id <> v_uid::text then
      raise exception 'This image was uploaded by someone else and cannot be attached here.'
        using errcode = '42501', detail = 'blocker=object_owner';
    end if;
    v_mime := v_obj.metadata ->> 'mimetype';
    v_size := nullif(v_obj.metadata ->> 'size', '')::bigint;
    if v_mime is null or v_mime not like 'image/%' then
      raise exception 'Only images can be attached to a reason.'
        using errcode = '22023', detail = 'blocker=not_image mimetype=' || coalesce(v_mime,'');
    end if;

    select e.id into v_emp
      from public.employees e
     where e.email is not null and lower(e.email) = v_email
     order by (e.status = 'ACTIVE') desc, e.id
     limit 1;

    insert into public.photos
      (storage_path, file_name, content_type, size_bytes, width_px, height_px,
       uploaded_by_employee_id, uploaded_at, source)
    values
      (p_storage_path, coalesce(nullif(btrim(p_file_name), ''), v_m[3] || '.' || v_m[4]), v_mime, v_size,
       p_width_px, p_height_px, v_emp, now(), 'client_app_upload')
    returning id into v_photo;

    -- caption = the uploader's GoTrue email: the estate's documented author convention for a link
    insert into public.photo_links (photo_id, entity_type, entity_id, role, caption)
    values (v_photo, p_entity_type, p_entity_id, 'reason_photo', v_email)
    returning id into v_link;
  end if;

  select count(*) into v_live
    from public.photo_links pl
   where pl.entity_type = p_entity_type and pl.entity_id = p_entity_id
     and pl.role = 'reason_photo' and pl.deleted_at is null;

  select to_jsonb(r) || jsonb_build_object('remaining', v_max - v_live) into v_out
    from client.reason_photos r
   where r.link_id = v_link;
  return v_out;
end;
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '77f76b6699ba31c2463a19f5d93359b9' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.attach_reason_photo(text,bigint,text,text,integer,integer)'; END IF;
  IF md5(pg_get_functiondef('client.attach_reason_photo(text,bigint,text,text,integer,integer)'::regprocedure)) <> '543c98ca909ba5b10137bcf0030812a7' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.attach_reason_photo(text,bigint,text,text,integer,integer)'; END IF;
  EXECUTE d;
  -- client.remove_reason_photo(bigint,text)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.remove_reason_photo(p_link_id bigint, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_email text;
  v_link  record;
  v_live  integer;
begin
  perform hr.fn_check_app('client_app', 'edit', 'remove a reason photo');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;

  select pl.id, pl.entity_type, pl.entity_id, pl.deleted_at, p.storage_path
    into v_link
    from public.photo_links pl
    join public.photos p on p.id = pl.photo_id
   where pl.id = p_link_id and pl.role = 'reason_photo';
  if not found then
    raise exception 'That image could not be found.'
      using errcode = 'P0002', detail = 'blocker=link_missing link_id=' || coalesce(p_link_id::text,'');
  end if;
  if v_link.deleted_at is not null then
    raise exception 'This image has already been removed.'
      using errcode = '22023', detail = 'blocker=already_removed link_id=' || p_link_id;
  end if;

  update public.photo_links
     set deleted_at = now(),
         deleted_by = auth.uid(),
         deleted_reason = coalesce(nullif(btrim(p_reason), ''), 'Removed in the Client App by ' || v_email)
   where id = p_link_id;

  select count(*) into v_live
    from public.photo_links pl
   where pl.entity_type = v_link.entity_type and pl.entity_id = v_link.entity_id
     and pl.role = 'reason_photo' and pl.deleted_at is null;

  return jsonb_build_object(
    'link_id',      p_link_id,
    'entity_type',  v_link.entity_type,
    'entity_id',    v_link.entity_id,
    'bucket',       'reason-photos',
    'storage_path', v_link.storage_path,
    'remaining',    client.reason_photo_max() - v_live,
    'live',         v_live);
end;
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'b4eb17252deab1ea62965459f817f751' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.remove_reason_photo(bigint,text)'; END IF;
  IF md5(pg_get_functiondef('client.remove_reason_photo(bigint,text)'::regprocedure)) <> '13c5edd7f54bdd35b899dc11c2c41671' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.remove_reason_photo(bigint,text)'; END IF;
  EXECUTE d;
  -- client.reject_property_page(bigint,text)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.reject_property_page(p_page_id bigint, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-21 (Trello 1Mej1zDX, Fred: "Reason required"): the people who can approve a site file can reject its
-- waiting version instead, with a reason. The version stays (append-only) and reads Rejected in Activity; the site
-- file and the property are unchanged; the next draft starts from the live version (or the property record).
-- One's own version may be rejected (a withdraw), so there is no own-version rule here.
declare
  v_uid    uuid := auth.uid();
  v_email  text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_reason text := btrim(coalesce(p_reason, ''));
  v_page   public.property_pages;
  v_live   int;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.reject_property_page';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.reject_property_page';
  end if;
  perform hr.fn_check_app('picture_planner', 'edit', 'reject a site file');
  if not (v_uid = any (public.fn_page_approver_ids())) then
    raise exception 'Only % can reject a page.', public.fn_page_approver_names() using errcode = '42501',
      detail = 'blocker=not_an_approver in client.reject_property_page';
  end if;
  if char_length(v_reason) not between 3 and 500 then
    raise exception 'Write why this version is rejected (3 to 500 characters).' using errcode = '22023',
      detail = 'blocker=reason in client.reject_property_page';
  end if;

  select * into v_page from public.property_pages where id = p_page_id;
  if not found then
    raise exception 'That version of the page does not exist. Reload the Page Builder.' using errcode = 'P0002',
      detail = 'blocker=no_such_version in client.reject_property_page';
  end if;
  perform pg_advisory_xact_lock(7342, v_page.property_id::int);   -- the same lock as submit and approve
  select * into v_page from public.property_pages where id = p_page_id;

  if v_page.approved_at is not null then
    raise exception 'This version is already approved, so it cannot be rejected.' using errcode = '22023',
      detail = 'blocker=already_approved in client.reject_property_page';
  end if;
  if v_page.rejected_at is not null then
    raise exception 'This version is already rejected.' using errcode = '22023',
      detail = 'blocker=already_rejected in client.reject_property_page';
  end if;
  -- Any version submitted after the live one is waiting and can be decided, not only the newest (Fred, 2026-10-21: "all
  -- that are pending can be waiting for approval, but only the ones that were submitted after an approved version").
  -- One below the live version was passed over and cannot.
  select max(version) into v_live from public.property_pages where property_id = v_page.property_id and approved_at is not null;
  if v_page.version < coalesce(v_live, 0) then
    raise exception 'A later version of this page is already live, so this one can no longer be rejected.' using errcode = '22023',
      detail = 'blocker=superseded in client.reject_property_page';
  end if;

  update public.property_pages
     set rejected_at = now(), rejected_by = v_uid, rejected_by_email = v_email, reject_reason = v_reason
   where id = p_page_id;

  return jsonb_build_object('ok', true, 'page_id', p_page_id, 'version', v_page.version);
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'ceaa4459b03500840246b2955c1dbe5b' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.reject_property_page(bigint,text)'; END IF;
  IF md5(pg_get_functiondef('client.reject_property_page(bigint,text)'::regprocedure)) <> 'b0345a408b7b76852a52b2daa333bdd1' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.reject_property_page(bigint,text)'; END IF;
  EXECUTE d;
  -- derm.get_visit_report(bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION derm.get_visit_report(p_visit_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_public_id     text;
  v_client_id     bigint;
  v_derm_required boolean;
  v_out           jsonb;
BEGIN
  perform hr.fn_require_app('derm_tracker', 'view');   -- 2026-10-20_1700 access phase 4
  IF nullif(current_setting('request.jwt.claims', true), '') IS NOT NULL
     AND coalesce(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION 'authentication required' USING errcode = '28000';
    END IF;
    IF lower(coalesce(auth.jwt() ->> 'email', '')) NOT LIKE '%@ayache.com'
       AND lower(coalesce(auth.jwt() ->> 'email', '')) NOT LIKE '%@unclogme.com' THEN
      RAISE EXCEPTION 'not a staff account' USING errcode = '42501';
    END IF;
  END IF;

  SELECT v.public_id, v.client_id, coalesce(v.derm_required, true)
    INTO v_public_id, v_client_id, v_derm_required
    FROM public.visits v
   WHERE v.id = p_visit_id
     AND v.deleted_at IS NULL
     AND v.visit_status = 'completed'
     AND v.client_id IS NOT NULL;
  IF v_public_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_out := customer.get_work_order_internal(v_public_id);
  IF v_out IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN v_out || jsonb_build_object(
    'client', (SELECT to_jsonb(c) FROM customer.clients c
                WHERE c.id = customer.uuid_from_bigint(v_client_id)
                LIMIT 1),  -- ponytail: LIMIT 1 guards a future duplicate row in customer.clients (0 today)
    'derm_required', v_derm_required);
END
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'c96f2d3cb1175f838f12ce95527b4245' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'derm.get_visit_report(bigint)'; END IF;
  IF md5(pg_get_functiondef('derm.get_visit_report(bigint)'::regprocedure)) <> '496e4fe9ca43641e8bb9f85bd4c22a8a' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'derm.get_visit_report(bigint)'; END IF;
  EXECUTE d;
  -- client.schedule_property_intake(bigint,text[],jsonb,text)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.schedule_property_intake(p_property_id bigint, p_requested text[], p_form_snapshot jsonb DEFAULT NULL::jsonb, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id bigint;
  v_token text;
  v_exp   timestamptz;
  v_bad text[];
  v_valid text[];
  v_req text[];
  v_dropped text[];
  v_added text[];
  v_snapshot jsonb := coalesce(p_form_snapshot, public.fn_intake_form_current());
begin
  perform hr.fn_check_app('client_app', 'edit', 'schedule an intake form');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_property_id is null then
    raise exception 'p_property_id is required' using errcode = '22023';
  end if;
  -- 2026-09-27: every intake uses the current form. A custom question list could pin any tree (a probe stored
  -- version 99 with an HTML label); no caller passes one (the Client App never does, the test fixture inserts).
  if p_form_snapshot is not null then
    raise exception 'A site survey form always uses the current questions.'
      using errcode = '22023', detail = 'blocker=custom_form in client.schedule_property_intake';
  end if;
  if p_requested is null or array_length(p_requested, 1) is null then
    raise exception 'pick at least one question to collect' using errcode = '22023';
  end if;
  if jsonb_typeof(v_snapshot) <> 'object' or not (v_snapshot ? 'sections') then
    raise exception 'the form definition is not valid' using errcode = '22023';
  end if;

  perform 1 from public.properties
   where id = p_property_id and deleted_at is null and coalesce(is_billing, false) = false;
  if not found then
    raise exception 'This property was removed or is a billing address, so it cannot get a site survey form.'
      using errcode = 'P0002', detail = format('blocker=not_a_service_property in client.schedule_property_intake (property %s)', p_property_id);
  end if;

  -- Every requested key must exist as an L2 question in the pinned tree. A typo'd key
  -- can never be answered, so the intake would sit at Incomplete for ever with no way
  -- to tell a typo from a lazy collector.
  select array_agg(q ->> 'key') into v_valid
  from jsonb_array_elements(v_snapshot -> 'sections') s,
       jsonb_array_elements(s -> 'questions') q;

  select array_agg(k) into v_bad
  from unnest(p_requested) k
  where k is null or btrim(k) = '' or v_valid is null or k <> all (v_valid);   -- a NULL or blank key is unknown too
  if v_bad is not null then
    raise exception 'unknown question key(s) for this form: %', v_bad using errcode = '22023';
  end if;

  -- A follow-up is asked only together with the question it depends on (fourth review, 2026-09-24).
  -- The dialog unchecks a question whose value we already hold, and an empty "key=" condition reads a
  -- parent that was never asked as blank, so "Measurements, if the gallons are not written anywhere"
  -- was being asked of every property whose gallons the office already has. Dropped here, once, for
  -- every caller; the stored set is the one the form, the status and the office all read.
  -- ...and (fifth review) an optional question is asked together with its ALTERNATIVE, the question
  -- shown when it is left blank ("key="), or a blank gallons answer would read Complete with no capacity.
  v_req := public.fn_intake_normalise_requested(v_snapshot, p_requested);
  select array_agg(k) into v_added from unnest(v_req) k where not coalesce(k = any (p_requested), false);
  select array_agg(k) into v_dropped from unnest(p_requested) k where not coalesce(k = any (v_req), false);
  -- Any follow-up whose parent was not ticked is refused in words, naming it (eighth review: a follow-up
  -- sent next to a required question used to be pruned silently and only reported in `dropped`).
  if v_dropped is not null then
    raise exception 'Pick the question each follow-up depends on as well.'
      using errcode = '22023', detail = 'blocker=followups_only in client.schedule_property_intake: ' || array_to_string(v_dropped, ', ');
  end if;
  -- A request of only optional questions reads Complete with nothing answered (sixth review).
  if not exists (select 1 from unnest(v_req) k
                  join lateral (select q from jsonb_array_elements(v_snapshot -> 'sections') s, jsonb_array_elements(s -> 'questions') q
                                 where q ->> 'key' = k limit 1) qq on true
                 where coalesce(qq.q -> 'optional', 'false'::jsonb) <> 'true'::jsonb) then
    raise exception 'Pick at least one question that is not optional.'
      using errcode = '22023', detail = 'blocker=optional_only in client.schedule_property_intake';
  end if;

  insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
  values (p_property_id, v_snapshot, to_jsonb(v_req), auth.jwt() ->> 'email')
  returning id, token, expires_at into v_id, v_token, v_exp;

  -- The bare token is no longer returned (2026-09-27): the Client App uses url only since CA1, and the token
  -- belongs in one place. expires_at lets the office see when the link stops working.
  return jsonb_build_object('ok', true, 'intake_id', v_id, 'url', public.fn_intake_link_url(v_token), 'expires_at', v_exp,
                            'requested', to_jsonb(v_req), 'dropped', to_jsonb(coalesce(v_dropped, '{}'::text[])), 'added', to_jsonb(coalesce(v_added, '{}'::text[])),
                            'form_version', v_snapshot -> 'version', 'note', p_note);
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '9eb7ee555c958bf1dc9af252270c4466' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.schedule_property_intake(bigint,text[],jsonb,text)'; END IF;
  IF md5(pg_get_functiondef('client.schedule_property_intake(bigint,text[],jsonb,text)'::regprocedure)) <> '31e0bea77455f44d141de45ac05b3613' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.schedule_property_intake(bigint,text[],jsonb,text)'; END IF;
  EXECUTE d;
  -- client.page_builder_list()
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.page_builder_list()
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
  perform hr.fn_require_app('picture_planner', 'view');   -- 2026-10-20_1600 access phase 3
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
    -- the newest version still waiting: not approved, not rejected, submitted after the live one (2026-10-21)
    left join lateral (select x.* from public.property_pages x
                        where x.property_id = p.id and x.approved_at is null and x.rejected_at is null
                          and x.version > coalesce(lv.version, 0)
                        order by x.version desc limit 1) pv on true
    left join lateral (select o.opened_at, o.staff from public.property_page_opens o
                        where o.property_id = p.id order by o.opened_at desc limit 1) lo on true
    left join public.property_page_links l on l.property_id = p.id
   where nullif(btrim(c.client_code), '') is not null
   order by c.client_code, p.id;
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '3ef567b9cc0697b881cefbe8f6bff7e7' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.page_builder_list()'; END IF;
  IF md5(pg_get_functiondef('client.page_builder_list()'::regprocedure)) <> 'd683094a89d44de0c8795d8d725e5d03' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.page_builder_list()'; END IF;
  EXECUTE d;
  -- client.get_page_versions(bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.get_page_versions(p_property_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_appr  boolean;
  v_self  boolean;
  v_block text;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_page_versions';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_page_versions';
  end if;
  perform hr.fn_require_app('picture_planner', 'view');   -- 2026-10-20_1600 access phase 3
  if p_property_id is null then
    raise exception 'No property was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_property in client.get_page_versions';
  end if;

  -- Who may decide a waiting version (2026-10-21): the same rules as approve_property_page and get_page_builder.
  v_appr := coalesce(v_uid = any (public.fn_page_approver_ids()), false);
  v_self := coalesce(v_uid = any (public.fn_page_self_approver_ids()), false);
  v_block := public.fn_page_blocker(p_property_id);

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
             'rejected_at', v.rejected_at, 'reject_reason', v.reject_reason,
             'rejected_by_name', case when v.rejected_at is not null then public.fn_page_staff_name(v.rejected_by_email) end,
             'replaced_by_version', r.version, 'replaced_at', r.at,
             'can_approve', s.status = 'waiting' and ab.b is null,
             'approve_blocker', case when s.status = 'waiting' then ab.b end,
             'can_reject', s.status = 'waiting' and v_appr,
             'restored_from_version', v.restored_from_version, 'source', v.source)
           order by v.version desc)
      from v
      cross join lateral (select case
               when v.approved_at is not null and v.version = v.live_version then 'live'
               when v.approved_at is not null then 'replaced'
               when v.rejected_at is not null then 'rejected'
               when v.version > coalesce(v.live_version, 0) then 'waiting'   -- every version after the live one (2026-10-21)
               else 'superseded' end as status) s
      -- why this caller cannot approve a waiting version (null: they can); own versions may still be rejected
      cross join lateral (select case
               when not v_appr then 'Only ' || public.fn_page_approver_names() || ' can approve a page.'
               when v.submitted_by = v_uid and not v_self then 'You submitted this version, so another person has to approve it.'
               else v_block end as b) ab
      -- replaced and superseded: the next APPROVED version and when it was approved (a superseded version was passed over
      -- when a later one went live, 2026-10-21)
      left join lateral (
        select n.version, n.approved_at as at
          from public.property_pages n
         where s.status in ('replaced', 'superseded')
           and n.property_id = v.property_id and n.version > v.version
           and n.approved_at is not null
         order by n.version
         limit 1) r on true), '[]'::jsonb);
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'd88274d110ee3b06772f94a38b4683df' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.get_page_versions(bigint)'; END IF;
  IF md5(pg_get_functiondef('client.get_page_versions(bigint)'::regprocedure)) <> '944b46969a1dbea4ac660503f82aa047' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.get_page_versions(bigint)'; END IF;
  EXECUTE d;
  -- client.cancel_intake(bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.cancel_intake(p_intake_id bigint)
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
  perform hr.fn_check_any_app(array['picture_planner', 'client_app'], 'edit', 'cancel a form');   -- 2026-10-20_1600 access phase 3; 2026-10-21_0900 access phase 5: the Client App cancels a link too
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
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '8066015873538f8a5bbbb62f8c617516' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.cancel_intake(bigint)'; END IF;
  IF md5(pg_get_functiondef('client.cancel_intake(bigint)'::regprocedure)) <> '6bd93ebe34b074f0bddb9d00678450a7' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.cancel_intake(bigint)'; END IF;
  EXECUTE d;
  -- derm_link_visits(bigint,bigint[])
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION public.derm_link_visits(p_manifest_id bigint, p_visit_ids bigint[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-20_1700 access phase 4: a DERM Tracker write that the browser made directly on the table, now behind
-- DERM Tracker's own checked action (Edit). SECURITY DEFINER widens nothing: authenticated already holds this
-- write with an unrestricted policy (measured 2026-10-20). Every table trigger still fires as before.
declare v_n integer;
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in public.derm_link_visits';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@ayache.com' and lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in public.derm_link_visits';
  end if;
  perform hr.fn_check_app('derm_tracker', 'edit', 'link visits to a manifest');
  insert into public.manifest_visits (manifest_id, visit_id)
  select p_manifest_id, v from unnest(coalesce(p_visit_ids, '{}'::bigint[])) v;
  get diagnostics v_n = row_count;
  return v_n;
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '7c18955b347863cecc3b6e69a2be0df6' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'derm_link_visits(bigint,bigint[])'; END IF;
  IF md5(pg_get_functiondef('derm_link_visits(bigint,bigint[])'::regprocedure)) <> '97e10d063363114489039f27ce2ce280' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'derm_link_visits(bigint,bigint[])'; END IF;
  EXECUTE d;
  -- derm_set_manifest_photos(bigint,text,text,text[],text[])
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION public.derm_set_manifest_photos(p_manifest_id bigint, p_manifest_url text, p_address_url text, p_manifest_extra_urls text[], p_address_extra_urls text[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-20_1700 access phase 4: a DERM Tracker write that the browser made directly on the table, now behind
-- DERM Tracker's own checked action (Edit). SECURITY DEFINER widens nothing: authenticated already holds this
-- write with an unrestricted policy (measured 2026-10-20). Every table trigger still fires as before.
declare v_n integer;
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in public.derm_set_manifest_photos';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@ayache.com' and lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in public.derm_set_manifest_photos';
  end if;
  perform hr.fn_check_app('derm_tracker', 'edit', 'save manifest photos');
  update public.derm_manifests
     set derm_manifest_url = p_manifest_url, derm_address_url = p_address_url,
         derm_manifest_extra_urls = p_manifest_extra_urls, derm_address_extra_urls = p_address_extra_urls
   where id = p_manifest_id;
  get diagnostics v_n = row_count;
  return v_n;
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '6dc881d23d2492de3acf2af5ff4b17fa' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'derm_set_manifest_photos(bigint,text,text,text[],text[])'; END IF;
  IF md5(pg_get_functiondef('derm_set_manifest_photos(bigint,text,text,text[],text[])'::regprocedure)) <> '607b0adc2e43345e6097a44b517851ab' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'derm_set_manifest_photos(bigint,text,text,text[],text[])'; END IF;
  EXECUTE d;
  -- client.delete_client_contact(bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.delete_client_contact(p_contact_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_row public.client_contacts;
begin
  perform hr.fn_check_app('client_app', 'edit', 'delete a contact');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_contact_id is null then
    raise exception 'p_contact_id is required' using errcode = '22023';
  end if;

  select * into v_row from public.client_contacts where id = p_contact_id;
  if not found then
    raise exception 'contact % not found', p_contact_id using errcode = 'P0002';
  end if;

  if v_row.property_id is null and v_row.contact_role = 'primary' then
    raise exception 'This is the client''s main contact and it comes from Jobber, so deleting it here would not stick — the next sync re-creates it within about five minutes. Clear its email and phone instead, which updates Jobber too.'
      using errcode = '42501';
  end if;

  delete from public.client_contacts where id = p_contact_id;

  return jsonb_build_object(
    'deleted_id',   v_row.id,
    'client_id',    v_row.client_id,
    'contact_role', v_row.contact_role,
    'property_id',  v_row.property_id,
    'email',        v_row.email,
    'phone',        v_row.phone
  );
end;
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '05d819b6f17e92a9e93ca9c6178d356e' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.delete_client_contact(bigint)'; END IF;
  IF md5(pg_get_functiondef('client.delete_client_contact(bigint)'::regprocedure)) <> '919357004d593b3d8671934d3d6fd52c' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.delete_client_contact(bigint)'; END IF;
  EXECUTE d;
  -- client.update_client_fields(bigint,jsonb)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.update_client_fields(p_client_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array['notes','group_id','client_class'];
  v_bad     text[];
  v_row     public.clients;
begin
  perform hr.fn_check_app('client_app', 'edit', 'edit client fields');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_client_id is null then
    raise exception 'p_client_id is required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for clients: %. Allowed: %',
      v_bad, v_allowed using errcode = '22023';
  end if;

  if p_patch ? 'group_id' and nullif(p_patch->>'group_id','') is not null then
    if not exists (select 1 from public.client_groups g
                   where g.id = (p_patch->>'group_id')::bigint) then
      raise exception 'client_groups id % does not exist', p_patch->>'group_id'
        using errcode = '23503';
    end if;
  end if;

  -- client_class: a human assertion. Value is strict (no NULL — unclassifying
  -- from the app is not a thing); the write pins the row as manual so the
  -- Jobber poll can never flip it back (trg_clients_protect_manual_class).
  if p_patch ? 'client_class' then
    if coalesce(p_patch->>'client_class','') not in ('commercial','residential') then
      raise exception 'client_class must be ''commercial'' or ''residential'''
        using errcode = '22023';
    end if;
    -- Two-step past the guard: on an already-manual row a single UPDATE that
    -- changes class while keeping source='manual' is SILENTLY reverted by
    -- fn_clients_protect_manual_class. Flip source first (class untouched →
    -- passes), then the main UPDATE sets class + re-pins manual.
    update public.clients
       set client_class_source = 'jobber'
     where id = p_client_id and client_class_source = 'manual';
  end if;

  update public.clients c set
    notes    = case when p_patch ? 'notes'
                    then nullif(p_patch->>'notes','') else c.notes end,
    group_id = case when p_patch ? 'group_id'
                    then nullif(p_patch->>'group_id','')::bigint else c.group_id end,
    client_class = case when p_patch ? 'client_class'
                        then p_patch->>'client_class' else c.client_class end,
    client_class_source = case when p_patch ? 'client_class'
                               then 'manual' else c.client_class_source end
  where c.id = p_client_id
  returning c.* into v_row;

  if not found then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;

  return to_jsonb(v_row);
end;
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> '45f7cd0f2c413675e1aa4eacb38c96ba' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.update_client_fields(bigint,jsonb)'; END IF;
  IF md5(pg_get_functiondef('client.update_client_fields(bigint,jsonb)'::regprocedure)) <> '544d6bfcb178e5c4add68b151065ee10' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.update_client_fields(bigint,jsonb)'; END IF;
  EXECUTE d;
  -- client.update_client_zone(bigint,bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.update_client_zone(p_client_id bigint, p_zone_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_n    integer;
  v_code text;
begin
  perform hr.fn_check_app('client_app', 'edit', 'change client zone');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_client_id is null then
    raise exception 'p_client_id is required' using errcode = '22023';
  end if;
  if not exists (select 1 from public.clients c where c.id = p_client_id) then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;
  if p_zone_id is not null then
    select z.code into v_code from public.zones z where z.id = p_zone_id;
    if v_code is null then
      raise exception 'zones id % does not exist', p_zone_id using errcode = '23503';
    end if;
  end if;

  update public.properties p
     set zone_id = p_zone_id
   where p.client_id = p_client_id
     and p.zone_id is distinct from p_zone_id;
  get diagnostics v_n = row_count;

  return jsonb_build_object(
    'client_id', p_client_id,
    'zone_id', p_zone_id,
    'zone_code', v_code,
    'properties_updated', v_n);
end;
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'bef564934f1686435e5fc998f13e18ba' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.update_client_zone(bigint,bigint)'; END IF;
  IF md5(pg_get_functiondef('client.update_client_zone(bigint,bigint)'::regprocedure)) <> '21c26db2a0b07f2b39ca93484a3aeb38' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.update_client_zone(bigint,bigint)'; END IF;
  EXECUTE d;
  -- client.preview_client_status_change(bigint,text)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION client.preview_client_status_change(p_client_id bigint, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_old  text;
  v_will boolean;
  v_n    int := 0;
  v_sc   int := 0;
  v_sa   bigint[];
begin
  perform hr.fn_require_app('client_app', 'view');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;

  select c.status into v_old from public.clients c where c.id = p_client_id;
  if v_old is null then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;

  v_will := (v_old = 'RECURRING' and p_status <> 'RECURRING')
         or (p_status in ('INACTIVE','PAUSED') and v_old not in ('INACTIVE','PAUSED'));

  if v_will then
    select count(*) into v_n
      from public.visits v
     where v.client_id = p_client_id and v.deleted_at is null
       and v.visit_status = 'scheduled' and v.visit_date >= current_date
       and exists (select 1 from public.jobs j
                    where j.id = v.job_id and j.title ilike 'Service Agreement%');
    select count(*) into v_sc
      from public.visits v
     where v.client_id = p_client_id and v.deleted_at is null
       and v.visit_status = 'scheduled' and v.visit_date >= current_date
       and not exists (select 1 from public.jobs j
                    where j.id = v.job_id and j.title ilike 'Service Agreement%');
  end if;

  v_sa := client.fn_client_live_sa_jobs(p_client_id);

  return jsonb_build_object(
    'current_status', v_old,
    'new_status', p_status,
    'will_clean_up', v_will,
    'sa_visits_to_remove', v_n,
    'service_call_visits_kept', v_sc,

    -- Does this client actually hold a live, current-format Service Agreement?
    'has_live_sa_job',  (cardinality(v_sa) > 0),
    'live_sa_job_ids',  to_jsonb(v_sa),

    -- CORRECTED 2026-09-08. Was `(v_will and p_status = 'ACTIVE')`, which never looked at
    -- the client and whose premise (the JS generator keying on ACTIVE OR RECURRING) has
    -- been dead since 2026-06-02. The live generator public.fn_generate_sa_visits requires
    -- c.status = 'RECURRING', so an ACTIVE client is never regenerated, by any path.
    -- Kept as a key so the deployed app does not break on a missing field.
    'reschedules_unless_job_closed', false,

    -- The honest warning: leaving RECURRING with a real SA in hand STOPS generation.
    -- This is what stranded 084-ULT and 201-ALA.
    'stops_sa_generation',
      (v_will and p_status <> 'RECURRING' and cardinality(v_sa) > 0)
  );
end;
$function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'c29cc26015e228808c4596e2f7049c71' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'client.preview_client_status_change(bigint,text)'; END IF;
  IF md5(pg_get_functiondef('client.preview_client_status_change(bigint,text)'::regprocedure)) <> '999fd7c7ecd7e303ecc940d4b8f95f9f' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'client.preview_client_status_change(bigint,text)'; END IF;
  EXECUTE d;
  -- set_visit_status(bigint,text,text)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION public.set_visit_status(p_visit_id bigint, p_status text, p_reason text DEFAULT NULL::text)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_row public.visits; v_email text;
BEGIN
  perform hr.fn_check_app('visit_calendar', 'edit', 'change a visit status');   -- 2026-10-21_0900 access phase 5
  -- AUTH: logged-in staff only (@ayache.com / @unclogme.com). Defense-in-depth over the
  -- authenticated-only EXECUTE grant so even a mis-grant can't let the public anon key through.
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'set_visit_status requires a logged-in staff user' USING ERRCODE='insufficient_privilege';
  END IF;
  v_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  IF v_email NOT LIKE '%@ayache.com' AND v_email NOT LIKE '%@unclogme.com' THEN
    RAISE EXCEPTION 'set_visit_status: % is not a staff account', v_email USING ERRCODE='insufficient_privilege';
  END IF;

  IF p_status NOT IN ('completed','scheduled','skipped','cancelled') THEN
    RAISE EXCEPTION 'set_visit_status: unsupported status %', p_status USING ERRCODE='check_violation';
  END IF;

  SELECT * INTO v_row FROM public.visits WHERE id = p_visit_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'visit % not found', p_visit_id; END IF;
  IF v_row.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'visit % is deleted', p_visit_id; END IF;

  IF p_status = 'completed' THEN
    IF v_row.visit_status <> 'scheduled' THEN
      RAISE EXCEPTION 'only a scheduled visit can be completed (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    UPDATE public.visits SET visit_status='completed', completed_at=now()
      WHERE id=p_visit_id RETURNING * INTO v_row;

  ELSIF p_status = 'scheduled' THEN  -- uncomplete ONLY (un-skip lives in unskip_visit)
    IF v_row.visit_status = 'skipped' THEN
      RAISE EXCEPTION 'visit % is skipped; use unskip_visit to restore it', p_visit_id USING ERRCODE='check_violation';
    ELSIF v_row.visit_status <> 'completed' THEN
      RAISE EXCEPTION 'only a completed visit can be un-completed (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    UPDATE public.visits SET visit_status='scheduled', completed_at=NULL
      WHERE id=p_visit_id RETURNING * INTO v_row;

  ELSIF p_status = 'skipped' THEN
    IF v_row.visit_status <> 'scheduled' THEN
      RAISE EXCEPTION 'only a scheduled visit can be skipped (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    UPDATE public.visits
       SET visit_status='skipped',
           skip_reason=NULLIF(btrim(coalesce(p_reason,'')),''),
           source=CASE WHEN source IN ('visit-calendar','supabase_cron') THEN source ELSE 'visit-calendar' END
     WHERE id=p_visit_id RETURNING * INTO v_row;
    PERFORM public.fn_promote_next_sa_occurrence(v_row.job_id);

  ELSE  -- 'cancelled'
    IF v_row.visit_status <> 'scheduled' THEN
      RAISE EXCEPTION 'only a scheduled visit can be cancelled (visit % is %)', p_visit_id, v_row.visit_status USING ERRCODE='check_violation';
    END IF;
    -- cancel == skip in Jobber: the AFTER push trigger deletes THIS occurrence (visit_status IN
    -- (cancelled,skipped) -> op='delete'); normalizing source makes that delete fire + bypass the
    -- origin gate, exactly as skip does. Reason not stored (no cancel_reason column in Phase 1).
    UPDATE public.visits
       SET visit_status='cancelled',
           source=CASE WHEN source IN ('visit-calendar','supabase_cron') THEN source ELSE 'visit-calendar' END
     WHERE id=p_visit_id RETURNING * INTO v_row;
    PERFORM public.fn_promote_next_sa_occurrence(v_row.job_id);
  END IF;

  RETURN v_row;
END; $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'da2537ed992ce9ec3eced7dc8e71145c' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'set_visit_status(bigint,text,text)'; END IF;
  IF md5(pg_get_functiondef('set_visit_status(bigint,text,text)'::regprocedure)) <> 'c69367b74ebdb18820560cdb2ebc5bbe' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'set_visit_status(bigint,text,text)'; END IF;
  EXECUTE d;
  -- ops.link_day_marker_dump_visit(bigint,bigint)
  d := replace(replace($rb$CREATE OR REPLACE FUNCTION ops.link_day_marker_dump_visit(p_marker_id bigint, p_dump_visit_id bigint)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- -- 2026-10-21_0900 access phase 5: the Calendar linked a dump marker to its dump visit with a direct column write
-- (authenticated holds UPDATE on dump_visit_id only, policy calendar_day_markers_rw USING true). Now behind Edit in the
-- Calendar. SECURITY DEFINER widens nothing: it writes that one column, as before.
declare v_n integer;
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in ops.link_day_marker_dump_visit';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@ayache.com' and lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in ops.link_day_marker_dump_visit';
  end if;
  perform hr.fn_check_app('visit_calendar', 'edit', 'link a dump visit to its marker');
  update ops.calendar_day_markers set dump_visit_id = p_dump_visit_id where id = p_marker_id;
  get diagnostics v_n = row_count;
  return v_n;
end $function$
$rb$, chr(13), ''), '<<CR>>', chr(13));
  IF md5(d) <> 'bc7391423dda4c71fa904d9e083af941' THEN RAISE EXCEPTION 'rollback: copy of % is not the pre-2000 body', 'ops.link_day_marker_dump_visit(bigint,bigint)'; END IF;
  IF md5(pg_get_functiondef('ops.link_day_marker_dump_visit(bigint,bigint)'::regprocedure)) <> '1bb51bbfaad27de6762ec301c931fd56' THEN RAISE EXCEPTION 'rollback: % changed after 2000', 'ops.link_day_marker_dump_visit(bigint,bigint)'; END IF;
  EXECUTE d;
END $r$;

DROP FUNCTION public.fn_is_staff_email(text);
NOTIFY pgrst, 'reload schema';
COMMIT;
