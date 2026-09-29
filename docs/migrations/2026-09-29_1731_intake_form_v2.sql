-- ============================================================================
-- 2026-09-29_1731_intake_form_v2.sql (applied 2026-09-29 17:31 ET)
-- 2026-09-29 · Site survey form, question list version 2: alarm photos, the manholes label, Gallons and Measurements
-- ============================================================================
-- Fred, 2026-09-29: "At the intake form, there is a question called "Is there an alarm?" when yes it needs to be
-- able (optional) to add up to 3 pictures for the Alarm. ... change the label "Photos, including the manholes and
-- the clean outs" ... at the Photos of the capacity plate or measurements question, we're missing 2 fields
-- "Gallons" and "Measurements" both are texts." Picked after the mockups: Gallons is a "Text box, as I said".
-- Design: Building Apps/Client App/docs/specs/2026-09-29-schedule-assign-task-design.md (section 4).
--
-- public.fn_intake_form_current() becomes version 2 (37 questions), built from the LIVE version 1 tree by
-- build_m2.mjs, never retyped. The changes, and nothing else:
-- 1. NEW access_entry.alarm_photos "Photos of the alarm", photos, show_if access_entry.alarm=yes, optional,
--    max_photos 3, right after "Alarm instructions". intake-submit (v20) refuses a 4th photo for it (429).
-- 2. grease_trap.photos label: "Photos, including the manholes and the clean outs" (same key, same meaning).
-- 3. grease_trap.capacity_gallons: label "Gallons", type TEXT (was number 1..20000), single_line, max_chars 50,
--    still optional; moved right under "Photos of the capacity plate or measurements". Same key on purpose: the
--    Property record tab, formToPage, get_property_activity and the Client App key on it; a whole-number text
--    still reaches grease_trap_size_gallons and Jobber (public.fn_intake_whole_gallons, migration before this one).
-- 4. grease_trap.capacity_measure: label "Measurements", show_if grease_trap.systems_count>0 (was "gallons left
--    blank"), optional, single_line, max_chars 200; right under Gallons. So both boxes always show next to the
--    plate photo, and neither blocks Complete; the plate photo stays required.
-- 5. version 2.
-- Forms already sent keep their own frozen snapshot (form_snapshot): only a NEW link gets version 2.
-- Rule 8: no table changes. Grants on fn_intake_form_current unchanged (asserted).
-- ATOMIC: no COMMIT; the VERIFY's writes run in a sentinel sub-block that is rolled back.
-- ============================================================================

do $pin$
begin
  if md5(pg_get_functiondef('public.fn_intake_form_current()'::regprocedure)) <> 'd93739b54cb1e29a4299f54bb93a916d'
     or (public.fn_intake_form_current() ->> 'version') <> '1' then
    raise exception 'PIN: fn_intake_form_current changed since 2026-09-29 (or is already version 2); rebuild from the live tree';
  end if;
  if to_regprocedure('public.fn_intake_whole_gallons(jsonb)') is null
     or not exists (select 1 from pg_attribute where attrelid = 'public.property_intakes'::regclass and attname = 'calendar_task_id' and not attisdropped) then
    raise exception 'PIN: the task-link and text-gallons migration is not applied; it must land before this one';
  end if;
end $pin$;

create temp table _intake_tree_v1 as select public.fn_intake_form_current() as t;

CREATE OR REPLACE FUNCTION public.fn_intake_form_current()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select '{
  "version": 2,
  "sections": [
    {
      "id": "site_map",
      "title": "Site map",
      "questions": [
        {
          "key": "site_map.truck_parking",
          "type": "gps_pin",
          "label": "Truck parking spot"
        }
      ]
    },
    {
      "id": "access_entry",
      "title": "Access & entry",
      "questions": [
        {
          "key": "access_entry.gate",
          "type": "yes_no",
          "label": "Is there a closed gate?"
        },
        {
          "key": "access_entry.gate_code",
          "type": "text",
          "label": "What is the gate code or key?",
          "show_if": "access_entry.gate=yes"
        },
        {
          "key": "access_entry.gate_photos",
          "type": "photos",
          "label": "Photos of the gate or entrance",
          "show_if": "access_entry.gate=yes"
        },
        {
          "key": "access_entry.equipment_where",
          "type": "choice",
          "label": "Where is the equipment located?",
          "options": [
            "Inside",
            "Outside"
          ]
        },
        {
          "key": "access_entry.access_point",
          "type": "choice",
          "label": "What is the best access point for our team?",
          "options": [
            "Front door",
            "Back door",
            "Side entrance",
            "Other"
          ]
        },
        {
          "key": "access_entry.access_point_note",
          "type": "text",
          "label": "If other, describe it",
          "show_if": "access_entry.access_point=Other"
        },
        {
          "key": "access_entry.access_photos",
          "type": "photos",
          "label": "Photos of the access point"
        },
        {
          "key": "access_entry.how_access",
          "type": "choice",
          "label": "How do we get in?",
          "options": [
            "Lock box",
            "Key",
            "Open",
            "Someone lets us in"
          ]
        },
        {
          "key": "access_entry.lock_box_code",
          "type": "text",
          "label": "Lock box code",
          "show_if": "access_entry.how_access=Lock box",
          "max_chars": 100,
          "single_line": true
        },
        {
          "key": "access_entry.lock_box_photos",
          "type": "photos",
          "label": "Photo of where the lock box is",
          "show_if": "access_entry.how_access=Lock box"
        },
        {
          "key": "access_entry.key_instruction",
          "type": "text",
          "label": "Key instructions",
          "show_if": "access_entry.how_access=Key"
        },
        {
          "key": "access_entry.alarm",
          "type": "yes_no",
          "label": "Is there an alarm?"
        },
        {
          "key": "access_entry.alarm_instruction",
          "type": "text",
          "label": "Alarm instructions",
          "show_if": "access_entry.alarm=yes"
        },
        {
          "key": "access_entry.alarm_photos",
          "label": "Photos of the alarm",
          "type": "photos",
          "show_if": "access_entry.alarm=yes",
          "optional": true,
          "max_photos": 3
        },
        {
          "key": "access_entry.where_inside",
          "type": "choice",
          "label": "Where is it inside?",
          "options": [
            "Kitchen",
            "Other"
          ],
          "show_if": "access_entry.equipment_where=Inside"
        },
        {
          "key": "access_entry.where_inside_note",
          "type": "text",
          "label": "If other, where inside?",
          "show_if": "access_entry.where_inside=Other"
        },
        {
          "key": "access_entry.where_outside",
          "type": "choice",
          "label": "Where is it outside?",
          "options": [
            "Front",
            "Back",
            "Other"
          ],
          "show_if": "access_entry.equipment_where=Outside"
        },
        {
          "key": "access_entry.where_outside_note",
          "type": "text",
          "label": "If other, where outside?",
          "show_if": "access_entry.where_outside=Other"
        },
        {
          "key": "access_entry.obstacles",
          "type": "text",
          "label": "Any obstacles, tight spaces, or anything else to report?",
          "optional": true
        }
      ]
    },
    {
      "id": "access_hours",
      "title": "Access hours",
      "questions": [
        {
          "key": "access_hours.schedule",
          "type": "weekly_hours",
          "label": "When can we come?"
        }
      ]
    },
    {
      "id": "grease_trap",
      "title": "Grease trap",
      "questions": [
        {
          "key": "grease_trap.systems_count",
          "type": "number",
          "label": "How many grease trap systems?"
        },
        {
          "key": "site_map.gt_location",
          "type": "gps_pin",
          "label": "Grease trap location",
          "show_if": "grease_trap.systems_count>0"
        },
        {
          "key": "grease_trap.cleanouts_count",
          "type": "number",
          "label": "How many clean outs?"
        },
        {
          "key": "grease_trap.manhole_count",
          "max": 50,
          "type": "number",
          "label": "How many manholes?"
        },
        {
          "key": "grease_trap.photos",
          "type": "photos",
          "label": "Photos, including the manholes and the clean outs",
          "show_if": "grease_trap.systems_count>0"
        },
        {
          "key": "grease_trap.capacity_photos",
          "type": "photos",
          "label": "Photos of the capacity plate or measurements",
          "show_if": "grease_trap.systems_count>0"
        },
        {
          "key": "grease_trap.capacity_gallons",
          "type": "text",
          "label": "Gallons",
          "show_if": "grease_trap.systems_count>0",
          "optional": true,
          "single_line": true,
          "max_chars": 50
        },
        {
          "key": "grease_trap.capacity_measure",
          "type": "text",
          "label": "Measurements",
          "show_if": "grease_trap.systems_count>0",
          "optional": true,
          "single_line": true,
          "max_chars": 200
        },
        {
          "key": "grease_trap.sample_ports",
          "type": "number",
          "label": "How many sample ports?"
        }
      ]
    },
    {
      "id": "lift_station",
      "title": "Lift station",
      "questions": [
        {
          "key": "lift_station.count",
          "type": "number",
          "label": "How many lift stations?"
        },
        {
          "key": "lift_station.photos",
          "type": "photos",
          "label": "Photos of the lift station",
          "show_if": "lift_station.count>0"
        },
        {
          "key": "lift_station.control_panel_photos",
          "type": "photos",
          "label": "Photo of the control panel",
          "show_if": "lift_station.count>0"
        }
      ]
    },
    {
      "id": "water_tank",
      "title": "Water tank",
      "questions": [
        {
          "key": "water_tank.count",
          "type": "number",
          "label": "How many water tanks?"
        },
        {
          "key": "water_tank.manhole_count",
          "type": "number",
          "label": "How many manholes?",
          "show_if": "water_tank.count>0"
        },
        {
          "key": "water_tank.capacity",
          "type": "text",
          "label": "Total capacity",
          "show_if": "water_tank.count>0"
        },
        {
          "key": "water_tank.photos",
          "type": "photos",
          "label": "Photos of the water tank",
          "show_if": "water_tank.count>0"
        }
      ]
    }
  ]
}'::jsonb;
$function$;

