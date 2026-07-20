-- 2026-07-20f — Record generated-sheet provenance as a FACT; retire the number-range guess
--
-- CONTEXT (Fred: "#4 do a brainstorming first, and fix it"). The brainstorm (4-lane investigation +
-- 3 designs + 9 adversarial reviews) overturned the premise I had been carrying, and the corrected
-- picture is worse than the original bug. All of the following was probed on Prod before writing:
--
--   1. THE WRITEBACK WAS NEVER MISSING. pdf-service commit 9897630 (2026-06-01) already calls
--      set_manifest_address_no() after upload. It has never run because ONE LINE EARLIER the same
--      endpoint overwrites derm_manifests.derm_address_url — the uploaded PHOTO of the physical
--      sheet, which is compliance evidence. The number-write sits downstream of a destructive write,
--      so the endpoint is unusable and nobody uses it. Deleting that line is the actual fix; the
--      writeback then works on its own.
--   2. THE NUMBER-RANGE HEURISTIC IS ALREADY WRONG, IN BOTH DIRECTIONS, TODAY:
--        derm.fn_sheet_is_generated('8251')   -> TRUE   (a REAL transient: manifest 1070 mid-typing
--                                                        on its way to '825167', persisted 2026-05-26)
--        derm.fn_sheet_is_generated('1027')   -> TRUE   (next sequence value; no such sheet exists)
--        derm.fn_sheet_is_generated('001027') -> FALSE  (the SAME number in the table's own
--                                                        canonical 6-char zero-padded format)
--      All 103 real ticket keys are exactly 6 chars zero-padded ('000068'..'830413'), and there is
--      no CHECK constraint on white_manifest_number — it is typed live in DERM Tracker with
--      autosave, so partial keystrokes persist ('0001' x14, '8251' x1). Since 2026-07-20d a TRUE
--      answer drives a BEFORE INSERT auto-stamp trigger and an auto-complete, both permanent. A
--      five-second transient during typing is enough to permanently mislabel a real county sheet.
--   3. THE TICKET NUMBER IS MUTABLE, so it must never be the identity of a generated sheet:
--      40 UPDATEs across 39 manifest rows changed white_manifest_number from one non-null value to
--      another; the latest is 819788 -> 829788 on 2026-07-16 from the DERM Tracker. (That renumber
--      is exactly what orphaned the ghost Stamp cards deleted in 2026-07-20e.)
--   4. THE 20d BLACKOUT EXCLUSION RESTS ON A DEAD RATIONALE. It was justified as "their FP copy is
--      the born-redacted FOG PDF", but customer.work_orders has ZERO fog/address URL columns today
--      (verified) — since the 2026-07-10 Blackout release the ONLY FP path is derm_manifest_url
--      from derm.redacted_manifest_docs (527 live docs). So "generated" would not degrade a
--      customer's document, it would FREEZE it.
--
-- WHAT THIS MIGRATION DOES (Part A: additive + subtractive; ZERO behaviour change by construction)
--   A. derm.address_sheets + derm.address_sheet_manifests — provenance recorded as a fact, keyed on
--      the sheet number and linked to manifests by IMMUTABLE id. Nothing copies the ticket number,
--      so a renumber can never orphan or un-generate a sheet.
--   B. derm.fn_address_sheet_no(manifest_id) — resolves a manifest's sheet number through the link
--      (ticket-wide, so a client added later to a generated ticket inherits it for free).
--   C. derm.record_generated_address_sheet(...) — the ONLY writer. Refuses outright if any target
--      manifest's ticket already carries an uploaded photo or a Stamp Studio card, which makes it
--      structurally impossible to flip one of today's 103 handwritten county sheets. Refuses to
--      renumber a manifest already bound to another sheet.
--   D. derm.fn_sheet_is_generated — body replaced by the lookup. Both heuristic limbs (numeric band
--      AND the '%.pdf' suffix) are GONE. Signature/return/volatility unchanged, so all 9 call sites
--      in 20c/20d need no edit. NULL still returns NULL (see the warning on the function).
--   E. derm.fn_blackout_targets — the generated-exclusion is re-keyed to the real reason: only
--      sheets that actually HAVE an uploaded photo to redact are targeted. Identical today; and it
--      correctly handles a future generated sheet that later gets photographed and filed.
--   F. REVOKE the sequence from anon (it held rwU directly, bypassing the deliberate REVOKE EXECUTE
--      on next_derm_address_id(), so any anon client could burn sheet numbers).
--
-- NOT IN THIS MIGRATION, deliberately: no backfill (all 535 live manifests are genuinely
-- handwritten: 535 image URLs, 0 .pdf, 0 numbers — numbering them would fabricate provenance and
-- fire six silent behaviour changes on real county sheets), no drop of derm_manifests.derm_address_no
-- (deprecate by comment first; dropping in the same ship as a behaviour change removes the cheap
-- rollback), no sequence reset (a previewed number may already exist on printed paper), and no
-- "Generate address PDF" button anywhere — the endpoint stays dark until Fred picks the first ticket.
--
-- ADR 010 AUDIT DECISION: BOTH new tables OPT IN. They gate fn_sheet_is_generated, which decides
-- Stamp Studio auto-placement and (via fn_blackout_targets) whether a client receives their redacted
-- FOG document. That is DERM compliance, so CLAUDE.md rule 8 forbids skipping audit.
--
-- 3NF standing check, column by column:
--   address_sheets.sheet_no        — the natural key of a generated sheet. Depends on nothing else.
--   address_sheets.pdf_bucket/path — RECORDED facts about the artifact produced for that sheet, not
--                                    derivations: a future path-convention change must not
--                                    retroactively falsify where a filed compliance PDF actually is.
--   address_sheets.last_generated_at — regeneration is normal (a client joins a shared ticket), so
--                                    this is the sheet's own attribute, not a copy of anything.
--   NO ticket_key column, on purpose (rule 3 / ADR 005 rule 2 — the ticket number is mutable and
--   copying it would silently orphan on the 40 recorded renumbers). The relationship lives in
--   address_sheet_manifests as FKs on immutable ids.
-- RULE 6: both tables carry deleted_at and the predicate filters it, so a mistakenly recorded sheet
--   has a non-destructive undo.
-- Idempotent and re-runnable. Writes ZERO bytes to derm_address_url or *_extra_urls.

