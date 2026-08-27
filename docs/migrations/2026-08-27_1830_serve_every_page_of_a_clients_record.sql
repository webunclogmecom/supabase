-- 2026-08-27_1830_serve_every_page_of_a_clients_record.sql
--
-- WHY: STEP 3 OF 3. THIS IS THE ONE THAT OPENS IT.
-- ---------------------------------------------------------------------------
-- Fred: "can't we show both pages?" Two clients are served ONE page of a record that spans two:
--
--   043-MIL  manifest 1692  ticket-832194   printed rows 5|6 on images 1|2, serves page 1
--   022-GRO  manifest 509   window4-sheet3  placed cards on pages 1 AND 2, serves page 2
--
-- ⚠ 022-GRO is NOT a multi-permit case. It is one client written on both pages of a handwritten pad
-- sheet, so this is a general single-page assumption rather than a GDO feature, and the same fix
-- covers both. Nothing in the estate reports this: `v_blackout_blocked_sheets` reports BLOCKED
-- folders, never UNDER-SERVED ones, so it took an audit to find.
--
-- Steps 1 and 2 (`2026-08-27_1800` + redactor v14) were deliberately inert. This one changes what
-- clients see.
--
-- WHAT CHANGES
-- ---------------------------------------------------------------------------
-- 1. `derm.redacted_manifest_docs` PK: (manifest_id) -> (manifest_id, effective_page).
-- 2. `derm.fn_blackout_targets`: elect a FOLDER per manifest and keep EVERY PAGE of it, and compare
--    staleness against the ledger row FOR THAT PAGE.
-- 3. `customer.work_orders`: the ledger join becomes a LATERAL pinning the first page.
--
-- 🛑 THE ELECTION STAYS, AND FRED'S PROPOSED KEY WOULD HAVE BROKEN IT. `DISTINCT ON (manifest_id)`
-- had two jobs: discarding a manifest's other FOLDERS (legitimate: 5 manifests are carded in two
-- folders, and without it each emits a target that upserts the same row and fights every sweep) and
-- discarding its other PAGES (the defect). Keying the ledger on (manifest_id, effective_page) alone
-- would collide on FOUR manifests (1246/1247/1248/1249 are the same paper carded in both `derm/1246`
-- and `ticket-828604`, at the SAME page 1). So the folder election is kept and only the page
-- election is dropped.
--
-- 🛑 THE LATERAL IN `customer.work_orders` IS NOT COSMETIC. A manifest can now hold two ledger rows,
-- and the existing plain LEFT JOIN would fan the view out to one work-order row per page. That row
-- duplication would be silent and would reach every consumer of the view, not just the FOG card.
-- Pinning the first page keeps the grain and keeps `derm_manifest_url` the scalar every existing
-- reader expects; the full list arrives separately as `fog_documents` on the RPC the Field Portal
-- actually calls.
--
-- ✅ `derm.v_blackout_blocked_sheets` NEEDS NO CHANGE, and this was checked rather than assumed. Both
-- of its `redacted_manifest_docs` joins sit inside `EXISTS (...)` predicates, which are semi-joins,
-- and every aggregate in the view is over `arm` (`count(DISTINCT arm.matched_client_id)` etc.), never
-- over `d`. A second ledger row per manifest therefore cannot inflate `clients_blocked` or
-- `manifests_blocked`. Verified by enumerating every `d.` reference in `pg_get_viewdef`: 2
-- occurrences, both inside EXISTS.
--
-- 🛑 BOTH BODIES WERE COPIED FROM THE CATALOGUE AND SPLICED BY SCRIPT, NEVER RETYPED. Anchors
-- asserted to match exactly once, and `fn_blackout_targets`' RETURNS TABLE list asserted
-- byte-identical so CREATE OR REPLACE stays legal and the `service_role` EXECUTE grant survives. A
-- DROP+CREATE there would discard it and the sweep would die at "targets rpc failed".
--
-- EXPECTED BLAST RADIUS: exactly ONE document regenerates today (manifest 509 page 1, which has
-- valid geometry already). 043-MIL's second page has no card yet, so it appears only once a person
-- places that stamp in the Studio, which is deliberately a separate act.
--
-- RULE 8 (audit trail): `derm.redacted_manifest_docs` stays OPT-OUT (machine-written derived output,
-- rewritten on every regeneration, fully reproducible from fn_blackout_targets plus the redactor).
-- The decisions that matter are audited on `address_row_map` and `page_block_extents`.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1. The key.
-- ---------------------------------------------------------------------------
ALTER TABLE derm.redacted_manifest_docs DROP CONSTRAINT redacted_manifest_docs_pkey;
ALTER TABLE derm.redacted_manifest_docs DROP CONSTRAINT redacted_manifest_docs_manifest_page_key;
ALTER TABLE derm.redacted_manifest_docs ADD PRIMARY KEY (manifest_id, effective_page);