-- VERIFY. Everything that writes runs inside the sentinel block below and is rolled back.
do $verify$
declare
  v_fred  uuid := '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b';
  v2      jsonb := public.fn_intake_form_current();
  v1      jsonb := (select t from _intake_tree_v1);
  v_order text[] := array['site_map.truck_parking','access_entry.gate','access_entry.gate_code','access_entry.gate_photos',
    'access_entry.equipment_where','access_entry.access_point','access_entry.access_point_note','access_entry.access_photos',
    'access_entry.how_access','access_entry.lock_box_code','access_entry.lock_box_photos','access_entry.key_instruction',
    'access_entry.alarm','access_entry.alarm_instruction','access_entry.alarm_photos','access_entry.where_inside',
    'access_entry.where_inside_note','access_entry.where_outside','access_entry.where_outside_note','access_entry.obstacles',
    'access_hours.schedule','grease_trap.systems_count','site_map.gt_location','grease_trap.cleanouts_count',
    'grease_trap.manhole_count','grease_trap.photos','grease_trap.capacity_photos','grease_trap.capacity_gallons',
    'grease_trap.capacity_measure','grease_trap.sample_ports','lift_station.count','lift_station.photos',
    'lift_station.control_panel_photos','water_tank.count','water_tank.manhole_count','water_tank.capacity','water_tank.photos'];
  v_changed text[] := array['access_entry.alarm_photos','grease_trap.photos','grease_trap.capacity_gallons','grease_trap.capacity_measure'];
  v_keys  text[];
  v_q jsonb; v_old jsonb; v_r jsonb; v_all text[]; v_742 text[]; v_gt text[];
