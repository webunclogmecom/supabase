-- ============================================================================
-- 2026-09-30_2234_intake_form_v3.sql (applied 2026-09-30 22:34 ET, DB clock)
-- 2026-09-30 · Site survey form, question list version 3: lift station and water tank photo slots, the capacity plate
-- label with an (i), and an explanation required on every photo
-- ============================================================================
-- Fred, 2026-09-30: (L) "Here I want a change of the label "Photos of the lift station" to "Photos for the lift station"
-- and to put 2 required photos, one for the Access and one for the Lift Station. (remember each can have a description)";
-- (W) "Here want two required photos, Capacity and Watertank, instead of just one, where it clear which one is which.";
-- (C) on the capacity plate card: "or gallons pumped , And mesurements (i)" and "everytime you add a pic you need to put
-- explaination". His picks: under "Photos for the lift station" Access (if needed) optional, Control panel and Lift
-- station required; Capacity and Water tank required; the label "Photos of the capacity plate or gallons pumped, and
-- measurements" with an (i); an explanation REQUIRED on every photo. Design: Building Apps/Picture Planner/docs/specs/
-- 2026-09-30-form-v3-photo-slots-design.md. Built by mk_mig_tree.mjs from the LIVE version 2 tree, never retyped:
-- 1. top level photo_note_required: true. intake-submit v22 refuses a claimed photo with no explanation on a form whose
--    snapshot says so; the collector page asks for one ("What does this photo show?"). Forms from versions 1 and 2
--    carry no such key, so nothing changes for them.
-- 2. grease_trap.capacity_photos: the new label and "info" (the (i) text on the form). Same key, same meaning.
-- 3. NEW section lift_station_photos "Photos for the lift station", right after "Lift station" (which keeps its count):
--    NEW lift_station.access_photos "Lift station access" (short "Access", optional, at most 3); the existing
--    lift_station.control_panel_photos, label "Lift station control panel" (short "Control panel", at most 3, now
--    listed before the station); the existing lift_station.photos, label "Lift station". All three show_if count>0.
-- 4. water_tank: NEW water_tank.capacity_photos "Water tank capacity" (short "Capacity", at most 3) before the existing
--    water_tank.photos, label "Water tank". Both show_if count>0.
-- 5. version 3. "short" is the word the collector form shows (Fred's words); every other reader shows "label", which
--    stands alone. get_intake, client.v_intake_questions, intake-submit and the fn_intake_* rules ignore short and info.
-- Keys are append-only: nothing leaves the tree. Forms already sent keep their frozen snapshot: only a NEW link gets v3.
-- 🛑 LAST in its plan: applied only after intake-submit v22 is deployed, the collector page with the v3 support is live
-- (its SHA-256 checked) and the Picture Planner B2 publish is live, so no version 3 form exists before every reader of
-- it supports it. The pin below also refuses to run before the section migration.
-- Rule 8: no table change. Grants on fn_intake_form_current unchanged (asserted).
-- ATOMIC: no COMMIT; the VERIFY's writes (one intake on 1164) run in a sentinel sub-block and are rolled back.
-- ============================================================================

do $pin$
begin
  if md5(pg_get_functiondef('public.fn_intake_form_current()'::regprocedure)) <> '8380e947c27e99d8bd427c37558720d2'
     or (public.fn_intake_form_current() ->> 'version') <> '2' then
    raise exception 'PIN: fn_intake_form_current changed since 2026-09-30 (or is already version 3); rebuild from the live tree';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'fn_intake_form_current') <> 1 then
    raise exception 'PIN: fn_intake_form_current has more than one overload';
  end if;
  if strpos(pg_get_functiondef('public.fn_page_content_problem(bigint,jsonb)'::regprocedure), $s$'lift_station','water_tank'$s$) = 0 then
    raise exception 'PIN: the page section migration (lift_station, water_tank) is not applied; it must land before this one';
  end if;
end $pin$;

create temp table _intake_tree_v2 as select public.fn_intake_form_current() as t;

