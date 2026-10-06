-- 2026-10-05_2215_quotes_stage_19_missing_fix_3_stale.sql
--
-- WHY
-- ---
-- Fred, 2026-10-05: "go ahead with all", on "compare every Jobber quote with our database?". Quote #215
-- (approved, Ava Coconut Grove) had never reached public.quotes, so the Client App's archive dialog said
-- there was nothing to resolve while Jobber refused the archive. A full read-only comparison the same
-- evening (all 229 Jobber quotes vs 276 rows, compared by the exact stored GID):
--   * 19 Jobber quotes were never loaded. 16 are OPEN (11 approved, 5 awaiting_response) on 15 clients,
--     $6,057.06 in total: each of those clients would get the same false "no quotes" result.
--     Cause: the one-time load of 2026-04-29 from raw (first filled 2026-04-10) got 122 of the 141 quotes
--     that existed then; why it skipped 19 could not be established (the event log is trimmed). They stay
--     missing because sync-jobber-poll pulls quotes by updatedAt only, and these have not changed since.
--     New and changed quotes do arrive (#215 arrived the moment it was archived), so this is a one-time gap.
--   * 3 rows still read OPEN although Jobber no longer has them that way (re-read by hand at 22:12 ET,
--     each answer carried a `data` key, positive control #215 returned normally):
--       166  #3158  draft              -> archived  (Jobber: archived; a 2026-04-29 duplicate of row 165
--                                                    whose link holds a bare number, not the GID)
--       167  #3159  awaiting_response  -> destroyed (Jobber: null; duplicate of row 168, already destroyed)
--       228  #3219  awaiting_response  -> destroyed (Jobber: null; deleted, no QUOTE_DESTROY on record)
--   * 0 status, number or total differences among the 210 matched quotes.
--
-- WHAT THIS DOES
--   PART 1 flips the 3 statuses (no row deleted; links untouched). public.quotes has NO audit trigger, so
--          the old values are in backups/2026-10-05_quotes_166_167_228_before.json (workspace, not this repo)
--          and in this header.
--   PART 2 stages the 19 in raw.jobber_pull_quotes with needs_populate = TRUE, in the shape the poll writes.
--          They are then replayed by `node scripts/sync/replay_to_webhook.js --entity=quotes --execute`, which
--          signs a QUOTE_UPDATE per row to webhook-jobber: handleQuote re-reads each quote from Jobber and
--          upserts it through fn_jobber_resolve_quote. Nothing here invents a value Jobber did not give.
--
-- RULE 8: no schema change. public.quotes stays opted out of audit (sync-mastered; unchanged decision).

BEGIN;

-- PART 1
UPDATE public.quotes SET quote_status = 'archived'
 WHERE id = 166 AND quote_number = '3158' AND quote_status = 'draft';
UPDATE public.quotes SET quote_status = 'destroyed'
 WHERE id IN (167, 228) AND quote_status = 'awaiting_response' AND quote_number IN ('3159', '3219');

-- PART 2
INSERT INTO raw.jobber_pull_quotes (data, pulled_at, ingested_at, needs_populate)
SELECT v.d, now(), now(), TRUE
  FROM (VALUES
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzM4ODk2ODM2","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC85NTk0MzYyNw=="},"amounts":{"total":500},"updatedAt":"2024-11-21T16:04:48Z","_cursorTime":"2024-11-21T16:04:48Z","quoteNumber":"1","quoteStatus":"converted"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzQxMTI2MDk5","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDE2MjQzNTY="},"amounts":{"total":310.59},"updatedAt":"2025-04-04T21:29:16Z","_cursorTime":"2025-04-04T21:29:16Z","quoteNumber":"5","quoteStatus":"archived"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzQyMDk0MjQ5","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDM2ODE2MjA="},"amounts":{"total":0},"updatedAt":"2025-05-06T13:49:10Z","_cursorTime":"2025-05-06T13:49:10Z","quoteNumber":"148","quoteStatus":"awaiting_response"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzQ0MTIyMDIx","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDc1MDY5NTA="},"amounts":{"total":538.36},"updatedAt":"2025-05-08T13:43:12Z","_cursorTime":"2025-05-08T13:43:12Z","quoteNumber":"167","quoteStatus":"awaiting_response"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzQ0NDMyMTkz","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC85NjgzMjYxMA=="},"amounts":{"total":538.36},"updatedAt":"2025-05-15T17:01:23Z","_cursorTime":"2025-05-15T17:01:23Z","quoteNumber":"170","quoteStatus":"awaiting_response"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzQ0NjAzODMz","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDg0MjE5NTI="},"amounts":{"total":580},"updatedAt":"2025-05-20T15:22:34Z","_cursorTime":"2025-05-20T15:22:34Z","quoteNumber":"171","quoteStatus":"awaiting_response"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzQ0NjUyMTI2","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDg2MDYzMTI="},"amounts":{"total":0},"updatedAt":"2025-05-21T13:13:17Z","_cursorTime":"2025-05-21T13:13:17Z","quoteNumber":"172","quoteStatus":"awaiting_response"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzQ1ODI4Mjc1","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMTExMDQ1NTA="},"amounts":{"total":365},"updatedAt":"2025-07-30T17:39:47Z","_cursorTime":"2025-07-30T17:39:47Z","quoteNumber":"185","quoteStatus":"approved"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzQ5NTcwNTE2","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMTg5MDIxMDQ="},"amounts":{"total":349},"updatedAt":"2025-09-22T17:07:28Z","_cursorTime":"2025-09-22T17:07:28Z","quoteNumber":"208","quoteStatus":"converted"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzUyMDYxMzIw","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMjM2MDE5MDQ="},"amounts":{"total":245},"updatedAt":"2025-11-21T20:39:01Z","_cursorTime":"2025-11-21T20:39:01Z","quoteNumber":"246","quoteStatus":"approved"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzUyNTE3ODQx","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMjQ3ODYyNzc="},"amounts":{"total":349},"updatedAt":"2025-12-07T19:01:10Z","_cursorTime":"2025-12-07T19:01:10Z","quoteNumber":"264","quoteStatus":"approved"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzUyODk2MjE3","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMjU4MDc5MTk="},"amounts":{"total":530},"updatedAt":"2025-12-20T14:22:08Z","_cursorTime":"2025-12-20T14:22:08Z","quoteNumber":"274","quoteStatus":"approved"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzUzMjMxNzUx","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMjY3MjU0NzY="},"amounts":{"total":413.08},"updatedAt":"2026-01-07T18:19:52Z","_cursorTime":"2026-01-07T18:19:52Z","quoteNumber":"285","quoteStatus":"approved"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzU0MDg2MDE1","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMjkxOTM4NDA="},"amounts":{"total":132.64},"updatedAt":"2026-02-03T16:20:38Z","_cursorTime":"2026-02-03T16:20:38Z","quoteNumber":"298","quoteStatus":"approved"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzU0MTM1NDcy","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMjkxOTM4NDA="},"amounts":{"total":816.82},"updatedAt":"2026-02-03T17:58:10Z","_cursorTime":"2026-02-03T17:58:10Z","quoteNumber":"300","quoteStatus":"approved"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzU0NzQ0MzA4","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMzA4NDg1MDI="},"amounts":{"total":361.32},"updatedAt":"2026-02-19T14:32:39Z","_cursorTime":"2026-02-19T14:32:39Z","quoteNumber":"3113","quoteStatus":"approved"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzU0OTA2MTYx","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMzEyNTY0OTU="},"amounts":{"total":361.32},"updatedAt":"2026-02-23T23:13:06Z","_cursorTime":"2026-02-23T23:13:06Z","quoteNumber":"3114","quoteStatus":"approved"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzU1MDQyNDEx","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMzE1NTc1MDg="},"amounts":{"total":413.08},"updatedAt":"2026-02-26T18:20:18Z","_cursorTime":"2026-02-26T18:20:18Z","quoteNumber":"3116","quoteStatus":"approved"}$j$::jsonb),
  ($j${"id":"Z2lkOi8vSm9iYmVyL1F1b3RlLzU1NDE5NDk2","client":{"id":"Z2lkOi8vSm9iYmVyL0NsaWVudC8xMzIzNjEyMzQ="},"amounts":{"total":413.08},"updatedAt":"2026-03-11T17:30:57Z","_cursorTime":"2026-03-11T17:30:57Z","quoteNumber":"3125","quoteStatus":"approved"}$j$::jsonb)

  ) v(d)
 WHERE NOT EXISTS (SELECT 1 FROM raw.jobber_pull_quotes r WHERE r.data->>'id' = v.d->>'id');

DO $verify$
DECLARE v_n integer;
BEGIN
  SELECT count(*) INTO v_n FROM public.quotes
   WHERE (id = 166 AND quote_status = 'archived') OR (id IN (167, 228) AND quote_status = 'destroyed');
  IF v_n <> 3 THEN RAISE EXCEPTION 'VERIFY 1: % of 3 stale rows corrected', v_n; END IF;

  SELECT count(*) INTO v_n FROM raw.jobber_pull_quotes WHERE needs_populate;
  IF v_n <> 19 THEN RAISE EXCEPTION 'VERIFY 2: % quotes flagged for replay (want 19)', v_n; END IF;

  -- none of the 19 is already linked (they really are missing)
  SELECT count(*) INTO v_n FROM raw.jobber_pull_quotes r
    JOIN public.entity_source_links l ON l.entity_type = 'quote' AND l.source_system = 'jobber' AND l.source_id = r.data->>'id'
   WHERE r.needs_populate;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 3: % staged quote(s) already linked', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: 3 stale rows corrected, 19 missing quotes staged for replay';
END
$verify$;

COMMIT;