-- ---------------------------------------------------------------------------
-- PART 2. Serve every page of the elected folder.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_blackout_targets(p_limit integer DEFAULT 3)
 RETURNS TABLE(manifest_id bigint, client_id bigint, ticket_key text, source_url text, effective_page integer, band_y0 numeric, band_y1 numeric, blocks_top numeric, blocks_bottom numeric, fingerprint text, old_url text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  -- ONE ticket_page_images call per distinct ticket (111) instead of ~1,100. MATERIALIZED is
  -- load-bearing: without it the planner may inline and re-evaluate per reference, which is the
  -- entire bug being fixed here.
  WITH timg AS MATERIALIZED (
    SELECT t.tkey, derm.ticket_page_images(t.tkey) AS imgs
    FROM (SELECT DISTINCT r.white_manifest_number AS tkey
            FROM derm.address_row_map r
           WHERE r.matched_manifest_id IS NOT NULL AND r.matched_client_id IS NOT NULL
             AND r.stamp_placed_at IS NOT NULL
             AND r.white_manifest_number IS NOT NULL) t
  ), cards AS (
    SELECT r.id AS card_id, r.dump_folder, r.page AS ocr_page, r.row_index, r.source,
           r.stamp_placed_at, r.matched_manifest_id AS mid, r.matched_client_id AS cid,
           r.white_manifest_number AS tkey, b.band_y0_pct, b.band_y1_pct, b.effective_page,
           ti.imgs
    FROM derm.address_row_map r
    JOIN derm.v_stamp_row_bands b ON b.id = r.id
    LEFT JOIN timg ti ON ti.tkey = r.white_manifest_number      -- LEFT: see header, NULL-ticket parity
    WHERE r.matched_manifest_id IS NOT NULL AND r.matched_client_id IS NOT NULL
      AND r.stamp_placed_at IS NOT NULL
      AND COALESCE(array_length(ti.imgs, 1), 0) > 0             -- identical predicate, memoized input
      AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r2
                      LEFT JOIN derm.v_stamp_row_bands b2 ON b2.id = r2.id
                      WHERE r2.dump_folder = r.dump_folder AND b2.id IS NULL)
      AND NOT EXISTS (
        SELECT 1 FROM (
          SELECT c2.id,
                 rank() OVER (PARTITION BY c2.dump_folder, c2.page ORDER BY c2.stamp_y_pct)  AS yr,
                 rank() OVER (PARTITION BY c2.dump_folder, c2.page ORDER BY c2.row_index)    AS rr
          FROM derm.address_row_map c2
          WHERE c2.dump_folder = r.dump_folder AND c2.source = 'claude-vision-v1'
            AND c2.stamp_y_pct IS NOT NULL AND c2.stamp_page = c2.page AND c2.page = r.page
        ) o WHERE o.id = r.id AND o.yr <> o.rr)
  ), grp AS (
    -- 🛑 GROUP FIRST, ELECT SECOND. The old DISTINCT ON (mid) was doing TWO jobs and only one was
    -- wanted. Job 1, legitimate: a manifest can carry placed cards in more than one
    -- (dump_folder, effective_page) group, and without an election each would emit a target that
    -- upserts the same PK and fights every sweep. Job 2, the DEFECT: it also discarded a manifest's
    -- other PERMIT cards INSIDE the winning group, so a client holding several GDO permits on one
    -- sheet was served only ONE of its own printed rows. Grouping first keeps job 1 and drops job 2.
    SELECT c.mid, c.cid, c.tkey, c.dump_folder, c.effective_page,
           max(c.imgs)                                   AS imgs,
           count(*)                                      AS n_bands,
           min(c.band_y0_pct)                            AS band_y0_pct,
           max(c.band_y1_pct)                            AS band_y1_pct,
           string_agg(c.band_y0_pct::text || '|' || c.band_y1_pct::text, '|'
                      ORDER BY c.band_y0_pct)            AS band_str,
           max(c.stamp_placed_at)                        AS stamp_placed_at,
           max(c.card_id)                                AS card_id
    FROM cards c
    GROUP BY c.mid, c.cid, c.tkey, c.dump_folder, c.effective_page
  ), elect AS (
    -- 🛑 ELECT A FOLDER, NOT A PAGE. The DISTINCT ON here still exists for its ONE legitimate job:
    -- 5 manifests carry placed cards in more than one dump_folder (1246/1247/1248/1249 are the same
    -- paper carded in both `derm/1246` and `ticket-828604`), and without an election each folder
    -- would emit a target that upserts the same row and fights every sweep. It must NOT also discard
    -- the manifest's other PAGES, which is what kept 043-MIL and 022-GRO seeing one page of their own
    -- record. So elect the folder here, then keep every page of it below.
    -- ⚠ This is why the key cannot simply be (manifest_id, effective_page): those 4 manifests collide
    -- on it, having two folders at the SAME page.
    SELECT DISTINCT ON (mid) mid, dump_folder FROM grp
    ORDER BY mid, stamp_placed_at DESC NULLS LAST, card_id DESC
  ), best AS (
    SELECT g.* FROM grp g
    JOIN elect e ON e.mid = g.mid AND e.dump_folder = g.dump_folder
  ), live AS (
    SELECT b.* FROM best b
    JOIN public.derm_manifests dm ON dm.id = b.mid AND dm.deleted_at IS NULL AND dm.client_id = b.cid
    WHERE EXISTS (SELECT 1 FROM public.manifest_visits mv
                  JOIN public.visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL
                  WHERE mv.manifest_id = b.mid)
  ), geo AS (
    SELECT l.mid, l.cid, l.tkey, l.dump_folder,
           l.imgs[l.effective_page] AS src,                     -- was (ticket_page_images(l.tkey))[...]
           l.effective_page, l.band_y0_pct AS y0, l.band_y1_pct AS y1, l.band_str, l.n_bands,
           LEAST(e.top_pct,
                 (SELECT min(b3.band_y0_pct) FROM derm.v_stamp_row_bands b3
                   WHERE b3.dump_folder = l.dump_folder AND b3.effective_page = l.effective_page)) AS btop,
           GREATEST(e.bottom_pct,
                 (SELECT max(b4.band_y1_pct) FROM derm.v_stamp_row_bands b4
                   WHERE b4.dump_folder = l.dump_folder AND b4.effective_page = l.effective_page)) AS bbot
    FROM live l
    JOIN derm.page_block_extents e
      ON e.dump_folder = l.dump_folder AND e.effective_page = l.effective_page   -- HARD GATE: measured pages only
    WHERE l.effective_page >= 1
      AND l.effective_page <= COALESCE(array_length(l.imgs, 1), 0)               -- same bound, memoized
  ), ok AS (
    SELECT g.* FROM geo g
    WHERE g.src IS NOT NULL AND g.y1 > g.y0
      AND NOT EXISTS (
        SELECT 1 FROM (
          SELECT mode() WITHIN GROUP (ORDER BY r5.image_url) AS ocr_img
          FROM derm.address_row_map r5
          WHERE r5.dump_folder = g.dump_folder AND r5.page = g.effective_page
            AND r5.image_url <> 'pending' AND r5.source = 'claude-vision-v1'
        ) oi
        WHERE oi.ocr_img IS NOT NULL
          AND derm._img_etag(oi.ocr_img) IS DISTINCT FROM derm._img_etag(g.src))
      -- 🛑 FOREIGN-BAND EXCLUSION. y0..y1 is now the UNION of a client's rows, and the redactor
      -- paints exactly two boxes: [btop..y0] and [y1..bbot]. So everything BETWEEN y0 and y1 is
      -- revealed. That is correct only while the interval contains nothing but this client's own
      -- rows. Measured 2026-08-27: 0 groups violate it and 0 groups have an internal gap, so this
      -- refuses nothing today -- it is here so a future non-contiguous group FAILS CLOSED (no
      -- document) instead of publishing a neighbour's printed row.
      AND NOT EXISTS (
        SELECT 1 FROM derm.address_row_map r6
        JOIN derm.v_stamp_row_bands b6 ON b6.id = r6.id
        WHERE r6.dump_folder = g.dump_folder
          AND COALESCE(r6.stamp_page, r6.page) = g.effective_page
          AND r6.stamp_placed_at IS NOT NULL
          AND (r6.matched_manifest_id IS DISTINCT FROM g.mid
            OR r6.matched_client_id   IS DISTINCT FROM g.cid)
          AND b6.band_y0_pct < g.y1 AND g.y0 < b6.band_y1_pct)
  ), fp AS (
    SELECT o.*, md5(coalesce(derm._img_etag(o.src), 'noetag') || '|' || o.band_str || '|' ||
                    coalesce(o.btop::text, 'x') || '|' || coalesce(o.bbot::text, 'x')) AS fprint
    FROM ok o
  )
  SELECT f.mid, f.cid, f.tkey, f.src, f.effective_page, f.y0, f.y1, f.btop, f.bbot, f.fprint, t.url
  FROM fp f
  -- 🛑 PER PAGE. Without the page this compares a page-2 target against the page-1 ledger row,
  -- so the fingerprints never match, every page-2 document is permanently stale, and the sweep
  -- republishes it every five minutes for ever.
  LEFT JOIN derm.redacted_manifest_docs t
         ON t.manifest_id = f.mid AND t.effective_page = f.effective_page
  LEFT JOIN derm.redacted_manifest_errors e2 ON e2.manifest_id = f.mid
  WHERE (t.manifest_id IS NULL OR t.fingerprint IS DISTINCT FROM f.fprint)
    AND (e2.manifest_id IS NULL OR e2.next_retry_at <= now())
  ORDER BY e2.next_retry_at NULLS FIRST, f.mid
  LIMIT p_limit;
