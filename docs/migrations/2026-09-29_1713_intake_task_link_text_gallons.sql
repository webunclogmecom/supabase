-- ============================================================================
-- 2026-09-29_1713_intake_task_link_text_gallons.sql (applied 2026-09-29 17:13 ET)
-- 2026-09-29 · The intake task link, and a text Gallons that still reaches the property record
-- ============================================================================
-- Fred, 2026-09-29:
--   (A) "At Client App, when we schedule it, we need to assign it to a person, and it needs to create a Task at
--       jobber and calendar app too, and we can take even advantage of that to prefill the name field at the
--       intake form"
--   (B) "at the Photos of the capacity plate or measurements question, we're missing 2 fields "Gallons" and
--       "Measurements" both are texts." Picked after the mockups: "Text box, as I said".
-- Design: Building Apps/Client App/docs/specs/2026-09-29-schedule-assign-task-design.md (sections 3 and 5).
--
-- 1. public.property_intakes.calendar_task_id bigint, UNIQUE, references ops.calendar_tasks(id) ON DELETE SET NULL.
--    Written only by the edge function save-calendar-task (service_role, x-app-source client-app) after the task is
--    recorded; read only by intake-submit (the assignee's name for "Your name"). Not frozen by
--    fn_property_intake_immutable (it freezes answers, submitted_at, collector, requested), so a task deleted in the
--    Calendar or in Jobber clears it. No new grant: authenticated holds none on this table, yannick_readonly's
--    column grant is not widened.
-- 2. NEW public.fn_intake_whole_gallons(jsonb) returns integer (IMMUTABLE, pure). Fred's rule for the text box: a
--    plain whole number after trimming, with optional thousands commas and an optional trailing "gal" or "gallons"
--    (any case), is that number; anything else is NULL. A version 1 number answer reads as itself.
--    Callers check the range (1 to 20,000). EXECUTE revoked from every app role: only the two SECURITY DEFINER
--    functions below call it, as their owner.
-- 3. client.get_intake_compare: for the gallons row, a text that is not a whole number from 1 to 20,000 reads the
--    NEW state 'not_savable' (shown, never offered: the Property record tab renders an unknown state as a white row
--    with the form's text and no checkbox, measured on the live chunk _staff.forms._id-CgXya2IY.js), and a whole
--    number is compared as a number, so "1,000 gal" reads 'same' against a stored 1000. 'theirs' stays the raw
--    answer. Four lines; every other byte copied from the live body.
-- 4. client.accept_intake_answers: a gallons text that reads as a whole number is taken as that number before the
--    existing whole-number and range checks. Everything else, the refusals included, is the live body unchanged.
--
-- Key choice (design section 5): the form keeps the key grease_trap.capacity_gallons. The Property record tab
-- (hard-coded key list), formToPage (reads a digit string), get_property_activity ("Grease trap gallons") and the
-- Client App's on-file map all key on it, so a new key would need a Picture Planner change before gallons could
-- reach the property again.
--
-- Rule 8 (audit): no new table; property_intakes (audit_property_intakes) and ops.calendar_tasks (audit_calendar_tasks)
-- are audited, so the new column is captured in full-row audit rows. ATOMIC: no COMMIT; the VERIFY's writes run in a
-- sentinel sub-block that is rolled back.
-- ============================================================================

do $pin$
begin
  if md5(pg_get_functiondef('client.get_intake_compare(bigint)'::regprocedure)) <> 'c2d7af8401b590dd7f500e1d3e33bdbe'
     or md5(pg_get_functiondef('client.accept_intake_answers(bigint,text[],jsonb)'::regprocedure)) <> '8c5ff6001c762fa3f264d8e6b9cdef76'
     or md5(pg_get_functiondef('public.fn_intake_accept_map()'::regprocedure)) <> 'b299ba83e76d2547a9bd3006eadb0978'
     or md5(pg_get_functiondef('public.fn_property_intake_immutable()'::regprocedure)) <> '4f3aa897df12a7bfd1e3d37ec36af75e' then
    raise exception 'PIN: a function this migration copies or relies on changed since 2026-09-29; re-read it and rebuild';
  end if;
  if exists (select 1 from pg_attribute where attrelid = 'public.property_intakes'::regclass and attname = 'calendar_task_id' and not attisdropped)
     or to_regprocedure('public.fn_intake_whole_gallons(jsonb)') is not null then
    raise exception 'PIN: calendar_task_id or fn_intake_whole_gallons already exists; this migration was applied';
  end if;
end $pin$;

create function public.fn_intake_whole_gallons(p jsonb)
returns integer
language sql
immutable
set search_path to ''
as $function$
  -- Form version 2 asks "Gallons" as TEXT (Fred, 2026-09-29: "Text box, as I said"). A plain whole number after
  -- trimming, with optional thousands commas and an optional trailing gal or gallons in any case (Fred's words), is that
  -- number; anything else is NULL, and the form's text is then shown only. A number answer (version 1 asked a
  -- number box) reads as itself when it is whole. At most 6 digits, the most accept's whole-number check takes,
  -- so the cast never overflows. No range here: the callers check 1 to 20,000.
  select case jsonb_typeof(p)
    when 'number' then case when (p #>> '{}') ~ '^[0-9]{1,6}$' then (p #>> '{}')::integer end
    when 'string' then (
      select case when m is not null and length(replace(m[1], ',', '')) <= 6 then replace(m[1], ',', '')::integer end
        from regexp_match(lower(public.fn_intake_trim(p #>> '{}')),
                          '^([0-9]{1,3}(,[0-9]{3})+|[0-9]+)[[:space:]]*(gal|gallons)?$') m)
  end;
$function$;

revoke all on function public.fn_intake_whole_gallons(jsonb) from public, anon, authenticated, service_role;

alter table public.property_intakes
  add column calendar_task_id bigint
    constraint property_intakes_calendar_task_id_key unique
    constraint property_intakes_calendar_task_id_fkey references ops.calendar_tasks(id) on delete set null;

comment on column public.property_intakes.calendar_task_id is
  'The Calendar/Jobber task made for this form when it was scheduled with an assignee (Client App, 2026-09-29). Written by save-calendar-task only; intake-submit reads it for the assignee''s name. NULL when no task, or when the task was deleted.';

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
  v_can boolean;
  v_open boolean;
  v_gal integer;
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
    -- Gallons (form version 2, 2026-09-29) is a TEXT answer (Fred: "Gallons" and "Measurements" "both are texts").
    -- Only a plain whole number from 1 to 20,000 ("1,000", "1000 gal") can reach the property record, and it is
    -- compared as that number, so "1,000 gal" reads same against a stored 1000. Any other text is shown on the form
    -- page and never offered: state not_savable. A version 1 number answer reads exactly as before.
    v_gal := case when v_col = 'grease_trap_size_gallons' then public.fn_intake_whole_gallons(v_theirs) end;
    v_state := case
      when not public.fn_intake_applicable(v_i.form_snapshot, v_i.answers, v_key) then 'not_shown'
      when not public.fn_intake_answered(v_i.answers, v_key) then 'unanswered'
      when v_col = 'grease_trap_size_gallons' and not coalesce(v_gal between 1 and 20000, false) then 'not_savable'
      when v_ours is null or v_ours = 'null'::jsonb          then 'blank'
      when v_ours = case when v_col = 'grease_trap_size_gallons' then to_jsonb(v_gal) else v_theirs end then 'same'
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
end $function$
;

CREATE OR REPLACE FUNCTION client.accept_intake_answers(p_intake_id bigint, p_keys text[], p_expected jsonb)
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
      -- Gallons (form version 2, 2026-09-29) is a text answer: "1,000" and "1000 gal" are that whole number, read by
      -- public.fn_intake_whole_gallons exactly as get_intake_compare offers it. Anything else meets the refusals below.
      if v_col = 'grease_trap_size_gallons' and public.fn_intake_whole_gallons(v_new) is not null then
        v_new := to_jsonb(public.fn_intake_whole_gallons(v_new));
      end if;
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
end $function$
;

-- VERIFY. Everything that writes runs inside the sentinel block below and is rolled back.
do $verify$
declare
  v_fred  uuid := '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b';
  v_key   text := 'grease_trap.capacity_gallons';
  v_snap  jsonb := '{"version":2,"sections":[{"id":"grease_trap","title":"Grease trap","questions":[
                     {"key":"grease_trap.systems_count","type":"number","label":"How many grease trap systems?"},
                     {"key":"grease_trap.capacity_gallons","type":"text","label":"Gallons","show_if":"grease_trap.systems_count>0","optional":true,"single_line":true,"max_chars":50},
                     {"key":"grease_trap.manhole_count","type":"number","label":"How many manholes?","max":50}]}]}';
  v_req   jsonb := '["grease_trap.systems_count","grease_trap.capacity_gallons","grease_trap.manhole_count"]';
  -- name, the gallons answer, the compare state it must read while the property holds 1000
  v_cases jsonb := '[{"n":"same_text","v":"1,000 gal","w":"same"},
                     {"n":"same_plain","v":"1000","w":"same"},
                     {"n":"same_spaced","v":"  1,000   gallons ","w":"same"},
                     {"n":"differs_text","v":"2,500","w":"differs"},
                     {"n":"prose","v":"about 1000","w":"not_savable"},
                     {"n":"zero","v":"0","w":"not_savable"},
                     {"n":"over","v":"25000","w":"not_savable"},
                     {"n":"old_same","v":1000,"w":"same"},
                     {"n":"old_differs","v":1500,"w":"differs"}]';
  v_c jsonb; v_f jsonb; v_cmp jsonb; v_r jsonb;
  v_ids jsonb := '{}'::jsonb; v_id bigint; v_task bigint; v_a bigint; v_b bigint;
  v_state text; v_detail text; v_msg text;
