-- 2026-11-21_1100 Trello #238: the Monthly Report goes to the county by email from the Ops Portal.
-- Fred, 2026-11-21: "now we're missing is the email, and the template for the email. Also when sending the email depending
-- on the selected file format that's how's gonna be attached to the email (pdf or excel)". Earlier the same morning: "once
-- we have that we don't need the button "Record as filed"", so a sent email records the report as filed.
--
-- Adds:
--   derm.lwt_monthly_sends    one row per email the lwt-monthly edge function sent: to the county, or a test copy to an
--                             internal address (is_test). Carries the Resend id (for the delivery status), the file sent
--                             and whether the report was then recorded as filed. Written ONLY by lwt-monthly with the
--                             service key; no app reads it directly (the function reads it), so RLS is on (event trigger
--                             rls_auto_enable) with NO policy, and anon / authenticated hold nothing.
--   public.app_config 'lwt_county_email'   the county's address. EMPTY until Fred has it: while empty the function refuses
--                             a county send and the page keeps Send Email off. Setting it is one UPDATE (audited table).
--
-- Audit (rule 8): derm.lwt_monthly_sends is OPTED OUT. It is an append-only machine log written by one function, never
-- edited by a person; it IS the record of what went to the county (as derm_email_sends is for the city emails).
-- 3NF: every column is a fact of the one send. period is stored because the bot's filing row lives outside this database.
-- Rollback beside this file.

begin;
set local lock_timeout = '3s';

create table derm.lwt_monthly_sends (
  id              bigint generated always as identity primary key,
  filing_id       bigint      not null,                 -- the GDO report bot's filing row (its id, outside this database)
  period          text        not null check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  file_format     text        not null check (file_format in ('pdf', 'xlsx')),
  file_name       text        not null,
  file_bytes      integer     not null check (file_bytes > 0),
  to_email        text        not null,
  is_test         boolean     not null default false,
  resend_email_id text,
  sent_by_email   text        not null,
  sent_at         timestamptz not null default now(),
  recorded        boolean,                              -- null on a test; true / false after the record that follows a county send
  record_note     text
);
comment on table derm.lwt_monthly_sends is
  'Trello #238 (2026-11-21): every Monthly Report email the lwt-monthly edge function sent, to the county or a test copy (is_test). Written only by that function with the service key; append-only by use. Opted out of audit: it is the record.';
create index lwt_monthly_sends_filing on derm.lwt_monthly_sends (filing_id, sent_at desc);

-- To take a role off an object, REVOKE ALL (root CLAUDE.md: a named list misses MAINTAIN on PG17).
revoke all on derm.lwt_monthly_sends from public, anon, authenticated;
revoke all on sequence derm.lwt_monthly_sends_id_seq from public, anon, authenticated;
grant select, insert, update on derm.lwt_monthly_sends to service_role;
grant usage on sequence derm.lwt_monthly_sends_id_seq to service_role;

insert into public.app_config (key, value) values ('lwt_county_email', '') on conflict (key) do nothing;

-- VERIFY
do $v$
declare v_acl text;
begin
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'derm' and c.relname = 'lwt_monthly_sends' and c.relrowsecurity) then
    raise exception 'VERIFY: RLS is not on derm.lwt_monthly_sends';
  end if;
  if has_table_privilege('authenticated', 'derm.lwt_monthly_sends', 'SELECT')
     or has_table_privilege('anon', 'derm.lwt_monthly_sends', 'SELECT')
     or has_table_privilege('authenticated', 'derm.lwt_monthly_sends', 'INSERT') then
    raise exception 'VERIFY: an API role can reach derm.lwt_monthly_sends';
  end if;
  if not has_table_privilege('service_role', 'derm.lwt_monthly_sends', 'INSERT') then
    raise exception 'VERIFY: service_role cannot write derm.lwt_monthly_sends';
  end if;
  select string_agg(a.grantee::regrole::text || ':' || a.privilege_type, ',' order by 1)
    into v_acl from pg_class c join pg_namespace n on n.oid = c.relnamespace, aclexplode(c.relacl) a
   where n.nspname = 'derm' and c.relname = 'lwt_monthly_sends' and a.grantee <> c.relowner;
  -- db_backup_reader reads every table of the backed-up schemas by default privileges (services/db-backup), on purpose.
  if v_acl is distinct from 'db_backup_reader:SELECT,service_role:INSERT,service_role:SELECT,service_role:UPDATE' then
    raise exception 'VERIFY: unexpected grants on derm.lwt_monthly_sends: %', v_acl;
  end if;
  if (select value from public.app_config where key = 'lwt_county_email') is null then
    raise exception 'VERIFY: app_config lwt_county_email is missing';
  end if;
end $v$;

commit;
