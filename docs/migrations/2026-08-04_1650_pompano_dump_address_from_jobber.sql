-- =====================================================================
-- 2026-08-04_1650  DUMP Pompano service address: re-sync from Jobber
-- =====================================================================
-- WHY
--   Fred: "For the DB and all the Apps, it seems we need to change the Address for
--   Pompano dump to 3100 North Powerline Road".
--
--   This is NOT a value to invent - JOBBER ALREADY HOLDS IT and our mirror is stale.
--   Read live from Jobber (GraphQL 2026-04-16), property
--   Z2lkOi8vSm9iYmVyL1Byb3BlcnR5LzExMTI2OTUxNw==, which is our properties.id 155:
--
--     street      "3100 n Powerline Road"
--     city        "Oakland Park"          <- NOT Pompano Beach
--     province    "Florida"
--     postalCode  "33309"                 <- NOT 33069
--     geoStatus   FOUND
--
--   Ours read '2401 North Powerline Road / Pompano Beach / 33069', last touched
--   2026-05-27. Jobber is canonical for addresses (rule #4), so this mirrors Jobber
--   EXACTLY rather than writing a prettier string - see the note on "n" below.
--
-- ⚠ THE CITY AND ZIP CHANGE TOO. Fred's message named only the street. Leaving
--   'Pompano Beach 33069' against a 3100 Powerline street would be internally
--   inconsistent AND would disagree with the master. Both come from the same Jobber read.
--
-- ⚠ WHY '3100 n Powerline Road' AND NOT '3100 North Powerline Road'.
--   Jobber stores the lowercase 'n'. We mirror it byte-for-byte so our copy stays
--   comparable to the master for drift checks, and so this row does not flip the first
--   time the property poll is ever switched on. If the spelled-out form is wanted, fix
--   it IN JOBBER and let it flow down - do not "tidy" it here, that just recreates drift.
--
-- 🛑 WHY OUR COPY WENT STALE, which is the bigger finding and is NOT fixed here:
--   `PROPERTY_UPDATE` HAS NEVER PRODUCED A SINGLE EVENT. scripts/sync/cron_jobber.js:280
--   declares `jobber_pull_properties: {entity:'property', topic:'PROPERTY_UPDATE'}`, but
--   no matching pg_cron job exists. Control: 446 CLIENT_UPDATE events in the last 24h,
--   so the poll harness itself works.
--   ⇒ A Jobber-side edit to any SERVICE property address never reaches us. BILLING
--   addresses do flow, because they ride CLIENT_UPDATE (webhook-jobber ~line 493) - which
--   is exactly why our billing row 553 already read '3100 n Powerline Road' while the
--   service row 155 did not. This is systemic across all ~824 properties, not Pompano-
--   specific, and enabling that poll would re-sync many rows at once. Fred's call.
--
-- 🛑 WHAT THIS DELIBERATELY DOES NOT TOUCH: latitude/longitude, and the hardcoded
--   Pompano geofence in public.dump_investigate (26.2632563,-80.1552085, radius 250 m),
--   which sits 726 m from Jobber's geocode of the new address. I could not establish the
--   true site location from our own data: there are 4 Pompano dump visits EVER, and
--   across 6,861 telemetry pings in the +/-3h windows, ZERO are within 250 m of EITHER
--   candidate (closest 2,062 m old / 1,925 m new). So that geofence has likely never
--   matched a real truck, and copying Jobber's geocode over it would swap one unverified
--   point for another. It needs a real observation, not a guess.
--
-- NO APP CHANGE IS NEEDED. All 7 live app bundles were walked to chunk closure with
--   positive controls firing: none contains '2401', 'Powerline', '33069' or '3100'. The
--   apps carry the site LABEL ("Pompano") and read the address from the DB.
--
-- AUDIT (rule #8): public.properties already carries an audit trigger, so this UPDATE is
--   recorded with app_source='sql'. Unchanged.
-- REVERSIBLE: yes - the pre-state is in the header above and in audit.logs.old_row.
-- =====================================================================

begin;

do $$
declare v_addr text; v_city text; v_zip text;
begin
  select address, city, zip into v_addr, v_city, v_zip from public.properties where id = 155;
  if not found then
    raise exception 'REFUSING: property 155 does not exist';
  end if;
  -- Idempotent + safe: proceed only from the known stale state, or if already correct.
  if (v_addr, v_city, v_zip) = ('3100 n Powerline Road', 'Oakland Park', '33309') then
    raise notice 'already correct - nothing to do';
  elsif (v_addr, v_city, v_zip) is distinct from ('2401 North Powerline Road', 'Pompano Beach', '33069') then
    raise exception 'REFUSING: property 155 is in an unexpected state (%, %, %) - re-read Jobber before writing',
      v_addr, v_city, v_zip;
  end if;
end $$;

update public.properties
   set address = '3100 n Powerline Road',
       city    = 'Oakland Park',
       zip     = '33309'
 where id = 155
   and (address, city, zip) is distinct from ('3100 n Powerline Road', 'Oakland Park', '33309');

-- ---------------------------------------------------------------------
-- ASSERTIONS
-- ---------------------------------------------------------------------
do $$
declare v_addr text; v_city text; v_zip text; v_state text; n int;
begin
  select address, city, zip, state into v_addr, v_city, v_zip, v_state
    from public.properties where id = 155;

  -- (a) the row now matches JOBBER byte-for-byte
  if (v_addr, v_city, v_zip) is distinct from ('3100 n Powerline Road', 'Oakland Park', '33309') then
    raise exception 'property 155 reads (%, %, %) - does not match Jobber', v_addr, v_city, v_zip;
  end if;
  if v_state is distinct from 'Florida' then
    raise exception 'property 155 state changed unexpectedly: %', v_state;
  end if;

  -- (b) NEGATIVE CONTROL: nothing else moved. The stale street must be gone from the
  --     whole table, and the sibling billing row must be untouched.
  select count(*) into n from public.properties where address ilike '%2401%Powerline%';
  if n <> 0 then raise exception '% propert(ies) still carry the old 2401 Powerline street', n; end if;

  select count(*) into n from public.properties
   where id = 553 and address = '3100 n Powerline Road' and city = 'Oakland Park' and zip = '33309';
  if n <> 1 then raise exception 'the billing row 553 was disturbed - it must be left exactly as it was'; end if;

  -- (c) the client still has exactly its two properties, and the dump-site client is intact
  select count(*) into n from public.properties where client_id = 76;
  if n <> 2 then raise exception 'DUMP Pompano should have 2 properties, has %', n; end if;

  -- (d) coordinates were NOT touched (this migration deliberately leaves the geofence
  --     question open - see the header)
  select count(*) into n from public.properties
   where id = 155 and latitude::text like '26.2632%' and longitude::text like '-80.1552%';
  if n <> 1 then
    raise exception 'property 155 coordinates changed - this migration must not touch them';
  end if;

  raise notice 'POMPANO ADDRESS OK - 155 mirrors Jobber, 553 untouched, coordinates untouched';
end $$;

commit;
