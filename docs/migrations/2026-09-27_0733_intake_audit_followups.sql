-- ============================================================================
-- 2026-09-27_0733_intake_audit_followups.sql (applied 2026-09-27_0733 ET)
-- 2026-09-27 · Intake audit follow-ups: the map save is retired; schedule_property_intake tidied
-- ============================================================================
-- Follows 2026-09-27_0652_page_map_in_draft_and_activity.sql, now that the Picture Planner's draft build is
-- live (chunk _staff.property._id-vemy_W-V.js, published about 07:24 ET).
--
-- 1. REVOKE EXECUTE ON client.update_property_site_map FROM authenticated. The map lives in the page draft
--    (Fred: "Make it draft-only"); the Planner no longer calls it (a crawl of all 21 live chunks from 5 routes
--    finds 0 references, with submit_property_page as the control), no other app, edge function or script
--    does (grep of both repos and the live Client App bundle), and pg_stat_statements shows no app call. So
--    properties.site_map is written only by approve_property_page from now on. The function is kept
--    (history, and a stale tab gets a plain permission error rather than a silent write).
--
-- 2. client.schedule_property_intake (audit findings D1-6, D1-7, D1-5 server half; body copied from the live
--    definition, md5 pinned):
--    - no longer returns the bare `token` (the Client App uses `url` only since CA1; the token lives in one
--      place); returns `expires_at` instead, so the office can be told when the link stops working;
--    - refuses a non-null p_form_snapshot (22023, blocker=custom_form): every intake uses the current form;
--      nothing passes one (the Client App never does; the [TEST] fixture inserts directly);
--    - a NULL or blank requested key is refused as unknown (it used to get the follow-up sentence);
--    - a removed or billing property gets a plain sentence (P0002, blocker=not_a_service_property).
--    Signature and grants unchanged.
--
-- Rule 8 (audit): no new table, no new write. Grants: update_property_site_map ends at {postgres=X/postgres};
-- schedule_property_intake keeps {postgres=X/postgres,authenticated=X/postgres} (asserted). ATOMIC: no
-- COMMIT; the VERIFY's test intake is created inside a sentinel sub-block and rolled back.
-- ============================================================================

do $pin$
begin
  if md5(pg_get_functiondef('client.schedule_property_intake(bigint,text[],jsonb,text)'::regprocedure)) <> 'e6506c576105d5d8057cc988b110f08e' then
    raise exception 'PIN: client.schedule_property_intake changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('client.update_property_site_map(bigint,jsonb,integer)'::regprocedure)) <> '49d321a16d09cf4a96f0e37efb38a428' then
    raise exception 'PIN: client.update_property_site_map changed since this migration was written';
  end if;
end $pin$;

-- ----------------------------------------------------------------- 1. the map save is retired
revoke execute on function client.update_property_site_map(bigint, jsonb, integer) from authenticated;

