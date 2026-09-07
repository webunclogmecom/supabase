-- 2026-09-07_1338_broward_dump_bucket_resolvers.sql
--
-- STEP 1 of the Broward FDEP manifest chain. Read-only in effect: three new resolver functions, one
-- GRANT, and one appended view column. No data is written, no existing object changes behaviour.
--
-- WHY. Fred, 2026-09-07, settling D10 and D12:
--   "we select which dump facility is it for, and if it's for the Broward one, then we generate this
--    one, if it's for Miami-DADE then we can continue with the former"
--   "We need to have now the blackout just for the Miami-DADE dumps (DERM Addresses manifests) and
--    for Broward dumps we don't."
-- Every object downstream now has to ask "which dump was this?" and there is no safe, shared way to
-- ask. This migration creates one, before anything depends on it.
--
-- 🛑 THE VOCABULARY TRAP THIS EXISTS TO CLOSE. Five county vocabularies are live at once:
--   properties.county='Dade' · disposal_facilities.county='Miami-Dade' · vehicle_decals='Miami-Dade'
--   derm.manifests.jurisdiction='dade' · file_manifest takes the literal 'Miami-Dade'
-- A direct `=` between any two of them silently returns an empty set. public.fn_dump_county_bucket
-- is the only sanctioned comparison. It folds Palm Beach into BROWARD, which is Fred's ruling from
-- 2026-07-28 and is deliberate.
--
-- 🛑 WHY EVERY RESOLVER COALESCES **OUTSIDE** THE SUBQUERY, AND NOT INSIDE.
-- Written the natural way, `SELECT coalesce(fn_dump_county_bucket(df.county),'UNKNOWN') FROM ...
-- WHERE dm.id = $1`, a missing or soft-deleted manifest returns ZERO ROWS, so the function value is
-- NULL. Then `NULL <> 'BROWARD'` is NULL, the row is dropped by every caller's WHERE, and the
-- manifest is treated as Broward: the blackout is skipped on a Miami-Dade sheet. That is a
-- fail-OPEN on the exact failure this chain exists to prevent. Writing it as
-- `SELECT coalesce((SELECT ...), 'UNKNOWN')` makes the empty case 'UNKNOWN', which every caller
-- treats as DADE, which is fail-CLOSED. The verification block below asserts a bogus id returns
-- 'UNKNOWN' and never NULL.
--
-- ⚠ CONSEQUENCE OF THAT CHOICE, and it bit me while writing this file: because these functions can
-- never return NULL, you CANNOT chain them with COALESCE. `coalesce(fn_manifest_dump_bucket(x),
-- fn_ticket_dump_bucket(y))` is dead code, the second arm is unreachable. fn_folder_dump_bucket
-- therefore branches on `matched_manifest_id IS NOT NULL` explicitly.
--
-- 🛑 derm.address_row_map.white_manifest_number IS A MISNAMED TICKET KEY. It holds
-- COALESCE(white, yellow). Anyone who writes the obvious join from the column name,
-- `dm.white_manifest_number = r.white_manifest_number`, gets a clean, confident, WRONG answer.
-- Measured today, distinct folders resolvable:
--     COALESCE(white, yellow) join ....... 137 of 141
--     white-only join .................... 114 of 141   <- silently drops the Broward folders
-- A verification query using the same wrong join would pass. The control below asserts both numbers.
--
-- ⚠ dump_folder HAS FOUR SHAPES, so fn_folder_dump_bucket does NOT parse the string. Measured over
-- stamp_sheet_status + address_row_map: `windowN-sheetM` 79, `ticket-N` 47, `derm/N` 12,
-- `backfill-N` 1. A regex resolver would return UNKNOWN for the majority. It joins through
-- address_row_map instead, which is data rather than convention.
--
-- ⚠ btrim ON BOTH SIDES of the ticket comparison. 8 live manifests (ids 1840-1847) currently hold
-- '834986 ' with a trailing space, filed today by derm-tracker, and derm.stamp_sheet_status carries
-- the matching folder key 'ticket-834986 '. Those rows are NOT repaired here: that is step 2, which
-- has its own ordering hazard (a CHECK added before the trim freezes those 8 rows against
-- sent_to_client, edit_manifest and soft-delete). Until then, btrim keeps them resolvable.
--
-- WHAT 'MIXED' MEANS. A ticket or folder spanning both buckets returns 'MIXED'. Callers use
-- `<> 'BROWARD'`, so MIXED and UNKNOWN both keep the blackout. Fail closed, never skip on ignorance.
-- Measured today: 0 folders span two ticket keys and 0 live manifests resolve to UNKNOWN, so no
-- caller should see either value yet. They exist so that the day one appears, nothing is stranded.
--
-- GRANTS. Supabase applies ALTER DEFAULT PRIVILEGES at CREATE time, BEFORE any GRANT in this body,
-- and a REVOKE FROM PUBLIC cannot remove a grant made BY NAME. So each function is explicitly
-- revoked and re-granted, and the verification reads has_function_privilege rather than trusting the
-- REVOKE. This estate has shipped that bug at least five times, most recently in
-- 2026-09-04_1738_company_hauler_licenses.sql.
--
-- ⚠ public.fn_dump_county_bucket NEEDS A NEW `authenticated` GRANT, and this is not optional.
-- public.manifest_pickable_visits carries reloptions {security_invoker=true}, so any expression
-- added to it runs as the CALLER. Function EXECUTE is checked against the current role inside ANY
-- view body, definer or invoker, so "make it a definer view" is not an escape hatch. Measured before
-- this migration: authenticated=false, anon=false, service_role=true, with
-- public.file_manifest authenticated=true as the positive control proving the probe works.
-- anon is deliberately NOT granted.
--
-- ⚠ THE VIEW IS EXTENDED WITH CREATE OR REPLACE AND THE COLUMN APPENDED LAST. DROP VIEW would
-- discard the grants established by 2026-07-28r, and two views depend on this one:
-- derm.v_stamp_unlinked_visits and public.dump_outstanding_visits.
-- 🛑 county_bucket IS ADDED AS A COLUMN, NEVER AS A WHERE CLAUSE. public.dump_outstanding_visits is
-- built directly on this view, and client 214-MYK vanished from /upload once already when a filter
-- was added here (recorded in the 2026-07-28 migration header). The picker filters client-side.

