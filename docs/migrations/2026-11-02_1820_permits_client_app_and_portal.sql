-- 2026-11-02_1820 · Permits for every county and city, step 3 of 3: the Client App and the portal learn the type
--
-- THE ASK. Fred, 2026-11-02 (Client App, Grove Kosher 022-GRO, Boca Raton): rename the section **City permits**;
-- Add permit = 1. Nickname, 2. Permit PDF + **File manually** (typed fields, layout A); *"the PDF is optional"* for
-- every type; the Field Portal shows *every type*, card retitled "Permits & Frequency". Plan:
-- docs/specs/2026-11-02-permits-one-table-plan.md. Trello sWPaXFZO.
--
-- WHAT CHANGES (anchored edits of the live bodies, md5-pinned)
--  1. client.gdos (the Client App's permit list): appends permit_type, permit_effective, permit_number (= gdo_number),
--     permit_type_name, issuing_authority; is_placeholder is now only for a GDO whose number is not GDO-n (a CCN is
--     a real permit, not a placeholder). Row 141 (057-BAY PSO) stops being a "placeholder".
--  2. NEW client.permit_types (code, name, issuing_authority, number_pattern, reads_pdf) of the ACTIVE types: the Add
--     permit type picker. SELECT to authenticated and service_role only (anon nothing).
--  3. customer.permits (Field Portal and the visit report, through customer.get_client_portal / get_work_order /
--     get_work_order_internal, whole rows, anon-reachable on purpose): appends permit_type, permit_type_name,
--     issuing_authority; `area` is 'Grease Trap' for a GDO and the type's name otherwise (it was 'Grease Trap' for
--     every permit, the PSO lift station included). Every type was already listed (status ACTIVE); Fred keeps that.
--     The frequency comparison (over_gdo_max, compliant) is already NULL for a permit with no max frequency.
--  4. client.upsert_gdo_permit (the Client App's only permit write path):
--     - accepts permit_type (must be an ACTIVE permit type, plain refusal otherwise) and permit_effective (bare date);
--     - an Add no longer requires the PDF (Fred, 2026-11-02: "the PDF is optional", replacing 2026-09-22);
--     - an Add with no permit_type stays GDO, so today's Client App keeps working unchanged until its release;
--     - two messages say "permit" instead of GDO/DERM. Whether the number fits the type is the step-1 trigger's job,
--       for every writer, and its sentence reaches the app as it is.
--     Whole-row return (to_jsonb(v_row)) now carries permit_type and permit_effective.
--
-- WHAT DOES NOT CHANGE
--  - Every other column value of client.gdos and customer.permits (VERIFY compares the original columns, row by row).
--  - Grants of both views (read back). customer.clients.gdo_permit_url stays GDO-only (step 2).
--
-- GUARDS: lock_timeout 3s; md5 pins; anchor counts; the function re-read equals the edited text. Requires step 1.
-- ROLLBACK: 2026-11-02_rollback_permits_one_table.sql

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.gdos'::regclass AND attname = 'permit_type' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'permits step 3: step 1 (2026-11-02_1800) is not applied';
  END IF;
END $pin$;

CREATE TEMP TABLE p3_cg ON COMMIT DROP AS SELECT t::text r FROM client.gdos t;
CREATE TEMP TABLE p3_cp ON COMMIT DROP AS SELECT t::text r FROM customer.permits t;
CREATE TEMP TABLE p3_acl ON COMMIT DROP AS
  SELECT oid, relacl::text acl FROM pg_class WHERE oid IN ('client.gdos'::regclass, 'customer.permits'::regclass);

-- client.gdos
DO $estep3_0$
DECLARE
  d text := pg_get_viewdef('client.gdos'::regclass, true);
  n text;
BEGIN
  IF md5(d) <> 'c4199ae0e9a42b193620bf6f9853952b' THEN RAISE EXCEPTION 'permits: client.gdos changed since 2026-11-02 (md5 %)', md5(d); END IF;
  n := d;
  IF (length(n) - length(replace(n, $a0$    gdo_number !~ '^GDO-[0-9]+$'::text AS is_placeholder,$a0$, ''))) / length($a0$    gdo_number !~ '^GDO-[0-9]+$'::text AS is_placeholder,$a0$) <> 1 THEN RAISE EXCEPTION 'permits: client.gdos anchor 0 not found 1 time(s)'; END IF;
  n := replace(n, $a0$    gdo_number !~ '^GDO-[0-9]+$'::text AS is_placeholder,$a0$, $b0$    permit_type = 'GDO'::text AND gdo_number !~ '^GDO-[0-9]+$'::text AS is_placeholder,$b0$);
  IF (length(n) - length(replace(n, $a1$    COALESCE(nickname, gdo_number) AS display_label
   FROM gdos;$a1$, ''))) / length($a1$    COALESCE(nickname, gdo_number) AS display_label
   FROM gdos;$a1$) <> 1 THEN RAISE EXCEPTION 'permits: client.gdos anchor 1 not found 1 time(s)'; END IF;
  n := replace(n, $a1$    COALESCE(nickname, gdo_number) AS display_label
   FROM gdos;$a1$, $b1$    COALESCE(nickname, gdo_number) AS display_label,
    permit_type,
    permit_effective,
    gdo_number AS permit_number,
    ( SELECT t.name FROM permit_types t WHERE t.code = gdos.permit_type) AS permit_type_name,
    ( SELECT t.issuing_authority FROM permit_types t WHERE t.code = gdos.permit_type) AS issuing_authority
   FROM gdos;$b1$);
  EXECUTE 'CREATE OR REPLACE VIEW client.gdos AS ' || n;
END $estep3_0$;

-- customer.permits
DO $estep3_1$
DECLARE
  d text := pg_get_viewdef('customer.permits'::regclass, true);
  n text;
BEGIN
  IF md5(d) <> '297d4872ec473a729112724270541b89' THEN RAISE EXCEPTION 'permits: customer.permits changed since 2026-11-02 (md5 %)', md5(d); END IF;
  n := d;
  IF (length(n) - length(replace(n, $a0$    'Grease Trap'::text AS area,$a0$, ''))) / length($a0$    'Grease Trap'::text AS area,$a0$) <> 1 THEN RAISE EXCEPTION 'permits: customer.permits anchor 0 not found 1 time(s)'; END IF;
  n := replace(n, $a0$    'Grease Trap'::text AS area,$a0$, $b0$        CASE
            WHEN g.permit_type = 'GDO'::text THEN 'Grease Trap'::text
            ELSE pt.name
        END AS area,$b0$);
  IF (length(n) - length(replace(n, $a1$        END AS frequency_source
   FROM gdos g
     JOIN clients c ON c.id = g.client_id$a1$, ''))) / length($a1$        END AS frequency_source
   FROM gdos g
     JOIN clients c ON c.id = g.client_id$a1$) <> 1 THEN RAISE EXCEPTION 'permits: customer.permits anchor 1 not found 1 time(s)'; END IF;
  n := replace(n, $a1$        END AS frequency_source
   FROM gdos g
     JOIN clients c ON c.id = g.client_id$a1$, $b1$        END AS frequency_source,
    g.permit_type,
    pt.name AS permit_type_name,
    pt.issuing_authority
   FROM gdos g
     JOIN permit_types pt ON pt.code = g.permit_type
     JOIN clients c ON c.id = g.client_id$b1$);
  EXECUTE 'CREATE OR REPLACE VIEW customer.permits AS ' || n;
END $estep3_1$;

-- client.upsert_gdo_permit
DO $estep3_2$
DECLARE
  d text := pg_get_functiondef('client.upsert_gdo_permit(bigint,bigint,jsonb)'::regprocedure);
  n text;
BEGIN
  IF md5(d) <> 'af1cca9b28b89453e2705d4da81f133b' THEN RAISE EXCEPTION 'permits: client.upsert_gdo_permit changed since 2026-11-02 (md5 %)', md5(d); END IF;
  n := d;
  IF (length(n) - length(replace(n, $a0$    'permit_document_path','status','notes','property_id','client_location_id'
  ];$a0$, ''))) / length($a0$    'permit_document_path','status','notes','property_id','client_location_id'
  ];$a0$) <> 1 THEN RAISE EXCEPTION 'permits: client.upsert_gdo_permit anchor 0 not found 1 time(s)'; END IF;
  n := replace(n, $a0$    'permit_document_path','status','notes','property_id','client_location_id'
  ];$a0$, $b0$    'permit_document_path','status','notes','property_id','client_location_id',
    'permit_type','permit_effective'   -- 2026-11-02, permits for every county
  ];$b0$);
  IF (length(n) - length(replace(n, $a1$  -- ⚠ BUG 3 FIX. Upper bound.$a1$, ''))) / length($a1$  -- ⚠ BUG 3 FIX. Upper bound.$a1$) <> 1 THEN RAISE EXCEPTION 'permits: client.upsert_gdo_permit anchor 1 not found 1 time(s)'; END IF;
  n := replace(n, $a1$  -- ⚠ BUG 3 FIX. Upper bound.$a1$, $b1$  -- 2026-11-02 (permits one table): the type must be a live permit type; the effective date is a bare date.
  -- Whether the number fits the type is checked for every writer by trg_aa_permit_number_matches_type.
  if p_patch ? 'permit_type' and not exists (
       select 1 from public.permit_types t
        where t.code = btrim(coalesce(p_patch->>'permit_type','')) and t.status = 'ACTIVE') then
    raise exception 'Unknown permit type %. Pick one from the list.', coalesce(nullif(btrim(p_patch->>'permit_type'),''), '(blank)')
      using errcode = '22023';
  end if;
  if p_patch ? 'permit_effective'
     and nullif(p_patch->>'permit_effective','') is not null
     and p_patch->>'permit_effective' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'permit_effective must be a bare date YYYY-MM-DD (got %)',
      p_patch->>'permit_effective' using errcode = '22023';
  end if;

  -- ⚠ BUG 3 FIX. Upper bound.$b1$);
  IF (length(n) - length(replace(n, $a2$This is the DERM permit ceiling; typical values are 30, 60 or 90.$a2$, ''))) / length($a2$This is the DERM permit ceiling; typical values are 30, 60 or 90.$a2$) <> 1 THEN RAISE EXCEPTION 'permits: client.upsert_gdo_permit anchor 2 not found 1 time(s)'; END IF;
  n := replace(n, $a2$This is the DERM permit ceiling; typical values are 30, 60 or 90.$a2$, $b2$This is the permit''s cleaning ceiling; typical values are 30, 60 or 90.$b2$);
  IF (length(n) - length(replace(n, $a3$(a GDO is issued to a location, not a business)$a3$, ''))) / length($a3$(a GDO is issued to a location, not a business)$a3$) <> 1 THEN RAISE EXCEPTION 'permits: client.upsert_gdo_permit anchor 3 not found 1 time(s)'; END IF;
  n := replace(n, $a3$(a GDO is issued to a location, not a business)$a3$, $b3$(a permit is issued to a location, not a business)$b3$);
  IF (length(n) - length(replace(n, $a4$    -- 2026-09-22, Fred: "we cannot have a GDO number without having the GDO file."
    if nullif(btrim(coalesce(p_patch->>'permit_document_path','')),'') is null then
      raise exception 'Attach the permit document before saving. A GDO number cannot be recorded without its permit file.'
        using errcode = '22023';
    end if;
$a4$, ''))) / length($a4$    -- 2026-09-22, Fred: "we cannot have a GDO number without having the GDO file."
    if nullif(btrim(coalesce(p_patch->>'permit_document_path','')),'') is null then
      raise exception 'Attach the permit document before saving. A GDO number cannot be recorded without its permit file.'
        using errcode = '22023';
    end if;
$a4$) <> 1 THEN RAISE EXCEPTION 'permits: client.upsert_gdo_permit anchor 4 not found 1 time(s)'; END IF;
  n := replace(n, $a4$    -- 2026-09-22, Fred: "we cannot have a GDO number without having the GDO file."
    if nullif(btrim(coalesce(p_patch->>'permit_document_path','')),'') is null then
      raise exception 'Attach the permit document before saving. A GDO number cannot be recorded without its permit file.'
        using errcode = '22023';
    end if;
$a4$, $b4$    -- 2026-11-02, Fred: "the PDF is optional" for every permit type, GDO included. This replaces the 2026-09-22
    -- rule "we cannot have a GDO number without having the GDO file" (and its CHECK, dropped in 2026-11-02_1800).
$b4$);
  IF (length(n) - length(replace(n, $a5$      max_frequency_days, permit_document_path, status, notes, property_id, client_location_id
    ) values ($a5$, ''))) / length($a5$      max_frequency_days, permit_document_path, status, notes, property_id, client_location_id
    ) values ($a5$) <> 1 THEN RAISE EXCEPTION 'permits: client.upsert_gdo_permit anchor 5 not found 1 time(s)'; END IF;
  n := replace(n, $a5$      max_frequency_days, permit_document_path, status, notes, property_id, client_location_id
    ) values ($a5$, $b5$      max_frequency_days, permit_document_path, status, notes, property_id, client_location_id,
      permit_type, permit_effective
    ) values ($b5$);
  IF (length(n) - length(replace(n, $a6$      nullif(p_patch->>'client_location_id','')::bigint
    )
    returning * into v_row;$a6$, ''))) / length($a6$      nullif(p_patch->>'client_location_id','')::bigint
    )
    returning * into v_row;$a6$) <> 1 THEN RAISE EXCEPTION 'permits: client.upsert_gdo_permit anchor 6 not found 1 time(s)'; END IF;
  n := replace(n, $a6$      nullif(p_patch->>'client_location_id','')::bigint
    )
    returning * into v_row;$a6$, $b6$      nullif(p_patch->>'client_location_id','')::bigint,
      coalesce(nullif(btrim(p_patch->>'permit_type'),''), 'GDO'),
      nullif(p_patch->>'permit_effective','')::date
    )
    returning * into v_row;$b6$);
  IF (length(n) - length(replace(n, $a7$                                else g.client_location_id end
    where g.id = p_gdo_id$a7$, ''))) / length($a7$                                else g.client_location_id end
    where g.id = p_gdo_id$a7$) <> 1 THEN RAISE EXCEPTION 'permits: client.upsert_gdo_permit anchor 7 not found 1 time(s)'; END IF;
  n := replace(n, $a7$                                else g.client_location_id end
    where g.id = p_gdo_id$a7$, $b7$                                else g.client_location_id end,
      permit_type = case when p_patch ? 'permit_type'
                         then btrim(p_patch->>'permit_type') else g.permit_type end,
      permit_effective = case when p_patch ? 'permit_effective'
                              then nullif(p_patch->>'permit_effective','')::date
                              else g.permit_effective end
    where g.id = p_gdo_id$b7$);
  EXECUTE n;
  IF pg_get_functiondef('client.upsert_gdo_permit(bigint,bigint,jsonb)'::regprocedure) <> n THEN RAISE EXCEPTION 'permits: client.upsert_gdo_permit re-read differs from the edited text'; END IF;
