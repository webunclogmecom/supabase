-- ============================================================================
-- ROLLBACK of 2026-10-29_1500_admin_review_list_grouped_by_area.sql
-- ============================================================================
-- Puts public.fn_admin_review_pending back to its body from before 2026-10-29_1330 (no `area` column; md5
-- 0c87852b...). fn_notification_health_items is left as it is (1500 put it back to that same pre-1330 body).
-- The edge function admin-review-reminder falls back to `city` when `area` is missing, so the post then groups by
-- city (Hallandale Beach, Surfside) instead of "Broward" and Surfside.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pre$
BEGIN
  IF pg_get_functiondef('public.fn_admin_review_pending'::regproc) NOT LIKE '%AS area,%' THEN
    RAISE EXCEPTION 'fn_admin_review_pending is not the 2026-10-29_1500 body; nothing to roll back';
  END IF;
END $pre$;

CREATE OR REPLACE FUNCTION public.fn_admin_review_pending()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH today AS (SELECT (now() AT TIME ZONE 'America/New_York')::date AS d),
  pend AS (
    -- completed since the city email went live (2026-09-15 09:07 ET), read from public.v_visit_city_email_state, the
    -- one per-visit answer (2026-10-12_1305). needs_city_email = DERM-required (NULL counts as required), not grey
    -- water, the city has an email on file, dated 2026-09-15 or later (older visits read before_go_live), a live
    -- manifest is linked, and nothing carrying the manifest has gone yet (Admin Review with the manifest, the DERM
    -- Tracker "Send to city", or the automatic sweep). The date line below repeats before_go_live on purpose, so no
    -- later change to the view can put a pre-go-live visit on the post. Not listed:
    -- waiting_manifest (no manifest linked yet, held: Diego, 2026-10-12, "kc is waiting manifest so off course I can
    -- not sent it") and report_sent_manifest_follows (Admin Review sent the report without the manifest; the sweep
    -- sends the manifest). A visit held too long is a health-check item (log_notification_health), not a post line.
    SELECT st.visit_id, c.client_code, c.name AS client_name, st.regulator_municipality AS city,
           st.visit_date, e.full_name AS driver,
           coalesce(pc.total_images, 0) AS photos_total, coalesce(pc.classified_images, 0) AS photos_sorted
    FROM public.v_visit_city_email_state st
    JOIN public.visits v ON v.id = st.visit_id
    JOIN public.clients c ON c.id = st.client_id
    LEFT JOIN public.v_visit_photo_counts pc ON pc.visit_id = st.visit_id
    LEFT JOIN public.employees e ON e.id = v.assigned_driver_id
    WHERE st.state = 'needs_city_email'
      AND st.visit_date >= DATE '2026-09-15'
      AND NOT public.fn_is_non_customer(st.client_id, ARRAY['test', 'fixture'])
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

DO $verify$
BEGIN
  IF md5(pg_get_functiondef('public.fn_admin_review_pending'::regproc)) <> '0c87852b0765f00ed76ff970c2a0b5ba' THEN
    RAISE EXCEPTION 'rollback: fn_admin_review_pending is not the pre-1330 body';
  END IF;
END $verify$;

COMMIT;
