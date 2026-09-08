-- ============================================================================
-- 2026-09-08_1130_remove_jobber_client_race_orphans.sql
--
-- Remove the 8 phantom client rows the create race left behind, now that the race is closed.
--
-- MUST BE APPLIED AFTER 2026-09-08_1100_jobber_client_resolve_atomic.sql. Cleaning before the
-- source is fixed just makes room for the next batch -- stop the bleeding, then clean.
--
-- WHAT THESE ARE. Each is a byte-identical name duplicate of a client we DO hold, created in the
-- same ~100ms burst by a concurrent handleClient, with NO entity_source_links row. Because every
-- sync path resolves a client by its link, these rows are invisible to Jobber forever: they can
-- never receive an update, a job, a visit or an invoice. They are not customers. They are debris.
--
--   565 Herzka Royal palm             twin 564    2026-08-23
--   570 North bay villa               twin 569    2026-08-31
--   572 Aromas del Peru Coral gables  twin 571    2026-08-31
--   574 Bibi's burgers                twin 573    2026-09-01   <- Fred's report
--   575 Bibi's burgers                twin 573    2026-09-01
--   576 Bibi's burgers                twin 573    2026-09-01
--   580 Cyril Heber                   twin 579    2026-09-02
--   581 Cyril Heber                   twin 579    2026-09-02
--
-- They are visible in the app: client.clients has no filter on the base table, so all four
-- "Bibi's burgers" render in the Client App, three of them with jobber_url NULL and nothing else.
-- That is exactly what Fred opened.
--
-- 🛑 CLIENTS 41 AND 153 ARE DELIBERATELY NOT IN THIS SET, though they are also unlinked.
--    They pre-date the webhook enablement (both created 2026-04-29), both are INACTIVE, 41 holds a
--    real client_code (050-PV) and 153 carries 2 properties + 1 job + 1 contact. Different cause,
--    real data attached, and merging them is a human decision. Left alone on purpose.
--
-- ⚠ BACKED UP FIRST to backups/2026-09-08_jobber_client_race_orphans.json (8 clients + their 8
--   client_locations rows, full column dumps, ids explicit so they can be re-inserted verbatim).
--
-- ⚠ WHY DELETE AND NOT SOFT-DELETE. public.clients HAS NO deleted_at COLUMN, so soft-delete is not
--   available on this table at all. The house rule ("soft-delete business data") is about customer
--   records; these carry zero dependents beyond the client_locations row a trigger made for them,
--   which is re-checked at apply time below across EVERY foreign key, not assumed.
--
-- Audit: audit_clients logs all 8 DELETEs with the full old_row, so the trail survives the rows.
-- ============================================================================

begin;

do $cleanup$
declare
  v_expected bigint[] := array[565,570,572,574,575,576,580,581];
  v_derived  bigint[];
  v_deps     bigint := 0;
  v_n        bigint;
  r          record;
  v_deleted  bigint;
begin
  -- ---- 1. DERIVE the set from the invariant, do not trust the hardcoded list ---------------
  -- unlinked + created after the webhook enablement + name-duplicate of a LINKED client.
  select array_agg(c.id order by c.id) into v_derived
    from public.clients c
   where not exists (select 1 from public.entity_source_links e
                      where e.entity_type='client' and e.entity_id=c.id and e.source_system='jobber')
     and c.created_at >= '2026-08-21'
     and exists (select 1 from public.clients t
                   join public.entity_source_links te
                     on te.entity_type='client' and te.entity_id=t.id and te.source_system='jobber'
                  where lower(btrim(t.name)) = lower(btrim(c.name)) and t.id <> c.id);

  -- ---- 2. AND REFUSE IF THE WORLD MOVED ----------------------------------------------------
  -- If the derived set is not exactly what was measured, something changed between the audit and
  -- this run: a new orphan appeared, or one of these acquired a link. Stop rather than guess.
  if v_derived is distinct from v_expected then
    raise exception 'REFUSING: derived orphan set % does not match the audited set %. Re-audit before deleting.',
      v_derived, v_expected;
  end if;

  -- ---- 3. RE-CHECK DEPENDENTS ACROSS EVERY FK, at apply time -------------------------------
  -- Not the four tables I happened to look at: every foreign key that points at public.clients.
  -- client_locations is expected (a trigger creates one per client) and cascades on delete.
  for r in
    select con.conrelid::regclass::text as tbl, a.attname as col
      from pg_constraint con
      join pg_attribute a on a.attrelid=con.conrelid and a.attnum=con.conkey[1]
     where con.confrelid='public.clients'::regclass and con.contype='f'
       and con.conrelid <> 'public.client_locations'::regclass
  loop
    execute format('select count(*) from %s where %I = any($1)', r.tbl, r.col)
      into v_n using v_expected;
    if v_n > 0 then
      raise exception 'REFUSING: % rows in %.% still reference these clients -- they are NOT debris',
        v_n, r.tbl, r.col;
    end if;
    v_deps := v_deps + v_n;
  end loop;
  raise notice 'dependent sweep clean across every FK except client_locations (which cascades)';

  -- ---- 4. delete ---------------------------------------------------------------------------
  delete from public.clients where id = any(v_expected);
  get diagnostics v_deleted = row_count;
  if v_deleted <> 8 then
    raise exception 'REFUSING: deleted % rows, expected 8', v_deleted;
  end if;
