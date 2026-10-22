-- ROLLBACK of 2026-10-22_1306_intake_form_v5: question list version 4 again (md5 asserted). Forms sent as version 5
-- keep their own list, which the collector form and every reader still read.
BEGIN;
SET LOCAL lock_timeout = '3s';
CREATE OR REPLACE FUNCTION public.fn_intake_form_current()
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
DO $v$ BEGIN
  IF md5(pg_get_functiondef('public.fn_intake_form_current'::regproc)) <> '43b6d8fad3d0c76e07a6b964bfd46767' THEN RAISE EXCEPTION 'rollback: body not the original'; END IF;
END $v$;
COMMIT;
