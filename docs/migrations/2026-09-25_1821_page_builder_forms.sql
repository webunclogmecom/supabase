-- ============================================================================
-- 2026-09-25_1821_page_builder_forms.sql (applied 2026-09-25_1821 ET)
-- 2026-09-25 · The Page Builder reads every submitted site survey form of its property, rule 14 applied
-- ============================================================================
-- Fred, 2026-09-25:
--   "also we need to have a way to fill the Builder Phase with the data from the intake forms (complete or
--    incomplete) we need to have a way to show that there and fill the data using those forms"
--
-- 1. client.get_page_builder_forms(p_property_id bigint) -> jsonb array, newest first, one element per
--    SUBMITTED, not cancelled intake form of the property (Complete or Incomplete):
--      {intake_id, submitted_at, collector, status, answered_count, applicable_count,
--       not_shown_count, answers: {question_key: value}, photos: [{photo_id, question_key}]}
--    A staff JWT only: the same STAFF gate and words as client.get_page_builder (plain sentence in MESSAGE,
--    blocker=<code> in DETAIL). It does NOT repeat get_page_builder's removed / billing property refusals:
--    the builder calls get_page_builder first and stops there, staff can already read any intake through
--    client.get_intake, and 0 intakes sit on a removed or billing property (measured 2026-09-25).
--    EXECUTE revoked from public and anon, granted to authenticated only.
--    It READS ONLY. It replaces the builder's second call (client.get_intake on the newest form), so the
--    Planner has ONE source of form values, already filtered:
--    - WHICH forms: client.v_intake_submissions with state = 'submitted' (called, not copied). That view
--      already leaves out cancelled forms and never expires a submitted one; awaiting forms hold no answers.
--    - status / answered_count / applicable_count: the same view columns, so the ONE completeness rule
--      (public.fn_intake_missing, reference rule 12) is called, never re-implemented.
--    - answers: only REQUESTED keys whose question the collector was SHOWN (public.fn_intake_applicable)
--      and ANSWERED (public.fn_intake_answered). Reference rule 14 at the consumer: the raw submission is
--      never rewritten. The live builder ignored `applicable` (its prefill, its "Site survey says" lines
--      and its pins button could all offer an abandoned lock-box code); this closes that for every
--      builder read at once. An answer to a question of TYPE 'photos' (read from the form's own snapshot,
--      not guessed from the value's JSON type, so a later array-valued question is not dropped silently)
--      is left out: photos come as ids.
--    - photos: only ids from public.fn_page_photo_ids(property), i.e. EXACTLY the set submit accepts (D8:
--      bucket by link kind, strict path, file exists), of this form, under a requested question that was
--      shown, AND whose path is in that question's SUBMITTED answer. intake-submit builds the answer from
--      the live links at submit, so a link whose attach was already past its token check and landed after
--      the submit (the same race reference rule 20 notes for cancel) is not part of what the collector
--      sent and is not offered. No caption: fn_page_photo_ids
--      blanks intake captions on purpose, so the collector's raw text can never reach a page anyone with
--      the link can open.
--    - not_shown_count: answered keys the collector was NOT shown in the end. The builder says how many
--      were held back and links to /forms/<id>, which labels them "Not shown to the collector".
--    - Never the collector link: the intake's secret column is not read at all (VERIFY 6c compares).
--    - Unknown property id -> [] (the builder has already loaded the property through get_page_builder).
--
-- 2. Decisions (each is one sentence from Fred to change):
--    - Filling writes the builder's DRAFT only (browser state + pp-draft localStorage). Nothing here
--      writes, and the Planner still never writes a property fact (Picture Planner rules 5 and 8;
--      accepting answers into the property stays the Client App's job).
--    - EXCEPT PINS, which have no draft: the map saves itself to properties.site_map through
--      client.update_property_site_map, as it does today. "Use this form's pins" stays a separate,
--      explicit button, never part of "Fill empty fields".
--    - get_page_builder is NOT replaced: its 8 KB body would have to be copied whole for data a second
--      read already serves, and its `intake` key keeps meaning "the latest submitted form".
--
-- 3. VERIFY 8 pins the premise of Planner prompt B0 item (1): a map save moves public.fn_page_source,
--    so a submit that sends the source loaded when the builder opened is refused blocker=source_changed
--    (40001), and the same submit with the saved map folded into that source is accepted. It was read
--    from the code before; this proves it. The Planner must refresh its baseline after its own map save.
--    (B0 is independent of this function and may ship before it; B1 needs this function live.)
--
-- Rule 8 (audit): no new table; the function writes nothing. Grants: revoked by name, whole proacl
-- asserted, and the read-only roles checked. ATOMIC: no COMMIT. The VERIFY's writes (test intakes, test
-- photo rows, a map save and a page submit) run inside a sentinel sub-block and are rolled back; VERIFY 9
-- checks the rows it created by id, not whole-table counts (a real field photo landing during the apply
-- must not read as "test rows survived").
--
-- SHIP WITH, same cycle (workspace CLAUDE.md 4b):
--   - Building Apps/Picture Planner/CLAUDE.md rule 5 (the builder reads client.get_page_builder_forms and
--     never client.get_intake) and rule 8 (B0: the submit baseline is refreshed after the builder's own
--     map save; Yes/No facts are stored as "yes"/"no").
--   - Supabase/docs/reference/client-intake-system.md rule 14 (a new consumer that honours "shown", plus
--     the submitted-path test for photos) and rule 18 (the builder's baseline after its own map save).
--   - Building Apps/Picture Planner/docs/08-changelog.md entries for B0, B1 and B2;
--     Building Apps/docs/client-intake-flow.md sections 9.4 and 13.3.
-- ============================================================================

-- ----------------------------------------------------------------- 0. the bodies this relies on are the ones we read
do $pin$
begin
  if md5(pg_get_functiondef('client.get_page_builder(bigint)'::regprocedure)) <> '17a68767dcc8060f78529783f3cf29fb' then
    raise exception 'PIN: client.get_page_builder changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('client.submit_property_page(bigint,jsonb,integer,integer,jsonb)'::regprocedure)) <> '4c7ad1ee1ec69fdf2c55d2ce68e7253b' then
    raise exception 'PIN: client.submit_property_page changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('public.fn_page_source(bigint)'::regprocedure)) <> 'cce019df417094afe2e67ef15681f037' then
    raise exception 'PIN: public.fn_page_source changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('public.fn_page_photo_ids(bigint)'::regprocedure)) <> 'a776b3bc150fcfa3e505d63a770ba67b' then
    raise exception 'PIN: public.fn_page_photo_ids changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('client.update_property_site_map(bigint,jsonb,integer)'::regprocedure)) <> '9a1055daa9b62ac6b3bb3cc50291235a' then
    raise exception 'PIN: client.update_property_site_map changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('public.fn_intake_applicable(jsonb,jsonb,text)'::regprocedure)) <> 'a28ac207c1aab383da525bc78ef52184'
     or md5(pg_get_functiondef('public.fn_intake_answered(jsonb,text)'::regprocedure)) <> '9ed2efa94e9a2b703491b1c53e404571' then
    raise exception 'PIN: fn_intake_applicable or fn_intake_answered changed since this migration was written';
  end if;
  if md5(pg_get_viewdef('client.v_intake_submissions'::regclass)) <> 'e1e26ccf880bff26722517406262dd36' then
    raise exception 'PIN: client.v_intake_submissions changed since this migration was written';
  end if;
end $pin$;

-- ----------------------------------------------------------------- 1. every submitted form of a property, filtered for the builder
create function client.get_page_builder_forms(p_property_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
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
comment on function client.get_page_builder_forms(bigint) is
  'Every submitted, not cancelled site survey form of a property for the Picture Planner Page Builder, newest first: status and counts from client.v_intake_submissions, answers only for requested questions the collector was SHOWN and answered (reference rule 14), photo ids only from fn_page_photo_ids (what submit accepts), no captions, no collector link. Staff JWT only. Reads only; the builder fills its own draft.';
revoke all on function client.get_page_builder_forms(bigint) from public, anon;
grant execute on function client.get_page_builder_forms(bigint) to authenticated;

-- ----------------------------------------------------------------- 2. VERIFY
do $verify$
declare
  v_fred     uuid;
  v_r        jsonb;
  v_f        jsonb;
  v_pb       jsonb;
  v_map      jsonb;
  v_state    text; v_detail text;
  v_snap     jsonb := public.fn_intake_form_current();
  v_req      jsonb;
  v_sub bigint; v_old bigint; v_cxl bigint; v_exp bigint; v_other bigint; v_await bigint;
  v_ph_ok bigint; v_ph_hidden bigint; v_ph_late bigint;
  v_u1       text := gen_random_uuid()::text;
  v_u2       text := gen_random_uuid()::text;
  v_u3       text := gen_random_uuid()::text;
  v_keys     text[];
  v_ids      bigint[];
  v_n        int;
  v_t        text;
  v_ver0     int    := (select coalesce(max(version), 0) from public.property_pages where property_id = 1164);
  v_map0     jsonb  := (select site_map from public.properties where id = 1164);
begin
  select id into v_fred from auth.users where lower(email) = 'fred@ayache.com';
  if v_fred is null then raise exception 'VERIFY 0: fred@ayache.com is missing from auth.users'; end if;
  v_req := to_jsonb(public.fn_intake_normalise_requested(v_snap, (select array_agg(question_key) from client.v_intake_questions)));

  -- V1. Grants and flags.
  if (select coalesce(p.proacl::text, 'NULL') from pg_proc p where p.oid = 'client.get_page_builder_forms(bigint)'::regprocedure)
     <> '{postgres=X/postgres,authenticated=X/postgres}' then
    raise exception 'VERIFY 1a: get_page_builder_forms proacl is %',
      (select p.proacl::text from pg_proc p where p.oid = 'client.get_page_builder_forms(bigint)'::regprocedure);
  end if;
  foreach v_t in array array['anon', 'service_role', 'yannick_readonly', 'pg_read_all_data', 'supabase_read_only_user'] loop
    if has_function_privilege(v_t, 'client.get_page_builder_forms(bigint)', 'EXECUTE') then
      raise exception 'VERIFY 1b: % can execute client.get_page_builder_forms', v_t;
    end if;
  end loop;
  if not has_function_privilege('authenticated', 'client.get_page_builder_forms(bigint)', 'EXECUTE') then
    raise exception 'VERIFY 1b: authenticated cannot execute client.get_page_builder_forms';
  end if;
  if not coalesce((select p.prosecdef and p.provolatile = 's' and 'search_path=""' = any (p.proconfig)
                     from pg_proc p where p.oid = 'client.get_page_builder_forms(bigint)'::regprocedure), false) then
    raise exception 'VERIFY 1c: get_page_builder_forms is not SECURITY DEFINER, STABLE and search_path pinned to empty';
  end if;
  -- 1d. The rules are CALLED: a later retype that drops one fails here (the data tests below catch the rest).
  if pg_get_functiondef('client.get_page_builder_forms(bigint)'::regprocedure) !~ 'client[.]v_intake_submissions'
     or pg_get_functiondef('client.get_page_builder_forms(bigint)'::regprocedure) !~ 'public[.]fn_intake_applicable'
     or pg_get_functiondef('client.get_page_builder_forms(bigint)'::regprocedure) !~ 'public[.]fn_page_photo_ids' then
    raise exception 'VERIFY 1d: get_page_builder_forms no longer calls the view, fn_intake_applicable or fn_page_photo_ids';
  end if;

  -- V2. The fixture: [TEST] intake 167 on 112-YA property 1164 (submitted, Incomplete, immutable, stays).
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  v_r := client.get_page_builder_forms(1164);
  reset role;
  select f into v_f from jsonb_array_elements(v_r) f where (f ->> 'intake_id')::bigint = 167;
  if v_f is null then raise exception 'VERIFY 2a: the submitted [TEST] form 167 is not listed for property 1164'; end if;
  select array_agg(k order by k collate "C") into v_keys from jsonb_object_keys(v_f -> 'answers') k;
  if v_keys is distinct from array['access_entry.gate', 'access_entry.gate_code', 'grease_trap.systems_count', 'site_map.truck_parking'] then
    raise exception 'VERIFY 2b: form 167 answers are %', v_keys;
  end if;
  if (v_f -> 'photos') is distinct from '[{"photo_id": 27404, "question_key": "access_entry.gate_photos"}]'::jsonb then
    raise exception 'VERIFY 2c: form 167 photos are %', v_f -> 'photos';
  end if;
  if not exists (select 1 from client.v_intake_submissions s
                  where s.intake_id = 167
                    and (v_f ->> 'status', (v_f ->> 'answered_count')::int, (v_f ->> 'applicable_count')::int)
                        is not distinct from (s.status, s.answered_count, s.applicable_count))
     or v_f ->> 'status' <> 'Incomplete' or (v_f ->> 'not_shown_count')::int <> 0
     or (v_f ->> 'collector') is distinct from '[TEST] collector' then
    raise exception 'VERIFY 2d: form 167 status or counts differ from client.v_intake_submissions';
  end if;
  -- 2e. The list is exactly the property's submitted, not cancelled forms, newest first (306 is awaiting).
  select array_agg((x.f ->> 'intake_id')::bigint order by x.ord) into v_ids from jsonb_array_elements(v_r) with ordinality x(f, ord);
  if v_ids is distinct from (select array_agg(i.id order by i.submitted_at desc, i.id desc) from public.property_intakes i
                              where i.property_id = 1164 and i.submitted_at is not null and i.cancelled_at is null) then
    raise exception 'VERIFY 2e: the listed forms are %', v_ids;
  end if;

  -- V3..V8 write test rows; the sentinel at the end rolls every one of them back.
  begin
    -- The main test form: awaiting first, so its photo paths can carry its id, then submitted.
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
    values (1164, v_snap, v_req, '[TEST] builder forms verify')
    returning id into v_sub;
    insert into public.photos (storage_path, content_type)
    values ('intake-photos/' || v_sub || '/' || v_u1 || '.png', 'image/png') returning id into v_ph_ok;
    insert into public.photos (storage_path, content_type)
    values ('intake-photos/' || v_sub || '/' || v_u2 || '.png', 'image/png') returning id into v_ph_hidden;
    -- A third photo linked under the SHOWN access question but NOT in its submitted answer: an attach that
    -- landed after the submit (the same race reference rule 20 notes for cancel). The pool carries it; the builder must not.
    insert into public.photos (storage_path, content_type)
    values ('intake-photos/' || v_sub || '/' || v_u3 || '.png', 'image/png') returning id into v_ph_late;
    insert into storage.objects (bucket_id, name)
    values ('intake-photos', v_sub || '/' || v_u1 || '.png'), ('intake-photos', v_sub || '/' || v_u2 || '.png'),
           ('intake-photos', v_sub || '/' || v_u3 || '.png');
    insert into public.photo_links (photo_id, entity_type, entity_id, role, caption)
    values (v_ph_ok, 'property_intake', v_sub, 'access_entry.access_photos', '[TEST] collector caption 7c1'),
           (v_ph_hidden, 'property_intake', v_sub, 'access_entry.lock_box_photos', null),
           (v_ph_late, 'property_intake', v_sub, 'access_entry.access_photos', null);
    -- The collector typed a lock-box code and photographed the lock box, then switched to Key; said the gate
    -- is closed with a code, then No; answered Inside/Kitchen, then Outside; typed a GT pin, then 0 traps.
    update public.property_intakes
       set collector = '[TEST] collector', submitted_at = now(),
           answers = jsonb_build_object(
             'access_entry.gate',               jsonb_build_object('value', 'no'),
             'access_entry.gate_code',          jsonb_build_object('value', '[TEST] 5555'),
             'access_entry.how_access',         jsonb_build_object('value', 'Key'),
             'access_entry.lock_box_code',      jsonb_build_object('value', '[TEST] 9999'),
             'access_entry.key_instruction',    jsonb_build_object('value', '[TEST] Key under the mat'),
             'access_entry.equipment_where',    jsonb_build_object('value', 'Outside'),
             'access_entry.where_inside',       jsonb_build_object('value', 'Kitchen'),
             'access_entry.where_outside',      jsonb_build_object('value', 'Other'),
             'access_entry.where_outside_note', jsonb_build_object('value', '[TEST] Behind the dumpster'),
             'access_entry.obstacles',          jsonb_build_object('value', ' '),
             'grease_trap.systems_count',       jsonb_build_object('value', 0),
             'site_map.gt_location',            jsonb_build_object('value', jsonb_build_object('lat', 25.8071, 'lng', -80.2065)),
             'access_entry.access_photos',      jsonb_build_object('value', jsonb_build_array(v_sub || '/' || v_u1 || '.png')),
             'access_entry.lock_box_photos',    jsonb_build_object('value', jsonb_build_array(v_sub || '/' || v_u2 || '.png')),
             'zz_test.not_asked',               jsonb_build_object('value', '[TEST] not asked'))
     where id = v_sub;
    -- Around it: an older submitted form, a submitted one whose link expired, a cancelled one, an awaiting
    -- one, and a submitted one on ANOTHER property (162).
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, submitted_at, answers, collector)
    values (1164, v_snap, v_req, '[TEST] builder forms verify', now() - interval '1 hour', '{}'::jsonb, '[TEST] older')
    returning id into v_old;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, submitted_at, answers, collector, expires_at)
    values (1164, v_snap, v_req, '[TEST] builder forms verify', now() - interval '2 hours', '{}'::jsonb, '[TEST] expired link', now() - interval '1 day')
    returning id into v_exp;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, submitted_at, answers, collector, cancelled_at)
    values (1164, v_snap, v_req, '[TEST] builder forms verify', now(), '{}'::jsonb, '[TEST] cancelled', now())
    returning id into v_cxl;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
    values (1164, v_snap, v_req, '[TEST] builder forms verify')
    returning id into v_await;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, submitted_at, answers, collector)
    values (162, v_snap, v_req, '[TEST] builder forms verify', now(), '{}'::jsonb, '[TEST] other property')
    returning id into v_other;

    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    v_r := client.get_page_builder_forms(1164);
    reset role;

    -- V3. Which forms, in which order.
    select array_agg((x.f ->> 'intake_id')::bigint order by x.ord) into v_ids from jsonb_array_elements(v_r) with ordinality x(f, ord);
    if v_ids[1] is distinct from v_sub then raise exception 'VERIFY 3a: the newest form is not first (%)', v_ids; end if;
    if not (v_old = any (v_ids) and v_exp = any (v_ids)) then
      raise exception 'VERIFY 3b: an older or expired-link submitted form is missing (%)', v_ids;
    end if;
    if v_cxl = any (v_ids) or v_await = any (v_ids) or v_other = any (v_ids) then
      raise exception 'VERIFY 3c: a cancelled, awaiting or other-property form is listed (%)', v_ids;
    end if;
    if v_ids is distinct from (select array_agg(i.id order by i.submitted_at desc, i.id desc) from public.property_intakes i
                                where i.property_id = 1164 and i.submitted_at is not null and i.cancelled_at is null) then
      raise exception 'VERIFY 3d: the list is not exactly the submitted, not cancelled forms, newest first (%)', v_ids;
    end if;

    -- V4. Rule 14: only requested questions that were SHOWN and answered; photos only under those.
    v_f := v_r -> 0;
    select array_agg(k order by k collate "C") into v_keys from jsonb_object_keys(v_f -> 'answers') k;
    if v_keys is distinct from array['access_entry.equipment_where', 'access_entry.gate', 'access_entry.how_access',
                                     'access_entry.key_instruction', 'access_entry.where_outside',
                                     'access_entry.where_outside_note', 'grease_trap.systems_count'] then
      raise exception 'VERIFY 4a: the test form answers are %', v_keys;
    end if;
    if (v_f -> 'answers' -> 'grease_trap.systems_count') is distinct from '0'::jsonb
       or (v_f -> 'answers' ->> 'access_entry.where_outside_note') is distinct from '[TEST] Behind the dumpster' then
      raise exception 'VERIFY 4b: a shown answer lost its value (0 is an answer)';
    end if;
    if (v_f ->> 'not_shown_count')::int <> 5 then
      raise exception 'VERIFY 4c: not_shown_count is % (gate code, lock box code, where inside, GT pin, lock box photos = 5)',
        v_f ->> 'not_shown_count';
    end if;
    if (v_f -> 'photos') is distinct from jsonb_build_array(jsonb_build_object('photo_id', v_ph_ok, 'question_key', 'access_entry.access_photos')) then
      raise exception 'VERIFY 4d: the test form photos are % (only the submitted access photo may be offered: not the hidden lock-box one, not the late attach)', v_f -> 'photos';
    end if;
    -- 4e. The controls that must still carry what the filter removed, so the filter is doing the work.
    set local role authenticated;
    v_f := client.get_intake(v_sub);
    reset role;
    if (select q -> 'value' from jsonb_array_elements(v_f -> 'sections') s, jsonb_array_elements(s -> 'questions') q
         where q ->> 'key' = 'access_entry.lock_box_code') is distinct from '"[TEST] 9999"'::jsonb then
      raise exception 'VERIFY 4e: control failed, client.get_intake no longer carries the abandoned lock-box code';
    end if;
    if (select count(*) from public.fn_page_photo_ids(1164) o where o.photo_id in (v_ph_hidden, v_ph_late)) <> 2 then
      raise exception 'VERIFY 4f: control failed, the builder pool does not carry the lock-box photo and the late attach';
    end if;

    -- V5. Status and counts are the view's (called, not copied), for every listed form.
    if exists (select 1 from jsonb_array_elements(v_r) f
                join client.v_intake_submissions s on s.intake_id = (f ->> 'intake_id')::bigint
               where (f ->> 'status', (f ->> 'answered_count')::int, (f ->> 'applicable_count')::int)
                     is distinct from (s.status, s.answered_count, s.applicable_count)) then
      raise exception 'VERIFY 5: a listed form''s status or counts differ from client.v_intake_submissions';
    end if;

    -- V6. Nothing secret: no collector caption, no collector link, for either property.
    if strpos(v_r::text, '[TEST] collector caption 7c1') > 0 or v_r::text ~ '"caption"' then
      raise exception 'VERIFY 6a: a collector caption reached the builder';
    end if;
    set local role authenticated;
    v_f := client.get_page_builder_forms(162);
    reset role;
    if not exists (select 1 from jsonb_array_elements(v_f) f where (f ->> 'intake_id')::bigint = v_other) then
      raise exception 'VERIFY 6b: the other property''s submitted form is not listed there';
    end if;
    if exists (select 1 from public.property_intakes i
                where i.property_id in (162, 1164)
                  and (strpos(v_r::text, i.token) > 0 or strpos(v_f::text, i.token) > 0)) then
      raise exception 'VERIFY 6c: an intake''s collector link secret reached the builder';
    end if;

    -- V7. Refusals, exact code and DETAIL; an unknown property is an empty list.
    set local role authenticated;
    if client.get_page_builder_forms(-1) is distinct from '[]'::jsonb then
      raise exception 'VERIFY 7a: an unknown property did not give an empty list';
    end if;
    begin
      perform client.get_page_builder_forms(null);
      raise exception 'VERIFY 7b: a null property was not refused' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '22023' or v_detail is distinct from 'blocker=no_property in client.get_page_builder_forms' then
        raise exception 'VERIFY 7b: a null property gave % / %', v_state, v_detail;
      end if;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'someone@gmail.com', 'role', 'authenticated')::text, true);
    begin
      perform client.get_page_builder_forms(1164);
      raise exception 'VERIFY 7c: a non-staff email read the forms' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '42501' or v_detail is distinct from 'blocker=not_staff in client.get_page_builder_forms' then
        raise exception 'VERIFY 7c: non-staff gave % / %', v_state, v_detail;
      end if;
    end;
    perform set_config('request.jwt.claims', '', true);
    begin
      perform client.get_page_builder_forms(1164);
      raise exception 'VERIFY 7d: no JWT read the forms' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '28000' or v_detail is distinct from 'blocker=not_signed_in in client.get_page_builder_forms' then
        raise exception 'VERIFY 7d: no JWT gave % / %', v_state, v_detail;
      end if;
    end;
    reset role;
    -- anon holds no USAGE on schema client, so 7e proves the schema gate; V1 proves the EXECUTE revoke.
    set local role anon;
    begin
      perform client.get_page_builder_forms(1164);
      raise exception 'VERIFY 7e: anon read the forms' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '42501' then raise exception 'VERIFY 7e: anon gave %', v_state; end if;
    end;
    reset role;

    -- V8. The premise of Planner prompt B0 item (1): the builder's own map save moves the submit baseline.
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    v_pb := client.get_page_builder(1164);
    v_map := client.update_property_site_map(1164,
               jsonb_build_object('pins', jsonb_build_object('truck', jsonb_build_object('lat', 25.8071, 'lng', -80.2065))),
               (v_pb -> 'property' ->> 'site_map_rev')::int);
    begin
      perform client.submit_property_page(1164, coalesce(v_pb -> 'pending' -> 'content', v_pb -> 'live' -> 'content'),
                (v_pb ->> 'newest_version')::int, (v_map ->> 'rev')::int, v_pb -> 'property' -> 'source');
      raise exception 'VERIFY 8a: a submit with the source loaded at open went through after a map save' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '40001' or v_detail is distinct from 'blocker=source_changed in client.submit_property_page' then
        raise exception 'VERIFY 8a: the stale-source submit gave % / %', v_state, v_detail;
      end if;
    end;
    v_f := client.submit_property_page(1164, coalesce(v_pb -> 'pending' -> 'content', v_pb -> 'live' -> 'content'),
             (v_pb ->> 'newest_version')::int, (v_map ->> 'rev')::int,
             (v_pb -> 'property' -> 'source') || jsonb_build_object('site_map', (v_map -> 'site_map') - 'rev'));
    reset role;
    if not coalesce((v_f ->> 'ok')::boolean, false) or (v_f ->> 'version')::int <> (v_pb ->> 'newest_version')::int + 1 then
      raise exception 'VERIFY 8b: the submit with the saved map folded into the source was not accepted';
    end if;

    raise exception 'VERIFY_ROLLBACK_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_ROLLBACK_SENTINEL' then raise; end if;
  end;

  -- V9. Nothing from the test survived.
  -- By the ids the test created (PL/pgSQL variables survive the sub-block rollback), not whole-table counts.
  if exists (select 1 from public.property_intakes
              where id = any (array[v_sub, v_old, v_exp, v_cxl, v_await, v_other])
                 or requested_by = '[TEST] builder forms verify')
     or exists (select 1 from public.photos where id = any (array[v_ph_ok, v_ph_hidden, v_ph_late]))
     or exists (select 1 from public.photo_links where photo_id = any (array[v_ph_ok, v_ph_hidden, v_ph_late]))
     or exists (select 1 from storage.objects where bucket_id = 'intake-photos' and name like v_sub || '/%')
     or exists (select 1 from public.property_pages where property_id = 1164 and version > v_ver0)
     or (select site_map from public.properties where id = 1164) is distinct from v_map0 then
    raise exception 'VERIFY 9: test rows survived the rollback';
  end if;

  raise notice 'VERIFY: all page builder forms assertions passed';
end $verify$;

notify pgrst, 'reload schema';
