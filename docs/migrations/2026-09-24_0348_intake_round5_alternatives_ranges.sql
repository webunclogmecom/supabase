-- =============================================================================
-- 2026-09-24_0348_intake_round5_alternatives_ranges.sql
-- Fix-forward from the FIFTH adversarial review round (12 agents; 7 confirmed, 1 refuted, 12 low returned
-- unverified). Keys unchanged; one question moves section, and V0 asserts all 35 by name and order.
--
-- 🛑 1. THE GALLONS / MEASUREMENTS PAIR COULD STILL BE SPLIT BY THE REQUEST SET. The either-or made the
--    gallons optional on the premise that "Measurements, if the gallons are not written anywhere" is asked
--    with them. Nothing guaranteed it: a request with the gallons but not the measurements read Complete
--    with no capacity data at all, and the dialog could produce it (tick gallons alone on a property that
--    holds them, or untick the measurements). ⇒ public.fn_intake_normalise_requested = prune, then add the
--    ALTERNATIVE of every requested optional question (a question whose show_if is "<that key>=").
--    client.schedule_property_intake stores it and returns "added" beside "dropped".
--
-- 2. THE GREASE-TRAP MAP PIN MOVES UNDER THE TRAP COUNT. site_map.gt_location (key unchanged) now sits in
--    the grease_trap section right after systems_count, shown only when it is above 0. 0311 left it ungated
--    because in the site-map section it would have appeared ABOVE the collector after they answered the
--    count further down; moving it removes that objection. Real no-trap sites exist (057-BAY is a lift
--    station, 013-DIM has only lift-station work) and could otherwise finish only with a false pin.
--
-- 3. NUMBER QUESTIONS CARRY THEIR WRITER'S RANGE: capacity_gallons "min":1,"max":20000 (0 means nobody
--    knows it, so it does not count; the measurements take its place), grease_trap.manhole_count "max":50
--    (chk_grease_trap_manhole_count_range). intake-submit v11 enforces min/max and whole numbers at submit.
--
-- 4. ACCEPT REFUSES, IN WORDS, WHAT THE WRITER CANNOT TAKE: a non-whole or out-of-range number (it raised a
--    raw 22P02 and rolled the whole accept back), and a lock box code with an interior line break, a hidden
--    character or more than 100 characters (properties_lock_box_key_shape_chk). It writes the trimmed,
--    normalised value and records that same value in property_intake_accepts.
--
-- VERIFY adds what round 5 found missing: a pre-flight md5 on every spliced body (0301 lacked one), the
-- unique index's predicate pinned both ways, parent_key on two-operator and padded conditions, the shown
-- side of every gated question, and an enumeration of the roles that can read the token.
--
-- RULE 8, AUDIT: no new table. ATOMIC: no COMMIT.
-- =============================================================================

-- ============================================================ 0. pre-flight: the bodies spliced below are the ones measured
do $pre$
begin
  if md5(pg_get_functiondef('public.fn_intake_form_current()'::regprocedure)) is distinct from 'aa65e663378488b2cf93fa3af727ba09'
     or md5(pg_get_functiondef('client.accept_intake_answers(bigint,text[])'::regprocedure)) is distinct from 'a57d941d7e40a713d98b4f55abe67ca8'
     or md5(pg_get_functiondef('client.schedule_property_intake(bigint,text[],jsonb,text)'::regprocedure)) is distinct from '3a20c12db2f4cee76c82fc2401bc2fde' then
    raise exception 'PRE-FLIGHT: a function this migration splices changed since it was measured; re-read it';
  end if;
end $pre$;


-- ============================================================ 1. normalise the requested set
create or replace function public.fn_intake_normalise_requested(p_snapshot jsonb, p_requested text[])
returns text[]
language plpgsql
immutable
set search_path to ''
as $$
declare
  v_out  text[] := public.fn_intake_prune_requested(p_snapshot, p_requested);
  v_q    jsonb;
  v_show text;
  v_pos  int;
  v_par  text;
