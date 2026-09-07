-- 2026-09-07_1420_ticket_number_trim_and_source_guard.sql
--
-- STEP 2 of the Broward FDEP manifest chain. Stops a live source defect and repairs the 30 values it
-- has already produced, in one transaction, because doing either half alone is worse than doing
-- neither.
--
-- THE DEFECT. public.file_manifest does not btrim its p_number argument (measured: the live body
-- contains no 'btrim' at all). On 2026-09-07 at 14:52 UTC the DERM Tracker filed a dump whose number
-- was typed with a trailing space, so 8 live manifests carry '834986 ' rather than '834986'.
-- One real Dade dump, 8 clients (017-FIA, 025-GRO, 043-MIL, 168-AVA, 171-CAF, 214-MYK, 239-COM,
-- 244-URI), facility 2, dump date 2026-09-05, all 8 linked to visits.
--
-- 🛑 WHY BOTH HALVES MUST SHIP TOGETHER. Fix only the source and the next manifest filed on that
-- ticket is created as '834986' while the existing 8 stay '834986 ', which SPLITS one physical dump
-- into two ticket groups. Every ticket-keyed object in the estate then disagrees with itself:
-- derm.manifests groups on COALESCE(white, yellow), fn_resolve_generated_sheet_for_ticket matches a
-- sheet to a ticket, file_manifest_on_shared_ticket finds siblings by it. A split ticket is worse
-- than a uniformly untrimmed one.
--
-- 🛑 THE SCOPE IS SEVEN COLUMNS ACROSS SIX TABLES, NOT TWO. The implementation spec named
-- "the 8 rows and the stamp_sheet_status folder key". Measured by sweeping every text column in
-- public/derm/customer/ops/client/audit/sync/raw whose name matches manifest|ticket|folder|number|sheet
-- (27 candidates), the real set is:
--
--     public.derm_manifests.white_manifest_number        8 rows
--     derm.address_row_map.white_manifest_number         8 rows
--     derm.address_row_map.dump_folder                   8 rows
--     derm.address_sheet_scan_reads.dump_folder          2 rows
--     derm.sheet_number_ocr_attempts.dump_folder         2 rows
--     derm.stamp_sheet_status.dump_folder                1 row
--     derm.row_ocr_attempts.ticket                       1 row
--                                                       30 values
--
-- Trimming derm_manifests alone would leave address_row_map still holding '834986 ', breaking the
-- join between a manifest and its own stamp cards and orphaning them from the blackout pipeline.
--
-- PRE-FLIGHT, all measured before writing this file:
--   collisions: the trimmed value exists in 0 rows of derm_manifests, address_row_map,
--     stamp_sheet_status and address_sheet_scan_reads. Control: the UNtrimmed folder key returns 8,
--     so the probe can see a row when there is one.
--   trg_ae_ticket_key_unambiguous RAISES when a white number collides with an existing yellow-only
--     ticket key, and it fires on UPDATE. No yellow ticket equals '834986' (control: 168 yellow
--     tickets exist), so the UPDATE below cannot trip it.
--   0 rows hold an empty-string ticket number today.
--   0 of the 8 manifests serve a redacted document, so no customer-facing artefact depends on the
--     current value.
--
-- ⚠ I MIS-READ pg_trigger.tgtype ONCE WHILE PREPARING THIS AND IT NEARLY HID THE COLLISION RISK.
-- The bits are INSERT = 4, DELETE = 8, UPDATE = 16. Decoding 8 as UPDATE reports every BEFORE
-- trigger here as delete-only and makes the UPDATE look unguarded when it is not. The corrected
-- reading is that trg_ab_adopt_sibling_white, trg_ae_ticket_key_unambiguous and
-- trg_derm_inherit_ticket_fields all fire on INSERT+UPDATE.
--
-- 🛑 THE GUARD IS ONE BEFORE TRIGGER ON THE TABLE, NOT AN EDIT TO FIVE WRITERS. public.file_manifest,
-- public.file_manifest_on_shared_ticket, derm.file_manifest_and_link, public.edit_manifest and any
-- raw SQL all reach these columns. Editing each one means retyping five bodies, which this repo's
-- CREATE OR REPLACE rule identifies as the way clauses get silently deleted, and it misses the sixth
-- writer nobody remembered. Same reasoning as trg_ac_stamp_witness.
--
-- 🛑 IT MUST SORT BEFORE trg_ab_adopt_sibling_white. Triggers fire alphabetically, and that one
-- adopts a sibling's white number BY COMPARISON, so it has to see values that are already normalised.
-- Hence trg_aa_. Renaming it is a breaking change.
--
-- RULE 8 (audit): no new table. Of the six tables touched, derm_manifests, address_row_map and
-- stamp_sheet_status carry audit triggers, so those 17 values are recoverable from audit.logs.old_row.
-- The other three (address_sheet_scan_reads, sheet_number_ocr_attempts, row_ocr_attempts, 5 values)
-- are unaudited OCR bookkeeping. No JSON backup is written because the inverse is deterministic and
-- recorded here: append one trailing space to the exact keys 'ticket-834986' and '834986' in those
-- three tables. They are also regenerable by re-running the OCR sweeps.
--
-- NOT DONE HERE, deliberately: public.file_manifest's jurisdiction and facility hardening, which is
-- step 3 and needs the Broward county restriction decided with it.

