-- =============================================================================
-- 2026-09-08_1510  authenticated may READ derm.generated_visit_sheets
-- =============================================================================
-- Correcting 2026-09-08_1500 forward. That migration created
-- derm.v_manifest_visit_sheets with security_invoker = on and LEFT JOINs
-- derm.generated_visit_sheets, on which authenticated held NOTHING (service_role
-- SELECT only, from 2026-09-07_2240). So the view raised 42501 for every app read:
--
--     42501: permission denied for table generated_visit_sheets
--     CONTEXT: select count(*) from derm.v_manifest_visit_sheets
--
-- (*) THIS IS THE FIFTH TIME THIS ESTATE HAS PAID FOR THE SAME ASYMMETRY, and the
-- only reason it cost nothing today is that 1500's VERIFY ran `SET LOCAL ROLE
-- authenticated` instead of asserting as postgres. As the owner the view reads
-- perfectly: postgres holds every grant, so a probe run as postgres reports a
-- healthy view and proves nothing about the app's actual read path. Test as the
-- role, never as the owner.
--
-- SELECT only, and deliberately so. 2026-09-07_2240 revoked the sequence grants
-- specifically so the app cannot MINT a Broward sheet number -- the paper is
-- printed at generation time and a second number for one physical sheet is
-- unrecoverable. Reading which number was generated for a visit is the opposite
-- of minting one: it is what lets the modal show the number the driver is already
-- carrying instead of offering to create another. No INSERT, UPDATE or DELETE,
-- and no USAGE on public.derm_broward_address_seq.
--
-- Rule 8: no schema change, nothing to opt in or out of.
-- =============================================================================

begin;

revoke all on derm.generated_visit_sheets from public;
revoke all on derm.generated_visit_sheets from anon;
grant select on derm.generated_visit_sheets to authenticated;

commit;

-- VERIFY: the grant is SELECT and nothing more, anon still holds nothing, and the
-- view now actually reads as the role the app uses.
do $$
declare v_n int;
begin
  if not has_table_privilege('authenticated','derm.generated_visit_sheets','SELECT') then
    raise exception 'FAIL: authenticated still cannot SELECT';
  end if;
  if has_table_privilege('authenticated','derm.generated_visit_sheets','INSERT')
     or has_table_privilege('authenticated','derm.generated_visit_sheets','UPDATE')
     or has_table_privilege('authenticated','derm.generated_visit_sheets','DELETE')
  then raise exception 'FAIL: authenticated got more than SELECT'; end if;
  if has_table_privilege('anon','derm.generated_visit_sheets','SELECT') then
    raise exception 'FAIL: anon can read the generation register';
  end if;
  if pg_catalog.has_sequence_privilege('authenticated','public.derm_broward_address_seq','USAGE') then
    raise exception 'FAIL: authenticated can mint a sheet number';
  end if;
  raise notice 'grants OK';
end $$;
