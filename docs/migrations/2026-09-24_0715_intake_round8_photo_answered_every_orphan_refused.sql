-- =============================================================================
-- 2026-09-24_0715_intake_round8_photo_answered_every_orphan_refused.sql
-- Fix-forward from the EIGHTH adversarial review round (6 agents: 2 confirmed, 14 low). The edge half
-- shipped as intake-submit v14; the viewer half ships in Picture Planner.
--
-- 1. THE LIST COUNTS ONLY PHOTOS THE DETAIL SHOWS. The detail page shows a requested question's photos
--    only when that question was shown AND answered; client.v_intake_submissions.photo_count (0450)
--    required only "shown", so a shown-but-unanswered question's photo was promised on the card and
--    absent from the detail. It now requires both, exactly as the detail does. Unlisted photos (a role
--    not requested) still count: the detail lists them under "Also in the record".
-- 2. EVERY ORPHAN FOLLOW-UP IS REFUSED IN WORDS. 0450 refused an orphan only when pruning left nothing,
--    or only optional questions; a follow-up sent next to any required question was pruned silently and
--    reported only in the "dropped" return field, which no caller shows. client.schedule_property_intake
--    now refuses whenever a follow-up's parent was not ticked: "Pick the question each follow-up depends
--    on as well.", DETAIL naming the keys. The Client App dialog ticks a follow-up's parent itself, so it
--    never sends one; this closes the path for any other caller. "dropped" stays in the result (empty).
--
-- RULE 8, AUDIT: no new table. ATOMIC: no COMMIT. Both bodies spliced from the live definitions, md5-pinned.
-- =============================================================================

do $pre$
begin
  if md5(pg_get_functiondef('client.schedule_property_intake(bigint,text[],jsonb,text)'::regprocedure)) is distinct from '1efd459e6ada732317c5cac34bd129e5'
     or md5(pg_get_viewdef('client.v_intake_submissions'::regclass, true)) is distinct from 'eef2382a669cf452599a113c93cd2b51' then
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
              WHERE pl.entity_type = 'property_intake'::text AND pl.entity_id = i.id AND pl.deleted_at IS NULL AND (NOT i.requested ? pl.role OR fn_intake_applicable(i.form_snapshot, i.answers, pl.role) AND fn_intake_answered(i.answers, pl.role)))
        END AS photo_count,
        CASE
            WHEN i.submitted_at IS NULL THEN NULL::boolean
            ELSE fn_intake_answered(i.answers, 'site_map.gt_location'::text) AND fn_intake_applicable(i.form_snapshot, i.answers, 'site_map.gt_location'::text)
        END AS has_gt_pin,
        CASE
            WHEN i.submitted_at IS NULL THEN NULL::boolean
            ELSE fn_intake_answered(i.answers, 'site_map.truck_parking'::text) AND fn_intake_applicable(i.form_snapshot, i.answers, 'site_map.truck_parking'::text)
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
  -- Any follow-up whose parent was not ticked is refused in words, naming it (eighth review: a follow-up
  -- sent next to a required question used to be pruned silently and only reported in `dropped`).
  if v_dropped is not null then
    raise exception 'Pick the question each follow-up depends on as well.'
      using errcode = '22023', detail = 'blocker=followups_only in client.schedule_property_intake: ' || array_to_string(v_dropped, ', ');
  end if;
  -- A request of only optional questions reads Complete with nothing answered (sixth review).
  if not exists (select 1 from unnest(v_req) k
                  join lateral (select q from jsonb_array_elements(v_snapshot -> 'sections') s, jsonb_array_elements(s -> 'questions') q
                                 where q ->> 'key' = k limit 1) qq on true
                 where coalesce(qq.q -> 'optional', 'false'::jsonb) <> 'true'::jsonb) then
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
  v_p1 bigint; v_i bigint; v_i2 bigint; v_s text; v_raised boolean; v_row record; v_res jsonb;
  v_q_before bigint; v_u text; v_ph bigint[] := '{}'; v_x bigint; v_made bigint;
