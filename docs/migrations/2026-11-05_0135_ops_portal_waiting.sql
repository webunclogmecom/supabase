-- =============================================================================
-- 2026-11-05_0135_ops_portal_waiting.sql
--
-- WHAT: ops.portal_waiting(), the numbers behind the Ops Portal header's bell: how many things are waiting, only for
--       the apps the signed-in person can open.
--
-- WHY: Fred, 2026-11-05: "we should have like a global header, where we can put notifactions". He then picked one bar
--      on the mockup. Mockup: https://claude.ai/artifact/KW6w5fKBtpXXv1N3FRX98w
--      Spec and record: Building Apps/Ops Portal/docs/08-changelog.md.
--
-- WHAT IT READS: the same checks the 11 AM Slack reminders already use, so the bell and Slack cannot disagree:
--   call_first       ops.visit_requests where open and call_required (the queue, Calendar To Be Scheduled)
--   time_on_site     public.fn_time_on_site_gaps(yesterday ET)          -> visits
--   photos_unsorted  public.fn_admin_review_pending()                   -> photos.count
--   city_emails      public.fn_admin_review_pending()                   -> city
--   stamp_sheets     derm.fn_stamp_open_sheets()
--   unopened_emails  public.fn_unopened_emails(now())                   -> emails
--
-- 🛑 NOT ops.fn_call_first_run: it marks requests as announced. This function writes nothing (STABLE).
--
-- ACCESS: SECURITY DEFINER because those four functions are closed to authenticated (measured: execute false). It
--   returns counts only, never a client or a row. A key is present only when the app is open to the person, by the
--   same rule as the portal's tileVisible: an app is closed when its mode is on and its level is neither view nor
--   edit. Someone who is not staff gets {}. The rule lives in shell/access.ts too; the app also hides what it cannot
--   open, but this function is what keeps the number from reaching them.
-- COST: the four checks took 563 ms together on Prod (2026-11-05 01:20 ET). The portal polls every 5 minutes.
--
-- RULE 8, AUDIT: no table written, so no audit trigger applies.
-- ATOMIC: one transaction. The VERIFY block raises on any failure and rolls the whole thing back.
-- ROLLBACK: 2026-11-05_0135_ops_portal_waiting_rollback.sql
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION ops.portal_waiting()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_access jsonb := hr.get_my_access();
  v_closed text[];
  v_out jsonb := '{}'::jsonb;
  v_admin jsonb;
BEGIN
  IF v_access IS NULL OR v_access->>'employee_id' IS NULL THEN
    RETURN v_out;
  END IF;

  SELECT coalesce(array_agg(a->>'app'), '{}'::text[]) INTO v_closed
    FROM jsonb_array_elements(coalesce(v_access->'apps', '[]'::jsonb)) a
   WHERE a->>'mode' = 'on' AND coalesce(a->>'level', 'none') NOT IN ('view', 'edit');

  IF NOT 'visit_calendar' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object(
      'call_first', (SELECT count(*) FROM ops.visit_requests r
                      WHERE r.deleted_at IS NULL AND r.status = 'open' AND r.call_required),
      'time_on_site', jsonb_array_length(coalesce(
        public.fn_time_on_site_gaps(((now() AT TIME ZONE 'America/New_York')::date - 1))->'visits', '[]'::jsonb)));
  END IF;

  IF NOT 'admin_review' = ANY (v_closed) THEN
    v_admin := public.fn_admin_review_pending();
    v_out := v_out || jsonb_build_object(
      'photos_unsorted', coalesce((v_admin->'photos'->>'count')::int, 0),
      'city_emails', jsonb_array_length(coalesce(v_admin->'city', '[]'::jsonb)));
  END IF;

  IF NOT 'stamp_studio' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('stamp_sheets', jsonb_array_length(coalesce(derm.fn_stamp_open_sheets(), '[]'::jsonb)));
  END IF;

  IF NOT 'derm_tracker' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('unopened_emails', jsonb_array_length(coalesce(public.fn_unopened_emails(now())->'emails', '[]'::jsonb)));
  END IF;

  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION ops.portal_waiting() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.portal_waiting() TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

DO $verify$
DECLARE
  v_fred jsonb; v_stranger jsonb; v_closed_app jsonb; v_uid uuid; v_keys text[];
  v_direct bigint;
BEGIN
  -- Grants: closed to anon by name, open to authenticated (controls that can each fail).
  IF has_function_privilege('anon', 'ops.portal_waiting()', 'execute') THEN RAISE EXCEPTION 'verify_fail: anon can execute'; END IF;
  IF NOT has_function_privilege('authenticated', 'ops.portal_waiting()', 'execute') THEN RAISE EXCEPTION 'verify_fail: authenticated cannot execute'; END IF;

  -- An admin who opens everything sees all six keys, and the count matches a direct read (positive control).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_fred := ops.portal_waiting();
  RESET ROLE;
  SELECT array_agg(k ORDER BY k) INTO v_keys FROM jsonb_object_keys(v_fred) k;
  IF v_keys IS DISTINCT FROM ARRAY['call_first','city_emails','photos_unsorted','stamp_sheets','time_on_site','unopened_emails'] THEN
    RAISE EXCEPTION 'verify_fail: admin keys %', v_keys;
  END IF;
  SELECT count(*) INTO v_direct FROM ops.visit_requests r WHERE r.deleted_at IS NULL AND r.status = 'open' AND r.call_required;
  IF (v_fred->>'call_first')::bigint <> v_direct THEN RAISE EXCEPTION 'verify_fail: call_first % vs %', v_fred->>'call_first', v_direct; END IF;

  -- Someone who is not staff gets nothing.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-000000000999', 'email', 'nobody@example.com', 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_stranger := ops.portal_waiting();
  RESET ROLE;
  IF v_stranger <> '{}'::jsonb THEN RAISE EXCEPTION 'verify_fail: a stranger sees %', v_stranger; END IF;

  -- An active field person with a sign-in, who by the group defaults does not open the Calendar, sees no Calendar number.
  SELECT u.id INTO v_uid FROM public.employees e JOIN auth.users u ON lower(u.email) = lower(e.email)
   WHERE e.status = 'ACTIVE' AND e.access_level = 'field' ORDER BY e.id LIMIT 1;
  IF v_uid IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', (SELECT email FROM auth.users WHERE id = v_uid), 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    v_closed_app := ops.portal_waiting();
    RESET ROLE;
    IF v_closed_app ? 'call_first' OR v_closed_app ? 'unopened_emails' THEN RAISE EXCEPTION 'verify_fail: field sees %', v_closed_app; END IF;
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'verify ok: admin %, field keys %', v_fred, (SELECT count(*) FROM jsonb_object_keys(coalesce(v_closed_app, '{}'::jsonb)));
END $verify$;

COMMIT;
