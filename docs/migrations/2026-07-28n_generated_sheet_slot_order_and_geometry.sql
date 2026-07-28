-- ============================================================================
-- 2026-07-28n — make generated-sheet auto-fill CORRECT (order + geometry + gate)
-- ============================================================================
-- Auto-fill has been built and armed since 2026-07-20 but has never once run in
-- production (derm.address_sheets is empty; zero cards carry stamp_placed_by =
-- 'stamp-studio-ai'). Before it is switched on, it had THREE defects that would
-- each have put wrong data on a customer-facing compliance document. All three
-- are fixed here. Provenance recording itself (the pdf-service half) is separate.
--
-- ── DEFECT 1: THE ROW ORDER WAS UNKNOWABLE, AND GUESSED WRONG ───────────────
-- fn_generated_sheet_slot replayed "siblings ordered by manifest id". Checked
-- against the two sheets physically in hand:
--   309944 (printed #1060) real order 195-MYK, 111-YC, 176-SOU
--                          by manifest id  195-MYK, 176-SOU, 111-YC   (2 and 3 swapped)
--   309898 (printed #1059) real order 089-COW, 208-HUB, 249-LOU, 248-CHA, 170-PV
--                          by manifest id  248-CHA, 170-PV, 208-HUB, 249-LOU, 089-COW
-- Nine candidate orderings were tested against both sheets (manifest id, visit id,
-- visit start_at, visit completed_at, client_code, client name, gdo_number,
-- address, manifest created_at). ALL NINE scored 0/2. The print order is simply
-- NOT derivable from stored data — it comes from the order the operator picks the
-- visits, which was never persisted.
--
-- Consequence if it had run: a stamp on the wrong client's row. The FP customer
-- blackout derives each client's visible band from that stamp, so client A would
-- have been shown client B's row on a DERM manifest. A live PII leak.
--
-- THE FIX: stop deriving it, record it. record_generated_address_sheet already
-- receives p_manifest_ids as an ARRAY, and an array is ordered — the generator
-- passes them in the order it prints them. The old code threw that away with
-- unnest(); WITH ORDINALITY keeps it. No signature change, so the pdf-service
-- contract is unchanged: it must simply pass the ids in printed order.
--
-- ⚠ AND IF THE ORDER IS UNKNOWN, WE DO NOT GUESS. fn_generated_sheet_slot now
-- returns NULL when the sheet has no recorded slots, and the trigger refuses to
-- place rather than falling back to row_index (which is card-creation order and
-- demonstrably unrelated to the printed order — on 309898 printed slot 1 is
-- row_index 5). Not stamping is a visible gap someone fixes; stamping the wrong
-- row is an invisible leak.
--
-- Multi-permit clients keep their expansion: a client with N ACTIVE well-formed
-- permits still occupies N rows (Casa Neos = 3), so slot is the client's POSITION
-- in print order and the starting row is the cumulative sum of rows before it.
--
-- ── DEFECT 2: THE Y GEOMETRY SAT ~3% TOO HIGH ──────────────────────────────
-- Measured against human stamps on generated sheet #1057 (830673) plus the two
-- sheets filled by hand today from their scans (#1059, #1060):
--   slot        1      2      3      4      5
--   was     25.98  34.62  41.58  49.10  57.25
--   actual  29.80  37.72  44.48  51.81  60.04     (mean of the verified sheets)
--   error   -3.82  -3.10  -2.90  -2.71  -2.79
-- Rows are only ~7.5-8% apart, so a 3% error pushes the stamp toward the row
-- ABOVE — compounding defect 1. x moves 6.82 -> 8.00 (human stamps cluster
-- 7.4-8.5). These are 5-slot GENERATED forms; scanned V4 forms have SIX slots and
-- a different pitch, which is why this function must only ever be applied to
-- sheets known to be generated.
--
-- ── DEFECT 3: THE PRODUCTION DOOR BLOCKED ITSELF ───────────────────────────
-- GATE 1 refuses any ticket that already carries a Stamp card, treating it as
-- handwritten evidence. But filing a manifest creates a card in the SAME
-- transaction (trg_zz_card_from_link -> _materialize_card), so the documented
-- flow "file the run, then Generate" could never pass its own gate. The 2026-07-21
-- validation only passed because its synthetic manifest had no linked visit and
-- therefore no card.
-- FIX: exempt cards that are OUR OWN materialiser (source='derm-link' with
-- flags->>'card_from_link'='true'). A human or vision-pass card (source
-- 'stamp-studio', 'claude-vision-v1', or any backfill) still refuses, and the
-- uploaded-photo clause stays unconditional — a photo always means handwritten.
--
-- AUDIT (ADR 010): derm.* Stamp-Studio working state, unaudited by design.
-- ============================================================================

begin;

-- 1) the recorded print order -------------------------------------------------
alter table derm.address_sheet_manifests add column if not exists slot integer;
comment on column derm.address_sheet_manifests.slot is
  'The manifest''s POSITION in the order the generator printed it on the sheet (1-based). The only place print order is knowable: it is operator selection order and is not derivable from any stored field. NULL means unrecorded -> auto-fill must refuse.';

-- 2) record it: an array is ordered, so keep the ordinality --------------------
create or replace function derm.record_generated_address_sheet(
  p_sheet_no bigint, p_bucket text, p_path text, p_manifest_ids bigint[]
) returns bigint
language plpgsql security definer set search_path to 'derm','public'
as $fn$
declare v_sheet_id bigint; v_bad text;
begin
  if p_sheet_no is null or p_manifest_ids is null or array_length(p_manifest_ids,1) is null then
    raise exception 'sheet_no and manifest_ids are required';
  end if;

  -- GATE 1 (defect 3): a photo ALWAYS refuses. A card refuses only when it is
  -- NOT our own link-materialised card and the ticket is not already this sheet.
  select string_agg(distinct k, ', ') into v_bad
  from (
    select coalesce(m.white_manifest_number, m.yellow_ticket_number) as k
      from public.derm_manifests m
     where m.id = any (p_manifest_ids) and m.deleted_at is null
       and (
         m.derm_address_url is not null
         or (
           exists (select 1 from derm.address_row_map a
                    where a.white_manifest_number = coalesce(m.white_manifest_number, m.yellow_ticket_number)
                      and not (a.source = 'derm-link' and coalesce(a.flags->>'card_from_link','') = 'true'))
           and not exists (
             select 1 from public.derm_manifests m2
               join derm.address_sheet_manifests l2 on l2.manifest_id = m2.id
               join derm.address_sheets s2 on s2.id = l2.sheet_id and s2.deleted_at is null
              where coalesce(m2.white_manifest_number, m2.yellow_ticket_number)
                    = coalesce(m.white_manifest_number, m.yellow_ticket_number)
                and m2.deleted_at is null and s2.sheet_no = p_sheet_no)
         )
       )
  ) q;
  if v_bad is not null then
    raise exception 'refusing: ticket(s) % already carry handwritten evidence (uploaded sheet photo or a human/vision Stamp card)', v_bad;
  end if;

  insert into derm.address_sheets (sheet_no, pdf_bucket, pdf_path)
  values (p_sheet_no, p_bucket, p_path)
  on conflict (sheet_no) do update set pdf_bucket = excluded.pdf_bucket,
                                       pdf_path = excluded.pdf_path,
                                       last_generated_at = now(), updated_at = now()
  returning id into v_sheet_id;

  -- ⚠ WITH ORDINALITY: this is the whole point. unnest() discarded the order.
  insert into derm.address_sheet_manifests (sheet_id, manifest_id, slot)
  select v_sheet_id, t.mid, t.ord
    from unnest(p_manifest_ids) with ordinality as t(mid, ord)
  on conflict (sheet_id, manifest_id) do update set slot = excluded.slot;

  return v_sheet_id;
end $fn$;

-- 3) slot from the RECORDED order, never guessed -------------------------------
create or replace function derm.fn_generated_sheet_slot(p_manifest_id bigint)
returns integer language sql stable security definer set search_path to 'derm','public'
as $fn$
  with me as (
    select m.id, coalesce(m.white_manifest_number, m.yellow_ticket_number) as k,
           (select l.slot from derm.address_sheet_manifests l
              join derm.address_sheets s on s.id = l.sheet_id and s.deleted_at is null
             where l.manifest_id = m.id order by l.slot nulls last limit 1) as my_slot
      from public.derm_manifests m
     where m.id = p_manifest_id and m.deleted_at is null
  ), before as (
    select greatest(1, (select count(*) from public.gdos gd
                         where gd.client_id = m.client_id and gd.status = 'ACTIVE'
                           and gd.gdo_number ~ '^GDO-[0-9]+$'))::int as rows_printed
      from public.derm_manifests m
      join me on coalesce(m.white_manifest_number, m.yellow_ticket_number) = me.k
      join derm.address_sheet_manifests l2 on l2.manifest_id = m.id
      join derm.address_sheets s2 on s2.id = l2.sheet_id and s2.deleted_at is null
     where m.deleted_at is null and l2.slot is not null and l2.slot < me.my_slot
  )
  -- NULL when the order was never recorded: caller must refuse, not guess.
  select case when (select my_slot from me) is not null
              then 1 + coalesce((select sum(rows_printed) from before), 0)::int
         end;
