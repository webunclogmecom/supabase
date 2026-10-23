-- ============================================================================
-- 2026-10-23_0130 Several grease traps on the site survey, and up to 9 GT / 3 truck pins on the map
-- ============================================================================
-- THE ASK: Yan (Serena's intake thread, 2026-10-22) "what happens when we have three grease trap systems? Does he ask us
--   for the model three times and the measurement three times?"; Fred (2026-10-23) "then if there are more Grease Traps
--   then it should ask for each of them like the measurements or the brand of each, also ... we should be able to put
--   multiple icons of like Grease Traps or Trucks in the map, up to 3 trucks and 9 GT", then "build it too, and test it".
--   Spec: Building Apps/Picture Planner/docs/specs/2026-10-23-several-grease-traps-and-map-pins-design.md
-- WHAT CHANGES (five bodies, md5 guarded, spliced from the live ones):
--   1. public.fn_intake_form_current: question list version 6, the grease trap section only. "How many grease trap
--      systems?" max 9; trap 1 keeps its keys, its location sits with its size questions and gets an (i); NEW keys for
--      traps 2 to 9 (append-only, intake reference rule 2): grease_trap.t<N>.location / .size_from / .model /
--      .capacity_measure / .capacity_gallons, shown when systems_count > N-1. Every other section byte-identical.
--   2. public.fn_intake_size_inputs: also the model and measurements of traps 2 to 9 (same signature, so
--      v_size_lookup_backlog and edge fn intake-size-lookup look them up with no change).
--   3. public.fn_intake_gallons_offer (still THE gallons rule): one trap unchanged; several traps = the TOTAL of each
--      trap's gallons (its own whole Gallons, else the AI's model answer, else its measurements answer), NULL when any
--      trap has none, kind 'traps' with the per-trap list and a readable summary.
--   4. client.accept_intake_answers: a 'traps' offer saves the total or refuses (blocker=traps_incomplete); it never
--      falls back to the trap 1 answer.
--   5. public.fn_site_map_problem: pin keys only gt, gt2..gt9, truck, truck2, truck3 (the map holds up to 9 GT and 3
--      trucks; Picture Planner draws them).
--   No file changes: the collector form, intake-submit and the Client App read the question list generically.
-- RULE 8: no table. ROLLBACK: 2026-10-23_rollback_several_grease_traps.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.fn_intake_form_current()'::regprocedure)) IS DISTINCT FROM 'b87ef418d8adff674c4383e3b9e08935' THEN
    RAISE EXCEPTION 'public.fn_intake_form_current() changed since this file was written: build again';
  END IF;
  IF md5(pg_get_functiondef('public.fn_intake_size_inputs(bigint)'::regprocedure)) IS DISTINCT FROM 'a483ebb1e0e1b5d530ae89eb47a04cce' THEN
    RAISE EXCEPTION 'public.fn_intake_size_inputs(bigint) changed since this file was written: build again';
  END IF;
  IF md5(pg_get_functiondef('public.fn_intake_gallons_offer(bigint)'::regprocedure)) IS DISTINCT FROM '587110f3dc4357ff604cd61f7d31ac8e' THEN
    RAISE EXCEPTION 'public.fn_intake_gallons_offer(bigint) changed since this file was written: build again';
  END IF;
  IF md5(pg_get_functiondef('client.accept_intake_answers(bigint,text[],jsonb)'::regprocedure)) IS DISTINCT FROM '2051e77eb871d0ba952d34de931a2956' THEN
    RAISE EXCEPTION 'client.accept_intake_answers(bigint,text[],jsonb) changed since this file was written: build again';
  END IF;
  IF md5(pg_get_functiondef('public.fn_site_map_problem(jsonb)'::regprocedure)) IS DISTINCT FROM '58f0be06097db41f404c1fc715435562' THEN
    RAISE EXCEPTION 'public.fn_site_map_problem(jsonb) changed since this file was written: build again';
  END IF;
