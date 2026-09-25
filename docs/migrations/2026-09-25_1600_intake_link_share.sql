-- =============================================================================
-- 2026-09-25_1600_intake_link_share.sql
-- "Share form" on Picture Planner /forms: staff can see an AWAITING intake's collector link again.
--
-- Fred, 2026-09-25: "At the planner one at the /forms we should have like the 'More Vertical' icon
-- (three consecutive dots) with a menu and have like a 'Share form' item there where it opens a modal
-- with a field pre-filled with the URL we created for the collector, that way the collector or any
-- other person can open the form to fill in case they need it again."
--
-- This answers the RE-SHOW half of open decision 13.2 item 7 of Building Apps/docs/client-intake-flow.md
-- ("re-show a link?"): yes, on demand, to staff, one intake at a time, only while the form can still be
-- filled. The CANCEL half stays open for Fred; until then a mis-shared link is revoked by a Supabase
-- session with: update public.property_intakes set cancelled_at = now() where id = <id>
-- and submitted_at is null and cancelled_at is null;  (every collector call then answers 404).
-- Until now the token surfaced only in client.schedule_property_intake's return value ("shown once").
--
-- WHAT
--   public.property_intake_link_reveals   who revealed which intake's link, when (no token, no URL)
--   client.get_intake_link(bigint)        the collector link of ONE awaiting intake, logged
--
-- 🛑 THE LINK IS THE SHORT FORM URL, https://planner.unclogme.app/intake#code=<token>, NOT the
--    office link <supabase>/functions/v1/intake-submit?t=<token>. Fred: "can't we remove that .html?".
--    /intake is a server route in Picture Planner that answers 308 to /intake.html with an EMPTY body
--    (measured 2026-09-25: when the route returned the HTML itself, the hosting injected its /~flock.js
--    tracker and og:image tags into it; a redirect has no body to inject into). Browsers carry the
--    #code=... fragment across the redirect, so the collector lands on the untouched static page. Both open the same form, but the
--    office link's ?t= lands in Supabase function_edge_logs (measured 2026-09-25: all three live tokens
--    are there), while a fragment never reaches any server. The URL is built HERE, once, so the app
--    never handles a bare token and the key stays `code` (the one the analytics guard scrubs).
--    ⚠ Coupling: the form host is now written in two places, this function and intake-submit's
--    FORM_URL (which still redirects the office link straight to /intake.html). Move both together.
-- 🛑 NEVER put the token or the link into a view, a list RPC, a table column or a message. This is
--    the one sanctioned re-display (REF rule 10 is amended to say so). Every refusal is checked
--    BEFORE the token is read into anything that could be returned or logged; no RAISE carries it.
-- 🛑 REFUSED unless awaiting: cancelled, submitted (the link only shows "Already submitted"), expired,
--    and a REMOVED property (the collector endpoint does not check deleted_at, so a shared link on a
--    removed property would still take a submission). Precedence matches client.get_intake.
-- 🛑 GRANTS. client has no function default ACL, so a new client function is EXECUTE-able by PUBLIC:
--    revoked from public and anon, granted to authenticated only; the VERIFY asserts the whole proacl.
--    The EXECUTE grant is the real boundary (a session can forge request.jwt.claims); the email check
--    in the body is defence in depth. A table postgres creates in public gets authenticated=arwdDxtm
--    and yannick_readonly=r by default: the log table and its sequence are revoked by name from
--    public, anon, authenticated and yannick_readonly, and the VERIFY asserts the whole relacl.
-- RULE 8, AUDIT: property_intake_link_reveals opts OUT. It IS the trail (an append-only log written
--   only by the function); auditing it would double every row for no reader. It holds no token and no
--   URL, so nothing needs redaction. Same shape as property_page_opens (2026-09-25_1330), but NOT
--   throttled: every row is a deliberate staff click, and the point is to know each one.
-- VOLATILE (it writes the log), so supabase-js calls it with POST in a read-write transaction.
-- ATOMIC: no COMMIT. The VERIFY's writes run inside a sentinel sub-block and are rolled back.
-- =============================================================================

-- ------------------------------------------------------------------ 1. THE LOG
create table public.property_intake_link_reveals (
  id             bigint generated always as identity primary key,
  intake_id      bigint not null references public.property_intakes(id) on delete cascade,
  revealed_by    uuid   not null,
  revealed_email text   not null,
  revealed_at    timestamptz not null default now()
);
create index property_intake_link_reveals_intake_idx on public.property_intake_link_reveals (intake_id, revealed_at desc);
comment on table public.property_intake_link_reveals is
  'Who revealed which intake''s collector link, and when (client.get_intake_link, Picture Planner "Share form"). No token, no URL. Written only by client.get_intake_link; no app role can read it. Not audited: it is the trail.';

