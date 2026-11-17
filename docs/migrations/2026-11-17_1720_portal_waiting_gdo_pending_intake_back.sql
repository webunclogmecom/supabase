-- =============================================================================
-- 2026-11-17_1720_portal_waiting_gdo_pending_intake_back.sql
--
-- WHAT: ops.portal_waiting() gains two keys, the two menu counts Fred picked that need a number from the database:
--   gdo_pending  "GDO reports pending", on DERM visits (DERM Tracker gate, like unopened_emails and manifests_need_someone)
--   intake_back  "Intake form back", on Site files (Picture Planner + approver gate, exactly site_files' gate)
--
-- WHY: Fred, on the Ops Portal menu (Trello #161, round B of Yan's review): the menu's counts follow what we notify in
--   Slack #apps-notifications. GDO pending = the reports the GDO Online Report bot could not file, as its 08:00 "Daily
--   digest" lists them ("Nothing pending" on a good day). Intake back = a returned site survey (the "Intake form back"
--   post by intake-slack-post), "counted until its Site file version is approved".
--
-- HOW: copied from the LIVE body (md5 14253eb27f0899428a86e4f72b8d6d02, the 2026-11-16_1915 body, guarded below). One
--   anchored edit: a block INSERTED before the last RETURN. No existing line changed (gen script asserts every old line
--   survives in order). New body md5 ca179953815003a3770d6d53a6213b46.
--   gdo_pending is the bot's own predicate (bot repo f7fc2d0, db.attention_sql: status ERROR*, last 30 days, no later
--   SUCCESS on the same permit + manifest; a no-permit row settled by a later SUCCESS on the same visit + manifest; one
--   per pair), read from the results the bot posts to us (public.derm_portal_submissions), not from its SQLite ledger,
--   which we cannot read. Replayed at 08:00 ET of every day 10-30..11-17 against the digests in #apps-notifications:
--   the same pairs, the same attempt counts, every day (10-30: 12656/839776 + no GDO/834433; 11-03: 2; 11-04..11-10: 3;
--   11-11: 2; 11-12: 1; 10-31..11-02 and 11-13..11-17: Nothing pending).
--   Where it can differ from the digest, by design or by blindness:
--     - a filing recorded by hand in the DERM Tracker is SUCCESS here and clears the count; the bot never hears of it,
--       so its digest keeps the pair up to 30 days (0 cases in the window);
--     - a bot result that never reached us (a dry-run error, a bot-dashboard hand entry, a result still in the bot's
--       retry cache) is invisible here; "Mark handled" acks (retired 2026-11-10) are invisible here.
--   intake_back: property_intakes submitted, not cancelled, property not removed, test clients out (fn_is_non_customer,
--   as site_files), and no APPROVED property_pages version made (submitted_at) after the form's submitted_at. One per
--   form, as the Slack post is one per form.
--
-- ACCESS: unchanged. SECURITY DEFINER, empty search_path, EXECUTE authenticated + service_role (CREATE OR REPLACE keeps
--   the grants; the VERIFY reads them back). Counts only.
-- RULE 8, AUDIT: no table written.
-- LOCK: a function replace; nothing reads it under a long lock. lock_timeout 3s.
-- REHEARSED: rolled back on Prod 2026-11-17, with the old body as the control (the same VERIFY fails on it: no new keys),
--   the rollback rehearsed after it, and both md5 guards proven to refuse the wrong body.
-- VERIFY (in this file): grants; both numbers equal a second formulation; the admin's answer has both keys and every
--   other key byte-identical to the old body's answer taken in this transaction before the replace; a Field person with
--   no app open gets neither key.
-- ATOMIC: one transaction. The guard and the VERIFY raise on any failure and roll the whole thing back.
-- ROLLBACK: 2026-11-17_1720_portal_waiting_gdo_pending_intake_back_rollback.sql
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('ops.portal_waiting()'::regprocedure)) <> '14253eb27f0899428a86e4f72b8d6d02' THEN
    RAISE EXCEPTION 'guard: ops.portal_waiting() is not the live 2026-11-16_1915 body (md5 %). Read it again before changing it.',
      md5(pg_get_functiondef('ops.portal_waiting()'::regprocedure));
  END IF;
END $guard$;

