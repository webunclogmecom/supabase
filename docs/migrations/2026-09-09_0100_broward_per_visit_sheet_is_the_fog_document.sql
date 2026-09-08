-- =============================================================================
-- 2026-09-09_0100  A Broward per-visit FDEP sheet IS the FOG document
-- =============================================================================
-- Fred, on the Field Portal for 028-HUM: *"i told you that the new Broward address
-- manifest doesn't need a blackout, but i don't know if that is preventing it to be
-- shown at the FP App, because i can't see the one at 27 Aug"*. It was. His screenshot
-- shows the card headed DERM FOG eManifest / DERM 312840 / DOCUMENTED with the viewer
-- reading "On file, not available for online viewing" -- the placeholder the FP renders
-- when it has no document URL.
--
-- (*) WHY A BROWARD PER-VISIT SHEET NEEDS NO BLACKOUT, AND WHY THE OLD ONES STILL DO.
-- The blackout exists because the Miami-Dade DERM_V4.00 address sheet is SHARED: one page
-- lists up to five clients, so handing it to a regulator or a customer whole discloses
-- businesses they have no relationship with. Measured before redaction shipped: 114 of 114
-- city sends disclosed other clients, averaging 7.15 and peaking at 18.
-- The Broward FDEP 62-705.300(3) form has ONE "B. ORIGINATOR INFORMATION" block and our
-- generator prints ONE VISIT PER PAGE, so a per-visit sheet carries exactly one client:
-- the one being shown it. There is nothing to redact. Fred, verbatim: *"broward receipts
-- from now on will not need a blackout"* and *"but the old ones yes"*, which the data
-- agrees with exactly:
--
--     Broward manifests carrying the SHARED sheet (still need the blackout)   167
--     manifests documented ONLY by per-visit FDEP sheets (need none)            3
--
-- (*) ONE DEFINITION, TWO CONSUMERS, BECAUSE THEY HAD ALREADY DIVERGED IN SHAPE.
-- customer.work_orders took page 1 through a LATERAL; customer.get_work_order built the
-- whole fog_documents array from its own JOIN. Both read derm.redacted_manifest_docs
-- DIRECTLY, so fixing either alone leaves the other blind -- and the FP card reads
-- get_work_order while send-derm-email reads the view. derm.fn_fog_documents is now the
-- single answer to "which FOG documents does this (manifest, client, visit) have?".
--
-- (*) IT IS A FALLBACK, NEVER A REPLACEMENT. When a redacted document exists it wins,
-- unchanged, for every one of the 700+ rows that have one. The per-visit sheet is returned
-- only when there is no redacted document at all. So this migration cannot alter what any
-- existing client or municipality is shown; VERIFY 2 asserts that against the whole
-- population rather than against the three rows that motivated it.
--
-- (*) SECURITY DEFINER, and the grants are the reason. Neither anon nor authenticated can
-- read derm.redacted_manifest_docs (pg_read_all_data + service_role only); they reach it
-- laundered through the owner-rights view and the SECDEF RPC. customer.get_work_order is
-- callable by ANON -- it is the Field Portal's lookup by public_id -- so an INVOKER
-- function here would 42501 the customer-facing card. The exposure is unchanged: a
-- per-visit FDEP sheet is the requesting client's own single-originator document, served
-- exactly the way its redacted counterpart already is.
--
-- (*) THE URL IS BUILT, NOT STORED. derm.manifest_visit_sheets holds photo_bucket +
-- photo_path (deliberately, so the pending private-storage move is a one-line change
-- rather than a migration). customer.public_url is NOT reusable here: it is hardcoded to
-- the 'GT - Visits Images' bucket. The shape emitted matches the stored URLs byte for byte:
--     https://<ref>.supabase.co/storage/v1/object/public/manifests/derm/1911/address_visit_5973.jpg
-- Bucket names are space-encoded so a bucket like 'GT - Visits Images' cannot emit a broken
-- URL if one is ever used here.
--
-- ⚠ NOT CHANGED, deliberately: public.v_derm_manifest_email_readiness.send_blocker and the
-- `no_redacted_sheet` / `missing_attachments` guards in send-derm-email. The city path is a
-- separate decision and is gated off today (city_email_live_sends=false,
-- city_email_start_from=infinity), so nothing there can send. Relaxing those guards before
-- the report demonstrably embeds the FDEP sheet would mail a municipality a report with a
-- missing FOG page, which is worse than the refusal it replaces.
--
-- Rule 8: one function and two consumers, no table changes, nothing to opt in or out of.
-- =============================================================================

