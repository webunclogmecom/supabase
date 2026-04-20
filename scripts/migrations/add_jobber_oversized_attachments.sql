-- ============================================================================
-- Migration: track oversized Jobber attachments for follow-up
-- ============================================================================
-- Context:
--   Supabase Pro bucket file_size_limit is capped at 50 MB. Some Jobber
--   attachments (videos, mostly) exceed this. The migration script skips
--   them and logs their metadata here so they can be recovered later —
--   either by upgrading the Supabase plan, using external storage, or
--   compressing before upload.
--
-- 3NF check:
--   Every column is a direct attribute of the (client_id, attachment_jobber_id)
--   pair. jobber_url_signed is captured at log time (it expires in 3 days —
--   load-bearing for any recovery pass that runs within that window).
--
-- NOTE:
--   This is an operational tracking table. It is NOT part of the business
--   schema. Rows are never consumed by views; they're read by a follow-up
--   recovery script or a human audit.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS jobber_oversized_attachments (
  id                      BIGSERIAL PRIMARY KEY,
  client_id               BIGINT REFERENCES clients(id),
  note_jobber_id          TEXT,
  attachment_jobber_id    TEXT NOT NULL UNIQUE,
  file_name               TEXT,
  content_type            TEXT,
  size_bytes              BIGINT,
  jobber_url_signed       TEXT,     -- signed S3 URL — expires ~3 days after logging
  classification_kind     TEXT,     -- 'visit' | 'non_visit'
  visit_id                BIGINT REFERENCES visits(id),
  logged_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_jobber_oversized_client
  ON jobber_oversized_attachments (client_id);

COMMENT ON TABLE jobber_oversized_attachments IS
  'Tracking table: Jobber attachments > 50 MB that the migration script skipped because of Supabase Pro bucket size cap. Recovery requires either plan upgrade or external storage.';

COMMIT;
