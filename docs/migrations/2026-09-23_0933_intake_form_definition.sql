-- =============================================================================
-- 2026-09-23_0933_intake_form_definition.sql
-- The question list, now that Yannick has settled the two open items.
--
-- WHAT. The L1/L2 tree the collector form renders and the office picks from, as one
-- immutable function so there is exactly one definition of "the current form".
--
-- WHY A FUNCTION AND NOT A TABLE. intake_form_versions was cut from the plan as
-- speculative: a version table for a form nobody had published once. The intake row
-- already freezes its own form_snapshot at schedule time, which is what makes a 2026
-- submission readable in 2028, so the only thing missing was a single source for
-- "what is current". Same shape as public.fn_intake_accept_map(), which already
-- exists beside it. Changing a question is one migration, and every intake already
-- scheduled keeps the tree it was scheduled with.
--
-- YANNICK'S ANSWERS, 2026-09-23, which this encodes:
--   1. WATER TANK: "yes that's correct if there's a water tank there's no sewer
--      connection". So the water tank is the SITE's tank, NOT the grease trap, and its
--      presence IS the sewer answer. That settles the contradiction between Serena's
--      notes (sewer becomes a Yes/No) and the checklist (no sewer section at all):
--      there is no sewer question, because the Water tank section answers it.
--      ⚠ This also overturns Fred's reading that it might mean the grease trap tank.
--   2. SAMPLE PORT: "this info need to be gotten with a visit, it's part of the grease
--      trap system". So it IS collected on site, and it belongs INSIDE Grease Trap
--      rather than as its own section. Serena's "sample port should be last on the
--      list" is honoured as last WITHIN that section, which is compatible with both.
--
-- ⚠ ONE SHAPE CHANGE TO schedule_property_intake. Its validation read
--   jsonb_array_elements_text(s->'questions'), i.e. questions had to be bare strings.
--   The form needs a label and a type per question to render at all, so questions are
--   now objects and the validator reads q->>'key'. Caught before anything was stored:
--   with the old reader every key would have compared against the JSON text of an
--   object and every schedule call would have failed. p_form_snapshot also now
--   defaults to the current tree, so the app cannot pin a stale one by accident.
--
-- 🛑 QUESTION KEYS ARE APPEND-ONLY. One key is being CORRECTED here and that is only
--    safe because nothing has used it: public.property_intakes holds 0 rows and
--    property_intake_accepts holds 0 rows (asserted below before the change). After
--    this migration, a changed meaning gets a NEW key, never a rename.
--    The correction: sample_port.count -> grease_trap.sample_ports, because Yannick
--    placed it inside the grease trap system.
--
-- RULE 8, AUDIT: no new table, nothing to opt in.
-- ATOMIC: no COMMIT, so a failed assertion rolls the whole migration back.
-- =============================================================================

