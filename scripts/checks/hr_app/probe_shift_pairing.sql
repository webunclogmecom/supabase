-- Probes for the shift pairing and "an approved shift is paid" (2026-10-21, Trello ZEYkT63t). Everything is undone: the
-- block ends by RAISE-ing its results. Run with scripts/checks/hr_app/run.js probe_shift_pairing.sql. Checks 1-3 pin real
-- history that must never change; the others pick live fixtures in the last 28 days.
DO $p$
DECLARE
  r jsonb := '[]'::jsonb; j jsonb; c_admin text; v_today date := (now() at time zone 'America/New_York')::date;
  v_ok boolean; v_po_e bigint; v_po_d date; v_po_pre boolean; v_pi_e bigint; v_pi_d date; v_rate numeric; v_sum numeric; v_note text;
BEGIN
  c_admin := json_build_object('sub',coalesce((select u.id::text from auth.users u where lower(u.email) = lower((select email from public.employees where id = 2))), '00000000-0000-0000-0000-000000000001'),'email',(select email from public.employees where id = 2),'role','authenticated')::text;

  -- 1-3. real shifts that must keep their pairing
  r := r || jsonb_build_object('t','1 a night shift pairs its 9 PM PRE with the next morning''s POST','ok',
        EXISTS (SELECT 1 FROM public.v_inspection_shifts WHERE employee_id = 40 AND shift_date = date '2026-10-14' AND pre_inspection_id = 537 AND post_inspection_id = 538 AND kind = 'pair'));
  r := r || jsonb_build_object('t','2 a morning POST with no PRE belongs to the night before','ok',
        EXISTS (SELECT 1 FROM public.v_inspection_shifts WHERE employee_id = 40 AND shift_date = date '2026-10-15' AND post_inspection_id = 541 AND pre_inspection_id IS NULL AND kind = 'post_only'));
  r := r || jsonb_build_object('t','3 a day shift pairs on the same day','ok',
        EXISTS (SELECT 1 FROM public.v_inspection_shifts WHERE employee_id = 35 AND shift_date = date '2026-10-15' AND pre_inspection_id = 539 AND post_inspection_id = 540));
  -- 4. one shift per person per date since September, every form in exactly one shift
  r := r || jsonb_build_object('t','4 no two shifts share a person and a date since Sep 1','ok',
        NOT EXISTS (SELECT 1 FROM public.v_inspection_shifts WHERE shift_date >= date '2026-09-01' GROUP BY employee_id, shift_date HAVING count(*) > 1)
        AND NOT EXISTS (SELECT 1 FROM hr.v_bonus_drift WHERE problem = 'shift_pairing_collision'));

  -- fixtures: an undecided one-form shift, an undecided paired shift whose form reports an issue
  SELECT s.employee_id, s.shift_date, s.pre_inspection_id IS NOT NULL INTO v_po_e, v_po_d, v_po_pre FROM public.v_inspection_shifts s
   WHERE s.kind <> 'pair' AND s.shift_date >= v_today - 28 AND s.shift_date <= v_today
     AND NOT EXISTS (SELECT 1 FROM public.shift_reviews sr WHERE sr.employee_id = s.employee_id AND sr.shift_date = s.shift_date)
     AND NOT EXISTS (SELECT 1 FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = s.employee_id AND g.work_date = s.shift_date)
     AND coalesce((SELECT x.amount FROM hr.fn_rate_on(s.employee_id, 'per_shift_bonus', s.shift_date) x), 0) > 0
   ORDER BY s.shift_date DESC LIMIT 1;
  SELECT s.employee_id, s.shift_date INTO v_pi_e, v_pi_d FROM public.v_inspection_shifts s
   WHERE s.kind = 'pair' AND s.has_issue AND s.shift_date >= v_today - 28 AND s.shift_date <= v_today
     AND NOT EXISTS (SELECT 1 FROM public.shift_reviews sr WHERE sr.employee_id = s.employee_id AND sr.shift_date = s.shift_date)
     AND NOT EXISTS (SELECT 1 FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = s.employee_id AND g.work_date = s.shift_date)
   ORDER BY s.shift_date DESC LIMIT 1;
  r := r || jsonb_build_object('t','0 fixtures found','ok', v_po_e IS NOT NULL, 'one_form', v_po_e || '|' || v_po_d, 'issue_pair', v_pi_e || '|' || v_pi_d);

  PERFORM set_config('request.jwt.claims', c_admin, true);
  -- 5. a one-form shift: it can carry a custom amount, has a link, and an approval is paid with a note
  r := r || jsonb_build_object('t','5 a one-form shift opens from the HR App','ok',
        hr.fn_admin_review_url('shift_bonus', null, v_po_e, v_po_d) = 'https://admin.unclogme.app/review-shift/shift-' || v_po_e || '-' || to_char(v_po_d, 'YYYY-MM-DD'));
  v_ok := true; BEGIN PERFORM hr.set_shift_bonus(v_po_e, v_po_d, 31, 'probe'); EXCEPTION WHEN others THEN v_ok := false; END;
  r := r || jsonb_build_object('t','5b a one-form shift takes a custom amount','ok', v_ok);
  INSERT INTO public.shift_reviews (employee_id, shift_date, review_status, bonus_status, bonus_decided_at) VALUES (v_po_e, v_po_d, 'approved', 'approved', now());
  SELECT sum(g.amount), max(g.note) INTO v_sum, v_note FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = v_po_e AND g.work_date = v_po_d;
  r := r || jsonb_build_object('t','6 an approved one-form shift is paid, the note names the missing form','ok', v_sum = 31
        AND v_note LIKE '%' || CASE WHEN v_po_pre THEN 'without the end-of-shift (POST) form.' ELSE 'without the start-of-shift (PRE) form.' END || '%', 'sum', v_sum, 'note', v_note);
  -- 7. a paired shift whose form reports an issue: pending counts it, an approval pays it
  IF v_pi_e IS NOT NULL THEN
    v_rate := coalesce((SELECT x.amount FROM hr.fn_shift_rate_on(v_pi_e, v_pi_d) x), 0);
    j := hr.get_employee_record(v_pi_e);
    r := r || jsonb_build_object('t','7 an undecided shift with an issue is pending at its amount','ok',
          EXISTS (SELECT 1 FROM jsonb_array_elements(j->'history') h WHERE h->>'type' = 'shift_bonus' AND (h->>'date')::date = v_pi_d
                    AND h->>'status' = 'pending' AND (h->>'amount')::numeric = v_rate));
    INSERT INTO public.shift_reviews (employee_id, shift_date, review_status, bonus_status, bonus_decided_at) VALUES (v_pi_e, v_pi_d, 'approved', 'approved', now());
    SELECT sum(g.amount), max(g.note) INTO v_sum, v_note FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = v_pi_e AND g.work_date = v_pi_d;
    r := r || jsonb_build_object('t','7b an approved shift with an issue is paid','ok', v_sum = v_rate AND v_note LIKE '%reports an issue%', 'sum', v_sum);
  ELSE
    r := r || jsonb_build_object('t','7 no undecided issue shift in the last 28 days (skipped)','ok', true);
  END IF;
  -- 8. a review with no form at all records $0
  INSERT INTO public.shift_reviews (employee_id, shift_date, review_status, bonus_status, bonus_decided_at) VALUES (40, date '2019-01-02', 'approved', 'approved', now());
  SELECT sum(g.amount), max(g.rule) INTO v_sum, v_note FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = 40 AND g.work_date = date '2019-01-02';
  r := r || jsonb_build_object('t','8 a shift with no form at all records $0','ok', v_sum = 0 AND v_note = 'forms_issue');
  -- 9. the repair of Michael's reviews
  r := r || jsonb_build_object('t','9 the two orphan denials are gone and Oct 5 is paid','ok',
        NOT EXISTS (SELECT 1 FROM public.shift_reviews WHERE employee_id = 40 AND shift_date IN (date '2026-10-03', date '2026-10-20'))
        AND (SELECT sum(amount) FROM hr.bonus_events WHERE kind = 'shift_bonus' AND employee_id = 40 AND work_date = date '2026-10-05')
            = (SELECT x.amount FROM hr.fn_shift_rate_on(40, date '2026-10-05') x));
  -- 10. the sweep writes nothing; privileges
  j := hr.fn_sync_all_bonuses('sweep');
  r := r || jsonb_build_object('t','10 the sweep writes nothing','ok', (j->>'shift_rows')::int = 0, 'v', j);
  r := r || jsonb_build_object('t','11 staff read the shifts, anon does not, nobody writes','ok',
        has_table_privilege('authenticated', 'public.v_inspection_shifts', 'SELECT')
        AND NOT has_table_privilege('anon', 'public.v_inspection_shifts', 'SELECT')
        AND NOT has_table_privilege('authenticated', 'public.v_inspection_shifts', 'INSERT'));
  PERFORM set_config('request.jwt.claims', '', true);
  RAISE EXCEPTION 'PROBE_RESULT %', r;
END $p$;
