-- =============================================================================
-- 2026-09-24_0450_intake_round7_list_counts_orphan_reason.sql
-- Fix-forward from the SEVENTH adversarial review round (10 agents; 6 confirmed, all lowered to low but
-- one medium on verification, 0 refuted, 13 low returned unverified). The viewer and edge-function halves
-- ship separately (Picture Planner, intake-submit v13).
--
-- 1. THE LIST COUNTS WHAT THE DETAIL SHOWS. client.v_intake_submissions counted every live photo link and
--    badged any answered pin, including those of a question the collector was later not shown (photos
--    taken before a parent changed, a grease-trap pin at a site that turned out to have no trap). The card
--    then promised photos and pins the detail page, correctly, does not show. photo_count now counts links
--    whose question was shown or is not a requested question; has_gt_pin / has_truck_pin require the pin
--    question to have been shown. Same columns, same order, same grants.
-- 2. THE RIGHT REASON WHEN PRUNING EMPTIES A REQUEST. An optional question plus an orphan follow-up was
--    pruned to the optional question alone and refused as "optional only", hiding the real cause and the
--    dropped keys. It now says "Pick the question each follow-up depends on as well." and names them.
-- VERIFY keys every residue check on the fixture's own ids (the 0426 time-scoped arms compared a now()
-- default with a later clock_timestamp() and could never fire), and checks the writer constraints exist
-- with EXACT bounds (0426's substring test passed on a missing constraint and on a tenfold widening).
--
-- RULE 8, AUDIT: no new table. ATOMIC: no COMMIT.
-- =============================================================================

do $pre$
begin
  if md5(pg_get_functiondef('client.schedule_property_intake(bigint,text[],jsonb,text)'::regprocedure)) is distinct from '0818d7bf335746f533bd72aa6b18d9e6'
     or md5(pg_get_viewdef('client.v_intake_submissions'::regclass, true)) is distinct from '9d2bef53fbf6518dddb10f667b5996ff' then
    raise exception 'PRE-FLIGHT: an object this migration replaces changed since it was measured; re-read it';
  end if;
end $pre$;

-- ============================================================ 1. the list view
create or replace view client.v_intake_submissions as
SELECT i.id AS intake_id,
        CASE
            WHEN i.submitted_at IS NOT NULL THEN 'submitted'::text
            ELSE 'awaiting'::text
        END AS state,
    i.property_id,
    p.client_id,
    c.client_code,
    c.name AS client_name,
    p.address,
    p.city,
    p.deleted_at IS NOT NULL AS property_deleted,
    i.requested_by,
    i.requested_at,
    i.expires_at,
    i.collector,
    i.submitted_at,
    pr.n_req AS requested_count,
        CASE
            WHEN i.submitted_at IS NULL THEN NULL::integer
            ELSE pr.n_app - cardinality(fn_intake_missing(i.form_snapshot, i.requested, i.answers))
        END AS answered_count,
        CASE
            WHEN i.submitted_at IS NULL THEN NULL::text
            WHEN cardinality(fn_intake_missing(i.form_snapshot, i.requested, i.answers)) = 0 THEN 'Complete'::text
            ELSE 'Incomplete'::text
        END AS status,
        CASE
            WHEN i.submitted_at IS NULL THEN NULL::integer
            ELSE ( SELECT count(*)::integer AS count
               FROM photo_links pl
              WHERE pl.entity_type = 'property_intake'::text AND pl.entity_id = i.id AND pl.deleted_at IS NULL
                AND (NOT (i.requested ? pl.role) OR public.fn_intake_applicable(i.form_snapshot, i.answers, pl.role)))
        END AS photo_count,
        CASE
            WHEN i.submitted_at IS NULL THEN NULL::boolean
            ELSE public.fn_intake_answered(i.answers, 'site_map.gt_location'::text)
                 AND public.fn_intake_applicable(i.form_snapshot, i.answers, 'site_map.gt_location'::text)
        END AS has_gt_pin,
        CASE
            WHEN i.submitted_at IS NULL THEN NULL::boolean
            ELSE public.fn_intake_answered(i.answers, 'site_map.truck_parking'::text)
                 AND public.fn_intake_applicable(i.form_snapshot, i.answers, 'site_map.truck_parking'::text)
        END AS has_truck_pin,
    ( SELECT count(*)::integer AS count
           FROM property_intake_accepts a
          WHERE a.intake_id = i.id) AS accepted_count,
    ( SELECT max(a.accepted_at) AS max
           FROM property_intake_accepts a
          WHERE a.intake_id = i.id) AS last_accepted_at,
        CASE
            WHEN i.submitted_at IS NULL THEN NULL::integer
            ELSE pr.n_app
        END AS applicable_count
   FROM property_intakes i
     JOIN properties p ON p.id = i.property_id
     LEFT JOIN clients c ON c.id = p.client_id
     CROSS JOIN LATERAL ( SELECT count(*)::integer AS n_req,
            count(*) FILTER (WHERE fn_intake_required(i.form_snapshot, i.answers, r.k))::integer AS n_app
           FROM ( SELECT DISTINCT x.value AS k
                   FROM jsonb_array_elements_text(i.requested) x(value)
                  WHERE x.value IS NOT NULL AND btrim(x.value) <> ''::text) r) pr
  WHERE i.cancelled_at IS NULL AND (i.submitted_at IS NOT NULL OR i.expires_at > now());

-- ============================================================ 2. schedule
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
  v_added text[];
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
  -- ...and (fifth review) an optional question is asked together with its ALTERNATIVE, the question
  -- shown when it is left blank ("key="), or a blank gallons answer would read Complete with no capacity.
  v_req := public.fn_intake_normalise_requested(v_snapshot, p_requested);
  select array_agg(k) into v_added from unnest(v_req) k where not coalesce(k = any (p_requested), false);
  select array_agg(k) into v_dropped from unnest(p_requested) k where not coalesce(k = any (v_req), false);
  if array_length(v_req, 1) is null then
    raise exception 'Pick the question each follow-up depends on as well.'
      using errcode = '22023', detail = 'blocker=followups_only in client.schedule_property_intake';
  end if;
  -- A request of only optional questions reads Complete with nothing answered (sixth review).
  if not exists (select 1 from unnest(v_req) k
                  join lateral (select q from jsonb_array_elements(v_snapshot -> 'sections') s, jsonb_array_elements(s -> 'questions') q
                                 where q ->> 'key' = k limit 1) qq on true
                 where coalesce(qq.q -> 'optional', 'false'::jsonb) <> 'true'::jsonb) then
    -- If pruning is what left only optional questions, the real problem is the dropped follow-up.
    if v_dropped is not null then
      raise exception 'Pick the question each follow-up depends on as well.'
        using errcode = '22023', detail = 'blocker=followups_only in client.schedule_property_intake: ' || array_to_string(v_dropped, ', ');
    end if;
    raise exception 'Pick at least one question that is not optional.'
      using errcode = '22023', detail = 'blocker=optional_only in client.schedule_property_intake';
  end if;

  insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
  values (p_property_id, v_snapshot, to_jsonb(v_req), auth.jwt() ->> 'email')
  returning id, token into v_id, v_token;

  return jsonb_build_object('ok', true, 'intake_id', v_id, 'token', v_token,
                            'requested', to_jsonb(v_req), 'dropped', to_jsonb(coalesce(v_dropped, '{}'::text[])), 'added', to_jsonb(coalesce(v_added, '{}'::text[])),
                            'form_version', v_snapshot -> 'version', 'note', p_note);
end $function$;

-- ============================================================ VERIFY
do $verify$
declare
  v_tree jsonb := public.fn_intake_form_current();
  v_p1 bigint; v_i bigint; v_ph1 bigint; v_ph2 bigint; v_s text; v_raised boolean; v_row record;
  v_q_before bigint; v_u text; v_i2 bigint; v_ph3 bigint; v_ph4 bigint;
begin
  -- V0 the writer constraints exist, with EXACT bounds (a missing row or a widened bound must fail)
  if (select count(*) from pg_constraint where conname in ('chk_grease_trap_manhole_count_range','properties_grease_trap_size_chk','properties_lock_box_key_shape_chk')) is distinct from 3::bigint then
    raise exception 'VERIFY V0a: a writer constraint the tree mirrors is missing or renamed'; end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conname = 'chk_grease_trap_manhole_count_range') !~ '<= 50\)'
     or (select pg_get_constraintdef(oid) from pg_constraint where conname = 'properties_grease_trap_size_chk') !~ '<= 20000\)'
     or (select pg_get_constraintdef(oid) from pg_constraint where conname = 'properties_lock_box_key_shape_chk') !~ '<= 100\)' then
    raise exception 'VERIFY V0b: a writer bound moved; the tree ranges must follow it'; end if;
  -- and the check itself can see a widened bound (the 0426 substring test could not)
  if 'CHECK (x <= 500)' ~ '<= 50\)' or 'CHECK (x <= 1000)' ~ '<= 100\)' then
    raise exception 'VERIFY V0c: the exact-bound pattern matches a widened bound'; end if;

  -- V1 grants unchanged
  if (select relacl::text from pg_class where oid = 'client.v_intake_submissions'::regclass) is distinct from '{postgres=arwdDxtm/postgres,authenticated=r/postgres}' then
    raise exception 'VERIFY V1: the list view grants changed'; end if;

  select min(p.id) into v_p1 from public.properties p
   where p.client_id = (select id from public.clients where client_code = '112-YA') and p.deleted_at is null and coalesce(p.is_billing,false) = false;
  select count(*) into v_q_before from sync.outbound_queue;

  begin
    perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000003","email":"verify@ayache.com","role":"authenticated"}', true);

    -- V2 the orphan reason wins over "optional only", and names the dropped key
    v_raised := false;
    begin perform client.schedule_property_intake(v_p1, array['access_entry.obstacles','access_entry.gate_code']);
    exception when sqlstate '22023' then
      get stacked diagnostics v_s = pg_exception_detail;
      v_raised := sqlerrm = 'Pick the question each follow-up depends on as well.' and v_s like '%access_entry.gate_code%';
    end;
    if not v_raised then raise exception 'VERIFY V2a: an optional + orphan request did not get the follow-up reason naming the key'; end if;
    v_raised := false;
    begin perform client.schedule_property_intake(v_p1, array['access_entry.obstacles']);
    exception when sqlstate '22023' then v_raised := sqlerrm = 'Pick at least one question that is not optional.'; end;
    if not v_raised then raise exception 'VERIFY V2b: an optional-only request lost its own message'; end if;

    -- V3 a submitted intake with a grease-trap pin and photos, at a site that turned out to have NO trap:
    --    the pin and the grease-trap photos were not shown, so the card neither counts nor badges them
    insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
    values (v_p1, v_tree, '["grease_trap.systems_count","site_map.gt_location","grease_trap.photos","access_entry.access_photos"]', '[TEST] round 7',
            '{"grease_trap.systems_count":{"value":0},"site_map.gt_location":{"value":{"lat":25.79,"lng":-80.13}}}', now())
    returning id into v_i;
    v_u := public.fn_intake_claim_upload_slot(v_i, 'jpg');
    insert into public.photos (storage_path, source, content_type) values ('intake-photos/' || v_u, 'intake_upload', 'image/jpeg') returning id into v_ph1;
    insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_ph1, 'property_intake', v_i, 'grease_trap.photos');
    v_u := public.fn_intake_claim_upload_slot(v_i, 'jpg');
    insert into public.photos (storage_path, source, content_type) values ('intake-photos/' || v_u, 'intake_upload', 'image/jpeg') returning id into v_ph2;
    insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_ph2, 'property_intake', v_i, 'access_entry.access_photos');
    select * into v_row from client.v_intake_submissions where intake_id = v_i;
    if v_row.photo_count is distinct from 1 or v_row.has_gt_pin is distinct from false then
      raise exception 'VERIFY V3a: the card counts a hidden question''s photo or badges a hidden pin (photos %, gt pin %)', v_row.photo_count, v_row.has_gt_pin; end if;
    -- POSITIVE CONTROL in the same view: a site WITH a trap counts both photos and badges the pin
    insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
    values (v_p1, v_tree, '["grease_trap.systems_count","site_map.gt_location","grease_trap.photos","access_entry.access_photos"]', '[TEST] round 7',
            '{"grease_trap.systems_count":{"value":1},"site_map.gt_location":{"value":{"lat":25.79,"lng":-80.13}}}', now())
    returning id into v_i2;
    v_u := public.fn_intake_claim_upload_slot(v_i2, 'jpg');
    insert into public.photos (storage_path, source, content_type) values ('intake-photos/' || v_u, 'intake_upload', 'image/jpeg') returning id into v_ph3;
    insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_ph3, 'property_intake', v_i2, 'grease_trap.photos');
    v_u := public.fn_intake_claim_upload_slot(v_i2, 'jpg');
    insert into public.photos (storage_path, source, content_type) values ('intake-photos/' || v_u, 'intake_upload', 'image/jpeg') returning id into v_ph4;
    insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_ph4, 'property_intake', v_i2, 'access_entry.access_photos');
    select * into v_row from client.v_intake_submissions where intake_id = v_i2;
    if v_row.photo_count is distinct from 2 or v_row.has_gt_pin is distinct from true then
      raise exception 'VERIFY V3b: CONTROL, a site with a trap must count 2 photos and badge the pin (photos %, gt pin %)', v_row.photo_count, v_row.has_gt_pin; end if;
    raise exception 'round 7 fixtures done' using errcode = 'PPOK7';
  exception when sqlstate 'PPOK7' then
    null;
  end;

  -- V3c POSITIVE CONTROL for V3a, outside the immutability trigger: the same rule on answers with a trap
  if not (public.fn_intake_applicable(v_tree, '{"grease_trap.systems_count":{"value":1}}', 'site_map.gt_location')
          and public.fn_intake_applicable(v_tree, '{"grease_trap.systems_count":{"value":1}}', 'grease_trap.photos'))
     or public.fn_intake_applicable(v_tree, '{"grease_trap.systems_count":{"value":0}}', 'grease_trap.photos') then
    raise exception 'VERIFY V3c: the gate the list now uses does not separate a site with a trap from one without'; end if;

  -- V4 nothing left behind, keyed on the fixtures' own ids (the variables survive the rollback)
  if exists (select 1 from public.property_intakes where id in (v_i, v_i2) or collector like '[TEST] round 7%' or requested_by = 'verify@ayache.com')
     or exists (select 1 from public.photo_links where entity_type = 'property_intake' and entity_id in (v_i, v_i2))
     or exists (select 1 from public.photos where id in (v_ph1, v_ph2, v_ph3, v_ph4))
     or exists (select 1 from public.property_intake_uploads where intake_id in (v_i, v_i2))
     or (select count(*) from sync.outbound_queue) is distinct from v_q_before then
    raise exception 'VERIFY V4: a fixture survived the sentinel'; end if;

  raise notice 'VERIFY: round 7 (list counts what the detail shows, orphan reason, exact bounds) passed';
end $verify$;

notify pgrst, 'reload schema';
