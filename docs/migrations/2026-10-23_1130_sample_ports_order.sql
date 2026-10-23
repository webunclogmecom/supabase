-- ============================================================================
-- 2026-10-23_1130 Site survey question list: "How many sample ports?" right after "How many manholes?"
-- ============================================================================
-- THE ASK: Fred (2026-10-23, on the collector form): 'the question "How many sample ports?" needs to be next to the other
--   questions, but's its below even the maps of the GT locations'. Version 6 (2026-10-23_0130) kept it last in the grease trap
--   section (Serena's 2026-09 placement, "Last, per Serena"), so with several traps it came after every trap's map.
-- WHAT CHANGES: public.fn_intake_form_current, the ORDER of the grease trap section only: grease_trap.sample_ports moves to
--   right after grease_trap.manhole_count (systems, clean outs, manholes, sample ports, photos, capacity photos, the traps).
--   Same keys, same questions byte for byte, same version number (6): order changes never bumped it (0348 moved
--   site_map.gt_location within version 1). Forms already sent keep their own list (form 1120 keeps the old order).
-- RULE 8: no table. ROLLBACK: 2026-10-23_rollback_1130_sample_ports_order.sql (the previous body).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.fn_intake_form_current'::regproc)) IS DISTINCT FROM '8abeb2b1a21e1d62736eb35ca51f2154' THEN
    RAISE EXCEPTION 'fn_intake_form_current changed since this file was written: build again';
  END IF;
END $g$;
CREATE TEMP TABLE before_f ON COMMIT DROP AS SELECT public.fn_intake_form_current() AS f,
  (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_intake_form_current'::regproc) AS acl;

CREATE OR REPLACE FUNCTION public.fn_intake_form_current()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select '{
  "version": 6,
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
          "type": "photos",
          "label": "Photos of the alarm",
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
          "max": 9,
          "type": "number",
          "label": "How many grease trap systems?"
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
          "key": "grease_trap.sample_ports",
          "type": "number",
          "label": "How many sample ports?"
        },
        {
          "key": "grease_trap.photos",
          "type": "photos",
          "label": "Photos, including the manholes and the clean outs",
          "show_if": "grease_trap.systems_count>0"
        },
        {
          "key": "grease_trap.capacity_photos",
          "info": "Take the grease trap''s capacity plate. If there is none, the gallons pumped. Add the measurements too.",
          "type": "photos",
          "label": "Photos of the capacity plate or gallons pumped, and measurements",
          "show_if": "grease_trap.systems_count>0"
        },
        {
          "key": "site_map.gt_location",
          "info": "If there are several grease traps, pin the first one here. The form then asks for each of the others.",
          "type": "gps_pin",
          "label": "Grease trap location",
          "show_if": "grease_trap.systems_count>0"
        },
        {
          "key": "grease_trap.size_from",
          "type": "choice",
          "label": "How can you give us its size?",
          "options": [
            "Model on the plate",
            "Measurements"
          ],
          "show_if": "grease_trap.systems_count>0",
          "optional": true
        },
        {
          "key": "grease_trap.model",
          "info": "The brand and model on the plate, for example Zurn GT2700-100. We look up its size, so you do not have to measure it.",
          "type": "text",
          "label": "Grease trap model",
          "show_if": "grease_trap.size_from=Model on the plate",
          "optional": true,
          "max_chars": 100,
          "single_line": true
        },
        {
          "key": "grease_trap.capacity_measure",
          "info": "Length, width and depth, in inches.",
          "type": "text",
          "label": "Measurements",
          "show_if": "grease_trap.size_from=Measurements",
          "optional": true,
          "max_chars": 200,
          "single_line": true
        },
        {
          "key": "grease_trap.capacity_gallons",
          "type": "text",
          "label": "Gallons",
          "show_if": "grease_trap.systems_count>0",
          "optional": true,
          "max_chars": 50,
          "single_line": true
        },
        {
          "key": "grease_trap.t2.location",
          "type": "gps_pin",
          "label": "Grease trap 2 location",
          "show_if": "grease_trap.systems_count>1"
        },
        {
          "key": "grease_trap.t2.size_from",
          "type": "choice",
          "label": "Grease trap 2: how can you give us its size?",
          "options": [
            "Model on the plate",
            "Measurements"
          ],
          "show_if": "grease_trap.systems_count>1",
          "optional": true
        },
        {
          "key": "grease_trap.t2.model",
          "info": "The brand and model on the plate, for example Zurn GT2700-100. We look up its size, so you do not have to measure it.",
          "type": "text",
          "label": "Grease trap 2 model",
          "show_if": "grease_trap.t2.size_from=Model on the plate",
          "optional": true,
          "max_chars": 100,
          "single_line": true
        },
        {
          "key": "grease_trap.t2.capacity_measure",
          "info": "Length, width and depth, in inches.",
          "type": "text",
          "label": "Grease trap 2 measurements",
          "show_if": "grease_trap.t2.size_from=Measurements",
          "optional": true,
          "max_chars": 200,
          "single_line": true
        },
        {
          "key": "grease_trap.t2.capacity_gallons",
          "type": "text",
          "label": "Grease trap 2 gallons",
          "show_if": "grease_trap.systems_count>1",
          "optional": true,
          "max_chars": 50,
          "single_line": true
        },
        {
          "key": "grease_trap.t3.location",
          "type": "gps_pin",
          "label": "Grease trap 3 location",
          "show_if": "grease_trap.systems_count>2"
        },
        {
          "key": "grease_trap.t3.size_from",
          "type": "choice",
          "label": "Grease trap 3: how can you give us its size?",
          "options": [
            "Model on the plate",
            "Measurements"
          ],
          "show_if": "grease_trap.systems_count>2",
          "optional": true
        },
        {
          "key": "grease_trap.t3.model",
          "info": "The brand and model on the plate, for example Zurn GT2700-100. We look up its size, so you do not have to measure it.",
          "type": "text",
          "label": "Grease trap 3 model",
          "show_if": "grease_trap.t3.size_from=Model on the plate",
          "optional": true,
          "max_chars": 100,
          "single_line": true
        },
        {
          "key": "grease_trap.t3.capacity_measure",
          "info": "Length, width and depth, in inches.",
          "type": "text",
          "label": "Grease trap 3 measurements",
          "show_if": "grease_trap.t3.size_from=Measurements",
          "optional": true,
          "max_chars": 200,
          "single_line": true
        },
        {
          "key": "grease_trap.t3.capacity_gallons",
          "type": "text",
          "label": "Grease trap 3 gallons",
          "show_if": "grease_trap.systems_count>2",
          "optional": true,
          "max_chars": 50,
          "single_line": true
        },
        {
          "key": "grease_trap.t4.location",
          "type": "gps_pin",
          "label": "Grease trap 4 location",
          "show_if": "grease_trap.systems_count>3"
        },
        {
          "key": "grease_trap.t4.size_from",
          "type": "choice",
          "label": "Grease trap 4: how can you give us its size?",
          "options": [
            "Model on the plate",
            "Measurements"
          ],
          "show_if": "grease_trap.systems_count>3",
          "optional": true
        },
        {
          "key": "grease_trap.t4.model",
          "info": "The brand and model on the plate, for example Zurn GT2700-100. We look up its size, so you do not have to measure it.",
          "type": "text",
          "label": "Grease trap 4 model",
          "show_if": "grease_trap.t4.size_from=Model on the plate",
          "optional": true,
          "max_chars": 100,
          "single_line": true
        },
        {
          "key": "grease_trap.t4.capacity_measure",
          "info": "Length, width and depth, in inches.",
          "type": "text",
          "label": "Grease trap 4 measurements",
          "show_if": "grease_trap.t4.size_from=Measurements",
          "optional": true,
          "max_chars": 200,
          "single_line": true
        },
        {
          "key": "grease_trap.t4.capacity_gallons",
          "type": "text",
          "label": "Grease trap 4 gallons",
          "show_if": "grease_trap.systems_count>3",
          "optional": true,
          "max_chars": 50,
          "single_line": true
        },
        {
          "key": "grease_trap.t5.location",
          "type": "gps_pin",
          "label": "Grease trap 5 location",
          "show_if": "grease_trap.systems_count>4"
        },
        {
          "key": "grease_trap.t5.size_from",
          "type": "choice",
          "label": "Grease trap 5: how can you give us its size?",
          "options": [
            "Model on the plate",
            "Measurements"
          ],
          "show_if": "grease_trap.systems_count>4",
          "optional": true
        },
        {
          "key": "grease_trap.t5.model",
          "info": "The brand and model on the plate, for example Zurn GT2700-100. We look up its size, so you do not have to measure it.",
          "type": "text",
          "label": "Grease trap 5 model",
          "show_if": "grease_trap.t5.size_from=Model on the plate",
          "optional": true,
          "max_chars": 100,
          "single_line": true
        },
        {
          "key": "grease_trap.t5.capacity_measure",
          "info": "Length, width and depth, in inches.",
          "type": "text",
          "label": "Grease trap 5 measurements",
          "show_if": "grease_trap.t5.size_from=Measurements",
          "optional": true,
          "max_chars": 200,
          "single_line": true
        },
        {
          "key": "grease_trap.t5.capacity_gallons",
          "type": "text",
          "label": "Grease trap 5 gallons",
          "show_if": "grease_trap.systems_count>4",
          "optional": true,
          "max_chars": 50,
          "single_line": true
        },
        {
          "key": "grease_trap.t6.location",
          "type": "gps_pin",
          "label": "Grease trap 6 location",
          "show_if": "grease_trap.systems_count>5"
        },
        {
          "key": "grease_trap.t6.size_from",
          "type": "choice",
          "label": "Grease trap 6: how can you give us its size?",
          "options": [
            "Model on the plate",
            "Measurements"
          ],
          "show_if": "grease_trap.systems_count>5",
          "optional": true
        },
        {
          "key": "grease_trap.t6.model",
          "info": "The brand and model on the plate, for example Zurn GT2700-100. We look up its size, so you do not have to measure it.",
          "type": "text",
          "label": "Grease trap 6 model",
          "show_if": "grease_trap.t6.size_from=Model on the plate",
          "optional": true,
          "max_chars": 100,
          "single_line": true
        },
        {
          "key": "grease_trap.t6.capacity_measure",
          "info": "Length, width and depth, in inches.",
          "type": "text",
          "label": "Grease trap 6 measurements",
          "show_if": "grease_trap.t6.size_from=Measurements",
          "optional": true,
          "max_chars": 200,
          "single_line": true
        },
        {
          "key": "grease_trap.t6.capacity_gallons",
          "type": "text",
          "label": "Grease trap 6 gallons",
          "show_if": "grease_trap.systems_count>5",
          "optional": true,
          "max_chars": 50,
          "single_line": true
        },
        {
          "key": "grease_trap.t7.location",
          "type": "gps_pin",
          "label": "Grease trap 7 location",
          "show_if": "grease_trap.systems_count>6"
        },
        {
          "key": "grease_trap.t7.size_from",
          "type": "choice",
          "label": "Grease trap 7: how can you give us its size?",
          "options": [
            "Model on the plate",
            "Measurements"
          ],
          "show_if": "grease_trap.systems_count>6",
          "optional": true
        },
        {
          "key": "grease_trap.t7.model",
          "info": "The brand and model on the plate, for example Zurn GT2700-100. We look up its size, so you do not have to measure it.",
          "type": "text",
          "label": "Grease trap 7 model",
          "show_if": "grease_trap.t7.size_from=Model on the plate",
          "optional": true,
          "max_chars": 100,
          "single_line": true
        },
        {
          "key": "grease_trap.t7.capacity_measure",
          "info": "Length, width and depth, in inches.",
          "type": "text",
          "label": "Grease trap 7 measurements",
          "show_if": "grease_trap.t7.size_from=Measurements",
          "optional": true,
          "max_chars": 200,
          "single_line": true
        },
        {
          "key": "grease_trap.t7.capacity_gallons",
          "type": "text",
          "label": "Grease trap 7 gallons",
          "show_if": "grease_trap.systems_count>6",
          "optional": true,
          "max_chars": 50,
          "single_line": true
        },
        {
          "key": "grease_trap.t8.location",
          "type": "gps_pin",
          "label": "Grease trap 8 location",
          "show_if": "grease_trap.systems_count>7"
        },
        {
          "key": "grease_trap.t8.size_from",
          "type": "choice",
          "label": "Grease trap 8: how can you give us its size?",
          "options": [
            "Model on the plate",
            "Measurements"
          ],
          "show_if": "grease_trap.systems_count>7",
          "optional": true
        },
        {
          "key": "grease_trap.t8.model",
          "info": "The brand and model on the plate, for example Zurn GT2700-100. We look up its size, so you do not have to measure it.",
          "type": "text",
          "label": "Grease trap 8 model",
          "show_if": "grease_trap.t8.size_from=Model on the plate",
          "optional": true,
          "max_chars": 100,
          "single_line": true
        },
        {
          "key": "grease_trap.t8.capacity_measure",
          "info": "Length, width and depth, in inches.",
          "type": "text",
          "label": "Grease trap 8 measurements",
          "show_if": "grease_trap.t8.size_from=Measurements",
          "optional": true,
          "max_chars": 200,
          "single_line": true
        },
        {
          "key": "grease_trap.t8.capacity_gallons",
          "type": "text",
          "label": "Grease trap 8 gallons",
          "show_if": "grease_trap.systems_count>7",
          "optional": true,
          "max_chars": 50,
          "single_line": true
        },
        {
          "key": "grease_trap.t9.location",
          "type": "gps_pin",
          "label": "Grease trap 9 location",
          "show_if": "grease_trap.systems_count>8"
        },
        {
          "key": "grease_trap.t9.size_from",
          "type": "choice",
          "label": "Grease trap 9: how can you give us its size?",
          "options": [
            "Model on the plate",
            "Measurements"
          ],
          "show_if": "grease_trap.systems_count>8",
          "optional": true
        },
        {
          "key": "grease_trap.t9.model",
          "info": "The brand and model on the plate, for example Zurn GT2700-100. We look up its size, so you do not have to measure it.",
          "type": "text",
          "label": "Grease trap 9 model",
          "show_if": "grease_trap.t9.size_from=Model on the plate",
          "optional": true,
          "max_chars": 100,
          "single_line": true
        },
        {
          "key": "grease_trap.t9.capacity_measure",
          "info": "Length, width and depth, in inches.",
          "type": "text",
          "label": "Grease trap 9 measurements",
          "show_if": "grease_trap.t9.size_from=Measurements",
          "optional": true,
          "max_chars": 200,
          "single_line": true
        },
        {
          "key": "grease_trap.t9.capacity_gallons",
          "type": "text",
          "label": "Grease trap 9 gallons",
          "show_if": "grease_trap.systems_count>8",
          "optional": true,
          "max_chars": 50,
          "single_line": true
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
          "short": "Control panel",
          "show_if": "lift_station.count>0",
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
DECLARE t jsonb := public.fn_intake_form_current(); o jsonb := (SELECT f FROM before_f); s jsonb; so jsonb;
BEGIN
  IF (SELECT acl FROM before_f) IS DISTINCT FROM (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_intake_form_current'::regproc) THEN RAISE EXCEPTION 'V1: ACL changed'; END IF;
  IF (t - 'sections') IS DISTINCT FROM (o - 'sections') THEN RAISE EXCEPTION 'V2: top level (version) changed'; END IF;
  IF (SELECT jsonb_agg(x ORDER BY n) FROM jsonb_array_elements(t -> 'sections') WITH ORDINALITY e(x, n) WHERE x ->> 'id' <> 'grease_trap')
     IS DISTINCT FROM (SELECT jsonb_agg(x ORDER BY n) FROM jsonb_array_elements(o -> 'sections') WITH ORDINALITY e(x, n) WHERE x ->> 'id' <> 'grease_trap') THEN
    RAISE EXCEPTION 'V2: another section changed';
  END IF;
  s := (SELECT x FROM jsonb_array_elements(t -> 'sections') x WHERE x ->> 'id' = 'grease_trap');
  so := (SELECT x FROM jsonb_array_elements(o -> 'sections') x WHERE x ->> 'id' = 'grease_trap');
  IF (s - 'questions') IS DISTINCT FROM (so - 'questions') THEN RAISE EXCEPTION 'V3: section title changed'; END IF;
  -- V4 the same questions, byte for byte, only the order differs
  IF (SELECT array_agg(q::text ORDER BY q::text) FROM jsonb_array_elements(s -> 'questions') q)
     IS DISTINCT FROM (SELECT array_agg(q::text ORDER BY q::text) FROM jsonb_array_elements(so -> 'questions') q) THEN
    RAISE EXCEPTION 'V4: a question changed';
  END IF;
  -- V5 the new order: sample ports 4th; everything else keeps its relative order
  IF (SELECT string_agg(q ->> 'key', ',' ORDER BY n) FROM jsonb_array_elements(s -> 'questions') WITH ORDINALITY e(q, n) WHERE n <= 6)
     <> 'grease_trap.systems_count,grease_trap.cleanouts_count,grease_trap.manhole_count,grease_trap.sample_ports,grease_trap.photos,grease_trap.capacity_photos' THEN
    RAISE EXCEPTION 'V5: order %', (SELECT string_agg(q ->> 'key', ',' ORDER BY n) FROM jsonb_array_elements(s -> 'questions') WITH ORDINALITY e(q, n) WHERE n <= 6);
  END IF;
  IF (SELECT string_agg(q ->> 'key', ',' ORDER BY n) FROM jsonb_array_elements(s -> 'questions') WITH ORDINALITY e(q, n) WHERE q ->> 'key' <> 'grease_trap.sample_ports')
     <> (SELECT string_agg(q ->> 'key', ',' ORDER BY n) FROM jsonb_array_elements(so -> 'questions') WITH ORDINALITY e(q, n) WHERE q ->> 'key' <> 'grease_trap.sample_ports') THEN
    RAISE EXCEPTION 'V5: another question moved';
  END IF;
  IF (SELECT q ->> 'key' FROM jsonb_array_elements(s -> 'questions') WITH ORDINALITY e(q, n) ORDER BY n DESC LIMIT 1) <> 'grease_trap.t9.capacity_gallons' THEN RAISE EXCEPTION 'V5: last question'; END IF;
END $v$;

COMMIT;
