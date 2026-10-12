-- 2026-10-12_1120 fn_admin_review_pending: count DERM Tracker city sends, skip non-DERM visits, hold until a manifest
--
-- Diego replied to Viktor's reminder (Slack, 2026-10-12): "plug in is a unclog", "kc is waiting manifest so off course
-- I can not sent it", "a la carte, I already sent it o october 9". Measured:
--   283-PIK visit 8575: Unclogging service call, derm_required = false; the function never tested derm_required.
--   106-ALC visit 6284 and 093-KC visit 6270: city email SENT 2026-10-09 from the DERM Tracker (derm_email_sends 190,
--     194); the function only counted Admin Review sends (visit_photo_email_sends).
--   093-KC visit 8741 (Oct 8): no manifest linked yet, so no city email can go.
-- Change: three predicates in the pend CTE, the rest of the body copied from pg_get_functiondef unchanged.
-- Rule 8: no table change, no audit opt-in needed. Grants unchanged (CREATE OR REPLACE keeps them).

BEGIN;
CREATE OR REPLACE FUNCTION public.fn_admin_review_pending()
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
      -- 2026-10-12 (Diego, Slack): a DERM Tracker "Send to city" counts too (v_visit_city_email_status), an unclog
      -- or other non-DERM visit is not a city email (derm_required false), and nothing can go before a manifest is linked
      AND NOT EXISTS (SELECT 1 FROM public.v_visit_city_email_status cs
                      WHERE cs.visit_id = v.id AND cs.city_email_sent_count > 0)
      AND v.derm_required IS NOT FALSE
      AND EXISTS (SELECT 1 FROM public.manifest_visits mv
                  JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL
                  WHERE mv.visit_id = v.id)
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
DECLARE r jsonb := public.fn_admin_review_pending(); ids bigint[];
BEGIN
  SELECT array_agg((e->>'visit_id')::bigint) INTO ids FROM jsonb_array_elements(r->'city') e;
  IF ids && ARRAY[8575, 6284, 6270]::bigint[] THEN RAISE EXCEPTION 'still listed: %', ids; END IF;
  IF EXISTS (SELECT 1 FROM unnest(ids) i JOIN public.visits v ON v.id = i WHERE v.derm_required IS FALSE) THEN RAISE EXCEPTION 'non-DERM listed'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(ids) i JOIN public.v_visit_city_email_status cs ON cs.visit_id = i AND cs.city_email_sent_count > 0) THEN RAISE EXCEPTION 'sent visit listed'; END IF;
  IF jsonb_typeof(r->'photos'->'count') <> 'number' THEN RAISE EXCEPTION 'photos part broken'; END IF;
  RAISE NOTICE 'city list now % visits: %', coalesce(array_length(ids,1),0), ids;
END $verify$;

COMMIT;
