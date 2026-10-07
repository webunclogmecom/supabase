-- ============================================================================
-- 2026-10-07 · Admin Review Slack reminder (photos not sorted, city emails not sent) + every reminder at 11 AM ET
-- ============================================================================
-- THE ASK
--   Serena (Slack, 2026-10-07): Diego forgot "send city email" for Hallandale and Surfside; she wants a reminder
--   when photos are not sorted, or sorted but the city email was not sent. Fred: "send the notifications like we
--   usually do at slack, and then later on i can make Viktor to read those notifications and act depending on
--   them" and "now i want one for Admin Review too, for the visits that are pending Photo sorts and city email
--   send". From a rendered mockup on real data he picked ONE post a day, "11 AM ET, and move all notifications to
--   that same time", and the city list covering "Everything since go-live".
--
-- WHAT CHANGES
--   A. NEW public.fn_admin_review_pending() -> jsonb {city: [...], photos: {count, last_7_days, oldest}}
--      - city: completed visits since 2026-09-15 (the city email went live 09:07 ET that day) whose property's city
--        has an email on file (public.v_visit_city_email.city_email_on_file), not grey water (not_for_city), and
--        with NO real Admin Review send (public.visit_photo_email_sends status 'sent', is_test false). One row per
--        visit: client, city, visit date, driver, photos total / sorted. Test and fixture clients left out.
--        It can only see sends made from Admin Review: a city email sent from someone's own mailbox still lists.
--      - photos: the queue's "Photos Not Sorted" (visits_with_review in_review_scope, completed, dated today or
--        earlier, total_images > classified_images from public.v_visit_photo_counts), test clients left out.
--      STABLE, invoker, service_role only.
--   B. NEW public.fn_request_admin_review_reminder() + cron 'admin-review-reminder' ('0 15,16 * * *'): only the run
--      that is 11 AM in New York goes through, and it makes no HTTP call when both lists are empty (posts nothing).
--      Posts through NEW edge fn admin-review-reminder (same shared bot, #apps-notifications, shown as "Admin Review").
--   C. The Stamp Studio reminder moves from 10 to 11 AM ET: fn_request_stamp_sheets_reminder (live body, md5 pinned,
--      only the hour line changes) and its cron '0 14,15 * * *' -> '0 15,16 * * *'.
--      The DUMP messages fire when a driver taps, so they have no time to move.
--
-- MEASURED AT WRITING (2026-10-07 ~13:00 ET): city 13 (Hallandale Beach 5, Surfside 8; 11 with photos sorted),
--   photos 138 (18 from the last 7 days, oldest Jul 1). Only 2 real Admin Review city sends ever (Sep 15, Oct 5).
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no new table, nothing written.
-- ROLLBACK: SELECT cron.unschedule('admin-review-reminder');
--           DROP FUNCTION public.fn_request_admin_review_reminder(); DROP FUNCTION public.fn_admin_review_pending();
--           re-apply the 10 AM stamp wrapper (md5 3e3a2a08...) and cron.alter_job(.., schedule := '0 14,15 * * *').
-- ============================================================================

BEGIN;

DO $pre$
BEGIN
  IF md5(pg_get_functiondef('public.fn_request_stamp_sheets_reminder()'::regprocedure)) <> '3e3a2a084614d6675682620f9da30a7d' THEN
    RAISE EXCEPTION 'fn_request_stamp_sheets_reminder moved: copy the live body again';
  END IF;
END $pre$;

-- A. what is waiting in Admin Review
CREATE FUNCTION public.fn_admin_review_pending()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH today AS (SELECT (now() AT TIME ZONE 'America/New_York')::date AS d),
  pend AS (
    -- completed since the city email went live (2026-09-15 09:07 ET), the property's city has an email on file, not
    -- grey water, and no real send from Admin Review ("Send email to City", send-visit-photos-email)
    SELECT v.id AS visit_id, c.client_code, c.name AS client_name, ce.regulator_municipality AS city,
           v.visit_date, e.full_name AS driver,
           coalesce(pc.total_images, 0) AS photos_total, coalesce(pc.classified_images, 0) AS photos_sorted
    FROM public.visits v
    JOIN public.clients c ON c.id = v.client_id
    JOIN public.v_visit_city_email ce ON ce.visit_id = v.id
    LEFT JOIN public.v_visit_photo_counts pc ON pc.visit_id = v.id
    LEFT JOIN public.employees e ON e.id = v.assigned_driver_id
    WHERE v.deleted_at IS NULL AND v.visit_status = 'completed'
      AND v.visit_date >= DATE '2026-09-15'
      AND ce.city_email_on_file AND NOT ce.not_for_city
      AND NOT public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture'])
      AND NOT EXISTS (SELECT 1 FROM public.visit_photo_email_sends s
                      WHERE s.visit_id = v.id AND s.status = 'sent' AND NOT coalesce(s.is_test, false))
  ),
  unsorted AS (
    -- the Admin Review queue's "Photos Not Sorted": in the queue, and some photo not classified yet
    SELECT w.id, w.visit_date
    FROM public.visits_with_review w
    JOIN public.v_visit_photo_counts pc ON pc.visit_id = w.id
    WHERE w.visit_status = 'completed' AND w.in_review_scope
      AND w.visit_date <= (SELECT d FROM today)
      AND pc.total_images > pc.classified_images
      AND NOT public.fn_is_non_customer(w.client_id, ARRAY['test', 'fixture'])
  )
  SELECT jsonb_build_object(
    'city', coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.city, p.visit_date, p.client_code) FROM pend p), '[]'::jsonb),
    'photos', jsonb_build_object(
      'count', (SELECT count(*) FROM unsorted),
      'last_7_days', (SELECT count(*) FROM unsorted WHERE visit_date > (SELECT d FROM today) - 7),
      'oldest', (SELECT min(visit_date) FROM unsorted)))
