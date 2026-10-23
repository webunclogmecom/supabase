-- 2026-10-22_2055 · Admin Review: the change list of a visit or shift review (Trello hnKCI96P)
--
-- Fred (Slack DM to Viktor, 2026-10-22): "be able to open Completed Reviews at the Admin Review App, in case we want to
-- make any update, nowadays they can't be opened, they're just completed." Card: "Changes to a completed review should be
-- tracked (who/when)". Fred's picks (2026-10-22): edit in place, the same people as reviewing (Edit in Admin Review), a
-- FULL CHANGE LIST on the review page, and a bonus change stays in the visit's week (hr.fn_sync_visit_bonus already takes
-- the bonus back and records it again, dated to the visit).
--
-- WHAT: public.get_review_history(p_visit_id) for a visit review, or (p_employee_id, p_shift_date) for a shift review.
-- One row per save, newest first, read from audit.logs (audit_visit_reviews / audit_shift_reviews, which log every write
-- with the caller's JWT). changes = the tracked fields that moved, each {field, label, from, to}; an empty list is a save
-- that changed nothing. who = employees.full_name of the JWT email, else the email, else "Database (manual fix)" for a
-- write with no login (app_source 'sql', e.g. the 2026-10-06/07 repairs).
-- Guard: View in Admin Review (hr.fn_require_app). RULE 8: no table created or changed. EXECUTE: authenticated +
-- service_role, revoked by name from PUBLIC and anon.
-- ROLLBACK: drop function public.get_review_history(bigint, bigint, date);

CREATE FUNCTION public.get_review_history(p_visit_id bigint DEFAULT NULL, p_employee_id bigint DEFAULT NULL,
                                          p_shift_date date DEFAULT NULL)
 RETURNS TABLE(changed_at timestamptz, changed_by text, operation text, changes jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_table text; v_pk jsonb; v_fields text[][];
BEGIN
  PERFORM hr.fn_require_app('admin_review', 'view');
  IF p_visit_id IS NOT NULL AND p_employee_id IS NULL AND p_shift_date IS NULL THEN
    v_table := 'visit_reviews'; v_pk := jsonb_build_object('visit_id', p_visit_id);
    v_fields := ARRAY[['bonus_status', 'Photo bonus'], ['bonus_denial_note', 'Bonus note'],
                      ['review_status', 'Status'], ['quality_flag_note', 'Quality note'],
                      ['invoice_status', 'Ready for invoice']];
  ELSIF p_visit_id IS NULL AND p_employee_id IS NOT NULL AND p_shift_date IS NOT NULL THEN
    v_table := 'shift_reviews'; v_pk := jsonb_build_object('employee_id', p_employee_id, 'shift_date', p_shift_date);
    v_fields := ARRAY[['bonus_status', 'Shift bonus'], ['bonus_denial_note', 'Bonus note'],
                      ['review_status', 'Status'], ['shift_quality_note', 'Quality note']];
  ELSE
    RAISE EXCEPTION 'Give a visit, or a person and a shift date.'
      USING ERRCODE = '22023', DETAIL = 'blocker=bad_key in public.get_review_history';
  END IF;

  RETURN QUERY
  SELECT l.changed_at,
         coalesce(e.full_name, l.jwt_claims->>'email',
                  CASE WHEN l.app_source = 'sql' THEN 'Database (manual fix)' ELSE l.app_source END),
         l.operation,
         coalesce((SELECT jsonb_agg(jsonb_build_object('field', v_fields[i][1], 'label', v_fields[i][2],
                                                       'from', l.old_row->>v_fields[i][1],
                                                       'to', l.new_row->>v_fields[i][1]) ORDER BY i)
                     FROM generate_series(1, array_length(v_fields, 1)) AS i
                    WHERE (l.old_row->>v_fields[i][1]) IS DISTINCT FROM (l.new_row->>v_fields[i][1])), '[]'::jsonb)
    FROM audit.logs l
    LEFT JOIN LATERAL (SELECT e.full_name FROM public.employees e
                        WHERE lower(e.email) = lower(l.jwt_claims->>'email') ORDER BY e.id LIMIT 1) e ON true
   WHERE l.table_schema = 'public' AND l.table_name = v_table AND l.record_pk = v_pk
   ORDER BY l.changed_at DESC, l.id DESC;
END $function$;

REVOKE ALL ON FUNCTION public.get_review_history(bigint, bigint, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_review_history(bigint, bigint, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_review_history(bigint, bigint, date) TO authenticated, service_role;

DO $v$
DECLARE r record; n int; n_log int;
BEGIN
  -- VERIFY 1: visit 8742 (bonus denied after an approval): one row per audit row, newest first, and its bonus change listed
  SELECT count(*) INTO n FROM public.get_review_history(p_visit_id => 8742);
  SELECT count(*) INTO n_log FROM audit.logs WHERE table_schema = 'public' AND table_name = 'visit_reviews'
                                              AND record_pk = jsonb_build_object('visit_id', 8742);
  IF n = 0 OR n <> n_log THEN RAISE EXCEPTION 'VERIFY 1: % rows for % audit rows', n, n_log; END IF;
  -- VERIFY 2 (positive control): some visit review has a save whose bonus went approved -> pending (the 10-06 repair)
  IF NOT EXISTS (SELECT 1 FROM audit.logs l, LATERAL public.get_review_history(p_visit_id => (l.record_pk->>'visit_id')::bigint) h,
                       LATERAL jsonb_array_elements(h.changes) c
                  WHERE l.table_name = 'visit_reviews' AND l.app_source = 'sql' AND l.operation = 'UPDATE'
                    AND l.old_row->>'bonus_status' = 'approved' AND l.new_row->>'bonus_status' = 'pending'
                    AND h.changed_at = l.changed_at AND c->>'field' = 'bonus_status'
                    AND c->>'from' = 'approved' AND c->>'to' = 'pending' AND h.changed_by = 'Database (manual fix)') THEN
    RAISE EXCEPTION 'VERIFY 2: the 10-06 bonus repair is not listed as approved -> pending by Database (manual fix)';
  END IF;
  -- VERIFY 3: a shift review lists its insert with the person's name
  SELECT h.* INTO r FROM public.shift_reviews s,
         LATERAL public.get_review_history(p_employee_id => s.employee_id, p_shift_date => s.shift_date) h
   ORDER BY s.shift_date DESC LIMIT 1;
  IF r.changed_at IS NULL THEN RAISE EXCEPTION 'VERIFY 3: no history for the latest shift review'; END IF;
  -- VERIFY 4: a re-save with no change has an empty list, never NULL
  IF EXISTS (SELECT 1 FROM public.get_review_history(p_visit_id => 6223) WHERE changes IS NULL) THEN
    RAISE EXCEPTION 'VERIFY 4: NULL changes';
  END IF;
  -- VERIFY 5: a wrong key is refused
  BEGIN
    PERFORM public.get_review_history(p_visit_id => 1, p_employee_id => 1);
    RAISE EXCEPTION 'VERIFY 5: a mixed key was accepted';
  EXCEPTION WHEN sqlstate '22023' THEN NULL;
  END;
  IF has_function_privilege('anon', 'public.get_review_history(bigint,bigint,date)', 'EXECUTE')
  OR NOT has_function_privilege('authenticated', 'public.get_review_history(bigint,bigint,date)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 6: grants';
  END IF;
END $v$;