END $g$;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS SELECT oid, proacl::text AS a FROM pg_proc WHERE oid IN ('public.fn_intake_form_current()'::regprocedure, 'public.fn_intake_size_inputs(bigint)'::regprocedure, 'public.fn_intake_gallons_offer(bigint)'::regprocedure, 'client.accept_intake_answers(bigint,text[],jsonb)'::regprocedure, 'public.fn_site_map_problem(jsonb)'::regprocedure);
CREATE TEMP TABLE other_fns ON COMMIT DROP AS
  SELECT p.oid, md5(pg_get_functiondef(p.oid)) AS m FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('public', 'client') AND p.prokind = 'f' AND p.oid NOT IN ('public.fn_intake_form_current()'::regprocedure, 'public.fn_intake_size_inputs(bigint)'::regprocedure, 'public.fn_intake_gallons_offer(bigint)'::regprocedure, 'client.accept_intake_answers(bigint,text[],jsonb)'::regprocedure, 'public.fn_site_map_problem(jsonb)'::regprocedure);
CREATE TEMP TABLE v5 ON COMMIT DROP AS SELECT public.fn_intake_form_current() AS f;

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
          "type": "number",
          "label": "How many grease trap systems?",
          "max": 9
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
          "info": "Take the grease trap''s capacity plate. If there is none, the gallons pumped. Add the measurements too.",
          "type": "photos",
          "label": "Photos of the capacity plate or gallons pumped, and measurements",
          "show_if": "grease_trap.systems_count>0"
        },
        {
          "key": "site_map.gt_location",
          "type": "gps_pin",
          "label": "Grease trap location",
          "show_if": "grease_trap.systems_count>0",
          "info": "If there are several grease traps, pin the first one here. The form then asks for each of the others."
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

CREATE OR REPLACE FUNCTION public.fn_intake_size_inputs(p_intake_id bigint)
 RETURNS TABLE(question_key text, kind text, input_text text, input_key text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select k.question_key, k.kind, public.fn_intake_trim(i.answers -> k.question_key ->> 'value'),
         public.fn_size_lookup_key(i.answers -> k.question_key ->> 'value')
    from public.property_intakes i
    cross join (values ('grease_trap.model', 'model'),
                       ('grease_trap.capacity_measure', 'measurements'),
                       ('grease_trap.t2.model', 'model'),
                       ('grease_trap.t2.capacity_measure', 'measurements'),
                       ('grease_trap.t3.model', 'model'),
                       ('grease_trap.t3.capacity_measure', 'measurements'),
                       ('grease_trap.t4.model', 'model'),
                       ('grease_trap.t4.capacity_measure', 'measurements'),
                       ('grease_trap.t5.model', 'model'),
                       ('grease_trap.t5.capacity_measure', 'measurements'),
                       ('grease_trap.t6.model', 'model'),
                       ('grease_trap.t6.capacity_measure', 'measurements'),
                       ('grease_trap.t7.model', 'model'),
                       ('grease_trap.t7.capacity_measure', 'measurements'),
                       ('grease_trap.t8.model', 'model'),
                       ('grease_trap.t8.capacity_measure', 'measurements'),
                       ('grease_trap.t9.model', 'model'),
                       ('grease_trap.t9.capacity_measure', 'measurements')) k(question_key, kind)
   where i.id = p_intake_id
     and i.submitted_at is not null and i.cancelled_at is null
     and coalesce(i.requested ? k.question_key, false)
     and jsonb_typeof(i.answers -> k.question_key -> 'value') = 'string'
     and public.fn_intake_trim(i.answers -> k.question_key ->> 'value') <> ''
     and public.fn_intake_applicable(i.form_snapshot, i.answers, k.question_key);
$function$;

CREATE OR REPLACE FUNCTION public.fn_intake_gallons_offer(p_intake_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- THE gallons rule (get_intake_compare shows it, accept_intake_answers saves it; the app never sends the number).
-- One grease trap (every form before question list 6, and a list 6 form counting one): exactly the rule of 2026-10-22,
-- the collector's own whole Gallons wins, otherwise the AI's model answer, else its measurements answer.
-- Several traps (2026-10-23, Fred: "if there are more Grease Traps then it should ask for each of them"): each trap's
-- gallons the same way, and the offer is their TOTAL, the number the property keeps. A trap without a number makes the
-- total NULL (never a part total); kind 'traps' and the list say which trap is missing.
declare
  i public.property_intakes%rowtype;
  v_key text; v_typed integer; v_l record;
  v_traps jsonb := '[]'::jsonb; v_lines text[] := '{}'; v_total integer := 0; v_missing boolean := false;
begin
  select * into i from public.property_intakes where id = p_intake_id;
  if not found then return null; end if;
  if not (coalesce(i.requested ? 'grease_trap.t2.capacity_gallons', false)
          and public.fn_intake_applicable(i.form_snapshot, i.answers, 'grease_trap.t2.capacity_gallons')) then
    return (select case
               when coalesce(public.fn_intake_whole_gallons(i.answers -> 'grease_trap.capacity_gallons' -> 'value') between 1 and 20000, false)
                    and public.fn_intake_applicable(i.form_snapshot, i.answers, 'grease_trap.capacity_gallons') then null
               else (select jsonb_build_object('gallons', g.gallons, 'lookup_id', g.id, 'kind', g.kind,
                              'input_text', x.input_text, 'summary', g.summary, 'source_url', g.source_url)
                       from public.fn_intake_size_inputs(i.id) x
                       join public.grease_trap_size_lookups g
                         on g.kind = x.kind and g.input_key = x.input_key and g.status = 'found'
                      order by case x.kind when 'model' then 1 else 2 end
                      limit 1)
             end);
  end if;
  for n in 1..9 loop
    v_key := case when n = 1 then 'grease_trap.capacity_gallons' else 'grease_trap.t' || n || '.capacity_gallons' end;
    continue when n > 1 and not (coalesce(i.requested ? v_key, false) and public.fn_intake_applicable(i.form_snapshot, i.answers, v_key));
    v_typed := case when public.fn_intake_applicable(i.form_snapshot, i.answers, v_key)
                    then public.fn_intake_whole_gallons(i.answers -> v_key -> 'value') end;
    if coalesce(v_typed between 1 and 20000, false) then
      v_total := v_total + v_typed;
      v_traps := v_traps || jsonb_build_object('n', n, 'gallons', v_typed, 'from', 'typed', 'lookup_id', null,
                   'input_text', public.fn_intake_trim(i.answers -> v_key ->> 'value'), 'summary', null, 'source_url', null);
      v_lines := v_lines || ('Grease trap ' || n || ': ' || to_char(v_typed, 'FM999,999') || ' gal, typed on the form.');
      continue;
    end if;
    select g.id, g.gallons, g.kind, x.input_text, g.summary, g.source_url into v_l
      from public.fn_intake_size_inputs(i.id) x
      join public.grease_trap_size_lookups g on g.kind = x.kind and g.input_key = x.input_key and g.status = 'found'
     where coalesce(substring(x.question_key from '^grease_trap[.]t([2-9])[.]')::int, 1) = n
     order by case x.kind when 'model' then 1 else 2 end
     limit 1;
    if found then
      v_total := v_total + v_l.gallons;
      v_traps := v_traps || jsonb_build_object('n', n, 'gallons', v_l.gallons, 'from', v_l.kind, 'lookup_id', v_l.id,
                   'input_text', v_l.input_text, 'summary', v_l.summary, 'source_url', v_l.source_url);
      v_lines := v_lines || ('Grease trap ' || n || ': ' || to_char(v_l.gallons, 'FM999,999') || ' gal, AI lookup of '
                             || case v_l.kind when 'model' then v_l.input_text else 'the measurements' end || '.');
    else
      v_missing := true;
      v_traps := v_traps || jsonb_build_object('n', n, 'gallons', null, 'from', null, 'lookup_id', null,
                   'input_text', null, 'summary', null, 'source_url', null);
      v_lines := v_lines || ('Grease trap ' || n || ': no gallons yet.');
    end if;
  end loop;
  return jsonb_build_object('kind', 'traps', 'gallons', case when v_missing then null else v_total end, 'lookup_id', null,
           'input_text', jsonb_array_length(v_traps) || ' grease traps', 'source_url', null,
           'summary', array_to_string(v_lines, ' '), 'traps', v_traps);
end
$function$;

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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_site_map_problem(p jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case
    when p is null then null
    when jsonb_typeof(p) <> 'object' then 'the site map must be a JSON object'
    when exists (select 1 from jsonb_object_keys(p) k where k not in ('rev','pins','arrows'))
      then 'the site map may only contain rev, pins and arrows'
    when p ? 'rev' and jsonb_typeof(p->'rev') <> 'number' then 'rev must be a number'
    when p ? 'pins'   and jsonb_typeof(p->'pins')   <> 'object' then 'pins must be an object'
    when p ? 'arrows' and jsonb_typeof(p->'arrows') <> 'array'  then 'arrows must be an array'
    when exists (select 1 from jsonb_object_keys(coalesce(p->'pins','{}'::jsonb)) k where k !~ '^(gt[2-9]?|truck[23]?)$')
      then 'pins may only be gt, gt2 to gt9, truck, truck2 and truck3'
    when jsonb_array_length(coalesce(p->'arrows','[]'::jsonb)) > 10
      then 'at most 10 arrows'
    when exists (
      select 1 from jsonb_each(coalesce(p->'pins','{}'::jsonb)) e(k,v)
      where jsonb_typeof(v) <> 'object'
         or jsonb_typeof(v->'lat') is distinct from 'number'
         or jsonb_typeof(v->'lng') is distinct from 'number'
         or (v->>'lat')::numeric not between -90 and 90
         or (v->>'lng')::numeric not between -180 and 180)
      then 'every pin needs a numeric lat between -90 and 90 and lng between -180 and 180'
    when exists (
      select 1 from jsonb_array_elements(coalesce(p->'arrows','[]'::jsonb)) a
      where jsonb_typeof(a) <> 'object'
         or jsonb_typeof(a->'points') is distinct from 'array'
         or jsonb_array_length(a->'points') < 2
         or jsonb_array_length(a->'points') > 30)
      then 'every arrow needs a points array with 2 to 30 points'
    when exists (
      select 1 from jsonb_array_elements(coalesce(p->'arrows','[]'::jsonb)) a,
                   jsonb_array_elements(a->'points') pt
      where jsonb_typeof(pt) <> 'object'
         or jsonb_typeof(pt->'lat') is distinct from 'number'
         or jsonb_typeof(pt->'lng') is distinct from 'number'
         or (pt->>'lat')::numeric not between -90 and 90
         or (pt->>'lng')::numeric not between -180 and 180)
      then 'every arrow point needs a numeric lat and lng in range'
    when octet_length(p::text) > 16384 then 'the site map is too large (16 KB maximum)'
    else null
  end
$function$;

DO $v$
DECLARE t jsonb := public.fn_intake_form_current(); o jsonb := (SELECT f FROM v5); s jsonb; ans jsonb; k text;
  all_keys jsonb;
BEGIN
  IF EXISTS (SELECT 1 FROM acl_before b JOIN pg_proc p ON p.oid = b.oid WHERE p.proacl::text IS DISTINCT FROM b.a) THEN RAISE EXCEPTION 'V1: ACL changed'; END IF;
  -- V2 version 6; every section but the grease trap's byte-identical
  IF (t ->> 'version') <> '6' OR (t - 'version' - 'sections') IS DISTINCT FROM (o - 'version' - 'sections') THEN RAISE EXCEPTION 'V2: top level'; END IF;
  IF (SELECT jsonb_agg(x ORDER BY n) FROM jsonb_array_elements(t -> 'sections') WITH ORDINALITY e(x, n) WHERE x ->> 'id' <> 'grease_trap')
     IS DISTINCT FROM (SELECT jsonb_agg(x ORDER BY n) FROM jsonb_array_elements(o -> 'sections') WITH ORDINALITY e(x, n) WHERE x ->> 'id' <> 'grease_trap') THEN
    RAISE EXCEPTION 'V2: another section moved';
  END IF;
  -- V3 append-only keys: all of version 5, plus exactly 40, unique; the section's order
  all_keys := (SELECT jsonb_agg(x) FROM jsonb_path_query(t, '$.sections[*].questions[*].key') x);
  IF EXISTS (SELECT 1 FROM jsonb_path_query(o, '$.sections[*].questions[*].key') k5 WHERE NOT all_keys @> jsonb_build_array(k5)) THEN RAISE EXCEPTION 'V3: a version 5 key is gone'; END IF;
  IF jsonb_array_length(all_keys) <> (SELECT count(*) FROM jsonb_path_query(o, '$.sections[*].questions[*].key')) + 40
     OR (SELECT count(DISTINCT x) FROM jsonb_array_elements_text(all_keys) x) <> jsonb_array_length(all_keys) THEN RAISE EXCEPTION 'V3: key count'; END IF;
  s := (SELECT x FROM jsonb_array_elements(t -> 'sections') x WHERE x ->> 'id' = 'grease_trap');
  IF (SELECT string_agg(q ->> 'key', ',' ORDER BY n) FROM jsonb_array_elements(s -> 'questions') WITH ORDINALITY e(q, n)) NOT LIKE
     'grease_trap.systems_count,grease_trap.cleanouts_count,grease_trap.manhole_count,grease_trap.photos,grease_trap.capacity_photos,site_map.gt_location,grease_trap.size_from,grease_trap.model,grease_trap.capacity_measure,grease_trap.capacity_gallons,grease_trap.t2.location,grease_trap.t2.size_from,grease_trap.t2.model,grease_trap.t2.capacity_measure,grease_trap.t2.capacity_gallons,%,grease_trap.t9.capacity_gallons,grease_trap.sample_ports' THEN
    RAISE EXCEPTION 'V3: grease trap order';
  END IF;
  IF (s -> 'questions' -> 0 ->> 'max') <> '9' THEN RAISE EXCEPTION 'V3: systems_count max'; END IF;
  -- V4 every show_if names a key of the list
  FOR k IN SELECT public.fn_intake_parent_key(t, q ->> 'key') FROM jsonb_path_query(t, '$.sections[*].questions[*]') q WHERE q ? 'show_if' LOOP
    IF NOT all_keys @> jsonb_build_array(k) THEN RAISE EXCEPTION 'V4: parent % missing', k; END IF;
  END LOOP;
  -- V5 what is shown, through THE rule
  ans := '{"grease_trap.systems_count": {"value": 3}, "grease_trap.t2.size_from": {"value": "Model on the plate"}, "grease_trap.t3.size_from": {"value": "Measurements"}}';
  IF NOT (public.fn_intake_applicable(t, ans, 'grease_trap.t2.location') AND public.fn_intake_applicable(t, ans, 'grease_trap.t3.capacity_gallons')
          AND public.fn_intake_applicable(t, ans, 'grease_trap.t2.model') AND NOT public.fn_intake_applicable(t, ans, 'grease_trap.t2.capacity_measure')
          AND public.fn_intake_applicable(t, ans, 'grease_trap.t3.capacity_measure') AND NOT public.fn_intake_applicable(t, ans, 'grease_trap.t3.model')
          AND NOT public.fn_intake_applicable(t, ans, 'grease_trap.t4.size_from') AND NOT public.fn_intake_applicable(t, ans, 'grease_trap.t4.location')
          AND public.fn_intake_applicable(t, ans, 'site_map.gt_location') AND public.fn_intake_applicable(t, ans, 'grease_trap.size_from')) THEN
    RAISE EXCEPTION 'V5: three traps';
  END IF;
  ans := '{"grease_trap.systems_count": {"value": 1}}';
  IF public.fn_intake_applicable(t, ans, 'grease_trap.t2.size_from') OR public.fn_intake_applicable(t, ans, 'grease_trap.t2.location') THEN RAISE EXCEPTION 'V5: one trap'; END IF;
  ans := '{"grease_trap.systems_count": {"value": 9}}';
  IF NOT public.fn_intake_applicable(t, ans, 'grease_trap.t9.location') THEN RAISE EXCEPTION 'V5: nine traps'; END IF;
  -- V6 a trap's location pin is required like trap 1's; its size questions never block Complete; the list normalises to itself
  IF (SELECT array_agg(m ORDER BY m) FROM unnest(public.fn_intake_missing(t, (SELECT jsonb_agg(x) FROM jsonb_path_query(t, '$.sections[*].questions[*].key') x),
       '{"grease_trap.systems_count": {"value": 3}, "grease_trap.t2.size_from": {"value": "Model on the plate"}}'::jsonb)) m WHERE m LIKE 'grease_trap.t%')
     IS DISTINCT FROM ARRAY['grease_trap.t2.location', 'grease_trap.t3.location'] THEN
    RAISE EXCEPTION 'V6: missing for three traps';
  END IF;
  IF cardinality(public.fn_intake_normalise_requested(t, ARRAY(SELECT x FROM jsonb_array_elements_text(all_keys) x))) <> jsonb_array_length(all_keys) THEN
    RAISE EXCEPTION 'V6: the full list does not normalise to itself';
  END IF;
  -- V7 the lookup inputs name traps 2 to 9
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.fn_intake_size_inputs(bigint)'::regprocedure) NOT LIKE '%grease_trap.t9.capacity_measure%' THEN RAISE EXCEPTION 'V7: inputs'; END IF;
  -- V8 the map: up to 9 GT and 3 trucks, nothing else; every stored map still valid
  IF public.fn_site_map_problem('{"pins":{"gt":{"lat":1,"lng":1},"gt9":{"lat":1,"lng":1},"truck":{"lat":1,"lng":1},"truck3":{"lat":1,"lng":1}}}') IS NOT NULL
     OR public.fn_site_map_problem('{"pins":{"gt10":{"lat":1,"lng":1}}}') IS NULL OR public.fn_site_map_problem('{"pins":{"truck4":{"lat":1,"lng":1}}}') IS NULL
     OR public.fn_site_map_problem('{"pins":{"foo":{"lat":1,"lng":1}}}') IS NULL OR public.fn_site_map_problem('{"pins":{"gt1":{"lat":1,"lng":1}}}') IS NULL THEN
    RAISE EXCEPTION 'V8: pin keys';
  END IF;
  IF EXISTS (SELECT 1 FROM public.properties WHERE public.fn_site_map_problem(site_map) IS NOT NULL)
     OR EXISTS (SELECT 1 FROM public.property_pages WHERE public.fn_site_map_problem(nullif(content -> 'site_map', 'null'::jsonb)) IS NOT NULL) THEN
    RAISE EXCEPTION 'V8: a stored map no longer passes';
  END IF;
  -- V9 nothing else moved
  IF EXISTS (SELECT 1 FROM other_fns o2 LEFT JOIN pg_proc p ON p.oid = o2.oid WHERE p.oid IS NULL OR md5(pg_get_functiondef(p.oid)) <> o2.m) THEN
    RAISE EXCEPTION 'V9: another function changed';
  END IF;
END $v$;

COMMIT;
