-- 2026-09-04_1738_company_hauler_licenses.sql
--
-- WHY. Fred, 2026-09-04, giving the canonical table for the first time:
--   Dade    - Hauler license LW-1133     · Decals: Moises C1184, David C0976
--   Broward - Hauler license WT-26-0104  · Decals: Moises 07675, David 07058
--
-- The DECAL half already lives in public.vehicle_decals and its 4 rows match that statement byte for
-- byte, so this migration does NOT touch it. What had no home anywhere in the database was the
-- COMPANY-level hauler license, one per jurisdiction. It existed only as a hard-coded TypeScript
-- literal in two edge functions, which is how it came to be marked "From Database" on Yannick's
-- Broward manifest config while being readable from no table at all.
--
-- 🛑 THIS CONTRADICTS A COMMENT IN SHIPPED CODE, DELIBERATELY.
-- supabase/functions/_shared/city-letter.ts:40 reads:
--     "These are the company DECAL numbers, one per county. They are NOT the hauler licence number
--      (#1404-25)"
-- directly above `DERM_DECALS = 'Miami-DADE: LW 1133 &middot; Broward: WT-26-0104'`.
-- Fred says those two numbers ARE the hauler licenses, and the per-truck numbers (C1184 / C0976 /
-- 07675 / 07058) are the decals. Fred outranks the comment. The comment and the constant are LEFT
-- UNCHANGED by this migration: correcting a live edge function is a separate change with its own
-- verification, and rewriting it here would bury the disagreement instead of recording it.
-- Whoever fixes that file: the constant is ALSO duplicated at
-- supabase/functions/send-visit-photos-email/index.ts:307.
--
-- 🟡 TWO THINGS DELIBERATELY NOT RESOLVED HERE, both asked of Fred:
--   1. #1404-25. docs/company.md:16 calls it "DERM License: Permit #1404-25 (active 2025-2026)" and
--      memory calls it the Miami-Dade Licensed Grease Trap Hauler number. If LW-1133 is the Dade
--      hauler license, these are either two different credentials or one of the two records is wrong.
--      No row is written for it until that is answered. Do NOT guess and backfill one.
--   2. Spelling. Fred wrote `LW-1133` with a hyphen; the shipped constant is `LW 1133` with a space.
--      Stored exactly as Fred wrote it. If the hyphen is wrong it is a one-row UPDATE, but on a
--      regulatory form the exact string matters, so it is flagged rather than normalised.
--
-- WHAT THIS IS FOR. The Broward Address (FDEP form 62-705.300(3)) has a `Hauler License #` field.
-- Fred's decision, same day: it carries WT-26-0104. Reading it from here instead of hard-coding it a
-- third time is the whole point of the table.
--
-- SHAPE. Mirrors public.vehicle_decals exactly: audit trigger, updated_at trigger, RLS enabled,
-- SELECT to authenticated + service_role + yannick_readonly, and NO anon grant of any kind.
--
-- Related: Building Apps/DERM Tracker/docs/broward-address-audit.md (D3),
--          docs/reference/company-credentials.md

-- NO explicit begin/commit: the Management API runs the whole body as ONE implicit transaction, so a
-- body without COMMIT; is atomic. A mid-body COMMIT; would split it in two and a later failure would
-- leave the first half applied. See memory reference_a_migration_containing_commit_is_not_atomic.

create table if not exists public.company_hauler_licenses (
  id             bigserial primary key,
  jurisdiction   text        not null,
  license_number text        not null,
  status         text        not null default 'ACTIVE',
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint company_hauler_licenses_jurisdiction_chk
    check (jurisdiction in ('Miami-Dade', 'Broward')),
  constraint company_hauler_licenses_status_chk
    check (status in ('ACTIVE', 'INACTIVE')),
  constraint company_hauler_licenses_number_nonblank_chk
    check (btrim(license_number) <> '')
);

comment on table public.company_hauler_licenses is
  'COMPANY-level grease waste hauler license, one per jurisdiction. Distinct from public.vehicle_decals, '
  'which is the PER-TRUCK decal. Source: Fred, 2026-09-04. Printed on regulatory forms (the FDEP '
  'Broward manifest 62-705.300(3) Hauler License # field), so treat the exact string as load-bearing. '
  'See docs/migrations/2026-09-04_1738_company_hauler_licenses.sql for the contradiction with '
  'city-letter.ts and the two open questions.';

comment on column public.company_hauler_licenses.license_number is
  'Exact string as issued. Do NOT normalise spacing or punctuation; it is printed on state forms.';

-- One ACTIVE license per jurisdiction. Partial so a superseded license can be kept as INACTIVE
-- history rather than deleted (estate rule: never hard-delete business data).
create unique index if not exists company_hauler_licenses_active_uniq
  on public.company_hauler_licenses (jurisdiction)
  where status = 'ACTIVE';

drop trigger if exists trg_company_hauler_licenses_updated_at on public.company_hauler_licenses;
create trigger trg_company_hauler_licenses_updated_at
  before update on public.company_hauler_licenses
  for each row execute function public.set_updated_at();

drop trigger if exists audit_company_hauler_licenses on public.company_hauler_licenses;
create trigger audit_company_hauler_licenses
  after insert or update or delete on public.company_hauler_licenses
  for each row execute function audit.log_change();

alter table public.company_hauler_licenses enable row level security;

drop policy if exists company_hauler_licenses_service_role_all on public.company_hauler_licenses;
create policy company_hauler_licenses_service_role_all
  on public.company_hauler_licenses for all to service_role using (true) with check (true);

drop policy if exists company_hauler_licenses_authn_read on public.company_hauler_licenses;
create policy company_hauler_licenses_authn_read
  on public.company_hauler_licenses for select to authenticated using (true);

revoke all on public.company_hauler_licenses from public;
grant select on public.company_hauler_licenses to authenticated;
grant select on public.company_hauler_licenses to yannick_readonly;
grant all    on public.company_hauler_licenses to service_role;
grant usage, select on sequence public.company_hauler_licenses_id_seq to service_role;

-- The two rows, verbatim from Fred.
insert into public.company_hauler_licenses (jurisdiction, license_number, notes)
values
  ('Miami-Dade', 'LW-1133',
   'Fred 2026-09-04. Shipped code spells it "LW 1133" (space) at _shared/city-letter.ts:44 and '
   'send-visit-photos-email/index.ts:307, and labels it a DECAL. Both flagged, neither changed here.'),
  ('Broward', 'WT-26-0104',
   'Fred 2026-09-04. Goes in the Hauler License # field of FDEP form 62-705.300(3).')
on conflict do nothing;