alter table public.property_intake_link_reveals enable row level security;
revoke all on public.property_intake_link_reveals from public, anon, authenticated, yannick_readonly;
do $g$
begin
  execute format('revoke all on sequence %s from public, anon, authenticated, yannick_readonly',
                 pg_get_serial_sequence('public.property_intake_link_reveals', 'id'));
end $g$;

-- ------------------------------------------------------------- 2. THE FUNCTION
create function client.get_intake_link(p_intake_id bigint)
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

  -- The link, built once here. The shape check keeps anything odd out of a URL (the collector
  -- endpoint accepts ^[A-Za-z0-9_-]{8,64}$); the token itself never appears in a message.
  select 'https://planner.unclogme.app/intake#code=' || i.token
    into v_url
    from public.property_intakes i
   where i.id = v_i.id and i.token ~ '^[A-Za-z0-9_-]{8,64}$';
  if v_url is null then
    raise exception 'This form''s link cannot be shown. Ask for help.'
      using errcode = '22023', detail = 'blocker=bad_token in client.get_intake_link';
  end if;

  insert into public.property_intake_link_reveals (intake_id, revealed_by, revealed_email)
  values (v_i.id, v_uid, v_email);

  return jsonb_build_object('ok', true, 'intake_id', v_i.id, 'url', v_url, 'expires_at', v_i.expires_at);
end
$function$;

comment on function client.get_intake_link(bigint) is
  'Picture Planner "Share form": the collector link (https://planner.unclogme.app/intake#code=<token>, a 308 to /intake.html) of ONE awaiting intake, for a staff JWT; logs each reveal in public.property_intake_link_reveals. Refuses cancelled, submitted, expired and removed-property intakes. The only re-display of an intake token (REF rule 10).';

revoke all on function client.get_intake_link(bigint) from public, anon;
grant execute on function client.get_intake_link(bigint) to authenticated;

-- ----------------------------------------------------------------- 3. VERIFY
do $verify$
declare
  v_fred     uuid;
  v_r        jsonb;
  v_state    text;
  v_detail   text;
  v_msg      text;
  v_awaiting bigint; v_sub bigint; v_can bigint; v_exp bigint; v_rem bigint;
  v_deleted_prop bigint;
  v_ok       boolean;
  v_n        int;
  v_audit0   bigint; v_audit1 bigint;
  v_md5_view text := md5(pg_get_viewdef('client.v_intake_submissions'::regclass));
  v_md5_get  text := md5(pg_get_functiondef('client.get_intake(bigint)'::regprocedure));
  v_t        text;
