-- 2026-07-03m  DERM manifest completeness guard: inherit ticket-level fields + detection view
-- ============================================================================
-- WHY: 087-BB (#827989, derm_manifests row 1256) showed "Partial record — Some fields
-- missing" with a blank dump date on its DERM Tracker visit page, while the Manifests
-- page badged #827989 "Documented". Two different status systems:
--   * Manifests page "Documented" = ANY PDF present in the manifest-number group (coarse).
--   * Visit card = derm.manifest_health.health_state per ROW; 'fully_complete' additionally
--     requires dump_ticket_date (Dade: white# + both PDFs + dump_ticket_date).
-- Row 1256 was created 2026-07-03 by a raw reconstruction INSERT that set the number + images
-- but left dump_ticket_date / disposal_facility_id / service_date NULL, so it fell to
-- 'partial_other'. Its 18 siblings all carry dump 2026-06-21 + facility 2.
--
-- ROOT CAUSE (data model): dump_ticket_date and disposal_facility_id are TICKET-LEVEL facts
-- (one physical dump = one date + one facility, shared by every client row on the same
-- manifest number) but are stored redundantly per row, so a row can be born missing them.
-- AUDIT CONFIRMED they are true invariants: 0 tickets have disagreeing non-null dump dates or
-- facilities across their rows. (service_date is client/visit-level, NOT ticket-level — never
-- inherited here.)
--
-- DEFENSE IN DEPTH:
--   (1) TRIGGER trg_derm_inherit_ticket_fields — BEFORE INSERT/UPDATE, auto-inherits
--       dump_ticket_date + disposal_facility_id from a unanimous sibling when the row's own is
--       NULL. Fills-only (never overwrites); only when siblings hold exactly ONE distinct
--       non-null value; matches siblings by whichever number the row carries (white preferred).
--       Complements the app: file_manifest already passes p_dump_date; this heals rows created
--       without it (raw SQL, a blank-date upload onto an existing ticket, a future backfill).
--   (2) VIEW ops.v_derm_row_completeness_gaps — surfaces every live row that is NOT
--       'fully_complete' with which field is missing, whether it is visit-linked, whether its
--       ticket still shows "Documented", and whether it is an accepted gap (has a note). For
--       automated monitoring (assert: no visit-linked, non-complete row without an accepted note).
--   (3) One-time backfill of existing null-facility rows that have a unanimous sibling value.
--
-- Reversible: DROP TRIGGER + DROP FUNCTION + DROP VIEW; backfill backup in
-- backups/2026-07-03_derm_facility_inherit_backfill_backup.json. No schema/column change.
-- ----------------------------------------------------------------------------

-- (1) inheritance trigger ----------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_derm_inherit_ticket_fields()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_dump date;
  v_fac  bigint;
BEGIN
  -- dump_ticket_date: inherit from a unanimous sibling on the same manifest number
  IF NEW.dump_ticket_date IS NULL
     AND (NEW.white_manifest_number IS NOT NULL OR NEW.yellow_ticket_number IS NOT NULL) THEN
    SELECT min(s.dump_ticket_date) INTO v_dump
      FROM public.derm_manifests s
     WHERE s.deleted_at IS NULL
       AND s.id IS DISTINCT FROM NEW.id
       AND s.dump_ticket_date IS NOT NULL
       AND (CASE WHEN NEW.white_manifest_number IS NOT NULL
                 THEN s.white_manifest_number = NEW.white_manifest_number
                 ELSE s.yellow_ticket_number = NEW.yellow_ticket_number END)
    HAVING count(DISTINCT s.dump_ticket_date) = 1;   -- only when siblings agree
    IF v_dump IS NOT NULL THEN
      NEW.dump_ticket_date := v_dump;
    END IF;
  END IF;

  -- disposal_facility_id: same inheritance
  IF NEW.disposal_facility_id IS NULL
     AND (NEW.white_manifest_number IS NOT NULL OR NEW.yellow_ticket_number IS NOT NULL) THEN
    SELECT min(s.disposal_facility_id) INTO v_fac
      FROM public.derm_manifests s
     WHERE s.deleted_at IS NULL
       AND s.id IS DISTINCT FROM NEW.id
       AND s.disposal_facility_id IS NOT NULL
       AND (CASE WHEN NEW.white_manifest_number IS NOT NULL
                 THEN s.white_manifest_number = NEW.white_manifest_number
                 ELSE s.yellow_ticket_number = NEW.yellow_ticket_number END)
    HAVING count(DISTINCT s.disposal_facility_id) = 1;
    IF v_fac IS NOT NULL THEN
      NEW.disposal_facility_id := v_fac;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_derm_inherit_ticket_fields ON public.derm_manifests;
CREATE TRIGGER trg_derm_inherit_ticket_fields
  BEFORE INSERT OR UPDATE ON public.derm_manifests
  FOR EACH ROW EXECUTE FUNCTION public.fn_derm_inherit_ticket_fields();

-- lightweight indexes for the sibling lookup (existing unique indexes lead with client_id)
CREATE INDEX IF NOT EXISTS derm_manifests_white_number_idx
  ON public.derm_manifests (white_manifest_number) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS derm_manifests_yellow_number_idx
  ON public.derm_manifests (yellow_ticket_number) WHERE deleted_at IS NULL;

-- (2) detection view ---------------------------------------------------------
CREATE OR REPLACE VIEW ops.v_derm_row_completeness_gaps AS
WITH tkt AS (
  SELECT coalesce(white_manifest_number, yellow_ticket_number) AS ticket,
         bool_or(derm_manifest_url IS NOT NULL OR derm_address_url IS NOT NULL
                 OR coalesce(array_length(derm_manifest_extra_urls, 1), 0) > 0
                 OR coalesce(array_length(derm_address_extra_urls, 1), 0) > 0) AS ticket_has_pdf
    FROM public.derm_manifests
   WHERE deleted_at IS NULL
     AND coalesce(white_manifest_number, yellow_ticket_number) IS NOT NULL
   GROUP BY 1
)
SELECT mh.id,
       c.client_code,
       coalesce(mh.white_manifest_number, mh.yellow_ticket_number) AS ticket,
       mh.jurisdiction,
       mh.health_state,
       mh.severity,
       (mh.white_manifest_number IS NULL AND mh.yellow_ticket_number IS NULL) AS missing_number,
       (NOT mh.has_manifest_pdf) AS missing_manifest_pdf,
       (NOT mh.has_address_pdf)  AS missing_address_pdf,
       (NOT mh.has_dump_date)    AS missing_dump_date,
       EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id = mh.id) AS visit_linked,
       coalesce(t.ticket_has_pdf, false) AS ticket_shows_documented,
       (mh.notes IS NOT NULL) AS accepted_gap_note,
       mh.notes
  FROM derm.manifest_health mh
  LEFT JOIN public.clients c ON c.id = mh.client_id
  LEFT JOIN tkt t ON t.ticket = coalesce(mh.white_manifest_number, mh.yellow_ticket_number)
 WHERE mh.health_state <> 'fully_complete';

COMMENT ON VIEW ops.v_derm_row_completeness_gaps IS
  'DERM manifest rows that would render as something other than a complete record on the visit page '
  '(derm.manifest_health.health_state <> fully_complete). accepted_gap_note=true means a human documented '
  'why (e.g. damaged paper manifest). Monitoring assert: no row with visit_linked=true AND accepted_gap_note=false. '
  'The trg_derm_inherit_ticket_fields trigger auto-heals the ticket-level dump_date/facility case; residual rows '
  'here genuinely need a number or a document uploaded.';

-- (3) one-time backfill: fill null ticket-level fields from a unanimous sibling ---------------
UPDATE public.derm_manifests dm
   SET disposal_facility_id = sub.v
  FROM (SELECT coalesce(white_manifest_number, yellow_ticket_number) AS tkt,
               max(disposal_facility_id) AS v,
               count(DISTINCT disposal_facility_id) FILTER (WHERE disposal_facility_id IS NOT NULL) AS n
          FROM public.derm_manifests WHERE deleted_at IS NULL GROUP BY 1) sub
 WHERE dm.deleted_at IS NULL
   AND dm.disposal_facility_id IS NULL
   AND coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = sub.tkt
   AND sub.n = 1;

UPDATE public.derm_manifests dm
   SET dump_ticket_date = sub.v
  FROM (SELECT coalesce(white_manifest_number, yellow_ticket_number) AS tkt,
               max(dump_ticket_date) AS v,
               count(DISTINCT dump_ticket_date) FILTER (WHERE dump_ticket_date IS NOT NULL) AS n
          FROM public.derm_manifests WHERE deleted_at IS NULL GROUP BY 1) sub
 WHERE dm.deleted_at IS NULL
   AND dm.dump_ticket_date IS NULL
   AND coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = sub.tkt
   AND sub.n = 1;
