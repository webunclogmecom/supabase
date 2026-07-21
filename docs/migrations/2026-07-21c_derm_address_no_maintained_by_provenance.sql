-- ============================================================================
-- 2026-07-21c — derm_manifests.derm_address_no maintained from provenance
--               (keyed by IMMUTABLE manifest id)
-- ============================================================================
-- WHY: the DERM Tracker's /manifests grouped list reads the BASE table
-- directly (the 2026-07-20 query-slim pass:
-- select id,white_manifest_number,...,derm_address_no) — not the
-- derm.manifests view that 2026-07-21b re-derived. With the base column left
-- permanently NULL after 20f removed the old writeback, the app's new
-- "Sheet N" chip and "Regenerate address sheet" label (Fred: "implement it")
-- could never appear (verified live: sheet 1054 recorded, chip absent).
--
-- The 20f removal was about the KEYING, not the column: the old writeback
-- stamped rows BY MUTABLE TICKET NUMBER, so a renumber sprayed the number
-- onto the wrong ticket (ghost sheet 819788). This migration reinstates the
-- column as a maintained mirror of provenance, stamped BY MANIFEST ID inside
-- derm.record_generated_address_sheet — renumber-proof by construction, and
-- single-valued because gate 2 guarantees a ticket carries at most one live
-- sheet. A trigger on derm.address_sheets clears the mirror when a sheet is
-- soft-deleted (ops repair path), so the column can never outlive its sheet.
--
-- 3NF NOTE: this is INTENTIONAL DENORMALIZATION per ADR 004 — a derived
-- value stored because the app's slimmed hot-path query reads the base table
-- and must not pay a per-row provenance join. Source of truth REMAINS
-- derm.address_sheets + derm.address_sheet_manifests; the only writers of the
-- mirror are the record RPC and the sheet soft-delete trigger below. Never
-- write derm_address_no by ticket number again.
--
-- AUDIT: derm_manifests is audited (audit_derm_manifests) — mirror updates
-- are captured with the caller's app_source. derm.address_sheets stays
-- audit-opt-out (Studio/provenance app state, standing decision).
--
-- VERIFICATION (2026-07-21, appended below after deploy).
-- ============================================================================

-- ─── 1. Stamp inside the record RPC ─────────────────────────────────────────
-- (CREATE OR REPLACE of derm.record_generated_address_sheet, adding the
--  mirror UPDATE at the end of the existing body — full function re-stated.)

DO $do$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'derm' AND p.proname = 'record_generated_address_sheet';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'derm.record_generated_address_sheet not found';
  END IF;
  IF v_src LIKE '%derm_address_no%' THEN
    RAISE NOTICE 'record RPC already maintains the mirror; skipping rewrite';
  END IF;
END $do$;

-- The RPC body is amended in-place by the deploy script (see the deploy note
-- in the verification record): after the provenance upsert + link refresh,
-- it now runs:
--
--   UPDATE public.derm_manifests m
--      SET derm_address_no = p_sheet_no
--    WHERE m.id = ANY(p_manifest_ids)
--      AND m.derm_address_no IS DISTINCT FROM p_sheet_no;
--
-- (Full amended function deployed via 2026-07-21c_apply.sql companion, which
-- re-states the entire function; kept out of this header for brevity. The
-- companion is committed alongside this file.)

-- ─── 2. Clear the mirror when a sheet is soft-deleted ───────────────────────

CREATE OR REPLACE FUNCTION derm.trg_clear_address_no_on_sheet_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    UPDATE public.derm_manifests m
       SET derm_address_no = NULL
      FROM derm.address_sheet_manifests l
     WHERE l.sheet_id = NEW.id
       AND m.id = l.manifest_id
       AND m.derm_address_no = NEW.sheet_no;
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_za_clear_address_no ON derm.address_sheets;
CREATE TRIGGER trg_za_clear_address_no
  AFTER UPDATE OF deleted_at ON derm.address_sheets
  FOR EACH ROW
  EXECUTE FUNCTION derm.trg_clear_address_no_on_sheet_delete();

-- ─── 3. Backfill current live provenance ────────────────────────────────────

UPDATE public.derm_manifests m
   SET derm_address_no = s.sheet_no
  FROM derm.address_sheet_manifests l
  JOIN derm.address_sheets s ON s.id = l.sheet_id AND s.deleted_at IS NULL
 WHERE m.id = l.manifest_id
   AND m.derm_address_no IS DISTINCT FROM s.sheet_no;

-- ============================================================================
-- VERIFICATION RECORD — 2026-07-21, all PASS (live production app + synthetic
-- arena ticket 999905 / manifest 1445 / sheet 1054; backup at
-- ..\backups\2026-07-21_generate_button_test_synthetic.json)
-- ============================================================================
-- - Backfill stamped manifest 1445 derm_address_no=1054 (the only live
--   provenance at deploy time).
-- - LIVE APP (derm.unclogme.app /manifests?q=999905, new bundle
--   manifests-CTT4w4jA.js): "Sheet 1054" chip rendered; button label flipped
--   to "Regenerate address sheet"; REGENERATION returned the SAME sheet_no
--   1054 with HTTP 200 (identity preserved, no extra sequence burn — seq
--   last_value stayed 1054); toast copy "Address sheet 1054 generated. Print
--   it for the driver." (no em dash).
-- - NEGATIVE (q=829201, real returned ticket with filed photos): generate
--   button NOT rendered (visibility gate = no address photo in group).
-- - trg_za_clear_address_no LIVE PASS: soft-deleting sheet 1054 cleared the
--   mirror on manifest 1445 before the synthetic rows were removed.
-- - Teardown: 0 residue (manifests/sheets/blackout targets/storage objects);
--   sequence consumed through 1054 => FIRST PRODUCTION SHEET = 1055.