CREATE OR REPLACE FUNCTION public.fn_intake_form_current()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select '{
  "version": 3,
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
          "label": "Photos of the capacity plate or gallons pumped, and measurements",
          "show_if": "grease_trap.systems_count>0",
          "info": "Take the grease trap''s capacity plate. If there is none, the gallons pumped. Add the measurements too."
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
        }
      ]
    },
    {
      "id": "lift_station_photos",
      "title": "Photos for the lift station",
      "questions": [
        {
          "key": "lift_station.access_photos",
          "type": "photos",
          "label": "Lift station access",
          "short": "Access",
          "show_if": "lift_station.count>0",
          "optional": true,
          "max_photos": 3
        },
        {
          "key": "lift_station.control_panel_photos",
          "type": "photos",
          "label": "Lift station control panel",
          "show_if": "lift_station.count>0",
          "short": "Control panel",
          "max_photos": 3
        },
        {
          "key": "lift_station.photos",
          "type": "photos",
          "label": "Lift station",
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
          "key": "water_tank.capacity_photos",
          "type": "photos",
          "label": "Water tank capacity",
          "short": "Capacity",
          "show_if": "water_tank.count>0",
          "max_photos": 3
        },
        {
          "key": "water_tank.photos",
          "type": "photos",
          "label": "Water tank",
          "show_if": "water_tank.count>0"
        }
      ]
    }
  ],
  "photo_note_required": true
}'::jsonb;
$function$;

-- VERIFY. Everything that writes runs inside the sentinel block below and is rolled back.
do $verify$
declare
  v_fred  uuid := '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b';
  v3      jsonb := public.fn_intake_form_current();
  v2      jsonb := (select t from _intake_tree_v2);
  v_order text[] := array['site_map.truck_parking','access_entry.gate','access_entry.gate_code','access_entry.gate_photos',
    'access_entry.equipment_where','access_entry.access_point','access_entry.access_point_note','access_entry.access_photos',
    'access_entry.how_access','access_entry.lock_box_code','access_entry.lock_box_photos','access_entry.key_instruction',
    'access_entry.alarm','access_entry.alarm_instruction','access_entry.alarm_photos','access_entry.where_inside',
    'access_entry.where_inside_note','access_entry.where_outside','access_entry.where_outside_note','access_entry.obstacles',
    'access_hours.schedule','grease_trap.systems_count','site_map.gt_location','grease_trap.cleanouts_count',
    'grease_trap.manhole_count','grease_trap.photos','grease_trap.capacity_photos','grease_trap.capacity_gallons',
    'grease_trap.capacity_measure','grease_trap.sample_ports','lift_station.count','lift_station.access_photos',
    'lift_station.control_panel_photos','lift_station.photos','water_tank.count','water_tank.manhole_count',
    'water_tank.capacity','water_tank.capacity_photos','water_tank.photos'];
  v_changed text[] := array['grease_trap.capacity_photos','lift_station.control_panel_photos','lift_station.photos','water_tank.photos'];
  v_keys  text[];
  v_q jsonb; v_old jsonb; v_r jsonb; v_ls text[];
  qv3 jsonb;