$function$;
REVOKE ALL ON FUNCTION public.fn_admin_review_pending() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_admin_review_pending() TO service_role;

-- B. the cron wrapper: 11 AM New York only, and no call when nothing is waiting
CREATE FUNCTION public.fn_request_admin_review_reminder()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text; v_p jsonb;
begin
  -- 11 AM Eastern whatever the season: the job runs at 15:00 and 16:00 UTC, and only one is 11 AM in New York
  if extract(hour from now() at time zone 'America/New_York') <> 11 then
    return;
  end if;
  v_p := public.fn_admin_review_pending();
  -- nothing waiting: post nothing, and make no call (the Stamp reminder's rule)
  if jsonb_array_length(v_p->'city') = 0 and coalesce((v_p->'photos'->>'count')::int, 0) = 0 then
    return;
  end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping the Admin Review reminder';
    return;
  end if;
  perform net.http_post(
    url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/admin-review-reminder',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000);
end
$function$;
REVOKE ALL ON FUNCTION public.fn_request_admin_review_reminder() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_request_admin_review_reminder() TO service_role;

SELECT cron.schedule('admin-review-reminder', '0 15,16 * * *', 'select public.fn_request_admin_review_reminder()');

-- C. the Stamp Studio reminder moves to 11 AM (body copied from the live definition; only the hour changes)
CREATE OR REPLACE FUNCTION public.fn_request_stamp_sheets_reminder()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text;
begin
  -- 11 AM Eastern whatever the season (Fred, 2026-10-07: every scheduled notification at 11): the job runs at 15:00
  -- and 16:00 UTC, and only one is 11 AM in New York
  if extract(hour from now() at time zone 'America/New_York') <> 11 then
    return;
  end if;
  -- every sheet completed: post nothing (Fred, 2026-10-05), and make no call
  if jsonb_array_length(derm.fn_stamp_open_sheets()) = 0 then
    return;
  end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping the Stamp Studio reminder';
    return;
  end if;
  perform net.http_post(
    url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/stamp-sheets-reminder',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000);
end
$function$;
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'stamp-sheets-reminder'), schedule := '0 15,16 * * *');

DO $verify$
DECLARE p jsonb;
BEGIN
  IF (SELECT schedule FROM cron.job WHERE jobname = 'stamp-sheets-reminder') <> '0 15,16 * * *'
     OR (SELECT schedule FROM cron.job WHERE jobname = 'admin-review-reminder') <> '0 15,16 * * *' THEN
    RAISE EXCEPTION 'cron schedules not at 15,16 UTC'; END IF;
  IF position('<> 11' in pg_get_functiondef('public.fn_request_stamp_sheets_reminder()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'stamp wrapper not at 11'; END IF;
  IF has_function_privilege('authenticated', 'public.fn_admin_review_pending()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.fn_admin_review_pending()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_request_admin_review_reminder()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.fn_request_admin_review_reminder()', 'EXECUTE') THEN
    RAISE EXCEPTION 'an app role can execute a reminder function'; END IF;
  p := public.fn_admin_review_pending();
  IF jsonb_typeof(p->'city') <> 'array' OR (p->'photos'->>'count') IS NULL THEN
    RAISE EXCEPTION 'pending shape wrong: %', p; END IF;
END $verify$;

COMMIT;