begin;

-- PART 1  the single definition of "which FOG documents does this pair have?"
create or replace function derm.fn_fog_documents(
  p_manifest_id bigint,
  p_client_id   bigint,
  p_visit_id    bigint
) returns table (effective_page integer, url text)
language sql
stable
security definer
set search_path to 'derm', 'public', 'pg_temp'
as $function$
  -- (a) The redacted pages of the SHARED Miami-Dade sheet. If any exist they win, and the
  --     per-visit arm is never reached. Nothing about an existing document changes.
  select d.effective_page, d.url
    from derm.redacted_manifest_docs d
   where d.manifest_id = p_manifest_id
     and d.client_id   = p_client_id
  union all
  -- (b) Only when there is no redacted document at all: the Broward FDEP per-visit sheet
  --     for THIS visit. It carries one originator, so it is already safe to show unredacted.
  --     Page 1 because a per-visit sheet is a single page by construction.
  select 1, 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/'
            || replace(s.photo_bucket, ' ', '%20') || '/' || s.photo_path
    from derm.manifest_visit_sheets s
   where s.manifest_id = p_manifest_id
     and s.visit_id    = p_visit_id
     and s.deleted_at is null
     and coalesce(s.photo_bucket, '') <> ''
     and coalesce(s.photo_path,   '') <> ''
     and not exists (select 1 from derm.redacted_manifest_docs d2
                      where d2.manifest_id = p_manifest_id and d2.client_id = p_client_id)
$function$;

comment on function derm.fn_fog_documents(bigint,bigint,bigint) is
  'The FOG documents for one (manifest, client, visit): the redacted pages of the shared '
  'Miami-Dade address sheet, or, when there are none, the Broward FDEP per-visit sheet for '
  'that visit. The FDEP form has one originator per page, so it needs no redaction. A '
  'redacted document always wins. Read by customer.work_orders and customer.get_work_order; '
  'do not re-implement it in either.';

revoke all on function derm.fn_fog_documents(bigint,bigint,bigint) from public;
grant execute on function derm.fn_fog_documents(bigint,bigint,bigint)
  to anon, authenticated, service_role, pg_read_all_data;

