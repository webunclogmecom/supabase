-- 2026-08-24_1750_drop_superseded_gdo_report_key.sql
--
-- WHAT: remove the superseded singular `gdo_report` key from customer.get_work_order.
--       The per-permit `gdo_reports` ARRAY replaces it.
--
-- WHY (Fred, 2026-08-24): "drop the old gdo_report key". It was introduced as a COMPAT SHIM in
--      `2026-08-24_1730_customer_gdo_reports_per_permit.sql` and kept in 1740, scoped `LIMIT 1`,
--      purely so the deployed Field Portal could not break in the window between the view becoming
--      multi-row and the app shipping. Both of those have happened, so the shim has done its job.
--
-- ⚠ WHY THE SHIM EXISTED AT ALL, because deleting it looks trivial and was not:
--      once customer.gdo_reports returned one row PER PERMIT, the original scalar subquery
--      (`select jsonb_build_object(...) from ... join customer.gdo_reports g on g.visit_id = v.id`)
--      raises **21000 "more than one row returned by a subquery"** on every multi-permit visit. The
--      live customer report reads this function on every page load, so removing the key in the same
--      migration that changed the grain would have 500'd the report for real customers.
--
-- ✅ VERIFIED SAFE BEFORE DROPPING, against the LIVE served bundle:
--      `gdo_reports` (array)   : 1  -> the app reads the array
--      `gdo_report` (singular) : 1  -> **and this is NOT a read of the key.**
--      That single occurrence is `kind:"gdo_report"` in the body of a get-derm-doc call:
--        functions.invoke("get-derm-doc",{body:{manifest_id,client_code,kind:"gdo_report",gdo_id}})
--      i.e. the DOCUMENT KIND, an unrelated string that merely shares the name. A naive count of the
--      substring says "still read" and would have blocked this drop indefinitely.
--      ⇒ Count the USAGE, not the mention. Same trap as `resetPasswordForEmail` being present in
--        every bundle because supabase-js DEFINES it.
--
-- ⚠ RESIDUAL RISK, ACCEPTED BY FRED WHEN ASKED: a browser holding a CACHED older bundle still reads
--      the key and will render an empty GDO block until it reloads. Nothing is lost and no error is
--      thrown - the section simply does not draw. I recommended waiting a day for caches to roll
--      over; he chose to drop now.
--
-- ⚠ NOTHING ELSE CHANGES. customer.gdo_reports is untouched. The array keys, including manifest_id,
--      stay exactly as 1740 left them.
--
-- ⚠ NAMING: ET is 15:00, but 1730/1740 are already taken and the numeric part functions as an
--      ORDERING LABEL in this repo. 1750 sorts after everything applied so far, which is what matters.

BEGIN;

SET LOCAL search_path = public;

CREATE OR REPLACE FUNCTION customer.get_work_order(p_work_order_id text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'customer', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'work_order', to_jsonb(w),
    'permits', (
      select coalesce(jsonb_agg(to_jsonb(p) order by p.position), '[]'::jsonb)
        from customer.permits p where p.client_id = w.client_id),
    'inspection_items', (
      select coalesce(jsonb_agg(to_jsonb(i) order by i.position), '[]'::jsonb)
        from customer.inspection_items i where i.work_order_id = w.id),
    'recommendations', (
      select coalesce(jsonb_agg(to_jsonb(r) order by r.position), '[]'::jsonb)
        from customer.recommendations r where r.work_order_id = w.id),
    'photos', (
      select coalesce(jsonb_agg(to_jsonb(ph) order by ph.position), '[]'::jsonb)
        from customer.wo_photos ph where ph.work_order_id = w.id),
    -- Online Report (GDO filing proof), ONE ENTRY PER PERMIT.
    -- Explicit key list: never to_jsonb(g). screenshot_path must never reach the customer; the image
    -- is fetched through get-derm-doc, which authorises on manifest_id + client_code (+ gdo_id).
    -- manifest_id is NULL on a permit with no filing - the app must not offer a document link then.
    'gdo_reports', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'gdo_id',           g.gdo_id,
               'gdo_number',       g.gdo_number,
               'manifest_id',      g.manifest_id,
               'reported',         g.reported,
               'reported_at',      g.reported_at,
               'confirmation',     g.confirmation,
               'status',           g.status,
               'has_report_image', g.has_report_image) order by g.gdo_number), '[]'::jsonb)
        from public.visits v
        join customer.gdo_reports g on g.visit_id = v.id
       where v.public_id = w.id and v.deleted_at is null)
  )
  from customer.work_orders w
  where w.id = p_work_order_id;
$function$;

COMMIT;
