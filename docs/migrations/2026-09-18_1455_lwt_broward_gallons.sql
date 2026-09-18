-- 2026-09-18_1455_lwt_broward_gallons.sql
--
-- WHY (Slack #C0B15CHQ1D4, 2026-09-18; design + 13-agent verification in
-- docs/superpowers/specs/2026-09-18-lwt-broward-gallons-design.md):
--   Jonathan is adding Broward-disposed tickets to the Miami-Dade LWT monthly report (flipping the
--   2026-08-20 "the county where the load is disposed decides" rule). Yan: "yes for the miami dade
--   pick up and Broward dump we need the gallons per client to add then to the report", and those
--   gallons pay the $0.00419/gal fee. Jonathan: "for Broward-disposed tickets specifically, the
--   flattener already reads gallons off each row if you send it. Today those rows return null (by
--   design, for Dade tickets that use the decal)." Fred: "we can use the Grease Trap Size from our
--   DB to fill it." Then, on the verified design: "Go with option A."
--
-- WHAT: derm.v_lwt_monthly_rows, CREATE OR REPLACE only. Column 18 `gallons` stops being
--   NULL::integer and becomes, on rows of a ticket offloaded OUTSIDE Miami-Dade only:
--       COALESCE(NULLIF(visit property grease_trap_size_gallons, 0), client Pumping
--                service_configs.equipment_size_gallons::integer)
--   and stays NULL on every row of a Miami-Dade-offload (white) ticket. Column 22 `gallons_source`
--   (text: 'grease_trap_size' | 'service_config_size' | null) is APPENDED LAST. The COMMENT is
--   rewritten. Nothing else in the view moves: the body is the live pg_get_viewdef (md5
--   8fa4e280baec13287e40a5706ee658fc, pinned below) with exactly those edits.
--
-- 🛑 THE ::integer CAST ON THE FALLBACK ARM IS MANDATORY. properties.grease_trap_size_gallons is
--    integer, service_configs.equipment_size_gallons is numeric, and COALESCE(integer, numeric) is
--    numeric: CREATE OR REPLACE then refuses with 42P16 "cannot change data type of view column
--    gallons from integer to numeric" (probed rolled-back on the live view, 2026-09-18). All 121
--    service_configs sizes are whole numbers today, so the cast is lossless now; it rounds half away
--    from zero if a fraction ever lands there.
--
-- 🛑 THE FALLBACK IS A SCALAR LATERAL PINNED TO service_type = 'Pumping', NEVER A PLAIN LEFT JOIN
--    ON client_id. 63 clients hold unsized Cleaning / Warranty of Drainage rows beside their Pumping
--    row; a plain join fans the view from 784 to 1,119 rows (probed). The UNIQUE is
--    (client_id, service_type), so the LATERAL returns at most one row per client.
--
-- 🛑 0 IS TREATED AS EMPTY IN BOTH ARMS. properties_grease_trap_size_chk admits 0..20000 and
--    client.update_property_capacity accepts 0, while the estate defines 0 as Jobber's empty for a
--    numeric custom field (CLAUDE.md, the custom-field shadow). Without NULLIF a typed 0 would be
--    served as 0 gallons with a source label. Both columns hold zero 0-values today (latent).
--
-- 🛑 WHITE (MIAMI-DADE OFFLOAD) ROWS STAY NULL ON PURPOSE. Jonathan resolves a white ticket's
--    quantity from the county invoice by decal (C1184 = 3,800, C0976 = 2,000; July filed as exactly
--    7 x 3,800 + 8 x 2,000), and his flattener takes ANY non-null row gallons over that. Filling
--    white rows would silently change his Dade numbers. 444 white rows sit on properties WITH a size,
--    so the gate is load-bearing and VERIFY 4 asserts it.
--
-- ⚠ WHAT THE NUMBER IS. A grease trap CAPACITY (the Jobber "Grease Trap Size" custom field, two-way
--    synced, edited in the Client App), not a measured volume: we store none, and the Dade
--    quantities on the same form are decal constants hand-written as "approximately N gallons" on
--    the WWTP receipt. Both arms descend from the same Airtable "Size GT in Gallon" (117 property
--    values were seeded from service_configs on 2026-08-13); the label tells maintained (property,
--    edited since) from frozen (service_configs, no live writer since Airtable retired).
--
-- ⚠ THE CONSUMER MUST CHANGE TOO, OR THIS FIELD IS MISREAD. Read from his generator
--    (webunclogmecom/unclogme-gdo-report-bot, main @ 2026-09-17): _flatten_ticket returns None on
--    offload_in_dade=false; row gallons are collected as a SET and used only when exactly ONE distinct
--    value exists (nulls ignored); with no value and one decal it falls back to the Dade decal
--    constant; an unresolved ticket blocks the whole xlsx. Per-client values therefore need him to
--    SUM the pickup_in_dade rows per ticket, treat a null row as unresolved, and never decal-fallback
--    on a Broward ticket. rpa-derm-monthly ships a ticket-head dade_pickup_gallons {total, rows,
--    rows_missing, complete} in the same change so that rule lives in one place.
--
-- ⚠ DATED CENSUS (moves with every Client App edit, do not quote as an invariant): 784 view rows;
--    153 rows gain a value, all on yellow tickets; August 2026 in-scope yellow rows 31, of which 24
--    get a value (22 grease_trap_size, 2 service_config_size: 192-FRK 25, 233-AH 2,000) and 7 stay
--    null (186-PV, 306-16, 293-ALC, 249-LOU, 014-JOY, 226-JER, 309-KEB hold no size anywhere).
--    Oddities served as-is: 189-FRE 250 gal on Cloggy (126 gal truck, in scope, 310590); 010-CS
--    4,000 gal on Moises (3,840, out of scope); 215-G7 4 gal (typed 2026-09-07, legacy 60, out of
--    scope); 061-TCE 10 gal (in scope, 312433).
--
-- ⚠ THE 2026-08-26_1842 COMMENT CHECK ("MEASURED gallons per manifest" must be present) is a dated
--    check inside a dated migration and is superseded here: that wording was a mischaracterisation
--    (the Dade quantities are decal constants, see above). The new COMMENT says so.
--
-- ROLLBACK: a second CREATE OR REPLACE with the previous body (2026-08-26_1600) plus
--   `NULL::text AS gallons_source` appended, because CREATE OR REPLACE cannot remove a column.
--   NEVER `DROP VIEW`: it cascades to derm.v_lwt_ticket_reported and discards both views' grants
--   (service_role SELECT here; service_role + authenticated SELECT there), and every month of the
--   endpoint, Dade included, would answer 500 monthly_query_failed / reported_lookup_failed.
--
-- AUDIT (rule 8): a view; no trigger applies. GRANTS: none touched, CREATE OR REPLACE keeps
--   {postgres=arwdDxtm/postgres,service_role=r/postgres}; VERIFY 8 asserts it. No NOTIFY pgrst is
--   needed: the pgrst_ddl_watch event trigger reloads the schema cache on ddl_command_end.

