-- 2026-08-27_1940_fog_documents_inside_work_order.sql
--
-- WHY: A CONTRACT BUG I SHIPPED 40 MINUTES AGO, CAUGHT BY LOOKING AT THE LIVE PAGE.
-- ---------------------------------------------------------------------------
-- `2026-08-27_1900` added `fog_documents` as a TOP-LEVEL key of the `customer.get_work_order`
-- payload, a sibling of `work_order`. Both consumers read it from INSIDE the work order:
--
--   the FOG card    `(Array.isArray(a.fog_documents) ? a.fog_documents : [])`   where a = workOrder
--   the print report `(Array.isArray(r.fog_documents) ? r.fog_documents : [])`  where r = workOrder
--
-- So the array was never seen. Because the app had also stopped reading the legacy
-- `derm_manifest_url` scalar, the FOG card fell through to its "On file, not available for online
-- viewing" placeholder: 022-GRO went from ONE working document to NONE. Confirmed on the live page
-- before this fix, and it is a REGRESSION, not merely the new feature failing to appear.
--
-- 🛑 HOW IT GOT PAST VERIFY, WHICH IS THE REUSABLE PART. `2026-08-27_1900`'s VERIFY asserted the
-- array had 2 entries, in page order, with non-null urls, and that single-page work orders returned
-- exactly 1. Every one of those assertions was TRUE and the feature was still broken, because they
-- all tested the PAYLOAD and none tested the CONTRACT: nothing asserted the array was reachable at
-- the path the consumer actually reads. A payload assertion cannot see a nesting mistake.
-- ⇒ When adding a key to an RPC an app already consumes, assert the PATH, not just the value, and
-- look at the rendered page. The bundle grep said `fog_documents` was present 4 times and that was
-- true and useless.
--
-- ⚠ The array expression is MOVED, not rewritten: it is lifted verbatim out of the top-level key and
-- merged into `work_order` with `to_jsonb(w) || jsonb_build_object(...)`, so the manifest-resolution
-- rule (newest service_date, LIMIT 1, matching customer.work_orders) is byte-identical.
--
-- ⚠ It is no longer duplicated at the top level. One location, and it is the one both readers use.
--
-- RULE 8 (audit trail): a function holds no state; opt-out.

BEGIN;

CREATE OR REPLACE FUNCTION customer.get_work_order(p_work_order_id text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'customer', 'pg_temp'
AS $function$
  select jsonb_build_object(
    -- 🛑 fog_documents lives INSIDE work_order, not beside it. Both consumers read it there:
    -- the FOG card does `workOrder.fog_documents` and the print report does the same. Returned as a
    -- sibling key it is invisible to them and the card silently falls back to its "not available
    -- for online viewing" placeholder, which is what happened on the first attempt.
    'work_order', to_jsonb(w) || jsonb_build_object(
      'fog_documents', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'effective_page', fd.effective_page,
               'url',            fd.url) order by fd.effective_page), '[]'::jsonb)
        from public.visits v
        cross join lateral (
          select dm_inner.id
            from public.derm_manifests dm_inner
            join public.manifest_visits mv on mv.manifest_id = dm_inner.id
           where mv.visit_id = v.id and dm_inner.deleted_at is null
           order by dm_inner.service_date desc nulls last
           limit 1) dm
        join derm.redacted_manifest_docs fd
          on fd.manifest_id = dm.id and fd.client_id = v.client_id
       where v.public_id = w.id and v.deleted_at is null)),
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

-- ---------------------------------------------------------------------------
-- VERIFY  (asserting the PATH the app reads, which is what 1900 failed to do)
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_wo text; v_inside jsonb; v_top jsonb; v_n integer;
BEGIN
  SELECT w.id INTO v_wo FROM customer.work_orders w
    JOIN public.visits v ON v.public_id = w.id
    JOIN public.manifest_visits mv ON mv.visit_id = v.id
   WHERE mv.manifest_id = 509 LIMIT 1;
  IF v_wo IS NULL THEN RAISE EXCEPTION 'VERIFY: no work order resolves manifest 509'; END IF;

  -- 1. 🛑 THE PATH THE APP ACTUALLY READS: payload -> work_order -> fog_documents.
  v_inside := customer.get_work_order(v_wo) -> 'work_order' -> 'fog_documents';
  IF v_inside IS NULL OR jsonb_typeof(v_inside) <> 'array' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: work_order.fog_documents is % - the app would show the placeholder',
                    COALESCE(jsonb_typeof(v_inside),'missing');
  END IF;
  IF jsonb_array_length(v_inside) <> 2 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % pages for 022-GRO, expected 2', jsonb_array_length(v_inside);
  END IF;
  IF (v_inside -> 0 ->> 'effective_page')::int <> 1 OR (v_inside -> 1 ->> 'effective_page')::int <> 2 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: pages out of order';
  END IF;

  -- 2. And it is no longer duplicated at the top level, so there is ONE place to read it.
  v_top := customer.get_work_order(v_wo) -> 'fog_documents';
  IF v_top IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: fog_documents still exists at the top level as well';
  END IF;

  -- 3. Single-page work orders return exactly one entry at the same path.
  SELECT count(*) INTO v_n FROM (
    SELECT w.id FROM customer.work_orders w
     WHERE w.derm_manifest_url IS NOT NULL AND w.id <> v_wo
       AND jsonb_array_length(customer.get_work_order(w.id) -> 'work_order' -> 'fog_documents') <> 1
     LIMIT 5) z;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: % single-page work order(s) wrong at the nested path', v_n;
  END IF;

  -- 4. The other top-level keys the app depends on are all still there.
  SELECT count(*) INTO v_n FROM jsonb_object_keys(customer.get_work_order(v_wo)) k
   WHERE k IN ('work_order','permits','inspection_items','recommendations','photos','gdo_reports');
  IF v_n <> 6 THEN RAISE EXCEPTION 'VERIFY 4 FAILED: only % of the 6 expected top-level keys', v_n; END IF;

  -- 5. The legacy scalar still resolves, so nothing else regresses.
  IF (customer.get_work_order(v_wo) -> 'work_order' ->> 'derm_manifest_url') IS NULL THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: derm_manifest_url went NULL';
  END IF;

  RAISE NOTICE 'VERIFY ok: work_order.fog_documents has 2 pages in order, no top-level duplicate, single-page work orders return 1, all 6 keys intact.';
END $do$;

COMMIT;
