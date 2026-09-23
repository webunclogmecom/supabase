-- 2026-09-23_0926_fillout_inspection_intake.sql
--
-- WHY
-- ---
-- Fred, 2026-09-23: "the idea is that later we will use a mobile app for the Drivers to do that
-- inspection, but for now we could try to also get the data when posted from the Fillout".
--
-- Pre/post SHIFT inspections are collected on two Fillout forms and land in Airtable. That pipeline
-- is LIVE and is not being touched by this migration. What died in July 2026 was only the feed from
-- Airtable into this warehouse: public.inspections stopped at 2026-07-11 with 319 rows while the
-- Airtable table kept filling and now holds 443. This adds a SECOND destination so a submission
-- reaches us directly, and it is deliberately shaped so the future driver mobile app can POST the
-- identical body to the identical endpoint with no server change.
--
-- 🛑 CORRECTION THIS WORK RESTS ON: this repo said Airtable was "fully retired, treat it as dead,
-- not live". That is true of the FEED and false of the DATA, and it was briefed to Viktor as fact on
-- 2026-09-23 before Fred corrected it. See the Airtable paragraph in CLAUDE.md.
--
-- WHAT THIS DOES NOT NEED, WHICH IS THE POINT
-- -------------------------------------------
-- Nothing about public.inspections, public.photos, public.photo_links or public.entity_source_links
-- changes. Measured before writing a line:
--   * entity_source_links_entity_type_chk ALREADY contains 'inspection'   (319 rows, all 'airtable')
--   * photo_links_entity_type_chk         ALREADY contains 'inspection'   (2,476 rows)
--   * photos.source has NO check constraint, so a new 'fillout_webhook' value is legal
--   * inspections.gas_level already stores exactly Fillout's four choices: 1/4, 1/2, 3/4, Full
--   * inspections.inspection_type is 'PRE' | 'POST'
--   * every Fillout photo field already has an established photo_links.role, in use:
--       dashboard 262, cabin 264, front 264, back 265, left_side 266, right_side 265,
--       cabin_left 22, cabin_right 22, sludge_level 131, water_level 131, remote 66,
--       derm_manifest 124, derm_address 229, closed_valve 100, issue 24, expense_receipt 41
--     ⚠ That live vocabulary is RICHER than the table in ADR 009, which lists tires/boots (never
--     used) and omits left_side/right_side/cabin_left/cabin_right/closed_valve/remote/expense_receipt
--     (all in use). The ADR's role table is stale; the DATA is the contract. Do not "correct" the
--     new code to match the ADR.
-- So this migration adds exactly ONE object: a queue, because the photos must not be fetched inside
-- the webhook request.
--
-- WHY A QUEUE AND NOT INLINE PHOTO FETCHING
-- -----------------------------------------
-- A submission carries up to 17 attachment fields. Fetching and re-uploading them inside the webhook
-- would (a) hold Fillout's request open for a long sequential round-trip chain, and Fillout retries
-- on timeout, which is how you get duplicate inspections; and (b) walk straight into the edge-function
-- memory ceiling this repo already documented the expensive way (std base64 OOM at ~5MB, see CLAUDE.md).
-- So the webhook commits the row FAST and enqueues the file URLs. A cron drains them a few at a time,
-- the same shape as redact-manifest-sweep (limit 1) and outbound-custom-field-push.
--
-- RULE 8 (audit-trail standing check): OPT OUT, and this is a change of state worth stating.
--   public.inspections carries NO audit trigger today (measured). This migration does not add one,
--   because an inspection is a sync-only append from a form submission, not a human-editable record,
--   and the raw submission is retained independently in public.webhook_events_log.
--   ⚠ If the driver mobile app ever lets someone EDIT a submitted inspection, that justification
--   expires and this table must be opted in. sync.inbound_file_queue itself is machine-only
--   plumbing and opts out for the same reason as sync.outbound_queue.
--
-- RULE 1 (source-agnostic schema): no fillout_* column exists anywhere. Identity lives in
--   entity_source_links (entity_type 'inspection', source_system 'fillout', source_id = the Fillout
--   Submission ID), exactly as the Airtable rows use source_system 'airtable'.
--
-- RULE 5 (idempotent upserts only): the Submission ID is the natural key. A replayed webhook
--   resolves the existing inspection through entity_source_links and UPDATEs it. Fillout retrying a
--   timed-out delivery therefore cannot create a second inspection.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1 - the inbound file queue
-- ---------------------------------------------------------------------------
-- Column names deliberately mirror sync.outbound_queue (status/attempts/last_error/processed_at) so
-- the two read the same way in a health view.

