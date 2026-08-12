-- ============================================================================
-- 2026-08-12_1225: remove the duplicate property row 1017 (170-PV Pura Vida Bakery)
-- ============================================================================
-- Fred, 2026-08-12: "for 170-PV we need to remove the duplicate address" ... "fix the
-- sweep, then do the two removals."
--
-- ⚠ ONLY ONE OF THE TWO REMOVALS IS DONE HERE. The other one is refused, on evidence,
-- and the reason is at the bottom of this file. Read it before re-attempting it.
--
-- WHAT THIS ROW IS.
-- public.properties id 1017, client 170-PV, address "1657 North Miami Avenue suite a".
-- 170-PV holds three property rows for a client that has exactly ONE property in Jobber:
--     id 16    service, Jobber-linked      1657 North Miami Avenue suite a
--     id 473   BILLING, Jobber-linked      1657 North Miami Avenue suite a
--     id 1017  service, NOT Jobber-linked  1657 North Miami Avenue suite a   <- this one
-- Jobber returns a single property for this client. Rows 16 and 473 are the service and
-- billing pair our schema stores for it. 1017 is a third copy that corresponds to nothing.
--
-- 🛑 IT IS A DUPLICATE BY NAME AS WELL AS BY ADDRESS, WHICH IS THE ONLY TEST THAT COUNTS.
-- Fred, 2026-08-12: "they have different Property names, so check that also in the others
-- when saying they're dupes." He is right, and it invalidated an earlier reading of this
-- data: Wynd 28 (242-WYN) has SIX Jobber properties at one street address distinguished
-- only by name (Presidente, Pari Pari, CU4, Pasta, Nino Gordo, Wynd 28), and those are six
-- real locations, not duplicates. Re-tested across all 430 service properties using name
-- AND address together: exactly ONE genuine duplicate group exists, and it is this one.
-- All three of 170-PV's rows carry a NULL name.
--
-- WHERE IT CAME FROM, because that matters more than the row.
-- Created 2026-08-10 13:35 ET by app_source='sql' with no jwt_claims and no request origin,
-- i.e. a direct script or Management API write, not an app and not the Jobber sweep. The
-- other two rows date from April and May. So something wrote a duplicate two days ago. That
-- writer has NOT been identified and this migration does not stop it; if a fourth row
-- appears for 170-PV, that is the finding, not this row.
--
-- SAFETY: it is provably orphaned. All nine foreign keys that point at public.properties
-- were counted for this id and every one is zero (jobs, visits, quotes, gdos, notes,
-- service_configs, client_locations, client_contacts, ops.visit_requests), as is
-- entity_source_links. The DELETE below re-asserts all ten rather than trusting that.
--
-- ⚠ RULE 6 (never hard-delete business data) AND WHY THIS IS ALLOWED.
-- public.properties has NO soft-delete column, so there is no INACTIVE state to move this
-- to. This is a data-entry artifact with zero references and no Jobber counterpart, not a
-- business record, and Fred authorised the removal explicitly. public.properties IS audited,
-- so the deleted row survives in audit.logs.old_row and is fully recoverable; the assertion
-- below refuses to run if that audit trigger is ever missing.
-- ============================================================================

do $do$
declare
  v_addr text; v_client text; v_linked int; v_audited boolean;
  v_refs int; v_before int; v_after int;
