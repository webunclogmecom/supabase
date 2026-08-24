-- 2026-08-24_1740_customer_gdo_reports_expose_manifest_id.sql
--
-- WHAT: expose `manifest_id` on customer.gdo_reports and in the get_work_order `gdo_reports` array.
--
-- WHY: consolidating the two evidence endpoints into ONE. `get-derm-doc` has served a `gdo_report`
--      KIND since 2026-08-02 and is keyed on **manifest_id + client_code**; `fp-gdo-evidence` (built
--      earlier today, before I found the older one) is keyed on **public_id + gdo_id**. The Field
--      Portal is moving to `get-derm-doc`, so each permit row must carry the `manifest_id` that
--      endpoint authorises against. Without it the app has a permit and no way to name the document.
--
-- ⚠ WHY `get-derm-doc` WINS AND MINE IS RETIRED, recorded so nobody reverses it later:
--      it has an ORIGIN ALLOWLIST, a real entitlement model (the manifest's own client OR a linked
--      non-deleted visit's client, resolved case-insensitively), a staff-session gate on
--      `kind='address'`, and the documented LIVE-SUCCESS-ONLY filter. `fp-gdo-evidence` had only the
--      slug check. One door, and it is the hardened one.
--
-- 🛑 THE LIVE-SUCCESS FILTER IS A SECURITY CONTROL, NOT TIDINESS (from get-derm-doc's own header,
--      verified there by opening one of each on 2026-08-02):
--        LIVE `<visit>/<run_id>.jpg` -> the county's bare "Report Submitted" page. No client data.
--        DRY  `<visit>/dryrun.jpg`   -> the full preview FORM: facility name, address, phone.
--      Dry-run paths are a FIXED filename per visit and therefore trivially guessable. Never relax
--      that filter to `status <> 'ERROR%'`.
--      ⇒ This also RETIRES the assumption Fred and I agreed to skip earlier today: somebody had
--        already opened both kinds, and LIVE SUCCESS images carry no other facility's data.
--
-- ⚠ APPEND-ONLY. CREATE OR REPLACE VIEW may only add columns at the END, so manifest_id goes last,
--      after the gdo_id / gdo_number / status added at 1730. Do not reorder the earlier ones.
--
-- ⚠ manifest_id is the SUBMISSION's manifest, read from the same row the rest of the fields come
--      from - not a second lookup. On a permit with no filing it is NULL, and the app must not offer
--      a document link in that case.

BEGIN;

SET LOCAL search_path = public;

CREATE OR REPLACE VIEW customer.gdo_reports AS
 SELECT v.id                                    AS visit_id,
        v.client_id,
        v.visit_date,
        (s.id IS NOT NULL)                      AS reported,
        s.created_at                            AS reported_at,
        s.portal_confirmation                   AS confirmation,
        COALESCE(s.status = 'SUCCESS'::text AND s.screenshot_path IS NOT NULL, false)
                                                AS has_report_image,
        g.id                                    AS gdo_id,
        g.gdo_number,
        s.status,
        s.manifest_id
   FROM visits v
   JOIN gdos g
     ON g.client_id = v.client_id
    AND g.status = 'ACTIVE'::text
    AND g.gdo_number ~ '^GDO-[0-9]+$'::text
   LEFT JOIN LATERAL (
        SELECT s1.id, s1.created_at, s1.portal_confirmation, s1.status, s1.screenshot_path,
               s1.manifest_id
          FROM derm_portal_submissions s1
         WHERE s1.visit_id = v.id
           AND NOT s1.dry_run
           AND s1.gdo_id = g.id
           AND (s1.status = 'SUCCESS'::text OR s1.portal_confirmation IS NOT NULL)
         ORDER BY s1.created_at DESC
         LIMIT 1) s ON true
  WHERE v.deleted_at IS NULL
    AND fn_visit_is_gdo_reporting(v.id);

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
    -- Explicit key list: never to_jsonb(g). screenshot_path must never reach the customer;
    -- the image is fetched through get-derm-doc, which authorises on manifest_id + client_code.
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
       where v.public_id = w.id and v.deleted_at is null),
    -- ⚠ SUPERSEDED, KEPT ONLY SO A CACHED APP BUNDLE DOES NOT LOSE THE SECTION. Verified today that
    --   the live Field Portal reads `gdo_reports` and NOT this key (0 occurrences in the served
    --   bundle), so it can be dropped once caches have rolled over. LIMIT 1 is required: without it
    --   this scalar subquery raises 21000 now that the view is multi-row.
    'gdo_report', (
      select jsonb_build_object(
               'reported',         g.reported,
               'reported_at',      g.reported_at,
               'confirmation',     g.confirmation,
               'has_report_image', g.has_report_image)
        from public.visits v
        join customer.gdo_reports g on g.visit_id = v.id
       where v.public_id = w.id and v.deleted_at is null
       order by g.reported desc, g.reported_at desc nulls last, g.gdo_number
       limit 1)
  )
  from customer.work_orders w
  where w.id = p_work_order_id;
$function$;

COMMIT;