begin
  -- Add the alternative of every kept optional question: a question whose condition is "<that key>="
  -- (shown when it is left blank). One pass is enough: an alternative is not itself optional today.
  for v_q in
    select q from jsonb_array_elements(coalesce(p_snapshot -> 'sections', '[]'::jsonb)) s,
                  jsonb_array_elements(coalesce(s -> 'questions', '[]'::jsonb)) q
     where jsonb_typeof(q) = 'object' and q ? 'show_if'
  loop
    v_show := public.fn_intake_trim(v_q ->> 'show_if');
    v_pos  := least(nullif(position('=' in v_show), 0), nullif(position('>' in v_show), 0));
    continue when v_pos is null or substr(v_show, v_pos, 1) <> '=' or public.fn_intake_trim(substr(v_show, v_pos + 1)) <> '';
    v_par := public.fn_intake_trim(substr(v_show, 1, v_pos - 1));
    continue when not coalesce(v_par = any (v_out), false) or coalesce(v_q ->> 'key' = any (v_out), false);
    continue when not exists (select 1 from jsonb_array_elements(p_snapshot -> 'sections') s2, jsonb_array_elements(s2 -> 'questions') pq
                               where pq ->> 'key' = v_par and (pq -> 'optional') = 'true'::jsonb);
    v_out := v_out || (v_q ->> 'key');
  end loop;
  return v_out;
end $$;

comment on function public.fn_intake_normalise_requested(jsonb, text[]) is
  'The requested intake keys as stored: fn_intake_prune_requested (no follow-up without its parent), plus the '
  'alternative of every requested optional question (a question whose show_if is "<that key>="), so an optional '
  'question left blank always leaves something required. client.schedule_property_intake stores this.';

revoke all on function public.fn_intake_normalise_requested(jsonb, text[]) from public, anon;
grant execute on function public.fn_intake_normalise_requested(jsonb, text[]) to authenticated, service_role;


-- ============================================================ 2. the tree (the pin moves, two ranges; keys unchanged)
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
          {"key":"access_entry.lock_box_code",   "label":"Lock box code",                        "type":"text",   "show_if":"access_entry.how_access=Lock box"},
          {"key":"access_entry.lock_box_photos", "label":"Photo of where the lock box is",       "type":"photos", "show_if":"access_entry.how_access=Lock box"},
          {"key":"access_entry.key_instruction", "label":"Key instructions",                     "type":"text",   "show_if":"access_entry.how_access=Key"},
          {"key":"access_entry.alarm",           "label":"Is there an alarm?",                   "type":"yes_no"},
          {"key":"access_entry.alarm_instruction","label":"Alarm instructions",                  "type":"text",   "show_if":"access_entry.alarm=yes"},
          {"key":"access_entry.where_inside",    "label":"Where is it inside?",                  "type":"choice", "options":["Kitchen","Other"], "show_if":"access_entry.equipment_where=Inside"},
          {"key":"access_entry.where_inside_note","label":"If other, where inside?",             "type":"text",   "show_if":"access_entry.where_inside=Other"},
          {"key":"access_entry.where_outside",   "label":"Where is it outside?",                 "type":"choice", "options":["Front","Back","Other"], "show_if":"access_entry.equipment_where=Outside"},
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


-- ============================================================ 3. schedule stores the normalised set
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

  insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
  values (p_property_id, v_snapshot, to_jsonb(v_req), auth.jwt() ->> 'email')
  returning id, token into v_id, v_token;

  return jsonb_build_object('ok', true, 'intake_id', v_id, 'token', v_token,
                            'requested', to_jsonb(v_req), 'dropped', to_jsonb(coalesce(v_dropped, '{}'::text[])), 'added', to_jsonb(coalesce(v_added, '{}'::text[])),
                            'form_version', v_snapshot -> 'version', 'note', p_note);
end $function$;


-- ============================================================ 4. accept refuses what the writer cannot take
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
    -- intake-submit v11 refuses these at submit too; this guards whatever reached the raw record.
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
        raise exception 'The lock box code has a line break, a hidden character or more than 100 characters, so it cannot be accepted as it is.'
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