begin
  -- V1 grants unchanged
  if (select relacl::text from pg_class where oid = 'client.v_intake_submissions'::regclass) is distinct from '{postgres=arwdDxtm/postgres,authenticated=r/postgres}' then
    raise exception 'VERIFY V1: the list view grants changed'; end if;

  select min(p.id) into v_p1 from public.properties p
   where p.client_id = (select id from public.clients where client_code = '112-YA') and p.deleted_at is null and coalesce(p.is_billing,false) = false;
  select count(*) into v_q_before from sync.outbound_queue;

  begin
    perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000003","email":"verify@ayache.com","role":"authenticated"}', true);

    -- V2a a follow-up sent next to a REQUIRED question: refused, naming it (0450 pruned it silently)
    v_raised := false;
    begin perform client.schedule_property_intake(v_p1, array['access_entry.how_access','access_entry.gate_code']);
    exception when sqlstate '22023' then
      get stacked diagnostics v_s = pg_exception_detail;
      v_raised := sqlerrm = 'Pick the question each follow-up depends on as well.' and v_s like '%access_entry.gate_code%';
    end;
    if not v_raised then raise exception 'VERIFY V2a: a required question plus an orphan follow-up was not refused naming the follow-up'; end if;
    -- V2b the 0450 cases keep their messages
    v_raised := false;
    begin perform client.schedule_property_intake(v_p1, array['access_entry.obstacles','access_entry.gate_code']);
    exception when sqlstate '22023' then get stacked diagnostics v_s = pg_exception_detail;
      v_raised := sqlerrm = 'Pick the question each follow-up depends on as well.' and v_s like '%access_entry.gate_code%'; end;
    if not v_raised then raise exception 'VERIFY V2b: optional + orphan lost the follow-up reason'; end if;
    v_raised := false;
    begin perform client.schedule_property_intake(v_p1, array['access_entry.obstacles']);
    exception when sqlstate '22023' then v_raised := sqlerrm = 'Pick at least one question that is not optional.'; end;
    if not v_raised then raise exception 'VERIFY V2c: an optional-only request lost its own message'; end if;
    -- V2d POSITIVE CONTROL: the parent ticked with its follow-up schedules, with nothing dropped
    v_res := client.schedule_property_intake(v_p1, array['access_entry.gate','access_entry.gate_code']);
    v_made := (v_res ->> 'intake_id')::bigint;
    if v_made is null or jsonb_array_length(v_res -> 'dropped') <> 0 then
      raise exception 'VERIFY V2d: CONTROL, a parent with its follow-up must schedule with nothing dropped (%)', v_res; end if;

    -- V3 the card counts a requested question's photo only when that question was shown AND answered
    insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
    values (v_p1, v_tree, '["grease_trap.systems_count","grease_trap.photos","access_entry.access_photos"]', '[TEST] round 8',
            '{"grease_trap.systems_count":{"value":1},"access_entry.access_photos":{"value":["x.jpg"]}}', now())
    returning id into v_i;   -- grease_trap.photos is SHOWN (a trap) but NOT answered
    foreach v_s in array array['grease_trap.photos','access_entry.access_photos'] loop
      v_u := public.fn_intake_claim_upload_slot(v_i, 'jpg');
      insert into public.photos (storage_path, source, content_type) values ('intake-photos/' || v_u, 'intake_upload', 'image/jpeg') returning id into v_x;
      v_ph := v_ph || v_x;
      insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_x, 'property_intake', v_i, v_s);
    end loop;
    select * into v_row from client.v_intake_submissions where intake_id = v_i;
    if v_row.photo_count is distinct from 1 then
      raise exception 'VERIFY V3a: a shown but unanswered question''s photo is counted (photos %)', v_row.photo_count; end if;
    -- POSITIVE CONTROL: the same site with the grease-trap photos question answered counts both
    insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
    values (v_p1, v_tree, '["grease_trap.systems_count","grease_trap.photos","access_entry.access_photos"]', '[TEST] round 8',
            '{"grease_trap.systems_count":{"value":1},"grease_trap.photos":{"value":["g.jpg"]},"access_entry.access_photos":{"value":["x.jpg"]}}', now())
    returning id into v_i2;
    foreach v_s in array array['grease_trap.photos','access_entry.access_photos'] loop
      v_u := public.fn_intake_claim_upload_slot(v_i2, 'jpg');
      insert into public.photos (storage_path, source, content_type) values ('intake-photos/' || v_u, 'intake_upload', 'image/jpeg') returning id into v_x;
      v_ph := v_ph || v_x;
      insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_x, 'property_intake', v_i2, v_s);
    end loop;
    select * into v_row from client.v_intake_submissions where intake_id = v_i2;
    if v_row.photo_count is distinct from 2 then
      raise exception 'VERIFY V3b: CONTROL, both answered questions must count (photos %)', v_row.photo_count; end if;
    raise exception 'round 8 fixtures done' using errcode = 'PPOK8';
  exception when sqlstate 'PPOK8' then
    null;
  end;

  -- V4 nothing left behind, keyed on the fixtures' own ids (the variables survive the rollback)
  if v_made is null or v_i is null or v_i2 is null then raise exception 'VERIFY V4a: a fixture id was never captured, so the residue check would check nothing'; end if;
  if exists (select 1 from public.property_intakes where id in (v_i, v_i2, v_made) or collector like '[TEST] round 8%' or requested_by = 'verify@ayache.com')
     or exists (select 1 from public.photo_links where entity_type = 'property_intake' and entity_id in (v_i, v_i2))
     or exists (select 1 from public.photos where id = any (v_ph))
     or exists (select 1 from public.property_intake_uploads where intake_id in (v_i, v_i2))
     or (select count(*) from sync.outbound_queue) is distinct from v_q_before then
    raise exception 'VERIFY V4b: a fixture survived the sentinel'; end if;

  raise notice 'VERIFY: round 8 (photos shown AND answered, every orphan follow-up refused) passed';
end $verify$;

notify pgrst, 'reload schema';
