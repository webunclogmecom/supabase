-- =============================================================================
-- 2026-09-08_1720  derm.generated_visit_sheets: an actual RLS READ POLICY
-- =============================================================================
-- Correcting 2026-09-08_1510 forward. That migration granted authenticated SELECT
-- on derm.generated_visit_sheets so the /manifests edit dialog could show the
-- number of a sheet the office had already generated. The GRANT was applied and
-- is correct. It does nothing, because the table has RLS ENABLED and ZERO
-- POLICIES, and under RLS a non-owner role with no policy sees no rows at all.
--
-- (*) A GRANT IS A PRIVILEGE CHECK. RLS IS A REACHABILITY CHECK. THEY ARE
-- DIFFERENT QUESTIONS AND THIS ESTATE HAS A MEMORY NOTE SAYING SO, WHICH I HAD
-- AND STILL GOT WRONG. Measured on live Prod inside a rolled-back probe, after
-- arranging one row in each table:
--
--                                              owner   authenticated
--   v_manifest_visit_sheets.has_sheet            1           1     <- fine
--   v_manifest_visit_sheets.generated_sheet_no   1           0     <- silent
--
--   derm.manifest_visit_sheets   policies: _service_all, _staff_read   -> readable
--   derm.generated_visit_sheets  policies: NONE                        -> 0 rows
--   has_table_privilege('authenticated','derm.generated_visit_sheets','SELECT') = TRUE
--
-- (*) WHY 1510's OWN VERIFY PASSED. It asserted has_table_privilege (true), and
-- its mutation control inserted into derm.manifest_visit_sheets and watched
-- has_sheet flip, which it did. The control exercised the NEIGHBOURING table,
-- which has policies. A positive control has to share the permission of the
-- thing it is vouching for, or it passes while the instrument is blind.
--
-- The failure is silent by construction: a LEFT JOIN onto rows RLS is hiding
-- returns NULL, not an error. So the app renders "No FDEP sheet yet" for a visit
-- whose sheet number is already printed on paper the driver is carrying, and
-- offers to mint a second one. That is the exact divergence
-- record_manifest_visit_sheet's adoption block exists to prevent.
--
-- Mirrors derm.manifest_visit_sheets exactly: read-only for authenticated, full
-- access for service_role, nothing for anon. No write policy for authenticated:
-- minting a Broward sheet number stays inside the SECURITY DEFINER RPC, and
-- authenticated still holds no USAGE on public.derm_broward_address_seq.
--
-- Rule 8: no schema change, no new table, nothing to opt in or out of.
-- =============================================================================

begin;

drop policy if exists generated_visit_sheets_service_all on derm.generated_visit_sheets;
drop policy if exists generated_visit_sheets_staff_read  on derm.generated_visit_sheets;

create policy generated_visit_sheets_service_all
  on derm.generated_visit_sheets
  for all
  to service_role
  using (true)
  with check (true);

create policy generated_visit_sheets_staff_read
  on derm.generated_visit_sheets
  for select
  to authenticated
  using (true);

commit;

-- -----------------------------------------------------------------------------
-- VERIFY: read as the ROLE, not as the owner, with the pre-fix behaviour as the
-- control. Rolled back either way.
-- -----------------------------------------------------------------------------
do $$
declare
  v_vid bigint;
  o_gen bigint; a_gen bigint; a_rows bigint;
  n_pol int;
begin
  select count(*) into n_pol
    from pg_policy p join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'derm' and c.relname = 'generated_visit_sheets';
  if n_pol <> 2 then
    raise exception 'FAIL: expected 2 policies, found %', n_pol;
  end if;

  -- anon must still hold nothing
  if has_table_privilege('anon','derm.generated_visit_sheets','SELECT') then
    raise exception 'FAIL: anon can read the generation register';
  end if;
  -- authenticated must still be unable to MINT
  if pg_catalog.has_sequence_privilege('authenticated','public.derm_broward_address_seq','USAGE') then
    raise exception 'FAIL: authenticated can mint a sheet number';
  end if;
  if has_table_privilege('authenticated','derm.generated_visit_sheets','INSERT')
     or has_table_privilege('authenticated','derm.generated_visit_sheets','UPDATE')
     or has_table_privilege('authenticated','derm.generated_visit_sheets','DELETE') then
    raise exception 'FAIL: authenticated got more than SELECT';
  end if;

  -- Arrange a live generated sheet on a real Broward visit, then read it AS the app.
  select mvs.visit_id into v_vid
    from derm.v_manifest_visit_sheets mvs
   where mvs.dump_bucket = 'BROWARD'
   order by mvs.visit_id
   limit 1;
  if v_vid is null then
    raise exception 'FAIL: no Broward visit to probe with, the check would be vacuous';
  end if;

  insert into derm.generated_visit_sheets
    (visit_id, sheet_no, form_kind, pdf_bucket, pdf_path, generated_at)
  values (v_vid, 888888, 'fdep-62-705.300-3', 'manifests', 'probe/verify.pdf', now())
  on conflict (visit_id) do update
    set sheet_no = 888888, deleted_at = null, pdf_path = 'probe/verify.pdf';

  select count(*) into o_gen
    from derm.v_manifest_visit_sheets where generated_sheet_no = 888888;

  set local role authenticated;
  select count(*) into a_gen
    from derm.v_manifest_visit_sheets where generated_sheet_no = 888888;
  select count(*) into a_rows from derm.v_manifest_visit_sheets;
  reset role;

  if a_rows = 0 then
    raise exception 'FAIL: authenticated sees no view rows at all, instrument is broken';
  end if;
  if o_gen = 0 then
    raise exception 'FAIL: the owner cannot see the arranged row, instrument is broken';
  end if;
  if a_gen <> o_gen then
    raise exception 'FAIL: RLS still hides the generated sheet from authenticated (owner %, authenticated %)',
      o_gen, a_gen;
  end if;

  raise exception 'VERIFY PASSED (rolled back) :: policies=% | view rows as authenticated=% | generated_sheet_no visible owner=% authenticated=%',
    n_pol, a_rows, o_gen, a_gen;
end $$;