BEGIN;

-- A. provenance tables ------------------------------------------------------
CREATE TABLE IF NOT EXISTS derm.address_sheets (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sheet_no          bigint      NOT NULL,
  pdf_bucket        text        NOT NULL,
  pdf_path          text        NOT NULL,
  last_generated_at timestamptz NOT NULL DEFAULT now(),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  CONSTRAINT address_sheets_pdf_path_chk CHECK (btrim(pdf_path) <> ''),
  CONSTRAINT address_sheets_sheet_no_chk CHECK (sheet_no >= 1000)
);
CREATE UNIQUE INDEX IF NOT EXISTS address_sheets_sheet_no_live_idx
  ON derm.address_sheets (sheet_no) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS derm.address_sheet_manifests (
  sheet_id    bigint NOT NULL REFERENCES derm.address_sheets (id) ON DELETE CASCADE,
  manifest_id bigint NOT NULL REFERENCES public.derm_manifests (id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (sheet_id, manifest_id)
);
CREATE INDEX IF NOT EXISTS address_sheet_manifests_manifest_idx
  ON derm.address_sheet_manifests (manifest_id);

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'audit_address_sheets') THEN
    CREATE TRIGGER audit_address_sheets AFTER INSERT OR UPDATE OR DELETE ON derm.address_sheets
      FOR EACH ROW EXECUTE FUNCTION audit.log_change();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'audit_address_sheet_manifests') THEN
    CREATE TRIGGER audit_address_sheet_manifests AFTER INSERT OR UPDATE OR DELETE ON derm.address_sheet_manifests
      FOR EACH ROW EXECUTE FUNCTION audit.log_change();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_address_sheets_updated_at') THEN
    CREATE TRIGGER trg_address_sheets_updated_at BEFORE UPDATE ON derm.address_sheets
      FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
  END IF;
END $$;

COMMENT ON TABLE derm.address_sheets IS
  'One row per DERM Address sheet WE generated (pdf-service). A row exists only after the PDF was successfully uploaded, so "generated" means the artifact exists, never that a number was reserved. Identity is sheet_no; the ticket number is deliberately NOT stored here because it is mutable (40 renumbers recorded in audit.logs).';
COMMENT ON TABLE derm.address_sheet_manifests IS
  'Links a generated sheet to the derm_manifests rows printed on it, by IMMUTABLE manifest id. This is how derm.fn_sheet_is_generated resolves a ticket, so a ticket renumber moves the manifests and the answer follows them with no propagation trigger.';

-- B. resolve a manifest's sheet number (ticket-wide) --------------------------
CREATE OR REPLACE FUNCTION derm.fn_address_sheet_no(p_manifest_id bigint)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT s.sheet_no
    FROM derm.address_sheet_manifests l
    JOIN derm.address_sheets s ON s.id = l.sheet_id AND s.deleted_at IS NULL
   WHERE l.manifest_id = p_manifest_id
   ORDER BY s.last_generated_at DESC
   LIMIT 1;
$$;