begin
  select id into v_fred from auth.users where lower(email) = 'fred@ayache.com';
  if v_fred is null then raise exception 'VERIFY 0: fred@ayache.com is missing from auth.users'; end if;
  select min(id) into v_deleted_prop from public.properties where deleted_at is not null;
  if v_deleted_prop is null then raise exception 'VERIFY 0b: no removed property to test with'; end if;

  -- V1. Grants: the whole ACLs, and has_*_privilege for every role that matters.
  select coalesce(p.proacl::text, 'NULL') into v_t from pg_proc p where p.oid = 'client.get_intake_link(bigint)'::regprocedure;
  if v_t <> '{postgres=X/postgres,authenticated=X/postgres}' then
    raise exception 'VERIFY 1a: client.get_intake_link proacl is %', v_t;
  end if;
  foreach v_t in array array['anon', 'service_role', 'yannick_readonly', 'pg_read_all_data', 'supabase_read_only_user'] loop
    if has_function_privilege(v_t, 'client.get_intake_link(bigint)', 'EXECUTE') then
      raise exception 'VERIFY 1b: % can execute client.get_intake_link', v_t;
    end if;
  end loop;
  if not has_function_privilege('authenticated', 'client.get_intake_link(bigint)', 'EXECUTE') then
    raise exception 'VERIFY 1c: authenticated cannot execute client.get_intake_link';
  end if;
  select c.relacl::text into v_t from pg_class c where c.oid = 'public.property_intake_link_reveals'::regclass;
  if v_t <> '{postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}' then
    raise exception 'VERIFY 1d: property_intake_link_reveals relacl is %', v_t;
  end if;
  foreach v_t in array array['anon', 'authenticated', 'yannick_readonly'] loop
    if has_table_privilege(v_t, 'public.property_intake_link_reveals', 'SELECT')
       or has_table_privilege(v_t, 'public.property_intake_link_reveals', 'INSERT') then
      raise exception 'VERIFY 1e: % can read or write property_intake_link_reveals', v_t;
    end if;
    if has_sequence_privilege(v_t, pg_get_serial_sequence('public.property_intake_link_reveals', 'id'), 'USAGE')
       or has_sequence_privilege(v_t, pg_get_serial_sequence('public.property_intake_link_reveals', 'id'), 'SELECT') then
      raise exception 'VERIFY 1f: % can use the reveal log sequence', v_t;
    end if;
  end loop;
  -- The log holds no token and no URL, by construction.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'property_intake_link_reveals'
                and column_name not in ('id', 'intake_id', 'revealed_by', 'revealed_email', 'revealed_at')) then
    raise exception 'VERIFY 1g: the reveal log has an unexpected column';
  end if;
  -- The token is still unreadable to app roles (the V4 allowlist of 2026-09-24_0348 is untouched).
  if has_column_privilege('authenticated', 'public.property_intakes', 'token', 'SELECT')
     or has_column_privilege('yannick_readonly', 'public.property_intakes', 'token', 'SELECT')
     or has_column_privilege('anon', 'public.property_intakes', 'token', 'SELECT') then
    raise exception 'VERIFY 1h: an app role can read property_intakes.token';
  end if;

  -- V2..V9 write test rows; the sentinel at the end rolls every one of them back.
  begin
    -- Fixtures (as postgres): one intake per state, all [TEST], on the test client's property 1164
    -- or on an already-removed property. No property row is written.
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
    select 1164, s, to_jsonb(public.fn_intake_normalise_requested(s, (select array_agg(question_key) from client.v_intake_questions))),
           '[TEST] link share verify'
      from (select public.fn_intake_form_current() s) x
    returning id into v_awaiting;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, submitted_at, answers, collector)
    select property_id, form_snapshot, requested, requested_by, now(), '{}'::jsonb, '[TEST] collector'
      from public.property_intakes where id = v_awaiting
    returning id into v_sub;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, cancelled_at)
    select property_id, form_snapshot, requested, requested_by, now()
      from public.property_intakes where id = v_awaiting
    returning id into v_can;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, expires_at)
    select property_id, form_snapshot, requested, requested_by, now() - interval '1 minute'
      from public.property_intakes where id = v_awaiting
    returning id into v_exp;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
    select v_deleted_prop, form_snapshot, requested, requested_by
      from public.property_intakes where id = v_awaiting
    returning id into v_rem;

    select count(*) into v_audit0 from audit.logs;

    -- V2. Staff JWT, awaiting: the link is the short form URL with THIS intake's token. The URL is
    --     compared inside SQL and only a boolean leaves; the token is never printed.
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    v_r := client.get_intake_link(v_awaiting);
    reset role;
    select (v_r ->> 'url') = 'https://planner.unclogme.app/intake#code=' || i.token
       and (v_r ->> 'ok')::boolean
       and (v_r ->> 'intake_id')::bigint = v_awaiting
       and (v_r ->> 'expires_at')::timestamptz = i.expires_at
       and not ((v_r ->> 'url') like '%?t=%')
      into v_ok
      from public.property_intakes i where i.id = v_awaiting;
    if not coalesce(v_ok, false) then raise exception 'VERIFY 2a: the awaiting intake did not return its own direct link'; end if;
    if (select count(*) from jsonb_object_keys(v_r)) <> 4 then raise exception 'VERIFY 2b: the reply carries extra keys'; end if;

    -- V3. The reveal was logged, once, with the caller, and the log row has no token in it.
    select count(*) into v_n from public.property_intake_link_reveals
     where intake_id = v_awaiting and revealed_by = v_fred and revealed_email = 'fred@ayache.com';
    if v_n <> 1 then raise exception 'VERIFY 3a: expected 1 reveal row, found %', v_n; end if;
    if exists (select 1 from public.property_intake_link_reveals r join public.property_intakes i on i.id = r.intake_id
                where position(i.token in to_jsonb(r)::text) > 0) then
      raise exception 'VERIFY 3b: a reveal row carries the token';
    end if;

    -- V4. A reveal writes no audit row (the function only reads property_intakes; the log is not audited).
    select count(*) into v_audit1 from audit.logs;
    if v_audit1 <> v_audit0 then raise exception 'VERIFY 4: a reveal wrote % audit row(s)', v_audit1 - v_audit0; end if;

    -- V5. Every refusal, as the staff JWT, with its blocker; none of them logs anything.
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    declare
      v_case record;
    begin
      for v_case in
        select * from (values (v_sub, 'submitted', '22023'), (v_can, 'cancelled', '22023'), (v_exp, 'expired', '22023'),
                              (v_rem, 'property_removed', '22023'), (-1::bigint, 'not_found', 'P0002'),
                              (null::bigint, 'no_intake', '22023')) t(id, blocker, errcode)
      loop
        begin
          perform client.get_intake_link(v_case.id);
          raise exception 'VERIFY 5: % was not refused', v_case.blocker using errcode = 'P0003';
        exception when others then
          get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail, v_msg = message_text;
          if v_state = 'P0003' then raise; end if;
          if v_state <> v_case.errcode or v_detail <> 'blocker=' || v_case.blocker || ' in client.get_intake_link' then
            raise exception 'VERIFY 5: % gave % / % / %', v_case.blocker, v_state, v_detail, v_msg;
          end if;
          -- No run of 16+ token characters in the operator message (the plain sentences have none; a
          -- token would). DETAIL is exact-matched above, so it cannot carry one either.
          if v_msg ~ '[A-Za-z0-9_-]{16,}' then
            raise exception 'VERIFY 5: % message carries a token-like string', v_case.blocker;
          end if;
        end;
      end loop;
    end;

    -- V6. A non-staff JWT and a missing JWT are refused.
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'someone@gmail.com', 'role', 'authenticated')::text, true);
    begin
      perform client.get_intake_link(v_awaiting);
      raise exception 'VERIFY 6a: a non-staff email got a link' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '42501' or v_detail <> 'blocker=not_staff in client.get_intake_link' then
        raise exception 'VERIFY 6a: non-staff gave % / %', v_state, v_detail;
      end if;
    end;
    perform set_config('request.jwt.claims', '', true);
    begin
      perform client.get_intake_link(v_awaiting);
      raise exception 'VERIFY 6b: no JWT got a link' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '28000' or v_detail <> 'blocker=not_signed_in in client.get_intake_link' then
        raise exception 'VERIFY 6b: no JWT gave % / %', v_state, v_detail;
      end if;
    end;
    reset role;

    -- V7. anon cannot call it at all (no USAGE on client, no EXECUTE).
    set local role anon;
    begin
      perform client.get_intake_link(v_awaiting);
      raise exception 'VERIFY 7: anon got a link' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '42501' then raise exception 'VERIFY 7: anon gave %', v_state; end if;
    end;
    reset role;

    -- V8. Only the one successful call was logged (no refusal wrote a row).
    select count(*) into v_n from public.property_intake_link_reveals where intake_id in (v_awaiting, v_sub, v_can, v_exp, v_rem);
    if v_n <> 1 then raise exception 'VERIFY 8: expected 1 reveal row in total, found %', v_n; end if;

    -- V9. authenticated cannot read the log directly.
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    begin
      perform 1 from public.property_intake_link_reveals limit 1;
      raise exception 'VERIFY 9: authenticated read the reveal log' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '42501' then raise exception 'VERIFY 9: reading the log gave %', v_state; end if;
    end;
    reset role;

    raise exception 'VERIFY_ROLLBACK_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_ROLLBACK_SENTINEL' then raise; end if;
  end;

  -- V10. Nothing from the test survived, and the read surfaces it must not touch are unchanged.
  if exists (select 1 from public.property_intakes where requested_by = '[TEST] link share verify')
     or exists (select 1 from public.property_intake_link_reveals) then
    raise exception 'VERIFY 10a: test rows survived the rollback';
  end if;
  if md5(pg_get_viewdef('client.v_intake_submissions'::regclass)) <> v_md5_view
     or md5(pg_get_functiondef('client.get_intake(bigint)'::regprocedure)) <> v_md5_get then
    raise exception 'VERIFY 10b: v_intake_submissions or get_intake changed';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'client' and table_name = 'v_intake_submissions' and column_name in ('token', 'url', 'link')) then
    raise exception 'VERIFY 10c: the list view exposes a link';
  end if;

  raise notice 'VERIFY: all intake link share assertions passed';
end $verify$;

notify pgrst, 'reload schema';