-- ---------------------------------------------------------------------------------------------
-- 0. Three resolvers, one per grain. Per manifest, per ticket, per stamp folder.
-- ---------------------------------------------------------------------------------------------

create or replace function derm.fn_manifest_dump_bucket(p_manifest_id bigint)
returns text
language sql
stable
security definer
set search_path = public, derm, pg_temp
as $$
  -- COALESCE outside the subquery on purpose. See the header. deleted_at is deliberately NOT
  -- filtered: a soft-deleted manifest must still resolve to its real bucket rather than to UNKNOWN.
  select coalesce((
    select public.fn_dump_county_bucket(df.county)
      from public.derm_manifests dm
      left join public.disposal_facilities df on df.id = dm.disposal_facility_id
     where dm.id = p_manifest_id
  ), 'UNKNOWN');
$$;

comment on function derm.fn_manifest_dump_bucket(bigint) is
  'Dump-county bucket (DADE|BROWARD|UNKNOWN) for one manifest, via its disposal facility. Never '
  'returns NULL, so do not chain it with COALESCE. Callers use <> ''BROWARD'' so UNKNOWN fails closed.';

create or replace function derm.fn_ticket_dump_bucket(p_ticket text)
returns text
language sql
stable
security definer
set search_path = public, derm, pg_temp
as $$
  select coalesce((
    select case when count(distinct public.fn_dump_county_bucket(df.county)) > 1
                then 'MIXED'
                else min(public.fn_dump_county_bucket(df.county))
           end
      from public.derm_manifests dm
      left join public.disposal_facilities df on df.id = dm.disposal_facility_id
     -- btrim both sides: 8 live rows carry a trailing space until step 2 repairs them.
     where coalesce(btrim(dm.white_manifest_number), btrim(dm.yellow_ticket_number)) = btrim(p_ticket)
       and dm.deleted_at is null
  ), 'UNKNOWN');
$$;

comment on function derm.fn_ticket_dump_bucket(text) is
  'Dump-county bucket for a ticket key (COALESCE(white, yellow)). Returns MIXED if one ticket spans '
  'both buckets, UNKNOWN if no live manifest matches. btrim on both sides. Never returns NULL.';

create or replace function derm.fn_folder_dump_bucket(p_folder text)
returns text
language sql
stable
security definer
set search_path = public, derm, pg_temp
as $$
  -- Joins through address_row_map rather than parsing dump_folder: the key has four shapes
  -- (windowN-sheetM 79, ticket-N 47, derm/N 12, backfill-N 1) and a regex would return UNKNOWN for
  -- most of them. Branches explicitly on matched_manifest_id because the resolvers never return NULL.
  select coalesce((
    select case when count(distinct b.bucket) > 1 then 'MIXED' else min(b.bucket) end
      from (
        select distinct case
                 when r.matched_manifest_id is not null
                   then derm.fn_manifest_dump_bucket(r.matched_manifest_id)
                 else derm.fn_ticket_dump_bucket(r.white_manifest_number)
               end as bucket
          from derm.address_row_map r
         where r.dump_folder = p_folder
      ) b
  ), 'UNKNOWN');
$$;

comment on function derm.fn_folder_dump_bucket(text) is
  'Dump-county bucket for a stamp dump_folder, resolved through derm.address_row_map. NOTE '
  'address_row_map.white_manifest_number is misnamed: it holds COALESCE(white, yellow).';

