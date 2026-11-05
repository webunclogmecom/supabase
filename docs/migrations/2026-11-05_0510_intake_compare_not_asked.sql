-- 2026-11-05_0510_intake_compare_not_asked
-- Fred, 2026-11-05, answered "Fix it" on screen 5 of the office training film, shown a before and after picture of the Property record
-- tab: it shows what is on file and "Not asked, already on file". Decisions row: Supabase/docs/decisions-to-build.md (seven screens, item 5).
--
-- THE DEFECT: client.get_intake_compare loops over the form's requested keys only, so a question the office skipped because the
-- value is on file has no row. The Planner fills a missing row with ours = null and draws "Not on file", the opposite of why it was
-- skipped. The spec already said this row shows "our value or 'Not on file'" (Picture Planner docs/specs/2026-09-28-intake-accept-tab-design.md,
-- section 3.3, line 74); the function never returned it.
-- REACH, measured 2026-11-05 (read-only, 18 submitted forms): 13 rows on 10 forms say Not on file when the value IS on file, 6 of those
-- forms on real clients. Lock box 4 (1 real), hours 5 (5 real), gallons 2 (1 real), manholes 2 (2 real). Sample ports and location 0.
-- 6 more not-asked manholes rows hold 0 on file; 0 reads as blank on purpose, so they stay Not on file / Not on the form. Gallons of 0
-- read the same way on a not-asked row (12 properties hold 0, no not-asked row hits it today).
--
-- WHAT CHANGES: this one function. Every form now returns all six rows. A key the form did not ask gets state 'not_asked',
-- ours = the same value the asked rows read, theirs = null. Requested rows are untouched, same order, new rows after them.
-- WHAT DOES NOT: accept_intake_answers (it refuses the key at blocker=not_requested, before it reads this row); the gates; the grants.
-- WHO SEES THE VALUE: the same gate as every asked row: staff email plus hr.fn_require_app('picture_planner','view'). Measured
-- 2026-11-05: 5 people hold it. A Forms-only person is refused (probe_pp_forms.sql, 'get_intake_compare (Property record) refused').
-- READERS, all checked: Picture Planner PropertyRecordTab (maps rows by key, ticks only blank and differs, already greys not_asked);
-- accept_intake_answers (by key, after the guard); public.fn_intake_gallons_offer (a comment only); tests accept_tab, gallons_text,
-- several_traps, size_lookup, v5-live, v6-live (all find a row by key). No view reads it. No other app's bundle does.
-- ORDER: this first, then the Planner's one line. Between them the row reads the value and "Not on the form", which is true.
-- Audit (rule 8): no table changes, no write path. Function comment corrected too: it named 4 of the now 7 states.
-- Rehearsed with ROLLBACK before applying: the old body fails VERIFY at V1, the new body passes, this file plus its rollback leaves the old md5.
-- Rollback: 2026-11-05_rollback_intake_compare_not_asked.sql.
-- Docs in the same cycle: Building Apps/docs/client-intake-flow.md (sections 'get_intake_compare' and Property record),
-- Picture Planner CLAUDE.md rule 19 and docs/08-changelog.md, Supabase docs/reference/client-intake-system.md.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path TO '';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('client.get_intake_compare(bigint)'::regprocedure)) <> 'ded16ded3733b1468f0becb58dc1feaf' THEN RAISE EXCEPTION 'guard: get_intake_compare moved'; END IF;
END $guard$;