CREATE TABLE sync.inbound_file_queue (
  id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_type    TEXT        NOT NULL,
  entity_id      BIGINT      NOT NULL,
  source_system  TEXT        NOT NULL,
  role           TEXT        NOT NULL,
  source_url     TEXT        NOT NULL,
  target_bucket  TEXT        NOT NULL,
  status         TEXT        NOT NULL DEFAULT 'pending',
  attempts       INTEGER     NOT NULL DEFAULT 0,
  last_error     TEXT,
  photo_id       BIGINT      REFERENCES public.photos(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  processed_at   TIMESTAMPTZ,

  CONSTRAINT inbound_file_queue_status_chk
    CHECK (status IN ('pending','done','skipped','error')),
  CONSTRAINT inbound_file_queue_entity_chk
    CHECK (entity_type IN ('inspection')),
  -- One attempt per (entity, role, source file). A replayed submission re-enqueues nothing.
  CONSTRAINT inbound_file_queue_uniq
    UNIQUE (entity_type, entity_id, role, source_url)
);

COMMENT ON TABLE sync.inbound_file_queue IS
  'Files named by an inbound webhook that must be fetched into Supabase Storage out of band. '
  'Written by the fillout-inspection edge function, drained by a cron. Exists so a webhook can '
  'answer fast: fetching ~17 attachments inline would hold the caller open and invite a retry, '
  'which duplicates the parent row. Mirrors sync.outbound_queue column-for-column where it can.';

COMMENT ON COLUMN sync.inbound_file_queue.role IS
  'The photo_links.role the fetched file will be given. Must be a role already in use for this '
  'entity_type - see the migration header for the live vocabulary and why it beats ADR 009.';

CREATE INDEX inbound_file_queue_pending_idx
  ON sync.inbound_file_queue (created_at)
  WHERE status = 'pending';

-- ---------------------------------------------------------------------------
-- PART 2 - grants
-- ---------------------------------------------------------------------------
-- 🛑 Supabase's ALTER DEFAULT PRIVILEGES hands out grants nobody wrote (CLAUDE.md, bitten twice).
-- Revoke first, grant explicitly, then ASSERT the resulting ACL rather than trusting the GRANTs.

REVOKE ALL ON sync.inbound_file_queue FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON sync.inbound_file_queue TO service_role;

-- ---------------------------------------------------------------------------
-- VERIFY - runs inside the transaction, rolls the whole thing back on any failure
-- ---------------------------------------------------------------------------
DO $verify$
DECLARE
  v_bad   INTEGER;
  v_txt   TEXT;
BEGIN
  -- 1. The premise of the whole design: no parent schema change was needed.
  SELECT count(*) INTO v_bad
  FROM pg_constraint
  WHERE conrelid = 'public.entity_source_links'::regclass
    AND conname  = 'entity_source_links_entity_type_chk'
    AND pg_get_constraintdef(oid) LIKE '%''inspection''%';
  IF v_bad <> 1 THEN
    RAISE EXCEPTION 'entity_source_links no longer whitelists inspection; the intake design assumed it does';
  END IF;

  SELECT count(*) INTO v_bad
  FROM pg_constraint
  WHERE conrelid = 'public.photo_links'::regclass
    AND conname  = 'photo_links_entity_type_chk'
    AND pg_get_constraintdef(oid) LIKE '%''inspection''%';
  IF v_bad <> 1 THEN
    RAISE EXCEPTION 'photo_links no longer whitelists inspection; photo intake would fail at runtime';
  END IF;

  -- 2. photos.source must stay unconstrained, or 'fillout_webhook' is rejected at runtime.
  SELECT count(*) INTO v_bad
  FROM pg_constraint
  WHERE conrelid = 'public.photos'::regclass AND contype = 'c'
    AND pg_get_constraintdef(oid) LIKE '%source%';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'photos.source has gained a CHECK; fillout_webhook must be added to it';
  END IF;

  -- 3. The roles this intake writes must ALL already exist in live data. A role that is new here
  --    is a typo, not a feature: it would render as an unknown tile in every consumer.
  SELECT string_agg(r, ', ') INTO v_txt
  FROM unnest(ARRAY[
    'dashboard','cabin','front','back','left_side','right_side','cabin_left','cabin_right',
    'sludge_level','water_level','remote','derm_manifest','derm_address','closed_valve','issue'
  ]) AS r
  WHERE NOT EXISTS (
    SELECT 1 FROM public.photo_links
    WHERE entity_type = 'inspection' AND role = r
  );
  IF v_txt IS NOT NULL THEN
    RAISE EXCEPTION 'these intake roles have no precedent in photo_links: %', v_txt;
  END IF;

  -- 4. The grant assertion, read off the ACL rather than off the GRANT statements above.
  IF has_table_privilege('authenticated', 'sync.inbound_file_queue', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated can read sync.inbound_file_queue; default privileges leaked again';
  END IF;
  IF has_table_privilege('anon', 'sync.inbound_file_queue', 'SELECT') THEN
    RAISE EXCEPTION 'anon can read sync.inbound_file_queue';
  END IF;
  IF NOT has_table_privilege('service_role', 'sync.inbound_file_queue', 'INSERT') THEN
    RAISE EXCEPTION 'service_role cannot write the queue; the edge function would fail';
  END IF;

  -- 5. Positive control: prove assertion 3 can actually fail, so a clean run means something.
  IF EXISTS (SELECT 1 FROM public.photo_links
             WHERE entity_type = 'inspection' AND role = 'a_role_that_must_not_exist') THEN
    RAISE EXCEPTION 'control failed: the role-precedent check cannot distinguish a bad role';
  END IF;

  RAISE NOTICE 'VERIFY passed: no parent schema change needed, queue is service_role-only, 15 roles have precedent';
END
$verify$;

COMMIT;
