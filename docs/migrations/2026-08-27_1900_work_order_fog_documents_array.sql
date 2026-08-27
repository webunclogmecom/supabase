-- 2026-08-27_1900_work_order_fog_documents_array.sql
--
-- WHY
-- ---
-- `2026-08-27_1830` made a manifest able to hold one redacted FOG document PER PAGE, and 022-GRO now
-- has two. `customer.work_orders.derm_manifest_url` is a scalar and, by design, now returns only the
-- FIRST page, so without this the second page exists and no client can reach it.
--
-- The Field Portal reads the visit through `customer.get_work_order`, NOT through the view
-- (measured: anon holds no SELECT on customer.work_orders but does hold EXECUTE on this function),
-- so the per-page list is added here. That also means this is a pure CREATE OR REPLACE FUNCTION with
-- no view column-list change, so no grant is at risk.
--
-- ⚠ The shape deliberately mirrors the `gdo_reports` array immediately above it, which is already
-- one-entry-per-permit and is already rendered as a list by the same Field Portal component. That is
-- what makes the app change small.
--
-- 🛑 THE MANIFEST IS RESOLVED THE SAME WAY `customer.work_orders` RESOLVES IT (newest service_date,
-- LIMIT 1). Joining `manifest_visits` straight through would return documents belonging to a
-- different manifest than the one the rest of the payload describes, on any visit carrying more than
-- one manifest. Two sources of truth for "which manifest is this work order about" is exactly the
-- kind of quiet divergence this estate keeps paying for.
--
-- ⚠ `derm` is NOT on this function's search_path (`public`, `customer`, `pg_temp`), so
-- `derm.redacted_manifest_docs` is schema-qualified. It is SECURITY DEFINER, which is how it reaches
-- a schema the caller holds nothing on.
--
-- ⚠ `work_order.derm_manifest_url` is left in place and unchanged. Removing it would break the
-- deployed Field Portal bundle the moment this lands, and the two can coexist: the scalar is page 1,
-- the array is every page.
--
-- 🛑 BODY COPIED FROM pg_get_functiondef AND SPLICED BY SCRIPT, one anchor asserted to match exactly
-- once. CREATE OR REPLACE takes the whole body.
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
       where v.public_id = w.id and v.deleted_at is null),
    -- The redacted FOG eManifest, ONE ENTRY PER PAGE. A client whose permitted facilities are
    -- printed across two pages of one sheet has TWO redacted documents; work_order.derm_manifest_url
    -- is only the first of them and is kept for backwards compatibility. Render this array.
    -- 🛑 The manifest is resolved with the SAME rule customer.work_orders uses (newest service_date,
    -- LIMIT 1). Joining manifest_visits directly instead would return documents for a manifest the
    -- rest of the payload is not describing, on a visit that carries more than one.
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
       where v.public_id = w.id and v.deleted_at is null)
  )
  from customer.work_orders w
  where w.id = p_work_order_id;
$function$;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_wo text; v_docs jsonb; v_n integer;
BEGIN
  -- 1. Grants survived.
  IF NOT has_function_privilege('anon','customer.get_work_order(text)','EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: anon lost EXECUTE on get_work_order';
  END IF;

  -- 2. 🛑 THE TWO-PAGE CASE. 022-GRO / manifest 509 is the reason this exists: its work order must
  --    now carry BOTH pages, in page order.
  SELECT w.id INTO v_wo FROM customer.work_orders w
    JOIN public.visits v ON v.public_id = w.id
    JOIN public.manifest_visits mv ON mv.visit_id = v.id
   WHERE mv.manifest_id = 509 LIMIT 1;
  IF v_wo IS NULL THEN RAISE EXCEPTION 'VERIFY 2 FAILED: no work order resolves manifest 509'; END IF;

  v_docs := customer.get_work_order(v_wo) -> 'fog_documents';
  IF jsonb_array_length(v_docs) <> 2 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: fog_documents has % entries for 022-GRO, expected 2: %',
                    jsonb_array_length(v_docs), v_docs::text;
  END IF;
  IF (v_docs -> 0 ->> 'effective_page')::int <> 1 OR (v_docs -> 1 ->> 'effective_page')::int <> 2 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: pages out of order: %', v_docs::text;
  END IF;
  IF (v_docs -> 0 ->> 'url') IS NULL OR (v_docs -> 1 ->> 'url') IS NULL THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: a page has no url';
  END IF;

  -- 3. THE CONTROL. A single-page work order must return exactly ONE entry, not zero and not two.
  --    Without this, an array that was always empty would pass VERIFY 2 in spirit but serve nothing.
  SELECT count(*) INTO v_n FROM (
    SELECT w.id FROM customer.work_orders w
     WHERE w.derm_manifest_url IS NOT NULL
       AND jsonb_array_length(customer.get_work_order(w.id) -> 'fog_documents') <> 1
       AND w.id <> v_wo
     LIMIT 5) z;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: % single-page work order(s) do not return exactly one document', v_n;
  END IF;

  -- 4. And the legacy scalar still works, so the deployed Field Portal bundle keeps rendering.
  IF (customer.get_work_order(v_wo) -> 'work_order' ->> 'derm_manifest_url') IS NULL THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: derm_manifest_url went NULL; the live app would show nothing';
  END IF;

  RAISE NOTICE 'VERIFY ok: fog_documents returns 2 pages for 022-GRO, exactly 1 for single-page work orders, and the legacy scalar still resolves.';
END $do$;

COMMIT;
