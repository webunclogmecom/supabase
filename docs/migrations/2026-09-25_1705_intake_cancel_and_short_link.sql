-- ============================================================================
-- 2026-09-25_1705 · Cancel an intake form (staff, in the Planner) + the short link from schedule
-- ============================================================================
-- Fred, 2026-09-25:
--   "Cancelling an intake form should only be possible at the Planner App, meaning a logged in
--    staff can do it. Not by a driver."
--   "Go ahead with the 'Link ready' short link follow-up"
--
-- 1. client.cancel_intake(p_intake_id bigint) -> {ok, intake_id, cancelled_at}
--    The ONE writer of property_intakes.cancelled_at for people. A signed-in staff JWT only: the
--    same gate as client.get_intake_link (plain sentence in MESSAGE, blocker=<code> in DETAIL),
--    EXECUTE revoked from public and anon and granted to authenticated only. Nobody holding a link
--    can cancel: the collector endpoint (intake-submit) has no cancel operation and anon holds
--    nothing on any intake object. It answers the cancel half of open decision 13.2 item 7 in
--    Building Apps/docs/client-intake-flow.md (the re-show half was 2026-09-25_1600).
--    - Refuses: not signed in (28000), not staff (42501), no id, not found (P0002), already
--      cancelled, submitted (a submitted form is a record; it stays). All 22023 unless noted.
--    - Allows an expired link and a removed property: stopping a dead or orphaned link is harmless.
--    - Locks the row (FOR UPDATE) and writes only while submitted_at and cancelled_at are still NULL, so a
--      cancel and a collector's submit cannot both win even if a later retype drops the lock (READ COMMITTED
--      re-checks the WHERE on the newest row). VERIFY 1e asserts both are still in the body.
--    - Who cancelled is recorded by the existing audit_property_intakes trigger (jwt email, and
--      app_source picture-planner from the Planner). No new column, no new table.
--    - After a cancel: every intake-submit request that STARTS after it commits answers 404 "This link is
--      no longer active." (resolveToken). An upload or attach already past its token check can still store a
--      file or photo link on the cancelled intake (nothing reads a cancelled intake's photos); only the submit
--      is refused in the database (section 2). get_intake_link refuses 'cancelled', and
--      client.v_intake_submissions stops listing it (it already filters cancelled rounds).
--
-- 2. Submit after cancel is refused IN THE DATABASE. intake-submit's compare-and-set is
--    `.is('submitted_at', null)` only, so a submit already in flight when the office cancels would
--    otherwise land on the cancelled row. New BEFORE UPDATE trigger
--    property_intakes_no_submit_after_cancel refuses the TRANSITION (old.cancelled_at set, old
--    submitted_at null, new submitted_at set). It keys on the transition, never on comparing the two
--    timestamps: submitted_at is stamped by the edge function's clock, cancelled_at by the
--    database's. The collector sees intake-submit's "Could not save the form, please try again.",
--    and a retry gets the 404. 0 of 4 intakes were cancelled when this shipped, so nothing existing
--    is in the refused shape.
--
-- 3. The short collector link is built in ONE place in SQL: public.fn_intake_link_url(token)
--    -> 'https://planner.unclogme.app/intake#code=' || token, or NULL when the token does not look
--    like one (^[A-Za-z0-9_-]{8,64}$, what the collector endpoint accepts). get_intake_link now calls
--    it (same output; the VERIFY compares against an independently built string) and
--    schedule_property_intake returns it as `url` NEXT TO `token` (additive: the live Client App
--    still builds intake-submit?t=<token> from `token` until its next publish reads `url`).
--    /intake is a Picture Planner route that 308s to /intake.html; the fragment never reaches a server
--    log, where the office link's ?t= does. The collector host still also lives in intake-submit's
--    GET redirect (FORM_URL): move the collector and both change together.
--    Both replaced bodies are SPLICED from the live definitions, md5-pinned below; one anchored
--    change each, every other byte identical.
--
-- Rule 8 (audit): no new table. property_intakes stays audited; the new functions write nothing
-- else. Grants: every new function is revoked by name and its whole proacl asserted.
-- ATOMIC: no COMMIT. The VERIFY's writes run inside a sentinel sub-block and are rolled back.
-- ============================================================================

-- ----------------------------------------------------------------- 0. the bodies we splice are the ones we read
do $pin$
begin
  if md5(pg_get_functiondef('client.get_intake_link(bigint)'::regprocedure)) <> '10d1c64491ddda7eb2de936c17f9c9af' then
    raise exception 'PIN: client.get_intake_link changed since this migration was written';
  end if;
  if md5(pg_get_functiondef('client.schedule_property_intake(bigint,text[],jsonb,text)'::regprocedure)) <> '71582cb90a6d037632840ad8263b33f5' then
    raise exception 'PIN: client.schedule_property_intake changed since this migration was written';
  end if;
end $pin$;

-- ----------------------------------------------------------------- 1. the one place the short link is built
create or replace function public.fn_intake_link_url(p_token text)
returns text
language sql
immutable
set search_path to ''
as $$
  select case when p_token ~ '^[A-Za-z0-9_-]{8,64}$'
              then 'https://planner.unclogme.app/intake#code=' || p_token end
$$;
comment on function public.fn_intake_link_url(text) is
  'The collector link for an intake token (the Picture Planner /intake route 308s to /intake.html). NULL when the token does not look like one. Called by client.get_intake_link and client.schedule_property_intake; intake-submit''s GET redirect is the only other place the host lives. 2026-09-25_1705.';
revoke all on function public.fn_intake_link_url(text) from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------- 2. the two callers (spliced from the live bodies, one change each)
CREATE OR REPLACE FUNCTION client.get_intake_link(p_intake_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_i     record;
  v_deleted boolean;
  v_url   text;
begin
  if v_uid is null then
    raise exception 'Please sign in again.'
      using errcode = '28000', detail = 'blocker=not_signed_in in client.get_intake_link';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.'
      using errcode = '42501', detail = 'blocker=not_staff in client.get_intake_link';
  end if;
  if p_intake_id is null then
    raise exception 'No form was chosen. Go back to the forms and try again.'
      using errcode = '22023', detail = 'blocker=no_intake in client.get_intake_link';
  end if;

  -- Everything but the token first: every refusal is decided before the token is read.
  select i.id, i.property_id, i.expires_at, i.submitted_at, i.cancelled_at
    into v_i
    from public.property_intakes i
   where i.id = p_intake_id;
  if not found then
    raise exception 'This form does not exist.'
      using errcode = 'P0002', detail = 'blocker=not_found in client.get_intake_link';
  end if;
  if v_i.cancelled_at is not null then
    raise exception 'This form was cancelled, so its link no longer opens.'
      using errcode = '22023', detail = 'blocker=cancelled in client.get_intake_link';
  end if;
  if v_i.submitted_at is not null then
    raise exception 'This form was already submitted, so its link cannot take answers any more. To collect again, schedule a new intake from the property in the Client App.'
      using errcode = '22023', detail = 'blocker=submitted in client.get_intake_link';
  end if;
  if v_i.expires_at <= now() then
    raise exception 'This link has expired. Schedule a new intake from the property in the Client App to get a new link.'
      using errcode = '22023', detail = 'blocker=expired in client.get_intake_link';
  end if;
  select (p.deleted_at is not null) into v_deleted from public.properties p where p.id = v_i.property_id;
  if coalesce(v_deleted, true) then
    raise exception 'This property was removed, so its form should not be filled any more.'
      using errcode = '22023', detail = 'blocker=property_removed in client.get_intake_link';
  end if;

  -- The link, built in ONE place, public.fn_intake_link_url (2026-09-25_1705). It returns NULL for a
  -- token that does not look like one (the collector endpoint accepts ^[A-Za-z0-9_-]{8,64}$); the token
  -- itself never appears in a message.
  select public.fn_intake_link_url(i.token)
    into v_url
    from public.property_intakes i
   where i.id = v_i.id;
  if v_url is null then
    raise exception 'This form''s link cannot be shown. Ask for help.'
      using errcode = '22023', detail = 'blocker=bad_token in client.get_intake_link';
  end if;

  insert into public.property_intake_link_reveals (intake_id, revealed_by, revealed_email)
  values (v_i.id, v_uid, v_email);

  return jsonb_build_object('ok', true, 'intake_id', v_i.id, 'url', v_url, 'expires_at', v_i.expires_at);
end
$function$;

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

  return jsonb_build_object('ok', true, 'intake_id', v_id, 'token', v_token, 'url', public.fn_intake_link_url(v_token),
                            'requested', to_jsonb(v_req), 'dropped', to_jsonb(coalesce(v_dropped, '{}'::text[])), 'added', to_jsonb(coalesce(v_added, '{}'::text[])),
                            'form_version', v_snapshot -> 'version', 'note', p_note);
end $function$;

-- ----------------------------------------------------------------- 3. cancel, staff only
create or replace function client.cancel_intake(p_intake_id bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_i     record;
  v_at    timestamptz;
begin
  if v_uid is null then
    raise exception 'Please sign in again.'
      using errcode = '28000', detail = 'blocker=not_signed_in in client.cancel_intake';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.'
      using errcode = '42501', detail = 'blocker=not_staff in client.cancel_intake';
  end if;
  if p_intake_id is null then
    raise exception 'No form was chosen. Go back to the forms and try again.'
      using errcode = '22023', detail = 'blocker=no_intake in client.cancel_intake';
  end if;

  -- The row lock makes a cancel and a collector's submit take turns (see the trigger below).
  select i.id, i.submitted_at, i.cancelled_at
    into v_i
    from public.property_intakes i
   where i.id = p_intake_id
   for update;
  if not found then
    raise exception 'This form does not exist.'
      using errcode = 'P0002', detail = 'blocker=not_found in client.cancel_intake';
  end if;
  if v_i.cancelled_at is not null then
    raise exception 'This form was already cancelled. Its link no longer opens.'
      using errcode = '22023', detail = 'blocker=already_cancelled in client.cancel_intake';
  end if;
  if v_i.submitted_at is not null then
    raise exception 'This form was already submitted, so it stays as a record and cannot be cancelled.'
      using errcode = '22023', detail = 'blocker=submitted in client.cancel_intake';
  end if;

  -- Guarded write: race-safe on its own under READ COMMITTED, the lock above is belt and braces.
  update public.property_intakes
     set cancelled_at = now()
   where id = v_i.id and submitted_at is null and cancelled_at is null
  returning cancelled_at into v_at;
  if not found then
    raise exception 'This form changed a moment ago. Reload the forms to see its state.'
      using errcode = '22023', detail = 'blocker=changed in client.cancel_intake';
  end if;

  return jsonb_build_object('ok', true, 'intake_id', v_i.id, 'cancelled_at', v_at);
end
$function$;
comment on function client.cancel_intake(bigint) is
  'Staff cancel an unsubmitted intake from the Picture Planner: its link stops at once (intake-submit answers 404). Refuses submitted and already-cancelled forms in words, blocker=<code> in DETAIL. Who cancelled is in audit.logs (audit_property_intakes). 2026-09-25_1705.';
revoke all on function client.cancel_intake(bigint) from public, anon;
grant execute on function client.cancel_intake(bigint) to authenticated;

-- ----------------------------------------------------------------- 4. a cancelled form cannot then be submitted
create or replace function public.fn_property_intake_no_submit_after_cancel()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  raise exception 'This form was cancelled, so it cannot be submitted.'
    using errcode = '22023', detail = 'blocker=cancelled in public.property_intakes (submit after cancel)';
end
$function$;
revoke all on function public.fn_property_intake_no_submit_after_cancel() from public, anon, authenticated, service_role;

create trigger property_intakes_no_submit_after_cancel
  before update of submitted_at on public.property_intakes
  for each row
  when (old.cancelled_at is not null and old.submitted_at is null and new.submitted_at is not null)
  execute function public.fn_property_intake_no_submit_after_cancel();

-- ----------------------------------------------------------------- 5. VERIFY
do $verify$
declare
  v_fred     uuid;
  v_r        jsonb;
  v_state    text; v_detail text; v_msg text;
  v_awaiting bigint; v_sub bigint; v_exp bigint; v_rem bigint; v_ctl bigint; v_new bigint;
  v_deleted_prop bigint;
  v_keys     text[];
  v_all      text[] := (select array_agg(question_key) from client.v_intake_questions);
  v_n        int;
  v_t        text;
  v_case     record;
  v_md5_view text := md5(pg_get_viewdef('client.v_intake_submissions'::regclass));
  v_md5_get  text := md5(pg_get_functiondef('client.get_intake(bigint)'::regprocedure));
  v_reveals0 bigint := (select count(*) from public.property_intake_link_reveals);
  v_intakes0 bigint := (select count(*) from public.property_intakes);
begin
  select id into v_fred from auth.users where lower(email) = 'fred@ayache.com';
  if v_fred is null then raise exception 'VERIFY 0: fred@ayache.com is missing from auth.users'; end if;
  select min(id) into v_deleted_prop from public.properties where deleted_at is not null;
  if v_deleted_prop is null then raise exception 'VERIFY 0b: no removed property to test with'; end if;

  -- V1. Grants: whole ACLs of every function this migration creates or replaces.
  foreach v_t in array array['client.cancel_intake(bigint)', 'client.get_intake_link(bigint)',
                             'client.schedule_property_intake(bigint,text[],jsonb,text)'] loop
    if (select coalesce(p.proacl::text, 'NULL') from pg_proc p where p.oid = v_t::regprocedure)
       <> '{postgres=X/postgres,authenticated=X/postgres}' then
      raise exception 'VERIFY 1a: % proacl is %', v_t, (select p.proacl::text from pg_proc p where p.oid = v_t::regprocedure);
    end if;
  end loop;
  foreach v_t in array array['public.fn_intake_link_url(text)', 'public.fn_property_intake_no_submit_after_cancel()'] loop
    if (select coalesce(p.proacl::text, 'NULL') from pg_proc p where p.oid = v_t::regprocedure) <> '{postgres=X/postgres}' then
      raise exception 'VERIFY 1b: % proacl is %', v_t, (select p.proacl::text from pg_proc p where p.oid = v_t::regprocedure);
    end if;
  end loop;
  foreach v_t in array array['anon', 'service_role', 'yannick_readonly', 'pg_read_all_data', 'supabase_read_only_user'] loop
    if has_function_privilege(v_t, 'client.cancel_intake(bigint)', 'EXECUTE') then
      raise exception 'VERIFY 1c: % can execute client.cancel_intake', v_t;
    end if;
  end loop;
  if (select tgenabled from pg_trigger where tgrelid = 'public.property_intakes'::regclass
        and tgname = 'property_intakes_no_submit_after_cancel') is distinct from 'O' then
    raise exception 'VERIFY 1d: the submit-after-cancel trigger is missing or disabled';
  end if;
  -- 1e. The race guard cannot be tested in one session, so its two halves are asserted on the body.
  if pg_get_functiondef('client.cancel_intake(bigint)'::regprocedure) !~* 'for[[:space:]]+update'
     or pg_get_functiondef('client.cancel_intake(bigint)'::regprocedure) !~* 'and[[:space:]]+submitted_at[[:space:]]+is[[:space:]]+null[[:space:]]+and[[:space:]]+cancelled_at[[:space:]]+is[[:space:]]+null' then
    raise exception 'VERIFY 1e: cancel_intake lost its row lock or its guarded write';
  end if;
  -- 1f. search_path pinned to empty on every function this migration creates or replaces.
  foreach v_t in array array['client.cancel_intake(bigint)', 'client.get_intake_link(bigint)',
                             'client.schedule_property_intake(bigint,text[],jsonb,text)', 'public.fn_intake_link_url(text)',
                             'public.fn_property_intake_no_submit_after_cancel()'] loop
    if not coalesce((select 'search_path=""' = any (p.proconfig) from pg_proc p where p.oid = v_t::regprocedure), false) then
      raise exception 'VERIFY 1f: % does not pin search_path to empty', v_t;
    end if;
  end loop;
  -- 1g. The three client RPCs are SECURITY DEFINER; the link builder is INVOKER and IMMUTABLE.
  if exists (select 1 from pg_proc p where p.oid in ('client.cancel_intake(bigint)'::regprocedure,
               'client.get_intake_link(bigint)'::regprocedure,
               'client.schedule_property_intake(bigint,text[],jsonb,text)'::regprocedure) and not p.prosecdef)
     or (select p.prosecdef or p.provolatile <> 'i' from pg_proc p where p.oid = 'public.fn_intake_link_url(text)'::regprocedure) then
    raise exception 'VERIFY 1g: security definer / invoker / immutable flags are wrong';
  end if;

  -- V2. The link builder, independently of every caller.
  if public.fn_intake_link_url('abcdEFGH1234_-xy') is distinct from 'https://planner.unclogme.app/intake#code=abcdEFGH1234_-xy' then
    raise exception 'VERIFY 2a: fn_intake_link_url built the wrong link';
  end if;
  if public.fn_intake_link_url(null) is not null or public.fn_intake_link_url('short') is not null
     or public.fn_intake_link_url('has space inside') is not null or public.fn_intake_link_url('a#b=cdefghij') is not null
     or public.fn_intake_link_url(repeat('a', 65)) is not null then
    raise exception 'VERIFY 2b: fn_intake_link_url accepted a token that does not look like one';
  end if;

  -- V3..V9 write test rows; the sentinel at the end rolls every one of them back.
  begin
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
    select 1164, s, to_jsonb(public.fn_intake_normalise_requested(s, v_all)), '[TEST] cancel verify'
      from (select public.fn_intake_form_current() s) x
    returning id into v_awaiting;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
    select property_id, form_snapshot, requested, requested_by from public.property_intakes where id = v_awaiting
    returning id into v_ctl;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, submitted_at, answers, collector)
    select property_id, form_snapshot, requested, requested_by, now(), '{}'::jsonb, '[TEST] collector'
      from public.property_intakes where id = v_awaiting
    returning id into v_sub;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, expires_at)
    select property_id, form_snapshot, requested, requested_by, now() - interval '1 minute'
      from public.property_intakes where id = v_awaiting
    returning id into v_exp;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
    select v_deleted_prop, form_snapshot, requested, requested_by
      from public.property_intakes where id = v_awaiting
    returning id into v_rem;

    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);

    -- V3. get_intake_link: same link as before, now from the helper (compared inside SQL, never printed).
    v_r := client.get_intake_link(v_ctl);
    reset role;
    if (v_r ->> 'url') is distinct from
       (select 'https://planner.unclogme.app/intake#code=' || token from public.property_intakes where id = v_ctl) then
      raise exception 'VERIFY 3: get_intake_link no longer returns the intake''s own short link';
    end if;
    set local role authenticated;

    -- V4. schedule_property_intake returns url next to token, and the url is that token's link.
    v_r := client.schedule_property_intake(1164, v_all);
    reset role;
    v_new := (v_r ->> 'intake_id')::bigint;
    if (v_r ->> 'url') is distinct from 'https://planner.unclogme.app/intake#code=' || (v_r ->> 'token')
       or (v_r ->> 'token') is distinct from (select token from public.property_intakes where id = v_new) then
      raise exception 'VERIFY 4a: schedule_property_intake url does not match the new intake''s token';
    end if;
    select array_agg(k order by k) into v_keys from jsonb_object_keys(v_r) k;
    if v_keys <> array['added', 'dropped', 'form_version', 'intake_id', 'note', 'ok', 'requested', 'token', 'url'] then
      raise exception 'VERIFY 4b: schedule_property_intake reply keys are %', v_keys;
    end if;
    set local role authenticated;

    -- V5. The happy path: an awaiting form is cancelled, audited with who did it, and its link stops.
    v_r := client.cancel_intake(v_awaiting);
    reset role;
    if not coalesce((v_r ->> 'ok')::boolean, false) or (v_r ->> 'intake_id')::bigint <> v_awaiting
       or (v_r ->> 'cancelled_at') is null
       or (select cancelled_at from public.property_intakes where id = v_awaiting) is null then
      raise exception 'VERIFY 5a: the awaiting form was not cancelled (%)', v_r;
    end if;
    select count(*) into v_n from audit.logs
     where table_name = 'property_intakes' and operation = 'UPDATE' and (new_row ->> 'id')::bigint = v_awaiting
       and new_row ->> 'cancelled_at' is not null and old_row ->> 'cancelled_at' is null
       and jwt_claims ->> 'email' = 'fred@ayache.com';
    if v_n <> 1 then raise exception 'VERIFY 5b: expected 1 audit row naming who cancelled, found %', v_n; end if;
    if exists (select 1 from client.v_intake_submissions where intake_id = v_awaiting) then
      raise exception 'VERIFY 5c: the cancelled form is still in the forms list';
    end if;
    set local role authenticated;
    begin
      perform client.get_intake_link(v_awaiting);
      raise exception 'VERIFY 5d: a cancelled form still gave its link' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=cancelled in client.get_intake_link' then
        raise exception 'VERIFY 5d: get_intake_link on a cancelled form gave % / %', v_state, v_detail;
      end if;
    end;

    -- V6. Every refusal, exact code and DETAIL, and nothing written by a refusal.
    for v_case in
      select * from (values
        (v_awaiting, '22023', 'blocker=already_cancelled in client.cancel_intake'),
        (v_sub,      '22023', 'blocker=submitted in client.cancel_intake'),
        (-1::bigint, 'P0002', 'blocker=not_found in client.cancel_intake'),
        (null::bigint, '22023', 'blocker=no_intake in client.cancel_intake')
      ) t(id, code, blocker)
    loop
      begin
        perform client.cancel_intake(v_case.id);
        raise exception 'VERIFY 6: % was not refused', v_case.blocker using errcode = 'P0003';
      exception when others then
        get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail, v_msg = message_text;
        if v_state <> v_case.code or v_detail is distinct from v_case.blocker then
          raise exception 'VERIFY 6: % gave % / % / %', v_case.blocker, v_state, v_detail, v_msg;
        end if;
        if v_msg ~ '[A-Za-z0-9_-]{16,}' then
          raise exception 'VERIFY 6: % message carries a token-like string', v_case.blocker;
        end if;
      end;
    end loop;
    reset role;
    if (select cancelled_at from public.property_intakes where id = v_sub) is not null then
      raise exception 'VERIFY 6b: refusing a submitted form still cancelled it';
    end if;
    set local role authenticated;

    -- V7. An expired link and a removed property can be cancelled.
    v_r := client.cancel_intake(v_exp);
    if not coalesce((v_r ->> 'ok')::boolean, false) then raise exception 'VERIFY 7a: an expired form could not be cancelled'; end if;
    v_r := client.cancel_intake(v_rem);
    if not coalesce((v_r ->> 'ok')::boolean, false) then raise exception 'VERIFY 7b: a removed property''s form could not be cancelled'; end if;

    -- V8. Not staff, no JWT, anon.
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'someone@gmail.com', 'role', 'authenticated')::text, true);
    begin
      perform client.cancel_intake(v_ctl);
      raise exception 'VERIFY 8a: a non-staff email cancelled a form' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '42501' or v_detail is distinct from 'blocker=not_staff in client.cancel_intake' then
        raise exception 'VERIFY 8a: non-staff gave % / %', v_state, v_detail;
      end if;
    end;
    perform set_config('request.jwt.claims', '', true);
    begin
      perform client.cancel_intake(v_ctl);
      raise exception 'VERIFY 8b: no JWT cancelled a form' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '28000' or v_detail is distinct from 'blocker=not_signed_in in client.cancel_intake' then
        raise exception 'VERIFY 8b: no JWT gave % / %', v_state, v_detail;
      end if;
    end;
    reset role;
    -- anon holds no USAGE on schema client, so V8c proves the schema gate; V1a/V1c prove the EXECUTE revoke.
    set local role anon;
    begin
      perform client.cancel_intake(v_ctl);
      raise exception 'VERIFY 8c: anon cancelled a form' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '42501' then raise exception 'VERIFY 8c: anon gave %', v_state; end if;
    end;
    reset role;
    if (select cancelled_at from public.property_intakes where id = v_ctl) is not null then
      raise exception 'VERIFY 8d: a refused caller cancelled the control form';
    end if;

    -- V9. A submit landing on a cancelled form is refused (the edge function's exact update, as the
    --     service role would send it); the same submit on the uncancelled control still works.
    set local role service_role;
    begin
      update public.property_intakes set answers = '{}'::jsonb, collector = '[TEST] late submit', submitted_at = now()
       where id = v_awaiting and submitted_at is null;
      raise exception 'VERIFY 9a: a submit landed on a cancelled form' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '22023' or v_detail is distinct from 'blocker=cancelled in public.property_intakes (submit after cancel)' then
        raise exception 'VERIFY 9a: submit after cancel gave % / %', v_state, v_detail;
      end if;
    end;
    update public.property_intakes set answers = '{}'::jsonb, collector = '[TEST] control submit', submitted_at = now()
     where id = v_ctl and submitted_at is null;
    get diagnostics v_n = row_count;
    reset role;
    if v_n <> 1 then raise exception 'VERIFY 9b: the control submit did not land (%)', v_n; end if;

    raise exception 'VERIFY_ROLLBACK_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_ROLLBACK_SENTINEL' then raise; end if;
  end;

  -- V10. Nothing from the test survived, and the read surfaces are unchanged.
  if (select count(*) from public.property_intakes) <> v_intakes0
     or exists (select 1 from public.property_intakes where requested_by = '[TEST] cancel verify')
     or (select count(*) from public.property_intake_link_reveals) <> v_reveals0 then
    raise exception 'VERIFY 10a: test rows survived the rollback';
  end if;
  if md5(pg_get_viewdef('client.v_intake_submissions'::regclass)) <> v_md5_view
     or md5(pg_get_functiondef('client.get_intake(bigint)'::regprocedure)) <> v_md5_get then
    raise exception 'VERIFY 10b: v_intake_submissions or get_intake changed';
  end if;

  raise notice 'VERIFY: all intake cancel and short link assertions passed';
end $verify$;

notify pgrst, 'reload schema';
