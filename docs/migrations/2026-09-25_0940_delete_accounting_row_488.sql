-- 2026-09-25 09:40 ET
-- Delete accounting contact 488 (170-PV Pura Vida Bakery), the one duplicate held back by
-- 2026-09-25_0845.
--
-- WHY (Fred, 2026-09-25: "yes do both"). 2026-09-25_0845 deleted 114 nameless accounting rows that
-- repeated their client-record email and KEPT row 488, because 170-PV was the only client whose
-- address existed in our database but not in Jobber: webhook-jobber writes
-- `email: primaryEmail ?? null` onto the client record whenever Jobber has an email or a phone, so the
-- first phone added in Jobber would have blanked our client-record email, leaving row 488 as the only
-- live copy. At 09:3x ET the address (marcel@puravidamiami.com) was added to the 170-PV Jobber client
-- as its primary email (clientEdit via the jobber_write app, verified by a separate read), and a sync
-- afterwards left our client-record row with the same address. So the reason to keep 488 is gone.
--
-- Same rule as 2026-09-25_0845, re-asserted in the DELETE. Backup:
-- backups/2026-09-25_0940_client_contacts_row_488.json (git-ignored). The audit trigger keeps the row
-- as old_row minus updated_at. Rule 8: no schema change.

begin;

do $$
declare n_deleted int; n_prefs bigint; v_before jsonb; v_after jsonb;
begin
  -- the premise this delete depends on: our client record still holds the address
  if not exists (select 1 from public.client_contacts cr where cr.client_id = 382 and cr.property_id is null
                   and cr.contact_role = 'primary' and lower(btrim(cr.email)) = 'marcel@puravidamiami.com') then
    raise exception 'client record of 170-PV no longer holds the address; nothing deleted';
  end if;

  select count(*) into n_prefs from public.client_communication_prefs;
  v_before := client.fn_derm_recipients(382);

  delete from public.client_contacts a
   where a.id = 488 and a.client_id = 382
     and a.contact_role = 'accounting' and a.property_id is null
     and a.name is null and a.phone is null and a.first_name is null and a.last_name is null
     and a.person_role is null and a.person_role_other is null
     and not exists (select 1 from public.client_communication_prefs p where p.contact_id = a.id)
     and not exists (select 1 from public.clients c where c.primary_contact_ref = 'ours:' || a.id)
     and exists (select 1 from public.client_contacts cr
                  where cr.client_id = a.client_id and cr.property_id is null and cr.contact_role = 'primary'
                    and nullif(btrim(cr.email), '') is not null
                    and lower(btrim(cr.email)) = lower(btrim(a.email)));
  get diagnostics n_deleted = row_count;
  if n_deleted <> 1 then raise exception 'deleted % rows (want 1); nothing kept', n_deleted; end if;

  -- VERIFY
  if (select count(*) from public.client_communication_prefs) <> n_prefs then
    raise exception 'VERIFY: communication prefs changed';
  end if;
  v_after := client.fn_derm_recipients(382);
  if v_after is distinct from v_before then raise exception 'VERIFY: 170-PV DERM recipients changed'; end if;
  if not exists (select 1 from audit.logs l where l.table_name = 'client_contacts' and l.operation = 'DELETE'
                  and l.changed_at = now() and l.record_pk->>'id' = '488' and l.old_row is not null) then
    raise exception 'VERIFY: no audit row for the delete';
  end if;
  raise notice 'row 488 deleted; 170-PV DERM recipients unchanged';
end $$;

commit;
