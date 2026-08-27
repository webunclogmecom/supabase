-- 2026-08-27_1800_redacted_docs_add_page_unique.sql
--
-- WHY: STEP 1 OF 3, AND IT IS DELIBERATELY INERT.
-- ---------------------------------------------------------------------------
-- Fred: "can't we show both pages?" A client whose permitted facilities are printed across two pages
-- of one sheet can only be served ONE of them today, because `derm.redacted_manifest_docs` is keyed
-- on `manifest_id` ALONE. Two clients are under-served right now:
--
--   043-MIL  manifest 1692  ticket-832194  printed rows 5|6 on images 1|2, serves page 1 only
--   022-GRO  manifest 509   window4-sheet3 cards on pages 1 AND 2, serves page 2 only
--
-- ⚠ 022-GRO is NOT a permit case at all: it is one client written on both pages of a handwritten pad
-- sheet. So this is not a multi-GDO feature, it is a general single-page assumption, and fixing the
-- key fixes both.
--
-- 🛑 WHY THIS IS SPLIT ACROSS THREE STEPS INSTEAD OF ONE MIGRATION.
-- The redactor upserts the ledger with `?on_conflict=manifest_id`, which requires a unique index on
-- `manifest_id` alone. Dropping that PK and deploying the new redactor cannot happen atomically:
--   - drop the PK first  -> the DEPLOYED redactor's on_conflict has no matching index and every
--                           sweep fails until the new build lands;
--   - deploy first       -> the new redactor's `on_conflict=manifest_id,effective_page` has no
--                           matching index and every sweep fails until the migration lands.
-- Either ordering breaks the */5 sweep for the length of the gap. Adding the composite UNIQUE while
-- the old PK still stands removes the gap entirely: both on_conflict targets resolve at once, so the
-- old redactor keeps working and the new one can be deployed whenever.
--
-- 🛑 THIS MIGRATION CHANGES NOTHING OBSERVABLE. The PK on `manifest_id` still permits exactly one row
-- per manifest, so the composite constraint is trivially satisfied by every existing row and cannot
-- admit a second page yet. `fn_blackout_targets` is untouched and still emits one row per manifest.
-- Nothing regenerates, no URL changes, no client sees anything different. Step 3 is what opens it.
--
-- Measured before applying: 640 rows, `effective_page` already `integer NOT NULL`, and ZERO duplicate
-- (manifest_id, effective_page) pairs, so the constraint is VALID immediately rather than NOT VALID.
--
-- RULE 8 (audit trail): `derm.redacted_manifest_docs` carries no audit trigger and is deliberately
-- **OPT-OUT**. It is machine-written derived output: the `*/5` sweep rewrites a row on every
-- regeneration, so auditing it would log churn rather than decisions, and every row is reproducible
-- from `derm.fn_blackout_targets` plus the redactor. The decisions that matter (the bands and the
-- page extent) are already audited on `derm.address_row_map` and `derm.page_block_extents`.

BEGIN;

ALTER TABLE derm.redacted_manifest_docs
  ADD CONSTRAINT redacted_manifest_docs_manifest_page_key UNIQUE (manifest_id, effective_page);

COMMENT ON CONSTRAINT redacted_manifest_docs_manifest_page_key ON derm.redacted_manifest_docs IS
  'The upsert target the redactor uses (?on_conflict=manifest_id,effective_page). Added while the '
  'manifest_id PK still stood so the deployed redactor and the new one could both resolve an index, '
  'leaving no window in which the */5 sweep fails. Becomes the PRIMARY KEY in 2026-08-27_1830.';

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer;
BEGIN
  -- 1. Both unique targets now exist, which is the whole point of this step.
  SELECT count(*) INTO v_n FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace
   WHERE n.nspname='derm' AND t.relname='redacted_manifest_docs' AND c.contype IN ('p','u');
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % unique/pk constraints, expected 2 (the manifest_id PK and the new composite)', v_n;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint c
                   JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace
                  WHERE n.nspname='derm' AND t.relname='redacted_manifest_docs'
                    AND c.conname='redacted_manifest_docs_pkey') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: the manifest_id PK is gone; the deployed redactor would start failing';
  END IF;

  -- 2. Grants untouched. ALTER TABLE ADD CONSTRAINT does not recreate the table, but assert it,
  --    because losing service_role here silently kills the sweep.
  IF NOT has_table_privilege('service_role','derm.redacted_manifest_docs','INSERT') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: service_role lost INSERT';
  END IF;
  IF has_table_privilege('anon','derm.redacted_manifest_docs','SELECT') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: anon gained SELECT';
  END IF;

  -- 3. NOTHING MOVED. Same row count, and no document became stale, so no client sees a change.
  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs;
  IF v_n <> 640 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: % ledger rows, expected 640', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(2000);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: % document(s) became stale; this step must be inert', v_n;
  END IF;

  RAISE NOTICE 'VERIFY ok: composite UNIQUE added alongside the manifest_id PK, 640 rows, 0 stale. Inert by design.';
END $do$;

COMMIT;
