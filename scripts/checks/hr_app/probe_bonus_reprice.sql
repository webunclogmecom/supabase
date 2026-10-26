-- Probes for "an amount change can update approved bonuses since its start date" (2026-10-21, Fred). Everything is undone:
-- the block ends by RAISE-ing its results. Since 2026-10-21 ("since" replaces later amounts) the window is every date
-- from the start date on. Run with scripts/checks/hr_app/run.js probe_bonus_reprice.sql.
-- Expected counts are computed here independently of hr.fn_bonus_reprice_rows, so the probe checks the rule, not itself.
DO $p$
DECLARE
  r jsonb := '[]'::jsonb; j jsonb; c_admin text; c_office text; v_today date := (now() at time zone 'America/New_York')::date;
  v_ok boolean; v_e bigint; v_d date; v_nxt date; v_r0 numeric; v_new numeric; v_vx bigint; v_exp int; v_snap jsonb; v_after jsonb;
  v_ds date; v_sr0 numeric; v_sexp int; v_fi jsonb; v_rate bigint;
BEGIN
  c_admin := json_build_object('sub',(select u.id::text from auth.users u where lower(u.email) = lower((select email from public.employees where id = 2))),'email',(select email from public.employees where id = 2),'role','authenticated')::text;
  c_office := json_build_object('sub',(select u.id::text from auth.users u where lower(u.email) = lower((select email from public.employees where id = (select e.id from public.employees e join auth.users u on lower(u.email) = lower(e.email) where e.status = 'ACTIVE' and e.access_level = 'office' and u.email_confirmed_at is not null and u.banned_until is null and not exists (select 1 from hr.access_overrides o where o.employee_id = e.id) order by e.id limit 1)))),'email',(select email from public.employees where id = (select e.id from public.employees e join auth.users u on lower(u.email) = lower(e.email) where e.status = 'ACTIVE' and e.access_level = 'office' and u.email_confirmed_at is not null and u.banned_until is null and not exists (select 1 from hr.access_overrides o where o.employee_id = e.id) order by e.id limit 1)),'role','authenticated')::text;
  -- The office fixture must NOT hold Pay rates and bonus settings: that is the premise of every 'office cannot ...'
  -- check. Office defaults can change (Fred set Office hr_pay = yes on 2026-10-23), so pin it here; the run's
  -- ROLLBACK undoes it.
  INSERT INTO hr.access_overrides (employee_id, app, level, set_by_email) SELECT e.id, 'hr_pay', 'no', 'probe' FROM public.employees e WHERE lower(e.email) = lower(c_office::jsonb->>'email');

  -- fixture: the person with the most open approved visit bonuses; window = from their earliest one to their next later amount
  SELECT g.employee_id INTO v_e FROM hr.bonus_events g
   WHERE g.kind = 'visit_bonus' AND g.rule = 'approved' AND g.reverses_id IS NULL AND NOT EXISTS (SELECT 1 FROM hr.bonus_events x WHERE x.reverses_id = g.id)
   GROUP BY g.employee_id ORDER BY count(*) DESC, g.employee_id LIMIT 1;
  SELECT min(g.work_date) INTO v_d FROM hr.bonus_events g
   WHERE g.employee_id = v_e AND g.kind = 'visit_bonus' AND g.rule = 'approved' AND g.reverses_id IS NULL AND NOT EXISTS (SELECT 1 FROM hr.bonus_events x WHERE x.reverses_id = g.id);
  v_nxt := (SELECT min(p.effective_from) FROM hr.pay_rates p WHERE p.employee_id = v_e AND p.kind = 'per_visit_bonus' AND p.effective_from > v_d);
  v_r0 := coalesce((SELECT x.amount FROM hr.fn_rate_on(v_e, 'per_visit_bonus', v_d) x), 0);
  v_new := v_r0 + 5;
  -- one visit in the window gets its own custom amount first: it must keep it
  SELECT g.visit_id INTO v_vx FROM hr.bonus_events g JOIN public.visit_team t ON t.visit_id = g.visit_id AND t.employee_id = g.employee_id
   WHERE g.employee_id = v_e AND g.kind = 'visit_bonus' AND g.rule = 'approved' AND g.reverses_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM hr.bonus_events x WHERE x.reverses_id = g.id) AND g.work_date >= v_d
   ORDER BY g.work_date DESC LIMIT 1;
  r := r || jsonb_build_object('t','0 fixtures found','ok', v_e IS NOT NULL AND v_vx IS NOT NULL, 'person', v_e, 'from', v_d, 'next', v_nxt, 'r0', v_r0, 'custom_visit', v_vx);

  -- 1. office without Pay rates and bonus settings cannot preview
  PERFORM set_config('request.jwt.claims', c_office, true);
  v_ok := false; BEGIN PERFORM hr.preview_person_bonus(v_e, 'per_visit_bonus', v_new, v_d); EXCEPTION WHEN others THEN v_ok := SQLSTATE = '42501'; END;
  r := r || jsonb_build_object('t','1 office cannot preview','ok', v_ok);

  PERFORM set_config('request.jwt.claims', c_admin, true);
  PERFORM hr.set_visit_bonus(v_vx, v_e, 33, 'probe custom');
  v_exp := (SELECT count(*) FROM hr.bonus_events g
             WHERE g.employee_id = v_e AND g.kind = 'visit_bonus' AND g.rule = 'approved' AND g.reverses_id IS NULL
               AND NOT EXISTS (SELECT 1 FROM hr.bonus_events x WHERE x.reverses_id = g.id)
               AND g.work_date >= v_d AND g.amount <> v_new
               -- every visit with its own live custom amount keeps it (v_vx, and real ones: Fred set 7866 on 2026-10-23)
               AND NOT coalesce((SELECT o.amount IS NOT NULL FROM hr.visit_bonus_overrides o
                                  WHERE o.visit_id = g.visit_id AND o.employee_id = g.employee_id ORDER BY o.id DESC LIMIT 1), false));
  -- 2. the preview counts exactly those
  j := hr.preview_person_bonus(v_e, 'per_visit_bonus', v_new, v_d);
  r := r || jsonb_build_object('t','2 preview counts the approved visits that would change','ok', (j->>'approved_count')::int = v_exp AND v_exp > 0 AND j->>'unit' = 'visit', 'v', j, 'expected', v_exp);
  r := r || jsonb_build_object('t','2b an unfinished form previews 0, no error','ok', (hr.preview_person_bonus(v_e, 'per_visit_bonus', null, v_d)->>'approved_count')::int = 0);

  SELECT jsonb_agg(jsonb_build_object('id', g.id, 'a', g.amount) ORDER BY g.id) INTO v_snap FROM hr.bonus_events g
   WHERE g.employee_id = v_e AND g.reverses_id IS NULL AND NOT EXISTS (SELECT 1 FROM hr.bonus_events x WHERE x.reverses_id = g.id);
  -- 3. without the box: approved bonuses keep their amounts
  j := hr.set_person_bonus(v_e, 'per_visit_bonus', v_new, v_d, 'probe', false);
  SELECT jsonb_agg(jsonb_build_object('id', g.id, 'a', g.amount) ORDER BY g.id) INTO v_after FROM hr.bonus_events g
   WHERE g.employee_id = v_e AND g.reverses_id IS NULL AND NOT EXISTS (SELECT 1 FROM hr.bonus_events x WHERE x.reverses_id = g.id);
  r := r || jsonb_build_object('t','3 unticked: approved bonuses keep their amount','ok', (j->>'updated_approved')::int = 0 AND v_after = v_snap);
  -- 4. same amount and date again, box ticked: applied (the amount was set already, the approved bonuses were not)
  j := hr.set_person_bonus(v_e, 'per_visit_bonus', v_new, v_d, 'probe apply', true);
  v_rate := (SELECT max(id) FROM hr.pay_rates WHERE employee_id = v_e AND kind = 'per_visit_bonus');
  r := r || jsonb_build_object('t','4 ticked: every approved visit in the window moves to the new amount','ok',
        NOT (j->>'noop')::boolean AND (j->>'updated_approved')::int = v_exp
        AND NOT EXISTS (SELECT 1 FROM hr.bonus_events g WHERE g.employee_id = v_e AND g.kind = 'visit_bonus' AND g.rule = 'approved'
                          AND g.reverses_id IS NULL AND NOT EXISTS (SELECT 1 FROM hr.bonus_events x WHERE x.reverses_id = g.id)
                          AND g.work_date >= v_d AND g.amount <> v_new
                          AND NOT coalesce((SELECT o.amount IS NOT NULL FROM hr.visit_bonus_overrides o
                                             WHERE o.visit_id = g.visit_id AND o.employee_id = g.employee_id ORDER BY o.id DESC LIMIT 1), false))
        AND (SELECT count(*) FROM hr.bonus_events g WHERE g.reprice_rate_id = v_rate AND g.reverses_id IS NULL AND g.filled_by = 'rate_change'
               AND g.note LIKE 'Amount changed to % from % by %: probe apply') = v_exp, 'v', j);
  r := r || jsonb_build_object('t','4b the visit with its own custom amount keeps it','ok',
        (SELECT g.amount FROM hr.bonus_events g WHERE g.visit_id = v_vx AND g.employee_id = v_e AND g.reverses_id IS NULL
           AND NOT EXISTS (SELECT 1 FROM hr.bonus_events x WHERE x.reverses_id = g.id)) = 33);
  -- 2026-10-21 (Fred: "make since replace later amounts too"): the later dated amount is replaced, for pending and approved
  r := r || jsonb_build_object('t','4c later dated amounts are replaced','ok', v_nxt IS NULL OR (
        (SELECT x.amount FROM hr.fn_rate_on(v_e, 'per_visit_bonus', v_nxt) x) = v_new
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(hr.get_person_bonus_amounts(array[v_e])->(v_e::text)->'per_visit_bonus') a
                         WHERE (a->>'effective_from')::date > v_d)
        AND EXISTS (SELECT 1 FROM jsonb_array_elements(hr.get_employee_record(v_e)->'activity') a, jsonb_array_elements(a->'changes') c
                     WHERE c->>'field' = 'Replaces later amounts')), 'next', v_nxt);
  r := r || jsonb_build_object('t','4d nothing left to change: preview 0','ok', (hr.preview_person_bonus(v_e, 'per_visit_bonus', v_new, v_d)->>'approved_count')::int = 0);
  -- 5. Activity says how many
  j := hr.get_employee_record(v_e);
  r := r || jsonb_build_object('t','5 Activity: Approved bonuses updated','ok', EXISTS (SELECT 1 FROM jsonb_array_elements(j->'activity') a, jsonb_array_elements(a->'changes') c
        WHERE a->>'operation' = 'RATE' AND c->>'field' = 'Approved bonuses updated' AND c->>'new' LIKE v_exp || ' visit% changed to the new amount'));
  -- 6. the hourly sweep moves nothing back
  j := hr.fn_sync_all_bonuses('sweep');
  r := r || jsonb_build_object('t','6 the sweep writes nothing','ok', (j->>'visit_rows')::int = 0 AND (j->>'shift_rows')::int = 0, 'v', j);
  -- 7. the health email: one "repriced" item, no late take-back for these reversals
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM public.log_hr_bonus_health();
  j := (SELECT s.details->'items' FROM public.sync_log s WHERE s.sync_source = 'hr-bonus-health' ORDER BY s.id DESC LIMIT 1);
  r := r || jsonb_build_object('t','7 health: one net item, no take-back items for it','ok',
        EXISTS (SELECT 1 FROM jsonb_array_elements(j) i WHERE i->>'kind' = 'hr_bonus:repriced:' || v_rate)
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j) i JOIN hr.bonus_events b ON i->>'kind' = 'hr_bonus:late_take_back:' || b.id WHERE b.reprice_rate_id = v_rate),
        'item', (SELECT i FROM jsonb_array_elements(j) i WHERE i->>'kind' = 'hr_bonus:repriced:' || v_rate));
  PERFORM set_config('request.jwt.claims', c_admin, true);

  -- 8. shift bonuses: same rule; a $0 forms-issue shift stays $0
  SELECT min(g.work_date) INTO v_ds FROM hr.bonus_events g WHERE g.employee_id = v_e AND g.kind = 'shift_bonus' AND g.rule = 'approved'
     AND g.reverses_id IS NULL AND NOT EXISTS (SELECT 1 FROM hr.bonus_events x WHERE x.reverses_id = g.id);
  IF v_ds IS NULL THEN
    r := r || jsonb_build_object('t','8 shift bonuses (no approved shift for this person, skipped)','ok', true);
  ELSE
    v_sr0 := coalesce((SELECT x.amount FROM hr.fn_rate_on(v_e, 'per_shift_bonus', v_ds) x), 0) + 3;
    v_nxt := (SELECT min(p.effective_from) FROM hr.pay_rates p WHERE p.employee_id = v_e AND p.kind = 'per_shift_bonus' AND p.effective_from > v_ds);
    v_sexp := (SELECT count(*) FROM hr.bonus_events g WHERE g.employee_id = v_e AND g.kind = 'shift_bonus' AND g.rule = 'approved' AND g.reverses_id IS NULL
                 AND NOT EXISTS (SELECT 1 FROM hr.bonus_events x WHERE x.reverses_id = g.id) AND g.work_date >= v_ds AND g.amount <> v_sr0);
    SELECT jsonb_agg(g.id ORDER BY g.id) INTO v_fi FROM hr.bonus_events g WHERE g.employee_id = v_e AND g.kind = 'shift_bonus' AND g.rule = 'forms_issue'
       AND g.reverses_id IS NULL AND NOT EXISTS (SELECT 1 FROM hr.bonus_events x WHERE x.reverses_id = g.id);
    j := hr.set_person_bonus(v_e, 'per_shift_bonus', v_sr0, v_ds, 'probe shift', true);
    r := r || jsonb_build_object('t','8 shift bonuses move the same way; forms-issue shifts stay','ok', (j->>'updated_approved')::int = v_sexp
          AND v_fi IS NOT DISTINCT FROM (SELECT jsonb_agg(g.id ORDER BY g.id) FROM hr.bonus_events g WHERE g.employee_id = v_e AND g.kind = 'shift_bonus' AND g.rule = 'forms_issue'
                                           AND g.reverses_id IS NULL AND NOT EXISTS (SELECT 1 FROM hr.bonus_events x WHERE x.reverses_id = g.id)), 'v', j, 'expected', v_sexp);
  END IF;
  -- 9. the HR App's current call (five named arguments) still works
  j := hr.set_person_bonus(p_employee_id => v_e, p_kind => 'per_visit_bonus', p_amount => v_new + 1, p_effective_from => v_today + 1, p_reason => 'probe 5 args');
  r := r || jsonb_build_object('t','9 the call without the new argument still works','ok', NOT (j->>'noop')::boolean AND (j->>'updated_approved')::int = 0);
  -- 10. app roles: the rule is not callable, the two RPCs are
  r := r || jsonb_build_object('t','10 privileges','ok', NOT has_function_privilege('authenticated', 'hr.fn_bonus_reprice_rows(bigint,text,numeric,date)', 'EXECUTE')
        AND has_function_privilege('authenticated', 'hr.preview_person_bonus(bigint,text,numeric,date)', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'hr.set_person_bonus(bigint,text,numeric,date,text,boolean)', 'EXECUTE'));
  PERFORM set_config('request.jwt.claims', '', true);
  RAISE EXCEPTION 'PROBE_RESULT %', r;
END $p$;
