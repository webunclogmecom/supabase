-- 2026-11-25_0300_derm_visit_prints.sql  (Trello #248 l5YyxQAD)
--
-- WHY. Diego, 2026-11-24 (#new-app-issues): a status that says Printed or Missing Document, set by itself when someone
-- prints, so the same manifest is not printed twice. Fred, 2026-11-25: a printer icon with a hover card (when, the address
-- sheet number, who), a warning before generating again, no "mark not printed"; then "build it" (D1: pressing Generate
-- counts as printed). Measured the same night: 129 of the 332 visits on a Miami-Dade sheet are on 2 or more sheets
-- (sheets 1160 and 1161, 9 seconds apart, the same 4 visits), and WHO made a sheet was never saved (the PDF service
-- writes the registers as postgres).
--
-- WHAT.
--   1. derm.visit_prints: one row per visit per print: visit, sheet number, form, when, who (an employee, NULL when not
--      known), source ('generate' = written at Generate from now on, 'history' = read once from the registers below).
--      Not the registers themselves: derm.address_sheets / address_sheet_clients (Miami-Dade, a new number per print) and
--      derm.generated_visit_sheets (Broward, ONE number per visit, re-used on a reprint; its regenerate_count also moves
--      when the stored PDF is recorded, so it cannot count prints) stay exactly as they are.
--   2. History, once: every live Miami-Dade sheet's visits (at the sheet's created_at) and every live Broward visit sheet
--      (at its generated_at). Broward reprints before today are not known; their person never is.
--   3. derm.fn_record_prints(visit_ids, sheet_nos, form_kind): called by edge fn generate-derm-address-preview WITH THE
--      SIGNED-IN PERSON'S TOKEN right after the PDF is made. The person is hr.fn_access_caller() (the one rule), never a
--      value from the request. A pair is recorded only when the register holds it and was written in the last 15 minutes,
--      so nobody can invent or back-date a print; the same pair twice within a minute is recorded once.
--      SECURITY DEFINER, search_path '', EXECUTE for authenticated only.
--   4. derm.v_visit_prints: what the apps read (no address, no email): visit, sheet, form, when, source, the person's
--      name and colour, and how many visits are on that sheet. Owner rights (the base table has no grant), SELECT for
--      authenticated only.
-- Rule 8 (audit): derm.visit_prints OPTS IN (audit_visit_prints).
-- ROLLBACK: 2026-11-25_0300_derm_visit_prints_rollback.sql drops the view, the function and the table.

begin;
set local lock_timeout = '3s';

create table derm.visit_prints (
  id          bigint generated always as identity primary key,
  visit_id    bigint not null references public.visits(id),
  sheet_no    bigint not null check (sheet_no >= 1000),
  form_kind   text   not null check (form_kind in ('derm-v4', 'fdep-62-705.300-3')),
  printed_at  timestamptz not null default now(),
  printed_by  bigint references public.employees(id),
  source      text   not null check (source in ('generate', 'history')),
  created_at  timestamptz not null default now()
);
comment on table derm.visit_prints is
  'One row per visit per printed DERM / FDEP sheet (Trello #248). Written by derm.fn_record_prints at Generate; history read once from the sheet registers. Read through derm.v_visit_prints.';
create index visit_prints_visit_id_idx on derm.visit_prints (visit_id);
create index visit_prints_sheet_no_idx on derm.visit_prints (sheet_no);
create index visit_prints_printed_by_idx on derm.visit_prints (printed_by);
create unique index visit_prints_history_uq on derm.visit_prints (visit_id, sheet_no) where source = 'history';
alter table derm.visit_prints enable row level security;
revoke all on derm.visit_prints from public, anon, authenticated;
create trigger audit_visit_prints after insert or update or delete on derm.visit_prints
  for each row execute function audit.log_change();

-- 2. History.
insert into derm.visit_prints (visit_id, sheet_no, form_kind, printed_at, printed_by, source)
select distinct on (c.visit_id, s.sheet_no) c.visit_id, s.sheet_no, coalesce(s.form_kind, 'derm-v4'), s.created_at, null, 'history'
  from derm.address_sheets s
  join derm.address_sheet_clients c on c.sheet_id = s.id
 where s.deleted_at is null and c.visit_id is not null
 order by c.visit_id, s.sheet_no;
insert into derm.visit_prints (visit_id, sheet_no, form_kind, printed_at, printed_by, source)
select g.visit_id, g.sheet_no, g.form_kind, g.generated_at, null, 'history'
  from derm.generated_visit_sheets g
 where g.deleted_at is null;

-- 3. The writer.
create or replace function derm.fn_record_prints(p_visit_ids bigint[], p_sheet_nos bigint[], p_form_kind text)
returns integer
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_emp bigint := hr.fn_access_caller();
  v_n   integer;
begin
  if v_emp is null then
    raise exception 'Sign in with your UnclogMe staff account.' using errcode = '42501';
  end if;
  if p_form_kind is null or p_form_kind not in ('derm-v4', 'fdep-62-705.300-3') then
    raise exception 'Unknown form %', p_form_kind using errcode = '22023';
  end if;
  if coalesce(cardinality(p_visit_ids), 0) = 0 or cardinality(p_visit_ids) <> coalesce(cardinality(p_sheet_nos), -1)
     or cardinality(p_visit_ids) > 200 then
    raise exception 'visit_ids and sheet_nos must be two lists of the same length (1 to 200)' using errcode = '22023';
  end if;

  insert into derm.visit_prints (visit_id, sheet_no, form_kind, printed_at, printed_by, source)
  select distinct x.visit_id, x.sheet_no, p_form_kind, now(), v_emp, 'generate'
    from unnest(p_visit_ids, p_sheet_nos) as x(visit_id, sheet_no)
   where (
           (p_form_kind = 'derm-v4' and exists (
              select 1 from derm.address_sheets s join derm.address_sheet_clients c on c.sheet_id = s.id
               where s.sheet_no = x.sheet_no and c.visit_id = x.visit_id and s.deleted_at is null
                 and s.created_at > now() - interval '15 minutes'))
        or (p_form_kind = 'fdep-62-705.300-3' and exists (
              select 1 from derm.generated_visit_sheets g
               where g.visit_id = x.visit_id and g.sheet_no = x.sheet_no and g.deleted_at is null
                 and g.updated_at > now() - interval '15 minutes'))
         )
     and not exists (
           select 1 from derm.visit_prints p
            where p.visit_id = x.visit_id and p.sheet_no = x.sheet_no and p.source = 'generate'
              and p.printed_at > now() - interval '1 minute');
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function derm.fn_record_prints(bigint[], bigint[], text) from public, anon;
grant execute on function derm.fn_record_prints(bigint[], bigint[], text) to authenticated;

-- 4. The reader.
create view derm.v_visit_prints as
select p.visit_id, p.sheet_no, p.form_kind, p.printed_at, p.source,
       e.full_name as printed_by_name, e.color_hex as printed_by_color,
       (select count(distinct p2.visit_id) from derm.visit_prints p2
         where p2.sheet_no = p.sheet_no and p2.form_kind = p.form_kind)::int as visits_on_sheet
  from derm.visit_prints p
  left join public.employees e on e.id = p.printed_by;
comment on view derm.v_visit_prints is
  'Trello #248: every print of every visit, for the DERM Visits lists (printer icon, hover card, the warning before generating again).';
-- REVOKE ALL first: the schema's default privileges give authenticated INSERT / UPDATE / DELETE on a new view, and a
-- simple view is auto-updatable, so a GRANT SELECT alone would leave the log writable through it.
revoke all on derm.v_visit_prints from public, anon, authenticated;
grant select on derm.v_visit_prints to authenticated;

-- VERIFY.
do $verify$
declare v_dade int; v_bro int; v_hist int; v_multi int;
begin
  select count(*) into v_dade from (select distinct c.visit_id, s.sheet_no from derm.address_sheets s
    join derm.address_sheet_clients c on c.sheet_id = s.id where s.deleted_at is null and c.visit_id is not null) d;
  select count(*) into v_bro from derm.generated_visit_sheets where deleted_at is null;
  select count(*) into v_hist from derm.visit_prints where source = 'history';
  if v_hist <> v_dade + v_bro then raise exception 'VERIFY: history % <> % + %', v_hist, v_dade, v_bro; end if;
  select count(*) into v_multi from (select visit_id from derm.visit_prints where form_kind = 'derm-v4'
    group by visit_id having count(distinct sheet_no) > 1) m;
  if v_multi < 100 then raise exception 'VERIFY: only % visits on 2+ Miami-Dade sheets (129 measured)', v_multi; end if;
  if not exists (select 1 from pg_trigger where tgname = 'audit_visit_prints') then raise exception 'VERIFY: no audit trigger'; end if;
  if has_function_privilege('anon', 'derm.fn_record_prints(bigint[], bigint[], text)', 'execute') then
    raise exception 'VERIFY: anon can execute fn_record_prints'; end if;
  if has_table_privilege('authenticated', 'derm.visit_prints', 'select') then raise exception 'VERIFY: base table readable'; end if;
  if has_table_privilege('authenticated', 'derm.v_visit_prints', 'insert') or has_table_privilege('authenticated', 'derm.v_visit_prints', 'update')
     or has_table_privilege('authenticated', 'derm.v_visit_prints', 'delete') or has_table_privilege('authenticated', 'derm.visit_prints', 'insert')
     or has_table_privilege('anon', 'derm.v_visit_prints', 'select') then raise exception 'VERIFY: a write or anon read is open'; end if;
  if not has_table_privilege('authenticated', 'derm.v_visit_prints', 'select') then raise exception 'VERIFY: staff cannot read the view'; end if;
  raise notice 'VERIFY ok: history % (Dade % + Broward %), % visits on 2+ Dade sheets', v_hist, v_dade, v_bro, v_multi;
end $verify$;

commit;
