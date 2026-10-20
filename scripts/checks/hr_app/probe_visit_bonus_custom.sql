-- Probes for the custom visit bonus and the "photos sorted before a bonus" rule (2026-10-20, Trello bZvoo91Z).
-- Everything is undone: the block ends by RAISE-ing its results. Run with scripts/checks/hr_app/run.js probe_visit_bonus_custom.sql.
-- Fixtures are picked live: a pending visit with every photo sorted, a pending visit with photos not sorted, and an
-- approved visit whose photos were not all sorted (approved before the rule).
DO $p$
DECLARE
  r jsonb := '[]'::jsonb; j jsonb; c_admin text; c_office text; v_today date := (now() at time zone 'America/New_York')::date;
  v_ok boolean; v_msg text; v_sorted bigint; v_unsorted bigint; v_old bigint; v_e bigint; v_other bigint; v_normal numeric;
  v_p0 numeric; v_p1 numeric; v_n0 bigint; v_sum numeric; v_open jsonb;
BEGIN
  c_admin := json_build_object('sub',coalesce((select u.id::text from auth.users u where lower(u.email) = lower((select email from public.employees where id = 2))), '00000000-0000-0000-0000-000000000001'),'email',(select email from public.employees where id = 2),'role','authenticated')::text;
  c_office := json_build_object('sub',coalesce((select u.id::text from auth.users u where lower(u.email) = lower((select email from public.employees where id = 42))), '00000000-0000-0000-0000-000000000001'),'email',(select email from public.employees where id = 42),'role','authenticated')::text;

  -- fixtures (one crew member, a real customer, in the review queue, bonus not decided)
  SELECT v.id, min(t.employee_id) INTO v_sorted, v_e
    FROM public.visits_with_review v JOIN public.visit_team t ON t.visit_id = v.id
    JOIN public.v_visit_photo_counts c ON c.visit_id = v.id
   WHERE v.visit_status = 'completed' AND v.in_review_scope AND v.visit_date <= v_today AND coalesce(v.bonus_status, 'pending') = 'pending'
     AND NOT public.fn_is_non_customer(v.client_id) AND c.total_images > 0 AND c.total_images = c.classified_images
     AND (SELECT count(*) FROM public.visit_team t2 WHERE t2.visit_id = v.id) = 1
   GROUP BY v.id ORDER BY v.id DESC LIMIT 1;
  SELECT v.id INTO v_unsorted
    FROM public.visits_with_review v JOIN public.v_visit_photo_counts c ON c.visit_id = v.id
   WHERE v.visit_status = 'completed' AND coalesce(v.bonus_status, 'pending') <> 'approved' AND c.total_images > c.classified_images
   ORDER BY v.id DESC LIMIT 1;
  SELECT vr.visit_id INTO v_old FROM public.visit_reviews vr JOIN public.v_visit_photo_counts c ON c.visit_id = vr.visit_id
   WHERE vr.bonus_status = 'approved' AND c.total_images > c.classified_images ORDER BY vr.visit_id LIMIT 1;
  SELECT e.id INTO v_other FROM public.employees e
   WHERE e.status = 'ACTIVE' AND NOT EXISTS (SELECT 1 FROM public.visit_team t WHERE t.visit_id = v_sorted AND t.employee_id = e.id) LIMIT 1;
  r := r || jsonb_build_object('t','0 fixtures found','ok', v_sorted IS NOT NULL AND v_unsorted IS NOT NULL AND v_old IS NOT NULL AND v_other IS NOT NULL,
        'sorted', v_sorted, 'crew', v_e, 'unsorted', v_unsorted, 'approved_unsorted', v_old);
  v_normal := coalesce((SELECT x.amount FROM hr.fn_rate_on(v_e, 'per_visit_bonus', (SELECT visit_date FROM public.visits WHERE id = v_sorted)) x), 0);

  -- 1. office without "Pay rates and bonus settings" cannot set an amount
  PERFORM set_config('request.jwt.claims', c_office, true);
  v_ok := false; BEGIN PERFORM hr.set_visit_bonus(v_sorted, v_e, 40, 'probe'); EXCEPTION WHEN others THEN v_ok := SQLSTATE = '42501'; END;
  r := r || jsonb_build_object('t','1 office cannot set a custom amount','ok', v_ok);
  r := r || jsonb_build_object('t','1b office is told it cannot','ok', (hr.get_review_bonuses(array[v_sorted], '[]'::jsonb)->>'can_set_amounts')::boolean IS FALSE);

  PERFORM set_config('request.jwt.claims', c_admin, true);
  r := r || jsonb_build_object('t','1c an admin can','ok', (hr.get_review_bonuses(array[v_sorted], '[]'::jsonb)->>'can_set_amounts')::boolean IS TRUE);
  -- 2. only someone on the Calendar crew, only a sane amount
  v_ok := false; BEGIN PERFORM hr.set_visit_bonus(v_sorted, v_other, 40, 'probe'); EXCEPTION WHEN others THEN v_ok := SQLERRM LIKE 'That person is not on this visit%'; END;
  r := r || jsonb_build_object('t','2 a person not on the crew is refused','ok', v_ok);
  v_ok := false; BEGIN PERFORM hr.set_visit_bonus(v_sorted, v_e, 1000.01, null); EXCEPTION WHEN others THEN v_ok := SQLERRM LIKE 'The amount must be%'; END;
  BEGIN PERFORM hr.set_visit_bonus(v_sorted, v_e, 1.234, null); v_ok := false; EXCEPTION WHEN others THEN v_ok := v_ok AND SQLERRM LIKE 'The amount must be%'; END;
  r := r || jsonb_build_object('t','2b out of range or sub-cent amounts are refused','ok', v_ok);

  -- 3. a custom amount on a pending visit: pending total, Admin Review reader, HR history row, Activity
  v_p0 := hr.fn_pending_bonus(v_e, v_today);
  j := hr.set_visit_bonus(v_sorted, v_e, 40, '  probe: hard first visit  ');
  v_p1 := hr.fn_pending_bonus(v_e, v_today);
  r := r || jsonb_build_object('t','3 the pending total moves by the difference','ok', NOT (j->>'noop')::boolean AND v_p1 - v_p0 = 40 - v_normal, 'p0', v_p0, 'p1', v_p1, 'normal', v_normal);
  j := hr.get_review_bonuses(array[v_sorted], '[]'::jsonb)->'visits'->(v_sorted::text)->'custom'->(v_e::text);
  r := r || jsonb_build_object('t','3b Admin Review reads the custom amount, who and why','ok',
        (j->>'amount')::numeric = 40 AND j->>'reason' = 'probe: hard first visit' AND j->>'set_by' IS NOT NULL, 'v', j);
  j := hr.get_employee_record(v_e);
  r := r || jsonb_build_object('t','3c the HR history pending row is $40 with the note','ok',
        EXISTS (SELECT 1 FROM jsonb_array_elements(j->'history') h WHERE (h->>'id')::bigint = -v_sorted AND (h->>'amount')::numeric = 40
                   AND h->>'note' LIKE 'Custom amount for this visit, set by %: probe: hard first visit'));
  r := r || jsonb_build_object('t','3d the person''s Activity says who changed it','ok',
        EXISTS (SELECT 1 FROM jsonb_array_elements(j->'activity') a WHERE a->>'operation' = 'RATE' AND a->>'app' = 'Admin Review'
                   AND a->'changes'->0->>'new' = '$40.00 for this visit' AND a->'changes'->0->>'old' = 'Normal amount'
                   AND a->'changes'->1->>'new' = 'probe: hard first visit' AND a->>'by' IS NOT NULL));
  -- 4. the same amount again writes nothing
  v_n0 := (SELECT count(*) FROM hr.visit_bonus_overrides);
  j := hr.set_visit_bonus(v_sorted, v_e, 40, 'again');
  r := r || jsonb_build_object('t','4 the same amount is a no-op','ok', (j->>'noop')::boolean AND (SELECT count(*) FROM hr.visit_bonus_overrides) = v_n0);

  -- 5. approving the bonus records $40 for that person
  INSERT INTO public.visit_reviews (visit_id, review_status, bonus_status, bonus_decided_at, invoice_status)
  VALUES (v_sorted, 'approved', 'approved', now(), 'pending')
  ON CONFLICT (visit_id) DO UPDATE SET bonus_status = 'approved', bonus_decided_at = now(), review_status = 'approved';
  SELECT jsonb_agg(jsonb_build_object('amount', g.amount, 'note', g.note, 'override', g.override_id IS NOT NULL)) INTO v_open
    FROM hr.bonus_events g WHERE g.kind = 'visit_bonus' AND g.visit_id = v_sorted AND g.reverses_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM hr.bonus_events x WHERE x.reverses_id = g.id);
  r := r || jsonb_build_object('t','5 the approved bonus is recorded at the custom amount','ok',
        jsonb_array_length(v_open) = 1 AND (v_open->0->>'amount')::numeric = 40 AND (v_open->0->>'override')::boolean, 'v', v_open);
  -- 6. changing it after it is recorded: taken back and recorded again
  PERFORM hr.set_visit_bonus(v_sorted, v_e, 25, 'probe change');
  SELECT sum(g.amount) INTO v_sum FROM hr.bonus_events g WHERE g.kind = 'visit_bonus' AND g.visit_id = v_sorted;
  r := r || jsonb_build_object('t','6 a change after recording nets to the new amount','ok', v_sum = 25
        AND (SELECT count(*) FROM hr.bonus_events g WHERE g.visit_id = v_sorted AND g.rule = 'reversal' AND g.note = 'Replaced by the custom amount set for this visit.') = 1, 'sum', v_sum);
  -- 7. back to the normal amount
  PERFORM hr.set_visit_bonus(v_sorted, v_e, null, null);
  SELECT sum(g.amount) INTO v_sum FROM hr.bonus_events g WHERE g.kind = 'visit_bonus' AND g.visit_id = v_sorted;
  r := r || jsonb_build_object('t','7 removing it records the normal amount','ok', v_sum = v_normal
        AND (hr.get_review_bonuses(array[v_sorted], '[]'::jsonb)->'visits'->(v_sorted::text)->'custom') = 'null'::jsonb, 'sum', v_sum);
  -- 8. the hourly sweep re-prices nothing (no recorded bonus moves on its own)
  j := hr.fn_sync_all_bonuses('sweep');
  r := r || jsonb_build_object('t','8 the sweep writes nothing','ok', (j->>'visit_rows')::int = 0, 'v', j);

  -- 9. the photos rule: approving with photos not sorted is refused (upsert and plain update)
  v_ok := false;
  BEGIN
    INSERT INTO public.visit_reviews (visit_id, review_status, bonus_status, bonus_decided_at, invoice_status)
    VALUES (v_unsorted, 'approved', 'approved', now(), 'pending')
    ON CONFLICT (visit_id) DO UPDATE SET bonus_status = 'approved', bonus_decided_at = now();
  EXCEPTION WHEN others THEN v_ok := SQLSTATE = '23514' AND SQLERRM LIKE 'Sort every photo of this visit before approving the bonus (% still not sorted). Nothing was saved.';
  END;
  r := r || jsonb_build_object('t','9 approving with photos not sorted is refused','ok', v_ok);
  INSERT INTO public.visit_reviews (visit_id, review_status, bonus_status, invoice_status) VALUES (v_unsorted, 'pending', 'denied', 'pending')
  ON CONFLICT (visit_id) DO UPDATE SET bonus_status = 'denied';
  r := r || jsonb_build_object('t','9b rejecting with photos not sorted still works','ok', (SELECT bonus_status FROM public.visit_reviews WHERE visit_id = v_unsorted) = 'denied');
  v_ok := false;
  BEGIN UPDATE public.visit_reviews SET bonus_status = 'approved' WHERE visit_id = v_unsorted;
  EXCEPTION WHEN others THEN v_ok := SQLSTATE = '23514'; END;
  r := r || jsonb_build_object('t','9c a plain update to approved is refused too','ok', v_ok);
  -- 10. a bonus approved before the rule stays approved and saves again (the upsert the app sends)
  INSERT INTO public.visit_reviews (visit_id, review_status, bonus_status, bonus_decided_at, invoice_status)
  VALUES (v_old, 'approved', 'approved', now(), 'ready')
  ON CONFLICT (visit_id) DO UPDATE SET invoice_status = 'ready', bonus_status = 'approved';
  r := r || jsonb_build_object('t','10 an approved bonus with unsorted photos saves again','ok', (SELECT invoice_status FROM public.visit_reviews WHERE visit_id = v_old) = 'ready');

  -- 11. the change log is append-only
  v_ok := false; BEGIN UPDATE hr.visit_bonus_overrides SET amount = 1; EXCEPTION WHEN others THEN v_ok := SQLERRM LIKE 'blocker=append_only%'; END;
  r := r || jsonb_build_object('t','11 custom amounts cannot be edited in place','ok', v_ok);
  -- 12. the app roles cannot read the table or the helper
  r := r || jsonb_build_object('t','12 app roles reach it only through the functions','ok',
        NOT has_table_privilege('authenticated', 'hr.visit_bonus_overrides', 'SELECT')
        AND NOT has_function_privilege('authenticated', 'hr.fn_visit_rate_on(bigint,bigint,date)', 'EXECUTE')
        AND has_function_privilege('authenticated', 'hr.set_visit_bonus(bigint,bigint,numeric,text)', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'hr.set_visit_bonus(bigint,bigint,numeric,text)', 'EXECUTE'));
  PERFORM set_config('request.jwt.claims', '', true);
  RAISE EXCEPTION 'PROBE_RESULT %', r;
END $p$;