-- ------------------------------------------------------------ 1. THE FORM TREE
create or replace function public.fn_intake_form_current()
returns jsonb language sql immutable set search_path to '' as $$
  select '{
    "version": 1,
    "sections": [
      {
        "id": "site_map",
        "title": "Site map",
        "questions": [
          {"key":"site_map.gt_location",   "label":"Grease trap location",  "type":"gps_pin"},
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
          {"key":"access_entry.access_point_note","label":"If other, describe it",               "type":"text"},
          {"key":"access_entry.access_photos",   "label":"Photos of the access point",           "type":"photos"},
          {"key":"access_entry.how_access",      "label":"How do we get in?",                    "type":"choice", "options":["Lock box","Key","Open","Someone lets us in"]},
          {"key":"access_entry.lock_box_code",   "label":"Lock box code",                        "type":"text",   "show_if":"access_entry.how_access=Lock box"},
          {"key":"access_entry.lock_box_photos", "label":"Photo of where the lock box is",       "type":"photos", "show_if":"access_entry.how_access=Lock box"},
          {"key":"access_entry.key_instruction", "label":"Key instructions",                     "type":"text",   "show_if":"access_entry.how_access=Key"},
          {"key":"access_entry.alarm",           "label":"Is there an alarm?",                   "type":"yes_no"},
          {"key":"access_entry.alarm_instruction","label":"Alarm instructions",                  "type":"text",   "show_if":"access_entry.alarm=yes"},
          {"key":"access_entry.where_inside",    "label":"Where is it inside?",                  "type":"choice", "options":["Kitchen","Other"], "show_if":"access_entry.equipment_where=Inside"},
          {"key":"access_entry.where_inside_note","label":"If other, where inside?",             "type":"text",   "show_if":"access_entry.equipment_where=Inside"},
          {"key":"access_entry.where_outside",   "label":"Where is it outside?",                 "type":"choice", "options":["Front","Back","Other"], "show_if":"access_entry.equipment_where=Outside"},
          {"key":"access_entry.obstacles",       "label":"Any obstacles, tight spaces, or anything else to report?", "type":"text"}
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
          {"key":"grease_trap.cleanouts_count",  "label":"How many clean outs?",                 "type":"number"},
          {"key":"grease_trap.manhole_count",    "label":"How many manholes?",                   "type":"number"},
          {"key":"grease_trap.photos",           "label":"Photos, including the manual and the clean out", "type":"photos"},
          {"key":"grease_trap.capacity_gallons", "label":"Total capacity in gallons",            "type":"number"},
          {"key":"grease_trap.capacity_measure", "label":"Measurements, if the gallons are not written anywhere", "type":"text"},
          {"key":"grease_trap.capacity_photos",  "label":"Photos of the capacity plate or measurements", "type":"photos"},
          {"key":"grease_trap.sample_ports",     "label":"How many sample ports?",               "type":"number"}
        ]
      },
      {
        "id": "lift_station",
        "title": "Lift station",
        "questions": [
          {"key":"lift_station.count",               "label":"How many lift stations?",   "type":"number"},
          {"key":"lift_station.photos",              "label":"Photos of the lift station","type":"photos"},
          {"key":"lift_station.control_panel_photos","label":"Photo of the control panel","type":"photos"}
        ]
      },
      {
        "id": "water_tank",
        "title": "Water tank",
        "questions": [
          {"key":"water_tank.count",         "label":"How many water tanks?", "type":"number"},
          {"key":"water_tank.manhole_count", "label":"How many manholes?",    "type":"number"},
          {"key":"water_tank.capacity",      "label":"Total capacity",        "type":"text"},
          {"key":"water_tank.photos",        "label":"Photos of the water tank", "type":"photos"}
        ]
      }
    ]
  }'::jsonb;
$$;

comment on function public.fn_intake_form_current() is
  'The current intake question tree: L1 sections, each with ordered L2 questions. '
  'Yannick 2026-09-23: a water tank means the property has NO sewer connection, which is '
  'why there is no sewer question; and sample ports are collected on the visit as part of '
  'the grease trap system, which is why the key is grease_trap.sample_ports and it sits '
  'last in that section (Serena''s "sample port last"). Keys are APPEND-ONLY: a changed '
  'meaning gets a new key, never a rename, or older submissions stop being readable.';

-- --------------------------------------------- 2. THE ACCEPT MAP, ONE KEY CORRECTED
create or replace function public.fn_intake_accept_map()
returns jsonb language sql immutable set search_path to '' as $$
  select '{
    "grease_trap.manhole_count":    "grease_trap_manhole_count",
    "grease_trap.sample_ports":     "sample_port_count",
    "grease_trap.capacity_gallons": "grease_trap_size_gallons",
    "access_entry.lock_box_code":   "lock_box_key",
    "access_hours.schedule":        "access_schedule"
  }'::jsonb;
$$;

