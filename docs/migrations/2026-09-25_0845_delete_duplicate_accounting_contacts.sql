-- 2026-09-25 08:45 ET
-- Delete 114 nameless accounting contacts that repeat their client-record email (115 found, 1 kept).
--
-- WHY (Fred, 2026-09-25, choosing "Delete them (Recommended)" for: "The 115 nameless duplicate
-- 'accounting' cards: what should I do?"). Contacts plan item 9: 115 live clients show a second,
-- nameless 'accounting' card with the client record's address (same address ignoring case and
-- surrounding spaces; 6 of them differ in letter case only), marked "Receives nothing".
--
-- ONE IS KEPT: row 488 (170-PV, client 382). Jobber holds NO email for that client, and
-- webhook-jobber writes `email: primaryEmail ?? null` onto the client record whenever Jobber has an
-- email OR a phone, so the first phone typed into Jobber for 170-PV blanks our client-record email.
-- Row 488 is then the only live copy of the address. That risk exists with or without this delete
-- (flagged to Fred separately); keeping the card costs one line of clutter.
--
-- WHAT THEY ARE. Rows copied from the Airtable 'Acounting Email' field by
-- scripts/populate/populate.js (line ~364) in the one-time load of 2026-04-29 19:46 UTC. Measured
-- 2026-09-25 08:41 ET: 115 rows, 115 clients, all live (ACTIVE / RECURRING / PAUSED), and on every
-- one name, phone, first_name, last_name, person_role and person_role_other are ALL null, 0 hold a
-- communication preference, and 0 are named by clients.primary_contact_ref (0 'ours:%' refs exist).
--
-- WHY IT IS SAFE, each point measured:
-- - Nothing reads them for sending: client.fn_derm_recipients follows service_report prefs only,
--   and these hold none. The VERIFY below proves every client's recipient set is unchanged.
-- - The only inbound FK is client_communication_prefs.contact_id (ON DELETE CASCADE), and it
--   reaches 0 rows here (asserted).
-- - The Jobber sync will not re-create them: webhook-jobber upserts client_contacts only for
--   contact_role 'primary'. An accounting row Fred deleted on 2026-09-02 is still gone.
-- - No Jobber write, no email, no app change.
-- - Rule 6 (never hard-delete) and its recoverability check: public.client_contacts IS audited
--   (audit_client_contacts, AFTER INSERT OR UPDATE OR DELETE), so each row is kept as the old_row of
--   its DELETE (asserted below) MINUS updated_at, which audit.log_change strips; the JSON backup is
--   the only complete copy and was written first:
--   backups/2026-09-25_0845_client_contacts_duplicate_accounting.json (git-ignored; client emails).
--   Restore ONE row at a time with INSERT ... OVERRIDING SYSTEM VALUE ... ON CONFLICT DO NOTHING (id is
--   GENERATED ALWAYS AS IDENTITY; a client that later gains a client-level accounting contact holds
--   the unique slot, so a bulk restore would abort on the first conflict).
--   Fred's explicit yes is the documented exception for this hard delete.
--
-- HOW. The ids are pinned (read 2026-09-25 08:43 ET) AND the full rule is re-asserted in the
-- DELETE itself, so a row edited since the read (a name typed in, a box ticked, the client record's
-- email changed) is skipped rather than deleted, and the count check then aborts the whole thing.

begin;

create temporary table _dup_ids (id bigint primary key) on commit drop;
insert into _dup_ids (id) select unnest(array[
    4, 9, 11, 13, 15, 21, 23, 25, 27, 29, 31, 33, 35, 37, 40, 42, 47, 52, 55, 57, 59, 62, 66, 72,
    85, 89, 103, 108, 113, 118, 120, 148, 153, 160, 166, 170, 179, 181, 185, 191, 196, 206, 230,
    246, 250, 277, 280, 296, 313, 315, 317, 319, 321, 323, 325, 327, 329, 331, 334, 336, 338, 340,
    345, 354, 358, 360, 363, 366, 368, 376, 385, 390, 395, 400, 402, 408, 411, 419, 423, 425, 428,
    431, 441, 444, 450, 452, 455, 457, 462, 464, 472, 475, 479, 481, 483, 490, 500, 503, 504, 506,
    507, 508, 509, 510, 512, 514, 515, 518, 519, 521, 522, 525, 528, 530
]::bigint[]);

do $$
declare n_pinned int; n_before_prefs bigint; v_before text; v_after text; n_deleted int; n_audit int;
        n_primary_before int; n_primary_after int;
begin
  select count(*) into n_pinned from _dup_ids;
  if n_pinned <> 114 then raise exception 'pinned ids: % (want 114)', n_pinned; end if;

  -- state that must not move
  select count(*) into n_before_prefs from public.client_communication_prefs;
  select count(*) into n_primary_before from public.client_contacts where property_id is null and contact_role = 'primary';
  select md5(string_agg(c.id::text || ':' || coalesce(client.fn_derm_recipients(c.id)::text, 'null'), '|' order by c.id))
    into v_before from public.clients c;

  delete from public.client_contacts a
   using _dup_ids d
   where a.id = d.id
     and a.contact_role = 'accounting'
     and a.property_id is null
     and a.name is null and a.phone is null and a.first_name is null and a.last_name is null
     and a.person_role is null and a.person_role_other is null
     and not exists (select 1 from public.client_communication_prefs p where p.contact_id = a.id)
     and not exists (select 1 from public.clients c where c.primary_contact_ref = 'ours:' || a.id)
     and exists (select 1 from public.client_contacts cr
                  where cr.client_id = a.client_id and cr.property_id is null and cr.contact_role = 'primary'
                    and nullif(btrim(cr.email), '') is not null
                    and lower(btrim(cr.email)) = lower(btrim(a.email)));
  get diagnostics n_deleted = row_count;
  if n_deleted <> 114 then
    raise exception 'deleted % rows (want 114); something changed since the read, nothing is kept', n_deleted;
  end if;

  -- VERIFY
  if (select count(*) from public.client_communication_prefs) <> n_before_prefs then
    raise exception 'VERIFY: communication prefs changed (the cascade reached a pref row)';
  end if;
  select count(*) into n_primary_after from public.client_contacts where property_id is null and contact_role = 'primary';
  if n_primary_after <> n_primary_before then raise exception 'VERIFY: client-record contacts changed'; end if;
  select md5(string_agg(c.id::text || ':' || coalesce(client.fn_derm_recipients(c.id)::text, 'null'), '|' order by c.id))
    into v_after from public.clients c;
  if v_after is distinct from v_before then raise exception 'VERIFY: a DERM recipient set changed'; end if;
  if exists (select 1 from public.client_contacts a join _dup_ids d on d.id = a.id) then
    raise exception 'VERIFY: a pinned row survived';
  end if;
  select count(*) into n_audit from audit.logs l
   where l.table_name = 'client_contacts' and l.operation = 'DELETE' and l.changed_at = now()
     and (l.record_pk->>'id')::bigint in (select id from _dup_ids)
     and l.old_row is not null;
  if n_audit <> 114 then
    raise exception 'VERIFY: % audit rows with old_row (want 114); not recoverable from the log', n_audit;
  end if;

  raise notice 'deleted % duplicate accounting contacts; prefs %, client records %, DERM recipients unchanged; % audit rows',
    n_deleted, n_before_prefs, n_primary_after, n_audit;
end $$;

commit;
