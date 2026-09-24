-- =============================================================================
-- 2026-09-24_0233_intake_tree_conditions_and_bounds.sql
-- Fix-forward from the THIRD adversarial review round (10 agents, 7 confirmed, 0 refuted),
-- plus Fred's two decisions of 2026-09-24.
--
-- 🛑 1. A CORRECTLY FILLED DEFAULT INTAKE COULD STILL NEVER BE COMPLETE. The 1949 fix only
--    helped a follow-up that CARRIES a show_if, and the live question tree left several
--    conditional questions unconditional. Probed with the live tree, all 35 keys requested and a
--    truthful survey of a sewer-connected site with no lift station and no water tank:
--    fn_intake_missing returned 8 keys, and even typing "N/A" into every text box left three
--    photo questions missing, because a photos answer can only be an uploaded file and nobody can
--    photograph a lift station that does not exist.
--    ⇒ The question tree (public.fn_intake_form_current) gains conditions, KEYS UNCHANGED
--      (keys stay append-only; a condition does not change a question's meaning):
--        access_entry.access_point_note   only if access_point = Other      ("If other, describe it")
--        access_entry.where_inside_note   only if where_inside = Other      (was gated on equipment_where)
--        grease_trap.capacity_measure     only if capacity_gallons is blank ("if the gallons are not written")
--        lift_station.photos, .control_panel_photos        only if lift_station.count > 0   (Fred)
--        water_tank.manhole_count, .capacity, .photos      only if water_tank.count > 0     (Fred)
--        access_entry.obstacles           OPTIONAL: kept and shown, never blocks Complete (Fred)
--    ⇒ Two grammar additions, made in THREE places together, in this order: the Client App's
--      Schedule dialog first (published 2026-09-24 02:35 ET, clients._id-B129zf9r.js, verified by
--      executing its helpers), then this migration, then the collector form:
--        "key>N"  shown only when the parent's answer is a number above N;
--        "key="   (empty value) shown only when the parent was left blank.
--      The operator is the FIRST '=' or '>', both sides trimmed, exactly as the dialog reads it.
--    ⇒ "optional" is a question attribute. public.fn_intake_required = shown AND not optional;
--      public.fn_intake_missing counts only required questions, and so do the list's
--      applicable_count / answered_count and get_intake's applicable_count.
--
-- 🛑 2. COMPARE AND ACCEPT IGNORED WHETHER A QUESTION WAS SHOWN. The collector form keeps what was
--    typed into a follow-up when its parent later changes, so a lock-box code typed and then
--    abandoned (how_access switched from Lock box to Key) reached the raw submission. The office
--    compare offered it and accept would have written it into properties.lock_box_key and pushed it
--    to Jobber. get_intake_compare now marks such a key 'not_shown'; accept_intake_answers refuses
--    it in plain words. The raw submission stays immutable: the filter is at the consumer.
--
-- 🛑 3. THE UPLOAD CAP COULD STILL BE BYPASSED. v8 counted objects already stored, so a burst of
--    upload calls made before any object landed minted unlimited signed URLs. Now a ledger,
--    public.property_intake_uploads, hands out at most 60 upload slots per intake EVER, through
--    public.fn_intake_claim_upload_slot under an advisory lock. 60, not 40: PHOTO_CAP (40 attached
--    photos, the product limit) stays in the edge function; the extra 20 are headroom for retries
--    on a bad signal, and the ceiling on storage is 60 objects per intake.
--    ponytail: a slot is never freed, so a collector who burns 60 uploads through retries is stuck;
--    reclaim slots whose URL expired unused (2 h) if that is ever seen.
--
-- 🛑 4. yannick_readonly COULD READ LIVE TOKENS. A LOGIN role with BYPASSRLS; the public-schema
--    default ACL gave it SELECT on property_intakes automatically. It keeps reading intakes, minus
--    the token column (a column-level grant). ⚠ Separately, that role's password is committed to the
--    public repo (docs/handoffs/yannick-*/YANNICK-CLAUDE-CODE-SETUP.md, since 2026-06-09). Fred
--    chose to have Yannick change it; this migration does not touch the login.
--
-- 5. BLANK NOW MEANS EXACTLY WHAT JavaScript's trim() REMOVES: TAB, LF, VT, FF, CR, SPACE, NBSP,
--    U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF. Before, seven Unicode
--    spaces counted as answered in SQL and blank in the form. Written with chr() codes so the set
--    does not depend on an escape sequence.
--
-- RULE 8, AUDIT: public.property_intake_uploads OPTS OUT. It is a machine-written capacity ledger
-- (service_role only, through one function), holds no human-editable field and no secret: its
-- paths are id-named and carry no token. Everything else is functions, views and grants.
-- ATOMIC: no COMMIT, so a failed assertion rolls the whole migration back.
-- =============================================================================


-- ============================================================ 1. blank = JS trim(), by code point
create or replace function public.fn_intake_answered(p_answers jsonb, p_key text)
 returns boolean
 language sql
 immutable
 set search_path to ''
as $function$
  select coalesce(
    p_answers is not null
    and p_answers -> p_key ? 'value'
    and jsonb_typeof(p_answers -> p_key -> 'value') <> 'null'
    and case jsonb_typeof(p_answers -> p_key -> 'value')
          when 'string' then btrim(p_answers -> p_key ->> 'value',
                                   chr(9) || chr(10) || chr(11) || chr(12) || chr(13) || chr(32) || chr(160)
                                   || chr(5760) || chr(8192) || chr(8193) || chr(8194) || chr(8195) || chr(8196)
                                   || chr(8197) || chr(8198) || chr(8199) || chr(8200) || chr(8201) || chr(8202)
                                   || chr(8232) || chr(8233) || chr(8239) || chr(8287) || chr(12288) || chr(65279)) <> ''
          when 'object' then (p_answers -> p_key -> 'value') <> '{}'::jsonb
          when 'array'  then (p_answers -> p_key -> 'value') <> '[]'::jsonb
          else true                       -- a number or a boolean is an answer, incl. 0 and false
        end,
  false);
$function$;


-- ============================================================ 2. the grammar: '=' and '>', first one wins
create or replace function public.fn_intake_applicable(p_snapshot jsonb, p_answers jsonb, p_key text)
returns boolean
language plpgsql
immutable
set search_path to ''
as $$
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
    v_parent := btrim(substr(v_show, 1, v_pos - 1));
    v_want   := btrim(substr(v_show, v_pos + 1));
    v_got    := coalesce(p_answers -> v_parent ->> 'value', '');
    if v_op = '=' then
      if btrim(v_got) is distinct from v_want then
        return false;                                -- the form hid it
      end if;
    else
      -- '>': a number above the threshold. CASE, not OR, so the cast never runs on text.
      if not (case when v_got ~ '^[[:space:]]*-?[0-9]+([.][0-9]+)?[[:space:]]*$'
                    and v_want ~ '^-?[0-9]+([.][0-9]+)?$'
                   then btrim(v_got)::numeric > v_want::numeric
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
end $$;

comment on function public.fn_intake_applicable(jsonb, jsonb, text) is
  'TRUE when intake question p_key was shown to the collector: every show_if in its chain holds for '
  'p_answers. Grammar: "key=value" (value may be empty: parent blank) or "key>N" (parent a number above '
  'N); the operator is the first "=" or ">", both sides trimmed. Mirrors the Client App dialog helpers '
  'and the collector form''s visible(); change all three together.';

create or replace function public.fn_intake_required(p_snapshot jsonb, p_answers jsonb, p_key text)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select public.fn_intake_applicable(p_snapshot, p_answers, p_key)
     and not coalesce((select (q -> 'optional') = 'true'::jsonb
                         from jsonb_array_elements(coalesce(p_snapshot -> 'sections', '[]'::jsonb)) s,
                              jsonb_array_elements(coalesce(s -> 'questions', '[]'::jsonb)) q
                        where jsonb_typeof(q) = 'object' and q ->> 'key' = p_key
                        limit 1), false);
$$;

comment on function public.fn_intake_required(jsonb, jsonb, text) is
  'TRUE when intake question p_key counts toward completeness: it was shown (fn_intake_applicable) '
  'and it is not marked "optional": true in the snapshot.';

create or replace function public.fn_intake_missing(p_snapshot jsonb, p_requested jsonb, p_answers jsonb)
returns text[]
language sql
immutable
set search_path to ''
as $$
  select coalesce(array_agg(r.k order by r.k), '{}'::text[])
    from (select distinct x as k
            from jsonb_array_elements_text(
                   case when jsonb_typeof(p_requested) = 'array' then p_requested else '[]'::jsonb end) x
           where x is not null and btrim(x) <> '') r
   where public.fn_intake_required(p_snapshot, p_answers, r.k)
     and not public.fn_intake_answered(p_answers, r.k);
$$;

comment on function public.fn_intake_missing(jsonb, jsonb, jsonb) is
  'THE completeness rule for an intake: the requested keys (NULL, blank and duplicates ignored) that '
  'count toward completeness (shown AND not optional) and are unanswered. Empty = Complete. Called by '
  'client.v_property_intake, client.v_intake_submissions, client.get_intake and intake-submit.';

revoke all on function public.fn_intake_required(jsonb, jsonb, text) from public, anon;
grant execute on function public.fn_intake_required(jsonb, jsonb, text) to authenticated, service_role, pg_read_all_data;


-- ============================================================ 3. the question tree gains its conditions
-- Copied from pg_get_functiondef and edited by exact, asserted string replacement: 9 lines change,
-- every key is unchanged.
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
          {"key":"grease_trap.photos",           "label":"Photos, including the manual and the clean out", "type":"photos"},
          {"key":"grease_trap.capacity_gallons", "label":"Total capacity in gallons",            "type":"number"},
          {"key":"grease_trap.capacity_measure", "label":"Measurements, if the gallons are not written anywhere", "type":"text", "show_if":"grease_trap.capacity_gallons="},
          {"key":"grease_trap.capacity_photos",  "label":"Photos of the capacity plate or measurements", "type":"photos"},
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


-- ============================================================ 4. the dialog's view exposes `optional`
-- Same nine columns, same order; `optional` is appended (a replace may only append).
create or replace view client.v_intake_questions as
 SELECT s.ord::integer AS section_order,
    s.section ->> 'id'::text AS section_id,
    s.section ->> 'title'::text AS section_title,
    q.ord::integer AS question_order,
    q.question ->> 'key'::text AS question_key,
    q.question ->> 'label'::text AS label,
    q.question ->> 'type'::text AS type,
    q.question -> 'options'::text AS options,
    q.question ->> 'show_if'::text AS show_if,
    coalesce((q.question -> 'optional') = 'true'::jsonb, false) AS optional
   FROM jsonb_array_elements(public.fn_intake_form_current() -> 'sections'::text) WITH ORDINALITY s(section, ord),
    LATERAL jsonb_array_elements(s.section -> 'questions'::text) WITH ORDINALITY q(question, ord);


-- ============================================================ 5. the list counts required questions
create or replace view client.v_intake_submissions as
select
  i.id                                                    as intake_id,
  case when i.submitted_at is not null then 'submitted' else 'awaiting' end as state,
  i.property_id,
  p.client_id,
  c.client_code,
  c.name                                                  as client_name,
  p.address,
  p.city,
  (p.deleted_at is not null)                              as property_deleted,
  i.requested_by,
  i.requested_at,
  i.expires_at,
  i.collector,
  i.submitted_at,
  pr.n_req                                                as requested_count,
  case when i.submitted_at is null then null
       else pr.n_app - cardinality(public.fn_intake_missing(i.form_snapshot, i.requested, i.answers)) end as answered_count,
  case when i.submitted_at is null then null
       when cardinality(public.fn_intake_missing(i.form_snapshot, i.requested, i.answers)) = 0 then 'Complete'
       else 'Incomplete' end                                                as status,
  case when i.submitted_at is null then null else
    (select count(*)::integer
       from public.photo_links pl
      where pl.entity_type = 'property_intake'
        and pl.entity_id = i.id
        and pl.deleted_at is null) end                                      as photo_count,
  case when i.submitted_at is null then null
       else public.fn_intake_answered(i.answers, 'site_map.gt_location') end   as has_gt_pin,
  case when i.submitted_at is null then null
       else public.fn_intake_answered(i.answers, 'site_map.truck_parking') end as has_truck_pin,
  (select count(*)::integer
     from public.property_intake_accepts a where a.intake_id = i.id)        as accepted_count,
  (select max(a.accepted_at)
     from public.property_intake_accepts a where a.intake_id = i.id)        as last_accepted_at,
  case when i.submitted_at is null then null else pr.n_app end              as applicable_count
from public.property_intakes i
join public.properties p on p.id = i.property_id
left join public.clients c on c.id = p.client_id
cross join lateral (
  select count(*)::integer as n_req,
         (count(*) filter (where public.fn_intake_required(i.form_snapshot, i.answers, r.k)))::integer as n_app
    from (select distinct x as k
            from jsonb_array_elements_text(i.requested) x
           where x is not null and btrim(x) <> '') r
) pr
where i.cancelled_at is null
  and (i.submitted_at is not null or i.expires_at > now());

comment on view client.v_intake_submissions is
  'One row per intake the Picture Planner /forms list shows: every submitted intake, and every awaiting '
  'one whose link is still live. Cancelled and expired-unused intakes are excluded. No answer VALUES here '
  '(client.get_intake has them, behind the staff check). requested_count = distinct requested keys; '
  'applicable_count = those that count toward completeness (shown to the collector, and not optional); '
  'answered_count = answered among those; status from public.fn_intake_missing. Collected-data columns '
  'are NULL for an awaiting intake.';

revoke all on client.v_intake_submissions from public, anon, authenticated;
grant select on client.v_intake_submissions to authenticated;


-- ============================================================ 6. the detail flags optional, counts required
create or replace function client.get_intake(p_intake_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_i            public.property_intakes;
  v_submitted    boolean;
  v_req          text[];
  v_known        text[];
  v_orphans      text[];
  v_photos       jsonb := '{}'::jsonb;
  v_sections     jsonb;
  v_other        jsonb;
  v_other_photos jsonb;
  v_accepted     jsonb;
  v_prop         jsonb;
  v_status       text;
  v_state        text;
  v_missing      text[];
  v_applicable   int;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_intake_id is null then
    raise exception 'p_intake_id is required' using errcode = '22023';
  end if;

  select * into v_i from public.property_intakes where id = p_intake_id;
  if not found then
    raise exception 'intake % does not exist', p_intake_id using errcode = 'P0002';
  end if;

  v_submitted := v_i.submitted_at is not null;
  v_state := case when v_i.cancelled_at is not null then 'cancelled'
                  when v_submitted                   then 'submitted'
                  when v_i.expires_at <= now()       then 'expired'
                  else 'awaiting' end;

  -- The same normalisation fn_intake_missing uses: distinct, no NULL, no blank. A NULL inside
  -- `x = ANY(arr)` would make every non-member test NULL and empty the unlisted lists.
  select coalesce(array_agg(distinct x) filter (where x is not null and btrim(x) <> ''), '{}') into v_req
    from jsonb_array_elements_text(v_i.requested) x;

  select coalesce(array_agg(k) filter (where k is not null and k <> ''), '{}') into v_known
    from jsonb_array_elements(coalesce(v_i.form_snapshot -> 'sections', '[]'::jsonb)) s,
         jsonb_array_elements(coalesce(s -> 'questions', '[]'::jsonb)) q,
         lateral (select case when jsonb_typeof(q) = 'string' then q #>> '{}' else q ->> 'key' end) kk(k);

  select coalesce(array_agg(r order by r), '{}') into v_orphans
    from unnest(v_req) r
   where not (r = any (v_known));

  -- Photos only for a submitted intake: the product rule. The folder is the intake id since
  -- intake-submit v7, never the token, so `path` carries no secret.
  if v_submitted then
    select coalesce(jsonb_object_agg(z.role, z.photos), '{}'::jsonb) into v_photos
      from (select pl.role,
                   jsonb_agg(jsonb_build_object(
                       'photo_id',     ph.id,
                       'bucket',       'intake-photos',
                       'path',         substr(ph.storage_path, length('intake-photos/') + 1),
                       'caption',      pl.caption,
                       'content_type', ph.content_type) order by pl.id) as photos
              from public.photo_links pl
              join public.photos ph on ph.id = pl.photo_id
             where pl.entity_type = 'property_intake'
               and pl.entity_id = v_i.id
               and pl.deleted_at is null
               and ph.storage_path like 'intake-photos/%'
               and pl.role is not null
             group by pl.role) z;
  end if;

  select coalesce(jsonb_agg(z.sec order by z.s_ord), '[]'::jsonb) into v_sections
    from (select s.ord as s_ord,
                 jsonb_build_object(
                   'id',    s.section ->> 'id',
                   'title', coalesce(s.section ->> 'title', s.section ->> 'id'),
                   'questions', jsonb_agg(jsonb_build_object(
                       'key',        q.k,
                       'label',      q.label,
                       'type',       q.typ,
                       'options',    q.opts,
                       'show_if',    q.show_if,
                       'applicable', case when v_submitted then public.fn_intake_applicable(v_i.form_snapshot, v_i.answers, q.k) end,
                       'optional',   q.opt,
                       'answered',   v_submitted and public.fn_intake_answered(v_i.answers, q.k),
                       'value',      case when v_submitted then v_i.answers -> q.k -> 'value' end,
                       'photos',     coalesce(v_photos -> q.k, '[]'::jsonb)) order by q.ord)) as sec
            from jsonb_array_elements(coalesce(v_i.form_snapshot -> 'sections', '[]'::jsonb))
                   with ordinality s(section, ord)
            cross join lateral (
              select qq.ord,
                     case when jsonb_typeof(qq.q) = 'string' then qq.q #>> '{}' else qq.q ->> 'key' end as k,
                     case when jsonb_typeof(qq.q) = 'string' then qq.q #>> '{}'
                          else coalesce(qq.q ->> 'label', qq.q ->> 'key') end                     as label,
                     case when jsonb_typeof(qq.q) = 'object' then qq.q ->> 'type' end              as typ,
                     case when jsonb_typeof(qq.q) = 'object' then qq.q -> 'options' end            as opts,
                     case when jsonb_typeof(qq.q) = 'object' then qq.q ->> 'show_if' end           as show_if,
                     case when jsonb_typeof(qq.q) = 'object' then coalesce((qq.q ->> 'optional')::boolean, false)
                          else false end                                                           as opt
                from jsonb_array_elements(coalesce(s.section -> 'questions', '[]'::jsonb))
                       with ordinality qq(q, ord)
            ) q
           where q.k = any (v_req)
           group by s.ord, s.section) z;

  if cardinality(v_orphans) > 0 then
    v_sections := v_sections || jsonb_build_array(jsonb_build_object(
      'id',    '_not_in_form_definition',
      'title', 'Asked, but not in this form''s definition',
      'questions', (select jsonb_agg(jsonb_build_object(
                        'key',        o,
                        'label',      o,
                        'type',       null,
                        'options',    null,
                        'show_if',    null,
                        'applicable', case when v_submitted then true end,
                        'optional',   false,
                        'answered',   v_submitted and public.fn_intake_answered(v_i.answers, o),
                        'value',      case when v_submitted then v_i.answers -> o -> 'value' end,
                        'photos',     coalesce(v_photos -> o, '[]'::jsonb)) order by o)
                      from unnest(v_orphans) o)));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('key', e.k, 'value', e.v -> 'value') order by e.k), '[]'::jsonb)
    into v_other
    from jsonb_each(coalesce(v_i.answers, '{}'::jsonb)) e(k, v)
   where v_submitted and not (e.k = any (v_req));

  select coalesce(jsonb_agg(jsonb_build_object('role', e.key, 'photos', e.value) order by e.key), '[]'::jsonb)
    into v_other_photos
    from jsonb_each(v_photos) e
   where not (e.key = any (v_req));

  select coalesce(jsonb_agg(jsonb_build_object(
             'question_key',  a.question_key,
             'target_column', a.target_column,
             'old_value',     a.old_value,
             'new_value',     a.new_value,
             'actor',         a.actor,
             'accepted_at',   a.accepted_at) order by a.accepted_at, a.id), '[]'::jsonb)
    into v_accepted
    from public.property_intake_accepts a
   where a.intake_id = v_i.id;

  select jsonb_build_object(
           'id',          p.id,
           'address',     p.address,
           'city',        p.city,
           'deleted',     p.deleted_at is not null,
           'client_id',   c.id,
           'client_code', c.client_code,
           'client_name', c.name)
    into v_prop
    from public.properties p
    left join public.clients c on c.id = p.client_id
   where p.id = v_i.property_id;

  -- THE rule, called, not copied.
  v_missing := public.fn_intake_missing(v_i.form_snapshot, v_i.requested, v_i.answers);
  select count(*) into v_applicable from unnest(v_req) k
   where public.fn_intake_required(v_i.form_snapshot, v_i.answers, k);
  v_status := case when not v_submitted then null
                   when cardinality(v_missing) = 0 then 'Complete'
                   else 'Incomplete' end;

  return jsonb_build_object(
    'intake_id',        v_i.id,
    'state',            v_state,
    'status',           v_status,
    'missing',          case when v_submitted then to_jsonb(v_missing) end,
    'property',         v_prop,
    'requested_by',     v_i.requested_by,
    'requested_at',     v_i.requested_at,
    'expires_at',       v_i.expires_at,
    'collector',        v_i.collector,
    'submitted_at',     v_i.submitted_at,
    'requested_count',  cardinality(v_req),
    'applicable_count', case when v_submitted then v_applicable end,
    'sections',         v_sections,
    'unlisted_answers', v_other,
    'unlisted_photos',  v_other_photos,
    'accepted',         v_accepted);
end $$;

revoke all on function client.get_intake(bigint) from public, anon;
grant execute on function client.get_intake(bigint) to authenticated;


-- ============================================================ 7. compare and accept respect "was it shown"
CREATE OR REPLACE FUNCTION client.get_intake_compare(p_intake_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_i public.property_intakes;
  v_p public.properties;
  v_map jsonb := public.fn_intake_accept_map();
  v_out jsonb := '[]'::jsonb;
  v_key text;
  v_col text;
  v_ours jsonb;
  v_theirs jsonb;
  v_state text;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;

  select * into v_i from public.property_intakes where id = p_intake_id;
  if not found then
    raise exception 'intake % not found', p_intake_id using errcode = 'P0002';
  end if;
  select * into v_p from public.properties where id = v_i.property_id;

  -- distinct, non-blank requested keys in their requested order (the same normalisation as
  -- public.fn_intake_missing), so a duplicated key is never compared twice
  for v_key in select e.k from jsonb_array_elements_text(v_i.requested) with ordinality e(k, ord)
                where e.k is not null and btrim(e.k) <> ''
                group by e.k order by min(e.ord) loop
    v_col := v_map ->> v_key;
    continue when v_col is null;                       -- intake-only answer, nothing to compare

    v_theirs := v_i.answers -> v_key -> 'value';
    v_ours := case v_col
      when 'grease_trap_manhole_count' then to_jsonb(nullif(v_p.grease_trap_manhole_count, 0))
      when 'sample_port_count'         then to_jsonb(v_p.sample_port_count)
      when 'grease_trap_size_gallons'  then to_jsonb(v_p.grease_trap_size_gallons)
      when 'lock_box_key'              then to_jsonb(nullif(btrim(coalesce(v_p.lock_box_key,'')), ''))
      when 'access_schedule'           then v_p.access_schedule
    end;

    -- A question the collector was NOT shown (its show_if chain did not match) may still
    -- carry a stale answer typed before the parent changed. It must never be offered for
    -- accept: it would write a lock-box code the collector abandoned into the property, and
    -- on to Jobber (third review round, 2026-09-24).
    v_state := case
      when not public.fn_intake_applicable(v_i.form_snapshot, v_i.answers, v_key) then 'not_shown'
      when not public.fn_intake_answered(v_i.answers, v_key) then 'unanswered'
      when v_ours is null or v_ours = 'null'::jsonb          then 'blank'
      when v_ours = v_theirs                                  then 'same'
      else 'differs'
    end;

    v_out := v_out || jsonb_build_object(
      'key', v_key, 'column', v_col, 'ours', v_ours, 'theirs', v_theirs, 'state', v_state);
  end loop;

  return jsonb_build_object('intake_id', v_i.id, 'property_id', v_i.property_id, 'fields', v_out);
end $function$;

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

revoke all on function client.get_intake_compare(bigint)             from public, anon;
revoke all on function client.accept_intake_answers(bigint, text[])  from public, anon;
grant execute on function client.get_intake_compare(bigint)            to authenticated;
grant execute on function client.accept_intake_answers(bigint, text[]) to authenticated;


-- ============================================================ 8. at most 60 upload slots per intake, ever
create table if not exists public.property_intake_uploads (
  intake_id bigint      not null references public.property_intakes(id) on delete cascade,
  slot      smallint    not null check (slot between 1 and 60),
  path      text        not null unique,
  issued_at timestamptz not null default now(),
  primary key (intake_id, slot)
);
comment on table public.property_intake_uploads is
  'Every signed upload URL intake-submit has issued, one row per slot, at most 60 per intake EVER. '
  'Bounds storage writes on a public, token-only endpoint (60 objects per intake). Written only by '
  'public.fn_intake_claim_upload_slot. Paths are id-named and carry no token. Audit: opted out '
  '(machine-written capacity ledger).';
alter table public.property_intake_uploads enable row level security;
revoke all on public.property_intake_uploads from public, anon, authenticated;

create or replace function public.fn_intake_claim_upload_slot(p_intake_id bigint, p_ext text)
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_slot int;
  v_path text;
begin
  if p_ext is null or p_ext not in ('jpg', 'png', 'webp', 'heic') then
    raise exception 'unsupported photo type %', p_ext using errcode = '22023';
  end if;
  -- One claimant at a time per intake, so two parallel calls can never take the same slot or
  -- both slip under the ceiling.
  perform pg_advisory_xact_lock(hashtext('property_intake_uploads'), p_intake_id::integer);
  select coalesce(max(slot), 0) + 1 into v_slot from public.property_intake_uploads where intake_id = p_intake_id;
  if v_slot > 60 then
    return null;                                     -- the caller answers 429
  end if;
  v_path := p_intake_id::text || '/' || gen_random_uuid()::text || '.' || p_ext;
  insert into public.property_intake_uploads (intake_id, slot, path) values (p_intake_id, v_slot, v_path);
  return v_path;
end $$;

comment on function public.fn_intake_claim_upload_slot(bigint, text) is
  'Claims the next of at most 60 upload slots for an intake and returns its storage path '
  '(<intake id>/<uuid>.<ext>), or NULL when all 60 are used. service_role only (intake-submit).';

revoke all on function public.fn_intake_claim_upload_slot(bigint, text) from public, anon, authenticated;
grant execute on function public.fn_intake_claim_upload_slot(bigint, text) to service_role;


-- ============================================================ 9. yannick_readonly: intakes yes, token no
revoke select on public.property_intakes from yannick_readonly;
grant select (id, property_id, form_snapshot, requested, expires_at, requested_by, requested_at,
              collector, answers, submitted_at, accepted, cancelled_at, created_at, updated_at)
   on public.property_intakes to yannick_readonly;


-- ============================================================ VERIFY
do $verify$
declare
  v_tree jsonb := public.fn_intake_form_current();
  v_all  jsonb;
  v_p1 bigint; v_p2 bigint;
  v_k bigint;  v_tok_k text;
  v_w bigint;  v_tok_w text;
  v_d bigint;
  v_ids bigint[];
  v_ph  bigint;
  v_n   int;
  v_s   text;
  v_j   jsonb;
  v_row record;
  v_raised boolean;
  v_lock_before text;
  v_paths text[];
  -- a truthful survey of a sewer-connected site with no lift station and no water tank
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
begin
  -- every key in the live tree
  select jsonb_agg(q ->> 'key') into v_all
    from jsonb_array_elements(v_tree -> 'sections') s, jsonb_array_elements(s -> 'questions') q;

  -- ============================================ V0 premises
  if (select count(*) from auth.users where lower(coalesce(email,'')) not like '%@ayache.com' and lower(coalesce(email,'')) not like '%@unclogme.com') <> 0 then
    raise exception 'VERIFY V0a: non-staff auth users exist'; end if;
  if jsonb_array_length(v_all) is distinct from 35 then raise exception 'VERIFY V0b: the tree must still hold 35 questions'; end if;

  -- ============================================ V1 privileges
  if not (has_function_privilege('authenticated','public.fn_intake_required(jsonb,jsonb,text)','EXECUTE')
      and has_function_privilege('pg_read_all_data','public.fn_intake_required(jsonb,jsonb,text)','EXECUTE')
      and has_function_privilege('service_role','public.fn_intake_required(jsonb,jsonb,text)','EXECUTE')
      and has_function_privilege('service_role','public.fn_intake_missing(jsonb,jsonb,jsonb)','EXECUTE')
      and has_function_privilege('service_role','public.fn_intake_applicable(jsonb,jsonb,text)','EXECUTE')) then
    raise exception 'VERIFY V1a: a reader of the views, or the edge function, cannot execute the rule'; end if;
  if has_function_privilege('anon','public.fn_intake_required(jsonb,jsonb,text)','EXECUTE') then raise exception 'VERIFY V1b'; end if;
  if not has_function_privilege('service_role','public.fn_intake_claim_upload_slot(bigint,text)','EXECUTE')
     or has_function_privilege('authenticated','public.fn_intake_claim_upload_slot(bigint,text)','EXECUTE')
     or has_function_privilege('anon','public.fn_intake_claim_upload_slot(bigint,text)','EXECUTE') then
    raise exception 'VERIFY V1c: the slot claim is not service_role-only'; end if;
  if has_table_privilege('authenticated','public.property_intake_uploads','SELECT,INSERT,UPDATE,DELETE')
     or has_table_privilege('anon','public.property_intake_uploads','SELECT,INSERT,UPDATE,DELETE') then
    raise exception 'VERIFY V1d: staff or anon can touch the upload ledger'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.property_intake_uploads'::regclass) then
    raise exception 'VERIFY V1e: the upload ledger has no RLS'; end if;
  if has_column_privilege('yannick_readonly','public.property_intakes','token','SELECT') then
    raise exception 'VERIFY V1f: yannick_readonly can still read the token'; end if;
  if not has_column_privilege('yannick_readonly','public.property_intakes','collector','SELECT') then
    raise exception 'VERIFY V1g: yannick_readonly lost the rest of the intake table'; end if;
  if has_table_privilege('anon','client.v_intake_questions','SELECT') or not has_table_privilege('authenticated','client.v_intake_questions','SELECT') then
    raise exception 'VERIFY V1h: v_intake_questions grants changed'; end if;
  if (select count(*) from client.v_intake_questions) is distinct from 35::bigint
     or (select count(*) from client.v_intake_questions where optional) is distinct from 1::bigint
     or (select question_key from client.v_intake_questions where optional) is distinct from 'access_entry.obstacles' then
    raise exception 'VERIFY V1i: v_intake_questions does not show 35 questions with obstacles the only optional one'; end if;

  -- ============================================ V2 blank = JS trim(), both directions
  foreach v_n in array array[9,10,11,12,13,32,160,5760,8192,8195,8202,8232,8233,8239,8287,12288,65279] loop
    if public.fn_intake_answered(jsonb_build_object('k', jsonb_build_object('value', chr(v_n) || chr(v_n))), 'k') is not false then
      raise exception 'VERIFY V2a: chr(%) alone counts as an answer, JS trim() removes it', v_n; end if;
  end loop;
  -- characters JS trim() does NOT remove stay answers (NEL, ZWSP, and plain letters incl. "v")
  foreach v_n in array array[133, 8203, 118] loop
    if public.fn_intake_answered(jsonb_build_object('k', jsonb_build_object('value', chr(v_n))), 'k') is not true then
      raise exception 'VERIFY V2b: chr(%) must count as an answer', v_n; end if;
  end loop;

  -- ============================================ V3 the grammar, pure
  if public.fn_intake_applicable(v_tree, '{"lift_station.count":{"value":2}}', 'lift_station.photos') is not true
     or public.fn_intake_applicable(v_tree, '{"lift_station.count":{"value":0}}', 'lift_station.photos') is not false
     or public.fn_intake_applicable(v_tree, '{}', 'lift_station.photos') is not false
     or public.fn_intake_applicable(v_tree, '{"lift_station.count":{"value":"abc"}}', 'lift_station.photos') is not false
     or public.fn_intake_applicable(v_tree, '{"water_tank.count":{"value":1}}', 'water_tank.capacity') is not true then
    raise exception 'VERIFY V3a: the ">" condition is wrong'; end if;
  if public.fn_intake_applicable(v_tree, '{}', 'grease_trap.capacity_measure') is not true
     or public.fn_intake_applicable(v_tree, '{"grease_trap.capacity_gallons":{"value":1000}}', 'grease_trap.capacity_measure') is not false then
    raise exception 'VERIFY V3b: the empty "=" condition is wrong'; end if;
  -- a two-deep chain: the stale child of a hidden parent is NOT shown
  if public.fn_intake_applicable(v_tree, '{"access_entry.equipment_where":{"value":"Inside"},"access_entry.where_inside":{"value":"Other"}}', 'access_entry.where_inside_note') is not true
     or public.fn_intake_applicable(v_tree, '{"access_entry.equipment_where":{"value":"Outside"},"access_entry.where_inside":{"value":"Other"}}', 'access_entry.where_inside_note') is not false then
    raise exception 'VERIFY V3c: the two-deep chain is not walked'; end if;
  -- spaces around the operator are tolerated, as the dialog tolerates them
  if public.fn_intake_applicable('{"sections":[{"questions":[{"key":"c","show_if":" p = yes "}]}]}', '{"p":{"value":"yes"}}', 'c') is not true then
    raise exception 'VERIFY V3d: a spaced condition is not read'; end if;
  -- a cycle and a self-loop terminate (visible), they do not hang
  if public.fn_intake_applicable('{"sections":[{"questions":[{"key":"a","show_if":"b=1"},{"key":"b","show_if":"a=1"}]}]}', '{"a":{"value":"1"},"b":{"value":"1"}}', 'a') is not true
     or public.fn_intake_applicable('{"sections":[{"questions":[{"key":"s","show_if":"s=1"}]}]}', '{"s":{"value":"1"}}', 's') is not true then
    raise exception 'VERIFY V3e: a cycle does not terminate as visible'; end if;
  -- optional is shown but not required
  if public.fn_intake_applicable(v_tree, '{}', 'access_entry.obstacles') is not true
     or public.fn_intake_required(v_tree, '{}', 'access_entry.obstacles') is not false then
    raise exception 'VERIFY V3f: obstacles must be shown and not required'; end if;

  -- ============================================ V4 the live tree is internally consistent
  -- every condition names a real key; an "=" on a choice names one of its options; a ">" is on a number
  select count(*) into v_n
    from jsonb_array_elements(v_tree -> 'sections') s
         cross join lateral jsonb_array_elements(s -> 'questions') q
         cross join lateral (select least(nullif(position('=' in (q->>'show_if')),0), nullif(position('>' in (q->>'show_if')),0)) as pos) p
         cross join lateral (select btrim(substr(q->>'show_if', 1, p.pos - 1)) as parent,
                                    substr(q->>'show_if', p.pos, 1) as op,
                                    btrim(substr(q->>'show_if', p.pos + 1)) as want) c
         -- LEFT, so a condition naming a MISSING parent keeps its row (par.pq NULL) and is counted
         left join lateral (select pq from jsonb_array_elements(v_tree -> 'sections') s2, jsonb_array_elements(s2 -> 'questions') pq
                             where pq ->> 'key' = c.parent limit 1) par on true
   where q ? 'show_if'
     and not (   (c.op = '>' and par.pq ->> 'type' = 'number' and c.want ~ '^-?[0-9]+$')
              or (c.op = '=' and c.want = '')
              or (c.op = '=' and par.pq ->> 'type' = 'yes_no' and c.want in ('yes','no'))
              or (c.op = '=' and par.pq ->> 'type' = 'choice' and (par.pq -> 'options') ? c.want));
  if v_n is distinct from 0 then raise exception 'VERIFY V4a: % conditions in the live tree name a missing key, a wrong option spelling, or ">" on a non-number', v_n; end if;
  select count(*) into v_n from jsonb_array_elements(v_tree -> 'sections') s, jsonb_array_elements(s -> 'questions') q where q ? 'show_if';
  if v_n is distinct from 16 then raise exception 'VERIFY V4b: expected 16 conditional questions in the live tree, found %', v_n; end if;

  -- ============================================ V5 THE regression: a truthful default intake is Complete
  if public.fn_intake_missing(v_tree, v_all, v_truthful) is distinct from '{}'::text[] then
    raise exception 'VERIFY V5a: a truthful survey of a site with no lift station and no water tank still misses %',
      public.fn_intake_missing(v_tree, v_all, v_truthful); end if;
  -- and the controls: a shown follow-up left blank IS missing, so the rule did not just go permissive
  if public.fn_intake_missing(v_tree, v_all, v_truthful || '{"lift_station.count":{"value":1}}'::jsonb)
     is distinct from array['lift_station.control_panel_photos','lift_station.photos'] then
    raise exception 'VERIFY V5b: one lift station must make its two photo questions required'; end if;
  if public.fn_intake_missing(v_tree, v_all, v_truthful - 'access_entry.key_instruction') is distinct from array['access_entry.key_instruction'] then
    raise exception 'VERIFY V5c: a blank shown follow-up must be missing'; end if;

  -- ============================================ fixtures, tagged [TEST]
  select min(p.id), max(p.id) into v_p1, v_p2 from public.properties p
   where p.client_id = (select id from public.clients where client_code = '112-YA')
     and p.deleted_at is null and coalesce(p.is_billing,false) = false;
  select lock_box_key into v_lock_before from public.properties where id = v_p2;

  -- K: submitted, how_access = Key, with a STALE lock-box code typed before the switch, and the
  -- optional obstacles left blank. Requested: how_access, key_instruction, lock_box_code, obstacles.
  insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
  values (v_p2, v_tree,
          '["access_entry.how_access","access_entry.key_instruction","access_entry.lock_box_code","access_entry.obstacles"]'::jsonb,
          '[TEST] tree verify',
          '{"access_entry.how_access":{"value":"Key"},"access_entry.key_instruction":{"value":"under the mat"},"access_entry.lock_box_code":{"value":"9999"}}'::jsonb,
          now())
  returning id, token into v_k, v_tok_k;
  -- W: awaiting, for the ledger and the audit UPDATE check
  insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
  values (v_p1, v_tree, '["access_entry.gate"]'::jsonb, '[TEST] tree verify') returning id, token into v_w, v_tok_w;
  v_ids := array[v_k, v_w];

  -- ============================================ V6 counts: required only, hidden leftovers do not count
  select * into v_row from client.v_intake_submissions where intake_id = v_k;
  if v_row.status is distinct from 'Complete' or v_row.requested_count is distinct from 4
     or v_row.applicable_count is distinct from 2 or v_row.answered_count is distinct from 2 then
    raise exception 'VERIFY V6a: K must be Complete, 2 required of 4 requested: % req % app % ans %',
      v_row.status, v_row.requested_count, v_row.applicable_count, v_row.answered_count; end if;
  if (select intake_status from client.v_property_intake where property_id = v_p2) is distinct from 'Complete' then
    raise exception 'VERIFY V6b: the Clients-list source does not agree K is Complete'; end if;

  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000003","email":"verify@ayache.com","role":"authenticated"}', true);
  v_j := client.get_intake(v_k);
  if v_j->>'status' is distinct from 'Complete' or (v_j->>'applicable_count')::int is distinct from 2 then
    raise exception 'VERIFY V6c: get_intake K wrong: % %', v_j->>'status', v_j->>'applicable_count'; end if;
  select count(*) into v_n from jsonb_array_elements(v_j#>'{sections,0,questions}') q
   where (q->>'key' = 'access_entry.lock_box_code' and q->>'applicable' = 'false' and q->>'answered' = 'true')
      or (q->>'key' = 'access_entry.obstacles'     and q->>'optional'   = 'true'  and q->>'answered' = 'false');
  if v_n is distinct from 2 then raise exception 'VERIFY V6d: the hidden leftover and the optional blank are not flagged'; end if;

  -- ============================================ V7 compare marks it not_shown, accept refuses it, nothing written
  v_j := client.get_intake_compare(v_k);
  if (select f->>'state' from jsonb_array_elements(v_j->'fields') f where f->>'key' = 'access_entry.lock_box_code') is distinct from 'not_shown' then
    raise exception 'VERIFY V7a: compare offers the stale lock-box code: %', v_j->'fields'; end if;
  v_raised := false;
  begin
    perform client.accept_intake_answers(v_k, array['access_entry.lock_box_code']);
  exception when sqlstate '22023' then
    v_raised := sqlerrm like '%was not shown%';
  end;
  if not v_raised then raise exception 'VERIFY V7b: accept did not refuse the stale lock-box code in plain words'; end if;
  if exists (select 1 from public.property_intake_accepts where intake_id = v_k) then
    raise exception 'VERIFY V7c: the refused accept wrote an accept row'; end if;
  if (select lock_box_key from public.properties where id = v_p2) is distinct from v_lock_before then
    raise exception 'VERIFY V7d: the refused accept changed the property'; end if;

  -- ============================================ V8 the ledger: 60 slots, then NULL, id-named paths
  for v_n in 1..60 loop
    v_s := public.fn_intake_claim_upload_slot(v_w, 'png');
    if v_s is null then raise exception 'VERIFY V8a: slot % was refused', v_n; end if;
    v_paths := v_paths || v_s;
  end loop;
  if public.fn_intake_claim_upload_slot(v_w, 'jpg') is not null then raise exception 'VERIFY V8b: a 61st slot was issued'; end if;
  if (select count(distinct p) from unnest(v_paths) p) is distinct from 60::bigint then raise exception 'VERIFY V8c: slot paths are not distinct'; end if;
  if exists (select 1 from unnest(v_paths) p
              where p !~ ('^' || v_w || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]png$')
                 or position(v_tok_w in p) > 0) then
    raise exception 'VERIFY V8d: a slot path is not <intake id>/<uuid>.png, or carries the token'; end if;
  v_raised := false;
  begin perform public.fn_intake_claim_upload_slot(v_w, 'exe'); exception when sqlstate '22023' then v_raised := true; end;
  if not v_raised then raise exception 'VERIFY V8e: an unsupported extension was accepted'; end if;

  -- ============================================ V9 audit redaction on UPDATE rows too
  update public.property_intakes set requested_by = '[TEST] tree verify, updated' where id = v_w;
  if exists (select 1 from audit.logs where table_name = 'property_intakes'
               and coalesce(new_row ->> 'id', old_row ->> 'id')::bigint = any (v_ids)
               and (coalesce(new_row,'{}') ? 'token' or coalesce(old_row,'{}') ? 'token')) then
    raise exception 'VERIFY V9a: an audit row (insert or update) carries the token'; end if;
  if (select count(*) from audit.logs where table_name = 'property_intakes' and operation = 'UPDATE'
        and coalesce(new_row ->> 'id', old_row ->> 'id')::bigint = v_w) < 1 then
    raise exception 'VERIFY V9b: the UPDATE left no audit row, so V9a proved nothing about updates'; end if;

  -- ============================================ V10 the standing token check has a positive control
  insert into public.photos (storage_path, source, content_type) values ('intake-photos/' || v_tok_k || '/control.jpg', 'intake_upload', 'image/jpeg') returning id into v_ph;
  select count(*) into v_n from public.photos ph join public.property_intakes t on position(t.token in ph.storage_path) > 0;
  if v_n is distinct from 1 then raise exception 'VERIFY V10a: the token check did not see a planted token path (saw %)', v_n; end if;
  delete from public.photos where id = v_ph;
  select count(*) into v_n from public.photos ph join public.property_intakes t on position(t.token in ph.storage_path) > 0;
  if v_n is distinct from 0 then raise exception 'VERIFY V10b: % photo paths contain a live token', v_n; end if;

  -- ============================================ V11 the same reads as authenticated
  execute 'set local role authenticated';
  if current_user is distinct from 'authenticated' then raise exception 'VERIFY V11a: the role did not switch'; end if;
  if (select status from client.v_intake_submissions where intake_id = v_k) is distinct from 'Complete'
     or (select count(*) from client.v_intake_questions) is distinct from 35::bigint
     or (client.get_intake(v_k))->>'status' is distinct from 'Complete' then
    raise exception 'VERIFY V11b: a staff session does not see what postgres sees'; end if;
  execute 'reset role';

  -- ============================================ V12 the raw record stays immutable
  v_raised := false;
  begin update public.property_intakes set answers = '{}'::jsonb where id = v_k;
  exception when sqlstate '22023' then v_raised := sqlerrm like '%raw intake submission is immutable%'; end;
  if not v_raised then raise exception 'VERIFY V12: the immutability trigger did not refuse'; end if;

  -- ============================================ cleanup (the ledger rows go with the intake), then prove it
  perform set_config('request.jwt.claims', '', true);
  delete from public.property_intakes where id = any (v_ids);
  if exists (select 1 from public.property_intakes where id = any (v_ids))
     or exists (select 1 from public.property_intake_uploads where intake_id = any (v_ids))
     or exists (select 1 from public.photos where id = v_ph) then
    raise exception 'VERIFY: fixtures left behind'; end if;
  if exists (select 1 from audit.logs where table_name = 'property_intakes' and operation = 'DELETE'
               and (old_row ->> 'id')::bigint = any (v_ids) and old_row ? 'token') then
    raise exception 'VERIFY V9c: a DELETE audit row carries the token'; end if;

  raise notice 'VERIFY: tree conditions, grammar, optional, compare/accept, upload ledger, all assertions passed';
end $verify$;

notify pgrst, 'reload schema';