begin
  -- V1. The helper's truth table (Fred's rule), NULL in, NULL out.
  for v_c in select * from jsonb_array_elements('[
      ["30",30],["1,000",1000],[" 1,000 gal ",1000],["1000 gallons",1000],["1000 GALLONS",1000],["1000 gallon",null],["30gal",30],["2,500 GAL",2500],
      [30,30],[1000,1000],["0",0],
      ["1,00",null],["30.5",null],[30.5,null],["about 30",null],["30 gal.",null],["gal",null],["",null],["   ",null],
      ["1234567",null],["12,345,678",null],["-5",null],[true,null],[null,null],["1 000",null],["1,000,",null]]'::jsonb) loop
    if public.fn_intake_whole_gallons(v_c -> 0) is distinct from (v_c ->> 1)::integer then
      raise exception 'VERIFY 1: fn_intake_whole_gallons(%) = %, want %', v_c -> 0, public.fn_intake_whole_gallons(v_c -> 0), v_c ->> 1;
    end if;
  end loop;
  if public.fn_intake_whole_gallons(null) is not null then
    raise exception 'VERIFY 1b: fn_intake_whole_gallons(NULL) is not NULL';
  end if;

  -- V2. The column: bigint, unique, a foreign key to ops.calendar_tasks that sets NULL on delete.
  if not exists (select 1 from pg_attribute a where a.attrelid = 'public.property_intakes'::regclass and a.attname = 'calendar_task_id'
                  and a.atttypid = 'bigint'::regtype and not a.attisdropped) then
    raise exception 'VERIFY 2a: property_intakes.calendar_task_id is missing or not bigint';
  end if;
  if not exists (select 1 from pg_constraint c where c.conname = 'property_intakes_calendar_task_id_fkey' and c.contype = 'f'
                  and c.conrelid = 'public.property_intakes'::regclass and c.confrelid = 'ops.calendar_tasks'::regclass and c.confdeltype = 'n') then
    raise exception 'VERIFY 2b: the foreign key to ops.calendar_tasks (on delete set null) is missing';
  end if;
  if not exists (select 1 from pg_constraint c where c.conname = 'property_intakes_calendar_task_id_key' and c.contype = 'u'
                  and c.conrelid = 'public.property_intakes'::regclass) then
    raise exception 'VERIFY 2c: the unique constraint on calendar_task_id is missing';
  end if;

  -- V3. Grants: the helper belongs to its owner only; compare and accept keep exactly their grants; no app role
  -- gained the table or the new column.
  if (select proacl::text from pg_proc where oid = 'public.fn_intake_whole_gallons(jsonb)'::regprocedure) is distinct from '{postgres=X/postgres}' then
    raise exception 'VERIFY 3a: fn_intake_whole_gallons grants are %', (select proacl::text from pg_proc where oid = 'public.fn_intake_whole_gallons(jsonb)'::regprocedure);
  end if;
  if (select string_agg(proacl::text, ' ' order by oid) from pg_proc where oid in ('client.get_intake_compare(bigint)'::regprocedure,
        'client.accept_intake_answers(bigint,text[],jsonb)'::regprocedure))
     <> '{postgres=X/postgres,authenticated=X/postgres} {postgres=X/postgres,authenticated=X/postgres}' then
    raise exception 'VERIFY 3b: compare or accept grants changed';
  end if;
  if has_column_privilege('authenticated', 'public.property_intakes', 'calendar_task_id', 'SELECT')
     or has_column_privilege('anon', 'public.property_intakes', 'calendar_task_id', 'SELECT')
     or has_column_privilege('yannick_readonly', 'public.property_intakes', 'calendar_task_id', 'SELECT')
     or (select relacl::text from pg_class where oid = 'public.property_intakes'::regclass) is distinct from '{postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}' then
    raise exception 'VERIFY 3c: an app role can read calendar_task_id, or the table grants changed';
  end if;

  begin
    -- Fixture: property 1164 (112-YA) holds 1000 gallons here, whatever it holds live; one submitted form per case.
    update public.properties set grease_trap_size_gallons = 1000 where id = 1164;
    for v_c in select * from jsonb_array_elements(v_cases) loop
      insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, answers, collector, submitted_at)
      values (1164, v_snap, v_req, '[TEST] verify text gallons',
              jsonb_build_object('grease_trap.systems_count', jsonb_build_object('value', 1),
                                 v_key, jsonb_build_object('value', v_c -> 'v'),
                                 'grease_trap.manhole_count', jsonb_build_object('value', '3')),
              '[TEST] verify', now())
      returning id into v_id;
      v_ids := v_ids || jsonb_build_object(v_c ->> 'n', v_id);
    end loop;

    -- V4. Compare, read as Fred: the state per case; theirs is the raw answer; ours is the stored number.
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    for v_c in select * from jsonb_array_elements(v_cases) loop
      v_cmp := client.get_intake_compare((v_ids ->> (v_c ->> 'n'))::bigint);
      select f into v_f from jsonb_array_elements(v_cmp -> 'fields') f where f ->> 'key' = v_key;
      if v_f ->> 'state' is distinct from v_c ->> 'w' then
        raise exception 'VERIFY 4a: % (%) reads state %, want %', v_c ->> 'n', v_c -> 'v', v_f ->> 'state', v_c ->> 'w';
      end if;
      if v_f -> 'theirs' is distinct from v_c -> 'v' then
        raise exception 'VERIFY 4b: % theirs is %, want the raw answer %', v_c ->> 'n', v_f -> 'theirs', v_c -> 'v';
      end if;
      if v_f -> 'ours' is distinct from '1000'::jsonb then
        raise exception 'VERIFY 4c: % ours is %, want 1000', v_c ->> 'n', v_f -> 'ours';
      end if;
    end loop;

    -- V5. Accept, as Fred: a text whole number is saved as that number; prose and out-of-range text are refused in
    -- words; an old number answer still saves; a digit-string manhole answer still saves (regression).
    begin
      v_r := client.accept_intake_answers((v_ids ->> 'differs_text')::bigint, array[v_key], jsonb_build_object(v_key, 1000));
    exception when others then
      get stacked diagnostics v_msg = message_text;
      raise exception 'VERIFY 5a: "2,500" was refused: %', v_msg;
    end;
    if (v_r ->> 'ok')::boolean is distinct from true then raise exception 'VERIFY 5a: "2,500" was not saved: %', v_r; end if;
    begin
      perform client.accept_intake_answers((v_ids ->> 'prose')::bigint, array[v_key], jsonb_build_object(v_key, 2500));
      raise exception 'VERIFY 5b: "about 1000" was saved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail, v_msg = message_text;
      if v_state <> '22023' or v_detail is distinct from 'blocker=not_whole_number in client.accept_intake_answers: ' || v_key
         or v_msg is distinct from 'That answer is not a whole number, so it cannot be accepted.' then
        raise exception 'VERIFY 5b: "about 1000" gave % / % / %', v_state, v_detail, v_msg;
      end if;
    end;
    foreach v_msg in array array['over', 'zero'] loop
      begin
        perform client.accept_intake_answers((v_ids ->> v_msg)::bigint, array[v_key], jsonb_build_object(v_key, 2500));
        raise exception 'VERIFY 5c: % was saved', v_msg using errcode = 'P0003';
      exception when others then
        get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
        if v_state <> '22023' or v_detail is distinct from 'blocker=gallons_out_of_range in client.accept_intake_answers: ' || v_key then
          raise exception 'VERIFY 5c: % gave % / %', v_msg, v_state, v_detail;
        end if;
      end;
    end loop;
    begin
      v_r := client.accept_intake_answers((v_ids ->> 'old_differs')::bigint, array[v_key], jsonb_build_object(v_key, 2500));
    exception when others then
      get stacked diagnostics v_msg = message_text;
      raise exception 'VERIFY 5d: the old number 1500 was refused: %', v_msg;
    end;
    if (v_r ->> 'ok')::boolean is distinct from true then raise exception 'VERIFY 5d: the old number 1500 was not saved: %', v_r; end if;
    v_cmp := client.get_intake_compare((v_ids ->> 'differs_text')::bigint);
    select f into v_f from jsonb_array_elements(v_cmp -> 'fields') f where f ->> 'key' = 'grease_trap.manhole_count';
    begin
      v_r := client.accept_intake_answers((v_ids ->> 'differs_text')::bigint, array['grease_trap.manhole_count'],
                                          jsonb_build_object('grease_trap.manhole_count', v_f -> 'ours'));
    exception when others then
      get stacked diagnostics v_msg = message_text;
      raise exception 'VERIFY 5e: the manhole "3" was refused: %', v_msg;
    end;
    if (v_r ->> 'ok')::boolean is distinct from true then raise exception 'VERIFY 5e: the manhole "3" was not saved: %', v_r; end if;
    reset role;
    if (select grease_trap_size_gallons from public.properties where id = 1164) is distinct from 1500
       or (select grease_trap_manhole_count from public.properties where id = 1164) is distinct from 3 then
      raise exception 'VERIFY 5f: 1164 holds % gallons and % manholes, want 1500 and 3',
        (select grease_trap_size_gallons from public.properties where id = 1164), (select grease_trap_manhole_count from public.properties where id = 1164);
    end if;
    if (select new_value from public.property_intake_accepts where intake_id = (v_ids ->> 'differs_text')::bigint and question_key = v_key)
       is distinct from '2500'::jsonb then
      raise exception 'VERIFY 5g: the ledger does not hold the number 2500 for "2,500"';
    end if;

    -- V6. The link: one task per form, one form per task, and a deleted task clears the form's link.
    insert into ops.calendar_tasks (title) values ('[TEST] verify intake link') returning id into v_task;
    v_a := (v_ids ->> 'same_text')::bigint;
    v_b := (v_ids ->> 'same_plain')::bigint;
    update public.property_intakes set calendar_task_id = v_task where id = v_a;
    begin
      update public.property_intakes set calendar_task_id = v_task where id = v_b;
      raise exception 'VERIFY 6a: two forms took one task' using errcode = 'P0003';
    exception when unique_violation then null;
    end;
    delete from ops.calendar_tasks where id = v_task;
    if (select calendar_task_id from public.property_intakes where id = v_a) is not null then
      raise exception 'VERIFY 6b: deleting the task did not clear the form''s link';
    end if;

    raise exception 'VERIFY_ROLLBACK_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_ROLLBACK_SENTINEL' then raise; end if;
  end;
  raise notice 'VERIFY: the gallons reading, the column, the grants, compare (same/differs/not_savable), accept (number, refusals, old answers) and the task link all hold';
end $verify$;

notify pgrst, 'reload schema';