begin
  -- (a) it is the row we think it is
  select p.address, c.client_code into v_addr, v_client
    from public.properties p join public.clients c on c.id=p.client_id where p.id=1017;
  if v_addr is null then raise exception 'property 1017 does not exist -- already removed?'; end if;
  if v_client <> '170-PV' then raise exception 'property 1017 belongs to %, expected 170-PV', v_client; end if;
  if v_addr !~* '1657 North Miami Avenue' then raise exception 'property 1017 address reads "%"', v_addr; end if;

  -- (b) it is the UNLINKED one. Deleting a Jobber-linked row would be undone by the sweep
  -- and would delete the wrong copy.
  select count(*) into v_linked from public.entity_source_links
   where entity_type='property' and source_system='jobber' and entity_id=1017;
  if v_linked <> 0 then raise exception 'property 1017 IS Jobber-linked -- wrong row'; end if;

  -- (c) 170-PV must still have its real pair afterwards, so assert the starting shape
  select count(*) into v_before from public.properties p join public.clients c on c.id=p.client_id
   where c.client_code='170-PV';
  if v_before <> 3 then raise exception '170-PV has % property rows, expected 3', v_before; end if;

  -- (d) every foreign key that points at properties, counted for this id
  select (select count(*) from public.jobs where property_id=1017)
       + (select count(*) from public.visits where property_id=1017)
       + (select count(*) from public.quotes where property_id=1017)
       + (select count(*) from public.gdos where property_id=1017)
       + (select count(*) from public.notes where property_id=1017)
       + (select count(*) from public.service_configs where property_id=1017)
       + (select count(*) from public.client_locations where property_id=1017)
       + (select count(*) from public.client_contacts where property_id=1017)
       + (select count(*) from ops.visit_requests where property_id=1017)
       + (select count(*) from public.entity_source_links where entity_type='property' and entity_id=1017)
    into v_refs;
  if v_refs <> 0 then raise exception 'property 1017 has % references -- refusing to delete', v_refs; end if;

  -- (e) the delete must be recoverable
  select exists (select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid
                  join pg_proc pr on pr.oid=t.tgfoid join pg_namespace pn on pn.oid=pr.pronamespace
                 where c.relname='properties' and pn.nspname='audit' and pr.proname='log_change'
                   and not t.tgisinternal) into v_audited;
  if not v_audited then
    raise exception 'public.properties is NOT audited -- this delete would leave no trail';
  end if;
end
$do$;

delete from public.properties where id = 1017;

do $do$
declare v_after int; v_svc int; v_bill int; v_audit int; v_dupes int;
begin
  select count(*) into v_after from public.properties p join public.clients c on c.id=p.client_id
   where c.client_code='170-PV';
  if v_after <> 2 then raise exception '170-PV now has % rows, expected 2', v_after; end if;

  -- the surviving pair must be exactly one service + one billing, both Jobber-linked
  select count(*) filter (where coalesce(p.is_billing,false)=false),
         count(*) filter (where p.is_billing)
    into v_svc, v_bill
    from public.properties p join public.clients c on c.id=p.client_id where c.client_code='170-PV';
  if v_svc <> 1 or v_bill <> 1 then
    raise exception '170-PV left with % service and % billing rows, expected 1 and 1', v_svc, v_bill;
  end if;

  -- recoverable
  select count(*) into v_audit from audit.logs
   where table_name='properties' and operation='DELETE' and old_row->>'id'='1017';
  if v_audit < 1 then raise exception 'no audit row captured for the delete'; end if;

  -- POSITIVE CONTROL: the duplicate detector must now find ZERO groups fleet-wide, and it
  -- must be the same test (name AND address) that found this one. If this reads 0 because
  -- the query is wrong rather than because the data is clean, the count below catches it.
  select count(*) into v_dupes from (
    select client_id from public.properties
     where coalesce(is_billing,false)=false
     group by client_id, lower(btrim(address)), lower(btrim(coalesce(name,'')))
    having count(*) > 1) t;
  if v_dupes <> 0 then raise exception '% duplicate property groups remain', v_dupes; end if;

  raise notice '170-PV reduced to its real service+billing pair; 0 duplicate groups fleet-wide';
end
$do$;

-- ============================================================================
-- 🛑 THE SECOND REMOVAL IS REFUSED. 045-NU / property 200 / "266 Miracle Mile".
-- ============================================================================
-- Fred's instruction was: "double check with what address jobber holds and if they don't
-- remove that address from ours and just keep what jobber holds (adopt from jobber)."
--
-- Checked. Jobber holds exactly ONE property for 045-NU, "3250 Northeast 1st Avenue suit
-- 117", and it does NOT hold 266 Miracle Mile. So by the letter of the instruction this row
-- would go. It must not, and the check is the reason the instruction included one:
--
--     public.jobs             2   <- id 1536 "Service Call", status action_required (LIVE)
--                                    id 228  "Grease trap pumping", archived
--     public.gdos             1   <- GDO-07733 (INACTIVE)
--     public.client_locations 1
--     entity_source_links     2   <- it WAS a real Jobber property once
--
-- jobs.property_id is ON DELETE NO ACTION, so the DELETE would simply raise. Forcing it
-- would strand a live job and null out a permit's location. This row is not a stray address,
-- it is a location with history that Jobber no longer returns, which is a different problem
-- (archived or deleted upstream) and needs a decision rather than a delete.
--
-- Left in place deliberately. Do not "finish the job" by deleting it.
-- ============================================================================