end
$cleanup$;

commit;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
do $verify$
declare v_n bigint; v_name text;
begin
  -- 1. all 8 gone
  select count(*) into v_n from public.clients where id in (565,570,572,574,575,576,580,581);
  if v_n <> 0 then raise exception 'VERIFY 1 FAILED: % orphan client(s) survive', v_n; end if;

  -- 2. their locations went with them (FK is ON DELETE CASCADE -- assert it actually fired)
  select count(*) into v_n from public.client_locations
   where client_id in (565,570,572,574,575,576,580,581);
  if v_n <> 0 then raise exception 'VERIFY 2 FAILED: % orphan client_locations survive', v_n; end if;

  -- 3. THE TWINS ARE UNTOUCHED. This is the assertion that matters: deleting the wrong row of a
  --    duplicate pair is the whole risk of this migration.
  select count(*) into v_n from public.clients where id in (564,569,571,573,579);
  if v_n <> 5 then raise exception 'VERIFY 3 FAILED: only % of the 5 linked twins remain', v_n; end if;

  -- and the one Fred asked about still resolves, with its data attached
  select c.name into v_name from public.clients c where c.id = 573;
  if v_name is distinct from 'Bibi''s burgers' then
    raise exception 'VERIFY 3b FAILED: client 573 is now named %', v_name;
  end if;
  if not exists (select 1 from public.entity_source_links
                  where entity_type='client' and source_system='jobber'
                    and source_id='Z2lkOi8vSm9iYmVyL0NsaWVudC8xNTEyNjE5NzI=' and entity_id=573) then
    raise exception 'VERIFY 3c FAILED: client 573 lost its Jobber link';
  end if;
  select count(*) into v_n from public.properties where client_id=573 and deleted_at is null;
  if v_n <> 2 then raise exception 'VERIFY 3d FAILED: client 573 has % properties, expected 2', v_n; end if;

  -- 4. EXACTLY ONE "Bibi's burgers" now
  select count(*) into v_n from public.clients where lower(btrim(name)) = 'bibi''s burgers';
  if v_n <> 1 then raise exception 'VERIFY 4 FAILED: % clients named Bibi''s burgers, expected 1', v_n; end if;

  -- 5. THE DELIBERATE EXCLUSIONS ARE STILL THERE. 41 and 153 are pre-webhook legacy rows with real
  --    data; sweeping them in would have been the easy mistake.
  select count(*) into v_n from public.clients where id in (41,153);
  if v_n <> 2 then raise exception 'VERIFY 5 FAILED: legacy clients 41/153 were removed -- they are NOT part of this'; end if;
  select count(*) into v_n from public.properties where client_id=153 and deleted_at is null;
  if v_n < 1 then raise exception 'VERIFY 5b FAILED: client 153 lost its properties'; end if;

  -- 6. no NEW orphan appeared while we worked (the */5 poll runs during migrations)
  select count(*) into v_n from public.clients c
   where not exists (select 1 from public.entity_source_links e
                      where e.entity_type='client' and e.entity_id=c.id and e.source_system='jobber')
     and c.created_at >= '2026-08-21';
  if v_n <> 0 then
    raise exception 'VERIFY 6 FAILED: % post-webhook orphan(s) present after cleanup -- the race may still be open', v_n;
  end if;

  raise notice 'VERIFY ok: 8 orphans and their locations gone; 5 linked twins intact; exactly one Bibi with its link and 2 properties; legacy 41/153 untouched; zero post-webhook orphans remain';
end
$verify$;
