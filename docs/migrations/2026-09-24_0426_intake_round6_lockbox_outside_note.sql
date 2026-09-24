-- =============================================================================
-- 2026-09-24_0426_intake_round6_lockbox_outside_note.sql
-- Fix-forward from the SIXTH adversarial review round (7 agents; 3 confirmed, 0 refuted, 18 low returned
-- unverified). The medium finding (an unticked "Remember me" survives a browser restart) is in the
-- canonical shared-session module of every staff app and is a separate task, not this migration.
--
-- 1. THE LOCK BOX SHAPE MOVES FORWARD TO SUBMIT, like the numbers did in round 5. access_entry.lock_box_code
--    carries "single_line": true, "max_chars": 100 (properties_lock_box_key_shape_chk); intake-submit v12
--    refuses an interior line break or control character, or more than 100 characters, naming the question,
--    and the form renders it as a one-line input. Accept keeps its own refusal; its comment no longer claims
--    v11 covered this, and its message says "control character" (what [[:cntrl:]] matches), not "hidden".
-- 2. "Where is it outside?" = Other gets its note, as inside and the access point already had:
--    access_entry.where_outside_note (NEW key, appended; keys are append-only, none changed). 36 questions.
-- 3. A request of only optional questions is refused in words: it read Complete with nothing answered.
-- VERIFY closes round 6's instrument gaps: the tree's ranges are asserted (the edge function's only source),
-- normalise is tested with a REQUIRED parent (no alternative added), a second live link for one photo on
-- the SAME intake under another question must collide, and the residue check is scoped to the fixtures,
-- the accept ledger and the Jobber outbound queue.
--
-- RULE 8, AUDIT: no new table. ATOMIC: no COMMIT.
-- =============================================================================

do $pre$
begin
  if md5(pg_get_functiondef('public.fn_intake_form_current()'::regprocedure)) is distinct from 'ebc831827572bf145c1b70cee771c9e3'
     or md5(pg_get_functiondef('client.accept_intake_answers(bigint,text[])'::regprocedure)) is distinct from '9ae47efe62b6c5e645b3e848d0f2ddb5'
     or md5(pg_get_functiondef('client.schedule_property_intake(bigint,text[],jsonb,text)'::regprocedure)) is distinct from '7915da2b06bf6d1b284b4a8aeb5e2684' then
    raise exception 'PRE-FLIGHT: a function this migration splices changed since it was measured; re-read it';
  end if;
end $pre$;

-- ============================================================ 1. the tree
CREATE OR REPLACE FUNCTION public.fn_intake_form_current()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select '{
    "version": 1,
    "sections": [
      {
        "id": "site_map",
        "title": "Site map",
        "questions": [
          {"key":"site_map.truck_parking", "label":"Truck parking spot",    "type":"gps_pin"}
        ]
      },
      {
        "id": "access_entry",
        "title": "Access & entry",
        "questions": [
          {"key":"access_entry.gate",            "label":"Is there a closed gate?",              "type":"yes_no"},
          {"key":"access_entry.gate_code",       "label":"What is the gate code or key?",        "type":"text",   "show_if":"access_entry.gate=yes"},
          {"key":"access_entry.gate_photos",     "label":"Photos of the gate or entrance",       "type":"photos", "show_if":"access_entry.gate=yes"},
          {"key":"access_entry.equipment_where", "label":"Where is the equipment located?",      "type":"choice", "options":["Inside","Outside"]},
          {"key":"access_entry.access_point",    "label":"What is the best access point for our team?", "type":"choice", "options":["Front door","Back door","Side entrance","Other"]},
          {"key":"access_entry.access_point_note","label":"If other, describe it",               "type":"text",   "show_if":"access_entry.access_point=Other"},
          {"key":"access_entry.access_photos",   "label":"Photos of the access point",           "type":"photos"},
          {"key":"access_entry.how_access",      "label":"How do we get in?",                    "type":"choice", "options":["Lock box","Key","Open","Someone lets us in"]},
          {"key":"access_entry.lock_box_code",   "label":"Lock box code",                        "type":"text",   "show_if":"access_entry.how_access=Lock box", "single_line":true, "max_chars":100},
          {"key":"access_entry.lock_box_photos", "label":"Photo of where the lock box is",       "type":"photos", "show_if":"access_entry.how_access=Lock box"},
          {"key":"access_entry.key_instruction", "label":"Key instructions",                     "type":"text",   "show_if":"access_entry.how_access=Key"},
          {"key":"access_entry.alarm",           "label":"Is there an alarm?",                   "type":"yes_no"},
          {"key":"access_entry.alarm_instruction","label":"Alarm instructions",                  "type":"text",   "show_if":"access_entry.alarm=yes"},
          {"key":"access_entry.where_inside",    "label":"Where is it inside?",                  "type":"choice", "options":["Kitchen","Other"], "show_if":"access_entry.equipment_where=Inside"},
          {"key":"access_entry.where_inside_note","label":"If other, where inside?",             "type":"text",   "show_if":"access_entry.where_inside=Other"},
          {"key":"access_entry.where_outside",   "label":"Where is it outside?",                 "type":"choice", "options":["Front","Back","Other"], "show_if":"access_entry.equipment_where=Outside"},
          {"key":"access_entry.where_outside_note","label":"If other, where outside?",            "type":"text",   "show_if":"access_entry.where_outside=Other"},
          {"key":"access_entry.obstacles",       "label":"Any obstacles, tight spaces, or anything else to report?", "type":"text", "optional":true}
        ]
      },
      {
        "id": "access_hours",
        "title": "Access hours",
        "questions": [
          {"key":"access_hours.schedule", "label":"When can we come?", "type":"weekly_hours"}
        ]
      },
      {
        "id": "grease_trap",
        "title": "Grease trap",
        "questions": [
          {"key":"grease_trap.systems_count",    "label":"How many grease trap systems?",        "type":"number"},
          {"key":"site_map.gt_location",         "label":"Grease trap location",                 "type":"gps_pin", "show_if":"grease_trap.systems_count>0"},
          {"key":"grease_trap.cleanouts_count",  "label":"How many clean outs?",                 "type":"number"},
          {"key":"grease_trap.manhole_count",    "label":"How many manholes?",                   "type":"number", "max":50},
          {"key":"grease_trap.photos",           "label":"Photos, including the manual and the clean out", "type":"photos", "show_if":"grease_trap.systems_count>0"},
          {"key":"grease_trap.capacity_gallons", "label":"Total capacity in gallons",            "type":"number", "show_if":"grease_trap.systems_count>0", "optional":true, "min":1, "max":20000},
          {"key":"grease_trap.capacity_measure", "label":"Measurements, if the gallons are not written anywhere", "type":"text", "show_if":"grease_trap.capacity_gallons="},
          {"key":"grease_trap.capacity_photos",  "label":"Photos of the capacity plate or measurements", "type":"photos", "show_if":"grease_trap.systems_count>0"},
          {"key":"grease_trap.sample_ports",     "label":"How many sample ports?",               "type":"number"}
        ]
      },
      {
        "id": "lift_station",
        "title": "Lift station",
        "questions": [
          {"key":"lift_station.count",               "label":"How many lift stations?",   "type":"number"},
          {"key":"lift_station.photos",              "label":"Photos of the lift station","type":"photos", "show_if":"lift_station.count>0"},
          {"key":"lift_station.control_panel_photos","label":"Photo of the control panel","type":"photos", "show_if":"lift_station.count>0"}
        ]
      },
      {
        "id": "water_tank",
        "title": "Water tank",
        "questions": [
          {"key":"water_tank.count",         "label":"How many water tanks?", "type":"number"},
          {"key":"water_tank.manhole_count", "label":"How many manholes?",    "type":"number", "show_if":"water_tank.count>0"},
          {"key":"water_tank.capacity",      "label":"Total capacity",        "type":"text",   "show_if":"water_tank.count>0"},
          {"key":"water_tank.photos",        "label":"Photos of the water tank", "type":"photos", "show_if":"water_tank.count>0"}
        ]
      }
    ]
  }'::jsonb;