-- PART 2  customer.work_orders. Definition COPIED from pg_get_viewdef and edited by
-- anchor-asserted substitution; diffed before applying. Only the rd LATERAL moved, and
-- the projected rd.url AS derm_manifest_url is byte-identical.
create or replace view customer.work_orders as
SELECT v.public_id AS id,
    customer.uuid_from_bigint(v.client_id) AS client_id,
    v.visit_date,
        CASE
            WHEN v.start_at IS NOT NULL THEN to_char((v.start_at AT TIME ZONE 'America/New_York'::text), 'FMHH12:MI AM'::text)
            ELSE NULL::text
        END AS visit_time,
    COALESCE(( SELECT string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS string_agg
           FROM visit_assignments va
             JOIN employees e ON e.id = va.employee_id
          WHERE va.visit_id = v.id), ( SELECT string_agg(e2.full_name, ', '::text ORDER BY e2.full_name) AS string_agg
           FROM visit_team vt
             JOIN employees e2 ON e2.id = vt.employee_id
          WHERE vt.visit_id = v.id)) AS driver,
    veh.name AS truck,
    ( SELECT vd.decal_number
           FROM manifest_visits mv
             JOIN derm_manifests dm_1 ON dm_1.id = mv.manifest_id AND dm_1.deleted_at IS NULL
             JOIN disposal_facilities df ON df.id = dm_1.disposal_facility_id
             JOIN vehicle_decals vd ON vd.vehicle_id = veh.id AND vd.jurisdiction = df.county AND vd.status = 'ACTIVE'::text
          WHERE mv.visit_id = v.id
         LIMIT 1) AS decal,
    COALESCE(v.manhole_count, NULLIF(prop.grease_trap_manhole_count, 0), NULLIF(( SELECT prim.grease_trap_manhole_count
           FROM properties prim
          WHERE prim.client_id = v.client_id AND prim.is_primary = true
         LIMIT 1), 0)) AS manholes,
    v.manhole_breakdown,
    v.ticket_number,
    v.trap_condition_notes AS trap_condition,
    row_number() OVER (PARTITION BY v.client_id, (EXTRACT(year FROM v.visit_date)) ORDER BY v.visit_date)::integer AS visit_num,
    ( SELECT
                CASE
                    WHEN sc.frequency_days IS NULL OR sc.frequency_days <= 0 THEN NULL::integer
                    ELSE GREATEST(1::numeric, round(365.0 / sc.frequency_days::numeric))::integer
                END AS "greatest"
           FROM service_configs sc
          WHERE sc.client_id = v.client_id AND sc.service_type = v.service_type
         LIMIT 1) AS visit_total,
    NULL::text AS notes,
    COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS derm_manifest_number,
    rd.url AS derm_manifest_url,
    COALESCE(dm.wwtp_receipt_number, dm.white_manifest_number, dm.yellow_ticket_number) AS wwtp_receipt_number,
        CASE
            WHEN rc.class = 'receipt'::text THEN dm.derm_manifest_url
            ELSE NULL::text
        END AS wwtp_receipt_url,
    dm.wwtp_ticket_number,
    v.created_at,
    COALESCE(v.completed_at, v.created_at) AS updated_at,
    COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS manifest_number,
        CASE
            WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'::text
            WHEN dm.white_manifest_number IS NOT NULL AND length(dm.white_manifest_number) >= 5 THEN 'dade'::text
            ELSE NULL::text
        END AS manifest_jurisdiction,
    dm.id AS manifest_id,
    COALESCE(NULLIF(prop.sample_port_count, 0), NULLIF(( SELECT prim.sample_port_count
           FROM properties prim
          WHERE prim.client_id = v.client_id AND prim.is_primary = true
         LIMIT 1), 0)) AS sample_ports,
    ( SELECT df.name
           FROM disposal_facilities df
          WHERE df.id = dm.disposal_facility_id) AS disposal_facility,
    COALESCE(( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE li.visit_id = v.id AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text), ( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND li.quote_id IS NULL AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text), ARRAY[]::text[]) AS services,
    ( SELECT df2.county
           FROM disposal_facilities df2
          WHERE df2.id = dm.disposal_facility_id) AS disposal_county,
    COALESCE(( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE li.visit_id = v.id AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text), ( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND li.quote_id IS NULL AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text), ARRAY[]::text[]) AS service_items,
    COALESCE(( SELECT array_agg(DISTINCT lbl.label) AS array_agg
           FROM ( SELECT COALESCE(sli.service_type,
                        CASE
                            WHEN x.nm ~* 'unclog'::text THEN 'Unclogging'::text
                            WHEN x.nm ~* 'pump'::text THEN 'Pumping'::text
                            WHEN x.nm ~* 'hydrojet'::text THEN 'Cleaning'::text
                            WHEN x.nm ~* '^camera inspection'::text THEN 'Camera Inspection'::text
                            WHEN x.nm ~* 'dye test'::text THEN 'Dye Test'::text
                            WHEN x.nm ~* 'assessment'::text THEN 'Assessment'::text
                            ELSE NULL::text
                        END) AS label
                   FROM ( SELECT TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) AS nm,
                            lpad("substring"(TRIM(BOTH FROM li.name), '^([0-9]+)'::text), 2, '0'::text) AS code
                           FROM line_items li
                          WHERE li.visit_id = v.id AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text) x
                     LEFT JOIN service_line_items sli ON sli.code = x.code) lbl
          WHERE lbl.label IS NOT NULL), ( SELECT array_agg(DISTINCT lbl.label) AS array_agg
           FROM ( SELECT COALESCE(sli.service_type,
                        CASE
                            WHEN x.nm ~* 'unclog'::text THEN 'Unclogging'::text
                            WHEN x.nm ~* 'pump'::text THEN 'Pumping'::text
                            WHEN x.nm ~* 'hydrojet'::text THEN 'Cleaning'::text
                            WHEN x.nm ~* '^camera inspection'::text THEN 'Camera Inspection'::text
                            WHEN x.nm ~* 'dye test'::text THEN 'Dye Test'::text
                            WHEN x.nm ~* 'assessment'::text THEN 'Assessment'::text
                            ELSE NULL::text
                        END) AS label
                   FROM ( SELECT TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) AS nm,
                            lpad("substring"(TRIM(BOTH FROM li.name), '^([0-9]+)'::text), 2, '0'::text) AS code
                           FROM line_items li
                          WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND li.quote_id IS NULL AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text) x
                     LEFT JOIN service_line_items sli ON sli.code = x.code) lbl
          WHERE lbl.label IS NOT NULL), ARRAY[]::text[]) AS service_type
   FROM visits v
     LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
     LEFT JOIN properties prop ON prop.id = v.property_id
     LEFT JOIN LATERAL ( SELECT dm_inner.id,
            dm_inner.client_id,
            dm_inner.service_date,
            dm_inner.dump_ticket_date,
            dm_inner.white_manifest_number,
            dm_inner.yellow_ticket_number,
            dm_inner.sent_to_client,
            dm_inner.sent_to_city,
            dm_inner.created_at,
            dm_inner.updated_at,
            dm_inner.wwtp_receipt_number,
            dm_inner.wwtp_receipt_document_path,
            dm_inner.wwtp_ticket_number,
            dm_inner.disposal_facility_id,
            dm_inner.derm_manifest_url,
            dm_inner.derm_address_url,
            dm_inner.fog_manifest_url,
            dm_inner.gdo_id
           FROM derm_manifests dm_inner
             JOIN manifest_visits mv ON mv.manifest_id = dm_inner.id
          WHERE mv.visit_id = v.id AND dm_inner.deleted_at IS NULL
          ORDER BY dm_inner.service_date DESC NULLS LAST
         LIMIT 1) dm ON true
     LEFT JOIN LATERAL ( SELECT f.url
           FROM derm.fn_fog_documents(dm.id, v.client_id, v.id) f
          ORDER BY f.effective_page
         LIMIT 1) rd ON true
     LEFT JOIN derm.receipt_doc_class rc ON rc.url = dm.derm_manifest_url
  WHERE v.visit_status = 'completed'::text AND v.client_id IS NOT NULL AND COALESCE(v.derm_required, true) = true AND v.deleted_at IS NULL;