-- ----------------------------------------------------------------- 2. schedule_property_intake
CREATE OR REPLACE FUNCTION client.schedule_property_intake(p_property_id bigint, p_requested text[], p_form_snapshot jsonb DEFAULT NULL::jsonb, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id bigint;
  v_token text;
  v_exp   timestamptz;
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
  -- 2026-09-27: every intake uses the current form. A custom question list could pin any tree (a probe stored
  -- version 99 with an HTML label); no caller passes one (the Client App never does, the test fixture inserts).
  if p_form_snapshot is not null then
    raise exception 'A site survey form always uses the current questions.'
      using errcode = '22023', detail = 'blocker=custom_form in client.schedule_property_intake';
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
    raise exception 'This property was removed or is a billing address, so it cannot get a site survey form.'
      using errcode = 'P0002', detail = format('blocker=not_a_service_property in client.schedule_property_intake (property %s)', p_property_id);
  end if;

  -- Every requested key must exist as an L2 question in the pinned tree. A typo'd key
  -- can never be answered, so the intake would sit at Incomplete for ever with no way
  -- to tell a typo from a lazy collector.
  select array_agg(q ->> 'key') into v_valid
  from jsonb_array_elements(v_snapshot -> 'sections') s,
       jsonb_array_elements(s -> 'questions') q;

  select array_agg(k) into v_bad
  from unnest(p_requested) k
  where k is null or btrim(k) = '' or v_valid is null or k <> all (v_valid);   -- a NULL or blank key is unknown too
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
  returning id, token, expires_at into v_id, v_token, v_exp;

  -- The bare token is no longer returned (2026-09-27): the Client App uses url only since CA1, and the token
  -- belongs in one place. expires_at lets the office see when the link stops working.
  return jsonb_build_object('ok', true, 'intake_id', v_id, 'url', public.fn_intake_link_url(v_token), 'expires_at', v_exp,
                            'requested', to_jsonb(v_req), 'dropped', to_jsonb(coalesce(v_dropped, '{}'::text[])), 'added', to_jsonb(coalesce(v_added, '{}'::text[])),
                            'form_version', v_snapshot -> 'version', 'note', p_note);
end $function$;

-- ----------------------------------------------------------------- 3. VERIFY
do $verify$
declare
  v_fred  uuid;
  v_r     jsonb;
  v_state text; v_detail text;
  v_keys  text[] := (select array_agg(question_key order by question_key) from client.v_intake_questions
                      where show_if is null and coalesce(optional, false) = false);
  v_n0    int := (select count(*) from public.property_intakes);
begin
  select id into v_fred from auth.users where lower(email) = 'fred@ayache.com';
  if (select coalesce(proacl::text, 'NULL') from pg_proc where oid = 'client.update_property_site_map(bigint,jsonb,integer)'::regprocedure)
     <> '{postgres=X/postgres}' then
    raise exception 'VERIFY 1: update_property_site_map proacl is %',
      (select proacl::text from pg_proc where oid = 'client.update_property_site_map(bigint,jsonb,integer)'::regprocedure);
  end if;
  if (select coalesce(proacl::text, 'NULL') from pg_proc where oid = 'client.schedule_property_intake(bigint,text[],jsonb,text)'::regprocedure)
     <> '{postgres=X/postgres,authenticated=X/postgres}' then
    raise exception 'VERIFY 1: schedule_property_intake lost or gained a grant';
  end if;
  if v_keys is null then raise exception 'VERIFY 0: no required top-level question found'; end if;

  begin
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    begin
      perform client.update_property_site_map(1164, null, null);
      raise exception 'VERIFY 2a: a staff session could still save the map' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '42501' then raise exception 'VERIFY 2a: the map save gave %', v_state; end if;
    end;
    v_r := client.schedule_property_intake(1164, v_keys);
    if v_r ? 'token' or not (v_r ? 'expires_at') or (v_r ->> 'expires_at')::timestamptz < now() + interval '59 days'
       or v_r ->> 'url' !~ '^https://planner[.]unclogme[.]app/intake#code=' then
      raise exception 'VERIFY 2b: the reply is %', v_r - 'url';
    end if;
    begin
      perform client.schedule_property_intake(1164, v_keys, public.fn_intake_form_current());
      raise exception 'VERIFY 2c: a custom form went through' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '22023' or v_detail is distinct from 'blocker=custom_form in client.schedule_property_intake' then
        raise exception 'VERIFY 2c: a custom form gave % / %', v_state, v_detail;
      end if;
    end;
    begin
      perform client.schedule_property_intake(1164, v_keys || array[null::text]);
      raise exception 'VERIFY 2d: a NULL key went through' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '22023' or sqlerrm !~ '^unknown question key' then
        raise exception 'VERIFY 2d: a NULL key gave % / %', v_state, sqlerrm;
      end if;
    end;
    begin
      perform client.schedule_property_intake(1164, v_keys || array['  ']);
      raise exception 'VERIFY 2e: a blank key went through' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '22023' or sqlerrm !~ '^unknown question key' then
        raise exception 'VERIFY 2e: a blank key gave % / %', v_state, sqlerrm;
      end if;
    end;
    begin
      perform client.schedule_property_intake(-1, v_keys);
      raise exception 'VERIFY 2f: an unknown property went through' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> 'P0002' or v_detail !~ '^blocker=not_a_service_property' or sqlerrm ~ 'property -1' then
        raise exception 'VERIFY 2f: an unknown property gave % / % / %', v_state, v_detail, sqlerrm;
      end if;
    end;
    reset role;
    raise exception 'VERIFY_ROLLBACK_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_ROLLBACK_SENTINEL' then raise; end if;
  end;
  if (select count(*) from public.property_intakes) <> v_n0 then
    raise exception 'VERIFY 3: a test intake survived the rollback';
  end if;
  raise notice 'VERIFY: map save retired, schedule_property_intake tidied';
end $verify$;

notify pgrst, 'reload schema';