-- The bell's answer BEFORE the change, as the first active admin with a confirmed sign-in, kept for the VERIFY (every
-- key but the two new ones must come back identical).
DO $before$
DECLARE v_uid uuid; v_email text; v jsonb;
BEGIN
  SELECT u.id, u.email INTO v_uid, v_email
    FROM public.employees e JOIN auth.users u ON lower(btrim(u.email)) = lower(btrim(e.email))
   WHERE e.status = 'ACTIVE' AND e.access_level = 'admin' AND u.email_confirmed_at IS NOT NULL
   ORDER BY e.id LIMIT 1;
  IF v_uid IS NULL THEN RAISE EXCEPTION 'verify_fail: no active admin with a confirmed sign-in'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v := ops.portal_waiting();
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('portal_waiting.before', v::text, true);
END $before$;

CREATE OR REPLACE FUNCTION ops.portal_waiting()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
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

  -- 2026-11-09_1230: Site file versions waiting for approval, only for someone who can approve them (Picture Planner open,
  -- and "Approve site files" by the one approver rule, public.fn_page_approver_ids()). The same versions the
  -- #apps-notifications post announces (public.fn_slack_event_claim, version_waiting): neither approved nor rejected, on a
  -- real client (test clients left out the same way), on a property not removed, and above the property's live version,
  -- because a version below the live one can no longer be decided (Picture Planner rules 20 and 27).
  IF NOT 'picture_planner' = ANY (v_closed) AND auth.uid() = ANY (public.fn_page_approver_ids()) THEN
    v_out := v_out || jsonb_build_object('site_files', (
      SELECT count(*)
        FROM public.property_pages pg
        JOIN public.properties p ON p.id = pg.property_id
       WHERE pg.approved_at IS NULL AND pg.rejected_at IS NULL AND p.deleted_at IS NULL
         AND pg.version > coalesce((SELECT max(l.version) FROM public.property_pages l
                                     WHERE l.property_id = pg.property_id AND l.approved_at IS NOT NULL), 0)
         AND NOT coalesce(public.fn_is_non_customer(p.client_id, array['test', 'fixture']), false)));
  END IF;

  -- 2026-11-16 (Trello #210, Fred's default "bell"): the Ops Portal's Home lists "Needs you" from this same answer, so the
  -- bell and the Home can never disagree. Four counts added, each behind the app that holds its list:
  --   late_today, requests_open (Visit Calendar): today's visits past their job's due date (late_status 'late', the
  --     Calendar's red mark; ops.portal_home's "late" is the same predicate), and every open visit request (call_first
  --     stays: the Home shows it as the detail of this line);
  --   reviews_pending (Admin Review): the review queue's rule (completed, in scope, dated today or before, pending);
  --   manifests_need_someone (DERM Tracker): the Manifests list's "Needs someone" rows, read from the one core
  --     (derm.fn_manifest_row_states_core): a test row never counts, a row counts when any place is amber or red.
  IF NOT 'visit_calendar' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object(
      'late_today', (SELECT count(*) FROM ops.v_calendar_visit v
                      WHERE v.visit_date = (now() AT TIME ZONE 'America/New_York')::date
                        AND v.visit_status <> 'cancelled' AND v.late_status = 'late'),
      'requests_open', (SELECT count(*) FROM ops.visit_requests r WHERE r.deleted_at IS NULL AND r.status = 'open'));
  END IF;

  IF NOT 'admin_review' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('reviews_pending', (
      SELECT count(*) FROM public.visits_with_review w
       WHERE w.visit_status = 'completed' AND w.in_review_scope
         AND w.visit_date <= (now() AT TIME ZONE 'America/New_York')::date AND w.review_status = 'pending'));
  END IF;

  IF NOT 'derm_tracker' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('manifests_need_someone', (
      SELECT count(*) FROM jsonb_each(derm.fn_manifest_row_states_core()) e
       WHERE NOT coalesce((e.value->>'test')::boolean, false)
         AND EXISTS (SELECT 1 FROM unnest(ARRAY['papers', 'stamps', 'copies', 'city', 'visit', 'email']) p(place)
                      WHERE e.value->p.place->>'s' IN ('warn', 'bad'))));
  END IF;

  -- 2026-11-17_1720 (Trello #161, Fred: the menu's counts follow what #apps-notifications posts). Two counts:
  --   gdo_pending (DERM Tracker, the same gate as the other DERM keys): the GDO Online Report bot's "pending" list, as its
  --     08:00 Daily digest prints it, rebuilt from the results the bot posts to us (rpa-derm-result writes
  --     public.derm_portal_submissions). The bot's own rule (its db.attention_sql): a live ERROR attempt in the last 30 days
  --     with no SUCCESS on the same permit and manifest after it; an attempt with no permit is settled by a later SUCCESS
  --     on the same visit and manifest. One per (permit, manifest), as the digest lists them. A filing recorded by hand
  --     in the DERM Tracker counts as filed here; the bot never hears of it, so its digest would keep listing it.
  --   intake_back (Picture Planner, the same gate as site_files; the "Intake form back" post tags these approvers): a
  --     returned site survey (submitted, not cancelled, real client, property not removed), counted until a Site file
  --     version made after the form came back is approved (Fred: "counted until its Site file version is approved").
  IF NOT 'derm_tracker' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('gdo_pending', (
      SELECT count(DISTINCT (e.gdo_id, e.manifest_id))
        FROM public.derm_portal_submissions e
       WHERE e.status LIKE 'ERROR%' AND NOT e.dry_run
         AND e.attempted_at >= now() - interval '30 days'
         AND NOT EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                          WHERE s.manifest_id = e.manifest_id AND NOT s.dry_run
                            AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL)
                            AND s.attempted_at > e.attempted_at
                            AND (s.gdo_id = e.gdo_id OR (e.gdo_id IS NULL AND s.visit_id = e.visit_id)))));
  END IF;

  IF NOT 'picture_planner' = ANY (v_closed) AND auth.uid() = ANY (public.fn_page_approver_ids()) THEN
    v_out := v_out || jsonb_build_object('intake_back', (
      SELECT count(*)
        FROM public.property_intakes i
        JOIN public.properties p ON p.id = i.property_id
       WHERE i.submitted_at IS NOT NULL AND i.cancelled_at IS NULL AND p.deleted_at IS NULL
         AND NOT coalesce(public.fn_is_non_customer(p.client_id, array['test', 'fixture']), false)
         AND NOT EXISTS (SELECT 1 FROM public.property_pages pg
                          WHERE pg.property_id = i.property_id AND pg.approved_at IS NOT NULL
                            AND pg.submitted_at > i.submitted_at)));
  END IF;

  RETURN v_out;
