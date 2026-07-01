-- 2026-07-01_derm_address_row_map.sql
-- Physical-row grain map: which client sits in which facility row of each DERM address sheet.
-- Audit: OPT-IN (DERM compliance, Rule 8 / ADR 010). updated_at trigger-managed (Rule 7).
-- Client referenced by FK only (Rules 2/3). Idempotent upsert key = (dump_folder,page,row_index) (Rule 5).
CREATE TABLE IF NOT EXISTS derm.address_row_map (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  dump_folder           text NOT NULL,
  white_manifest_number text,
  page                  int  NOT NULL,
  row_index             int  NOT NULL,
  image_url             text NOT NULL,
  facility_name_read    text,
  address_read          text,
  matched_client_id     bigint REFERENCES public.clients(id),
  assignment_status     text NOT NULL CHECK (assignment_status IN ('matched','unmatched','low_confidence','proposed')),
  confidence            text CHECK (confidence IN ('high','medium','low')),
  agent_agreement       text,
  flags                 jsonb NOT NULL DEFAULT '{}'::jsonb,
  source                text NOT NULL DEFAULT 'claude-vision-v1',
  reviewed_by           text,
  reviewed_at           timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT address_row_map_natural_key UNIQUE (dump_folder, page, row_index)
);
CREATE INDEX IF NOT EXISTS idx_address_row_map_manifest ON derm.address_row_map (white_manifest_number);
CREATE INDEX IF NOT EXISTS idx_address_row_map_client   ON derm.address_row_map (matched_client_id);

DROP TRIGGER IF EXISTS trg_address_row_map_updated_at ON derm.address_row_map;
CREATE TRIGGER trg_address_row_map_updated_at BEFORE UPDATE ON derm.address_row_map
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS audit_address_row_map ON derm.address_row_map;
CREATE TRIGGER audit_address_row_map AFTER INSERT OR UPDATE OR DELETE ON derm.address_row_map
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();
