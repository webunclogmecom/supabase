-- =============================================================================
-- 2026-09-24_0311_intake_round4_gallons_pruning_trim.sql
-- Fix-forward from the FOURTH adversarial review round (9 agents; 6 confirmed, 0 refuted, 6 low
-- returned unverified). Keys unchanged (append-only); a VERIFY asserts all 35 by name.
--
-- 🛑 1. A SITE WHOSE GALLONS ARE UNKNOWN COULD NEVER BE COMPLETE. "Measurements, if the gallons are not
--    written anywhere" is the alternative to the gallons, but the gallons question stayed required, so
--    a truthful survey (gallons blank, measurements typed) stayed Incomplete and only a false 0 finished
--    it. 372 of 506 live properties hold no gallons. ⇒ grease_trap.capacity_gallons is "optional": the
--    measurements question is required exactly when the gallons are blank.
--
-- 🛑 2. A FOLLOW-UP COULD BE ASKED WITHOUT ITS PARENT. The Schedule dialog unchecks a question whose value
--    we already hold (the gallons, for 134 properties) but leaves its follow-up checked, and an empty
--    "key=" reads a parent that was never asked as blank, so the collector was made to measure a trap
--    whose gallons the office already had. ⇒ client.schedule_property_intake drops every requested key
--    whose parent chain is not requested (public.fn_intake_prune_requested) and returns them as
--    "dropped". Refuses, in words, a set of nothing but orphans.
--
-- 3. GREASE-TRAP FOLLOW-UPS NEED A GREASE TRAP, as lift station and water tank already do (Fred's rule
--    of 2026-09-24, "only when the count is above 0", applied to the third equipment section):
--    grease_trap.photos, .capacity_gallons, .capacity_photos only if grease_trap.systems_count > 0
--    (capacity_measure follows through the gallons). site_map.gt_location is deliberately NOT gated:
--    it sits in an earlier section, so it would appear above the collector after they answer the
--    count further down. Left for Fred.
--
-- 🛑 4. THE STATUS RULE COULD RAISE. fn_intake_applicable trimmed answers with btrim (U+0020 only) and
--    tested ">" with [[:space:]], which accepts 19 more Unicode spaces, so a count of NBSP+"5" reached
--    ::numeric and raised 22P02 inside fn_intake_missing, which client.v_property_intake and
--    client.clients call. intake-submit computes status before writing, so no such answer can land
--    through it today; the rule must still never raise. ⇒ every trim is now public.fn_intake_trim (the
--    JS trim() set, which the form's visible() and Number() use), and ">" tests an ASCII number on the
--    trimmed value. fn_intake_answered calls the same helper, so the set is defined once.
--
-- 5. ONE LIVE LINK PER INTAKE PHOTO. attach checked, then inserted, with no lock, and the only unique
--    key on photo_links includes the caller's free-text role, so a parallel burst could link one photo
--    under many roles. ⇒ partial unique index photo_links (photo_id) for live property_intake links;
--    intake-submit v10 reads a collision as "already attached". Links <= photos <= 60 (the ledger).
--
-- 6. yannick_readonly COULD READ THE UPLOAD LEDGER (the public schema's default ACL again; 0233's header
--    said "service_role only" and V1d checked only authenticated and anon). Revoked; the ACL is now
--    asserted as a whole.
--
-- VERIFY also closes the round's test gaps: V4a was NULL-blind (a LEFT JOIN kept the row, then
-- NOT(NULL) dropped it) and now has a mutated-tree positive control; compare/accept get a positive
-- control (a shown lock-box code is offered and accepted); the ledger is checked per intake; the blank
-- set is looped over all 25 code points plus non-blank controls; "the first operator wins" is tested.
-- All fixture work runs in a sub-block rolled back by a sentinel, so it leaves no rows, no audit rows
-- and no outbound queue entries.
--
-- RULE 8, AUDIT: no new table. photo_links keeps its audit trigger; the index adds no column.
-- ATOMIC: no COMMIT, so a failed assertion rolls the whole migration back.
-- =============================================================================


-- ============================================================ 1. one trim, the JS trim() set
create or replace function public.fn_intake_trim(p text)
returns text
language sql
immutable
set search_path to ''
as $$
  select btrim(p, chr(9) || chr(10) || chr(11) || chr(12) || chr(13) || chr(32) || chr(160) || chr(5760) || chr(8192) || chr(8193) || chr(8194) || chr(8195) || chr(8196) || chr(8197) || chr(8198) || chr(8199) || chr(8200) || chr(8201) || chr(8202) || chr(8232) || chr(8233) || chr(8239) || chr(8287) || chr(12288) || chr(65279));
$$;

comment on function public.fn_intake_trim(text) is
  'Trims exactly what JavaScript''s String.prototype.trim() removes (TAB, LF, VT, FF, CR, SPACE, NBSP, '
  'U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF). The intake rule uses it '
  'wherever the collector form uses trim(), so the two cannot disagree on what is blank.';

revoke all on function public.fn_intake_trim(text) from public, anon;
grant execute on function public.fn_intake_trim(text) to authenticated, service_role, pg_read_all_data;


