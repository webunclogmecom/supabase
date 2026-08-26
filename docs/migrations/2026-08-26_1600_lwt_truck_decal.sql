-- 2026-08-26_1600_lwt_truck_decal.sql
--
-- WHY (Jonathan Veras, 2026-08-25, #new-app-issues, thread on p1787661000342979):
--   "the decal per row, or a truck-name -> decal map. Everything we resolve quantity from is keyed
--    on decals (C1184 -> 3,800, C0976 -> 2,000 ...), and the payload only carries truck names.
--    Right now the connected fetch correctly refuses every ticket for unresolved gallons, so the
--    button works but can't generate a month until that field exists."
--
-- WHAT: adds ONE nullable column, derm.v_lwt_monthly_rows.truck_decal, the vehicle's ACTIVE
--       Miami-Dade decal. Nothing else in the view changes.
--
-- 🛑 THE COLUMN IS APPENDED LAST, AND IT HAS TO BE. CREATE OR REPLACE VIEW can only ADD columns at
--    the END of the select list. Putting truck_decal next to truck_capacity_gallons, where it
--    belongs semantically, fails with:
--        ERROR 42P16: cannot change name of view column "gallons" to "truck_decal"
--        HINT: Use ALTER VIEW ... RENAME COLUMN ...
--    Postgres reads a mid-list insert as a RENAME of whatever occupied that position. If you ever
--    need it moved for readability, that is a DROP + CREATE, which discards grants (see
--    reference_drop_view_discards_grants) and is not worth it for column order.
--
-- 🛑 FAN-OUT IS IMPOSSIBLE, NOT MERELY ABSENT. public.vehicle_decals carries
--    vehicle_decals_vehicle_jurisdiction_uniq UNIQUE (vehicle_id, jurisdiction), so a LEFT JOIN
--    pinned to a single jurisdiction cannot duplicate a row. This matters: the view is strictly
--    one row per visit (700 rows / 700 distinct visit_id today) and a Postman assertion exists
--    solely to catch a join fan-out, because a duplicated row would double the reported activity.
--
-- 🛑 MIAMI-DADE ONLY, ON PURPOSE. The monthly LWT form is a Miami-Dade form. The Broward decal is
--    deliberately NOT exposed: which decal a Broward-offload row should carry is entangled with the
--    scope question ("does a Dade pickup that offloaded in Broward belong on this form?"), which
--    Jonathan has referred to Yan and which is NOT settled. Exposing a second decal now would
--    invite a caller to answer that question by accident.
--
-- ⚠ 51 OF 700 ROWS WILL CARRY NULL, AND THAT IS THE HONEST ANSWER, NOT A GAP TO PAPER OVER:
--     Cloggy   43 rows / 27 in-scope tickets, offloads 2026-01-15 .. 2026-08-20, no decal in ANY
--              jurisdiction, vehicle status ACTIVE, 126 gal tank
--     (none)    6 rows with no truck at all
--     Cloggy    2 rows out of scope
--    Either Cloggy is not a permitted LWT vehicle, in which case those tickets may not belong on
--    the form at all, or the decal is missing from our data. That is a question for Diego and it
--    is being asked. A null here makes the caller refuse the ticket, which is correct; inventing a
--    decal would put a wrong permit number on a county filing.
--
-- ⚠ NO TEMPORAL VALIDITY. vehicle_decals has no valid_from/valid_to. If a decal is ever replaced,
--    historical months will report the CURRENT decal, not the one that was valid at the time.
--    Harmless today (4 decal rows, all ACTIVE, none ever replaced) and a real trap the first time
--    a truck is re-permitted. Do not assume a filed month is reproducible across a decal change.
--
-- ⚠ THIS IS NOT THE FILED QUANTITY. Jonathan, same thread: "The county invoice bills actual
--    gallons per manifest -- 828837 is 3,800 on the invoice, which as you noted matches no truck --
--    and the form's fee is computed from those gallons. So decal capacity can't fill Quantity."
--    Verified here: ticket 828837 is Moises / decal C1184 / grease_tank_capacity_gallons 9000,
--    against 3,800 on the county invoice. truck_capacity_gallons is an INTERNAL fleet fact.
--    gallons stays NULL (0 non-null of 700) because we store no measured volume.
--
-- ROLLBACK: re-run the previous definition; this is a pure column addition to a view.

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
    NULL::integer AS gallons,
    m.id AS manifest_id,
    v.id AS visit_id,
    vd.decal_number AS truck_decal
   FROM derm_manifests m
     JOIN manifest_visits mv ON mv.manifest_id = m.id
     JOIN visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL
     JOIN clients c ON c.id = m.client_id
     LEFT JOIN properties p ON p.id = v.property_id
     LEFT JOIN vehicles ve ON ve.id = v.vehicle_id
     LEFT JOIN vehicle_decals vd ON vd.vehicle_id = ve.id AND vd.jurisdiction = 'Miami-Dade'::text AND vd.status = 'ACTIVE'::text
     LEFT JOIN disposal_facilities df ON df.id = m.disposal_facility_id
  WHERE m.deleted_at IS NULL;
