-- 2026-08-06_1422 — read the printed ROSTER off the sheet, so a stamp's row is MEASURED not inferred
--
-- Fred: "can we keep the certainty really high so we minimize the stamping landing on another
-- clients row? think about this, maybe training, adapting a tool to this, or what."
--
-- THE IDEA. Today the auto-place reasons: "this sheet's client SET equals this ticket's client set,
-- therefore slot N is client X." That is an INFERENCE from set arithmetic, and it is the only thing
-- standing between us and a stamp on another client's row — which, via the FP blackout, would show
-- one client another client's line on a compliance document.
--
-- But the sheets already print the answer. Every Section B row reads, verbatim:
--     GDO-08940 | Facility Name | 091-SB Street Bar
--     GDO-12517 | Facility Name | 110-CLA Claudie
-- The CLIENT CODE is on the row. We already run a vision model over these scans to read the sheet
-- number; having it also read the ordered roster turns "slot N should be client X" from something we
-- deduce into something we OBSERVE. That is strictly stronger than any set-matching rule, and it is
-- the same lesson this codebase keeps relearning: measure the raw signal, do not trust a proxy.
--
-- WHAT THIS BUYS, CONCRETELY. It lets the two currently-stuck tickets resolve WITHOUT weakening the
-- cross-client guard — because the relaxations become conditional on a positive row-level reading:
--   * 310607 — sheets 1077 and 1078 have byte-identical rosters, so the resolver sees two candidates
--     and refuses. The paper reads 1078. A tie-break on the printed number is identification, not a
--     guess.
--   * 310590 — its sheet 1074 lists 9 facilities while only 8 manifests were filed (165-LPB's went to
--     310607 instead), so the exact-set test fails. Both pages read 1074, so the sheet IS its sheet.
--
-- 🛑 THIS TABLE ALONE CHANGES NOTHING. It only records what the vision pass saw. The resolver is NOT
-- touched here. The gate that consumes these rows ships separately and ONLY after the reads have been
-- checked against the actual images by eye — because a wrong roster read would authorise exactly the
-- mis-placement this exists to prevent. Capture first, verify, then gate.
--
-- ⚠ WE STILL MAY NOT MARK THE SHEETS (Fred, 2026-08-04). No QR, no barcode, no watermark. This reads
-- what DERM already prints. Do not revive marking as a "simpler" alternative.
--
-- 3NF: one row per (folder, page, printed row). `client_code_read` is what the model saw, NOT a FK —
-- deliberately, because it must be able to record a code that matches nothing (that is a finding, not
-- corruption). Resolution to a client happens at read time, never on write.
-- Audit: `derm.*` working-state lane is unaudited by design, consistent with address_sheet_scan_reads.

begin;

create table if not exists derm.address_sheet_row_reads (
  dump_folder        text    not null,
  page               int     not null check (page > 0),
  row_index          int     not null check (row_index > 0),   -- 1-based, top to bottom in Section B
  client_code_read   text,                                     -- e.g. '091-SB'; NULL = row present but unreadable
  facility_name_read text,
  confidence         text    check (confidence in ('high','low')),
  read_at            timestamptz not null default now(),
  primary key (dump_folder, page, row_index)
);

comment on table derm.address_sheet_row_reads is
  'What the vision pass read in each printed Section B row of a scanned DERM address sheet, in order. '
  'Exists so a stamp''s row can be MEASURED (does row N actually say 091-SB?) rather than inferred '
  'from client-set arithmetic. client_code_read is intentionally NOT a foreign key: a code matching '
  'nothing is a finding worth keeping, not a write to reject.';

-- Written only by the OCR edge function (service_role). The Studio does not read it directly; the
-- gate function below is the only consumer.
-- ⚠ Supabase ALTER DEFAULT PRIVILEGES grants new tables to anon AND authenticated — revoke by name,
-- and grant the WRITER explicitly (forgetting this 42501'd the sheet-number OCR on its first run).
revoke all on derm.address_sheet_row_reads from public, anon, authenticated;
grant select, insert, update, delete on derm.address_sheet_row_reads to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- The gate: does the PAPER agree that this row belongs to this client?
-- ─────────────────────────────────────────────────────────────────────────────
-- Returns TRUE  = the printed row says this client. Safe to stamp.
--         FALSE = the printed row says a DIFFERENT client. Never stamp.
--         NULL  = no usable read. Caller decides; the relaxed paths MUST treat NULL as refuse.
--
-- Deliberately compares the CLIENT CODE, not the facility name. The code ('062-TCE') is a short
-- high-signal token; the names are not distinctive — sheet 1081 page 2 carries BOTH
-- '061-TCE The carrot express 71st Collins' and '062-TCE The carrot express Aventura Mall', which a
-- name match would happily confuse. That pair is precisely the mis-place this is meant to catch.
create or replace function derm.fn_row_read_confirms(
  p_dump_folder text, p_page int, p_row_index int, p_client_code text)
returns boolean
language sql
stable
security definer
set search_path to 'derm', 'public'
as $$
  select case
           when r.client_code_read is null then null
           when r.confidence is distinct from 'high' then null
           else upper(trim(r.client_code_read)) = upper(trim(p_client_code))
         end
    from derm.address_sheet_row_reads r
   where r.dump_folder = p_dump_folder
     and r.page        = p_page
     and r.row_index   = p_row_index;
$$;

comment on function derm.fn_row_read_confirms(text,int,int,text) is
  'TRUE = the printed row names this client, FALSE = it names a different one, NULL = no usable read. '
  'Compares client CODE, never facility name (two "The carrot express" rows sit on one real sheet). '
  'A low-confidence read is treated as NO read, never as agreement.';

revoke all on function derm.fn_row_read_confirms(text,int,int,text) from public, anon, authenticated;
grant execute on function derm.fn_row_read_confirms(text,int,int,text) to service_role;

commit;

-- Next, in order, and NOT before: (1) extend ocr-address-sheet-number to populate this;
-- (2) run it on ticket-310590 / ticket-310607 / ticket-831938; (3) compare every read row against the
-- image BY EYE; (4) only then ship the resolver relaxation gated on fn_row_read_confirms.