$function$;

-- ---------------------------------------------------------------------------
-- PART 3. Keep customer.work_orders at one row per work order.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW customer.work_orders AS
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
     -- 🛑 LATERAL, NOT A PLAIN JOIN. A manifest can now hold one redacted document PER PAGE, and a
     -- plain join would fan this view out to one work-order row per page: the row itself would
     -- duplicate, silently, on every consumer of customer.work_orders. Pin the FIRST page so the
     -- grain is preserved and `derm_manifest_url` stays the scalar every existing reader expects.
     -- The full per-page list is served by customer.get_work_order's `fog_documents` array.
     LEFT JOIN LATERAL ( SELECT rd_inner.url
           FROM derm.redacted_manifest_docs rd_inner
          WHERE rd_inner.manifest_id = dm.id AND rd_inner.client_id = v.client_id
          ORDER BY rd_inner.effective_page
         LIMIT 1) rd ON true
     LEFT JOIN derm.receipt_doc_class rc ON rc.url = dm.derm_manifest_url
  WHERE v.visit_status = 'completed'::text AND v.client_id IS NOT NULL AND COALESCE(v.derm_required, true) = true AND v.deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_bad integer; v_pk text;
BEGIN
  -- 1. The key is the composite, and the old one is gone.
  SELECT pg_get_constraintdef(c.oid) INTO v_pk FROM pg_constraint c
    JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace
   WHERE n.nspname='derm' AND t.relname='redacted_manifest_docs' AND c.contype='p';
  IF v_pk IS DISTINCT FROM 'PRIMARY KEY (manifest_id, effective_page)' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: PK is %', COALESCE(v_pk,'<none>');
  END IF;

  -- 2. Grants survived, on all three objects. Losing service_role EXECUTE here kills the sweep
  --    silently; losing authenticated on the view takes the Field Portal offline.
  IF NOT has_function_privilege('service_role','derm.fn_blackout_targets(integer)','EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: service_role lost EXECUTE on fn_blackout_targets';
  END IF;
  IF NOT has_table_privilege('service_role','derm.redacted_manifest_docs','INSERT') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: service_role lost INSERT on the ledger';
  END IF;
  IF NOT has_table_privilege('authenticated','customer.work_orders','SELECT') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: authenticated lost SELECT on customer.work_orders';
  END IF;
  IF has_table_privilege('anon','customer.work_orders','SELECT') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: anon gained SELECT on customer.work_orders';
  END IF;

  -- 3. 🛑 THE GRAIN CONTROL. customer.work_orders must still hold exactly one row per work order.
  --    If the LATERAL were wrong this is where the silent duplication would show.
  SELECT count(*) INTO v_bad FROM (
    SELECT id FROM customer.work_orders GROUP BY id HAVING count(*) > 1) z;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: % work order(s) duplicated; the ledger join is fanning out', v_bad;
  END IF;

  -- 4. THE POINT: the under-served manifests now emit a target for their missing page.
  --    022-GRO/509 has cards on pages 1 and 2 and served page 2, so page 1 must appear.
  IF NOT EXISTS (SELECT 1 FROM derm.fn_blackout_targets(2000)
                  WHERE manifest_id = 509 AND effective_page = 1) THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: manifest 509 page 1 is still not a target; the page election is still in place';
  END IF;

  -- 5. AND NOTHING ELSE MOVED. Exactly one document may be stale: 509 page 1. If the ledger join were
  --    still manifest-only, every page-2 row would be permanently stale and this would be large.
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(2000);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: % documents stale, expected exactly 1 (manifest 509 page 1)', v_n;
  END IF;

  -- 6. The folder election is intact: no manifest emits targets from two folders.
  SELECT count(*) INTO v_bad FROM (
    SELECT manifest_id FROM derm.fn_blackout_targets(2000)
     GROUP BY manifest_id HAVING count(DISTINCT ticket_key) > 1) y;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: % manifest(s) emit targets from two folders; they would fight over one row', v_bad;
  END IF;

  -- 7. The existing 640 documents are untouched and still reachable.
  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs;
  IF v_n <> 640 THEN RAISE EXCEPTION 'VERIFY 7 FAILED: % ledger rows, expected 640', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: PK is (manifest_id, effective_page), work_orders grain preserved, manifest 509 page 1 is now a target, exactly 1 stale, folder election intact.';
END $do$;

COMMIT;