-- ============================================================ VERIFY
do $verify$
declare
  v_tree jsonb := public.fn_intake_form_current();
  v_keys text[];
  v_all  jsonb;
  v_n int; v_j jsonb; v_s text; v_raised boolean;
  v_p1 bigint; v_p2 bigint; v_i bigint; v_w bigint; v_ph bigint; v_lock_before text; v_gal_before integer;
  v_nogt jsonb := jsonb_build_object(
    'site_map.truck_parking',      jsonb_build_object('value', jsonb_build_object('lat', 25.791, 'lng', -80.131)),
    'access_entry.gate',           jsonb_build_object('value', 'no'),
    'access_entry.equipment_where',jsonb_build_object('value', 'Outside'),
    'access_entry.where_outside',  jsonb_build_object('value', 'Back'),
    'access_entry.access_point',   jsonb_build_object('value', 'Back door'),
    'access_entry.access_photos',  jsonb_build_object('value', jsonb_build_array('p')),
    'access_entry.how_access',     jsonb_build_object('value', 'Open'),
    'access_entry.alarm',          jsonb_build_object('value', 'no'),
    'access_hours.schedule',       jsonb_build_object('value', jsonb_build_object('mon', jsonb_build_object('open','00:00','close','00:00'))),
    'grease_trap.systems_count',   jsonb_build_object('value', 0),
    'grease_trap.cleanouts_count', jsonb_build_object('value', 0),
    'grease_trap.manhole_count',   jsonb_build_object('value', 0),
    'grease_trap.sample_ports',    jsonb_build_object('value', 0),
    'lift_station.count',          jsonb_build_object('value', 1),
    'lift_station.photos',         jsonb_build_object('value', jsonb_build_array('p')),
    'lift_station.control_panel_photos', jsonb_build_object('value', jsonb_build_array('p')),
    'water_tank.count',            jsonb_build_object('value', 0));
  v_onegt jsonb;
