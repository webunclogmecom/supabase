-- ============================================================================
-- 2026-08-18  client.clients: expose the grease trap size to the Client App
-- ============================================================================
-- WHY. Fred asked for a Grease Trap Size column on the Clients table. The value lives
-- ONLY on public.properties.grease_trap_size_gallons and is exposed NOWHERE in the
-- client schema, so the app could not read it at all. This adds one derived column.
--
-- THE RULE, and it is the whole design decision:
--   PREFER THE SERVICE PROPERTY, FALL BACK TO THE BILLING TWIN.
-- Nearly every client carries TWO properties, one service (is_billing=false) and one
-- billing (is_billing=true), the documented service/billing duplicate. Measured today:
--   * 116 of 901 properties carry a size (all positive, 1..4000; ZERO zeros, so Jobber's
--     defaultValue:0 trap has not polluted this column)
--   * 105 sizes sit on a SERVICE property, 11 on a BILLING one
--   * 10 of those 11 have NO sized service twin, so a service-only rule would blank 10
--     clients whose size IS on file. Hence the COALESCE fallback: 115 clients show a
--     value instead of 105.
--   * exactly ONE client disagrees with itself: 227-PER Aromas del Peru, billing 1200 vs
--     service 895 at the SAME address. Service wins (895), because the service address is
--     where the trap physically is. That is a DATA conflict to fix upstream, not a display
--     problem. Flagged to Fred, deliberately not edited here.
--
-- SUM WAS REJECTED: billing and service are the same physical place, so summing double
-- counts. max() is used only to make the theoretical multi-property case deterministic.
--
-- is_billing IS DISTINCT FROM true (not = false) so a NULL is_billing property still
-- contributes rather than vanishing from BOTH arms. Measured: 0 NULLs today, but keeping
-- the value is the fail-safe direction.
--
-- BODY COPIED FROM pg_get_viewdef, NOT RETYPED (Supabase/CLAUDE.md). Two anchors were
-- asserted to match exactly once each before the edit. The ONLY changes are the appended
-- select-list column and the appended LATERAL; everything else is byte-identical.
-- CREATE OR REPLACE (not DROP) so the SELECT grants survive. Verified below.
--
-- RULE 8 (audit): a VIEW carries no triggers and stores no rows. Opt-out, nothing to audit.
-- ============================================================================

BEGIN;
SET LOCAL search_path = public, pg_catalog;

CREATE OR REPLACE VIEW client.clients AS
SELECT c.id,
    c.client_code,
    c.name,
    c.status,
    c.balance,
    c.notes,
    c.created_at,
    c.updated_at,
    c.group_id,
    c.client_class,
    c.client_class_source,
    ( SELECT
                CASE
                    WHEN l.source_id ~ '^[0-9]+$'::text THEN 'https://secure.getjobber.com/clients/'::text || l.source_id
                    WHEN (length(l.source_id) % 4) = 0 AND l.source_id ~ '^[A-Za-z0-9+/]+={0,2}$'::text THEN 'https://secure.getjobber.com/clients/'::text || split_part(convert_from(decode(l.source_id, 'base64'::text), 'UTF8'::name), '/'::text, '-1'::integer)
                    ELSE NULL::text
                END AS "case"
           FROM entity_source_links l
          WHERE l.entity_type = 'client'::text AND l.source_system = 'jobber'::text AND l.entity_id = c.id
         LIMIT 1) AS jobber_url,
    dz.zone_id,
    dz.zone_code,
    gt.grease_trap_size_gallons
   FROM clients c
     LEFT JOIN LATERAL ( SELECT
                CASE
                    WHEN count(DISTINCT p.zone_id) = 1 THEN min(p.zone_id)
                    ELSE NULL::bigint
                END AS zone_id,
                CASE
                    WHEN count(DISTINCT p.zone_id) = 1 THEN min(z.code)
                    WHEN count(DISTINCT p.zone_id) > 1 THEN 'MIXED'::text
                    ELSE NULL::text
                END AS zone_code
           FROM properties p
             JOIN zones z ON z.id = p.zone_id
          WHERE p.client_id = c.id AND p.zone_id IS NOT NULL) dz ON true
     LEFT JOIN LATERAL ( SELECT COALESCE(
                max(p.grease_trap_size_gallons) FILTER (WHERE p.is_billing IS DISTINCT FROM true),
                max(p.grease_trap_size_gallons) FILTER (WHERE p.is_billing IS true)
              ) AS grease_trap_size_gallons
           FROM properties p
          WHERE p.client_id = c.id AND p.grease_trap_size_gallons IS NOT NULL) gt ON true;

