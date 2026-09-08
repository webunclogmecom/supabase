-- 2026-09-07_2240  Broward FDEP: the GENERATION-TIME sheet register, and the adoption
--                  that stops the printed number and the stored number diverging.
--
-- Fred: "now wire it."
--
-- ============================================================================
-- WHY THIS EXISTS
-- ============================================================================
-- The FDEP sheet's top-left "#" box is PRINTED. The number therefore has to be
-- decided at GENERATION, before the driver leaves. But at generation there is no
-- manifest: a manifest needs a dump_ticket_date and a disposal_facility_id, both
-- of which only exist after the dump. derm.manifest_visit_sheets is keyed
-- (manifest_id, visit_id) with manifest_id NOT NULL, so it structurally cannot
-- hold a generated-but-not-yet-filed sheet.
--
-- The DADE PATH ALREADY SOLVED THIS and its answer is the precedent followed
-- here. public.record_generated_sheet_preview is keyed on CLIENTS, not
-- manifests, and its own comment says why: "at generation time neither exists
-- yet ... The only durable fact here is 'sheet N was printed for these clients'".
-- derm.fn_resolve_generated_sheet_for_ticket links it to the ticket afterwards.
--
-- The Broward analogue is the VISIT, and it is strictly better than the Dade one:
-- Dade has to resolve later on an exact unambiguous CLIENT-SET match, which can
-- decline; a visit id is exact, so adoption at upload can never be ambiguous.
--
-- ============================================================================
-- 🛑 THE FAILURE THIS PREVENTS, AND WHY NOTHING WOULD HAVE RAISED
-- ============================================================================
-- public.record_manifest_visit_sheet (shipped 2026-09-07_1710) calls
--   v_sheet := nextval('public.derm_broward_address_seq')
-- whenever the (manifest_id, visit_id) pair carries no sheet_no yet. If
-- generation allocated a number too, and stored it anywhere else, the driver's
-- PAPER and the register would carry DIFFERENT numbers for the same physical
-- sheet.
--   * manifest_visit_sheets_sheet_no_uniq is a per-row unique index. It cannot
--     see a duplicate that lives in another table.
--   * derm_broward_address_seq is at last_value=10000, is_called=false. NEITHER
--     allocator has ever run, so no existing row would expose the divergence.
--   * The first live Broward dump would be the first chance to notice, on paper.
-- That is the 2026-08-04 mis-stamp class of defect: a generated sheet number
-- resolved onto the wrong physical piece of paper.
--
-- The fix is one lookup: record_manifest_visit_sheet now ADOPTS the printed
-- number when one exists, and only mints when there is genuinely none (a sheet
-- filled on a blank pad the office never generated, which is how every Broward
-- manifest in history was filed).
--
-- ============================================================================
-- WHAT THIS DOES NOT DO, DELIBERATELY
-- ============================================================================
-- 1. It does NOT write derm.address_sheets. That table is the MIAMI-DADE
--    register and writing an FDEP sheet into it would arm the Dade five-row
--    auto-placement geometry: derm.fn_sheet_is_generated keys on the TICKET, and
--    re-measured today, ZERO function bodies in public/derm/ops/customer/client
--    read derm.address_sheets.form_kind (positive control: 9 read address_sheets
--    itself). form_kind there is decorative, so "we set form_kind so the ladder
--    ignores it" would be a no-op reported as a guard.
--    Related: derm.address_sheet_clients.rows_printed is frozen as the client's
--    GDO count and drives the five-per-page cumulative window in
--    derm.v_sheet_printed_rows. That column has no meaning for a form with one
--    visit per page and no GDO concept.
-- 2. It does NOT disarm the Dade ladder on the 7 live Broward tickets that
--    already have derm.address_sheets rows (310429, 310590, 310607, 311045,
--    311780, 312433, 312500) or touch the 31 stamp-studio-ai cards on them.
--    Those are CORRECT for the Dade paper that physically exists. Gating the
--    ladder is its own change, and it is inherited, not introduced here.
-- 3. It does NOT renumber the 41 historical Broward manifests carrying a
--    Dade-series derm_address_no. D11 is open.
--
-- ============================================================================
-- ALSO IN HERE: two repairs in the objects this touches
-- ============================================================================
-- A. public.manifest_pickable_visits silently LOST security_invoker=true.
--    2026-09-07_1338 set it and recorded a verification line; four hours later
--    2026-09-07_1610_repoint_dump_consumers.sql recreated the view with no WITH
--    clause and reloptions came back NULL. The view is owned by postgres
--    (BYPASSRLS), so it currently reads past RLS. Latent only because every
--    relevant authenticated policy is USING(true) -- but the earlier migration's
--    own verification record is false as it stands, and this is the second time
--    the option has been lost. ALTER VIEW SET, not a recreate: DROP VIEW discards
--    grants.
-- B. public.derm_broward_address_seq grants authenticated USAGE and anon SELECT.
--    Neither was in any migration body; both come from Supabase's ALTER DEFAULT
--    PRIVILEGES. public.next_broward_address_id() was carefully granted to
--    service_role only, and that revoke is BYPASSABLE while any signed-in browser
--    can call nextval() on the sequence directly. A privilege argument that rests
--    on the function grant alone is measuring the wrong object.
--
-- Verified before writing: derm.manifest_visit_sheets has 0 rows,
-- derm_broward_address_seq last_value=10000 is_called=false, and both
-- record_manifest_visit_sheet and next_broward_address_id are SECURITY DEFINER
-- owned by postgres -- so revoking the sequence grants cannot break either.
-- ⚠ THE VERIFY BLOCK BELOW BURNS SHEET NUMBER 10000. nextval() is NOT
-- transactional, so the behaviour probe's allocation survives its own rollback.
-- The first real Broward sheet will therefore be 10001, not 10000. That is the
-- same accepted behaviour as the Dade series, whose gaps are documented in
-- pdf-service rule 5 ("previews consume-but-don't-store; sequence gaps are
-- expected"). It is worth one burned number to prove the allocator is idempotent
-- against the live function rather than against a reading of it.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. The register. Visit-grain, because that is what exists at generation.
-- ---------------------------------------------------------------------------
create table if not exists derm.generated_visit_sheets (
  visit_id         bigint      primary key references public.visits(id),
  sheet_no         bigint      not null,
  form_kind        text        not null default 'fdep-62-705.300-3',
  pdf_bucket       text,
  pdf_path         text,
  generated_at     timestamptz not null default now(),
  regenerated_at   timestamptz,
  regenerate_count integer     not null default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz,
  constraint generated_visit_sheets_sheet_no_chk   check (sheet_no >= 10000),
  constraint generated_visit_sheets_form_kind_chk  check (form_kind = 'fdep-62-705.300-3'),
  constraint generated_visit_sheets_pdf_path_chk   check (pdf_path is null or btrim(pdf_path) <> ''),
  constraint generated_visit_sheets_pdf_bucket_chk check (pdf_bucket is null or btrim(pdf_bucket) <> '')
);

comment on table derm.generated_visit_sheets is
  'One row per VISIT for which a Broward FDEP address sheet has been GENERATED. '
  'Exists before any manifest does, which is the whole point: the sheet number is '
  'printed on paper the driver carries away, so it must be decided at generation. '
  'public.record_manifest_visit_sheet ADOPTS sheet_no from here at photo upload. '
  'NEVER renumber a row: the number is on paper.';

comment on column derm.generated_visit_sheets.sheet_no is
  'From public.derm_broward_address_seq (the 10000 series). Allocated ONCE per visit. '
  'A regeneration reuses it and bumps regenerate_count.';

comment on column derm.generated_visit_sheets.pdf_bucket is
  'Bucket and path are stored SEPARATELY, never an absolute URL, so the generated '
  'sheet can be moved to a private bucket later without rewriting a stored string. '
  'Same reason derm.manifest_visit_sheets stores them separately.';

-- The number is unique across live rows, and it must also never collide with a
-- number the upload path minted. Partial, so a soft-deleted row frees nothing
-- (the paper still exists) but also never blocks.
create unique index if not exists generated_visit_sheets_sheet_no_uniq
  on derm.generated_visit_sheets (sheet_no) where deleted_at is null;

create index if not exists generated_visit_sheets_generated_at_idx
  on derm.generated_visit_sheets (generated_at desc);

-- Both triggers mirror derm.manifest_visit_sheets exactly (read off
-- pg_get_triggerdef, not guessed: the helper is set_updated_at, NOT
-- fn_set_updated_at, and the audit function is audit.log_change).
drop trigger if exists trg_generated_visit_sheets_updated_at on derm.generated_visit_sheets;
create trigger trg_generated_visit_sheets_updated_at
  before update on derm.generated_visit_sheets
  for each row execute function public.set_updated_at();

drop trigger if exists audit_generated_visit_sheets on derm.generated_visit_sheets;
create trigger audit_generated_visit_sheets
  after insert or delete or update on derm.generated_visit_sheets
  for each row execute function audit.log_change();

alter table derm.generated_visit_sheets enable row level security;

-- Privileges mirror derm.manifest_visit_sheets, which grants SELECT only: every
-- write goes through the SECURITY DEFINER function and runs as the owner, so no
-- role needs INSERT here. authenticated gets nothing yet because no app reads
-- this table; manifest_visit_sheets does grant it, and this can match the day a
-- UI needs to show a generated-but-not-yet-filed sheet.
revoke all on derm.generated_visit_sheets from public, anon, authenticated;
grant select on derm.generated_visit_sheets to service_role;

-- ---------------------------------------------------------------------------
-- 2. The allocator/recorder. IDEMPOTENT ON visit_id.
-- ---------------------------------------------------------------------------
-- Idempotence is not a nicety here. generate-derm-address-preview is deployed
-- verify_jwt=false with no handler-side auth, so every call is reachable by an
-- anonymous caller and every call is a WRITE that burns a sequence number.
-- Because this returns the EXISTING number for a visit that already has one,
-- repeated calls for the same visits burn nothing after the first. That is a
-- correctness requirement (never renumber) that happens to bound the damage.
-- It is NOT a substitute for closing that door, which is a separate decision.
create or replace function public.record_generated_visit_sheet(
  p_visit_id   bigint,
  p_pdf_bucket text default null,
  p_pdf_path   text default null
) returns bigint
language plpgsql
security definer
set search_path to 'public', 'derm', 'pg_temp'
as $fn$
declare
  v_sheet bigint;
  v_new   boolean := false;
begin
  if p_visit_id is null then
    raise exception 'A visit is required to generate an address sheet.'
      using errcode = '22023';
  end if;

  if not exists (select 1 from public.visits v where v.id = p_visit_id) then
    raise exception 'Visit % does not exist.', p_visit_id
      using errcode = '22023';
  end if;

  -- Reuse before minting. THE NUMBER IS ON PAPER.
  select g.sheet_no into v_sheet
    from derm.generated_visit_sheets g
   where g.visit_id = p_visit_id and g.deleted_at is null;

  if v_sheet is null then
    v_sheet := nextval('public.derm_broward_address_seq');
    v_new := true;
  end if;

  insert into derm.generated_visit_sheets
    (visit_id, sheet_no, pdf_bucket, pdf_path, generated_at, deleted_at)
  values
    (p_visit_id, v_sheet, nullif(btrim(p_pdf_bucket), ''), nullif(btrim(p_pdf_path), ''), now(), null)
  on conflict (visit_id) do update
    -- Only overwrite the PDF location when the caller actually supplied one:
    -- allocation happens BEFORE the render, so the first call of a pair passes
    -- nulls and must not erase the path a previous generation stored.
    set pdf_bucket       = coalesce(nullif(btrim(p_pdf_bucket), ''), derm.generated_visit_sheets.pdf_bucket),
        pdf_path         = coalesce(nullif(btrim(p_pdf_path), ''),   derm.generated_visit_sheets.pdf_path),
        regenerated_at   = case when v_new then null else now() end,
        regenerate_count = derm.generated_visit_sheets.regenerate_count
                           + case when v_new then 0 else 1 end,
        deleted_at       = null;
        -- sheet_no deliberately NOT in the update list. Never renumber.

  return v_sheet;
end;
$fn$;

comment on function public.record_generated_visit_sheet(bigint, text, text) is
  'Allocate (once) and record the Broward FDEP sheet number for one VISIT. '
  'Idempotent on visit_id: a second call returns the SAME number and bumps '
  'regenerate_count. Call with nulls to allocate before rendering, then again '
  'with the bucket and path once the PDF is stored.';

-- Supabase grants EXECUTE to PUBLIC at CREATE time, before any GRANT here runs,
-- and REVOKE FROM PUBLIC does not remove a by-name grant. Revoke by name too.
revoke all on function public.record_generated_visit_sheet(bigint, text, text) from public;
revoke all on function public.record_generated_visit_sheet(bigint, text, text) from anon;
revoke all on function public.record_generated_visit_sheet(bigint, text, text) from authenticated;
grant execute on function public.record_generated_visit_sheet(bigint, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 3. THE ADOPTION. record_manifest_visit_sheet stops minting over a printed number.
-- ---------------------------------------------------------------------------
-- Body extracted with pg_get_functiondef and edited in ONE place (the block
-- marked ADOPTION below). The signature is unchanged, so no DROP, no re-GRANT,
-- and no PGRST203 for a cached tab.
create or replace function public.record_manifest_visit_sheet(
  p_manifest_id bigint, p_visit_id bigint, p_photo_bucket text, p_photo_path text
) returns bigint
language plpgsql
security definer
set search_path to 'public', 'derm', 'pg_temp'
as $function$
declare
  v_client  bigint;
  v_bucket  text;
  v_sheet   bigint;
begin
  if p_manifest_id is null or p_visit_id is null then
    raise exception 'A manifest and a visit are both required to record an address sheet.'
      using errcode = '22023';
  end if;

  if coalesce(btrim(p_photo_bucket), '') = '' or coalesce(btrim(p_photo_path), '') = '' then
    raise exception 'The uploaded sheet needs both a storage bucket and a path. Got bucket %, path %.',
      coalesce(quote_literal(p_photo_bucket), 'NULL'), coalesce(quote_literal(p_photo_path), 'NULL')
      using errcode = '22023';
  end if;

  select m.client_id into v_client
    from public.derm_manifests m
   where m.id = p_manifest_id and m.deleted_at is null;

  if v_client is null then
    raise exception 'Manifest % does not exist or has been deleted.', p_manifest_id
      using errcode = '22023';
  end if;

  -- The visit must be ON this manifest. See refusal 2 in the header.
  if not exists (select 1 from public.manifest_visits mv
                  where mv.manifest_id = p_manifest_id and mv.visit_id = p_visit_id) then
    raise exception 'Visit % is not linked to manifest %, so a sheet cannot be attached to it. Link the visit first.',
      p_visit_id, p_manifest_id
      using errcode = '22023';
  end if;

  v_bucket := derm.fn_manifest_dump_bucket(p_manifest_id);
  if v_bucket <> 'BROWARD' then
    raise exception 'Manifest % was dumped at a % site. One address sheet per visit is the Broward FDEP form only; a Miami-Dade sheet covers several clients at once.',
      p_manifest_id, v_bucket
      using errcode = '22023';
  end if;

  -- Allocate a number only the first time. See the header: the paper is already printed.
  select s.sheet_no into v_sheet
    from derm.manifest_visit_sheets s
   where s.manifest_id = p_manifest_id and s.visit_id = p_visit_id;

  -- ===================== ADOPTION (2026-09-07_2240) =======================
  -- If the office GENERATED a sheet for this visit, the driver is holding paper
  -- with that number on it. Adopt it. Minting here instead would put a second,
  -- different number in the register for the same physical sheet, and nothing
  -- in the schema could see the divergence: the unique index on sheet_no is
  -- per-row within this table and cannot reach the generation register.
  if v_sheet is null then
    select g.sheet_no into v_sheet
      from derm.generated_visit_sheets g
     where g.visit_id = p_visit_id and g.deleted_at is null;
  end if;
  -- ========================================================================

  -- Still null means genuinely un-generated: a sheet filled on a blank pad the
  -- office never printed. That is how every Broward manifest in history was
  -- filed, so it stays supported rather than refused.
  if v_sheet is null then
    v_sheet := nextval('public.derm_broward_address_seq');
  end if;

  insert into derm.manifest_visit_sheets
    (manifest_id, visit_id, client_id, sheet_no, photo_bucket, photo_path, uploaded_at, deleted_at)
  values
    (p_manifest_id, p_visit_id, v_client, v_sheet, btrim(p_photo_bucket), btrim(p_photo_path), now(), null)
  on conflict (manifest_id, visit_id) do update
    set photo_bucket = excluded.photo_bucket,
        photo_path   = excluded.photo_path,
        uploaded_at  = excluded.uploaded_at,
        deleted_at   = null;
        -- sheet_no deliberately NOT updated: the number is on paper the driver carried.

  return v_sheet;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 4. REPAIR A: restore security_invoker on public.manifest_pickable_visits.
-- ---------------------------------------------------------------------------
alter view public.manifest_pickable_visits set (security_invoker = true);

-- ---------------------------------------------------------------------------
-- 5. REPAIR B: the Broward sequence is not a public toy.
-- ---------------------------------------------------------------------------
-- Safe because every sanctioned caller is SECURITY DEFINER owned by postgres:
--   public.next_broward_address_id()      SECURITY DEFINER  (verified)
--   public.record_manifest_visit_sheet()  SECURITY DEFINER  (verified)
--   public.record_generated_visit_sheet() SECURITY DEFINER  (created above)
revoke usage, select, update on sequence public.derm_broward_address_seq from authenticated;
revoke usage, select, update on sequence public.derm_broward_address_seq from anon;

commit;

-- ============================================================================
-- VERIFY. Every assertion below must pass. Run as one statement.
-- ============================================================================
do $verify$
declare
  n integer;
  t text;
  v_sheet_a bigint;
  v_sheet_b bigint;
  v_before  bigint;
begin
  -- ---- structure -----------------------------------------------------------
  select count(*) into n from information_schema.tables
   where table_schema = 'derm' and table_name = 'generated_visit_sheets';
  if n <> 1 then raise exception 'A1 FAILED: derm.generated_visit_sheets missing'; end if;

  select count(*) into n from information_schema.columns
   where table_schema = 'derm' and table_name = 'generated_visit_sheets'
     and column_name in ('visit_id','sheet_no','form_kind','pdf_bucket','pdf_path',
                         'generated_at','regenerated_at','regenerate_count','deleted_at');
  if n <> 9 then raise exception 'A2 FAILED: expected 9 named columns, got %', n; end if;

  -- visit_id is the PK, i.e. the grain really is the visit and not the manifest
  select count(*) into n from pg_constraint
   where conrelid = 'derm.generated_visit_sheets'::regclass and contype = 'p'
     and pg_get_constraintdef(oid) = 'PRIMARY KEY (visit_id)';
  if n <> 1 then raise exception 'A3 FAILED: PK is not PRIMARY KEY (visit_id)'; end if;

  select count(*) into n from pg_constraint
   where conrelid = 'derm.generated_visit_sheets'::regclass
     and conname = 'generated_visit_sheets_sheet_no_chk';
  if n <> 1 then raise exception 'A4 FAILED: sheet_no >= 10000 CHECK missing'; end if;

  select count(*) into n from pg_indexes
   where schemaname = 'derm' and tablename = 'generated_visit_sheets'
     and indexname = 'generated_visit_sheets_sheet_no_uniq';
  if n <> 1 then raise exception 'A5 FAILED: sheet_no unique index missing'; end if;

  -- ---- the adoption is really in the deployed body -------------------------
  select pg_get_functiondef(p.oid) into t from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'record_manifest_visit_sheet';
  if t not like '%generated_visit_sheets%' then
    raise exception 'A6 FAILED: record_manifest_visit_sheet does not consult the generation register';
  end if;
  if t not like '%ADOPTION (2026-09-07_2240)%' then
    raise exception 'A7 FAILED: the adoption block is not in the deployed body';
  end if;
  -- and it did NOT lose the guards it already had
  if t not like '%fn_manifest_dump_bucket%' then
    raise exception 'A8 FAILED: the BROWARD-only guard was lost';
  end if;
  if t not like '%is not linked to manifest%' then
    raise exception 'A9 FAILED: the visit-must-be-on-the-manifest guard was lost';
  end if;

  -- ---- privileges ----------------------------------------------------------
  if has_function_privilege('anon', 'public.record_generated_visit_sheet(bigint,text,text)', 'execute') then
    raise exception 'A10 FAILED: anon can execute record_generated_visit_sheet';
  end if;
  if has_function_privilege('authenticated', 'public.record_generated_visit_sheet(bigint,text,text)', 'execute') then
    raise exception 'A11 FAILED: authenticated can execute record_generated_visit_sheet';
  end if;
  if not has_function_privilege('service_role', 'public.record_generated_visit_sheet(bigint,text,text)', 'execute') then
    raise exception 'A12 FAILED: service_role CANNOT execute record_generated_visit_sheet';
  end if;
  if has_table_privilege('authenticated', 'derm.generated_visit_sheets', 'select') then
    raise exception 'A13 FAILED: authenticated can read derm.generated_visit_sheets';
  end if;
  if not has_table_privilege('service_role', 'derm.generated_visit_sheets', 'select') then
    raise exception 'A14 FAILED: service_role cannot read derm.generated_visit_sheets';
  end if;
  -- Nobody writes it directly. The SECURITY DEFINER function is the only door.
  if has_table_privilege('service_role', 'derm.generated_visit_sheets', 'insert') then
    raise exception 'A14b FAILED: service_role holds a direct INSERT it does not need';
  end if;
  select count(*) into n from pg_trigger
   where tgrelid = 'derm.generated_visit_sheets'::regclass and not tgisinternal;
  if n <> 2 then raise exception 'A14c FAILED: expected 2 triggers (audit + updated_at), got %', n; end if;

  -- sequence: authenticated and anon lost it, service_role kept it
  if has_sequence_privilege('authenticated', 'public.derm_broward_address_seq', 'usage') then
    raise exception 'A15 FAILED: authenticated still holds USAGE on derm_broward_address_seq';
  end if;
  if has_sequence_privilege('anon', 'public.derm_broward_address_seq', 'select') then
    raise exception 'A16 FAILED: anon still holds SELECT on derm_broward_address_seq';
  end if;
  if not has_sequence_privilege('service_role', 'public.derm_broward_address_seq', 'usage') then
    raise exception 'A17 FAILED: service_role lost USAGE on derm_broward_address_seq';
  end if;

  -- ---- repair A ------------------------------------------------------------
  select count(*) into n from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'public' and c.relname = 'manifest_pickable_visits'
     and c.reloptions @> array['security_invoker=true'];
  if n <> 1 then raise exception 'A18 FAILED: manifest_pickable_visits is not security_invoker'; end if;

  -- ---- BEHAVIOUR. A savepoint-wrapped probe that ALWAYS rolls back. --------
  -- A bare DO block COMMITS, so the write below is fenced by its own
  -- BEGIN..EXCEPTION sub-block with an unconditional re-raise at the end.
  select last_value into v_before from public.derm_broward_address_seq;
  begin
    -- allocate for a real visit
    v_sheet_a := public.record_generated_visit_sheet(
      (select v.id from public.visits v order by v.id limit 1), null, null);
    if v_sheet_a < 10000 then
      raise exception 'A19 FAILED: allocated % which is not in the 10000 series', v_sheet_a;
    end if;

    -- IDEMPOTENCE: the same visit must come back with the SAME number.
    v_sheet_b := public.record_generated_visit_sheet(
      (select v.id from public.visits v order by v.id limit 1), 'b', 'p/x.pdf');
    if v_sheet_a <> v_sheet_b then
      raise exception 'A20 FAILED: renumbered % -> % on the second call', v_sheet_a, v_sheet_b;
    end if;

    -- the second call recorded the path and counted the regeneration
    select regenerate_count into n from derm.generated_visit_sheets
     where visit_id = (select v.id from public.visits v order by v.id limit 1);
    if n <> 1 then raise exception 'A21 FAILED: regenerate_count is % not 1', n; end if;

    select pdf_path into t from derm.generated_visit_sheets
     where visit_id = (select v.id from public.visits v order by v.id limit 1);
    if t <> 'p/x.pdf' then raise exception 'A22 FAILED: pdf_path is % not p/x.pdf', t; end if;

    -- CONTROL: the probe is genuinely writing. If this row is absent the four
    -- assertions above passed vacuously.
    select count(*) into n from derm.generated_visit_sheets;
    if n <> 1 then raise exception 'A23 FAILED (CONTROL): probe wrote % rows, expected 1', n; end if;

    raise exception 'ROLLBACK_PROBE';
  exception
    when others then
      if sqlerrm <> 'ROLLBACK_PROBE' then raise; end if;
  end;

  -- the probe left nothing behind
  select count(*) into n from derm.generated_visit_sheets;
  if n <> 0 then raise exception 'A24 FAILED: probe left % rows behind', n; end if;

  raise notice 'ALL 26 ASSERTIONS PASSED';
end;
$verify$;