END $estep3_2$;

-- client.permit_types: the type picker
CREATE VIEW client.permit_types AS
  SELECT t.code, t.name, t.issuing_authority, t.number_pattern, t.reads_pdf
    FROM public.permit_types t
   WHERE t.status = 'ACTIVE';
COMMENT ON VIEW client.permit_types IS 'Live permit types for the Client App''s Add permit picker (2026-11-02).';
REVOKE ALL ON client.permit_types FROM PUBLIC, anon, authenticated;
GRANT SELECT ON client.permit_types TO authenticated, service_role;

-- VERIFY
DO $verify$
DECLARE g int; n int;
BEGIN
  -- client.gdos: the original 17 columns move only on row 141 (is_placeholder true -> false)
  SELECT count(*) INTO g FROM (SELECT r FROM p3_cg EXCEPT ALL
    SELECT row(id, client_id, gdo_number, location_label, property_id, permit_expiration, permit_document_path, status, notes,
               created_at, updated_at, max_frequency_days, client_location_id, permit_thumbnail_path, is_placeholder, nickname,
               display_label)::text FROM client.gdos) x;
  SELECT count(*) INTO n FROM (SELECT row(id, client_id, gdo_number, location_label, property_id, permit_expiration, permit_document_path,
               status, notes, created_at, updated_at, max_frequency_days, client_location_id, permit_thumbnail_path, is_placeholder,
               nickname, display_label)::text r FROM client.gdos EXCEPT ALL SELECT r FROM p3_cg) x;
  IF g <> 1 OR n <> 1 OR EXISTS (SELECT 1 FROM client.gdos WHERE id = 141 AND is_placeholder) THEN
    RAISE EXCEPTION 'permits step 3 VERIFY: client.gdos gone %, new % (predicted 1 / 1, row 141 is_placeholder false)', g, n;
  END IF;
  IF EXISTS (SELECT 1 FROM client.gdos WHERE permit_number IS DISTINCT FROM gdo_number OR permit_type_name IS NULL OR issuing_authority IS NULL) THEN
    RAISE EXCEPTION 'permits step 3 VERIFY: client.gdos new columns are not filled';
  END IF;
  -- customer.permits: the original 15 columns move only on the PSO row (area), and every GDO stays 'Grease Trap'
  SELECT count(*) INTO g FROM (SELECT r FROM p3_cp EXCEPT ALL
    SELECT row(id, client_id, permit_number, area, frequency, permit_url, "position", property_id, location_label, permit_expiration,
               max_frequency_days, over_gdo_max, our_frequency_days, compliant, frequency_source)::text FROM customer.permits) x;
  SELECT count(*) INTO n FROM (SELECT row(id, client_id, permit_number, area, frequency, permit_url, "position", property_id, location_label,
               permit_expiration, max_frequency_days, over_gdo_max, our_frequency_days, compliant, frequency_source)::text r
          FROM customer.permits EXCEPT ALL SELECT r FROM p3_cp) x;
  IF g > 1 OR n <> g OR EXISTS (SELECT 1 FROM customer.permits WHERE permit_type = 'GDO' AND area <> 'Grease Trap')
     OR EXISTS (SELECT 1 FROM customer.permits WHERE permit_type <> 'GDO' AND area = 'Grease Trap') THEN
    RAISE EXCEPTION 'permits step 3 VERIFY: customer.permits gone %, new % (predicted at most the PSO row)', g, n;
  END IF;
  -- grants unchanged, the new view closed to anon
  IF EXISTS (SELECT 1 FROM p3_acl a JOIN pg_class c ON c.oid = a.oid WHERE c.relacl::text IS DISTINCT FROM a.acl) THEN
    RAISE EXCEPTION 'permits step 3 VERIFY: client.gdos or customer.permits grants changed';
  END IF;
  IF has_table_privilege('anon', 'client.permit_types', 'SELECT') OR NOT has_table_privilege('authenticated', 'client.permit_types', 'SELECT')
     OR (SELECT count(*) FROM client.permit_types) <> 3 THEN
    RAISE EXCEPTION 'permits step 3 VERIFY: client.permit_types grants or rows are wrong';
  END IF;
  IF position('Attach the permit document before saving' in pg_get_functiondef('client.upsert_gdo_permit(bigint,bigint,jsonb)'::regprocedure)) > 0 THEN
    RAISE EXCEPTION 'permits step 3 VERIFY: the RPC still requires the PDF';
  END IF;
END $verify$;

COMMIT;