-- ---------------------------------------------------------------------------------------------
-- 1. THE SOURCE GUARD. Every writer, one object.
-- ---------------------------------------------------------------------------------------------

create or replace function public.fn_normalize_ticket_numbers()
returns trigger
language plpgsql
as $$
begin
  -- btrim, then fold an all-whitespace value to NULL: '' is not a ticket number, and leaving it as
  -- an empty string would satisfy the CHECK below while meaning nothing.
  new.white_manifest_number := nullif(btrim(new.white_manifest_number), '');
  new.yellow_ticket_number  := nullif(btrim(new.yellow_ticket_number),  '');
  return new;
end;
$$;

comment on function public.fn_normalize_ticket_numbers() is
  'Normalises derm_manifests ticket numbers at the table, so every writer is covered without '
  'retyping five function bodies. Must sort before trg_ab_adopt_sibling_white, which compares them.';

drop trigger if exists trg_aa_normalize_ticket_numbers on public.derm_manifests;
create trigger trg_aa_normalize_ticket_numbers
  before insert or update on public.derm_manifests
  for each row execute function public.fn_normalize_ticket_numbers();

-- ---------------------------------------------------------------------------------------------
-- 2. THE REPAIR. All six tables, one transaction.
--
-- 🛑 THE ORDER IS LOAD-BEARING: EVERY derm.* TABLE FIRST, public.derm_manifests LAST.
-- The first attempt at this migration did derm_manifests first and ABORTED with
--     23505 duplicate key on address_row_map_natural_key
--     Key (dump_folder, page, row_index) = (ticket-834986, 1, 1) already exists
-- on a key that a pre-flight probe had measured as absent (0 rows) moments earlier. Both readings
-- were correct: the row did not exist before the migration, and my own earlier statement created it.
--
-- The mechanism, read off the live bodies rather than guessed:
--   derm.fn_resolve_card_manifest is an AFTER INSERT OR UPDATE trigger on public.derm_manifests. It
--   looks up cards by `r.white_manifest_number = COALESCE(NEW.white, NEW.yellow)`. The instant the
--   manifest is trimmed to '834986' while the cards still hold '834986 ', that lookup matches
--   NOTHING; the manifest has 8 manifest_visits links, so the function's second branch fires
--   `PERFORM derm._materialize_card(NEW.id)` and mints a BRAND NEW card at dump_folder
--   'ticket-834986', page 1, row_index 1. The subsequent folder trim then tries to move the old card
--   onto that same natural key.
--
-- Trimming the cards FIRST means the lookup finds them, takes the `SET matched_manifest_id` branch,
-- and never materialises anything. Verified by the row counts in VERIFY 3.
--
-- ⚠ A pre-flight collision probe cannot see this class of conflict, because the conflicting row does
-- not exist until the migration is half-applied. The only thing that catches it is a transaction:
-- the failed attempt wrote nothing, confirmed afterwards by six independent counts.
--
-- ⚠ Checked and harmless: derm.trg_generated_cards_follow_renumber also fires here, but it rewrites
-- `white_manifest_number` (never `dump_folder`) and only in the generated lane, so it cannot collide.
-- trg_zz_dirty_on_card_change will clear stamp_sheet_status.completed for this folder; measured, it
-- is ALREADY false with reopened_at NULL, so that is a no-op rather than a new human task.

