-- ============================================================================
-- 2026-07-17 — gdos demotion guard + re-demotion of the 18 regressed rows
-- ============================================================================
-- WHY. The 2026-06-28 GDO reconciliation demoted 19 wrong-permit rows
-- (status='INACTIVE', notes carry the PDF evidence). audit.logs proves they
-- were silently RE-PROMOTED to ACTIVE by three writer classes:
--   1. a bulk AT-re-ingest script via the Management API (2026-06-29
--      17:01-17:04 UTC burst, app_source='sql', clients in alphabetical order),
--   2. webhook-airtable's GDO update path, which forced status='ACTIVE'
--      whenever Airtable re-sent the same (client, gdo_number) — patched
--      2026-07-17 (expiration-only update; INSERT still ACTIVE),
--   3. one-off REST PATCHes (/gdos, 07-11 + 07-12).
-- Airtable still carries ~28 wrong GDO numbers (2026-06-28 office-corrections
-- list, never applied there), so ANY Airtable-driven writer keeps regressing
-- the demotions. This guard makes a demotion durable at the DB layer: a row
-- whose notes carry the DEMOTED/DEDUP marker cannot be flipped back to ACTIVE
-- unless the SAME update amends the notes (i.e. a deliberate, documented
-- reactivation — the 2026-07-09 sweep pattern). Blind flips are silently kept
-- INACTIVE with a WARNING so multi-statement writers (webhooks) don't break.
--
-- AUDIT (rule 8): public.gdos is already audited (trigger audit_gdos) — the
-- guard changes no audit posture. The re-demotions below fire audit rows.
-- Backup of the 18 rows: ..\..\backups\2026-07-17_gdos_redemote_before.json
-- Full audit: docs/audits/2026-07-17_gdo_full_audit.md
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_gdos_guard_demoted()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status = 'INACTIVE'
     AND NEW.status = 'ACTIVE'
     AND OLD.notes ~* '(DEMOTED|DEDUP)'
     AND NEW.notes IS NOT DISTINCT FROM OLD.notes THEN
    RAISE WARNING 'gdos guard: row % (%) was demoted with PDF evidence; keeping INACTIVE. To deliberately reactivate, amend notes in the same UPDATE.',
      OLD.id, OLD.gdo_number;
    NEW.status := 'INACTIVE';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_aa_gdos_guard_demoted ON public.gdos;
CREATE TRIGGER trg_aa_gdos_guard_demoted
  BEFORE UPDATE ON public.gdos
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_gdos_guard_demoted();

-- ── Re-demote the 18 regressed rows (June-28 verdicts stand; permits are
-- location-bound street-level mismatches, so annual renewal cannot make them
-- correct; 060-TU/227-PER/132-PUM/114-CI freshly re-confirmed by Yan + the
-- 2026-07-17 PDF reads). Notes are amended in the same UPDATE, so this
-- statement itself passes the guard.
UPDATE public.gdos g
SET status = 'INACTIVE',
    notes = g.notes || ' [2026-07-17 RE-DEMOTED: was regressed to ACTIVE by the AT re-ingest writers (see audit 2026-07-17_gdo_full_audit.md); the PDF evidence above stands.]'
FROM public.clients c
WHERE c.id = g.client_id
  AND g.status = 'ACTIVE'
  AND (c.client_code, g.gdo_number) IN (
    ('013-DIM','GDO-03687'), ('016-FIA','GDO-13335'), ('021-GRA','GDO-00376'),
    ('042-MT','GDO-04127'),  ('060-TU','GDO-13076'),  ('063-TCE','GDO-08976'),
    ('083-SHUL','GDO-12490'),('084-ULT','GDO-03828'), ('104-PV','GDO-08976'),
    ('114-CI','GDO-11886'),  ('132-PUM','GDO-000951'),('136-BB','GDO-11220'),
    ('150-KOS','GDO-01958'), ('187-HAI','GDO-07382'), ('188-ACA','GDO-02118'),
    ('194-PV','GDO-03375'),  ('222-SPE','GDO-09290'), ('227-PER','GDO-02079')
  );