begin;

-- ---------------------------------------------------------------------------------------------
-- PART 0: the body below was copied from the LIVE definition, never retyped. Refuse to run if the
-- live view has moved since it was copied (another session, or a later migration).
-- ---------------------------------------------------------------------------------------------
do $$
declare v_md5 text;
begin
  select md5(pg_get_viewdef('derm.v_lwt_monthly_rows'::regclass, true)) into v_md5;
  if v_md5 <> '8fa4e280baec13287e40a5706ee658fc' then
    raise exception 'derm.v_lwt_monthly_rows is not the definition this migration was spliced from (md5 %); re-splice from pg_get_viewdef before applying', v_md5;
  end if;
end $$;

-- PART 1: snapshot the rows the view serves today, for the byte-for-byte comparison in VERIFY.
create temp table lwt_old on commit drop as
  select * from derm.v_lwt_monthly_rows;

-- ---------------------------------------------------------------------------------------------
-- PART 2: the view. Edits against the live body, and ONLY these:
--   (a) `NULL::integer AS gallons`               -> the gated CASE below (column 18, still integer)
--   (b) `... AS truck_decal`                      -> followed by the appended `gallons_source` (column 22)
--   (c) a LEFT JOIN LATERAL scf before the WHERE  -> the Pumping service_configs fallback
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW derm.v_lwt_monthly_rows AS
 SELECT COALESCE(m.white_manifest_number, m.yellow_ticket_number) AS ticket_number,
        CASE
            WHEN m.white_manifest_number IS NOT NULL THEN 'white'::text
            ELSE 'yellow'::text
        END AS ticket_kind,
    m.white_manifest_number IS NOT NULL AS offload_in_dade,
    m.dump_ticket_date AS offload_date,
    df.name AS disposal_facility,
    v.visit_date AS pickup_date,
    c.client_code,
    replace(replace(replace(replace(replace(replace(replace(c.name, chr(8217), ''''::text), chr(8216), ''''::text), chr(8220), '"'::text), chr(8221), '"'::text), chr(8211), '-'::text), chr(8212), '-'::text), chr(160), ' '::text) AS client_name,
    p.address,
    p.city,
        CASE
            WHEN p.state IS NULL THEN NULL::text
            WHEN upper(translate(derm.fn_normalize_state_input(p.state), chr(201) || chr(233), 'Ee'::text)) = ANY (ARRAY['FL'::text, 'FLORIDA'::text]) THEN 'FL'::text
            WHEN upper(translate(derm.fn_normalize_state_input(p.state), chr(201) || chr(233), 'Ee'::text)) = ANY (ARRAY['CA'::text, 'CALIFORNIA'::text]) THEN 'CA'::text
            WHEN upper(translate(derm.fn_normalize_state_input(p.state), chr(201) || chr(233), 'Ee'::text)) = ANY (ARRAY['NY'::text, 'NEW YORK'::text]) THEN 'NY'::text
            WHEN upper(translate(derm.fn_normalize_state_input(p.state), chr(201) || chr(233), 'Ee'::text)) = ANY (ARRAY['QC'::text, 'QUEBEC'::text]) THEN 'QC'::text
            WHEN derm.fn_normalize_state_input(p.state) ~ '^[A-Za-z]{2}$'::text THEN upper(derm.fn_normalize_state_input(p.state))
            ELSE derm.fn_normalize_state_input(p.state)
        END AS state,
    p.zip,
    p.county,
    COALESCE(p.county = 'Dade'::text, false) AS pickup_in_dade,
    COALESCE(p.county = 'Dade'::text, false) OR m.white_manifest_number IS NOT NULL AS in_scope,
    ve.name AS truck,
    ve.grease_tank_capacity_gallons AS truck_capacity_gallons,
        CASE
            WHEN m.white_manifest_number IS NULL THEN COALESCE(NULLIF(p.grease_trap_size_gallons, 0), scf.sc_size)
            ELSE NULL::integer
        END AS gallons,
    m.id AS manifest_id,
    v.id AS visit_id,
    vd.decal_number AS truck_decal,
        CASE
            WHEN m.white_manifest_number IS NOT NULL THEN NULL::text
            WHEN NULLIF(p.grease_trap_size_gallons, 0) IS NOT NULL THEN 'grease_trap_size'::text
            WHEN scf.sc_size IS NOT NULL THEN 'service_config_size'::text
            ELSE NULL::text
        END AS gallons_source
   FROM derm_manifests m
     JOIN manifest_visits mv ON mv.manifest_id = m.id
     JOIN visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL
     JOIN clients c ON c.id = m.client_id
     LEFT JOIN properties p ON p.id = v.property_id
     LEFT JOIN vehicles ve ON ve.id = v.vehicle_id
     LEFT JOIN vehicle_decals vd ON vd.vehicle_id = ve.id AND vd.jurisdiction = 'Miami-Dade'::text AND vd.status = 'ACTIVE'::text
     LEFT JOIN disposal_facilities df ON df.id = m.disposal_facility_id
     LEFT JOIN LATERAL ( SELECT sc.equipment_size_gallons::integer AS sc_size
           FROM service_configs sc
          WHERE sc.client_id = m.client_id AND sc.service_type = 'Pumping'::text AND sc.equipment_size_gallons > 0::numeric
          ORDER BY sc.id
         LIMIT 1) scf ON true
  WHERE m.deleted_at IS NULL;

-- PART 3: the COMMENT. Everything but the gallons sentences is the 2026-08-26_1842 text verbatim.
comment on view derm.v_lwt_monthly_rows is
  'One row per PICKUP ACTIVITY for the Miami-Dade LWT monthly filing, served by rpa-derm-monthly. '
  'in_scope = pickup county is Dade OR the ticket offloaded in Miami-Dade, evaluated PER ROW '
  'because 20 tickets mix counties. pickup_date is visits.visit_date and NEVER '
  'derm_manifests.service_date, a misnomer holding the dump date. '
  'gallons (since 2026-09-18, Yan): NULL on every row of a ticket offloaded in Miami-Dade (white), '
  'whose filed quantity the consumer resolves per manifest from the county invoice by decal '
  '(C1184 3,800 / C0976 2,000, hand-written as approximately on the WWTP receipt: a decal constant, '
  'not a measured volume). On a ticket offloaded outside Miami-Dade (yellow, Broward) it is the '
  'grease trap CAPACITY of the visit property (properties.grease_trap_size_gallons, the Jobber '
  'Grease Trap Size, two-way synced), else the client Pumping service_configs.equipment_size_gallons, '
  'else NULL; 0 counts as empty; gallons_source names the arm (grease_trap_size / '
  'service_config_size / NULL). A capacity, not a measured volume: we store none. NEVER fill white '
  'rows: the consumer takes any non-null row value over the invoice. '
  'NOTHING on the form is computed from TRUCK capacity or from the decal. '
  'truck_capacity_gallons is an internal fleet fact, served for sanity-checking a load only. '
  'truck_decal is the vehicle ACTIVE Miami-Dade permit number; null means we hold no decal and the '
  'caller must refuse the ticket rather than guess. '
  'truck_decals on the served payload is MANIFEST-grained while rows is filing-grained, so it can '
  'name a decal appearing on no row served; file from the row own truck_decal. '
  'state is mapped to USPS two-letter by an EXPLICIT list with unrecognised values passing through '
  'verbatim, so a non-Florida property can never be silently relabelled on a compliance form. '
  'address, city, state, zip and county are NULL TOGETHER on the no-property case (14 of 700 rows '
  'on 2026-08-26), never half-populated. '
  'client_name has typographic punctuation folded to ASCII; accented LETTERS are deliberately '
  'preserved because they are the correct spelling (Chateau, Espanola Way) and stripping them '
  'would misspell a regulator-facing document.';

-- ---------------------------------------------------------------------------------------------
-- PART 4: VERIFY. Every assertion mirrors the rule or compares against the snapshot; no literal
-- row counts. Raises (and therefore rolls the whole transaction back) on any failure.
-- ---------------------------------------------------------------------------------------------
do $$
declare
  n_old bigint; n_new bigint;
  d_ab bigint; d_ba bigint; d_ctl bigint;
  n_gal bigint; n_rule bigint;
  n_white_filled bigint; n_white_anchor bigint;
  n_mismatch bigint; n_min integer;
  n_src_prop bigint; n_src_sc bigint;
  n_cols int; c18 text; c22 text;
  v_acl text; n_dep bigint; v_comment text;
begin
  -- 1. same row count as before
  select count(*) into n_old from lwt_old;
  select count(*) into n_new from derm.v_lwt_monthly_rows;
  if n_old <> n_new then
    raise exception 'VERIFY 1: row count moved % -> % (a fan-out or a lost join)', n_old, n_new;
  end if;

  -- 2. the 20 columns other than gallons are byte-identical, both directions
  select count(*) into d_ab from (
    select ticket_number, ticket_kind, offload_in_dade, offload_date, disposal_facility, pickup_date,
           client_code, client_name, address, city, state, zip, county, pickup_in_dade, in_scope,
           truck, truck_capacity_gallons, manifest_id, visit_id, truck_decal
      from lwt_old
    except all
    select ticket_number, ticket_kind, offload_in_dade, offload_date, disposal_facility, pickup_date,
           client_code, client_name, address, city, state, zip, county, pickup_in_dade, in_scope,
           truck, truck_capacity_gallons, manifest_id, visit_id, truck_decal
      from derm.v_lwt_monthly_rows) x;
  select count(*) into d_ba from (
    select ticket_number, ticket_kind, offload_in_dade, offload_date, disposal_facility, pickup_date,
           client_code, client_name, address, city, state, zip, county, pickup_in_dade, in_scope,
           truck, truck_capacity_gallons, manifest_id, visit_id, truck_decal
      from derm.v_lwt_monthly_rows
    except all
    select ticket_number, ticket_kind, offload_in_dade, offload_date, disposal_facility, pickup_date,
           client_code, client_name, address, city, state, zip, county, pickup_in_dade, in_scope,
           truck, truck_capacity_gallons, manifest_id, visit_id, truck_decal
      from lwt_old) x;
  if d_ab <> 0 or d_ba <> 0 then
    raise exception 'VERIFY 2: the untouched columns differ (old-new %, new-old %)', d_ab, d_ba;
  end if;
  -- positive control: the same comparison with one column perturbed must be non-zero
  select count(*) into d_ctl from (
    select ticket_number, client_code || 'x' from lwt_old
    except all
    select ticket_number, client_code from derm.v_lwt_monthly_rows) x;
  if d_ctl = 0 then
    raise exception 'VERIFY 2 control: a perturbed comparison returned 0, so the EXCEPT ALL proves nothing';
  end if;

  -- 3. gallons follows the rule exactly: recomputed here from the base tables, not from the view
  select count(gallons) into n_gal from derm.v_lwt_monthly_rows;
  select count(*) into n_rule
    from derm_manifests m
    join manifest_visits mv on mv.manifest_id = m.id
    join visits v on v.id = mv.visit_id and v.deleted_at is null
    left join properties p on p.id = v.property_id
   where m.deleted_at is null
     and m.white_manifest_number is null
     and (nullif(p.grease_trap_size_gallons, 0) is not null
          or exists (select 1 from service_configs sc
                      where sc.client_id = m.client_id and sc.service_type = 'Pumping'
                        and sc.equipment_size_gallons > 0));
  if n_gal <> n_rule then
    raise exception 'VERIFY 3: % rows carry gallons but the rule recomputed from the base tables gives %', n_gal, n_rule;
  end if;
  if n_gal = 0 then
    raise exception 'VERIFY 3: zero rows carry gallons; the instrument is untested';
  end if;

  -- 4. no white (Miami-Dade offload) row carries a value, and the gate had something to hold back
  select count(*) filter (where gallons is not null),
         count(*) filter (where exists (select 1 from visits v join properties p on p.id = v.property_id
                                         where v.id = r.visit_id and p.grease_trap_size_gallons > 0))
    into n_white_filled, n_white_anchor
    from derm.v_lwt_monthly_rows r where offload_in_dade;
  if n_white_filled <> 0 then
    raise exception 'VERIFY 4: % white rows carry gallons; the offload gate is broken', n_white_filled;
  end if;
  if n_white_anchor = 0 then
    raise exception 'VERIFY 4 anchor: no white row sits on a sized property, so the gate was never exercised';
  end if;

  -- 5. gallons and gallons_source are null together, and a value is always positive
  select count(*) into n_mismatch from derm.v_lwt_monthly_rows
   where (gallons is null) <> (gallons_source is null);
  if n_mismatch <> 0 then
    raise exception 'VERIFY 5: % rows have gallons and gallons_source disagreeing on null', n_mismatch;
  end if;
  select min(gallons) into n_min from derm.v_lwt_monthly_rows;
  if n_min is null or n_min <= 0 then
    raise exception 'VERIFY 5: min(gallons) is % (0 must read as empty)', n_min;
  end if;

  -- 6. both arms fire at least once (a fallback that never fires is indistinguishable from a broken one)
  select count(*) filter (where gallons_source = 'grease_trap_size'),
         count(*) filter (where gallons_source = 'service_config_size')
    into n_src_prop, n_src_sc from derm.v_lwt_monthly_rows;
  if n_src_prop = 0 or n_src_sc = 0 then
    raise exception 'VERIFY 6: arms fired grease_trap_size=% service_config_size=%; both must be > 0', n_src_prop, n_src_sc;
  end if;

  -- 7. shape: 22 columns, gallons still integer at 18, gallons_source text at 22
  select count(*) into n_cols from pg_attribute
   where attrelid = 'derm.v_lwt_monthly_rows'::regclass and attnum > 0 and not attisdropped;
  select attname || ':' || format_type(atttypid, atttypmod) into c18 from pg_attribute
   where attrelid = 'derm.v_lwt_monthly_rows'::regclass and attnum = 18;
  select attname || ':' || format_type(atttypid, atttypmod) into c22 from pg_attribute
   where attrelid = 'derm.v_lwt_monthly_rows'::regclass and attnum = 22;
  if n_cols <> 22 or c18 <> 'gallons:integer' or c22 <> 'gallons_source:text' then
    raise exception 'VERIFY 7: shape is % columns, 18=%, 22=%', n_cols, c18, c22;
  end if;

  -- 8. grants untouched, the dependent view still reads, the comment landed
  select relacl::text into v_acl from pg_class where oid = 'derm.v_lwt_monthly_rows'::regclass;
  if v_acl <> '{postgres=arwdDxtm/postgres,service_role=r/postgres}' then
    raise exception 'VERIFY 8: relacl is %', v_acl;
  end if;
  select count(*) into n_dep from derm.v_lwt_ticket_reported;
  if n_dep = 0 then
    raise exception 'VERIFY 8: derm.v_lwt_ticket_reported returned 0 rows';
  end if;
  select obj_description('derm.v_lwt_monthly_rows'::regclass, 'pg_class') into v_comment;
  if v_comment !~ 'gallons_source' or v_comment ~* 'gallons is always null' then
    raise exception 'VERIFY 8: the view comment was not replaced';
  end if;

  raise notice 'VERIFY passed: rows %, gallons on % rows (property %, service_config %), white rows filled 0 of % anchored', n_new, n_gal, n_src_prop, n_src_sc, n_white_anchor;
end $$;

-- Summary for the operator (the Management API returns the last row-returning statement).
select
  (select count(*) from derm.v_lwt_monthly_rows)                                   as rows_total,
  (select count(gallons) from derm.v_lwt_monthly_rows)                             as rows_with_gallons,
  (select count(*) from derm.v_lwt_monthly_rows where gallons_source = 'grease_trap_size')    as from_property,
  (select count(*) from derm.v_lwt_monthly_rows where gallons_source = 'service_config_size') as from_service_config,
  (select count(*) from derm.v_lwt_monthly_rows
     where not offload_in_dade and in_scope and offload_date >= '2026-08-01' and offload_date < '2026-09-01') as aug_in_scope_yellow_rows,
  (select count(gallons) from derm.v_lwt_monthly_rows
     where not offload_in_dade and in_scope and offload_date >= '2026-08-01' and offload_date < '2026-09-01') as aug_in_scope_yellow_with_gallons,
  (select jsonb_agg(jsonb_build_object('t', ticket_number, 'c', client_code, 'g', gallons, 'truck', truck, 'in', in_scope) order by gallons, ticket_number)
     from derm.v_lwt_monthly_rows where gallons <= 25)                               as rows_at_or_below_25_gal;

commit;
