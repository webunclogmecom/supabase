-- 2026-08-02_2305  customer.get_work_order: add a `gdo_report` key for the FP "Online Report" section
--
-- Second half of the data path for Fred's "Online Report" section (first half:
-- 2026-08-02_2226 added customer.gdo_reports.has_report_image).
--
-- -- 🛑 WHY THE FIRST MIGRATION ALONE WIRED NOTHING ---------------------------
-- I added the column to customer.gdo_reports assuming the Field Portal reads the customer.* VIEWS.
-- It does not. Measured from the live bundle: the FP builds ONE anon client with
-- `db:{schema:"customer"}` and its entire read surface is TWO SECURITY DEFINER RPCs --
-- `customer.get_client_portal(p_slug)` and `customer.get_work_order(p_work_order_id)`.
-- That is also why all 9 customer.* views are `anon = false, authenticated = true`: they are not
-- what the portal reads. So a column on a view the app never queries is invisible to it.
-- ⚠ Generalisable: verify which LAYER the consumer actually reads before adding to a layer.
-- The grant matrix was sitting there saying "anon cannot read these views" and I read it as an
-- inconsistency to flag rather than as the answer.
--
-- -- SHAPE ---------------------------------------------------------------------
-- `gdo_report` is a sibling key alongside permits / inspection_items / recommendations / photos,
-- matching the established structure. Additive: every existing key keeps its name, type and
-- contents, so the current app ignores the new key until it is taught to render it.
--   filed   -> {reported:true,  reported_at:<ts>, confirmation:'Submitted — DERM portal…', has_report_image:true}
--   unfiled -> {reported:false, reported_at:null, confirmation:null,                        has_report_image:false}
--   a visit that is not GDO-reporting at all -> null (no row in customer.gdo_reports)
--
-- -- ⚠ WHY jsonb_build_object AND NOT to_jsonb(g) -----------------------------
-- My first probe used `to_jsonb(g)` and it leaked **raw bigint `visit_id` and `client_id`**
-- (measured: client_id 10 and 298) into an ANON-reachable payload. The whole customer schema
-- deliberately obfuscates ids -- customer.work_orders.id is the visit's `public_id` and its
-- client_id is `customer.uuid_from_bigint(...)` -- precisely so a portal visitor cannot enumerate
-- sequential internal ids. Splatting the view row would have quietly undone that for two columns.
-- Build the object explicitly and expose ONLY what the card renders.
-- Probed after the fix: `(gdo_report) ?| array['visit_id','client_id']` = **false**.
--
-- The visit join lives INSIDE this SECURITY DEFINER function because customer.work_orders
-- deliberately exposes no visit_id; we map back via `public.visits.public_id = w.id`, and filter
-- `deleted_at IS NULL` so a soft-deleted visit cannot resurface a filing.
--
-- PROBED rolled back before applying: filed (visit 6036 / wo vD3NSI7sQF) and unfiled
-- (visit 1467 / wo snYaSDvoio) both correct; keys = client, gdo_report, inspection_items, permits,
-- photos, recommendations, work_order; photos still an array and work_order still an object.
--
-- ADR 010 rule 8: function only, no table/column change -> no audit-trigger decision.
-- search_path stays '' (everything schema-qualified). SECURITY DEFINER is required: the portal is
-- ANON and holds no grant on customer.gdo_reports (authenticated-only) or public.visits.

BEGIN;

CREATE OR REPLACE FUNCTION customer.get_work_order(p_work_order_id text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'work_order', to_jsonb(w),
    'client', (
      select to_jsonb(c) from customer.clients c where c.id = w.client_id),
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
    -- Online Report (GDO filing proof). Explicit key list: never to_jsonb(g) -- see header.
    'gdo_report', (
      select jsonb_build_object(
               'reported',         g.reported,
               'reported_at',      g.reported_at,
               'confirmation',     g.confirmation,
               'has_report_image', g.has_report_image)
        from public.visits v
        join customer.gdo_reports g on g.visit_id = v.id
       where v.public_id = w.id and v.deleted_at is null)
  )
  from customer.work_orders w
  where w.id = p_work_order_id;
$function$;

COMMIT;