revoke all on function derm.fn_manifest_dump_bucket(bigint) from public;
revoke all on function derm.fn_ticket_dump_bucket(text)     from public;
revoke all on function derm.fn_folder_dump_bucket(text)     from public;
revoke all on function derm.fn_manifest_dump_bucket(bigint) from anon, authenticated;
revoke all on function derm.fn_ticket_dump_bucket(text)     from anon, authenticated;
revoke all on function derm.fn_folder_dump_bucket(text)     from anon, authenticated;
grant execute on function derm.fn_manifest_dump_bucket(bigint) to service_role;
grant execute on function derm.fn_ticket_dump_bucket(text)     to service_role;
grant execute on function derm.fn_folder_dump_bucket(text)     to service_role;

-- ---------------------------------------------------------------------------------------------
-- 0b. The invoker view below needs this. See the header for why a definer view is not an escape.
-- ---------------------------------------------------------------------------------------------

grant execute on function public.fn_dump_county_bucket(text) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 1. Append county_bucket to the picker view. A COLUMN, never a filter.
-- ---------------------------------------------------------------------------------------------

create or replace view public.manifest_pickable_visits
with (security_invoker = true) as
 SELECT visit_id,
    visit_date,
    start_at,
    completed_at,
    service_type,
    title,
    client_id,
    client_code,
    client_name,
    address,
    city,
    county,
    public.fn_dump_county_bucket(county) AS county_bucket
   FROM ( SELECT v.id AS visit_id,
            v.visit_date,
            v.start_at,
            v.completed_at,
            v.service_type,
            v.title,
            c.id AS client_id,
            c.client_code,
            c.name AS client_name,
            COALESCE(p.address, primary_p.address) AS address,
            COALESCE(p.city, primary_p.city) AS city,
            COALESCE(p.county, primary_p.county) AS county
           FROM visits v
             JOIN clients c ON c.id = v.client_id
             LEFT JOIN properties p ON p.id = v.property_id
             LEFT JOIN properties primary_p ON primary_p.client_id = v.client_id AND primary_p.is_primary = true
          WHERE v.visit_status = 'completed'::text AND (v.derm_required IS NULL OR v.derm_required = true) AND v.deleted_at IS NULL AND NOT (EXISTS ( SELECT 1
                   FROM manifest_visits mv
                     JOIN derm_manifests dm ON dm.id = mv.manifest_id
                  WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL))) _pv
  WHERE NOT (client_id IN ( SELECT clients.id
           FROM clients
          WHERE clients.client_code = ANY (ARRAY['000-DH'::text, '000-DP'::text])));

-- ---------------------------------------------------------------------------------------------
-- VERIFICATION RECORD. Applied 2026-09-07 13:38 ET. 23 assertions, 23 pass.
-- ---------------------------------------------------------------------------------------------
-- Grants (read with has_function_privilege, never inferred from the REVOKE):
--   derm resolvers: authenticated=false, anon=false, service_role=true
--   public.fn_dump_county_bucket: authenticated=true (new), anon=false, service_role=true
-- Fail-closed, the assertion this migration exists for. All four return 'UNKNOWN', never NULL:
--   fn_manifest_dump_bucket(999999999) · fn_manifest_dump_bucket(NULL)
--   fn_ticket_dump_bucket('zzz-not-a-ticket') · fn_folder_dump_bucket('zzz-not-a-folder')
-- Positive controls: facility 3 -> BROWARD, facility 2 -> DADE.
-- Coverage: 712 live manifests resolve, 0 UNKNOWN. Split BROWARD=167 DADE=545, matching the
--   independent count taken before this migration.
-- View: county_bucket present, security_invoker=true preserved, authenticated SELECT preserved,
--   dependent views still queryable (dump_outstanding_visits 9 rows, v_stamp_unlinked_visits 12),
--   picker unchanged at 12 rows, now bucketed BROWARD=7 DADE=5.
--
-- ⚠ ONE NUMBER CAME BACK HIGHER THAN PREDICTED AND WAS RUN DOWN RATHER THAN ACCEPTED.
-- Folders resolving to a real bucket: predicted 137 from the ticket-string join, measured 139.
-- The two extra are folders whose recorded ticket key is an OCR MISREAD that matches no manifest,
-- and which a human later matched correctly by manifest id:
--     derm/1246      key '828601'  ->  manifests 1246-1249, white '828604'
--     ticket-820714  key '820714'  ->  manifests 1622-1624, white '830714'
-- Both DADE (facility 2), so no Broward consequence. This CONFIRMS the design: prefer
-- matched_manifest_id over the string, because the string is an OCR guess and the id is the
-- human-corrected truth. A resolver that parsed dump_folder, or joined only on the ticket key,
-- would have silently returned UNKNOWN for both.
-- Pre-existing data issue, NOT created here and NOT repaired here: 2 folders in
-- derm.address_row_map carry a white_manifest_number matching no manifest.