$function$;

-- ============================================================ 2. accept: comment and wording
CREATE OR REPLACE FUNCTION client.accept_intake_answers(p_intake_id bigint, p_keys text[])
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
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(v_actor,'')) not like '%@ayache.com'
     and lower(coalesce(v_actor,'')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_keys is null or array_length(p_keys, 1) is null then
    raise exception 'no keys were accepted' using errcode = '22023';
  end if;

  select * into v_i from public.property_intakes where id = p_intake_id;
  if not found then
    raise exception 'intake % not found', p_intake_id using errcode = 'P0002';
  end if;
  if v_i.submitted_at is null then
    raise exception 'intake % has not been submitted yet', p_intake_id using errcode = '22023';
  end if;

  v_cmp := client.get_intake_compare(p_intake_id);

  foreach v_key in array p_keys loop
    v_col := v_map ->> v_key;
    if v_col is null then
      raise exception 'question % does not map to a property field', v_key using errcode = '22023';
    end if;
    if not public.fn_intake_answered(v_i.answers, v_key) then
      raise exception 'question % was not answered, nothing to accept', v_key using errcode = '22023';
    end if;
    if not public.fn_intake_applicable(v_i.form_snapshot, v_i.answers, v_key) then
      raise exception 'That answer belongs to a question the collector was not shown, so it cannot be accepted.'
        using errcode = '22023',
              detail  = 'blocker=not_shown in client.accept_intake_answers: ' || v_key;
    end if;

    select f into v_field from jsonb_array_elements(v_cmp -> 'fields') f where f ->> 'key' = v_key;
    v_old := v_field -> 'ours';
    v_new := v_i.answers -> v_key -> 'value';

    -- Refuse, in words, a value the writer cannot take (fifth review), before anything is written.
    -- intake-submit refuses the numbers at submit (v11) and the lock box shape (v12) too; this guards
    -- whatever reached the raw record another way.
    if v_col in ('grease_trap_size_gallons', 'grease_trap_manhole_count', 'sample_port_count') then
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
  -- not null here, i.e. because a real person clicked Accept).
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