-- PART 3  customer.get_work_order. Same treatment. The fog_documents projection shape
-- (effective_page + url, ordered) is unchanged, so both its consumers keep working:
-- the FP FOG card and the print report both read workOrder.fog_documents.
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
        cross join lateral derm.fn_fog_documents(dm.id, v.client_id, v.id) fd
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

commit;

-- -----------------------------------------------------------------------------
-- VERIFY. The population control is the point: this must change nothing for any
-- manifest that already had a redacted document. Rolled back either way.
-- -----------------------------------------------------------------------------
do $$
declare
  v_28hum_url text; v_28hum_pages int;
  v_before int; v_after int; v_moved int;
  v_anon_ok int; v_shared_unchanged int; v_pid text;
  n int;
begin
  ---------------------------------------------------------------------------
  -- V1  the reported symptom: 028-HUM / visit 5973 / manifest 1911 now has a
  --     FOG document, and it is that visit's own FDEP sheet
  ---------------------------------------------------------------------------
  select count(*), min(url) into v_28hum_pages, v_28hum_url
    from derm.fn_fog_documents(1911, 318, 5973);
  if v_28hum_pages <> 1 then
    raise exception 'V1 FAIL: expected 1 FOG document for 1911/318/5973, got %', v_28hum_pages;
  end if;
  if v_28hum_url not like '%address_visit_5973%' then
    raise exception 'V1 FAIL: the document is not that visit''s sheet: %', v_28hum_url;
  end if;

  -- and it reaches the two consumers
  select count(*) into n from customer.work_orders w
   where w.manifest_id = 1911 and w.derm_manifest_url is not null;
  if n <> 1 then raise exception 'V1 FAIL: work_orders.derm_manifest_url still null for 1911'; end if;

  select jsonb_array_length(customer.get_work_order((select public_id from public.visits where id=5973))
           -> 'work_order' -> 'fog_documents') into n;
  if n <> 1 then raise exception 'V1 FAIL: get_work_order returned % fog_documents, expected 1', n; end if;

  ---------------------------------------------------------------------------
  -- V2  POPULATION CONTROL. Every manifest that already had a redacted document
  --     must serve byte-identical documents. This is the assertion that matters:
  --     without it, "312840 works now" could mean the view serves anything.
  ---------------------------------------------------------------------------
  -- ⚠ customer.work_orders.client_id is a UUID (the customer-facing id) and
  -- derm.redacted_manifest_docs.client_id is the bigint public.clients.id. Joining them
  -- directly raises 42883, which is how the first version of this control was caught.
  -- The bigint comes from public.visits, joined on the view's own id (v.public_id).
  select count(*) into v_shared_unchanged
    from customer.work_orders w
    join public.visits v on v.public_id = w.id
   where exists (select 1 from derm.redacted_manifest_docs d
                  where d.manifest_id = w.manifest_id and d.client_id = v.client_id)
     and w.derm_manifest_url is distinct from (
       select d2.url from derm.redacted_manifest_docs d2
        where d2.manifest_id = w.manifest_id and d2.client_id = v.client_id
        order by d2.effective_page limit 1);
  if v_shared_unchanged <> 0 then
    raise exception 'V2 FAIL: % rows with a redacted doc now serve a different URL', v_shared_unchanged;
  end if;

  select count(*) into v_before from derm.redacted_manifest_docs;
  select count(distinct (w.manifest_id, w.client_id)) into v_after
    from customer.work_orders w where w.derm_manifest_url is not null;
  raise notice 'V2 redacted rows=% ; work orders serving a FOG doc=%', v_before, v_after;

  ---------------------------------------------------------------------------
  -- V3  DISCRIMINATION: a redacted document must WIN over a per-visit sheet.
  --     Arrange both on one pair and require the redacted one to be served.
  ---------------------------------------------------------------------------
  -- This table has SIX NOT NULL columns beyond the key (fingerprint, band_y0, band_y1,
  -- source_url ...), so a probe row must supply them all. Enumerated from pg_attribute
  -- rather than guessed one failure at a time.
  insert into derm.redacted_manifest_docs
    (manifest_id, client_id, effective_page, url, fingerprint, band_y0, band_y1, source_url)
  values (1911, 318, 1, 'https://example.invalid/probe-redacted.jpg',
          'probe-verify-rolled-back', 10.0, 20.0, 'https://example.invalid/probe-source.jpg')
  on conflict do nothing;

  select url into v_28hum_url from derm.fn_fog_documents(1911, 318, 5973) order by effective_page limit 1;
  if v_28hum_url <> 'https://example.invalid/probe-redacted.jpg' then
    raise exception 'V3 FAIL: the per-visit sheet beat a real redacted document (%)', v_28hum_url;
  end if;
  select count(*) into n from derm.fn_fog_documents(1911, 318, 5973);
  if n <> 1 then raise exception 'V3 FAIL: both arms returned, got % rows', n; end if;

  delete from derm.redacted_manifest_docs
   where manifest_id = 1911 and client_id = 318 and url = 'https://example.invalid/probe-redacted.jpg';

  ---------------------------------------------------------------------------
  -- V4  a soft-deleted per-visit sheet must NOT be served
  ---------------------------------------------------------------------------
  update derm.manifest_visit_sheets set deleted_at = now()
   where manifest_id = 1911 and visit_id = 5973;
  select count(*) into n from derm.fn_fog_documents(1911, 318, 5973);
  if n <> 0 then raise exception 'V4 FAIL: a soft-deleted sheet is still served'; end if;
  update derm.manifest_visit_sheets set deleted_at = null
   where manifest_id = 1911 and visit_id = 5973;

  ---------------------------------------------------------------------------
  -- V5  GRANTS, as the roles. anon matters: customer.get_work_order is the
  --     Field Portal's public lookup and an INVOKER function would 42501 it.
  ---------------------------------------------------------------------------
  if not has_function_privilege('anon','derm.fn_fog_documents(bigint,bigint,bigint)','EXECUTE')
     or not has_function_privilege('authenticated','derm.fn_fog_documents(bigint,bigint,bigint)','EXECUTE')
     or not has_function_privilege('service_role','derm.fn_fog_documents(bigint,bigint,bigint)','EXECUTE')
     or not has_function_privilege('pg_read_all_data','derm.fn_fog_documents(bigint,bigint,bigint)','EXECUTE')
  then raise exception 'V5 FAIL: a reader role lacks EXECUTE'; end if;

  -- ⚠ Resolve the public_id BEFORE switching role. anon cannot read public.visits (the
  -- 2026-07-12 harden), so an inline subquery here fails 42501 on the LOOKUP and tells you
  -- nothing about the RPC you meant to test.
  select public_id into v_pid from public.visits where id = 5973;
  set local role anon;
  select jsonb_array_length(customer.get_work_order(v_pid) -> 'work_order' -> 'fog_documents')
    into v_anon_ok;
  reset role;
  if v_anon_ok <> 1 then
    raise exception 'V5 FAIL: anon sees % fog_documents through get_work_order, expected 1', v_anon_ok;
  end if;

  set local role authenticated;
  select count(*) into n from customer.work_orders where manifest_id = 1911;
  reset role;
  if n = 0 then raise exception 'V5 FAIL: authenticated cannot read work_orders'; end if;

  raise exception 'ALL VERIFY PASSED (rolled back) :: 028-HUM served=% | redacted rows unchanged=% | anon fog_documents=%',
    v_28hum_pages, v_shared_unchanged, v_anon_ok;
end $$;
