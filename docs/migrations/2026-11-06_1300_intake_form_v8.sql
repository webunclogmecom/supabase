-- ============================================================================
-- 2026-11-06 Site survey question list, version 8: Yan's four changes on the form
-- ============================================================================
-- THE ASK: Yan (2026-11-05, on the Collector training film): "if there's an alarm is it asking them to show us where the pad is. And if
--   it's inside there the light switch are. About the time we can come, we should tell them that if they don't know the office will do
--   it. When there multiple GT and they are next to each other we don't need to drop multiple pin it tell them to put at the same place".
--   Fred offered the exact wording in the thread; Yan: "perfect" (2026-11-06). Fred: the light switches are a normal question.
-- WHAT CHANGES: public.fn_intake_form_current, version 7 to 8.
--   access_entry.alarm_instruction: the label, the same key, because the answer is the same thing asked more exactly.
--   NEW access_entry.light_switches: text, only when the equipment is Inside or Inside and Outside, right after the inside location.
--   access_hours.schedule and site_map.gt_location: one more sentence in their hints. grease_trap.t2 to t9.location: a hint each.
--   82 questions, 30 hints. The form page draws all of this as it stands. Forms already sent keep their own list.
-- NOT HERE: the Site file row for the light switches is a Picture Planner change (the facts are free keys, no database list).
-- RULE 8: no table. ROLLBACK: 2026-11-06_1300_intake_form_v8_rollback.sql (the previous body).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.fn_intake_form_current'::regproc)) IS DISTINCT FROM 'ad99eface997127ffafedfad729be3b5' THEN
    RAISE EXCEPTION 'fn_intake_form_current changed since this file was written: build again';
  END IF;
END $g$;
CREATE TEMP TABLE before_f ON COMMIT DROP AS SELECT public.fn_intake_form_current() AS f,
  (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_intake_form_current'::regproc) AS acl;
CREATE TEMP TABLE before_q ON COMMIT DROP AS SELECT count(*) AS n FROM client.v_intake_questions;
CREATE TEMP TABLE before_i ON COMMIT DROP AS SELECT count(*) AS n FROM public.property_intakes WHERE form_snapshot @> '{"sections":[{"questions":[{"key":"access_entry.light_switches"}]}]}';

CREATE OR REPLACE FUNCTION public.fn_intake_form_current()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select '{
  "version": 8,
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
          "info": "Ask the general manager or the person in charge.",
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
          "key": "access_entry.light_switches",
          "type": "text",
          "label": "Where are the light switches?",
          "show_if": "access_entry.equipment_where=Inside|Inside and Outside"
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
          "label": "Where is the alarm pad, and how do we turn it off?",
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
          "label": "When can we come?",
          "info": "The hours our truck can come, not when the business is open. Ask the general manager or the person in charge. If nobody knows, leave it blank and the office will take care of it."
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
          "info": "If there are several grease traps, pin the first one here. The form then asks for each of the others. If they are next to each other, put the pins in the same place.",
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
          "info": "If it is next to another grease trap, put the pin in the same place.",
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
          "info": "If it is next to another grease trap, put the pin in the same place.",
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
          "info": "If it is next to another grease trap, put the pin in the same place.",
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
          "info": "If it is next to another grease trap, put the pin in the same place.",
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
          "info": "If it is next to another grease trap, put the pin in the same place.",
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
          "info": "If it is next to another grease trap, put the pin in the same place.",
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
          "info": "If it is next to another grease trap, put the pin in the same place.",
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
          "info": "If it is next to another grease trap, put the pin in the same place.",
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
DECLARE
  t jsonb := public.fn_intake_form_current();
  e jsonb := (SELECT f FROM before_f);
  r record;
  ins_s text;
  ins_q text;
BEGIN
  -- V1 the grants did not move
  IF (SELECT acl FROM before_f) IS DISTINCT FROM (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_intake_form_current'::regproc) THEN RAISE EXCEPTION 'V1: ACL changed'; END IF;
  -- V2 the new list IS the old list plus exactly these changes; nothing else moved
  FOR r IN
    SELECT (s.n - 1)::text AS si, (q.m - 1)::text AS qi, q.x ->> 'key' AS k
      FROM jsonb_array_elements(e -> 'sections') WITH ORDINALITY s(x, n),
           jsonb_array_elements(s.x -> 'questions') WITH ORDINALITY q(x, m)
  LOOP
    IF r.k = 'access_entry.alarm_instruction' THEN e := jsonb_set(e, ARRAY['sections', r.si, 'questions', r.qi, 'label'], to_jsonb('Where is the alarm pad, and how do we turn it off?'::text));
    ELSIF r.k = 'access_hours.schedule' THEN e := jsonb_set(e, ARRAY['sections', r.si, 'questions', r.qi, 'info'], to_jsonb('The hours our truck can come, not when the business is open. Ask the general manager or the person in charge. If nobody knows, leave it blank and the office will take care of it.'::text));
    ELSIF r.k = 'site_map.gt_location' THEN e := jsonb_set(e, ARRAY['sections', r.si, 'questions', r.qi, 'info'], to_jsonb('If there are several grease traps, pin the first one here. The form then asks for each of the others. If they are next to each other, put the pins in the same place.'::text));
    ELSIF r.k ~ '^grease_trap[.]t[2-9][.]location$' THEN e := jsonb_set(e, ARRAY['sections', r.si, 'questions', r.qi, 'info'], to_jsonb('If it is next to another grease trap, put the pin in the same place.'::text));
    ELSIF r.k = 'access_entry.where_inside_note' THEN ins_s := r.si; ins_q := r.qi;
    END IF;
  END LOOP;
  -- after the loop: an insert moves the places of the questions behind it
  e := jsonb_insert(e, ARRAY['sections', ins_s, 'questions', ins_q], jsonb_build_object('key', 'access_entry.light_switches', 'type', 'text', 'label', 'Where are the light switches?', 'show_if', 'access_entry.equipment_where=Inside|Inside and Outside'), true);
  e := jsonb_set(e, '{version}', '8'::jsonb);
  IF t IS DISTINCT FROM e THEN RAISE EXCEPTION 'V2: the list is not the old list plus these changes'; END IF;
  -- V3 82 questions where there were 81, 30 hints where there were 22
  IF (SELECT count(*) FROM jsonb_array_elements(t -> 'sections') s, jsonb_array_elements(s -> 'questions') q) <> 82 THEN RAISE EXCEPTION 'V3: question count'; END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(t -> 'sections') s, jsonb_array_elements(s -> 'questions') q WHERE q ? 'info') <> 30 THEN RAISE EXCEPTION 'V3: hint count'; END IF;
  -- V4 the Client App's list holds the one new follow-up, under the equipment tile's section
  IF (SELECT count(*) FROM client.v_intake_questions) IS DISTINCT FROM (SELECT n FROM before_q) + 1 THEN RAISE EXCEPTION 'V4: client.v_intake_questions count'; END IF;
  IF NOT EXISTS (SELECT 1 FROM client.v_intake_questions WHERE question_key = 'access_entry.light_switches' AND section_id = 'access_entry') THEN RAISE EXCEPTION 'V4: new question not in the view'; END IF;
  -- V5 a form's list is frozen: nothing already sent moved
  IF (SELECT n FROM before_i) IS DISTINCT FROM (SELECT count(*) FROM public.property_intakes WHERE form_snapshot @> '{"sections":[{"questions":[{"key":"access_entry.light_switches"}]}]}') THEN RAISE EXCEPTION 'V5: a sent form changed'; END IF;
END $v$;

COMMIT;