-- ============================================================ 3. schedule: refuse an all-optional request
CREATE OR REPLACE FUNCTION client.schedule_property_intake(p_property_id bigint, p_requested text[], p_form_snapshot jsonb DEFAULT NULL::jsonb, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id bigint;
  v_token text;
  v_bad text[];
  v_valid text[];
  v_req text[];
  v_dropped text[];
  v_added text[];
  v_snapshot jsonb := coalesce(p_form_snapshot, public.fn_intake_form_current());
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
  if p_requested is null or array_length(p_requested, 1) is null then
    raise exception 'pick at least one question to collect' using errcode = '22023';
  end if;
  if jsonb_typeof(v_snapshot) <> 'object' or not (v_snapshot ? 'sections') then
    raise exception 'the form definition is not valid' using errcode = '22023';
  end if;

  perform 1 from public.properties
   where id = p_property_id and deleted_at is null and coalesce(is_billing, false) = false;
  if not found then
    raise exception 'property % is not a live service property', p_property_id using errcode = 'P0002';
  end if;

  -- Every requested key must exist as an L2 question in the pinned tree. A typo'd key
  -- can never be answered, so the intake would sit at Incomplete for ever with no way
  -- to tell a typo from a lazy collector.
  select array_agg(q ->> 'key') into v_valid
  from jsonb_array_elements(v_snapshot -> 'sections') s,
       jsonb_array_elements(s -> 'questions') q;

  select array_agg(k) into v_bad
  from unnest(p_requested) k
  where v_valid is null or k <> all (v_valid);
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
  if array_length(v_req, 1) is null then
    raise exception 'Pick the question each follow-up depends on as well.'
      using errcode = '22023', detail = 'blocker=followups_only in client.schedule_property_intake';
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
  returning id, token into v_id, v_token;

  return jsonb_build_object('ok', true, 'intake_id', v_id, 'token', v_token,
                            'requested', to_jsonb(v_req), 'dropped', to_jsonb(coalesce(v_dropped, '{}'::text[])), 'added', to_jsonb(coalesce(v_added, '{}'::text[])),
                            'form_version', v_snapshot -> 'version', 'note', p_note);
end $function$;

-- ============================================================ VERIFY
do $verify$
declare
  v_tree jsonb := public.fn_intake_form_current();
  v_keys text[];
  v_all  jsonb;
  v_n int; v_j jsonb; v_s text; v_raised boolean;
  v_p1 bigint; v_p2 bigint; v_i bigint; v_ph bigint; v_lock_before text; v_t0 timestamptz := clock_timestamp();
  q_of jsonb;
begin
  select array_agg(q ->> 'key' order by s.o, q.o) into v_keys
    from jsonb_array_elements(v_tree -> 'sections') with ordinality s(sec, o),
         lateral jsonb_array_elements(s.sec -> 'questions') with ordinality q(q, o);
  v_all := to_jsonb(v_keys);

  -- V0 keys: the 35 unchanged plus the new note, in order; 21 conditions
  if v_keys is distinct from array['site_map.truck_parking', 'access_entry.gate', 'access_entry.gate_code', 'access_entry.gate_photos', 'access_entry.equipment_where', 'access_entry.access_point', 'access_entry.access_point_note', 'access_entry.access_photos', 'access_entry.how_access', 'access_entry.lock_box_code', 'access_entry.lock_box_photos', 'access_entry.key_instruction', 'access_entry.alarm', 'access_entry.alarm_instruction', 'access_entry.where_inside', 'access_entry.where_inside_note', 'access_entry.where_outside', 'access_entry.where_outside_note', 'access_entry.obstacles', 'access_hours.schedule', 'grease_trap.systems_count', 'site_map.gt_location', 'grease_trap.cleanouts_count', 'grease_trap.manhole_count', 'grease_trap.photos', 'grease_trap.capacity_gallons', 'grease_trap.capacity_measure', 'grease_trap.capacity_photos', 'grease_trap.sample_ports', 'lift_station.count', 'lift_station.photos', 'lift_station.control_panel_photos', 'water_tank.count', 'water_tank.manhole_count', 'water_tank.capacity', 'water_tank.photos']::text[] then raise exception 'VERIFY V0: keys or order not as expected: %', v_keys; end if;
  select count(*) into v_n from jsonb_array_elements(v_tree -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ? 'show_if';
  if v_n is distinct from 21 then raise exception 'VERIFY V0b: expected 21 conditional questions, found %', v_n; end if;

  -- V0c the tree carries the writer's ranges: intake-submit's ONLY source for its submit-time refusals
  select jsonb_object_agg(q ->> 'key', q) into q_of from jsonb_array_elements(v_tree -> 'sections') s, jsonb_array_elements(s -> 'questions') q;
  if (q_of #> '{grease_trap.capacity_gallons,min}') is distinct from '1'::jsonb
     or (q_of #> '{grease_trap.capacity_gallons,max}') is distinct from '20000'::jsonb
     or (q_of #> '{grease_trap.manhole_count,max}') is distinct from '50'::jsonb
     or (q_of #> '{access_entry.lock_box_code,max_chars}') is distinct from '100'::jsonb
     or (q_of #> '{access_entry.lock_box_code,single_line}') is distinct from 'true'::jsonb then
    raise exception 'VERIFY V0c: the tree lost a writer range (gallons 1..20000, manholes <= 50, lock box one line <= 100)'; end if;
  -- and they agree with the constraints they mirror
  if position('<= 50' in (select pg_get_constraintdef(oid) from pg_constraint where conname = 'chk_grease_trap_manhole_count_range')) = 0
     or position('<= 20000' in (select pg_get_constraintdef(oid) from pg_constraint where conname = 'properties_grease_trap_size_chk')) = 0
     or position('<= 100' in (select pg_get_constraintdef(oid) from pg_constraint where conname = 'properties_lock_box_key_shape_chk')) = 0 then
    raise exception 'VERIFY V0d: a writer constraint changed; the tree ranges must follow it'; end if;

  -- V1 the outside note
  if public.fn_intake_applicable(v_tree, '{"access_entry.equipment_where":{"value":"Outside"},"access_entry.where_outside":{"value":"Other"}}', 'access_entry.where_outside_note') is distinct from true
     or public.fn_intake_applicable(v_tree, '{"access_entry.equipment_where":{"value":"Outside"},"access_entry.where_outside":{"value":"Front"}}', 'access_entry.where_outside_note') is distinct from false
     or public.fn_intake_applicable(v_tree, '{"access_entry.equipment_where":{"value":"Inside"},"access_entry.where_outside":{"value":"Other"}}', 'access_entry.where_outside_note') is distinct from false then
    raise exception 'VERIFY V1: the outside note is not shown exactly for Outside + Other'; end if;

  -- V2 normalise adds an alternative only for an OPTIONAL parent
  if public.fn_intake_normalise_requested('{"sections":[{"questions":[{"key":"p"},{"key":"c","show_if":"p="}]}]}', array['p']) is distinct from array['p']
     or public.fn_intake_normalise_requested('{"sections":[{"questions":[{"key":"p","optional":true},{"key":"c","show_if":"p="}]}]}', array['p']) is distinct from array['p','c'] then
    raise exception 'VERIFY V2: the alternative is added for a required parent, or not for an optional one'; end if;

  select min(p.id), max(p.id) into v_p1, v_p2 from public.properties p
   where p.client_id = (select id from public.clients where client_code = '112-YA')
     and p.deleted_at is null and coalesce(p.is_billing,false) = false;
  select lock_box_key into v_lock_before from public.properties where id = v_p2;

  begin
    perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000003","email":"verify@ayache.com","role":"authenticated"}', true);

    -- V3 an all-optional request is refused in words; with one required question it is accepted
    v_raised := false;
    begin perform client.schedule_property_intake(v_p1, array['access_entry.obstacles']);
    exception when sqlstate '22023' then v_raised := sqlerrm = 'Pick at least one question that is not optional.'; end;
    if not v_raised then raise exception 'VERIFY V3a: an all-optional request was not refused in words'; end if;
    v_j := client.schedule_property_intake(v_p1, array['access_entry.obstacles','access_entry.gate']);
    if (v_j ->> 'ok') is distinct from 'true' then raise exception 'VERIFY V3b: a request with a required question was refused'; end if;

    -- V4 accept's lock box refusal says what it checks
    insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
    values (v_p2, v_tree, '["access_entry.how_access","access_entry.lock_box_code"]', '[TEST] round 6',
            '{"access_entry.how_access":{"value":"Lock box"},"access_entry.lock_box_code":{"value":"12\u000334"}}', now()) returning id into v_i;
    v_raised := false;
    begin perform client.accept_intake_answers(v_i, array['access_entry.lock_box_code']);
    exception when sqlstate '22023' then v_raised := sqlerrm like '%control character%'; end;
    if not v_raised then raise exception 'VERIFY V4: the lock box refusal does not say "control character"'; end if;

    -- V5 one photo, one intake, a second question: collides (the rule intake-submit's 409 relies on)
    v_s := public.fn_intake_claim_upload_slot(v_i, 'jpg');
    insert into public.photos (storage_path, source, content_type) values ('intake-photos/' || v_s, 'intake_upload', 'image/jpeg') returning id into v_ph;
    insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_ph, 'property_intake', v_i, 'grease_trap.photos');
    v_raised := false;
    begin insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_ph, 'property_intake', v_i, 'grease_trap.capacity_photos');
    exception when unique_violation then v_raised := true; end;
    if not v_raised then raise exception 'VERIFY V5: one photo got a second live link on the same intake'; end if;

    raise exception 'round 6 fixtures done' using errcode = 'PPOK6';
  exception when sqlstate 'PPOK6' then
    null;
  end;

  -- V6 nothing left behind, scoped to what the fixtures could have written
  if exists (select 1 from public.property_intakes where collector like '[TEST] round 6%' or requested_by = 'verify@ayache.com')
     or exists (select 1 from public.property_intake_accepts where actor = 'verify@ayache.com')
     or exists (select 1 from public.photo_links where entity_type = 'property_intake' and created_at >= v_t0)
     or exists (select 1 from sync.outbound_queue where created_at >= v_t0)
     or (select lock_box_key from public.properties where id = v_p2) is distinct from v_lock_before then
    raise exception 'VERIFY V6: a fixture survived the sentinel'; end if;

  raise notice 'VERIFY: round 6 (lock box shape in the tree, outside note, optional-only refusal) passed';
end $verify$;

notify pgrst, 'reload schema';