-- What every submitted form reads before the change, to prove nothing else moved. Dropped with the transaction; never printed.
SELECT set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
CREATE TEMP TABLE _cmp_before ON COMMIT DROP AS
  SELECT i.id, client.get_intake_compare(i.id) AS c FROM public.property_intakes i WHERE i.submitted_at IS NOT NULL;

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
  v_offer jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email','')))
      then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  perform hr.fn_require_app('picture_planner', 'view');   -- 2026-10-20_1600 access phase 3

  select * into v_i from public.property_intakes where id = p_intake_id;
  if not found then
    raise exception 'intake % not found', p_intake_id using errcode = 'P0002';
  end if;
  select * into v_p from public.properties where id = v_i.property_id;

  -- distinct, non-blank requested keys in their requested order (the same normalisation as
  -- public.fn_intake_missing), so a duplicated key is never compared twice.
  -- 2026-11-05 (Fred, training film screen 5): then every accept-map key this form did not ask, so that row can say what
  -- is on file (state not_asked below) instead of the app drawing "Not on file" for a missing row.
  for v_key in select z.k from (
                 select e.k, min(e.ord) as ord from jsonb_array_elements_text(v_i.requested) with ordinality e(k, ord)
                  where e.k is not null and btrim(e.k) <> ''
                  group by e.k
                 union all
                 select m.k, null from jsonb_object_keys(v_map) m(k) where not (v_i.requested ? m.k)
               ) z order by z.ord nulls last, z.k loop
    v_col := v_map ->> v_key;
    continue when v_col is null;                       -- intake-only answer, nothing to compare

    v_theirs := v_i.answers -> v_key -> 'value';
    v_ours := case v_col
      when 'grease_trap_manhole_count' then to_jsonb(nullif(v_p.grease_trap_manhole_count, 0))
      when 'sample_port_count'         then to_jsonb(v_p.sample_port_count)
      when 'grease_trap_size_gallons'  then to_jsonb(v_p.grease_trap_size_gallons)
      when 'lock_box_key'              then to_jsonb(nullif(btrim(coalesce(v_p.lock_box_key,'')), ''))
      when 'access_schedule'           then v_p.access_schedule
      when 'grease_trap_location'      then to_jsonb(v_p.grease_trap_location)
    end;

    -- 2026-11-05: not asked on this form. ours is what is on file; theirs is always null, even if the raw record holds a
    -- stray answer for this key ("Also in the record" shows those). The screen gives this state no tick, and
    -- accept_intake_answers refuses the key (blocker=not_requested) before it reads this row. Gallons of 0 read as blank here,
    -- because accept_intake_answers says a 0 means nobody knows it; asked rows keep reading the stored number.
    if not (v_i.requested ? v_key) then
      v_out := v_out || jsonb_build_object('key', v_key, 'column', v_col,
        'ours', case when v_col = 'grease_trap_size_gallons' then nullif(v_ours, '0'::jsonb) else v_ours end,
        'theirs', null, 'state', 'not_asked');
      continue;
    end if;

    -- A question the collector was NOT shown (its show_if chain did not match) may still
    -- carry a stale answer typed before the parent changed. It must never be offered for
    -- accept: it would write a lock-box code the collector abandoned into the property, and
    -- on to Jobber (third review round, 2026-09-24).
    -- Gallons (form version 2, 2026-09-29) is a TEXT answer (Fred: "Gallons" and "Measurements" "both are texts").
    -- Only a plain whole number from 1 to 20,000 ("1,000", "1000 gal") can reach the property record, and it is
    -- compared as that number, so "1,000 gal" reads same against a stored 1000. Any other text is shown on the form
    -- page and never offered: state not_savable. A version 1 number answer reads exactly as before.
    -- 2026-10-22 (Trello 6t3RDVkE): gallons the AI looked up from the collector's grease trap model or measurements.
    -- public.fn_intake_gallons_offer is THE rule (accept_intake_answers calls it too): it offers a number only when the
    -- collector's own Gallons is not a whole number from 1 to 20,000, and the row then compares that number and carries
    -- 'offer' (what was looked up, the summary, the source page) so the screen can say where it came from.
    v_offer := case when v_col = 'grease_trap_size_gallons' then public.fn_intake_gallons_offer(v_i.id) end;
    if v_offer is not null then
      v_theirs := v_offer -> 'gallons';
    end if;
    v_gal := case when v_col = 'grease_trap_size_gallons' then public.fn_intake_whole_gallons(v_theirs) end;
    v_state := case
      when v_offer is null and not public.fn_intake_applicable(v_i.form_snapshot, v_i.answers, v_key) then 'not_shown'
      when v_offer is null and not public.fn_intake_answered(v_i.answers, v_key) then 'unanswered'
      when v_col = 'grease_trap_size_gallons' and not coalesce(v_gal between 1 and 20000, false) then 'not_savable'
      when v_ours is null or v_ours = 'null'::jsonb          then 'blank'
      when v_ours = case when v_col = 'grease_trap_size_gallons' then to_jsonb(v_gal) else v_theirs end then 'same'
      else 'differs'
    end;

    v_out := v_out || (jsonb_build_object(
      'key', v_key, 'column', v_col, 'ours', v_ours, 'theirs', v_theirs, 'state', v_state)
      || case when v_offer is not null then jsonb_build_object('offer', v_offer) else '{}'::jsonb end);
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

COMMENT ON FUNCTION client.get_intake_compare(bigint) IS 'What the office accept screen renders: one row for each of the six accept-map keys, on every form. state is blank (pre-ticked), same (no-op), differs (show both values, a human decides, Fred 2026-09-22), unanswered, not_shown, not_savable (gallons only) or not_asked (this form did not ask it: ours is what is on file, theirs is null, never offered, accept_intake_answers refuses it). A stored manhole count of 0 reads as BLANK on purpose: 370 of 506 rows are 0 and the column is NOT NULL DEFAULT 0, so zero and unknown are the same value.';

DO $verify$
DECLARE
  v_n bigint; v_id bigint; v_ours jsonb; v_state text; v_det text;