$fn$;

-- 4) corrected geometry for the 5-slot GENERATED form --------------------------
create or replace function derm.fn_generated_row_geometry(p_row_index integer)
returns table(o_page integer, o_x_pct numeric, o_y_pct numeric)
language sql immutable
as $fn$
  select ((p_row_index - 1) / 5) + 1,
         8.00::numeric,
         (array[29.80, 37.72, 44.48, 51.81, 60.04]::numeric[])[((p_row_index - 1) % 5) + 1]
$fn$;

-- 5) the trigger refuses when the slot is unknown ------------------------------
create or replace function derm.trg_autoplace_generated()
returns trigger language plpgsql as $fn$
declare geo record; v_slot integer;
begin
  if NEW.white_manifest_number is not null
     and NEW.stamp_placed_at is null
     and derm.fn_sheet_is_generated(NEW.white_manifest_number) then
    v_slot := derm.fn_generated_sheet_slot(NEW.matched_manifest_id);
    -- ⚠ NO row_index fallback. row_index is card-creation order and is provably
    -- unrelated to printed order (309898: printed slot 1 is row_index 5).
    -- Guessing here writes a stamp onto another client's row.
    if v_slot is not null then
      select * into geo from derm.fn_generated_row_geometry(v_slot);
      NEW.page            := geo.o_page;
      NEW.stamp_page      := geo.o_page;
      NEW.stamp_x_pct     := round(geo.o_x_pct, 3);
      NEW.stamp_y_pct     := round(geo.o_y_pct, 3);
      NEW.stamp_placed_at := now();
      NEW.stamp_placed_by := 'stamp-studio-ai';
    end if;
  end if;
  return NEW;
