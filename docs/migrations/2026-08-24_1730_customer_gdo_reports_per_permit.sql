-- 2026-08-24_1730_customer_gdo_reports_per_permit.sql
--
-- WHAT: make the Field Portal's GDO data PER PERMIT instead of per visit.
--         - customer.gdo_reports        -> one row per (visit, ACTIVE GDO permit), not one per visit
--         - customer.get_work_order     -> emits a NEW `gdo_reports` ARRAY; the old singular
--                                          `gdo_report` key is KEPT so the deployed app cannot break
--
-- WHY (Fred, 2026-08-24, on https://fp.unclogme.app/043-mil/visit/qpUrslVPtH = visit 6617):
--       *"I don't see the evidence of the GDO Online Report ... the evidence should be displayed on
--       the FP App, and also it should be separated by their GDO, so we know."*
--
-- 🛑 THE VIEW COLLAPSED EVERY PERMIT INTO ONE ROW, AND THE CUSTOMER SAW A CONTRADICTION.
--       The old body picked a single submission for the whole visit and ignored `gdo_id` entirely:
--
--           LEFT JOIN LATERAL (SELECT ... FROM derm_portal_submissions s_1
--                               WHERE s_1.visit_id = v.id AND NOT s_1.dry_run
--                                 AND (status='SUCCESS' OR portal_confirmation IS NOT NULL)
--                               ORDER BY created_at DESC LIMIT 1) s ON true
--
--       On visit 6617 that returns GDO-14117's confirmation string, while `reported` is computed
--       across ALL the client's active permits and is therefore FALSE because GDO-11024 never
--       succeeded. So the portal showed **"Submitted - DERM portal confirmed" together with
--       not-reported**, with no hint that two permits exist. Per permit the truth is simple:
--       GDO-14117 filed 08-07, GDO-11024 four failed login attempts.
--       This is the SAME per-visit-vs-per-permit defect fixed in the DERM Tracker card earlier today
--       (`2026-08-24_1215_gdo_correct_report_per_run.sql`), in a second place.
--
-- ⚠ THE OLD `gdo_report` KEY IS DELIBERATELY KEPT AND SCOPED WITH `LIMIT 1`.
--       Once the view returns several rows, the existing scalar subquery inside get_work_order would
--       raise "more than one row returned by a subquery". The deployed Field Portal still reads that
--       key, so removing it would break the live customer report the moment this applies. It is
--       pinned to the newest reported permit and stays until the app has moved to `gdo_reports`.
--       ⇒ Delete it in a LATER migration, after the app ships. Not before.
--
-- ⚠ EVIDENCE IMAGES ARE NOT EXPOSED HERE, ON PURPOSE. `has_report_image` stays a BOOLEAN and no
--       `screenshot_path` is ever returned to the customer. `rpa-evidence` is private and its only
--       SELECT policy is for `authenticated`; the Field Portal runs as ANON. Serving the picture
--       needs a signed URL minted server-side by an edge function that validates the visit slug and
--       derives the path ITSELF. **A path must never be accepted from the client.**
--
-- ⚠ ASSUMPTION RECORDED, AT FRED'S EXPLICIT CALL: the evidence images are single-facility, because
--       a submission row is per (visit, run, gdo_id) and the bot files one permit per run. I offered
--       to open the two images for 6617 first and he chose to proceed on that reasoning. It matters
--       because the DERM *Address sheet* is shared across a dump run and DOES leak other clients,
--       which is why the city receives a blacked-out copy. If a GDO evidence image is ever found to
--       show more than one facility, this exposure must be pulled immediately.
--
-- ⚠ MATCHED STRICTLY ON `s.gdo_id = g.id`. The old body also accepted `s2.gdo_id IS NULL` for legacy
--       rows. Measured before writing this: **11 of 11 live submissions carry a gdo_id**, so the
--       strict join loses nothing and avoids fanning a null-permit row across every permit.
--
-- ⚠ NAMING: ET was 13:55 when this was written, but `2026-08-24_1700_...` already exists, so the
--       numeric part is functioning as an ORDERING LABEL in this repo rather than a wall clock.
--       Named 1730 so it sorts AFTER everything already applied, which is the property that matters.
--
-- AUDIT (ADR 010): views and one function only; no table changes, so no trigger work.

BEGIN;

SET LOCAL search_path = public;

-- ---------------------------------------------------------------------------
-- 1. one row per (visit, ACTIVE permit)
--    CREATE OR REPLACE only permits APPENDING columns, so the original seven keep their
--    position and type and gdo_id / gdo_number / status are added at the end.
-- ---------------------------------------------------------------------------
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
        s.status
   FROM visits v
   JOIN gdos g
     ON g.client_id = v.client_id
    AND g.status = 'ACTIVE'::text
    AND g.gdo_number ~ '^GDO-[0-9]+$'::text
   LEFT JOIN LATERAL (
        SELECT s1.id, s1.created_at, s1.portal_confirmation, s1.status, s1.screenshot_path
          FROM derm_portal_submissions s1
         WHERE s1.visit_id = v.id
           AND NOT s1.dry_run
           AND s1.gdo_id = g.id
           AND (s1.status = 'SUCCESS'::text OR s1.portal_confirmation IS NOT NULL)
         ORDER BY s1.created_at DESC
         LIMIT 1) s ON true
  WHERE v.deleted_at IS NULL
    AND fn_visit_is_gdo_reporting(v.id);

COMMENT ON VIEW customer.gdo_reports IS
  'One row per (visit, ACTIVE GDO permit). Per-permit since 2026-08-24: the previous body took a '
  'single submission per VISIT and ignored gdo_id, so a multi-permit visit showed one permit''s '
  'confirmation next to a visit-wide reported=false. Never returns screenshot_path; the customer '
  'portal is anon and evidence is signed server-side.';

-- ---------------------------------------------------------------------------
-- 2. get_work_order: add the array, keep the scalar
-- ---------------------------------------------------------------------------
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
    -- Explicit key list: never to_jsonb(g). screenshot_path must never reach the customer.
    'gdo_reports', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'gdo_id',           g.gdo_id,
               'gdo_number',       g.gdo_number,
               'reported',         g.reported,
               'reported_at',      g.reported_at,
               'confirmation',     g.confirmation,
               'status',           g.status,
               'has_report_image', g.has_report_image) order by g.gdo_number), '[]'::jsonb)
        from public.visits v
        join customer.gdo_reports g on g.visit_id = v.id
       where v.public_id = w.id and v.deleted_at is null),
    -- ⚠ SUPERSEDED, KEPT ONLY SO THE DEPLOYED APP DOES NOT BREAK. Remove in a later migration once
    --   the Field Portal reads `gdo_reports`. LIMIT 1 is required: without it this scalar subquery
    --   now raises 21000 "more than one row returned by a subquery".
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