begin
  -- V1. Version 3, the flag, the 39 keys in this exact order, the 7 sections in this order, the new section's title.
  select array_agg(q ->> 'key' order by s.o, qq.o) into v_keys
    from jsonb_array_elements(v3 -> 'sections') with ordinality s(sec, o),
         jsonb_array_elements(s.sec -> 'questions') with ordinality qq(q, o);
  if (v3 ->> 'version') <> '3' or (v3 -> 'photo_note_required') is distinct from 'true'::jsonb
     or (select array_agg(k order by k) from jsonb_object_keys(v3) k) is distinct from array['photo_note_required','sections','version']
     or v_keys is distinct from v_order then
    raise exception 'VERIFY 1a: version %, flag %, keys % are not the version 3 list', v3 ->> 'version', v3 -> 'photo_note_required', v_keys;
  end if;
  if (select array_agg(s ->> 'id' order by o) from jsonb_array_elements(v3 -> 'sections') with ordinality x(s, o))
       is distinct from array['site_map','access_entry','access_hours','grease_trap','lift_station','lift_station_photos','water_tank']
     or (select s ->> 'title' from jsonb_array_elements(v3 -> 'sections') s where s ->> 'id' = 'lift_station_photos') is distinct from 'Photos for the lift station' then
    raise exception 'VERIFY 1b: the sections are not the version 3 sections';
  end if;

  -- V2. Every version 2 question is unchanged except the four it names; each new or changed one is exactly as specified.
  for v_old in select q from jsonb_array_elements(v2 -> 'sections') s, jsonb_array_elements(s -> 'questions') q loop
    select q into v_q from jsonb_array_elements(v3 -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ->> 'key' = v_old ->> 'key';
    if v_q is null then raise exception 'VERIFY 2a: % is gone', v_old ->> 'key'; end if;
    if not ((v_old ->> 'key') = any (v_changed)) and v_q is distinct from v_old then
      raise exception 'VERIFY 2b: % changed: % -> %', v_old ->> 'key', v_old, v_q;
    end if;
  end loop;
  for v_q in select x from jsonb_array_elements(jsonb_build_array(
      $j${"key":"grease_trap.capacity_photos","type":"photos","label":"Photos of the capacity plate or gallons pumped, and measurements","show_if":"grease_trap.systems_count>0","info":"Take the grease trap's capacity plate. If there is none, the gallons pumped. Add the measurements too."}$j$::jsonb,
      $j${"key":"lift_station.access_photos","type":"photos","label":"Lift station access","short":"Access","show_if":"lift_station.count>0","optional":true,"max_photos":3}$j$::jsonb,
      $j${"key":"lift_station.control_panel_photos","type":"photos","label":"Lift station control panel","short":"Control panel","show_if":"lift_station.count>0","max_photos":3}$j$::jsonb,
      $j${"key":"lift_station.photos","type":"photos","label":"Lift station","show_if":"lift_station.count>0"}$j$::jsonb,
      $j${"key":"water_tank.capacity_photos","type":"photos","label":"Water tank capacity","short":"Capacity","show_if":"water_tank.count>0","max_photos":3}$j$::jsonb,
      $j${"key":"water_tank.photos","type":"photos","label":"Water tank","show_if":"water_tank.count>0"}$j$::jsonb)) x loop
    select q into qv3 from jsonb_array_elements(v3 -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ->> 'key' = v_q ->> 'key';
    if qv3 is distinct from v_q then raise exception 'VERIFY 2c: % is % (wanted %)', v_q ->> 'key', qv3, v_q; end if;
  end loop;
  if (select count(*) from jsonb_array_elements(v3 -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ? 'show_if') <> 24
     or (select count(*) from jsonb_array_elements(v3 -> 'sections') s, jsonb_array_elements(s -> 'questions') q where not (q ? 'show_if')) <> 15
     or (select count(*) from jsonb_array_elements(v3 -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ->> 'type' = 'photos') <> 11
     or (select array_agg(q ->> 'key' order by q ->> 'key') from jsonb_array_elements(v3 -> 'sections') s, jsonb_array_elements(s -> 'questions') q
          where (q -> 'optional') = 'true'::jsonb)
        is distinct from array['access_entry.alarm_photos','access_entry.obstacles','grease_trap.capacity_gallons','grease_trap.capacity_measure','lift_station.access_photos'] then
    raise exception 'VERIFY 2d: the counts (24 conditional, 15 top-level, 11 photos, 5 optional) do not hold';
  end if;

  -- V3. The rules on the new tree (the study's probe t3.sql): count 1 with the control panel and the station and no access
  -- photo misses nothing; the station alone misses the control panel; the water tank photo alone misses the capacity
  -- photo; both miss nothing; counts 0 miss nothing; the full list normalises to itself; the two new keys alone are
  -- pruned; the access photo's parent is the count; the access photo is never required.
  v_ls := array['lift_station.count','lift_station.access_photos','lift_station.control_panel_photos','lift_station.photos',
                'water_tank.count','water_tank.manhole_count','water_tank.capacity','water_tank.capacity_photos','water_tank.photos'];
  if public.fn_intake_missing(v3, to_jsonb(v_ls), '{"lift_station.count":{"value":1},"lift_station.control_panel_photos":{"value":["a"]},"lift_station.photos":{"value":["b"]},"water_tank.count":{"value":0}}') <> '{}'::text[]
     or public.fn_intake_missing(v3, to_jsonb(v_ls), '{"lift_station.count":{"value":1},"lift_station.photos":{"value":["b"]},"water_tank.count":{"value":0}}') is distinct from array['lift_station.control_panel_photos']
     or public.fn_intake_missing(v3, to_jsonb(v_ls), '{"lift_station.count":{"value":0},"water_tank.count":{"value":1},"water_tank.manhole_count":{"value":1},"water_tank.capacity":{"value":"500"},"water_tank.photos":{"value":["c"]}}') is distinct from array['water_tank.capacity_photos']
     or public.fn_intake_missing(v3, to_jsonb(v_ls), '{"lift_station.count":{"value":0},"water_tank.count":{"value":1},"water_tank.manhole_count":{"value":1},"water_tank.capacity":{"value":"500"},"water_tank.photos":{"value":["c"]},"water_tank.capacity_photos":{"value":["d"]}}') <> '{}'::text[]
     or public.fn_intake_missing(v3, to_jsonb(v_ls), '{"lift_station.count":{"value":0},"water_tank.count":{"value":0}}') <> '{}'::text[] then
    raise exception 'VERIFY 3a: fn_intake_missing does not follow the new slots';
  end if;
  if public.fn_intake_normalise_requested(v3, v_order) is distinct from v_order
     or public.fn_intake_prune_requested(v3, array['lift_station.access_photos','water_tank.capacity_photos']) <> '{}'::text[]
     or public.fn_intake_parent_key(v3, 'lift_station.access_photos') is distinct from 'lift_station.count'
     or public.fn_intake_required(v3, '{"lift_station.count":{"value":1}}', 'lift_station.access_photos')
     or not public.fn_intake_required(v3, '{"lift_station.count":{"value":1}}', 'lift_station.control_panel_photos')
     or not public.fn_intake_required(v3, '{"water_tank.count":{"value":2}}', 'water_tank.capacity_photos') then
    raise exception 'VERIFY 3b: normalise, prune, parent or required is wrong on the new tree';
  end if;

  -- V4. The Client App's reader: 39 rows, 15 top-level, the new section's three rows, and no "short" or "info" column.
  if (select count(*) from client.v_intake_questions) <> 39 or (select count(*) from client.v_intake_questions where show_if is null) <> 15
     or (select count(*) from client.v_intake_questions where section_id = 'lift_station_photos') <> 3 then
    raise exception 'VERIFY 4: client.v_intake_questions does not read the version 3 tree';
  end if;

  -- V5. Grants unchanged.
  if (select proacl::text from pg_proc where oid = 'public.fn_intake_form_current()'::regprocedure)
     is distinct from '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}' then
    raise exception 'VERIFY 5: fn_intake_form_current grants changed';
  end if;

  begin
    -- V6. A new link, made as Fred through the real RPC, freezes version 3 (with the flag) and asks the new questions.
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    v_r := client.schedule_property_intake(1164, v_order);
    reset role;
    if (v_r ->> 'form_version') <> '3' or not (v_r -> 'requested' ? 'lift_station.access_photos')
       or not (v_r -> 'requested' ? 'water_tank.capacity_photos') or jsonb_array_length(v_r -> 'requested') <> 39 then
      raise exception 'VERIFY 6: a new link is not version 3 with all 39 questions: %', v_r - 'url';
    end if;
    if (select form_snapshot from public.property_intakes where id = (v_r ->> 'intake_id')::bigint) is distinct from v3 then
      raise exception 'VERIFY 6b: the new link did not freeze the version 3 tree';
    end if;
    raise exception 'VERIFY_ROLLBACK_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_ROLLBACK_SENTINEL' then raise; end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'VERIFY: version 3 has the 39 questions in order, the flag, only the named ones changed, the rules hold, the Client App reads it, a new link freezes it';
end $verify$;

drop table _intake_tree_v2;

notify pgrst, 'reload schema';