BEGIN
  -- V1 the rule: every submitted form has exactly the six rows, each key once.
  SELECT count(*) INTO v_n FROM _cmp_before b
   WHERE jsonb_array_length(client.get_intake_compare(b.id) -> 'fields') <> 6
      OR (SELECT count(DISTINCT f ->> 'key') FROM jsonb_array_elements(client.get_intake_compare(b.id) -> 'fields') f) <> 6;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY V1: % forms do not have exactly the six rows', v_n; END IF;

  -- V2 nothing else moved: without the new rows, each form's reply is the reply it gave before, same rows, same order.
  SELECT count(*) INTO v_n FROM _cmp_before b, LATERAL (SELECT client.get_intake_compare(b.id) AS c) a
   WHERE (a.c - 'fields') IS DISTINCT FROM (b.c - 'fields')
      OR (SELECT coalesce(jsonb_agg(x.f ORDER BY x.o), '[]'::jsonb) FROM jsonb_array_elements(a.c -> 'fields') WITH ORDINALITY x(f, o)
           WHERE x.f ->> 'state' <> 'not_asked') IS DISTINCT FROM (b.c -> 'fields');
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY V2: % forms changed beyond the new rows', v_n; END IF;

  -- V3 a not_asked row is exactly a key the form did not ask, and it never carries a form value or an offer.
  SELECT count(*) INTO v_n FROM public.property_intakes i, LATERAL jsonb_array_elements(client.get_intake_compare(i.id) -> 'fields') f
   WHERE i.submitted_at IS NOT NULL
     AND ((f ->> 'state' = 'not_asked') <> (NOT (i.requested ? (f ->> 'key')))
          OR (f ->> 'state' = 'not_asked' AND (f -> 'theirs' <> 'null'::jsonb OR f ? 'offer')));
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY V3: % rows break the not_asked shape', v_n; END IF;

  -- V4 THE REPORTED CASE, the control the old body must fail: a lock box code on file that the form did not ask reads as on file.
  -- Measured 2026-11-05: 4 forms, 1 real and 3 on 112-YA.
  SELECT count(*) INTO v_n FROM public.property_intakes i
    JOIN public.properties p ON p.id = i.property_id,
    LATERAL jsonb_array_elements(client.get_intake_compare(i.id) -> 'fields') f
   WHERE i.submitted_at IS NOT NULL AND nullif(btrim(coalesce(p.lock_box_key, '')), '') IS NOT NULL
     AND NOT (i.requested ? 'access_entry.lock_box_code')
     AND f ->> 'key' = 'access_entry.lock_box_code' AND f ->> 'state' = 'not_asked' AND f -> 'ours' <> 'null'::jsonb;
  IF v_n < 1 THEN RAISE EXCEPTION 'VERIFY V4: no not-asked lock box code reads as on file'; END IF;

  -- V5 it cannot be saved: a not_asked key on the test client is refused, with what the screen showed. Nothing is written before the refusal.
  SELECT i.id INTO v_id FROM public.property_intakes i
    JOIN public.properties p ON p.id = i.property_id JOIN public.clients c ON c.id = p.client_id
   WHERE c.client_code = '112-YA' AND i.submitted_at IS NOT NULL AND NOT (i.requested ? 'access_entry.lock_box_code')
     AND nullif(btrim(coalesce(p.lock_box_key, '')), '') IS NOT NULL
   ORDER BY i.id DESC LIMIT 1;
  IF v_id IS NULL THEN RAISE EXCEPTION 'VERIFY V5: fixture gone, no not-asked lock box form on 112-YA'; END IF;
  SELECT f -> 'ours' INTO v_ours FROM jsonb_array_elements(client.get_intake_compare(v_id) -> 'fields') f WHERE f ->> 'key' = 'access_entry.lock_box_code';
  BEGIN
    PERFORM client.accept_intake_answers(v_id, ARRAY['access_entry.lock_box_code'], jsonb_build_object('access_entry.lock_box_code', v_ours));
    RAISE EXCEPTION 'VERIFY V5: the accept took a not-asked key';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_det = PG_EXCEPTION_DETAIL;
    IF v_det NOT LIKE 'blocker=not_requested%' THEN RAISE EXCEPTION 'VERIFY V5: refused for another reason: %', v_det; END IF;
  END;

  -- V6 the door is the same: gate lines still in the body, grants unchanged, still SECURITY DEFINER.
  IF pg_get_functiondef('client.get_intake_compare(bigint)'::regprocedure) NOT LIKE '%hr.fn_require_app(''picture_planner'', ''view'')%' THEN RAISE EXCEPTION 'VERIFY V6: the app gate is gone'; END IF;
  IF has_function_privilege('anon', 'client.get_intake_compare(bigint)', 'EXECUTE') OR NOT has_function_privilege('authenticated', 'client.get_intake_compare(bigint)', 'EXECUTE') THEN RAISE EXCEPTION 'VERIFY V6: grants moved'; END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'client.get_intake_compare(bigint)'::regprocedure) THEN RAISE EXCEPTION 'VERIFY V6: no longer SECURITY DEFINER'; END IF;
END $verify$;

SELECT set_config('request.jwt.claims', '', true);
COMMIT;