begin
  -- V1. Version 2, the 37 keys in this exact order, the same sections, the questions as data.
  select array_agg(q ->> 'key' order by s.o, qq.o) into v_keys
    from jsonb_array_elements(v2 -> 'sections') with ordinality s(sec, o),
         jsonb_array_elements(s.sec -> 'questions') with ordinality qq(q, o);
  if (v2 ->> 'version') <> '2' or v_keys is distinct from v_order then
    raise exception 'VERIFY 1a: version % and keys % are not the version 2 list', v2 ->> 'version', v_keys;
  end if;
  if (select array_agg(s ->> 'id' order by o) from jsonb_array_elements(v2 -> 'sections') with ordinality x(s, o))
     is distinct from (select array_agg(s ->> 'id' order by o) from jsonb_array_elements(v1 -> 'sections') with ordinality x(s, o)) then
    raise exception 'VERIFY 1b: the sections changed';
  end if;

  -- V2. Every version 1 question is unchanged except the three it names; the new one is exactly as specified.
  for v_old in select q from jsonb_array_elements(v1 -> 'sections') s, jsonb_array_elements(s -> 'questions') q loop
    select q into v_q from jsonb_array_elements(v2 -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ->> 'key' = v_old ->> 'key';
    if v_q is null then raise exception 'VERIFY 2a: % is gone', v_old ->> 'key'; end if;
    if not ((v_old ->> 'key') = any (v_changed)) and v_q is distinct from v_old then
      raise exception 'VERIFY 2b: % changed: % -> %', v_old ->> 'key', v_old, v_q;
    end if;
  end loop;
  if (select q from jsonb_array_elements(v2 -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ->> 'key' = 'access_entry.alarm_photos')
     is distinct from '{"key":"access_entry.alarm_photos","label":"Photos of the alarm","type":"photos","show_if":"access_entry.alarm=yes","optional":true,"max_photos":3}'::jsonb then
    raise exception 'VERIFY 2c: alarm photos is not as specified';
  end if;
  if (select q ->> 'label' from jsonb_array_elements(v2 -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ->> 'key' = 'grease_trap.photos')
     is distinct from 'Photos, including the manholes and the clean outs' then
    raise exception 'VERIFY 2d: the grease trap photos label is wrong';
  end if;
  if (select q from jsonb_array_elements(v2 -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ->> 'key' = 'grease_trap.capacity_gallons')
     is distinct from '{"key":"grease_trap.capacity_gallons","label":"Gallons","type":"text","show_if":"grease_trap.systems_count>0","optional":true,"single_line":true,"max_chars":50}'::jsonb then
    raise exception 'VERIFY 2e: Gallons is not the text box as specified';
  end if;
  if (select q from jsonb_array_elements(v2 -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ->> 'key' = 'grease_trap.capacity_measure')
     is distinct from '{"key":"grease_trap.capacity_measure","label":"Measurements","type":"text","show_if":"grease_trap.systems_count>0","optional":true,"single_line":true,"max_chars":200}'::jsonb then
    raise exception 'VERIFY 2f: Measurements is not as specified';
  end if;
  if (select count(*) from jsonb_array_elements(v2 -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ? 'show_if') <> 22
     or (select count(*) from jsonb_array_elements(v2 -> 'sections') s, jsonb_array_elements(s -> 'questions') q where not (q ? 'show_if')) <> 15
     or (select count(*) from jsonb_array_elements(v2 -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ->> 'type' = 'photos') <> 9
     or (select array_agg(q ->> 'key' order by q ->> 'key') from jsonb_array_elements(v2 -> 'sections') s, jsonb_array_elements(s -> 'questions') q
          where (q -> 'optional') = 'true'::jsonb)
        is distinct from array['access_entry.alarm_photos','access_entry.obstacles','grease_trap.capacity_gallons','grease_trap.capacity_measure'] then
    raise exception 'VERIFY 2g: the counts (22 conditional, 15 top-level, 9 photos, 4 optional) do not hold';
  end if;

  -- V3. The rules, on the new tree: alarm photos shown only for Alarm yes and never required; Measurements shown
  -- with Gallons typed; only the plate photo is required among the capacity questions; the list normalises to
  -- itself; an orphan alarm photos key is pruned; form 742's list plus the new keys loses nothing.
  if not public.fn_intake_applicable(v2, '{"access_entry.alarm":{"value":"yes"}}', 'access_entry.alarm_photos')
     or public.fn_intake_applicable(v2, '{"access_entry.alarm":{"value":"no"}}', 'access_entry.alarm_photos')
     or public.fn_intake_required(v2, '{"access_entry.alarm":{"value":"yes"}}', 'access_entry.alarm_photos') then
    raise exception 'VERIFY 3a: alarm photos are not shown-for-yes-only and optional';
  end if;
  if not public.fn_intake_applicable(v2, '{"grease_trap.systems_count":{"value":1},"grease_trap.capacity_gallons":{"value":"30"}}', 'grease_trap.capacity_measure') then
    raise exception 'VERIFY 3b: Measurements is hidden when Gallons is typed';
  end if;
  v_gt := array['grease_trap.systems_count','site_map.gt_location','grease_trap.cleanouts_count','grease_trap.manhole_count','grease_trap.photos',
                'grease_trap.capacity_photos','grease_trap.capacity_gallons','grease_trap.capacity_measure','grease_trap.sample_ports'];
  v_r := '{"grease_trap.systems_count":{"value":1},"site_map.gt_location":{"value":{"lat":25.8,"lng":-80.2}},"grease_trap.cleanouts_count":{"value":2},
           "grease_trap.manhole_count":{"value":1},"grease_trap.photos":{"value":["1164/a.jpg"]},"grease_trap.sample_ports":{"value":1}}';
  if public.fn_intake_missing(v2, to_jsonb(v_gt), v_r) is distinct from array['grease_trap.capacity_photos'] then
    raise exception 'VERIFY 3c: without the plate photo, missing is %', public.fn_intake_missing(v2, to_jsonb(v_gt), v_r);
  end if;
  if public.fn_intake_missing(v2, to_jsonb(v_gt), v_r || '{"grease_trap.capacity_photos":{"value":["1164/b.jpg"]}}') <> '{}'::text[] then
    raise exception 'VERIFY 3d: with the plate photo alone, missing is not empty';
  end if;
  if public.fn_intake_normalise_requested(v2, v_order) is distinct from v_order then
    raise exception 'VERIFY 3e: the full list does not normalise to itself';
  end if;
  if public.fn_intake_prune_requested(v2, array['access_entry.gate','access_entry.alarm_photos']) is distinct from array['access_entry.gate'] then
    raise exception 'VERIFY 3f: an alarm photos key without Alarm was not pruned';
  end if;
  v_742 := (select array_agg(k) from public.property_intakes i, jsonb_array_elements_text(i.requested) k where i.id = 742)
           || array['access_entry.alarm_photos','grease_trap.capacity_gallons','grease_trap.capacity_measure'];
  if exists (select 1 from unnest(v_742) k where not (k = any (public.fn_intake_normalise_requested(v2, v_742)))) then
    raise exception 'VERIFY 3g: form 742''s list plus the new keys loses a key';
  end if;

  -- V4. The Client App's reader: 37 rows, 15 top-level, Gallons read as text.
  if (select count(*) from client.v_intake_questions) <> 37 or (select count(*) from client.v_intake_questions where show_if is null) <> 15
     or (select type from client.v_intake_questions where question_key = 'grease_trap.capacity_gallons') <> 'text' then
    raise exception 'VERIFY 4: client.v_intake_questions does not read the version 2 tree';
  end if;

  -- V5. Grants unchanged.
  if (select proacl::text from pg_proc where oid = 'public.fn_intake_form_current()'::regprocedure)
     is distinct from '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}' then
    raise exception 'VERIFY 5: fn_intake_form_current grants changed';
  end if;

  begin
    -- V6. A new link, made as Fred through the real RPC, freezes version 2 and asks the new questions.
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    v_all := v_order;
    v_r := client.schedule_property_intake(1164, v_all);
    if (v_r ->> 'form_version') <> '2' or not (v_r -> 'requested' ? 'access_entry.alarm_photos')
       or not (v_r -> 'requested' ? 'grease_trap.capacity_gallons') or jsonb_array_length(v_r -> 'requested') <> 37 then
      raise exception 'VERIFY 6: a new link is not version 2 with all 37 questions: %', v_r - 'url';
    end if;
    reset role;
    if (select form_snapshot from public.property_intakes where id = (v_r ->> 'intake_id')::bigint) is distinct from v2 then
      raise exception 'VERIFY 6b: the new link did not freeze the version 2 tree';
    end if;
    raise exception 'VERIFY_ROLLBACK_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_ROLLBACK_SENTINEL' then raise; end if;
  end;
  raise notice 'VERIFY: version 2 has the 37 questions in order, only the four named ones changed, the rules hold, the Client App reads it, a new link freezes it';
end $verify$;

drop table _intake_tree_v1;

notify pgrst, 'reload schema';