update derm.address_row_map
   set white_manifest_number = btrim(white_manifest_number)
 where white_manifest_number is distinct from btrim(white_manifest_number);

update derm.address_row_map
   set dump_folder = btrim(dump_folder)
 where dump_folder is distinct from btrim(dump_folder);

update derm.address_sheet_scan_reads
   set dump_folder = btrim(dump_folder)
 where dump_folder is distinct from btrim(dump_folder);

update derm.sheet_number_ocr_attempts
   set dump_folder = btrim(dump_folder)
 where dump_folder is distinct from btrim(dump_folder);

update derm.stamp_sheet_status
   set dump_folder = btrim(dump_folder)
 where dump_folder is distinct from btrim(dump_folder);

update derm.row_ocr_attempts
   set ticket = btrim(ticket)
 where ticket is distinct from btrim(ticket);

-- LAST, now that every card already carries the trimmed key.
update public.derm_manifests
   set white_manifest_number = btrim(white_manifest_number)
 where white_manifest_number is distinct from btrim(white_manifest_number);

update public.derm_manifests
   set yellow_ticket_number = btrim(yellow_ticket_number)
 where yellow_ticket_number is distinct from btrim(yellow_ticket_number);

-- ---------------------------------------------------------------------------------------------
-- 3. THE CONSTRAINTS. VALIDATED, because step 2 leaves zero violators. If it did not, the ALTER
--    raises and this whole migration rolls back, which is the intended self-check.
-- ---------------------------------------------------------------------------------------------

alter table public.derm_manifests
  add constraint derm_manifests_white_number_trimmed_chk
  check (white_manifest_number is null or white_manifest_number = btrim(white_manifest_number));

alter table public.derm_manifests
  add constraint derm_manifests_yellow_number_trimmed_chk
  check (yellow_ticket_number is null or yellow_ticket_number = btrim(yellow_ticket_number));

-- ---------------------------------------------------------------------------------------------
-- VERIFY. Raises, and therefore rolls the migration back, on any failure.
-- ---------------------------------------------------------------------------------------------

do $$
declare
  v_untrimmed int;
  v_split     int;
  v_probe     text;
