-- ============================================================================
-- 2026-10-22_1306 Site survey question list version 5: the grease trap's model or its measurements (Trello 6t3RDVkE)
-- ============================================================================
-- THE ASK: Yan (2026-10-21) "if we know the model of the grease trap we don't need to measure it"; Fred (2026-10-22)
--   "either to have a free text where we can put the measurements ourselves, or we can put the grease trap model so we
--   can do this lookup using AI", and on the rendered form he picked B: pick one first.
--   Spec: Building Apps/Picture Planner/docs/specs/2026-10-22-grease-trap-model-lookup-design.md (plan step 5).
-- WHAT CHANGES: public.fn_intake_form_current, question list version 5, the grease trap section only:
--   NEW grease_trap.size_from (choice "How can you give us its size?": Model on the plate / Measurements, optional, shown
--   when systems_count > 0); NEW grease_trap.model (text, shown for "Model on the plate", one line, 100 characters, with an
--   (i)); grease_trap.capacity_measure (same key, same meaning) now shown for "Measurements", with an (i) "Length, width and
--   depth, in inches."; Gallons moves after them, unchanged. Every other section is byte-identical (VERIFY 2). Keys are
--   append-only (intake reference rule 2): the 40 keys of version 4 all stay. Forms already sent keep their own list.
--   The collector form needs no change (it already draws a choice with a follow-up, and the show_if grammar trims both
--   sides only, so "Model on the plate" matches as typed); the Client App's Schedule dialog adds follow-ups by parent key.
--   A submitted model or measurements text is looked up by edge fn intake-size-lookup (parts 1 and 2).
-- RULE 8: no table. ROLLBACK: 2026-10-22_rollback_intake_form_v5.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.fn_intake_form_current'::regproc)) IS DISTINCT FROM '43b6d8fad3d0c76e07a6b964bfd46767' THEN
    RAISE EXCEPTION 'fn_intake_form_current changed since this file was written: build again';
  END IF;
END $g$;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS SELECT proacl::text AS a FROM pg_proc WHERE oid = 'public.fn_intake_form_current'::regproc;