begin
  select array_agg(q ->> 'key' order by s.o, q.o) into v_keys
    from jsonb_array_elements(v_tree -> 'sections') with ordinality s(sec, o),
         lateral jsonb_array_elements(s.sec -> 'questions') with ordinality q(q, o);
  v_all := to_jsonb(v_keys);
  v_onegt := (v_nogt - 'grease_trap.systems_count') || jsonb_build_object(
    'grease_trap.systems_count', jsonb_build_object('value', 1),
    'site_map.gt_location',      jsonb_build_object('value', jsonb_build_object('lat', 25.79, 'lng', -80.13)),
    'grease_trap.photos',        jsonb_build_object('value', jsonb_build_array('p')),
    'grease_trap.capacity_gallons', jsonb_build_object('value', 1000),
    'grease_trap.capacity_photos',  jsonb_build_object('value', jsonb_build_array('p')));

  -- ============================================ V0 keys unchanged, the pin now right after the trap count
  if v_keys is distinct from array['site_map.truck_parking', 'access_entry.gate', 'access_entry.gate_code', 'access_entry.gate_photos', 'access_entry.equipment_where', 'access_entry.access_point', 'access_entry.access_point_note', 'access_entry.access_photos', 'access_entry.how_access', 'access_entry.lock_box_code', 'access_entry.lock_box_photos', 'access_entry.key_instruction', 'access_entry.alarm', 'access_entry.alarm_instruction', 'access_entry.where_inside', 'access_entry.where_inside_note', 'access_entry.where_outside', 'access_entry.obstacles', 'access_hours.schedule', 'grease_trap.systems_count', 'site_map.gt_location', 'grease_trap.cleanouts_count', 'grease_trap.manhole_count', 'grease_trap.photos', 'grease_trap.capacity_gallons', 'grease_trap.capacity_measure', 'grease_trap.capacity_photos', 'grease_trap.sample_ports', 'lift_station.count', 'lift_station.photos', 'lift_station.control_panel_photos', 'water_tank.count', 'water_tank.manhole_count', 'water_tank.capacity', 'water_tank.photos']::text[] then raise exception 'VERIFY V0: the question keys or order are not the expected ones: %', v_keys; end if;
  select count(*) into v_n from jsonb_array_elements(v_tree -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ? 'show_if';
  if v_n is distinct from 20 then raise exception 'VERIFY V0b: expected 20 conditional questions, found %', v_n; end if;

  -- ============================================ V1 completeness at real sites, both sides of every gate
  if public.fn_intake_missing(v_tree, v_all, v_nogt) is distinct from '{}'::text[] then
    raise exception 'VERIFY V1a: a truthful site with NO grease trap and NO pin still misses %', public.fn_intake_missing(v_tree, v_all, v_nogt); end if;
  if public.fn_intake_missing(v_tree, v_all, v_onegt) is distinct from '{}'::text[] then
    raise exception 'VERIFY V1b: a truthful site with one trap misses %', public.fn_intake_missing(v_tree, v_all, v_onegt); end if;
  if public.fn_intake_missing(v_tree, v_all, v_onegt - 'site_map.gt_location') is distinct from array['site_map.gt_location']
     or public.fn_intake_missing(v_tree, v_all, v_onegt - 'grease_trap.capacity_photos') is distinct from array['grease_trap.capacity_photos']
     or public.fn_intake_missing(v_tree, v_all, v_onegt - 'grease_trap.photos') is distinct from array['grease_trap.photos']
     or public.fn_intake_missing(v_tree, v_all, v_onegt - 'grease_trap.capacity_gallons') is distinct from array['grease_trap.capacity_measure'] then
    raise exception 'VERIFY V1c: with one trap, the pin, both photo questions and gallons-or-measurements must each be required'; end if;

  -- ============================================ V2 normalising the requested set
  if public.fn_intake_normalise_requested(v_tree, v_keys) is distinct from v_keys then
    raise exception 'VERIFY V2a: normalising the full set changed it'; end if;
  if public.fn_intake_normalise_requested(v_tree, array['site_map.truck_parking', 'access_entry.gate', 'access_entry.gate_code', 'access_entry.gate_photos', 'access_entry.equipment_where', 'access_entry.access_point', 'access_entry.access_point_note', 'access_entry.access_photos', 'access_entry.how_access', 'access_entry.lock_box_code', 'access_entry.lock_box_photos', 'access_entry.key_instruction', 'access_entry.alarm', 'access_entry.alarm_instruction', 'access_entry.where_inside', 'access_entry.where_inside_note', 'access_entry.where_outside', 'access_entry.obstacles', 'access_hours.schedule', 'grease_trap.systems_count', 'site_map.gt_location', 'grease_trap.cleanouts_count', 'grease_trap.manhole_count', 'grease_trap.photos', 'grease_trap.capacity_gallons', 'grease_trap.capacity_photos', 'grease_trap.sample_ports', 'lift_station.count', 'lift_station.photos', 'lift_station.control_panel_photos', 'water_tank.count', 'water_tank.manhole_count', 'water_tank.capacity', 'water_tank.photos']::text[])
     is distinct from (array['site_map.truck_parking', 'access_entry.gate', 'access_entry.gate_code', 'access_entry.gate_photos', 'access_entry.equipment_where', 'access_entry.access_point', 'access_entry.access_point_note', 'access_entry.access_photos', 'access_entry.how_access', 'access_entry.lock_box_code', 'access_entry.lock_box_photos', 'access_entry.key_instruction', 'access_entry.alarm', 'access_entry.alarm_instruction', 'access_entry.where_inside', 'access_entry.where_inside_note', 'access_entry.where_outside', 'access_entry.obstacles', 'access_hours.schedule', 'grease_trap.systems_count', 'site_map.gt_location', 'grease_trap.cleanouts_count', 'grease_trap.manhole_count', 'grease_trap.photos', 'grease_trap.capacity_gallons', 'grease_trap.capacity_photos', 'grease_trap.sample_ports', 'lift_station.count', 'lift_station.photos', 'lift_station.control_panel_photos', 'water_tank.count', 'water_tank.manhole_count', 'water_tank.capacity', 'water_tank.photos']::text[] || array['grease_trap.capacity_measure']) then
    raise exception 'VERIFY V2b: the gallons without the measurements did not get the measurements added'; end if;
  if public.fn_intake_normalise_requested(v_tree, array['grease_trap.systems_count','grease_trap.capacity_gallons'])
     is distinct from array['grease_trap.systems_count','grease_trap.capacity_gallons','grease_trap.capacity_measure']
     or public.fn_intake_normalise_requested(v_tree, array['grease_trap.systems_count']) is distinct from array['grease_trap.systems_count']
     or public.fn_intake_normalise_requested(v_tree, array['grease_trap.capacity_measure']) is distinct from '{}'::text[] then
    raise exception 'VERIFY V2c: the alternative is added only with its optional parent, and an orphan is still pruned'; end if;
  -- the finding itself: gallons requested, measurements not, gallons blank -> must not be Complete
  if public.fn_intake_missing(v_tree, to_jsonb(public.fn_intake_normalise_requested(v_tree, array['grease_trap.systems_count','grease_trap.capacity_gallons'])),
       '{"grease_trap.systems_count":{"value":1}}') is distinct from array['grease_trap.capacity_measure'] then
    raise exception 'VERIFY V2d: a blank gallons answer still reads Complete with no capacity'; end if;

  -- ============================================ V3 parent_key: first operator, padding
  if public.fn_intake_parent_key('{"sections":[{"questions":[{"key":"c","show_if":"p=a>b"}]}]}', 'c') is distinct from 'p'
     or public.fn_intake_parent_key('{"sections":[{"questions":[{"key":"c","show_if":"p>1=2"}]}]}', 'c') is distinct from 'p'
     or public.fn_intake_parent_key(jsonb_build_object('sections', jsonb_build_array(jsonb_build_object('questions', jsonb_build_array(
          jsonb_build_object('key','c','show_if', chr(160) || 'p' || chr(12288) || '>0'))))), 'c') is distinct from 'p'
     or public.fn_intake_applicable(jsonb_build_object('sections', jsonb_build_array(jsonb_build_object('questions', jsonb_build_array(
          jsonb_build_object('key','p'), jsonb_build_object('key','c','show_if', chr(160) || 'p ' || '=' || ' yes' || chr(8233)))))),
          '{"p":{"value":"yes"}}', 'c') is distinct from true then
    raise exception 'VERIFY V3: a two-operator or padded condition is read wrongly'; end if;

  -- ============================================ V4 who can read the token (platform roles only)
  select count(*) into v_n from pg_roles r
   where has_column_privilege(r.oid, 'public.property_intakes'::regclass, 'token', 'SELECT')
     and r.rolname not in ('postgres','service_role','supabase_admin','pg_read_all_data','supabase_etl_admin','supabase_read_only_user');
  if v_n is distinct from 0 then raise exception 'VERIFY V4: % role(s) outside the platform allowlist can read the intake token', v_n; end if;

  -- ============================================ fixtures, rolled back by the sentinel
  select min(p.id), max(p.id) into v_p1, v_p2 from public.properties p
   where p.client_id = (select id from public.clients where client_code = '112-YA')
     and p.deleted_at is null and coalesce(p.is_billing,false) = false;
  select lock_box_key, grease_trap_size_gallons into v_lock_before, v_gal_before from public.properties where id = v_p2;

  begin
    perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000003","email":"verify@ayache.com","role":"authenticated"}', true);

    -- V5 schedule adds the alternative and says so
    v_j := client.schedule_property_intake(v_p1, array['grease_trap.systems_count','grease_trap.capacity_gallons']);
    if (select requested from public.property_intakes where id = (v_j ->> 'intake_id')::bigint)
       is distinct from '["grease_trap.systems_count","grease_trap.capacity_gallons","grease_trap.capacity_measure"]'::jsonb
       or v_j -> 'added' is distinct from '["grease_trap.capacity_measure"]'::jsonb
       or v_j -> 'dropped' is distinct from '[]'::jsonb then
      raise exception 'VERIFY V5: schedule did not store and report the added measurements: %', v_j; end if;

    -- V6 accept refuses bad values in words, and writes good ones normalised
    insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
    values (v_p2, v_tree, '["grease_trap.systems_count","grease_trap.capacity_gallons","grease_trap.manhole_count","grease_trap.sample_ports","access_entry.how_access","access_entry.lock_box_code"]',
            '[TEST] round 5', '{"grease_trap.systems_count":{"value":1},"grease_trap.capacity_gallons":{"value":748.8},"grease_trap.manhole_count":{"value":60},"grease_trap.sample_ports":{"value":"3.5"},"access_entry.how_access":{"value":"Lock box"},"access_entry.lock_box_code":{"value":"12\n34"}}', now())
    returning id into v_i;
    foreach v_s in array array['grease_trap.capacity_gallons','grease_trap.manhole_count','grease_trap.sample_ports','access_entry.lock_box_code'] loop
      v_raised := false;
      begin perform client.accept_intake_answers(v_i, array[v_s]);
      exception when sqlstate '22023' then v_raised := sqlerrm not like '%invalid input%' and sqlerrm not like '%violates%'; end;
      if not v_raised then raise exception 'VERIFY V6a: accept did not refuse % in words', v_s; end if;
    end loop;
    -- gallons 0 is "nobody knows"
    insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
    values (v_p2, v_tree, '["grease_trap.systems_count","grease_trap.capacity_gallons"]', '[TEST] round 5',
            '{"grease_trap.systems_count":{"value":1},"grease_trap.capacity_gallons":{"value":0}}', now()) returning id into v_w;
    v_raised := false;
    begin perform client.accept_intake_answers(v_w, array['grease_trap.capacity_gallons']);
    exception when sqlstate '22023' then v_raised := sqlerrm like 'Capacity must be between 1 and 20,000%'; end;
    if not v_raised then raise exception 'VERIFY V6b: gallons 0 was accepted'; end if;
    -- POSITIVE CONTROL: good values are written, trimmed and normalised, and recorded as written
    insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
    values (v_p2, v_tree, '["grease_trap.systems_count","grease_trap.capacity_gallons","access_entry.how_access","access_entry.lock_box_code"]', '[TEST] round 5',
            jsonb_build_object('grease_trap.systems_count', jsonb_build_object('value', 1), 'grease_trap.capacity_gallons', jsonb_build_object('value', '1250'),
                               'access_entry.how_access', jsonb_build_object('value', 'Lock box'), 'access_entry.lock_box_code', jsonb_build_object('value', chr(160) || 'TEST-4321' || chr(10))), now())
    returning id into v_i;
    perform client.accept_intake_answers(v_i, array['grease_trap.capacity_gallons','access_entry.lock_box_code']);
    if (select grease_trap_size_gallons from public.properties where id = v_p2) is distinct from 1250
       or (select lock_box_key from public.properties where id = v_p2) is distinct from 'TEST-4321'
       or (select new_value from public.property_intake_accepts where intake_id = v_i and question_key = 'access_entry.lock_box_code') is distinct from '"TEST-4321"'::jsonb
       or (select new_value from public.property_intake_accepts where intake_id = v_i and question_key = 'grease_trap.capacity_gallons') is distinct from '1250'::jsonb then
      raise exception 'VERIFY V6c: POSITIVE CONTROL, good values were not written normalised'; end if;

    -- V7 the one-live-link index, both sides of its predicate
    v_s := public.fn_intake_claim_upload_slot(v_i, 'jpg');
    insert into public.photos (storage_path, source, content_type) values ('intake-photos/' || v_s, 'intake_upload', 'image/jpeg') returning id into v_ph;
    insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_ph, 'property_intake', v_i, 'grease_trap.photos');
    v_raised := false;
    begin insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_ph, 'property_intake', v_w, 'grease_trap.photos');
    exception when unique_violation then v_raised := true; end;
    if not v_raised then raise exception 'VERIFY V7a: one photo got a live link on a second intake'; end if;
    update public.photo_links set deleted_at = now() where photo_id = v_ph and entity_id = v_i;
    insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_ph, 'property_intake', v_i, 'grease_trap.capacity_photos');
    if (select count(*) from public.photo_links where photo_id = v_ph and deleted_at is null) is distinct from 1::bigint then
      raise exception 'VERIFY V7b: a soft-deleted link still blocks a new live one'; end if;

    raise exception 'round 5 fixtures done' using errcode = 'PPOK5';
  exception when sqlstate 'PPOK5' then
    null;
  end;

  -- ============================================ V8 nothing left behind
  if exists (select 1 from public.property_intakes where collector = '[TEST] round 5' or requested_by = 'verify@ayache.com')
     or exists (select 1 from public.photo_links where entity_type = 'property_intake')
     or (select lock_box_key from public.properties where id = v_p2) is distinct from v_lock_before
     or (select grease_trap_size_gallons from public.properties where id = v_p2) is distinct from v_gal_before then
    raise exception 'VERIFY V8: a fixture survived the sentinel'; end if;

  raise notice 'VERIFY: round 5 (alternatives, pin under the trap count, ranges, accept refusals) passed';
end $verify$;

notify pgrst, 'reload schema';
