-- 2026-09-03_2210_sheet_number_read_on_upload.sql
--
-- WHY
-- ---
-- Fred: *"cron-24 should only be done once per manifest (in all it's pages), unless there is an
-- update of the manifest (like adding, deleting pages, etc)... so instead of a cron, maybe a
-- trigger, when a manifest (with it's pages) gets uploaded on the DERM App, it should happen."*
--
-- Full reasoning, the measured scope table and the test plan:
--   docs/superpowers/specs/2026-09-03-sheet-number-read-on-upload-design.md
--
-- THE DEFECT
-- ----------
-- `derm.fn_sheet_number_ocr_targets()` returns **0 rows estate-wide**, so cron 24
-- `sheet-number-ocr-sweep` is a structural no-op. Positive control: `_for(ARRAY['834742'])` returns
-- 1 row, so the machinery works and the zero is structural. Arm A needs an unplaced card (0 exist);
-- Arm B is documented SELF-DRAINING and every folder it covers has been read once.
--
-- The sheet number is the ONLY thing establishing which physical page each stored scan is, and a
-- reversed pair is what put every stamp on the wrong scan on `ticket-833813`, `ticket-312433` and
-- `ticket-833049`. With the sweep drained, nothing can catch the next one.
--
-- 🛑 THE ROOT CAUSE IS THE PREDICATE, NOT THE SCHEDULE. Both arms ask "has this page EVER been
-- read?" - `sr.dump_folder = ... AND sr.page = ...`, with **`image_url` never compared**. So once a
-- page has any read it is never offered again EVEN IF THE IMAGE AT THAT POSITION CHANGED. Delete a
-- page and every later position now holds a different scan while the stale reads keep asserting the
-- old mapping. That is a silent wrong answer, and it is what this migration removes.
--
-- FRED'S RULE, AS A DERIVED CONDITION
-- -----------------------------------
--   an image position needs reading IFF no scan read names the image that is at that position NOW
-- which is `... AND sr.image_url = g.url`. It needs no state to maintain and expresses his rule
-- exactly: read once per page; re-read only when a page is added, deleted or replaced; otherwise
-- never again. It is also SELF-HEALING, where a trigger-fed queue would miss the SQL backfills this
-- estate does constantly.
--
-- TRIGGER *AND* CRON, WITH DIFFERENT JOBS
--   * TRIGGER on `public.derm_manifests` gives immediacy, fires once per STATEMENT, and only when
--     there is backlog. It cannot do the reading itself: that is a vision call over HTTP and must
--     not sit in the operator's upload transaction.
--   * The DERIVED PREDICATE is the source of truth.
--   * The CRON stays as the safety net. It now normally finds nothing and makes no HTTP call - the
--     same shape as `city-email-sweep` (1.5 s of DB time per day there).
--
-- THE RETRY BOUND IS NARROWER THAN IT LOOKS, AND THAT IS MEASURED FROM THE HANDLER SOURCE
-- ---------------------------------------------------------------------------------------
-- `ocr-address-sheet-number` upserts on `(dump_folder, page)` and WRITES `image_url`, and it writes
-- **even when the number is unreadable** (`confidence:'unreadable'`, `sheet_no_read:null`). So the
-- derived predicate self-drains after one attempt on any page the handler actually reaches; no
-- ledger is needed for that. The gap is the EXCEPTION path: on a failed image fetch or vision error
-- it does `continue` **without writing** ("leave it unread; the gate treats no read as no opinion").
-- Those pages would retry for ever.
-- ⇒ `derm.sheet_number_ocr_attempts` bounds ONLY that path. `image_url` is IN THE KEY, so replacing
-- a scan re-arms it automatically with no expiry logic.
-- ⇒ The attempt is recorded when the target is HANDED OUT, not when the worker reports back: that
-- gives at-most-N without trusting a worker that may die mid-call. A target handed out and never
-- processed still counts, which is the fail-safe direction.
--
-- 🛑 SCOPE IS DELIBERATELY UNCHANGED, AND THE GAP IS REPORTED RATHER THAN SILENTLY CLOSED.
-- The existing filter is `dump_folder LIKE 'ticket-%'`, justified on "a read can never be used"
-- because `window*` folders have no generated-sheet link. **That is the same premise Arm B exists to
-- refute** - true for auto-placement, false for page identity. Measured today:
--     ticket-%   42 multi-image positions,  0 unread
--     derm/*     11 multi-image positions,  0 unread
--     window*    35 multi-image positions, 35 unread, across 17 folders
-- and **those 17 folders serve 157 client documents** (`window*` is 371 of the 677 served overall).
-- Reading them is a client-facing decision with a real cost (35 vision calls on handwritten pads
-- whose reads may be garbage - one run once read `window12-sheet9` as `224`) and a real risk. It is
-- NOT taken here. `derm.v_sheet_number_ocr_backlog` is scope-free so the gap is visible and
-- countable; widening the targets filter is one line when Fred decides.
-- ⚠ Mitigating fact, so the risk is not overstated: `fn_sheet_image_position` only honours a
-- high-confidence read with a `-N` SUFFIX, so unsuffixed noise like `224` is inert.
--
-- 🛑 UNATTENDED RE-PLACEMENT IS NOT SHIPPED, ON PURPOSE.
-- The deeper half of the ticket-834742 bug is timing: the card was filed at 12:20:39 and the OCR ran
-- **9m24s later**, so the map was empty at filing. Even a trigger cannot guarantee the read beats the
-- filing. Since `2026-09-03_1510` a missing map no longer corrupts anything - the card is simply not
-- placed - so the failure mode is a silently UNPLACED card, not a wrongly-placed one. Auto-placement
-- is the mechanism that put every stamp on the wrong scan on three folders; adding a second,
-- unattended placement path that fires later, on data whose page map has just changed, is how that
-- class of defect returns. What ships instead is the DETECTOR, `derm.v_cards_awaiting_page_map`.
-- Empty is healthy. The manual `_for(...)` escape hatch is untouched and stays unbounded.
--
-- RULE 8 (audit): `derm.sheet_number_ocr_attempts` OPTS OUT. It is machine bookkeeping with no
-- human-editable field, regenerable by definition (deleting it only re-arms reads), and it mirrors
-- `derm.row_ocr_attempts`, which is also unaudited. No other table changes.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1. The attempt ledger. Bounds ONLY the handler's exception path.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS derm.sheet_number_ocr_attempts (
  dump_folder      text        NOT NULL,
  page             integer     NOT NULL,
  image_url        text        NOT NULL,
  attempts         integer     NOT NULL DEFAULT 0,
  first_attempt_at timestamptz NOT NULL DEFAULT now(),
  last_attempt_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sheet_number_ocr_attempts_pkey PRIMARY KEY (dump_folder, page, image_url),
  CONSTRAINT sheet_number_ocr_attempts_attempts_chk CHECK (attempts >= 0 AND attempts <= 100)
);

COMMENT ON TABLE derm.sheet_number_ocr_attempts IS
  'Bounds the sheet-number OCR retry loop. Only needed for the handler''s EXCEPTION path: a normal '
  'read (including an unreadable one) writes derm.address_sheet_scan_reads and self-drains the '
  'backlog. image_url is part of the key ON PURPOSE, so replacing a scan re-arms the page with no '
  'expiry logic. Unaudited by design (rule 8 opt-out): machine bookkeeping, regenerable, and '
  'deleting a row only causes a re-read.';

REVOKE ALL ON TABLE derm.sheet_number_ocr_attempts FROM PUBLIC;
REVOKE ALL ON TABLE derm.sheet_number_ocr_attempts FROM anon;
GRANT SELECT, INSERT, UPDATE ON TABLE derm.sheet_number_ocr_attempts TO service_role;

-- ---------------------------------------------------------------------------
-- PART 2. THE DERIVED PREDICATE. Scope-free on purpose, so the window* gap stays countable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW derm.v_sheet_number_ocr_backlog AS
WITH f AS (
  SELECT r.dump_folder, max(r.white_manifest_number) AS ticket
    FROM derm.address_row_map r
   WHERE r.white_manifest_number IS NOT NULL
   GROUP BY r.dump_folder
)
SELECT f.dump_folder,
       f.ticket,
       g.ord::int                                                   AS page,
       g.url                                                        AS image_url,
       coalesce(array_length(derm.ticket_page_images(f.ticket), 1), 0) AS n_pages,
       coalesce(a.attempts, 0)                                      AS attempts,
       a.last_attempt_at,
       CASE WHEN f.dump_folder LIKE 'ticket-%' THEN 'in_scope'
            ELSE 'out_of_scope' END                                 AS scope
  FROM f
  CROSS JOIN LATERAL unnest(derm.ticket_page_images(f.ticket)) WITH ORDINALITY AS g(url, ord)
  LEFT JOIN derm.sheet_number_ocr_attempts a
         ON a.dump_folder = f.dump_folder AND a.page = g.ord AND a.image_url = g.url
 WHERE g.url IS NOT NULL
   AND g.url <> 'pending'
   -- 🛑 THE WHOLE CHANGE: the read must name the image that is at this position NOW.
   AND NOT EXISTS (SELECT 1 FROM derm.address_sheet_scan_reads sr
                    WHERE sr.dump_folder = f.dump_folder
                      AND sr.page        = g.ord
                      AND sr.image_url   = g.url);

COMMENT ON VIEW derm.v_sheet_number_ocr_backlog IS
  'Image positions whose sheet number has not been read from the file CURRENTLY at that position. '
  'Empty (within scope) is healthy. Deliberately scope-free: `scope` labels the rows the cron will '
  'act on, so the window* gap (17 folders serving 157 client documents, never machine-checked for '
  'page identity) stays visible and countable rather than being filtered away.';

REVOKE ALL ON derm.v_sheet_number_ocr_backlog FROM PUBLIC;
REVOKE ALL ON derm.v_sheet_number_ocr_backlog FROM anon;
GRANT SELECT ON derm.v_sheet_number_ocr_backlog TO service_role;

-- ---------------------------------------------------------------------------
-- PART 3. The target list. Now reads the backlog, applies scope + the attempt bound, and records
--         the attempt in the same statement.
-- ⚠ Signature is byte-identical (name, arg, RETURNS TABLE) because the edge function calls it by
--   name over PostgREST. It changes from STABLE sql to VOLATILE plpgsql because it now writes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_sheet_number_ocr_targets(p_limit integer DEFAULT 3)
 RETURNS TABLE(dump_folder text, ticket text, page integer, image_url text)
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $fn$
#variable_conflict use_column
-- The RETURNS TABLE output parameters are named dump_folder/ticket/page/image_url so the edge
-- function can read them, and those names also appear as COLUMNS in the INSERT target list and
-- the ON CONFLICT clause below. Without this directive PL/pgSQL raises 42702 (ambiguous). The
-- output names cannot be changed: ocr-address-sheet-number reads r.dump_folder / r.page /
-- r.image_url off the PostgREST response.
DECLARE v_lim integer := greatest(1, least(coalesce(p_limit, 3), 10));
BEGIN
  -- Column aliases (f/t/pg/u) avoid shadowing the RETURNS TABLE output parameters.
  RETURN QUERY
  WITH picked AS (
    SELECT b.dump_folder AS f, b.ticket AS t, b.page AS pg, b.image_url AS u
      FROM derm.v_sheet_number_ocr_backlog b
     WHERE b.scope = 'in_scope'
       -- single-image folders have no ordering to get wrong, so a read changes no decision
       AND b.n_pages > 1
       AND b.attempts < 3
     ORDER BY b.dump_folder, b.page
     LIMIT v_lim
  ), noted AS (
    -- A data-modifying CTE runs to completion whether or not the outer query reads it.
    INSERT INTO derm.sheet_number_ocr_attempts AS a (dump_folder, page, image_url, attempts)
    SELECT p.f, p.pg, p.u, 1 FROM picked p
    ON CONFLICT (dump_folder, page, image_url)
    DO UPDATE SET attempts = a.attempts + 1, last_attempt_at = now()
    RETURNING 1
  )
  SELECT p.f, p.t, p.pg, p.u FROM picked p ORDER BY p.f, p.pg;
END $fn$;

COMMENT ON FUNCTION derm.fn_sheet_number_ocr_targets(integer) IS
  'Pages whose sheet number needs reading, from derm.v_sheet_number_ocr_backlog. Records the attempt '
  'when the target is HANDED OUT, not when the worker reports back, so a worker that dies mid-call '
  'still consumes its budget (fail-safe). Gives up after 3 attempts on the same image; replacing the '
  'image re-arms it because image_url is in the ledger key.';

-- ---------------------------------------------------------------------------
-- PART 4. Immediacy: fire on upload, once per statement, only when there is work.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_sheet_number_backlog_exists()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $fn$
  SELECT EXISTS (SELECT 1 FROM derm.v_sheet_number_ocr_backlog b
                  WHERE b.scope = 'in_scope' AND b.n_pages > 1 AND b.attempts < 3);
$fn$;

CREATE OR REPLACE FUNCTION public.trg_request_sheet_number_ocr()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'derm'
AS $fn$
BEGIN
  IF derm.fn_sheet_number_backlog_exists() THEN
    BEGIN
      PERFORM public.fn_request_sheet_number_ocr();
    EXCEPTION WHEN others THEN
      -- 🛑 SWALLOWED ON PURPOSE, and this is the one place in this migration where a failure is
      -- invisible. Failing an operator's manifest upload because a vision request could not be
      -- QUEUED would be a worse outcome than a late read. The cron is the safety net that makes the
      -- silence recoverable, and derm.v_sheet_number_ocr_backlog shows the work either way - so
      -- unlike tg_broadcast_inval, a swallowed failure here is still VISIBLE somewhere.
      NULL;
    END;
  END IF;
  RETURN NULL;
END $fn$;

DROP TRIGGER IF EXISTS zzz_request_sheet_number_ocr ON public.derm_manifests;
CREATE TRIGGER zzz_request_sheet_number_ocr
  AFTER INSERT OR UPDATE OF derm_address_url, derm_address_extra_urls ON public.derm_manifests
  FOR EACH STATEMENT EXECUTE FUNCTION public.trg_request_sheet_number_ocr();

-- ---------------------------------------------------------------------------
-- PART 5. The detector for the timing gap. Empty is healthy.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW derm.v_cards_awaiting_page_map AS
SELECT r.dump_folder,
       r.white_manifest_number AS ticket,
       r.id                    AS card_id,
       r.matched_client_id,
       r.matched_manifest_id,
       s.slot,
       geo.o_page              AS printed_page,
       derm.fn_sheet_image_position(r.dump_folder, geo.o_page) AS image_position,
       r.created_at
  FROM derm.address_row_map r
  CROSS JOIN LATERAL (SELECT derm.fn_generated_sheet_slot(r.matched_manifest_id) AS slot) s
  CROSS JOIN LATERAL derm.fn_generated_row_geometry(s.slot) AS geo
 WHERE r.stamp_placed_at IS NULL
   AND r.white_manifest_number IS NOT NULL
   AND s.slot IS NOT NULL
   AND derm.fn_sheet_is_generated(r.white_manifest_number)
   -- the map resolves NOW, so this card could be placed and was not
   AND derm.fn_sheet_image_position(r.dump_folder, geo.o_page) IS NOT NULL;

COMMENT ON VIEW derm.v_cards_awaiting_page_map IS
  'Unplaced cards on a generated sheet whose page map has since RESOLVED, i.e. the card was refused '
  'placement because the sheet number had not been read yet and could be placed now. EMPTY IS '
  'HEALTHY. Deliberately a detector and not an auto-placer: auto-placement is what put every stamp '
  'on the wrong scan on ticket-833813, ticket-312433 and ticket-833049, and a second unattended '
  'placement path firing on freshly-changed page maps is how that returns.';

REVOKE ALL ON derm.v_cards_awaiting_page_map FROM PUBLIC;
REVOKE ALL ON derm.v_cards_awaiting_page_map FROM anon;
GRANT SELECT ON derm.v_cards_awaiting_page_map TO service_role;

-- ---------------------------------------------------------------------------
-- VERIFY
-- 🛑 The in-scope backlog is 0 today, so a passing install would prove NOTHING. This drives the
--    whole state machine on a SYNTHETIC two-page folder inside a rolled-back savepoint, and
--    includes MUTATION CONTROLS proving the OLD predicate cannot see the two cases that matter.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  F  text := 'ticket-ZZOCR';
  T  text := 'ZZOCR';
  A  text := 'https://example.invalid/zzocr/a.jpg';
  B  text := 'https://example.invalid/zzocr/b.jpg';
  C  text := 'https://example.invalid/zzocr/c.jpg';
  D  text := 'https://example.invalid/zzocr/d.jpg';
  n int; n_old int; imgs text[];
  r_backlog int; r_targets int;
BEGIN
  -- ---- static wiring ----
  SELECT count(*) INTO n FROM pg_trigger
   WHERE tgrelid = 'public.derm_manifests'::regclass
     AND tgname = 'zzz_request_sheet_number_ocr'
     AND (tgtype & 1) = 0
     AND tgenabled = 'O';
  IF n <> 1 THEN RAISE EXCEPTION 'VERIFY 0a: the upload trigger is missing, row-level or disabled'; END IF;

  IF (SELECT provolatile FROM pg_proc WHERE oid = 'derm.fn_sheet_number_ocr_targets(integer)'::regprocedure) <> 'v' THEN
    RAISE EXCEPTION 'VERIFY 0b: the targets function is not VOLATILE, so it cannot record attempts';
  END IF;

  SELECT count(*) INTO n FROM derm.v_cards_awaiting_page_map;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 0c: % card(s) already awaiting a page map', n; END IF;

  SET CONSTRAINTS ALL IMMEDIATE;

  BEGIN
    -- ---- FIXTURE: a legitimate two-page folder, one distinct image per page ----
    INSERT INTO derm.address_row_map
      (dump_folder, white_manifest_number, page, row_index, image_url, assignment_status, confidence, source)
    VALUES (F, T, 1, 1, A, 'matched', 'high', 'ocr-fixture'),
           (F, T, 2, 1, B, 'matched', 'high', 'ocr-fixture');

    imgs := derm.ticket_page_images(T);
    IF imgs IS DISTINCT FROM ARRAY[A, B] THEN
      RAISE EXCEPTION 'VERIFY 1: fixture image list is %, expected two distinct pages', imgs;
    END IF;

    -- 1. Two positions, no reads -> two backlog rows, targets offer both, attempts recorded.
    SELECT count(*) INTO r_backlog FROM derm.v_sheet_number_ocr_backlog WHERE dump_folder = F;
    IF r_backlog <> 2 THEN RAISE EXCEPTION 'VERIFY 1a: backlog is %, expected 2', r_backlog; END IF;
    SELECT count(*) INTO r_targets FROM derm.fn_sheet_number_ocr_targets(10) WHERE dump_folder = F;
    IF r_targets <> 2 THEN RAISE EXCEPTION 'VERIFY 1b: targets offered %, expected 2', r_targets; END IF;
    SELECT count(*) INTO n FROM derm.sheet_number_ocr_attempts WHERE dump_folder = F AND attempts = 1;
    IF n <> 2 THEN RAISE EXCEPTION 'VERIFY 1c: % attempt row(s) at 1, expected 2 - hand-out is not recorded', n; END IF;

    -- 2. A read naming the image AT position 1 drains it.
    INSERT INTO derm.address_sheet_scan_reads
      (dump_folder, page, sheet_no_read, raw_read, confidence, model, image_url, read_at)
    VALUES (F, 1, '900-1', '900-1', 'high', 'fixture', A, now());
    SELECT count(*) INTO r_backlog FROM derm.v_sheet_number_ocr_backlog WHERE dump_folder = F;
    IF r_backlog <> 1 THEN RAISE EXCEPTION 'VERIFY 2: backlog is % after reading page 1, expected 1', r_backlog; END IF;

    -- 3. A read naming the WRONG image must NOT drain position 2.
    INSERT INTO derm.address_sheet_scan_reads
      (dump_folder, page, sheet_no_read, raw_read, confidence, model, image_url, read_at)
    VALUES (F, 2, '900-2', '900-2', 'high', 'fixture', A, now());
    SELECT count(*) INTO r_backlog FROM derm.v_sheet_number_ocr_backlog WHERE dump_folder = F;
    IF r_backlog <> 1 THEN
      RAISE EXCEPTION 'VERIFY 3: a read naming the WRONG image drained the backlog (now %) - image_url is not compared', r_backlog;
    END IF;

    -- 3b. MUTATION CONTROL: the OLD page-presence predicate is blind to this.
    SELECT count(*) INTO n_old
      FROM unnest(derm.ticket_page_images(T)) WITH ORDINALITY AS g(url, ord)
     WHERE NOT EXISTS (SELECT 1 FROM derm.address_sheet_scan_reads sr
                        WHERE sr.dump_folder = F AND sr.page = g.ord);
    IF n_old <> 0 THEN RAISE EXCEPTION 'VERIFY 3b: control - the OLD predicate reported %, expected 0', n_old; END IF;

    -- 4. Correct it -> nothing left to do. FRED RULE: once per manifest.
    UPDATE derm.address_sheet_scan_reads SET image_url = B WHERE dump_folder = F AND page = 2;
    SELECT count(*) INTO r_backlog FROM derm.v_sheet_number_ocr_backlog WHERE dump_folder = F;
    IF r_backlog <> 0 THEN RAISE EXCEPTION 'VERIFY 4a: backlog is %, expected 0', r_backlog; END IF;
    SELECT count(*) INTO r_targets FROM derm.fn_sheet_number_ocr_targets(10) WHERE dump_folder = F;
    IF r_targets <> 0 THEN RAISE EXCEPTION 'VERIFY 4b: targets still offered %, expected 0', r_targets; END IF;

    -- 5. Replace the scan at position 2 -> it comes back. FRED RULE: unless the pages change.
    UPDATE derm.address_row_map SET image_url = C WHERE dump_folder = F AND page = 2;
    IF derm.ticket_page_images(T) IS DISTINCT FROM ARRAY[A, C] THEN
      RAISE EXCEPTION 'VERIFY 5a: the image list did not follow the change';
    END IF;
    SELECT count(*) INTO r_backlog FROM derm.v_sheet_number_ocr_backlog WHERE dump_folder = F;
    IF r_backlog <> 1 THEN RAISE EXCEPTION 'VERIFY 5b: a replaced scan did not re-arm the page (backlog %)', r_backlog; END IF;

    -- 5c. MUTATION CONTROL: the OLD predicate is blind to a replaced scan too.
    SELECT count(*) INTO n_old
      FROM unnest(derm.ticket_page_images(T)) WITH ORDINALITY AS g(url, ord)
     WHERE NOT EXISTS (SELECT 1 FROM derm.address_sheet_scan_reads sr
                        WHERE sr.dump_folder = F AND sr.page = g.ord);
    IF n_old <> 0 THEN RAISE EXCEPTION 'VERIFY 5c: control - the OLD predicate reported %, expected 0', n_old; END IF;

    -- 6. The attempt bound stops the error path, and the row stays VISIBLE rather than dropped.
    PERFORM derm.fn_sheet_number_ocr_targets(10);
    PERFORM derm.fn_sheet_number_ocr_targets(10);
    PERFORM derm.fn_sheet_number_ocr_targets(10);
    SELECT attempts INTO n FROM derm.sheet_number_ocr_attempts
     WHERE dump_folder = F AND page = 2 AND image_url = C;
    IF n <> 3 THEN RAISE EXCEPTION 'VERIFY 6a: attempts is %, expected 3', n; END IF;
    SELECT count(*) INTO r_targets FROM derm.fn_sheet_number_ocr_targets(10) WHERE dump_folder = F;
    IF r_targets <> 0 THEN RAISE EXCEPTION 'VERIFY 6b: targets still offered % after 3 attempts', r_targets; END IF;
    SELECT count(*) INTO r_backlog FROM derm.v_sheet_number_ocr_backlog WHERE dump_folder = F;
    IF r_backlog <> 1 THEN RAISE EXCEPTION 'VERIFY 6c: the exhausted page vanished from the backlog - it must stay visible'; END IF;

    -- 7. Replacing the image re-arms the budget, because image_url is in the ledger key.
    UPDATE derm.address_row_map SET image_url = D WHERE dump_folder = F AND page = 2;
    SELECT count(*) INTO r_targets FROM derm.fn_sheet_number_ocr_targets(10) WHERE dump_folder = F;
    IF r_targets <> 1 THEN RAISE EXCEPTION 'VERIFY 7: a replaced scan did not re-arm the attempt budget (offered %)', r_targets; END IF;

    -- 8. The upload gate sees the work.
    IF NOT derm.fn_sheet_number_backlog_exists() THEN
      RAISE EXCEPTION 'VERIFY 8: the trigger gate reports no backlog while the fixture has one';
    END IF;

    RAISE EXCEPTION 'ZZ_OCR_FIXTURE_ROLLBACK';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'ZZ_OCR_FIXTURE_ROLLBACK' THEN RAISE; END IF;
  END;

  -- 9. The fixture left nothing behind.
  SELECT count(*) INTO n FROM derm.address_row_map WHERE dump_folder = 'ticket-ZZOCR';
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 9a: % fixture card(s) survived', n; END IF;
  SELECT count(*) INTO n FROM derm.sheet_number_ocr_attempts WHERE dump_folder = 'ticket-ZZOCR';
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 9b: % fixture attempt row(s) survived', n; END IF;
  SELECT count(*) INTO n FROM derm.address_sheet_scan_reads WHERE dump_folder = 'ticket-ZZOCR';
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 9c: % fixture read(s) survived', n; END IF;

  -- 10. Real post-state: nothing in scope is silently pending, and the out-of-scope gap is
  --     REPORTED. 10b is the control: without it, a view filtering everything would pass 10a.
  SELECT count(*) INTO n FROM derm.v_sheet_number_ocr_backlog WHERE scope = 'in_scope' AND n_pages > 1;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 10a: % in-scope page(s) unexpectedly pending', n; END IF;
  SELECT count(*) INTO n FROM derm.v_sheet_number_ocr_backlog WHERE scope = 'out_of_scope' AND n_pages > 1;
  IF n = 0 THEN
    RAISE EXCEPTION 'VERIFY 10b: control - the out-of-scope gap reports 0, so the view filters everything and 10a proves nothing';
  END IF;

  RAISE NOTICE 'VERIFY ok: read-once-per-page proven, replacement re-arms, attempts bound the error path, % out-of-scope page(s) reported', n;
END $do$;

COMMIT;