CREATE FUNCTION pg_temp.form_v4()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select '{
  "version": 4,
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
            "Outside",
            "Inside and Outside"
          ]
        },
        {
          "key": "access_entry.where_inside",
          "type": "choice",
          "label": "Where is it inside?",
          "options": [
            "Kitchen",
            "Other"
          ],
          "show_if": "access_entry.equipment_where=Inside|Inside and Outside"
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
          "show_if": "access_entry.equipment_where=Outside|Inside and Outside"
        },
        {
          "key": "access_entry.where_outside_note",
          "type": "text",
          "label": "If other, where outside?",
          "show_if": "access_entry.where_outside=Other"
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

CREATE OR REPLACE FUNCTION public.fn_intake_form_current()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select '{
  "version": 5,
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
            "Outside",
            "Inside and Outside"
          ]
        },
        {
          "key": "access_entry.where_inside",
          "type": "choice",
          "label": "Where is it inside?",
          "options": [
            "Kitchen",
            "Other"
          ],
          "show_if": "access_entry.equipment_where=Inside|Inside and Outside"
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
          "show_if": "access_entry.equipment_where=Outside|Inside and Outside"
        },
        {
          "key": "access_entry.where_outside_note",
          "type": "text",
          "label": "If other, where outside?",
          "show_if": "access_entry.where_outside=Other"
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
          "key": "grease_trap.size_from",
          "type": "choice",
          "label": "How can you give us its size?",
          "show_if": "grease_trap.systems_count>0",
          "optional": true,
          "options": ["Model on the plate", "Measurements"]
        },
        {
          "key": "grease_trap.model",
          "type": "text",
          "label": "Grease trap model",
          "show_if": "grease_trap.size_from=Model on the plate",
          "optional": true,
          "single_line": true,
          "max_chars": 100,
          "info": "The brand and model on the plate, for example Zurn GT2700-100. We look up its size, so you do not have to measure it."
        },
        {
          "key": "grease_trap.capacity_measure",
          "type": "text",
          "label": "Measurements",
          "show_if": "grease_trap.size_from=Measurements",
          "optional": true,
          "single_line": true,
          "max_chars": 200,
          "info": "Length, width and depth, in inches."
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

DO $v$
DECLARE t jsonb := public.fn_intake_form_current(); o jsonb := pg_temp.form_v4(); k text; s jsonb; ans jsonb;
BEGIN
  IF (SELECT a FROM acl_before) IS DISTINCT FROM (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_intake_form_current'::regproc) THEN
    RAISE EXCEPTION 'V1: ACL changed';
  END IF;
  -- V2 version 5; every section but the grease trap's byte-identical; photo_note_required kept
  IF (t ->> 'version') <> '5' OR (t - 'version' - 'sections') IS DISTINCT FROM (o - 'version' - 'sections') THEN RAISE EXCEPTION 'V2: top level'; END IF;
  IF (SELECT jsonb_agg(x ORDER BY n) FROM jsonb_array_elements(t -> 'sections') WITH ORDINALITY e(x, n) WHERE x ->> 'id' <> 'grease_trap')
     IS DISTINCT FROM (SELECT jsonb_agg(x ORDER BY n) FROM jsonb_array_elements(o -> 'sections') WITH ORDINALITY e(x, n) WHERE x ->> 'id' <> 'grease_trap') THEN
    RAISE EXCEPTION 'V2: another section moved';
  END IF;
  -- V3 keys append-only: every version 4 key stays, plus exactly the two new ones; the section's order
  IF EXISTS (SELECT 1 FROM jsonb_path_query(o, '$.sections[*].questions[*].key') k4 WHERE NOT (SELECT jsonb_agg(x) FROM jsonb_path_query(t, '$.sections[*].questions[*].key') x) @> jsonb_build_array(k4)) THEN
    RAISE EXCEPTION 'V3: a version 4 key is gone';
  END IF;
  IF (SELECT count(*) FROM jsonb_path_query(t, '$.sections[*].questions[*].key')) <> (SELECT count(*) FROM jsonb_path_query(o, '$.sections[*].questions[*].key')) + 2 THEN
    RAISE EXCEPTION 'V3: key count';
  END IF;
  s := (SELECT x FROM jsonb_array_elements(t -> 'sections') x WHERE x ->> 'id' = 'grease_trap');
  IF (SELECT string_agg(q ->> 'key', ',' ORDER BY n) FROM jsonb_array_elements(s -> 'questions') WITH ORDINALITY e(q, n))
     <> 'grease_trap.systems_count,site_map.gt_location,grease_trap.cleanouts_count,grease_trap.manhole_count,grease_trap.photos,grease_trap.capacity_photos,grease_trap.size_from,grease_trap.model,grease_trap.capacity_measure,grease_trap.capacity_gallons,grease_trap.sample_ports' THEN
    RAISE EXCEPTION 'V3: grease trap order %', (SELECT string_agg(q ->> 'key', ',' ORDER BY n) FROM jsonb_array_elements(s -> 'questions') WITH ORDINALITY e(q, n));
  END IF;
  -- V4 every show_if names a key of the list
  FOR k IN SELECT public.fn_intake_parent_key(t, q ->> 'key') FROM jsonb_path_query(t, '$.sections[*].questions[*]') q WHERE q ? 'show_if' LOOP
    IF NOT EXISTS (SELECT 1 FROM jsonb_path_query(t, '$.sections[*].questions[*].key') x WHERE x #>> '{}' = k) THEN RAISE EXCEPTION 'V4: parent % missing', k; END IF;
  END LOOP;
  -- V5 what is shown, through THE rule
  ans := '{"grease_trap.systems_count": {"value": 1}, "grease_trap.size_from": {"value": "Model on the plate"}}';
  IF NOT public.fn_intake_applicable(t, ans, 'grease_trap.model') OR public.fn_intake_applicable(t, ans, 'grease_trap.capacity_measure')
     OR NOT public.fn_intake_applicable(t, ans, 'grease_trap.capacity_gallons') THEN RAISE EXCEPTION 'V5: model picked'; END IF;
  ans := '{"grease_trap.systems_count": {"value": 1}, "grease_trap.size_from": {"value": " Measurements "}}';
  IF public.fn_intake_applicable(t, ans, 'grease_trap.model') OR NOT public.fn_intake_applicable(t, ans, 'grease_trap.capacity_measure') THEN RAISE EXCEPTION 'V5: measurements picked'; END IF;
  ans := '{"grease_trap.systems_count": {"value": 1}}';
  IF public.fn_intake_applicable(t, ans, 'grease_trap.model') OR public.fn_intake_applicable(t, ans, 'grease_trap.capacity_measure')
     OR NOT public.fn_intake_applicable(t, ans, 'grease_trap.size_from') THEN RAISE EXCEPTION 'V5: nothing picked'; END IF;
  ans := '{"grease_trap.systems_count": {"value": 0}, "grease_trap.size_from": {"value": "Model on the plate"}}';
  IF public.fn_intake_applicable(t, ans, 'grease_trap.size_from') OR public.fn_intake_applicable(t, ans, 'grease_trap.model') THEN RAISE EXCEPTION 'V5: no trap'; END IF;
  -- V6 the new questions never block Complete; the full list normalises to itself (no prune, no addition)
  IF EXISTS (SELECT 1 FROM unnest(public.fn_intake_missing(t, (SELECT jsonb_agg(x) FROM jsonb_path_query(t, '$.sections[*].questions[*].key') x),
       '{"grease_trap.systems_count": {"value": 1}, "grease_trap.size_from": {"value": "Model on the plate"}}'::jsonb)) m
       WHERE m IN ('grease_trap.size_from', 'grease_trap.model', 'grease_trap.capacity_measure')) THEN
    RAISE EXCEPTION 'V6: an optional question is missing';
  END IF;
  IF cardinality(public.fn_intake_normalise_requested(t, ARRAY(SELECT x #>> '{}' FROM jsonb_path_query(t, '$.sections[*].questions[*].key') x)))
     <> (SELECT count(*) FROM jsonb_path_query(t, '$.sections[*].questions[*].key')) THEN
    RAISE EXCEPTION 'V6: the full list does not normalise to itself';
  END IF;
  -- V7 forms already sent keep their own list
  IF EXISTS (SELECT 1 FROM public.property_intakes WHERE (form_snapshot ->> 'version') = '5') THEN RAISE EXCEPTION 'V7: a version 5 form already exists'; END IF;
END $v$;

COMMIT;