begin
  select (select count(*) from public.derm_manifests
           where white_manifest_number is distinct from btrim(white_manifest_number)
              or yellow_ticket_number  is distinct from btrim(yellow_ticket_number))
       + (select count(*) from derm.address_row_map
           where white_manifest_number is distinct from btrim(white_manifest_number)
              or dump_folder is distinct from btrim(dump_folder))
       + (select count(*) from derm.address_sheet_scan_reads
           where dump_folder is distinct from btrim(dump_folder))
       + (select count(*) from derm.sheet_number_ocr_attempts
           where dump_folder is distinct from btrim(dump_folder))
       + (select count(*) from derm.stamp_sheet_status
           where dump_folder is distinct from btrim(dump_folder))
       + (select count(*) from derm.row_ocr_attempts
           where ticket is distinct from btrim(ticket))
    into v_untrimmed;
  if v_untrimmed <> 0 then
    raise exception 'VERIFY 1 FAILED: % untrimmed values remain across the six tables', v_untrimmed;
  end if;

  -- The ticket must not have split: all 8 manifests, all 8 row-map cards and the one folder key
  -- must agree on the SAME trimmed value.
  select count(*) into v_split from public.derm_manifests where white_manifest_number = '834986';
  if v_split <> 8 then
    raise exception 'VERIFY 2 FAILED: expected 8 manifests on 834986, found %', v_split;
  end if;

  select count(*) into v_split from derm.address_row_map where dump_folder = 'ticket-834986';
  if v_split <> 8 then
    raise exception 'VERIFY 3 FAILED: expected 8 row-map cards on ticket-834986, found %', v_split;
  end if;

  select count(*) into v_split from derm.stamp_sheet_status where dump_folder = 'ticket-834986';
  if v_split <> 1 then
    raise exception 'VERIFY 4 FAILED: expected 1 stamp_sheet_status row, found %', v_split;
  end if;

  -- The links must have survived. 8 before, 8 after.
  select count(*) into v_split from public.manifest_visits mv
    where mv.manifest_id in (select id from public.derm_manifests where white_manifest_number='834986');
  if v_split <> 8 then
    raise exception 'VERIFY 5 FAILED: expected 8 manifest_visits links, found %', v_split;
  end if;

  -- The step-1 resolver must still agree, through its own btrim and now without needing it.
  if derm.fn_ticket_dump_bucket('834986') <> 'DADE' then
    raise exception 'VERIFY 6 FAILED: ticket 834986 no longer resolves to DADE';
  end if;

  -- THE SOURCE GUARD, EXERCISED rather than assumed. A PL/pgSQL body is not parsed until it runs,
  -- so "the migration applied" says nothing about whether the trigger works.
  --
  -- 🛑 THIS IS A ROLLED-BACK PROBE ON A LIVE ROW, NOT AN INSERT-THEN-DELETE. An earlier draft
  -- inserted a synthetic manifest and deleted it, which breaks rule 6 (never hard-delete business
  -- data), fires the card-materialisation and OCR-request triggers on INSERT, and relies on
  -- id = max(id) to find its own row back, which another session can invalidate. A bare DO block
  -- COMMITS, so the nested BEGIN..EXCEPTION below is what makes this safe: it opens an implicit
  -- savepoint, and the unconditional raise at the end discards every write inside it.
  begin
    update public.derm_manifests
       set white_manifest_number = '  834986  '
     where white_manifest_number = '834986'
       and id = (select min(id) from public.derm_manifests where white_manifest_number = '834986')
    returning white_manifest_number into v_probe;

    if v_probe is distinct from '834986' then
      raise exception 'VERIFY 7 FAILED: trigger did not trim on UPDATE, got %', quote_literal(v_probe);
    end if;

    update public.derm_manifests
       set white_manifest_number = '   '
     where id = (select min(id) from public.derm_manifests where white_manifest_number = '834986')
    returning white_manifest_number into v_probe;

    if v_probe is not null then
      raise exception 'VERIFY 8 FAILED: whitespace-only did not fold to NULL, got %', quote_literal(v_probe);
    end if;

    -- Always discard the probe. This is the only exit from this block.
    raise exception 'ZZ_ROLLBACK_PROBE';
  exception
    when others then
      if sqlerrm <> 'ZZ_ROLLBACK_PROBE' then
        raise;                       -- a genuine VERIFY failure propagates and aborts the migration
      end if;
  end;

  -- Prove the probe really was discarded, outside the savepoint.
  select count(*) into v_split from public.derm_manifests where white_manifest_number = '834986';
  if v_split <> 8 then
    raise exception 'VERIFY 9 FAILED: probe was not rolled back, 834986 now has % rows', v_split;
  end if;

  raise notice 'VERIFY PASSED: 0 untrimmed, ticket 834986 intact at 8/8/1, 8 links, resolver DADE, trigger trims on UPDATE and folds whitespace to NULL, probe rolled back cleanly';
end $$;