end $fn$;

commit;

-- ----------------------------------------------------------------------------
-- 2026-07-28n (amendment, same day) — restore two things the rewrite dropped.
-- Caught by the rolled-back test T3, which failed with 42P10 before anything
-- reached production. Rewriting a whole function loses whatever you forget to
-- copy, so both omissions are called out explicitly here:
--   (1) ON CONFLICT (sheet_no) WHERE deleted_at IS NULL — the unique index is
--       PARTIAL, so dropping the WHERE makes the conflict target unmatched and
--       the function raises 42P10 on its first real call.
--   (2) the derm_address_no mirror UPDATE (2026-07-21c) — DERM Tracker's slim
--       /manifests read surfaces the sheet number from that column. Losing it
--       would have left the app blind to sheet numbers while the provenance
--       tables silently held them. Mirror is keyed BY MANIFEST ID, never by
--       ticket number (that keying caused the 819788 ghost).
-- ----------------------------------------------------------------------------
create or replace function derm.record_generated_address_sheet(
  p_sheet_no bigint, p_bucket text, p_path text, p_manifest_ids bigint[]
) returns bigint
language plpgsql security definer set search_path to 'derm','public'
as $fn$
declare v_sheet_id bigint; v_bad text; v_other bigint;
begin
  if p_sheet_no is null or p_manifest_ids is null or array_length(p_manifest_ids,1) is null then
    raise exception 'sheet_no and manifest_ids are required';
  end if;

  select string_agg(distinct k, ', ') into v_bad
  from (
    select coalesce(m.white_manifest_number, m.yellow_ticket_number) as k
      from public.derm_manifests m
     where m.id = any (p_manifest_ids) and m.deleted_at is null
       and (
         m.derm_address_url is not null
         or (
           exists (select 1 from derm.address_row_map a
                    where a.white_manifest_number = coalesce(m.white_manifest_number, m.yellow_ticket_number)
                      and not (a.source = 'derm-link' and coalesce(a.flags->>'card_from_link','') = 'true'))
           and not exists (
             select 1 from public.derm_manifests m2
               join derm.address_sheet_manifests l2 on l2.manifest_id = m2.id
               join derm.address_sheets s2 on s2.id = l2.sheet_id and s2.deleted_at is null
              where coalesce(m2.white_manifest_number, m2.yellow_ticket_number)
                    = coalesce(m.white_manifest_number, m.yellow_ticket_number)
                and m2.deleted_at is null and s2.sheet_no = p_sheet_no)
         )
       )
  ) q;
  if v_bad is not null then
    raise exception 'refusing: ticket(s) % already carry handwritten evidence (uploaded sheet photo or a human/vision Stamp card)', v_bad;
  end if;

  -- no silent renumbering onto another live sheet
  select s.sheet_no into v_other
    from derm.address_sheet_manifests l
    join derm.address_sheets s on s.id = l.sheet_id and s.deleted_at is null
   where l.manifest_id = any (p_manifest_ids) and s.sheet_no <> p_sheet_no
   limit 1;
  if v_other is not null then
    raise exception 'refusing to renumber: one of these manifests already belongs to sheet %', v_other;
  end if;

  insert into derm.address_sheets (sheet_no, pdf_bucket, pdf_path)
  values (p_sheet_no, p_bucket, p_path)
  on conflict (sheet_no) where deleted_at is null      -- (1) PARTIAL index target
  do update set pdf_bucket = excluded.pdf_bucket,
                pdf_path   = excluded.pdf_path,
                last_generated_at = now()
  returning id into v_sheet_id;

  -- WITH ORDINALITY: the array is ordered and that order IS the printed order.
  insert into derm.address_sheet_manifests (sheet_id, manifest_id, slot)
  select v_sheet_id, t.mid, t.ord
    from unnest(p_manifest_ids) with ordinality as t(mid, ord)
  on conflict (sheet_id, manifest_id) do update set slot = excluded.slot;

  -- (2) the derm_address_no mirror, keyed BY MANIFEST ID
  update public.derm_manifests m
     set derm_address_no = p_sheet_no
   where m.id = any (p_manifest_ids)
     and m.derm_address_no is distinct from p_sheet_no;

  return v_sheet_id;
end $fn$;