END;
$function$;

NOTIFY pgrst, 'reload schema';

DO $verify$
DECLARE
  v_uid uuid; v_email text; v_before jsonb := current_setting('portal_waiting.before')::jsonb;
  v_admin jsonb; v_field jsonb; v_gdo bigint; v_intake bigint; v_t0 timestamptz; v_ms numeric;
BEGIN
  IF md5(pg_get_functiondef('ops.portal_waiting()'::regprocedure)) <> 'ca179953815003a3770d6d53a6213b46' THEN
    RAISE EXCEPTION 'verify_fail: not the new body (md5 %)', md5(pg_get_functiondef('ops.portal_waiting()'::regprocedure));
  END IF;
  IF has_function_privilege('anon', 'ops.portal_waiting()', 'execute')
     OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = 'ops.portal_waiting()'::regprocedure AND a.grantee = 0)
     OR NOT has_function_privilege('authenticated', 'ops.portal_waiting()', 'execute')
     OR NOT has_function_privilege('service_role', 'ops.portal_waiting()', 'execute') THEN
    RAISE EXCEPTION 'verify_fail: grants moved';
  END IF;

  -- The two numbers, worked out a second way.
  --   gdo_pending: per (permit, manifest), the newest live error in 30 days is after the newest SUCCESS on that pair.
  SELECT count(*) INTO v_gdo FROM (
    SELECT e.gdo_id, e.manifest_id
      FROM public.derm_portal_submissions e
      LEFT JOIN LATERAL (SELECT max(s.attempted_at) AS ok_at FROM public.derm_portal_submissions s
                          WHERE s.manifest_id = e.manifest_id AND NOT s.dry_run
                            AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL)
                            AND (s.gdo_id = e.gdo_id OR (e.gdo_id IS NULL AND s.visit_id = e.visit_id))) ok ON true
     WHERE e.status LIKE 'ERROR%' AND NOT e.dry_run AND e.attempted_at >= now() - interval '30 days'
     GROUP BY 1, 2
    HAVING max(e.attempted_at) > coalesce(max(ok.ok_at), '-infinity')) x;
  --   intake_back: the form came back after the property's newest APPROVED Site file version was made, or there is none.
  SELECT count(*) INTO v_intake
    FROM public.property_intakes i
    JOIN public.properties p ON p.id = i.property_id
    LEFT JOIN (SELECT property_id, max(submitted_at) AS made FROM public.property_pages
                WHERE approved_at IS NOT NULL GROUP BY 1) a ON a.property_id = i.property_id
   WHERE i.submitted_at IS NOT NULL AND i.cancelled_at IS NULL AND p.deleted_at IS NULL
     AND NOT coalesce(public.fn_is_non_customer(p.client_id, array['test', 'fixture']), false)
     AND (a.made IS NULL OR a.made <= i.submitted_at);

  -- The admin (an approver): both new keys with those numbers, and every other key exactly as before.
  SELECT u.id, u.email INTO v_uid, v_email
    FROM public.employees e JOIN auth.users u ON lower(btrim(u.email)) = lower(btrim(e.email))
   WHERE e.status = 'ACTIVE' AND e.access_level = 'admin' AND u.email_confirmed_at IS NOT NULL
   ORDER BY e.id LIMIT 1;
  IF v_uid IS NULL THEN RAISE EXCEPTION 'verify_fail: no active admin with a confirmed sign-in'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_t0 := clock_timestamp(); v_admin := ops.portal_waiting(); v_ms := round(extract(epoch FROM clock_timestamp() - v_t0) * 1000);
  RESET ROLE;
  IF v_before ?| ARRAY['gdo_pending', 'intake_back'] THEN RAISE EXCEPTION 'verify_fail: the old answer already had a new key'; END IF;
  IF NOT (v_admin ?& ARRAY['gdo_pending', 'intake_back']) THEN
    RAISE EXCEPTION 'verify_fail: admin keys %', (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_admin) k);
  END IF;
  IF (v_admin - 'gdo_pending' - 'intake_back') IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'verify_fail: another key moved: before % after %', v_before, v_admin;
  END IF;
  IF (v_admin->>'gdo_pending')::bigint IS DISTINCT FROM v_gdo THEN RAISE EXCEPTION 'verify_fail: gdo_pending % vs %', v_admin->>'gdo_pending', v_gdo; END IF;
  IF (v_admin->>'intake_back')::bigint IS DISTINCT FROM v_intake THEN RAISE EXCEPTION 'verify_fail: intake_back % vs %', v_admin->>'intake_back', v_intake; END IF;

  -- A Field person with no app open and a working sign-in gets neither.
  SELECT u.id, u.email INTO v_uid, v_email
    FROM public.employees e JOIN auth.users u ON lower(u.email) = lower(e.email)
   WHERE e.status = 'ACTIVE' AND e.access_level = 'field'
     AND u.email_confirmed_at IS NOT NULL AND (u.banned_until IS NULL OR u.banned_until <= now())
     AND NOT EXISTS (SELECT 1 FROM hr.fn_effective_access(e.id) f WHERE f.parent IS NULL AND f.level IN ('view', 'edit'))
   ORDER BY e.id LIMIT 1;
  IF v_uid IS NULL THEN RAISE EXCEPTION 'verify_fail: no field person with no app open to test with'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_field := ops.portal_waiting();
  RESET ROLE;
  IF v_field ?| ARRAY['gdo_pending', 'intake_back'] THEN RAISE EXCEPTION 'verify_fail: a Field person gets a new count %', v_field; END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('verify.summary', format('admin %s; gdo_pending %s, intake_back %s (second way %s, %s); field %s; %s ms',
    v_admin, v_admin->>'gdo_pending', v_admin->>'intake_back', v_gdo, v_intake, v_field, v_ms), true);
  RAISE NOTICE 'verify ok: %', current_setting('verify.summary');
END $verify$;

COMMIT;
