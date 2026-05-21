-- 2026-05-18d_derm_manifest_number_proposals.sql
--
-- Queue table for OCR-extracted manifest number proposals. Ops staff review
-- + approve before the value lands on the canonical derm_manifests row.
--
-- Workflow:
--   1. Script runs Claude Vision over each manifest_photo_url where
--      white_manifest_number IS NULL → inserts a proposal here
--   2. Ops staff (or DERM Tracker UI) reviews via filtered list
--   3. On approve: UPDATE derm_manifests.white_manifest_number, mark
--      proposal as approved
--   4. On reject: mark as rejected with a note
--
-- Audit opt-in per Rule 8 (CLAUDE.md): this table has human-edit fields
-- (review_status, reviewed_by, reviewed_at, notes). Opting in.

BEGIN;

CREATE TABLE IF NOT EXISTS public.derm_manifest_number_proposals (
  id                      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  manifest_id             BIGINT NOT NULL REFERENCES public.derm_manifests(id) ON DELETE CASCADE,
  proposed_number         TEXT,
  confidence              TEXT CHECK (confidence IN ('high','medium','low','unknown')),
  source                  TEXT NOT NULL DEFAULT 'claude_vision',
  source_image_url        TEXT,
  raw_response            TEXT,             -- the model's full response for audit
  review_status           TEXT NOT NULL DEFAULT 'pending' CHECK (review_status IN ('pending','approved','rejected','superseded')),
  reviewed_by             UUID,             -- auth.users.id when Phase 2 auth ships; NULL today
  reviewed_at             TIMESTAMPTZ,
  notes                   TEXT,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (manifest_id, proposed_number, source)
);

CREATE INDEX idx_dmnp_manifest ON public.derm_manifest_number_proposals (manifest_id);
CREATE INDEX idx_dmnp_status   ON public.derm_manifest_number_proposals (review_status, created_at DESC);

-- updated_at trigger (canonical set_updated_at, matches the 22 other tables)
CREATE TRIGGER trg_derm_manifest_number_proposals_updated_at
  BEFORE UPDATE ON public.derm_manifest_number_proposals
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Audit trigger — human-edit table; opted in per Rule 8
CREATE TRIGGER audit_derm_manifest_number_proposals
  AFTER INSERT OR UPDATE OR DELETE ON public.derm_manifest_number_proposals
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- RLS — anon read + insert + update (so DERM Tracker UI can list + approve/reject).
-- Anon DELETE not granted; we mark rejected instead (Rule 6: never hard-delete).
ALTER TABLE public.derm_manifest_number_proposals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_read_dmnp"   ON public.derm_manifest_number_proposals FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_dmnp" ON public.derm_manifest_number_proposals FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_update_dmnp" ON public.derm_manifest_number_proposals FOR UPDATE TO anon USING (true) WITH CHECK (true);
CREATE POLICY "authenticated_read_dmnp"   ON public.derm_manifest_number_proposals FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated_write_dmnp"  ON public.derm_manifest_number_proposals FOR ALL    TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE ON public.derm_manifest_number_proposals TO anon;
GRANT ALL                    ON public.derm_manifest_number_proposals TO authenticated, service_role;

COMMIT;

-- ---------------------------------------------------------------------------
-- View exposed to DERM Tracker (derm schema)
-- ---------------------------------------------------------------------------
BEGIN;

CREATE OR REPLACE VIEW derm.manifest_number_proposals AS
SELECT
  p.id,
  p.manifest_id,
  p.proposed_number,
  p.confidence,
  p.source,
  p.source_image_url,
  p.review_status,
  p.notes,
  p.created_at::text                   AS created_at,
  p.updated_at::text                   AS updated_at,
  dm.white_manifest_number             AS current_value,
  dm.derm_manifest_url                 AS manifest_photo_url,
  c.name                               AS client_name,
  dm.service_date::text                AS service_date
FROM public.derm_manifest_number_proposals p
JOIN public.derm_manifests dm ON dm.id = p.manifest_id
LEFT JOIN public.clients c    ON c.id  = dm.client_id;

GRANT SELECT ON derm.manifest_number_proposals TO anon, authenticated;
GRANT ALL    ON derm.manifest_number_proposals TO service_role;

COMMIT;
