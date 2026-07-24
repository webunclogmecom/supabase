-- 2026-07-24b  DUMP testing mode: one-tap removal of [TEST]-flagged dumps
--
-- WHY (Fred 2026-07-24): the DUMP app gets a "Testing" screen so Yannick can preview the after-hours /
-- closed warnings + the Slack alerts on demand. Anything created there is tagged [TEST] in the visit's
-- notes (edge fn `create` with test_mode:true), and the Testing screen's "Remove all test visits" button
-- calls the edge `test_cleanup` action, which runs this function.
--
-- SAFETY: this can ONLY touch app-created TEST dumps. Scoping (client_id IN (365,76) AND source='manual'
-- AND notes LIKE '%[TEST]%'), with an honest note about which predicate is load-bearing:
--   * The `[TEST]` notes marker is THE discriminator, and it is trustworthy by construction: it is added
--     ONLY by the edge fn's own test_mode prefix, and any caller-injected `[TEST]` in the free-text
--     eta_snapshot/site_status_note is stripped before the notes are written (see stripTestTag). So a real
--     (non-test) dump never carries the marker and can never be selected here.
--   * `source='manual'` is a secondary guard. ⚠ In the CURRENT build phase (PUSH_TO_JOBBER=false) EVERY
--     app dump — real driver dumps included — is written source='manual', so on its own this predicate does
--     NOT separate real from test; the marker does. It becomes a real second barrier AFTER go-live: a test
--     dump is forced source='manual' (test_mode overrides the Jobber push), while real dumps then ride in
--     as source='visit-calendar'/'jobber' and are excluded here twice over.
--   * client_id IN (365,76) bounds it to the two dump places.
-- Visits are SOFT-deleted (deleted_at, never hard-deleted -- Rule 6); the app-specific children
-- (dump_manifest_handout, dump_activity, plus the visit's line_items / visit_team) are removed so nothing
-- dangles. Returns the count.
--
-- AUDIT: visits + dump_manifest_handout are audited (the soft-delete + handout deletes are captured);
-- dump_activity is the append-only telemetry trail. SECURITY DEFINER, service_role-only (the edge fn).

CREATE OR REPLACE FUNCTION public.dump_test_cleanup()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_ids   bigint[];
  v_count integer;
BEGIN
  SELECT array_agg(id) INTO v_ids
  FROM public.visits
  WHERE client_id IN (365, 76)
    AND source = 'manual'
    AND deleted_at IS NULL
    AND notes LIKE '%[TEST]%';

  IF v_ids IS NULL THEN
    RETURN 0;
  END IF;

  DELETE FROM public.dump_manifest_handout WHERE dump_visit_id = ANY (v_ids) OR visit_id = ANY (v_ids);
  DELETE FROM public.dump_activity          WHERE dump_visit_id = ANY (v_ids);
  DELETE FROM public.visit_team             WHERE visit_id      = ANY (v_ids);
  DELETE FROM public.line_items             WHERE visit_id      = ANY (v_ids);

  UPDATE public.visits SET deleted_at = now() WHERE id = ANY (v_ids) AND deleted_at IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

REVOKE ALL     ON FUNCTION public.dump_test_cleanup() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.dump_test_cleanup() TO service_role;
