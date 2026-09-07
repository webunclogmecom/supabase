-- 2026-09-07_1610_broward_per_visit_sheets.sql
--
-- STEP 4 of the Broward FDEP manifest chain, and the last thing between here and the upload UI.
-- Creates the storage model for a per-visit Broward address sheet: a new table, a form discriminator
-- on the sheet register, a second number series starting at 10000, and its allocator.
--
-- WHY A NEW TABLE AND NOT A COLUMN. Fred, 2026-09-07: "if it's Broward we need to upload a picture
-- per visit we select." There is nowhere to put that today. public.derm_manifests.derm_address_url
-- is ONE scalar on a per-CLIENT row, and rule #10 makes a manifest exactly one (ticket, client)
-- pair. Measured: 3 live Broward manifests carry 2 or more visits (138 / 076-TCE, 729 / 205-SAS,
-- 1287 / 230-KRU, the last one a Pumping and a Cleaning four days apart). On those, a per-visit
-- upload written into the scalar would silently keep only the last photo, and the client would be
-- served a sheet describing a different visit. That is the failure this table exists to prevent.
--
-- WHY NOT MAKE THE MANIFEST THE VISIT INSTEAD. That was the alternative, and it is more invasive
-- than it looks: it requires dropping or re-keying derm_manifests_client_yt_unique, which IS rule
-- #10, and both find-or-create RPCs (public.file_manifest_on_shared_ticket and
-- derm.file_manifest_and_link) resolve a sibling with `... AND client_id = ... ORDER BY id LIMIT 1`,
-- so a second manifest per (client, ticket) makes both silently link the second visit to the FIRST
-- manifest. Two silent failures to buy one column. This model touches no existing key.
--
-- 🛑 derm_manifests.derm_address_url IS DELIBERATELY STILL WRITTEN for a Broward manifest, with that
-- client's FIRST sheet. It is read by roughly 19 catalogue objects (customer.work_orders,
-- derm.manifest_health, derm.visits.has_manifest, derm.ticket_page_images,
-- ops.v_derm_ticket_doc_gaps, ops.v_derm_row_completeness_gaps, public.trg_request_sheet_number_ocr
-- and more), and 0 of 712 live rows are NULL there, so a NULL is a row shape production has never
-- seen. Leaving it NULL would make every new Broward manifest a permanent P1 in /manifests/health
-- (derm.manifest_health.fully_complete requires it on BOTH jurisdiction branches) and would make
-- send-derm-email skip the send at its `missing_attachments` gate, which sits ~91 lines ABOVE the
-- redaction guard and would therefore defeat the D12 work before it was reached.
--
-- 🛑 derm_manifests.derm_address_no MUST NOT BE USED FOR THE BROWARD SHEET NUMBER. It is a scalar,
-- so it cannot hold two numbers for the 3 two-visit manifests, and derm.manifests falls back across
-- the whole ticket group with `ORDER BY s.sheet_no LIMIT 1`, which would display another visit's
-- state manifest number with no error and no writer to blame. The 10000 series lives on
-- derm.manifest_visit_sheets.sheet_no and nowhere else.
--
-- ⚠ form_kind ON derm.address_sheets IS NULLABLE, AND THE NULL IS LOAD-BEARING. All 48 existing
-- rows stay NULL, meaning "the historical world: the Miami-Dade DERM_V4.00 sheet". This is the
-- pattern the estate warns about (a column added later is NULL across all history and the NULL
-- silently carries the old semantics) and here that is exactly the intent, so it is written down:
-- NULL is not missing data and must never be backfilled. Fred, 2026-09-07: "this is only starting
-- today, new rules and config, Monday Sep 7th 2026, meaning we can't change old data for it."
--
-- ⚠ A SECOND SEQUENCE, NOT A CHANGED ALLOCATOR. public.next_derm_address_id() is a bare
-- `nextval('public.derm_address_seq')` and is left completely alone. Adding a parameter to it would
-- create a PostgREST OVERLOAD and answer 300 PGRST203 to any caller, the same trap step 3 avoided.
-- The Broward allocator is a separate function with its own name.
-- derm.address_sheets.sheet_no carries CHECK (sheet_no >= 1000), so 10000 passes unchanged.
-- Live Dade series today: 48 rows, 1064 to 1111, sequence last_value 1111. The two series cannot
-- collide for decades, and are distinguishable on sight.
--
-- RULE 8 (audit): OPT-IN. This table holds pointers to a regulator-facing compliance document that
-- is served to customers, so the hard rule applies ("No table that touches customer.*, billing, DERM
-- compliance, or webhook secrets is allowed to skip audit").
--
-- RULE 6 (never hard-delete): deleted_at, not DELETE. The FK to derm_manifests is ON DELETE CASCADE
-- only because a manifest is itself never hard-deleted; it is a belt, not the mechanism.
--
-- GRANTS: mirrors derm.address_sheets (authenticated=r, service_role=r) rather than
-- derm.redacted_manifest_docs (service_role only), because the upload screen has to show which of
-- the selected visits already carry a sheet. Writes go through SECURITY DEFINER RPCs, so no role
-- needs INSERT. anon gets nothing. Supabase applies ALTER DEFAULT PRIVILEGES at CREATE TIME, BEFORE
-- any GRANT in this body, and a REVOKE FROM PUBLIC cannot remove a grant made BY NAME, so the
-- verification block reads relacl and has_table_privilege rather than trusting the REVOKEs. This
-- estate has shipped that bug at least five times, most recently 2026-09-04_1738.

-- ---------------------------------------------------------------------------------------------
-- 1. The form discriminator on the sheet register.
-- ---------------------------------------------------------------------------------------------

alter table derm.address_sheets
  add column if not exists form_kind text;

alter table derm.address_sheets
  add constraint address_sheets_form_kind_chk
  check (form_kind is null or form_kind in ('derm-v4', 'fdep-62-705.300-3'));

comment on column derm.address_sheets.form_kind is
  'Which printed form this sheet is. NULL means the historical Miami-Dade DERM_V4.00 sheet and is '
  'DELIBERATE: all 48 pre-2026-09-07 rows are NULL and must never be backfilled. Forward-only per '
  'Fred 2026-09-07. Without this, derm.fn_sheet_is_generated keys only on the ticket and arms the '
  'Dade five-row auto-placement geometry for a portrait FDEP sheet.';

-- ---------------------------------------------------------------------------------------------
-- 2. The Broward number series and its allocator. The Dade one is untouched.
-- ---------------------------------------------------------------------------------------------

create sequence if not exists public.derm_broward_address_seq start with 10000 increment by 1;

comment on sequence public.derm_broward_address_seq is
  'Broward FDEP sheet numbers. Fred 2026-09-07 chose a new series from 10000 ("we do not know yet '
  'if broward will do it, or us, but for now, generate a new one, start at 10000"). Separate from '
  'public.derm_address_seq (Dade, at 1111) so neither series gaps the other.';

create or replace function public.next_broward_address_id()
returns bigint
language sql
security definer
set search_path = public, pg_temp
as $fn$ select nextval('public.derm_broward_address_seq') $fn$;

revoke all on function public.next_broward_address_id() from public;
revoke all on function public.next_broward_address_id() from anon, authenticated;
grant execute on function public.next_broward_address_id() to service_role;

-- ---------------------------------------------------------------------------------------------
-- 3. The per-visit sheet.
-- ---------------------------------------------------------------------------------------------

create table if not exists derm.manifest_visit_sheets (
  manifest_id   bigint      not null references public.derm_manifests(id) on delete cascade,
  visit_id      bigint      not null references public.visits(id),
  client_id     bigint      not null references public.clients(id),
  sheet_no      bigint,
  form_kind     text        not null default 'fdep-62-705.300-3',
  pdf_bucket    text,
  pdf_path      text,
  photo_bucket  text,
  photo_path    text,
  generated_at  timestamptz,
  uploaded_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  primary key (manifest_id, visit_id),
  constraint manifest_visit_sheets_form_kind_chk
    check (form_kind in ('fdep-62-705.300-3')),
  constraint manifest_visit_sheets_sheet_no_chk
    check (sheet_no is null or sheet_no >= 10000),
  constraint manifest_visit_sheets_pdf_path_chk
    check (pdf_path is null or btrim(pdf_path) <> ''),
  constraint manifest_visit_sheets_photo_path_chk
    check (photo_path is null or btrim(photo_path) <> '')
);

create index if not exists manifest_visit_sheets_visit_idx  on derm.manifest_visit_sheets (visit_id);
create index if not exists manifest_visit_sheets_client_idx on derm.manifest_visit_sheets (client_id);
create unique index if not exists manifest_visit_sheets_sheet_no_uniq
  on derm.manifest_visit_sheets (sheet_no) where sheet_no is not null and deleted_at is null;

comment on table derm.manifest_visit_sheets is
  'One FDEP Broward address sheet per VISIT. Exists because derm_manifests.derm_address_url is a '
  'single scalar on a per-CLIENT row while a Broward sheet is per visit, and 3 live Broward '
  'manifests already carry 2+ visits. Rule #10 (a manifest is one ticket-client pair) is untouched. '
  'Paths are stored as bucket + path, NEVER as an absolute public URL, so the object can move to a '
  'private bucket without rewriting any stored string.';

comment on column derm.manifest_visit_sheets.photo_path is
  'The uploaded photo of the signed sheet, as bucket + path. Deliberately NOT an absolute '
  '/object/public/ URL: 2,755 such stored URLs elsewhere in the estate are why a bucket flip would '
  'break 15 consumers at once.';

-- Rule 8: opt-in, and mandatory here (customer-facing DERM compliance).
drop trigger if exists audit_manifest_visit_sheets on derm.manifest_visit_sheets;
create trigger audit_manifest_visit_sheets
  after insert or update or delete on derm.manifest_visit_sheets
  for each row execute function audit.log_change();

drop trigger if exists trg_manifest_visit_sheets_updated_at on derm.manifest_visit_sheets;
create trigger trg_manifest_visit_sheets_updated_at
  before update on derm.manifest_visit_sheets
  for each row execute function public.set_updated_at();

alter table derm.manifest_visit_sheets enable row level security;

-- See the header: the default privileges have ALREADY been applied by CREATE TABLE, above this line.
revoke all on derm.manifest_visit_sheets from public;
revoke all on derm.manifest_visit_sheets from anon;
revoke all on derm.manifest_visit_sheets from authenticated;
grant select on derm.manifest_visit_sheets to authenticated;
grant select on derm.manifest_visit_sheets to service_role;

drop policy if exists manifest_visit_sheets_service_all on derm.manifest_visit_sheets;
create policy manifest_visit_sheets_service_all on derm.manifest_visit_sheets
  for all to service_role using (true) with check (true);

drop policy if exists manifest_visit_sheets_staff_read on derm.manifest_visit_sheets;
create policy manifest_visit_sheets_staff_read on derm.manifest_visit_sheets
  for select to authenticated using (true);

-- ---------------------------------------------------------------------------------------------
-- VERIFY.
-- ---------------------------------------------------------------------------------------------

do $$
declare
  v_txt text;
  v_n   int;
begin
  -- A. The historical NULLs are intact. This is the forward-only guarantee.
  select count(*) into v_n from derm.address_sheets where form_kind is not null;
  if v_n <> 0 then raise exception 'VERIFY A FAILED: % address_sheets rows were backfilled', v_n; end if;
  select count(*) into v_n from derm.address_sheets;
  if v_n <> 48 then raise exception 'VERIFY A2 FAILED: expected 48 sheets, found %', v_n; end if;

  -- B. The Dade allocator is byte-identical, i.e. untouched.
  select pg_get_functiondef(p.oid) into v_txt from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'next_derm_address_id';
  if position('derm_address_seq' in v_txt) = 0 or position('broward' in lower(v_txt)) > 0 then
    raise exception 'VERIFY B FAILED: the Dade allocator was modified';
  end if;
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'next_derm_address_id';
  if v_n <> 1 then raise exception 'VERIFY B2 FAILED: next_derm_address_id has % overloads', v_n; end if;

  -- C. The new series starts where Fred asked, and the CHECK admits it.
  if nextval('public.derm_broward_address_seq') <> 10000 then
    raise exception 'VERIFY C FAILED: the Broward series did not start at 10000';
  end if;
  perform setval('public.derm_broward_address_seq', 10000, false);   -- hand back the burned value

  -- D. THE ACL, read from the catalogue rather than inferred from the REVOKEs above.
  if has_table_privilege('anon', 'derm.manifest_visit_sheets', 'SELECT')
    then raise exception 'VERIFY D FAILED: anon can read the sheet table'; end if;
  if has_table_privilege('anon', 'derm.manifest_visit_sheets', 'INSERT')
    then raise exception 'VERIFY D2 FAILED: anon can write the sheet table'; end if;
  if has_table_privilege('authenticated', 'derm.manifest_visit_sheets', 'INSERT')
    then raise exception 'VERIFY D3 FAILED: authenticated can INSERT, default privileges leaked'; end if;
  if has_table_privilege('authenticated', 'derm.manifest_visit_sheets', 'DELETE')
    then raise exception 'VERIFY D4 FAILED: authenticated can DELETE, default privileges leaked'; end if;
  if not has_table_privilege('authenticated', 'derm.manifest_visit_sheets', 'SELECT')
    then raise exception 'VERIFY D5 FAILED: authenticated cannot read the sheet table'; end if;
  -- POSITIVE CONTROL for the probe itself: without this, D could pass on a broken reader.
  if not has_table_privilege('service_role', 'derm.manifest_visit_sheets', 'SELECT')
    then raise exception 'VERIFY D6 FAILED: control failed, the privilege reader is not working'; end if;

  -- E. Rule 8 and the updated_at trigger are actually attached.
  select count(*) into v_n from pg_trigger t join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'derm' and c.relname = 'manifest_visit_sheets' and not t.tgisinternal;
  if v_n <> 2 then raise exception 'VERIFY E FAILED: expected 2 triggers, found %', v_n; end if;

  -- F. RLS is on.
  select relrowsecurity into v_txt from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'derm' and c.relname = 'manifest_visit_sheets';
  if v_txt <> 'true' then raise exception 'VERIFY F FAILED: RLS is not enabled'; end if;

  -- G. The table can hold the shape it exists for: two visits on ONE manifest. Rolled back.
  begin
    insert into derm.manifest_visit_sheets (manifest_id, visit_id, client_id, sheet_no)
    select mv.manifest_id, mv.visit_id, m.client_id, 90000 + row_number() over (order by mv.visit_id)
      from public.manifest_visits mv
      join public.derm_manifests m on m.id = mv.manifest_id and m.deleted_at is null
     where mv.manifest_id = (
             select mv2.manifest_id from public.manifest_visits mv2
               join public.derm_manifests m2 on m2.id = mv2.manifest_id and m2.deleted_at is null
              where derm.fn_manifest_dump_bucket(m2.id) = 'BROWARD'
              group by mv2.manifest_id having count(*) > 1
              order by mv2.manifest_id limit 1);
    get diagnostics v_n = row_count;
    if v_n < 2 then
      raise exception 'VERIFY G FAILED: only % rows inserted for a two-visit manifest', v_n;
    end if;
    raise exception 'ZZ_ROLLBACK';
  exception when others then
    if sqlerrm <> 'ZZ_ROLLBACK' then raise; end if;
  end;

  select count(*) into v_n from derm.manifest_visit_sheets;
  if v_n <> 0 then raise exception 'VERIFY G2 FAILED: % probe rows survived', v_n; end if;

  raise notice 'VERIFY PASSED: 48 address_sheets rows still NULL form_kind; Dade allocator untouched with 1 overload; Broward series starts at 10000; ACL is authenticated=SELECT only with anon denied and the control passing; 2 triggers; RLS on; a two-visit manifest accepts two sheets and the probe rolled back';
end $$;