-- C. the ONLY writer, with the gate that makes mislabeling structurally impossible
CREATE OR REPLACE FUNCTION derm.record_generated_address_sheet(
  p_sheet_no bigint, p_bucket text, p_path text, p_manifest_ids bigint[])
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'derm','public' AS $$
DECLARE v_sheet_id bigint; v_bad text; v_other bigint;
BEGIN
  IF p_sheet_no IS NULL OR p_bucket IS NULL OR btrim(coalesce(p_path,'')) = ''
     OR p_manifest_ids IS NULL OR array_length(p_manifest_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'record_generated_address_sheet: all arguments are required (sheet=%, bucket=%, path=%)',
      p_sheet_no, p_bucket, p_path;
  END IF;

  -- GATE 1: refuse any ticket that already carries handwritten evidence (an uploaded photo or a
  -- Stamp Studio card). This is what makes it impossible to flip one of today's real county sheets.
  SELECT string_agg(DISTINCT k, ', ') INTO v_bad
  FROM (
    SELECT COALESCE(m.white_manifest_number, m.yellow_ticket_number) AS k
      FROM public.derm_manifests m
     WHERE m.id = ANY (p_manifest_ids) AND m.deleted_at IS NULL
       AND (m.derm_address_url IS NOT NULL
            OR EXISTS (SELECT 1 FROM derm.address_row_map a
                        WHERE a.white_manifest_number = COALESCE(m.white_manifest_number, m.yellow_ticket_number)))
  ) q;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'refusing: ticket(s) % already carry handwritten evidence (uploaded sheet photo or Stamp Studio card)', v_bad;
  END IF;

  -- GATE 2: never renumber a manifest that already belongs to a different live sheet.
  SELECT s.sheet_no INTO v_other
    FROM derm.address_sheet_manifests l
    JOIN derm.address_sheets s ON s.id = l.sheet_id AND s.deleted_at IS NULL
   WHERE l.manifest_id = ANY (p_manifest_ids) AND s.sheet_no <> p_sheet_no
   LIMIT 1;
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION 'refusing to renumber: one of these manifests already belongs to sheet %', v_other;
  END IF;

  INSERT INTO derm.address_sheets (sheet_no, pdf_bucket, pdf_path)
  VALUES (p_sheet_no, p_bucket, p_path)
  ON CONFLICT ON CONSTRAINT address_sheets_pkey DO NOTHING;

  SELECT id INTO v_sheet_id FROM derm.address_sheets
   WHERE sheet_no = p_sheet_no AND deleted_at IS NULL;
  IF v_sheet_id IS NULL THEN
    INSERT INTO derm.address_sheets (sheet_no, pdf_bucket, pdf_path)
    VALUES (p_sheet_no, p_bucket, p_path) RETURNING id INTO v_sheet_id;
  ELSE
    UPDATE derm.address_sheets
       SET pdf_bucket = p_bucket, pdf_path = p_path, last_generated_at = now()
     WHERE id = v_sheet_id;
  END IF;

  INSERT INTO derm.address_sheet_manifests (sheet_id, manifest_id)
  SELECT v_sheet_id, unnest(p_manifest_ids)
  ON CONFLICT DO NOTHING;

  RETURN v_sheet_id;
END $$;

REVOKE ALL ON FUNCTION derm.record_generated_address_sheet(bigint, text, text, bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.record_generated_address_sheet(bigint, text, text, bigint[]) TO service_role;

-- D. the predicate: recorded fact, no more guessing ---------------------------
-- ⚠ NULL IN -> NULL OUT, byte-identical to the deployed three-valued behaviour. derm.address_row_map
-- has rows with a NULL white_manifest_number and fn_blackout_targets filters on
-- NOT derm.fn_sheet_is_generated(...) — returning FALSE instead of NULL would ADMIT those rows into
-- the redaction pipeline. Do not "simplify" the CASE away.
CREATE OR REPLACE FUNCTION derm.fn_sheet_is_generated(p_sheet_no text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN p_sheet_no IS NULL THEN NULL ELSE EXISTS (
    SELECT 1
      FROM derm.address_sheet_manifests l
      JOIN derm.address_sheets   s ON s.id = l.sheet_id AND s.deleted_at IS NULL
      JOIN public.derm_manifests m ON m.id = l.manifest_id AND m.deleted_at IS NULL
     WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = p_sheet_no
  ) END;
$$;

COMMENT ON FUNCTION derm.fn_sheet_is_generated(text) IS
  'TRUE iff this ticket carries a sheet WE generated, as RECORDED in derm.address_sheets. Superseded the 2026-07-20c heuristics (numeric band >= 1000 and a .pdf suffix on derm_address_url) which were proven wrong in both directions on live data: ''8251'' (a real mid-typing transient) and ''1027'' returned TRUE, while the canonically zero-padded ''001027'' returned FALSE.';
COMMENT ON COLUMN public.derm_manifests.derm_address_no IS
  'DEPRECATED 2026-07-20f. Never populated (0/535). Read derm.fn_address_sheet_no(id) instead. Kept this cycle so the rollback stays cheap; drop once nothing reads the base column.';

-- F. anon must not be able to burn sheet numbers ------------------------------
REVOKE ALL ON SEQUENCE public.derm_address_seq FROM anon;

COMMIT;

-- E. fn_blackout_targets — re-key the exclusion to the real reason.
--    Deployed separately (grafted onto the live definition with a pattern-count guard) so this file
--    never carries a stale copy of that function. The single changed line is:
--      -  AND NOT derm.fn_sheet_is_generated(r.white_manifest_number)
--      +  AND COALESCE(array_length(derm.ticket_page_images(r.white_manifest_number), 1), 0) > 0
--    i.e. "only sheets that actually have an uploaded photo to redact". Identical today (all 103
--    sheets are photos); correctly excludes a future generated sheet that has no photo; and
--    correctly INCLUDES a generated sheet that later gets photographed and filed, which the blanket
--    exclusion would have wrongly frozen.
