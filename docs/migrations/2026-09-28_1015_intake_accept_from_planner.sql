-- ============================================================================
-- 2026-09-28_1015_intake_accept_from_planner.sql (applied 2026-09-28_1309 ET)
-- 2026-09-28 · Intake answers reach the property record from the Picture Planner, page approvers only
-- ============================================================================
-- Fred, 2026-09-28, on the Accept screen: layout C, "a second tab" on the form page, then
--   "All good, except "Any staff login can accept" it should be only the ones that are page approvers".
-- Spec: Building Apps/Picture Planner/docs/specs/2026-09-28-intake-accept-tab-design.md (section 4).
--
-- 1. client.accept_intake_answers(bigint, text[]) is DROPPED and replaced by
--    client.accept_intake_answers(p_intake_id bigint, p_keys text[], p_expected jsonb). No app ever called the old
--    one (all live bundles: 0 calls) and no database object names it (checked below before the drop).
--    - Page approvers only: after the staff gate, a login not in public.fn_page_approver_ids() is refused
--      "Only <names> can save these answers to the property record." (42501, blocker=not_an_approver).
--    - Stale screen: p_expected maps each key to the "ours" the tab showed (from the compare). A key whose ours
--      changed since is refused "The property record changed since you opened this form. Reload to see it."
--      (22023, blocker=stale), before anything is written. JSON null and a missing key both mean "Not on file".
--    - A repeated key is taken once (it wrote two ledger rows); a key the form did not ask is refused
--      (blocker=not_requested, flow doc 13.2 item 27); an hours answer the writer cannot take is refused in words
--      (blocker=hours_shape) instead of the writer's technical text.
--    - Every refusal a person can reach is a plain sentence with the code in DETAIL.
--    - The test client first: until app_config key intake_accept_all_properties = 'true' (Fred opens it after the
--      live check), a form on a property outside 112-YA is refused "For now, answers can only be saved on the test
--      client 112-YA." (42501, blocker=test_only), so a build defect cannot reach a real client's record or Jobber.
-- 2. client.get_intake_compare gains can_accept (true only for a page approver) and accept_blocker (the sentence,
--    NULL for an approver): the get_page_builder can_approve / approve_blocker pattern. Otherwise unchanged.
-- 3. client.get_property_activity gains one event per property_intake_accepts row, kind intake_accepted (ord 9):
--    "Accepted from Site survey form #717 by Fred: Lock box code Not on file → 7390"; hours read
--    "...: When we can come replaced". Rows of one save keep their saved order (tie-break on the ledger id).
--
-- Unchanged and relied on: accept writes through client.update_property_operational / update_property_capacity, so
-- the Jobber push of the lock box code and the gallons still comes from trg_properties_enqueue_outbound (it needs the
-- staff JWT the Planner's call carries). Manholes, sample ports and hours are ours only.
--
-- Rule 8 (audit): no new table; property_intake_accepts, property_intakes and properties are audited. Grants: the new
-- accept is revoked by name and granted to authenticated only; the replaced functions keep theirs (asserted).
-- ATOMIC: no COMMIT; the VERIFY's writes run in a sentinel sub-block.
-- ============================================================================

do $pin$
begin
  if md5(pg_get_functiondef('client.accept_intake_answers(bigint,text[])'::regprocedure)) <> '7cdf8f2eb1f896c9928c994b9c9f2977'
     or md5(pg_get_functiondef('client.get_intake_compare(bigint)'::regprocedure)) <> '79c72142e5bb7465ee920ea3f0626e39'
     or md5(pg_get_functiondef('client.get_property_activity(bigint)'::regprocedure)) <> 'afcba377b3f243caf83e292d58b0b735'
     or md5(pg_get_functiondef('public.fn_intake_accept_map()'::regprocedure)) <> 'b299ba83e76d2547a9bd3006eadb0978'
     or md5(pg_get_functiondef('client.update_property_operational(bigint,jsonb)'::regprocedure)) <> '0ef7a1b6bce69ef74231eddb45c3cce9'
     or md5(pg_get_functiondef('client.update_property_capacity(bigint,integer)'::regprocedure)) <> 'ee90e86a382b6c15a5c25a2f4a6e466f'
     or md5(pg_get_functiondef('public.fn_page_approver_ids()'::regprocedure)) <> '1ce2b08a1c30397886e576fdc6871dae'
     or md5(pg_get_functiondef('public.fn_page_approver_names()'::regprocedure)) <> 'b0edf6bc5c8a4ea379199e20ed19b55f'
     or md5(pg_get_functiondef('public.fn_page_staff_name(text)'::regprocedure)) <> '24b7a15362dec11c2e28498487dd069d' then
    raise exception 'PIN: an intake or page function changed since this migration was written';
  end if;
  -- Nothing but the old accept itself names it. Positive control: the accept map is found in exactly two bodies.
  if (select count(*) from pg_proc where prosrc ilike '%accept_intake_answers%') <> 1
     or (select count(*) from pg_proc where prosrc ilike '%fn_intake_accept_map%') <> 2 then
    raise exception 'PIN: something else calls accept_intake_answers (or the reference check cannot see)';
  end if;
  if not exists (select 1 from auth.users where id = '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b' and lower(email) = 'fred@ayache.com')
     or not exists (select 1 from auth.users where id = '8bdb9ba7-e917-466d-bdb1-c525dbf90194' and lower(email) = 'jon.v@ayache.com')
     or not ('5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b'::uuid = any (public.fn_page_approver_ids()))
     or '8bdb9ba7-e917-466d-bdb1-c525dbf90194'::uuid = any (public.fn_page_approver_ids()) then
    raise exception 'PIN: the test logins are not what this migration expects (Fred an approver, Jonathan staff but not)';
  end if;
  if exists (select 1 from public.app_config where key = 'intake_accept_all_properties') then
    raise exception 'PIN: the open-to-every-property switch already exists; this migration ships it closed';
  end if;
end $pin$;

-- 1. The accept: dropped and recreated with the stale guard.
drop function client.accept_intake_answers(bigint, text[]);

create function client.accept_intake_answers(p_intake_id bigint, p_keys text[], p_expected jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
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
    if not public.fn_intake_answered(v_i.answers, v_key) then
      raise exception 'That question was not answered on the form, so there is nothing to save.'
        using errcode = '22023', detail = 'blocker=not_answered in client.accept_intake_answers: ' || v_key;
    end if;
    if not public.fn_intake_applicable(v_i.form_snapshot, v_i.answers, v_key) then
      raise exception 'That answer belongs to a question the collector was not shown, so it cannot be accepted.'
        using errcode = '22023',
              detail  = 'blocker=not_shown in client.accept_intake_answers: ' || v_key;
    end if;

    select f into v_field from jsonb_array_elements(v_cmp -> 'fields') f where f ->> 'key' = v_key;
    v_old := v_field -> 'ours';
    v_new := v_i.answers -> v_key -> 'value';

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
      (intake_id, property_id, question_key, target_column, old_value, new_value, actor)
    values (p_intake_id, v_i.property_id, v_key, v_col, v_old, v_new, v_actor);
    v_written := v_written || v_key;
  end loop;

  -- Reuse the gated writers rather than touching public.properties directly. They
  -- carry the allowlist, the staff gate, the error vocabulary and, for gallons and
  -- the lock box, the outbound Jobber push (which only fires because auth.uid() is
  -- not null here, i.e. because a real person pressed Save).
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

revoke all on function client.accept_intake_answers(bigint, text[], jsonb) from public, anon, authenticated, service_role;
grant execute on function client.accept_intake_answers(bigint, text[], jsonb) to authenticated;

-- 2. The compare tells the screen who may save (the live body, plus v_can and the two keys).
create or replace function client.get_intake_compare(p_intake_id bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
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
  v_can boolean;
  v_open boolean;
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

  -- Page approvers only may save, on the test client until it is opened (2026-09-28); accept_intake_answers is the
  -- gate, this only tells the screen.
  v_can := coalesce(auth.uid() = any (public.fn_page_approver_ids()), false);
  v_open := coalesce((select value from public.app_config where key = 'intake_accept_all_properties'), '') = 'true'
            or exists (select 1 from public.clients c where c.id = v_p.client_id and c.client_code = '112-YA');
  return jsonb_build_object('intake_id', v_i.id, 'property_id', v_i.property_id, 'fields', v_out,
    'can_accept', v_can and v_open,
    'accept_blocker', case when not v_can then 'Only ' || public.fn_page_approver_names() || ' can save these answers to the property record.'
                           when not v_open then 'For now, answers can only be saved on the test client 112-YA.' end);
end $function$;

-- 3. The history lists every accept (the live body, plus the tail and sub columns and the ord 9 branch).
create or replace function client.get_property_activity(p_property_id bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_property_activity';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_property_activity';
  end if;
  if p_property_id is null then
    raise exception 'No property was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_property in client.get_property_activity';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'at', ev.at, 'kind', ev.kind, 'who', ev.who, 'intake_id', ev.intake_id, 'version', ev.version,
             'text', ev.what || coalesce(' by ' || ev.who, '')
                     -- a developer approval of one's own version says so (2026-09-27)
                     || case when ev.kind = 'page_approved' and exists (
                               select 1 from public.property_pages x
                                where x.property_id = p_property_id and x.version = ev.version
                                  and x.approved_by = x.submitted_by)
                             then ', who also made it (developer approval)' else '' end
                     -- what an accept changed comes after the name (2026-09-28)
                     || coalesce(ev.tail, ''))
           order by ev.at desc, ev.ord desc, ev.sub)
      from (
        -- The office asked for a site survey form (Client App, Schedule intake). requested_by is the
        -- login email; a test script writes a "[TEST] ..." label there instead, shown as it is.
        select i.requested_at as at, 1 as ord, 'form_requested'::text as kind, i.id as intake_id, null::int as version,
               'Site survey form #' || i.id || ' requested' as what,
               case when i.requested_by like '%@%' then public.fn_page_staff_name(i.requested_by)
                    else nullif(btrim(i.requested_by), '') end as who,
               null::text as tail, null::bigint as sub
          from public.property_intakes i
         where i.property_id = p_property_id
        union all
        -- Share form on the Planner shows the collector link; every reveal is logged.
        select r.revealed_at, 2, 'form_link_shown', i.id, null,
               'Link to site survey form #' || i.id || ' shown', public.fn_page_staff_name(r.revealed_email), null, null
          from public.property_intake_link_reveals r
          join public.property_intakes i on i.id = r.intake_id
         where i.property_id = p_property_id
        union all
        -- The collector's name is what they typed on the form, not a login.
        select i.submitted_at, 3, 'form_filled', i.id, null,
               'Site survey form #' || i.id || ' filled in', nullif(btrim(i.collector), ''), null, null
          from public.property_intakes i
         where i.property_id = p_property_id and i.submitted_at is not null
        union all
        select i.cancelled_at, 4, 'form_cancelled', i.id, null,
               'Site survey form #' || i.id || ' cancelled',
               public.fn_page_staff_name((
                 select l.jwt_claims ->> 'email' from audit.logs l
                  where l.table_name = 'property_intakes' and l.record_pk ->> 'id' = i.id::text
                    and l.table_schema = 'public' and l.operation = 'UPDATE'
                    and l.old_row ->> 'cancelled_at' is null and l.new_row ->> 'cancelled_at' is not null
                  order by l.changed_at desc limit 1)), null, null
          from public.property_intakes i
         where i.property_id = p_property_id and i.cancelled_at is not null
        union all
        -- "Who made the draft": the person who sent the version for approval.
        select pg.submitted_at, 5, 'page_submitted', null, pg.version,
               'Version ' || pg.version || ' of the driver page submitted for approval',
               public.fn_page_staff_name(pg.submitted_by_email), null, null
          from public.property_pages pg
         where pg.property_id = p_property_id
        union all
        select pg.approved_at, 6, 'page_approved', null, pg.version,
               'Version ' || pg.version || ' of the driver page approved',
               public.fn_page_staff_name(pg.approved_by_email), null, null
          from public.property_pages pg
         where pg.property_id = p_property_id and pg.approved_at is not null
        union all
        select k.created_at, 7, 'driver_link_created', null, null, 'Driver link created',
               public.fn_page_staff_name((select u.email from auth.users u where u.id = k.created_by)), null, null
          from public.property_page_links k
         where k.property_id = p_property_id
        union all
        -- public_id is a redacted audit column, so a rotation shows as rotated_at moving. Never the link.
        select l.changed_at, 8, 'driver_link_replaced', null, null, 'Driver link replaced',
               public.fn_page_staff_name(l.jwt_claims ->> 'email'), null, null
          from audit.logs l
         where l.table_name = 'property_page_links' and l.table_schema = 'public' and l.operation = 'UPDATE'
           and l.record_pk ->> 'property_id' = p_property_id::text
           and l.old_row ->> 'rotated_at' is distinct from l.new_row ->> 'rotated_at'
        union all
        -- An approver saved a form answer to the property record (Picture Planner, 2026-09-28). One row per field;
        -- the rows of one save share accepted_at, so the ledger id keeps them in the order they were saved.
        -- The lock box code is shown: staff already see it on the property card.
        select a.accepted_at, 9, 'intake_accepted', a.intake_id, null,
               'Accepted from Site survey form #' || a.intake_id,
               public.fn_page_staff_name(a.actor),
               ': ' || case a.question_key
                         when 'access_entry.lock_box_code'   then 'Lock box code'
                         when 'access_hours.schedule'        then 'When we can come'
                         when 'grease_trap.capacity_gallons' then 'Grease trap gallons'
                         when 'grease_trap.manhole_count'    then 'Manholes'
                         when 'grease_trap.sample_ports'     then 'Sample ports'
                         else a.question_key end
                    || case when a.question_key = 'access_hours.schedule' then ' replaced'
                            else ' ' || coalesce(a.old_value #>> '{}', 'Not on file') || ' → '
                                     || coalesce(a.new_value #>> '{}', 'Not on file') end,
               a.id
          from public.property_intake_accepts a
         where a.property_id = p_property_id
      ) ev
     where ev.at is not null), '[]'::jsonb);
end $function$;

-- VERIFY. Everything below writes only inside the sentinel block, which is rolled back.
do $verify$
declare
  v_fred   uuid := '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b';
  v_jon    uuid := '8bdb9ba7-e917-466d-bdb1-c525dbf90194';
  v_ro     text := 'Only ' || public.fn_page_approver_names() || ' can save these answers to the property record.';
  v_stale  text := 'The property record changed since you opened this form. Reload to see it.';
  v_all    text[] := array['access_entry.lock_box_code', 'access_hours.schedule', 'grease_trap.capacity_gallons',
                           'grease_trap.manhole_count', 'grease_trap.sample_ports'];
  v_ans    jsonb := (select answers from public.property_intakes where id = 715);
  v_lock   text := public.fn_intake_trim(v_ans #>> '{access_entry.lock_box_code,value}');
  v_gal    integer := public.fn_intake_trim(v_ans #>> '{grease_trap.capacity_gallons,value}')::integer;
  v_mh     integer := public.fn_intake_trim(v_ans #>> '{grease_trap.manhole_count,value}')::integer;
  v_sp     integer := public.fn_intake_trim(v_ans #>> '{grease_trap.sample_ports,value}')::integer;
  v_pre    text := 'Accepted from Site survey form #715 by ' || public.fn_page_staff_name('fred@ayache.com') || ': ';
  v_cmp jsonb; v_exp jsonb; v_r jsonb; v_act jsonb; v_tid bigint; v_aid bigint; v_oid bigint;
  v_state text; v_detail text; v_msg text;
  v_ledger0 bigint := (select count(*) from public.property_intake_accepts);
  v_prop0   text   := (select md5(to_jsonb(p)::text) from public.properties p where id = 1164);
  v_queue0  bigint := (select count(*) from sync.outbound_queue where entity_type = 'property' and entity_id = 1164);
  v_acc0    jsonb  := (select accepted from public.property_intakes where id = 715);
  v_n0      bigint := (select count(*) from public.property_intakes where property_id = 1164);
begin
  -- V0. The fixture: form 715 answered all five.
  if v_lock is null or v_gal is null or v_mh is null or v_sp is null or v_ans #> '{access_hours.schedule,value}' is null then
    raise exception 'VERIFY 0: form 715 no longer answers all five fields';
  end if;

  -- V1. The two-argument accept is gone; the three functions are authenticated only.
  if to_regprocedure('client.accept_intake_answers(bigint,text[])') is not null then
    raise exception 'VERIFY 1a: the two-argument accept still exists';
  end if;
  if (select string_agg(coalesce(proacl::text, 'NULL'), ' ') from pg_proc where oid in (
        'client.accept_intake_answers(bigint,text[],jsonb)'::regprocedure, 'client.get_intake_compare(bigint)'::regprocedure,
        'client.get_property_activity(bigint)'::regprocedure))
     <> '{postgres=X/postgres,authenticated=X/postgres} {postgres=X/postgres,authenticated=X/postgres} {postgres=X/postgres,authenticated=X/postgres}' then
    raise exception 'VERIFY 1b: a grant is wrong';
  end if;

  begin
    -- V2. The compare tells the screen who may save.
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    v_cmp := client.get_intake_compare(715);
    if (v_cmp ->> 'can_accept')::boolean is distinct from true or not (v_cmp ? 'accept_blocker') or v_cmp ->> 'accept_blocker' is not null then
      raise exception 'VERIFY 2a: Fred reads can_accept % / %', v_cmp ->> 'can_accept', v_cmp ->> 'accept_blocker';
    end if;
    if (select count(*) from jsonb_array_elements(v_cmp -> 'fields') f where f ->> 'state' = 'blank') <> 5 then
      raise exception 'VERIFY 2b: form 715 on property 1164 no longer has five blank fields; the fixture changed';
    end if;
    select jsonb_object_agg(f ->> 'key', f -> 'ours') into v_exp from jsonb_array_elements(v_cmp -> 'fields') f;
    perform set_config('request.jwt.claims', json_build_object('sub', v_jon, 'email', 'jon.v@ayache.com', 'role', 'authenticated')::text, true);
    v_cmp := client.get_intake_compare(715);
    if (v_cmp ->> 'can_accept')::boolean is distinct from false or v_cmp ->> 'accept_blocker' is distinct from v_ro then
      raise exception 'VERIFY 2c: a staff login that is not an approver reads % / %', v_cmp ->> 'can_accept', v_cmp ->> 'accept_blocker';
    end if;

    -- V3. Not an approver, and not staff: refused before anything else.
    begin
      perform client.accept_intake_answers(715, v_all, v_exp);
      raise exception 'VERIFY 3a: a staff login that is not an approver saved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail, v_msg = message_text;
      if v_state <> '42501' or v_detail is distinct from 'blocker=not_an_approver in client.accept_intake_answers' or v_msg is distinct from v_ro then
        raise exception 'VERIFY 3a: gave % / % / %', v_state, v_detail, v_msg;
      end if;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'email', 'verify.outsider@gmail.com', 'role', 'authenticated')::text, true);
    begin
      perform client.accept_intake_answers(715, v_all, v_exp);
      raise exception 'VERIFY 3b: a non-staff login saved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '42501' or v_detail is distinct from 'blocker=not_staff in client.accept_intake_answers' then
        raise exception 'VERIFY 3b: gave % / %', v_state, v_detail;
      end if;
    end;

    -- V4. Fred: the refusals that come before any write.
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    begin
      perform client.accept_intake_answers(715, array[null]::text[], v_exp);
      raise exception 'VERIFY 4a: no keys saved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=no_keys in client.accept_intake_answers' then raise exception 'VERIFY 4a: gave % / %', v_state, v_detail; end if;
    end;
    begin
      perform client.accept_intake_answers(715, v_all, null);
      raise exception 'VERIFY 4b: no p_expected saved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=no_expected in client.accept_intake_answers' then raise exception 'VERIFY 4b: gave % / %', v_state, v_detail; end if;
    end;
    begin
      perform client.accept_intake_answers(-1, v_all, v_exp);
      raise exception 'VERIFY 4c: an unknown form saved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> 'P0002' or v_detail is distinct from 'blocker=not_found in client.accept_intake_answers' then raise exception 'VERIFY 4c: gave % / %', v_state, v_detail; end if;
    end;
    begin
      perform client.accept_intake_answers(715, array['verify.not_a_field'], v_exp);
      raise exception 'VERIFY 4d: a key with no property field saved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=no_property_field in client.accept_intake_answers: verify.not_a_field' then raise exception 'VERIFY 4d: gave % / %', v_state, v_detail; end if;
    end;
    begin
      perform client.accept_intake_answers(715, array['access_entry.lock_box_code'], '{"access_entry.lock_box_code": "0000"}');
      raise exception 'VERIFY 4e: a screen that showed another lock box code saved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail, v_msg = message_text;
      if v_state <> '22023' or v_detail is distinct from 'blocker=stale in client.accept_intake_answers: access_entry.lock_box_code' or v_msg is distinct from v_stale then
        raise exception 'VERIFY 4e: gave % / % / %', v_state, v_detail, v_msg;
      end if;
    end;
    reset role;
    if (select count(*) from public.property_intake_accepts) <> v_ledger0 then
      raise exception 'VERIFY 4f: a refusal wrote a ledger row';
    end if;

    -- V5. Fred saves all five, the lock box key sent twice.
    set local role authenticated;
    v_r := client.accept_intake_answers(715, v_all || array['access_entry.lock_box_code'], v_exp);
    if v_r -> 'accepted' is distinct from to_jsonb(v_all) or v_r ->> 'by' is distinct from 'fred@ayache.com' then
      raise exception 'VERIFY 5a: the reply reads %', v_r - 'by';
    end if;
    v_act := client.get_property_activity(1164);
    v_cmp := client.get_intake_compare(715);
    reset role;
    if (select count(*) from public.property_intake_accepts where intake_id = 715) <> 5 then
      raise exception 'VERIFY 5b: % ledger rows (expected 5: the repeated key is taken once)',
        (select count(*) from public.property_intake_accepts where intake_id = 715);
    end if;
    if (select lock_box_key from public.properties where id = 1164) is distinct from v_lock
       or (select grease_trap_size_gallons from public.properties where id = 1164) is distinct from v_gal
       or (select grease_trap_manhole_count from public.properties where id = 1164) is distinct from v_mh
       or (select sample_port_count from public.properties where id = 1164) is distinct from v_sp
       or (select access_schedule from public.properties where id = 1164) is distinct from v_ans #> '{access_hours.schedule,value}' then
      raise exception 'VERIFY 5c: the property record does not hold the form''s five answers';
    end if;
    if (select count(*) from sync.outbound_queue q
         where q.entity_type = 'property' and q.entity_id = 1164 and q.status = 'pending' and q.enqueued_by = v_fred::text
           and ((q.field_label = 'Lock Box/Key' and q.desired_value = to_jsonb(v_lock))
             or (q.field_label = 'Grease Trap size' and q.desired_value = to_jsonb(v_gal)))) <> 2 then
      raise exception 'VERIFY 5d: the lock box code and the gallons were not both queued for Jobber';
    end if;
    if (select count(*) from jsonb_array_elements(v_cmp -> 'fields') f where f ->> 'state' = 'same') <> 5 then
      raise exception 'VERIFY 5e: after the save the compare does not read "same" on all five';
    end if;
    -- (row 0 holds the lock box code, so it is compared but never printed)
    if (select count(*) from jsonb_array_elements(v_act) e where e ->> 'kind' = 'intake_accepted') <> 5
       or v_act -> 0 ->> 'text' is distinct from v_pre || 'Lock box code Not on file → ' || v_lock
       or v_act -> 1 ->> 'text' is distinct from v_pre || 'When we can come replaced'
       or v_act -> 2 ->> 'text' is distinct from v_pre || 'Grease trap gallons Not on file → ' || v_gal
       or v_act -> 3 ->> 'text' is distinct from v_pre || 'Manholes Not on file → ' || v_mh
       or v_act -> 4 ->> 'text' is distinct from v_pre || 'Sample ports Not on file → ' || v_sp
       or (v_act -> 0 ->> 'intake_id')::bigint is distinct from 715 then
      raise exception 'VERIFY 5f: the history reads % | % | % | %',
        v_act -> 1 ->> 'text', v_act -> 2 ->> 'text', v_act -> 3 ->> 'text', v_act -> 4 ->> 'text';
    end if;

    -- V6. The stale guard compares the VALUE: the screen said "Not on file" but manholes now reads v_mh.
    set local role authenticated;
    begin
      perform client.accept_intake_answers(715, array['grease_trap.manhole_count'], '{"grease_trap.manhole_count": null}');
      raise exception 'VERIFY 6a: a stale screen saved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail, v_msg = message_text;
      if v_state <> '22023' or v_detail is distinct from 'blocker=stale in client.accept_intake_answers: grease_trap.manhole_count'
         or v_msg is distinct from v_stale then
        raise exception 'VERIFY 6a: gave % / % / %', v_state, v_detail, v_msg;
      end if;
    end;
    -- control: the same call, sending what the property now holds, goes through
    v_r := client.accept_intake_answers(715, array['grease_trap.manhole_count'], jsonb_build_object('grease_trap.manhole_count', v_mh));
    if v_r -> 'accepted' is distinct from '["grease_trap.manhole_count"]'::jsonb then
      raise exception 'VERIFY 6b: the control did not save (%)', v_r -> 'accepted';
    end if;

    -- V7. Two made-up [TEST] forms on 1164 (rolled back with the rest): a key the form did not ask, hours the writer
    -- cannot take, and a form nobody submitted.
    reset role;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, collector, answers, submitted_at)
    select property_id, form_snapshot, requested - 'grease_trap.sample_ports', '[TEST] verify 2026-09-28', '[TEST] verify',
           jsonb_set(answers, '{access_hours.schedule,value}', '{"mon": {"open": "9am", "close": "17:00"}}'), now()
      from public.property_intakes where id = 715
    returning id into v_tid;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
    select property_id, form_snapshot, requested, '[TEST] verify 2026-09-28' from public.property_intakes where id = 715
    returning id into v_aid;
    set local role authenticated;
    begin
      perform client.accept_intake_answers(v_tid, array['grease_trap.sample_ports'], jsonb_build_object('grease_trap.sample_ports', v_sp));
      raise exception 'VERIFY 7a: a key the form did not ask was saved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=not_requested in client.accept_intake_answers: grease_trap.sample_ports' then
        raise exception 'VERIFY 7a: gave % / %', v_state, v_detail;
      end if;
    end;
    v_cmp := client.get_intake_compare(v_tid);
    begin
      perform client.accept_intake_answers(v_tid, array['access_hours.schedule'], jsonb_build_object('access_hours.schedule',
                (select f -> 'ours' from jsonb_array_elements(v_cmp -> 'fields') f where f ->> 'key' = 'access_hours.schedule')));
      raise exception 'VERIFY 7b: hours the writer cannot take were saved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=hours_shape in client.accept_intake_answers: access_hours.schedule' then
        raise exception 'VERIFY 7b: gave % / %', v_state, v_detail;
      end if;
    end;
    begin
      perform client.accept_intake_answers(v_aid, array['grease_trap.manhole_count'], '{}');
      raise exception 'VERIFY 7c: a form nobody submitted was saved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_detail is distinct from 'blocker=not_submitted in client.accept_intake_answers' then
        raise exception 'VERIFY 7c: gave % / %', v_state, v_detail;
      end if;
    end;

    -- V9. The test client only, until opened: a made-up [TEST] form on another client's property is read-only and
    -- refused; the one config row that opens it turns the same form on (nothing is saved on that property).
    reset role;
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, collector, answers, submitted_at)
    select (select p.id from public.properties p join public.clients c on c.id = p.client_id
             where c.client_code <> '112-YA' and p.deleted_at is null order by p.id limit 1),
           form_snapshot, requested, '[TEST] verify 2026-09-28', '[TEST] verify', answers, now()
      from public.property_intakes where id = 715
    returning id into v_oid;
    set local role authenticated;
    v_cmp := client.get_intake_compare(v_oid);
    if (v_cmp ->> 'can_accept')::boolean is distinct from false
       or v_cmp ->> 'accept_blocker' is distinct from 'For now, answers can only be saved on the test client 112-YA.' then
      raise exception 'VERIFY 9a: another client''s form reads % / %', v_cmp ->> 'can_accept', v_cmp ->> 'accept_blocker';
    end if;
    select jsonb_object_agg(f ->> 'key', f -> 'ours') into v_exp from jsonb_array_elements(v_cmp -> 'fields') f;
    begin
      perform client.accept_intake_answers(v_oid, array['grease_trap.manhole_count'], v_exp);
      raise exception 'VERIFY 9b: another client''s property was saved while closed' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '42501' or v_detail is distinct from 'blocker=test_only in client.accept_intake_answers' then
        raise exception 'VERIFY 9b: gave % / %', v_state, v_detail;
      end if;
    end;
    reset role;
    insert into public.app_config (key, value) values ('intake_accept_all_properties', 'true');
    set local role authenticated;
    v_cmp := client.get_intake_compare(v_oid);
    if (v_cmp ->> 'can_accept')::boolean is distinct from true or v_cmp ->> 'accept_blocker' is not null then
      raise exception 'VERIFY 9c: the open switch did not open it (% / %)', v_cmp ->> 'can_accept', v_cmp ->> 'accept_blocker';
    end if;
    reset role;

    raise exception 'VERIFY_ROLLBACK_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_ROLLBACK_SENTINEL' then raise; end if;
  end;

  -- V8. Nothing from the test survived.
  if (select count(*) from public.property_intake_accepts) <> v_ledger0
     or (select md5(to_jsonb(p)::text) from public.properties p where id = 1164) is distinct from v_prop0
     or (select count(*) from sync.outbound_queue where entity_type = 'property' and entity_id = 1164) <> v_queue0
     or (select accepted from public.property_intakes where id = 715) is distinct from v_acc0
     or (select count(*) from public.property_intakes where property_id = 1164) <> v_n0
     or exists (select 1 from public.property_intakes where requested_by = '[TEST] verify 2026-09-28')
     or exists (select 1 from public.app_config where key = 'intake_accept_all_properties') then
    raise exception 'VERIFY 8: test rows survived the rollback';
  end if;
  raise notice 'VERIFY: approvers only, test client only until opened; stale screens refused (and the same call with the current value goes through); repeats taken once; unasked keys, bad hours and unsubmitted forms refused; the history reads each accept';
end $verify$;

notify pgrst, 'reload schema';
