-- ============================================================================
-- Migration: drop properties.location_photo_url
-- ============================================================================
-- Context:
--   The column was added to store a property's primary location photo URL,
--   deprecated in favor of the unified photos + photo_links architecture
--   (ADR 009). The ADR 009 migration planned a backfill pass before drop.
--
-- Discovery (2026-04-20):
--   Probed the column — 161 of 421 rows populated, BUT the values are
--   "Yes" / "No" literals, not URLs. A bug in populate.js (line 334)
--   pulled from Airtable field "Photo and Location of GT" which turns
--   out to be a checkbox, not an attachment field.
--
--   Host-regex check on the populated values:
--     host="Yes"  count=132
--     host="No"   count=29
--     No real URLs.
--
--   There's nothing to backfill. The column is semantically broken
--   from the initial populate run.
--
-- 3NF check:
--   Dropping the column is a pure reduction. No consumers because any
--   reader would have seen "Yes"/"No" instead of a URL and (hopefully)
--   noticed it was broken.
--
-- Consumer cleanup:
--   populate.js lines 334, 545, 581, 603, 615 are updated in the same
--   commit to stop writing the column.
--
-- Supersedes:
--   The "properties.location_photo_url backfill + drop" follow-up
--   mentioned in ADR 009 and docs/migration-plan.md.
-- ============================================================================

BEGIN;

ALTER TABLE properties DROP COLUMN IF EXISTS location_photo_url;

COMMIT;