-- ============================================================ 2. answered: same predicate, the set moves
CREATE OR REPLACE FUNCTION public.fn_intake_answered(p_answers jsonb, p_key text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select coalesce(
    p_answers is not null
    and p_answers -> p_key ? 'value'
    and jsonb_typeof(p_answers -> p_key -> 'value') <> 'null'
    and case jsonb_typeof(p_answers -> p_key -> 'value')
          when 'string' then public.fn_intake_trim(p_answers -> p_key ->> 'value') <> ''
          when 'object' then (p_answers -> p_key -> 'value') <> '{}'::jsonb
          when 'array'  then (p_answers -> p_key -> 'value') <> '[]'::jsonb
          else true                       -- a number or a boolean is an answer, incl. 0 and false
        end,
  false);
$function$;


-- ============================================================ 3. applicable: trims like JS, ">" cannot raise
CREATE OR REPLACE FUNCTION public.fn_intake_applicable(p_snapshot jsonb, p_answers jsonb, p_key text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  v_key    text := p_key;
  v_show   text;
  v_pos    int;
  v_op     text;
  v_parent text;
  v_want   text;
  v_got    text;
  v_depth  int := 0;
begin
  loop
    v_show := null;
    select q ->> 'show_if' into v_show
      from jsonb_array_elements(coalesce(p_snapshot -> 'sections', '[]'::jsonb)) s,
           jsonb_array_elements(coalesce(s -> 'questions', '[]'::jsonb)) q
     where jsonb_typeof(q) = 'object' and q ->> 'key' = v_key
     limit 1;
    if v_show is null or btrim(v_show) = '' then
      return true;                                   -- no condition: always asked
    end if;
    -- The operator is the FIRST '=' or '>'. LEAST ignores NULL, so a missing one drops out.
    v_pos := least(nullif(position('=' in v_show), 0), nullif(position('>' in v_show), 0));
    if v_pos is null then
      return true;                                   -- no operator: not a condition
    end if;
    v_op     := substr(v_show, v_pos, 1);
    v_parent := public.fn_intake_trim(substr(v_show, 1, v_pos - 1));
    v_want   := public.fn_intake_trim(substr(v_show, v_pos + 1));
    v_got    := public.fn_intake_trim(coalesce(p_answers -> v_parent ->> 'value', ''));
    if v_op = '=' then
      if v_got is distinct from v_want then
        return false;                                -- the form hid it
      end if;
    else
      -- '>': a number above the threshold. CASE, not OR, so the cast never runs on text.
      -- v_got is already trimmed by the JS set; the pattern is ASCII only, so the cast cannot raise.
      if not (case when v_got ~ '^-?[0-9]+([.][0-9]+)?$'
                    and v_want ~ '^-?[0-9]+([.][0-9]+)?$'
                   then v_got::numeric > v_want::numeric
                   else false end) then
        return false;
      end if;
    end if;
    v_depth := v_depth + 1;
    if v_depth >= 10 then
      return true;                                   -- a cycle in an authored tree: stay visible
    end if;
    v_key := v_parent;                               -- the parent must itself have been shown
  end loop;
end $function$;


-- ============================================================ 4. a follow-up needs its parent requested
create or replace function public.fn_intake_parent_key(p_snapshot jsonb, p_key text)
returns text
language sql
immutable
set search_path to ''
as $$
  -- The parent a show_if names: everything before the FIRST '=' or '>', trimmed. NULL when the question
  -- has no condition or the condition has no operator (fn_intake_applicable then shows it always).
  select nullif(public.fn_intake_trim(substr(c.s, 1, c.pos - 1)), '')
    from (select q ->> 'show_if' as s,
                 least(nullif(position('=' in (q ->> 'show_if')), 0), nullif(position('>' in (q ->> 'show_if')), 0)) as pos
            from jsonb_array_elements(coalesce(p_snapshot -> 'sections', '[]'::jsonb)) sec,
                 jsonb_array_elements(coalesce(sec -> 'questions', '[]'::jsonb)) q
           where jsonb_typeof(q) = 'object' and q ->> 'key' = p_key
           limit 1) c
   where c.pos is not null;
$$;

create or replace function public.fn_intake_prune_requested(p_snapshot jsonb, p_requested text[])
returns text[]
language plpgsql
immutable
set search_path to ''
as $$
declare
  v_out    text[] := '{}';
  v_k      text;
  v_cur    text;
  v_parent text;
  v_depth  int;
  v_ok     boolean;
begin
  -- distinct, first occurrence order, NULL and blank ignored (as fn_intake_missing reads a set)
  for v_k in
    select u.k from unnest(p_requested) with ordinality u(k, n)
     where u.k is not null and btrim(u.k) <> ''
     group by u.k order by min(u.n)
  loop
    v_cur := v_k; v_depth := 0; v_ok := true;
    loop
      v_parent := public.fn_intake_parent_key(p_snapshot, v_cur);
      exit when v_parent is null;
      if not coalesce(v_parent = any (p_requested), false) then
        v_ok := false;
        exit;
      end if;
      v_depth := v_depth + 1;
      exit when v_depth >= 10;                      -- a cycle in an authored tree: keep it
      v_cur := v_parent;
    end loop;
    if v_ok then
      v_out := v_out || v_k;
    end if;
  end loop;
  return v_out;
end $$;

comment on function public.fn_intake_prune_requested(jsonb, text[]) is
  'The requested intake keys minus every key whose show_if parent chain is not itself requested '
  '(distinct, order kept). client.schedule_property_intake stores this, so a follow-up is never asked '
  'without the question it depends on.';

revoke all on function public.fn_intake_parent_key(jsonb, text) from public, anon;
revoke all on function public.fn_intake_prune_requested(jsonb, text[]) from public, anon;
grant execute on function public.fn_intake_parent_key(jsonb, text) to authenticated, service_role;
grant execute on function public.fn_intake_prune_requested(jsonb, text[]) to authenticated, service_role;


-- ============================================================ 5. the tree (three lines change, keys unchanged)
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
          {"key":"grease_trap.cleanouts_count",  "label":"How many clean outs?",                 "type":"number"},
          {"key":"grease_trap.manhole_count",    "label":"How many manholes?",                   "type":"number"},
          {"key":"grease_trap.photos",           "label":"Photos, including the manual and the clean out", "type":"photos", "show_if":"grease_trap.systems_count>0"},
          {"key":"grease_trap.capacity_gallons", "label":"Total capacity in gallons",            "type":"number", "show_if":"grease_trap.systems_count>0", "optional":true},
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


-- ============================================================ 6. schedule stores the pruned set
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
  v_req := public.fn_intake_prune_requested(v_snapshot, p_requested);
  select array_agg(k) into v_dropped from unnest(p_requested) k where not coalesce(k = any (v_req), false);
  if array_length(v_req, 1) is null then
    raise exception 'Pick the question each follow-up depends on as well.'
      using errcode = '22023', detail = 'blocker=followups_only in client.schedule_property_intake';
  end if;

  insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
  values (p_property_id, v_snapshot, to_jsonb(v_req), auth.jwt() ->> 'email')
  returning id, token into v_id, v_token;

  return jsonb_build_object('ok', true, 'intake_id', v_id, 'token', v_token,
                            'requested', to_jsonb(v_req), 'dropped', to_jsonb(coalesce(v_dropped, '{}'::text[])),
                            'form_version', v_snapshot -> 'version', 'note', p_note);
end $function$;


-- ============================================================ 7. one live link per intake photo
create unique index if not exists photo_links_intake_one_live_link_per_photo
  on public.photo_links (photo_id)
  where entity_type = 'property_intake' and deleted_at is null;


-- ============================================================ 8. the ledger is service_role only, really
revoke all on public.property_intake_uploads from yannick_readonly;


-- ============================================================ VERIFY
create function pg_temp.v4a_violations(p_tree jsonb) returns int language sql as $f$
  select count(*)::int
    from jsonb_array_elements(p_tree -> 'sections') s
         cross join lateral jsonb_array_elements(s -> 'questions') q
         cross join lateral (select least(nullif(position('=' in (q ->> 'show_if')), 0), nullif(position('>' in (q ->> 'show_if')), 0)) as pos) p
         cross join lateral (select public.fn_intake_trim(substr(q ->> 'show_if', 1, p.pos - 1)) as parent,
                                    substr(q ->> 'show_if', p.pos, 1) as op,
                                    public.fn_intake_trim(substr(q ->> 'show_if', p.pos + 1)) as want) c
         left join lateral (select pq from jsonb_array_elements(p_tree -> 'sections') s2, jsonb_array_elements(s2 -> 'questions') pq
                             where pq ->> 'key' = c.parent limit 1) par on true
   where q ? 'show_if'
     -- coalesce(..., false): a missing parent or operator makes the whole test NULL, and NOT(NULL) would
     -- drop the row. That is exactly how 0233's V4a could never report a missing parent.
     and not coalesce(p.pos is not null and par.pq is not null and (
               (c.op = '>' and par.pq ->> 'type' = 'number' and c.want ~ '^-?[0-9]+$')
            or (c.op = '=' and c.want = '')
            or (c.op = '=' and par.pq ->> 'type' = 'yes_no' and c.want in ('yes','no'))
            or (c.op = '=' and par.pq ->> 'type' = 'choice' and (par.pq -> 'options') ? c.want)), false);
$f$;

do $verify$
declare
  v_tree jsonb := public.fn_intake_form_current();
  v_keys text[];
  v_n    int;
  v_cp   int;
  v_j    jsonb;
  v_raised boolean;
  v_row  record;
  v_p1 bigint; v_p2 bigint;
  v_k bigint; v_l bigint; v_w bigint; v_ph bigint;
  v_lock_before text;
  v_s text;
  v_mini_eq text := '{"sections":[{"questions":[{"key":"p"},{"key":"c","show_if":"p="}]}]}';
  v_mini_gt text := '{"sections":[{"questions":[{"key":"p"},{"key":"c","show_if":"p>0"}]}]}';
  v_truthful jsonb := jsonb_build_object(
    'site_map.gt_location',        jsonb_build_object('value', jsonb_build_object('lat', 25.79, 'lng', -80.13)),
    'site_map.truck_parking',      jsonb_build_object('value', jsonb_build_object('lat', 25.791, 'lng', -80.131)),
    'access_entry.gate',           jsonb_build_object('value', 'no'),
    'access_entry.equipment_where',jsonb_build_object('value', 'Inside'),
    'access_entry.access_point',   jsonb_build_object('value', 'Front door'),
    'access_entry.access_photos',  jsonb_build_object('value', jsonb_build_array('p')),
    'access_entry.how_access',     jsonb_build_object('value', 'Key'),
    'access_entry.key_instruction',jsonb_build_object('value', 'under the mat'),
    'access_entry.alarm',          jsonb_build_object('value', 'no'),
    'access_entry.where_inside',   jsonb_build_object('value', 'Kitchen'),
    'access_hours.schedule',       jsonb_build_object('value', jsonb_build_object('mon', jsonb_build_object('open','22:00','close','06:00'))),
    'grease_trap.systems_count',   jsonb_build_object('value', 1),
    'grease_trap.cleanouts_count', jsonb_build_object('value', 1),
    'grease_trap.manhole_count',   jsonb_build_object('value', 2),
    'grease_trap.photos',          jsonb_build_object('value', jsonb_build_array('p')),
    'grease_trap.capacity_gallons',jsonb_build_object('value', 1000),
    'grease_trap.capacity_photos', jsonb_build_object('value', jsonb_build_array('p')),
    'grease_trap.sample_ports',    jsonb_build_object('value', 1),
    'lift_station.count',          jsonb_build_object('value', 0),
    'water_tank.count',            jsonb_build_object('value', 0));
  v_all  jsonb;
begin
  select array_agg(q ->> 'key' order by s.o, q.o) into v_keys
    from jsonb_array_elements(v_tree -> 'sections') with ordinality s(sec, o),
         lateral jsonb_array_elements(s.sec -> 'questions') with ordinality q(q, o);
  v_all := to_jsonb(v_keys);

  -- ============================================ V0 keys unchanged, by name and order
  if v_keys is distinct from array['site_map.gt_location', 'site_map.truck_parking', 'access_entry.gate', 'access_entry.gate_code', 'access_entry.gate_photos', 'access_entry.equipment_where', 'access_entry.access_point', 'access_entry.access_point_note', 'access_entry.access_photos', 'access_entry.how_access', 'access_entry.lock_box_code', 'access_entry.lock_box_photos', 'access_entry.key_instruction', 'access_entry.alarm', 'access_entry.alarm_instruction', 'access_entry.where_inside', 'access_entry.where_inside_note', 'access_entry.where_outside', 'access_entry.obstacles', 'access_hours.schedule', 'grease_trap.systems_count', 'grease_trap.cleanouts_count', 'grease_trap.manhole_count', 'grease_trap.photos', 'grease_trap.capacity_gallons', 'grease_trap.capacity_measure', 'grease_trap.capacity_photos', 'grease_trap.sample_ports', 'lift_station.count', 'lift_station.photos', 'lift_station.control_panel_photos', 'water_tank.count', 'water_tank.manhole_count', 'water_tank.capacity', 'water_tank.photos']::text[] then
    raise exception 'VERIFY V0: the question keys changed: %', v_keys; end if;

  -- ============================================ V1 privileges
  if not (has_function_privilege('authenticated','public.fn_intake_trim(text)','EXECUTE')
      and has_function_privilege('service_role','public.fn_intake_trim(text)','EXECUTE')
      and has_function_privilege('pg_read_all_data','public.fn_intake_trim(text)','EXECUTE')) then
    raise exception 'VERIFY V1a: a reader of the status views cannot execute fn_intake_trim'; end if;
  if has_function_privilege('anon','public.fn_intake_trim(text)','EXECUTE')
     or has_function_privilege('anon','public.fn_intake_parent_key(jsonb,text)','EXECUTE')
     or has_function_privilege('anon','public.fn_intake_prune_requested(jsonb,text[])','EXECUTE') then
    raise exception 'VERIFY V1b: anon can execute a new intake helper'; end if;
  if (select relacl::text from pg_class where oid = 'public.property_intake_uploads'::regclass)
     is distinct from '{postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}' then
    raise exception 'VERIFY V1c: the upload ledger ACL is not postgres + service_role: %',
      (select relacl::text from pg_class where oid = 'public.property_intake_uploads'::regclass); end if;
  if has_table_privilege('yannick_readonly','public.property_intake_uploads','SELECT') then
    raise exception 'VERIFY V1d: yannick_readonly can still read the ledger'; end if;
  if has_column_privilege('yannick_readonly','public.property_intakes','token','SELECT')
     or not has_column_privilege('yannick_readonly','public.property_intakes','collector','SELECT') then
    raise exception 'VERIFY V1e: the yannick_readonly column grant on property_intakes changed'; end if;
  if (select array_agg(question_key order by question_key) from client.v_intake_questions where optional)
     is distinct from array['access_entry.obstacles','grease_trap.capacity_gallons'] then
    raise exception 'VERIFY V1f: the optional questions are not obstacles and the gallons'; end if;

  -- ============================================ V2 blank = JS trim(), every code point, and it never raises
  foreach v_cp in array array[9,10,11,12,13,32,160,5760,8192,8193,8194,8195,8196,8197,8198,8199,8200,8201,8202,8232,8233,8239,8287,12288,65279] loop
    if public.fn_intake_answered(jsonb_build_object('k', jsonb_build_object('value', chr(v_cp))), 'k') is distinct from false then
      raise exception 'VERIFY V2a: code point % alone counts as an answer', v_cp; end if;
    if public.fn_intake_applicable(v_mini_eq::jsonb, jsonb_build_object('p', jsonb_build_object('value', chr(v_cp))), 'c') is distinct from true then
      raise exception 'VERIFY V2b: a parent of only code point % is not blank for "p="', v_cp; end if;
    if public.fn_intake_applicable(v_mini_gt::jsonb, jsonb_build_object('p', jsonb_build_object('value', chr(v_cp) || '5' || chr(v_cp))), 'c') is distinct from true then
      raise exception 'VERIFY V2c: 5 padded with code point % is not a number above 0', v_cp; end if;
  end loop;
  -- controls: characters trim() keeps are answers and are not numbers
  if public.fn_intake_answered('{"k":{"value":"​"}}'::jsonb, 'k') is distinct from true
     or public.fn_intake_answered(jsonb_build_object('k', jsonb_build_object('value', chr(8203))), 'k') is distinct from true
     or public.fn_intake_answered('{"k":{"value":"v"}}'::jsonb, 'k') is distinct from true then
    raise exception 'VERIFY V2d: a zero-width space or a letter is not an answer'; end if;
  if public.fn_intake_applicable(v_mini_gt::jsonb, jsonb_build_object('p', jsonb_build_object('value', chr(8203) || '5')), 'c') is distinct from false
     or public.fn_intake_applicable(v_mini_gt::jsonb, jsonb_build_object('p', jsonb_build_object('value', chr(65301))), 'c') is distinct from false
     or public.fn_intake_applicable(v_mini_gt::jsonb, jsonb_build_object('p', jsonb_build_object('value', chr(1637))), 'c') is distinct from false
     or public.fn_intake_applicable(v_mini_gt::jsonb, '{"p":{"value":"1e3"}}'::jsonb, 'c') is distinct from false
     or public.fn_intake_applicable(v_mini_gt::jsonb, '{"p":{"value":"-3"}}'::jsonb, 'c') is distinct from false
     or public.fn_intake_applicable(v_mini_gt::jsonb, '{"p":{"value":5.5}}'::jsonb, 'c') is distinct from true then
    raise exception 'VERIFY V2e: ">" accepts a non-ASCII or non-plain number, or refuses 5.5'; end if;
  -- the row that raised 22P02 before this migration
  if public.fn_intake_missing(v_tree, '["lift_station.count","lift_station.photos"]'::jsonb,
       jsonb_build_object('lift_station.count', jsonb_build_object('value', chr(160) || '5'))) is distinct from array['lift_station.photos'] then
    raise exception 'VERIFY V2f: NBSP+5 lift stations must require the photos, not raise'; end if;

  -- ============================================ V3 the first operator wins
  if public.fn_intake_applicable('{"sections":[{"questions":[{"key":"p"},{"key":"c","show_if":"p=a>b"}]}]}', '{"p":{"value":"a>b"}}', 'c') is distinct from true
     or public.fn_intake_applicable('{"sections":[{"questions":[{"key":"p"},{"key":"c","show_if":"p=a>b"}]}]}', '{"p":{"value":"a"}}', 'c') is distinct from false then
    raise exception 'VERIFY V3: "p=a>b" is not read as p equals "a>b"'; end if;

  -- ============================================ V4 the live tree is consistent, and the check can see a violation
  if pg_temp.v4a_violations(v_tree) is distinct from 0 then
    raise exception 'VERIFY V4a: % conditions in the live tree are malformed', pg_temp.v4a_violations(v_tree); end if;
  if pg_temp.v4a_violations(jsonb_set(v_tree, '{sections}', (v_tree -> 'sections') || '[{"id":"z","questions":[
        {"key":"z1","show_if":"nope.key=yes"}, {"key":"z2","show_if":"access_entry.gate"},
        {"key":"z3","show_if":""}, {"key":"z4","show_if":"nope.key="}]}]'::jsonb)) is distinct from 4 then
    raise exception 'VERIFY V4b: the consistency check cannot see a missing parent, a missing operator or an empty condition'; end if;
  select count(*) into v_n from jsonb_array_elements(v_tree -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ? 'show_if';
  if v_n is distinct from 19 then raise exception 'VERIFY V4c: expected 19 conditional questions, found %', v_n; end if;

  -- ============================================ V5 completeness
  if public.fn_intake_missing(v_tree, v_all, v_truthful) is distinct from '{}'::text[] then
    raise exception 'VERIFY V5a: the truthful survey with gallons misses %', public.fn_intake_missing(v_tree, v_all, v_truthful); end if;
  if public.fn_intake_missing(v_tree, v_all, (v_truthful - 'grease_trap.capacity_gallons')
       || '{"grease_trap.capacity_measure":{"value":"60in x 36in x 48in deep"}}') is distinct from '{}'::text[] then
    raise exception 'VERIFY V5b: unknown gallons plus measurements is not Complete'; end if;
  if public.fn_intake_missing(v_tree, v_all, v_truthful - 'grease_trap.capacity_gallons') is distinct from array['grease_trap.capacity_measure'] then
    raise exception 'VERIFY V5c: neither gallons nor measurements must miss the measurements'; end if;
  if public.fn_intake_missing(v_tree, v_all, (v_truthful - 'grease_trap.photos' - 'grease_trap.capacity_gallons' - 'grease_trap.capacity_photos')
       || '{"grease_trap.systems_count":{"value":0}}') is distinct from '{}'::text[] then
    raise exception 'VERIFY V5d: a site with no grease trap is not Complete'; end if;
  if public.fn_intake_missing(v_tree, v_all, v_truthful - 'grease_trap.photos') is distinct from array['grease_trap.photos'] then
    raise exception 'VERIFY V5e: one grease trap must still require its photos'; end if;
  if public.fn_intake_missing(v_tree, v_all, v_truthful || '{"lift_station.count":{"value":1}}')
     is distinct from array['lift_station.control_panel_photos','lift_station.photos'] then
    raise exception 'VERIFY V5f: one lift station must still require its photos'; end if;

  -- ============================================ V6 pruning
  if public.fn_intake_prune_requested(v_tree, v_keys) is distinct from v_keys then
    raise exception 'VERIFY V6a: pruning the full set changed it'; end if;
  if public.fn_intake_prune_requested(v_tree, array['site_map.gt_location', 'site_map.truck_parking', 'access_entry.gate', 'access_entry.gate_code', 'access_entry.gate_photos', 'access_entry.equipment_where', 'access_entry.access_point', 'access_entry.access_point_note', 'access_entry.access_photos', 'access_entry.how_access', 'access_entry.lock_box_code', 'access_entry.lock_box_photos', 'access_entry.key_instruction', 'access_entry.alarm', 'access_entry.alarm_instruction', 'access_entry.where_inside', 'access_entry.where_inside_note', 'access_entry.where_outside', 'access_entry.obstacles', 'access_hours.schedule', 'grease_trap.systems_count', 'grease_trap.cleanouts_count', 'grease_trap.manhole_count', 'grease_trap.photos', 'grease_trap.capacity_measure', 'grease_trap.capacity_photos', 'grease_trap.sample_ports', 'lift_station.count', 'lift_station.photos', 'lift_station.control_panel_photos', 'water_tank.count', 'water_tank.manhole_count', 'water_tank.capacity', 'water_tank.photos']::text[])
     is distinct from array['site_map.gt_location', 'site_map.truck_parking', 'access_entry.gate', 'access_entry.gate_code', 'access_entry.gate_photos', 'access_entry.equipment_where', 'access_entry.access_point', 'access_entry.access_point_note', 'access_entry.access_photos', 'access_entry.how_access', 'access_entry.lock_box_code', 'access_entry.lock_box_photos', 'access_entry.key_instruction', 'access_entry.alarm', 'access_entry.alarm_instruction', 'access_entry.where_inside', 'access_entry.where_inside_note', 'access_entry.where_outside', 'access_entry.obstacles', 'access_hours.schedule', 'grease_trap.systems_count', 'grease_trap.cleanouts_count', 'grease_trap.manhole_count', 'grease_trap.photos', 'grease_trap.capacity_photos', 'grease_trap.sample_ports', 'lift_station.count', 'lift_station.photos', 'lift_station.control_panel_photos', 'water_tank.count', 'water_tank.manhole_count', 'water_tank.capacity', 'water_tank.photos']::text[] then
    raise exception 'VERIFY V6b: the measurements survive without the gallons question'; end if;
  if public.fn_intake_prune_requested(v_tree, array['site_map.gt_location', 'site_map.truck_parking', 'access_entry.gate', 'access_entry.gate_code', 'access_entry.gate_photos', 'access_entry.equipment_where', 'access_entry.access_point', 'access_entry.access_point_note', 'access_entry.access_photos', 'access_entry.how_access', 'access_entry.lock_box_code', 'access_entry.lock_box_photos', 'access_entry.key_instruction', 'access_entry.alarm', 'access_entry.alarm_instruction', 'access_entry.where_inside', 'access_entry.where_inside_note', 'access_entry.where_outside', 'access_entry.obstacles', 'access_hours.schedule', 'grease_trap.cleanouts_count', 'grease_trap.manhole_count', 'grease_trap.photos', 'grease_trap.capacity_gallons', 'grease_trap.capacity_measure', 'grease_trap.capacity_photos', 'grease_trap.sample_ports', 'lift_station.count', 'lift_station.photos', 'lift_station.control_panel_photos', 'water_tank.count', 'water_tank.manhole_count', 'water_tank.capacity', 'water_tank.photos']::text[])
     is distinct from array['site_map.gt_location', 'site_map.truck_parking', 'access_entry.gate', 'access_entry.gate_code', 'access_entry.gate_photos', 'access_entry.equipment_where', 'access_entry.access_point', 'access_entry.access_point_note', 'access_entry.access_photos', 'access_entry.how_access', 'access_entry.lock_box_code', 'access_entry.lock_box_photos', 'access_entry.key_instruction', 'access_entry.alarm', 'access_entry.alarm_instruction', 'access_entry.where_inside', 'access_entry.where_inside_note', 'access_entry.where_outside', 'access_entry.obstacles', 'access_hours.schedule', 'grease_trap.cleanouts_count', 'grease_trap.manhole_count', 'grease_trap.sample_ports', 'lift_station.count', 'lift_station.photos', 'lift_station.control_panel_photos', 'water_tank.count', 'water_tank.manhole_count', 'water_tank.capacity', 'water_tank.photos']::text[] then
    raise exception 'VERIFY V6c: the grease-trap chain is not pruned with its count'; end if;
  if public.fn_intake_prune_requested(v_tree, array['access_entry.gate_code']) is distinct from '{}'::text[]
     or public.fn_intake_prune_requested(v_tree, array['access_entry.gate', 'access_entry.gate', null, '  ']) is distinct from array['access_entry.gate'] then
    raise exception 'VERIFY V6d: orphans, duplicates, NULL or blanks are not handled'; end if;
  if public.fn_intake_parent_key(v_tree, 'grease_trap.capacity_measure') is distinct from 'grease_trap.capacity_gallons'
     or public.fn_intake_parent_key(v_tree, 'access_entry.gate') is not null
     or public.fn_intake_parent_key(v_tree, 'nope') is not null then
    raise exception 'VERIFY V6e: fn_intake_parent_key reads the wrong parent'; end if;
  -- the regression: the dialog's default set for a property whose gallons we hold is completable
  if public.fn_intake_missing(v_tree, to_jsonb(public.fn_intake_prune_requested(v_tree, array['site_map.gt_location', 'site_map.truck_parking', 'access_entry.gate', 'access_entry.gate_code', 'access_entry.gate_photos', 'access_entry.equipment_where', 'access_entry.access_point', 'access_entry.access_point_note', 'access_entry.access_photos', 'access_entry.how_access', 'access_entry.lock_box_code', 'access_entry.lock_box_photos', 'access_entry.key_instruction', 'access_entry.alarm', 'access_entry.alarm_instruction', 'access_entry.where_inside', 'access_entry.where_inside_note', 'access_entry.where_outside', 'access_entry.obstacles', 'access_hours.schedule', 'grease_trap.systems_count', 'grease_trap.cleanouts_count', 'grease_trap.manhole_count', 'grease_trap.photos', 'grease_trap.capacity_measure', 'grease_trap.capacity_photos', 'grease_trap.sample_ports', 'lift_station.count', 'lift_station.photos', 'lift_station.control_panel_photos', 'water_tank.count', 'water_tank.manhole_count', 'water_tank.capacity', 'water_tank.photos']::text[])),
       v_truthful - 'grease_trap.capacity_gallons') is distinct from '{}'::text[] then
    raise exception 'VERIFY V6f: the pruned default set still misses something'; end if;

  -- ============================================ fixtures, all rolled back by the sentinel
  select min(p.id), max(p.id) into v_p1, v_p2 from public.properties p
   where p.client_id = (select id from public.clients where client_code = '112-YA')
     and p.deleted_at is null and coalesce(p.is_billing,false) = false;
  select lock_box_key into v_lock_before from public.properties where id = v_p2;

  begin
    perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000003","email":"verify@ayache.com","role":"authenticated"}', true);

    -- V7 schedule stores the pruned set and names what it dropped
    v_j := client.schedule_property_intake(v_p1, array['site_map.gt_location', 'site_map.truck_parking', 'access_entry.gate', 'access_entry.gate_code', 'access_entry.gate_photos', 'access_entry.equipment_where', 'access_entry.access_point', 'access_entry.access_point_note', 'access_entry.access_photos', 'access_entry.how_access', 'access_entry.lock_box_code', 'access_entry.lock_box_photos', 'access_entry.key_instruction', 'access_entry.alarm', 'access_entry.alarm_instruction', 'access_entry.where_inside', 'access_entry.where_inside_note', 'access_entry.where_outside', 'access_entry.obstacles', 'access_hours.schedule', 'grease_trap.systems_count', 'grease_trap.cleanouts_count', 'grease_trap.manhole_count', 'grease_trap.photos', 'grease_trap.capacity_measure', 'grease_trap.capacity_photos', 'grease_trap.sample_ports', 'lift_station.count', 'lift_station.photos', 'lift_station.control_panel_photos', 'water_tank.count', 'water_tank.manhole_count', 'water_tank.capacity', 'water_tank.photos']::text[]);
    if (select requested from public.property_intakes where id = (v_j ->> 'intake_id')::bigint)
       is distinct from to_jsonb(array['site_map.gt_location', 'site_map.truck_parking', 'access_entry.gate', 'access_entry.gate_code', 'access_entry.gate_photos', 'access_entry.equipment_where', 'access_entry.access_point', 'access_entry.access_point_note', 'access_entry.access_photos', 'access_entry.how_access', 'access_entry.lock_box_code', 'access_entry.lock_box_photos', 'access_entry.key_instruction', 'access_entry.alarm', 'access_entry.alarm_instruction', 'access_entry.where_inside', 'access_entry.where_inside_note', 'access_entry.where_outside', 'access_entry.obstacles', 'access_hours.schedule', 'grease_trap.systems_count', 'grease_trap.cleanouts_count', 'grease_trap.manhole_count', 'grease_trap.photos', 'grease_trap.capacity_photos', 'grease_trap.sample_ports', 'lift_station.count', 'lift_station.photos', 'lift_station.control_panel_photos', 'water_tank.count', 'water_tank.manhole_count', 'water_tank.capacity', 'water_tank.photos']::text[]) then
      raise exception 'VERIFY V7a: schedule stored an orphan follow-up'; end if;
    if v_j -> 'dropped' is distinct from '["grease_trap.capacity_measure"]'::jsonb then
      raise exception 'VERIFY V7b: schedule did not report the dropped follow-up: %', v_j -> 'dropped'; end if;
    v_raised := false;
    begin
      perform client.schedule_property_intake(v_p1, array['access_entry.gate_code']);
    exception when sqlstate '22023' then
      v_raised := sqlerrm = 'Pick the question each follow-up depends on as well.';
    end;
    if not v_raised then raise exception 'VERIFY V7c: an all-orphan set was not refused in words'; end if;

    -- V8 compare/accept: K hidden (refused), L shown (offered and accepted)
    insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
    values (v_p2, v_tree, '["access_entry.how_access","access_entry.key_instruction","access_entry.lock_box_code","access_entry.obstacles"]',
            '[TEST] round 4', '{"access_entry.how_access":{"value":"Key"},"access_entry.key_instruction":{"value":"under the mat"},"access_entry.lock_box_code":{"value":"9999"}}', now())
    returning id into v_k;
    insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
    values (v_p2, v_tree, '["access_entry.how_access","access_entry.lock_box_code"]',
            '[TEST] round 4', '{"access_entry.how_access":{"value":"Lock box"},"access_entry.lock_box_code":{"value":"[TEST] 4321"}}', now())
    returning id into v_l;
    if (select f ->> 'state' from jsonb_array_elements(client.get_intake_compare(v_k) -> 'fields') f where f ->> 'key' = 'access_entry.lock_box_code') is distinct from 'not_shown' then
      raise exception 'VERIFY V8a: compare offers a hidden lock-box code'; end if;
    v_raised := false;
    begin perform client.accept_intake_answers(v_k, array['access_entry.lock_box_code']);
    exception when sqlstate '22023' then v_raised := sqlerrm like '%was not shown%'; end;
    if not v_raised then raise exception 'VERIFY V8b: accept did not refuse a hidden answer'; end if;
    v_s := (select f ->> 'state' from jsonb_array_elements(client.get_intake_compare(v_l) -> 'fields') f where f ->> 'key' = 'access_entry.lock_box_code');
    if v_s is null or v_s not in ('blank', 'differs') then
      raise exception 'VERIFY V8c: POSITIVE CONTROL, a shown lock-box code is not offered (state %)', v_s; end if;
    perform client.accept_intake_answers(v_l, array['access_entry.lock_box_code']);
    if (select lock_box_key from public.properties where id = v_p2) is distinct from '[TEST] 4321' then
      raise exception 'VERIFY V8d: POSITIVE CONTROL, accepting a shown answer did not write it'; end if;

    -- V9 the ledger is per intake
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
    values (v_p1, v_tree, '["access_entry.gate"]', '[TEST] round 4') returning id into v_w;
    for v_n in 1..60 loop
      if public.fn_intake_claim_upload_slot(v_w, 'png') is null then raise exception 'VERIFY V9a: slot % refused', v_n; end if;
    end loop;
    if public.fn_intake_claim_upload_slot(v_w, 'png') is not null then raise exception 'VERIFY V9b: a 61st slot was issued'; end if;
    v_s := public.fn_intake_claim_upload_slot(v_k, 'jpg');
    if v_s is null or v_s not like v_k || '/%' then raise exception 'VERIFY V9c: another intake could not claim its first slot (%)', v_s; end if;
    if (select slot from public.property_intake_uploads where intake_id = v_k) is distinct from 1::smallint then
      raise exception 'VERIFY V9d: the other intake did not start at slot 1'; end if;
    if public.fn_intake_claim_upload_slot(v_w, 'png') is not null then raise exception 'VERIFY V9e: the full intake got a slot'; end if;

    -- V10 one live link per intake photo, whatever the role
    insert into public.photos (storage_path, source, content_type) values (v_s, 'intake_upload', 'image/jpeg') returning id into v_ph;
    insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_ph, 'property_intake', v_k, 'access_entry.access_photos');
    v_raised := false;
    begin insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_ph, 'property_intake', v_k, 'grease_trap.photos');
    exception when unique_violation then v_raised := true; end;
    if not v_raised then raise exception 'VERIFY V10: one photo got a second live intake link'; end if;

    -- V11 the list and a staff session agree
    select * into v_row from client.v_intake_submissions where intake_id = v_k;
    if v_row.status is distinct from 'Complete' or v_row.requested_count is distinct from 4
       or v_row.applicable_count is distinct from 2 or v_row.answered_count is distinct from 2 then
      raise exception 'VERIFY V11a: K must be Complete, 2 required of 4: % % % %', v_row.status, v_row.requested_count, v_row.applicable_count, v_row.answered_count; end if;
    execute 'set local role authenticated';
    if current_user is distinct from 'authenticated' then raise exception 'VERIFY V11b: the role did not switch'; end if;
    if (select status from client.v_intake_submissions where intake_id = v_l) is distinct from 'Complete'
       or (client.get_intake(v_k)) ->> 'status' is distinct from 'Complete'
       or (select count(*) from client.v_intake_questions) is distinct from 35::bigint then
      raise exception 'VERIFY V11c: a staff session does not see what postgres sees'; end if;
    execute 'reset role';

    raise exception 'round 4 fixtures done' using errcode = 'PPOK4';
  exception when sqlstate 'PPOK4' then
    null;   -- every fixture row, audit row and queue entry above is gone
  end;

  -- ============================================ V12 nothing left behind
  if exists (select 1 from public.property_intakes where collector = '[TEST] round 4' or requested_by in ('[TEST] round 4', 'verify@ayache.com'))
     or exists (select 1 from public.photo_links where entity_type = 'property_intake')
     or (select lock_box_key from public.properties where id = v_p2) is distinct from v_lock_before then
    raise exception 'VERIFY V12: a fixture survived the sentinel'; end if;

  raise notice 'VERIFY: round 4 (gallons either-or, pruning, grease-trap gating, trim, link bound, ledger ACL) passed';
end $verify$;

drop function pg_temp.v4a_violations(jsonb);

notify pgrst, 'reload schema';