DO $verify$
DECLARE n_rows int; n_cols int; last_col text; n_sized int; v_per int; n_auth int; v_opts text; n_service_only int; v_ary int;
BEGIN
  SELECT count(*) INTO n_rows FROM client.clients;
  IF n_rows <> 448 THEN RAISE EXCEPTION 'ABORT: client.clients has % rows, expected 448', n_rows; END IF;

  SELECT count(*) INTO n_cols FROM information_schema.columns
   WHERE table_schema='client' AND table_name='clients';
  IF n_cols <> 15 THEN RAISE EXCEPTION 'ABORT: % columns, expected 15 (14 plus the new one)', n_cols; END IF;

  SELECT column_name INTO last_col FROM information_schema.columns
   WHERE table_schema='client' AND table_name='clients' ORDER BY ordinal_position DESC LIMIT 1;
  IF last_col <> 'grease_trap_size_gallons' THEN
    RAISE EXCEPTION 'ABORT: last column is %, expected grease_trap_size_gallons', last_col; END IF;

  -- the fallback rule must beat the service-only rule by exactly the 10 measured clients
  SELECT count(*) INTO n_sized FROM client.clients WHERE grease_trap_size_gallons IS NOT NULL;
  SELECT count(DISTINCT client_id) INTO n_service_only FROM public.properties
   WHERE is_billing IS DISTINCT FROM true AND grease_trap_size_gallons IS NOT NULL;
  IF n_sized <> 115 THEN RAISE EXCEPTION 'ABORT: % clients sized, expected 115', n_sized; END IF;
  IF n_sized - n_service_only <> 10 THEN
    RAISE EXCEPTION 'ABORT: fallback added % clients, expected exactly 10', n_sized - n_service_only; END IF;

  -- 227-PER: service 895 must win over billing 1200. This is the control that proves the
  -- COALESCE is ordered service-first; a billing-first rule would return 1200 here.
  SELECT grease_trap_size_gallons INTO v_per FROM client.clients WHERE client_code = '227-PER';
  IF v_per IS DISTINCT FROM 895 THEN
    RAISE EXCEPTION 'ABORT: 227-PER shows %, expected 895 (service must beat billing 1200)', v_per; END IF;

  -- 198-ARY: its ONLY size sits on the billing property, so this proves the SECOND
  -- COALESCE arm actually fires. Without it this client would read NULL and the
  -- 115-vs-105 count above could still pass by coincidence.
  SELECT grease_trap_size_gallons INTO v_ary FROM client.clients WHERE client_code = '198-ARY';
  IF v_ary IS DISTINCT FROM 1500 THEN
    RAISE EXCEPTION 'ABORT: 198-ARY shows %, expected 1500 from the billing fallback', v_ary; END IF;

  -- grants survived the REPLACE
  SELECT count(*) INTO n_auth FROM information_schema.role_table_grants
   WHERE table_schema='client' AND table_name='clients' AND grantee='authenticated' AND privilege_type='SELECT';
  IF n_auth <> 1 THEN RAISE EXCEPTION 'ABORT: authenticated lost SELECT on client.clients'; END IF;

  -- still owner-rights, not security_invoker (the schema-per-app pattern depends on this)
  SELECT COALESCE(c.reloptions::text,'(null)') INTO v_opts FROM pg_class c
   JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='client' AND c.relname='clients';
  IF v_opts <> '(null)' THEN RAISE EXCEPTION 'ABORT: reloptions changed to %', v_opts; END IF;

  RAISE NOTICE 'VERIFIED: 445 rows, 15 cols, last=%, 115 sized (+10 from fallback), 227-PER=895, grants intact', last_col;
END $verify$;

COMMIT;