-- ------------------------- 3. SCHEDULE READS q->>'key' AND DEFAULTS TO THE CURRENT TREE
create or replace function client.schedule_property_intake(
  p_property_id bigint, p_requested text[], p_form_snapshot jsonb default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_id bigint;
  v_token text;
  v_bad text[];
  v_valid text[];
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

  insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
  values (p_property_id, v_snapshot, to_jsonb(p_requested), auth.jwt() ->> 'email')
  returning id, token into v_id, v_token;

  return jsonb_build_object('ok', true, 'intake_id', v_id, 'token', v_token,
                            'requested', to_jsonb(p_requested),
                            'form_version', v_snapshot -> 'version', 'note', p_note);
end $$;

revoke all on function public.fn_intake_form_current() from public, anon;
grant execute on function public.fn_intake_form_current() to authenticated;
revoke all on function client.schedule_property_intake(bigint, text[], jsonb, text) from public, anon;
grant execute on function client.schedule_property_intake(bigint, text[], jsonb, text) to authenticated;

-- ------------------------------------------------------------------- 4. VERIFY
do $verify$
declare
  v_prop bigint;
  v_keys text[];
  v_dupes text[];
  v_orphans text[];
  v_n int;
  v_res jsonb;
  v_raised boolean;
begin
  -- 4.0 the key correction is only safe because nothing has used the old key
  select count(*) into v_n from public.property_intakes;
  if v_n <> 0 then raise exception 'VERIFY 4.0a: % intake rows exist; renaming a question key is no longer safe', v_n; end if;
  select count(*) into v_n from public.property_intake_accepts;
  if v_n <> 0 then raise exception 'VERIFY 4.0b: % accept rows exist; renaming a question key is no longer safe', v_n; end if;

  -- 4.1 the tree parses and every key is unique across the whole form
  select array_agg(q ->> 'key') into v_keys
  from jsonb_array_elements(public.fn_intake_form_current() -> 'sections') s,
       jsonb_array_elements(s -> 'questions') q;
  if v_keys is null or array_length(v_keys,1) < 20 then
    raise exception 'VERIFY 4.1: expected at least 20 questions, got %', coalesce(array_length(v_keys,1),0);
  end if;
  select array_agg(k) into v_dupes from (
    select k, count(*) c from unnest(v_keys) k group by k having count(*) > 1) d;
  if v_dupes is not null then raise exception 'VERIFY 4.1b: duplicate question keys: %', v_dupes; end if;

  -- 4.2 every question carries a key, a label and a type
  select count(*) into v_n
  from jsonb_array_elements(public.fn_intake_form_current() -> 'sections') s,
       jsonb_array_elements(s -> 'questions') q
  where q ->> 'key' is null or q ->> 'label' is null or q ->> 'type' is null;
  if v_n <> 0 then raise exception 'VERIFY 4.2: % questions are missing key, label or type', v_n; end if;

  -- 4.3 THE INVARIANT THAT MATTERS: every key in the accept map must exist in the form,
  -- or an office Accept would point at a question the collector was never asked.
  select array_agg(k) into v_orphans
  from jsonb_object_keys(public.fn_intake_accept_map()) k
  where k <> all (v_keys);
  if v_orphans is not null then
    raise exception 'VERIFY 4.3: the accept map references question(s) that do not exist in the form: %', v_orphans;
  end if;

  -- 4.4 Yannick's two answers are actually encoded
  if 'grease_trap.sample_ports' <> all (v_keys) then raise exception 'VERIFY 4.4a: sample ports is not collected on the visit'; end if;
  if (select count(*) from unnest(v_keys) k where k like 'sample_port.%') <> 0 then raise exception 'VERIFY 4.4b: the old standalone sample_port section is still present'; end if;
  if (select count(*) from unnest(v_keys) k where k like '%sewer%') <> 0 then raise exception 'VERIFY 4.4c: a sewer question exists; the water tank section IS the sewer answer'; end if;
  if 'water_tank.count' <> all (v_keys) then raise exception 'VERIFY 4.4d: the water tank section is missing'; end if;
  -- sample ports must be LAST inside grease trap (Serena's "last on the list")
  if (select q ->> 'key'
        from jsonb_array_elements(public.fn_intake_form_current() -> 'sections') s,
             jsonb_array_elements(s -> 'questions') with ordinality z(q, ord)
       where s ->> 'id' = 'grease_trap'
       order by z.ord desc limit 1) <> 'grease_trap.sample_ports' then
    raise exception 'VERIFY 4.4e: sample ports is not last in the grease trap section';
  end if;

  -- 4.5 schedule works against the NEW question shape, and still refuses a typo
  select id into v_prop from public.properties p
   where p.client_id = (select id from public.clients where client_code = '112-YA')
     and p.deleted_at is null and coalesce(p.is_billing,false) = false
   order by p.id limit 1;
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","email":"fred@ayache.com"}', true);

  v_res := client.schedule_property_intake(v_prop, array['access_entry.gate','grease_trap.sample_ports']);
  if (v_res ->> 'ok') <> 'true' then raise exception 'VERIFY 4.5a: schedule failed against the new shape'; end if;
  if (v_res -> 'form_version')::text <> '1' then raise exception 'VERIFY 4.5b: form_version was not returned'; end if;

  v_raised := false;
  begin
    perform client.schedule_property_intake(v_prop, array['access_entry.typo']);
  exception when others then v_raised := true;
  end;
  if not v_raised then raise exception 'VERIFY 4.5c: an unknown question key was accepted'; end if;

  delete from public.property_intakes where property_id = v_prop;
  perform set_config('request.jwt.claims', '', true);

  raise notice 'VERIFY: form definition assertions passed (% questions)', array_length(v_keys,1);
end $verify$;

notify pgrst, 'reload schema';
