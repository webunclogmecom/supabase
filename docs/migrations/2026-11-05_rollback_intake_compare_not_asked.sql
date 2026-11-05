-- Rollback of 2026-11-05_0510_intake_compare_not_asked. Puts the previous body back verbatim, md5 ded16ded3733b1468f0becb58dc1feaf, and the
-- previous comment. The Planner line can stay: with no not_asked rows from the database it never fires.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path TO '';

DO $guard$
BEGIN
  IF pg_get_functiondef('client.get_intake_compare(bigint)'::regprocedure) NOT LIKE '%''state'', ''not_asked''%' THEN RAISE EXCEPTION 'guard: get_intake_compare is not the 2026-11-05 body'; END IF;
END $guard$;

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
      when 'grease_trap_location'      then to_jsonb(v_p.grease_trap_location)
    end;

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

COMMENT ON FUNCTION client.get_intake_compare(bigint) IS 'What the office accept screen renders. state is blank (accept auto-fills), same (no-op), differs (show both values, a human decides, Fred 2026-09-22) or unanswered. A stored manhole count of 0 reads as BLANK on purpose: 370 of 506 rows are 0 and the column is NOT NULL DEFAULT 0, so zero and unknown are the same value.';

DO $verify$
BEGIN
  IF md5(pg_get_functiondef('client.get_intake_compare(bigint)'::regprocedure)) <> 'ded16ded3733b1468f0becb58dc1feaf' THEN RAISE EXCEPTION 'VERIFY: the body is not the previous one'; END IF;
END $verify$;
COMMIT;
