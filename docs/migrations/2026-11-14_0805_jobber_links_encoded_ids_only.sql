-- 2026-11-14_0805_jobber_links_encoded_ids_only.sql
--
-- WHY
-- ---
-- Fred, 2026-11-14: "Do this task here: Merge duplicate quote rows from two Jobber id forms". Found while the
-- Ops Portal's Clients pages were built: Jobber quotes #3158 and #3159 were each stored twice in public.quotes.
--
-- Measured 2026-11-14, 07:40 to 08:05 ET:
--   * Every Jobber link in public.entity_source_links holds the ENCODED id (base64 of gid://Jobber/<Type>/<n>),
--     more than 30,000 rows over 16 kinds, EXCEPT two quote links holding the bare number:
--       link  4146 -> quote 166 (#3158, no client, archived), the twin of quote 165 (link  1367, encoded)
--       link 20926 -> quote 167 (#3159, destroyed),           the twin of quote 168 (link 23911, encoded)
--   * Both are leftovers of the convention before 2026-04-29, when the webhook stored bare numbers and the first
--     load stored encoded ids, so a lookup missed and minted a second row. The 2026-07-31 cleanup
--     (2026-07-31_1119_esl_numeric_gid_cleanup.sql) removed the leftovers it listed by id; these two were not on
--     its list. The 2026-10-05 stage 19 fix named them duplicates and only corrected their status.
--   * The kept twins were re-read from Jobber (read only, 2026-11-14): #3158 is archived (= quote 165, archived);
--     #3159 answers null, gone (= quote 168, destroyed).
--   * The duplicates have 0 jobs, 0 line items and 0 payment allocations. The three foreign keys on
--     public.quotes are NO ACTION, so a reference missed here makes the DELETE fail instead of orphaning it.
--   * NOT duplicates, untouched: #3244, #3276, #3292 and #3305 are each two DIFFERENT Jobber quotes (different
--     ids): Jobber gave a deleted quote's number to the next quote.
-- No live writer stores a bare number today (every writer, the payments copy included, stores the encoded id).
-- So the rule becomes structural: the database refuses a bare-number Jobber id, and a writer that ever regresses
-- fails loudly (23514) instead of minting a second row. Jobber's own API also refuses a bare number as an
-- EncodedId (2026-07-31 finding).
--
-- WHAT THIS DOES
--   PART 1 guards the exact state measured (any difference stops the migration).
--   PART 2 deletes links 4146 and 20926, then quotes 166 and 167. Backup (workspace, not this public repo):
--          backups/2026-11-14_quote_doubles_166_167.json (taken 08:02:58 ET). public.quotes carries an audit trigger
--          since 2026-11-14_0620, so the delete is in audit.logs too.
--   PART 3 adds CHECK entity_source_links_jobber_id_encoded.
--   VERIFY inside the transaction.
-- Rollback: 2026-11-14_rollback_jobber_links_encoded_ids_only.sql. Standing check:
-- scripts/checks/jobber_links_one_id_form.sql.

BEGIN;

-- PART 1: the state this was written against
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.entity_source_links WHERE source_system = 'jobber' AND source_id ~ '^[0-9]+$';
  IF n <> 2 THEN RAISE EXCEPTION 'GUARD: expected 2 bare-number jobber links, found %', n; END IF;
  IF (SELECT count(*) FROM public.entity_source_links
       WHERE (id = 4146 AND entity_type = 'quote' AND entity_id = 166 AND source_system = 'jobber' AND source_id = '58385340')
          OR (id = 20926 AND entity_type = 'quote' AND entity_id = 167 AND source_system = 'jobber' AND source_id = '58466042')) <> 2
    THEN RAISE EXCEPTION 'GUARD: links 4146 and 20926 are not as measured'; END IF;
  IF (SELECT count(*) FROM public.entity_source_links
       WHERE (id = 1367 AND entity_type = 'quote' AND entity_id = 165 AND source_id = 'Z2lkOi8vSm9iYmVyL1F1b3RlLzU4Mzg1MzQw')
          OR (id = 23911 AND entity_type = 'quote' AND entity_id = 168 AND source_id = 'Z2lkOi8vSm9iYmVyL1F1b3RlLzU4NDY2MDQy')) <> 2
    THEN RAISE EXCEPTION 'GUARD: the kept twins 165 and 168 are not linked as measured'; END IF;
  IF (SELECT count(*) FROM public.quotes WHERE (id = 166 AND quote_number = '3158') OR (id = 167 AND quote_number = '3159')) <> 2
    THEN RAISE EXCEPTION 'GUARD: quotes 166 and 167 are not as measured'; END IF;
  IF EXISTS (SELECT 1 FROM public.jobs WHERE quote_id IN (166, 167))
     OR EXISTS (SELECT 1 FROM public.line_items WHERE quote_id IN (166, 167))
     OR EXISTS (SELECT 1 FROM public.payment_allocations WHERE quote_id IN (166, 167))
    THEN RAISE EXCEPTION 'GUARD: something references quote 166 or 167'; END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'entity_source_links_jobber_id_encoded')
    THEN RAISE EXCEPTION 'GUARD: the CHECK already exists'; END IF;
END $$;

-- PART 2: remove the two leftover duplicates and their bare-number links
DELETE FROM public.entity_source_links WHERE id IN (4146, 20926) AND source_system = 'jobber' AND source_id ~ '^[0-9]+$';
DELETE FROM public.quotes WHERE id IN (166, 167);

-- PART 3: the rule, in the database
ALTER TABLE public.entity_source_links
  ADD CONSTRAINT entity_source_links_jobber_id_encoded
  CHECK (source_system <> 'jobber' OR source_id !~ '^[0-9]+$');
COMMENT ON CONSTRAINT entity_source_links_jobber_id_encoded ON public.entity_source_links IS
  'A Jobber link stores the ENCODED id (base64 of gid://Jobber/<Type>/<n>), never the bare number: the two forms made the same Jobber record twice before 2026-04-29 (2026-11-14_0805).';

-- VERIFY
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.entity_source_links WHERE source_system = 'jobber' AND source_id ~ '^[0-9]+$';
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY: % bare-number jobber links remain', n; END IF;
  IF EXISTS (SELECT 1 FROM public.quotes WHERE id IN (166, 167)) THEN RAISE EXCEPTION 'VERIFY: a duplicate quote remains'; END IF;
  IF (SELECT count(*) FROM public.quotes WHERE id IN (165, 168)) <> 2 THEN RAISE EXCEPTION 'VERIFY: a kept twin is missing'; END IF;
  -- No Jobber record on two rows of one kind, once both forms are decoded (positive control below).
  SELECT count(*) INTO n FROM (
    SELECT entity_type, substring(convert_from(decode(rpad(source_id, ((length(source_id) + 3) / 4) * 4, '='), 'base64'), 'UTF8') FROM '([0-9]+)$') AS jid
      FROM public.entity_source_links
     WHERE source_system = 'jobber' AND source_id ~ '^[A-Za-z0-9+/=]+$'
     GROUP BY 1, 2 HAVING count(DISTINCT entity_id) > 1) d WHERE jid IS NOT NULL;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY: % Jobber records still sit on two rows of one kind', n; END IF;
  -- Positive control of the decoder: the kept link of #3158 decodes to its number.
  IF substring(convert_from(decode(rpad('Z2lkOi8vSm9iYmVyL1F1b3RlLzU4Mzg1MzQw', 36, '='), 'base64'), 'UTF8') FROM '([0-9]+)$') <> '58385340'
    THEN RAISE EXCEPTION 'VERIFY: the decoder does not decode a known id'; END IF;
  -- Positive control of the CHECK: a bare number is refused (a made-up entity id, so no unique index fires first).
  BEGIN
    INSERT INTO public.entity_source_links (entity_type, entity_id, source_system, source_id) VALUES ('quote', -1, 'jobber', '58385340');
    RAISE EXCEPTION 'VERIFY: the CHECK let a bare number in';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;

COMMIT;
