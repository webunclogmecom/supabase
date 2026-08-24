-- ============================================================================
-- 2026-08-24_1520  Schedule the row-level OCR, with an attempt ledger so it cannot
--                  re-ask forever
-- ============================================================================
--
-- Fred: "do the row OCR sweep".
--
-- ---------------------------------------------------------------------------
-- PART 0.  WHY THIS EXISTS
-- ---------------------------------------------------------------------------
--
-- `ocr-address-sheet-rows` has been deployed and working for weeks and **nothing has ever called
-- it**: no cron, no DB function, no app path. `derm.address_sheet_row_reads` only ever filled when
-- somebody invoked it by hand. The sheet-NUMBER OCR is scheduled (`sheet-number-ocr-sweep`, */10,
-- via `public.fn_request_sheet_number_ocr()`); the ROW reader was not.
--
-- That is what left ticket 833395 unresolved. Its 3 clients are a SUBSET of sheet 1093's 8, so it
-- can only resolve through the superset arm of `derm.fn_resolve_generated_sheet_for_ticket`, and
-- that arm requires `derm.fn_sheet_rows_all_confirmed`, which reads row reads. Exact client-set
-- equality needs none, which is why most sheets resolved and this one sat.
--
-- ---------------------------------------------------------------------------
-- PART 1.  🛑 READ-PRESENCE IS THE WRONG PREDICATE HERE, AND IT WOULD BURN VISION CALLS FOREVER
-- ---------------------------------------------------------------------------
--
-- `derm.fn_sheet_number_ocr_targets` excludes a page that already has a scan read. Copying that
-- shape for rows is a trap, because the two handlers behave differently on a bad page:
--
--   ocr-address-sheet-number   writes a row even at low confidence, so the page leaves the queue
--   ocr-address-sheet-rows     `if (payload.length) { ... }` at index.ts:205 -- a page that parses
--                              to ZERO rows writes NOTHING
--
-- So "target pages with no row read" re-targets an unparseable page on every cycle, for ever, at
-- one vision call each. Nothing would report it: the cron would say `succeeded` every ten minutes.
--
-- ⇒ `derm.row_ocr_attempts` records that we ASKED, not that we got an answer. Three attempts and
-- the ticket is left alone.
--
-- ⚠ AND THE BUDGET MUST RE-ARM WHEN THE PAPER CHANGES, or a page that failed while its scan was
-- bad could never be read again after a better scan is uploaded. The ledger stores a fingerprint of
-- the ticket's image list; a different fingerprint resets the count. That is the same
-- stored-what-we-saw-then idea as `sync.source_field_shadow` and the stamp witness.
--
-- ---------------------------------------------------------------------------
-- PART 2.  SCOPE, AND WHY IT IS DELIBERATELY NARROW
-- ---------------------------------------------------------------------------
--
-- Measured now: **3 tickets need row reads** (828604, 830714, 833530), 3 pages between them. At one
-- ticket per cycle the queue drains in 30 minutes and then sits empty. This is not a backfill.
--
-- The target predicate mirrors `fn_sheet_number_ocr_targets`' `placeable` exactly, and for the same
-- two reasons recorded there:
--   * a folder with NO unplaced stamp can never be auto-placed again, so reading it changes no
--     decision;
--   * only `ticket-%` folders, because the historical `window<N>-sheet<M>` batch set has zero
--     generated-sheet links, so a read of one can never be used.
--
-- ⚠ ONE TICKET PER CYCLE, not one image. `ocr-address-sheet-rows` takes `{ticket}` and processes
-- EVERY page of it, so a 3-page ticket is 3 vision calls in one request. The number sweep's
-- `{limit: 2}` counts IMAGES; this cap counts TICKETS and is therefore the tighter of the two.
--
-- ADR 010 rule 8 (audit): `derm.row_ocr_attempts` OPTS OUT. It is a machine-written scheduling
-- ledger with no human-editable field, no client data, and no compliance meaning: it records that a
-- request was sent. Losing it costs at most three repeated vision calls. It touches nothing in
-- `customer.*`, billing, DERM compliance or webhook secrets, so the hard rule does not apply.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 3.  The attempt ledger
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS derm.row_ocr_attempts (
  ticket            text        PRIMARY KEY,
  attempts          integer     NOT NULL DEFAULT 0,
  image_fingerprint text,
  first_attempt_at  timestamptz NOT NULL DEFAULT now(),
  last_attempt_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT row_ocr_attempts_attempts_chk CHECK (attempts >= 0 AND attempts <= 100)
);

COMMENT ON TABLE derm.row_ocr_attempts IS
  'Scheduling ledger for ocr-address-sheet-rows: records that a read was REQUESTED, not that one '
  'was returned. The handler writes nothing for a page that parses to zero rows, so a predicate '
  'keyed on "does a read exist" would re-ask for ever. image_fingerprint is the ticket''s image '
  'list, so replacing a bad scan re-arms the budget. '
  'See docs/migrations/2026-08-24_1520_row_ocr_sweep.sql.';

-- Supabase's ALTER DEFAULT PRIVILEGES hands out grants nobody wrote, so revoke explicitly.
REVOKE ALL ON derm.row_ocr_attempts FROM PUBLIC;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON derm.row_ocr_attempts FROM anon';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'REVOKE ALL ON derm.row_ocr_attempts FROM authenticated';
  END IF;
END $$;
GRANT SELECT ON derm.row_ocr_attempts TO service_role;

-- ---------------------------------------------------------------------------
-- PART 4.  Target selection, kept in SQL so it is testable in a transaction
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION derm.fn_sheet_row_ocr_targets(p_limit integer DEFAULT 1)
 RETURNS TABLE(dump_folder text, ticket text, pages integer, attempts integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  with placeable as (
    -- identical reasoning to derm.fn_sheet_number_ocr_targets: a fully-placed sheet can never be
    -- auto-placed again, and non-`ticket-%` folders have no generated-sheet link at all.
    select distinct r.dump_folder, r.white_manifest_number as ticket
      from derm.address_row_map r
     where r.white_manifest_number is not null
       and r.stamp_placed_at is null
       and r.dump_folder like 'ticket-%'
  ), imgs as (
    select p.dump_folder, p.ticket,
           derm.ticket_page_images(p.ticket) as urls
      from placeable p
  ), pg as (
    select i.dump_folder, i.ticket,
           md5(coalesce(array_to_string(i.urls, '|'), '')) as fingerprint,
           g.ord::int as page, g.url
      from imgs i
      cross join lateral unnest(i.urls) with ordinality as g(url, ord)
     where g.url is not null and g.url <> 'pending'
  )
  select pg.dump_folder, pg.ticket,
         count(*) filter (
           where not exists (select 1 from derm.address_sheet_row_reads rr
                              where rr.dump_folder = pg.dump_folder and rr.page = pg.page)
         )::int as pages,
         coalesce(max(a.attempts), 0)::int as attempts
    from pg
    left join derm.row_ocr_attempts a
      on a.ticket = pg.ticket and a.image_fingerprint = pg.fingerprint
   group by pg.dump_folder, pg.ticket
  having count(*) filter (
           where not exists (select 1 from derm.address_sheet_row_reads rr
                              where rr.dump_folder = pg.dump_folder and rr.page = pg.page)
         ) > 0
     -- the budget. A different fingerprint means new paper and the LEFT JOIN misses, so
     -- coalesce(...,0) re-arms it automatically.
     and coalesce(max(a.attempts), 0) < 3
   order by coalesce(max(a.attempts), 0), pg.ticket
   limit greatest(1, least(coalesce(p_limit, 1), 5));
$function$;

-- ---------------------------------------------------------------------------
-- PART 5.  The sweep. Mirrors public.fn_request_sheet_number_ocr line for line.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_request_sheet_row_ocr()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text; t record;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping sheet-row OCR sweep';
    return;
  end if;

  for t in select * from derm.fn_sheet_row_ocr_targets(1) loop
    -- Record the ATTEMPT before asking. The handler writes nothing for a page that parses to zero
    -- rows, so if this were recorded on success the ticket would be re-asked every cycle for ever.
    insert into derm.row_ocr_attempts (ticket, attempts, image_fingerprint)
    values (t.ticket, 1, md5(coalesce(array_to_string(derm.ticket_page_images(t.ticket), '|'), '')))
    on conflict (ticket) do update
       set attempts = case
                        when derm.row_ocr_attempts.image_fingerprint
                             is distinct from excluded.image_fingerprint
                        then 1                                   -- new paper, fresh budget
                        else derm.row_ocr_attempts.attempts + 1
                      end,
           image_fingerprint = excluded.image_fingerprint,
           last_attempt_at = now();

    perform net.http_post(
      url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/ocr-address-sheet-rows',
      headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
      body := jsonb_build_object('ticket', t.ticket),
      timeout_milliseconds := 120000);
  end loop;
end; $function$;

REVOKE ALL ON FUNCTION public.fn_request_sheet_row_ocr() FROM PUBLIC;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.fn_request_sheet_row_ocr() FROM anon';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.fn_request_sheet_row_ocr() FROM authenticated';
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.fn_request_sheet_row_ocr() TO service_role;

REVOKE ALL ON FUNCTION derm.fn_sheet_row_ocr_targets(integer) FROM PUBLIC;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON FUNCTION derm.fn_sheet_row_ocr_targets(integer) FROM anon';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'REVOKE ALL ON FUNCTION derm.fn_sheet_row_ocr_targets(integer) FROM authenticated';
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION derm.fn_sheet_row_ocr_targets(integer) TO service_role;

-- Offset from sheet-number-ocr-sweep (*/10, minutes 0,10,20...) so the two never contend for the
-- same vision quota in the same minute.
SELECT cron.schedule('sheet-row-ocr-sweep', '5-55/10 * * * *',
                     'SELECT public.fn_request_sheet_row_ocr()');

-- ---------------------------------------------------------------------------
-- PART 6.  VERIFY
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_n int; v_txt text; v_att int;
BEGIN
  ------------------------------------------------------------------------
  -- 6.1  The queue is the measured backlog, not everything. If this returned the
  --      whole fleet the predicate is wrong and the cost estimate with it.
  ------------------------------------------------------------------------
  SELECT count(*), string_agg(ticket, ' ' ORDER BY ticket)
    INTO v_n, v_txt FROM derm.fn_sheet_row_ocr_targets(50);
  IF v_n <> 3 OR v_txt IS DISTINCT FROM '828604 830714 833530' THEN
    RAISE EXCEPTION 'expected the 3 measured tickets, got % (%)', v_n, coalesce(v_txt, 'NULL');
  END IF;

  -- and the cap must actually cap
  SELECT count(*) INTO v_n FROM derm.fn_sheet_row_ocr_targets(1);
  IF v_n <> 1 THEN RAISE EXCEPTION 'the per-cycle cap returned % tickets', v_n; END IF;

  ------------------------------------------------------------------------
  -- 6.2  CONTROL: a ticket that is already fully stamped must NOT be targeted.
  --      Without this the predicate could be returning everything with stamps.
  ------------------------------------------------------------------------
  IF EXISTS (SELECT 1 FROM derm.fn_sheet_row_ocr_targets(50) WHERE ticket = '833395') THEN
    RAISE EXCEPTION 'a fully-placed ticket is being targeted, so `placeable` is not applied';
  END IF;

  ------------------------------------------------------------------------
  -- 6.3  THE BUDGET. Burn three attempts on one ticket and it must leave the queue.
  --      This is the arm that stops an unparseable page costing a vision call for ever,
  --      and it is the whole reason for the ledger, so it gets a real test.
  ------------------------------------------------------------------------
  DECLARE v_before int; v_after int; v_rearmed int;
  BEGIN
    BEGIN
      SELECT count(*) INTO v_before FROM derm.fn_sheet_row_ocr_targets(50) WHERE ticket = '828604';

      INSERT INTO derm.row_ocr_attempts (ticket, attempts, image_fingerprint)
      VALUES ('828604', 3, md5(coalesce(array_to_string(derm.ticket_page_images('828604'), '|'), '')));

      SELECT count(*) INTO v_after FROM derm.fn_sheet_row_ocr_targets(50) WHERE ticket = '828604';

      -- new paper must re-arm the budget even though attempts is still 3
      UPDATE derm.row_ocr_attempts SET image_fingerprint = 'a-different-scan' WHERE ticket = '828604';
      SELECT count(*) INTO v_rearmed FROM derm.fn_sheet_row_ocr_targets(50) WHERE ticket = '828604';

      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;

    IF v_before <> 1 THEN RAISE EXCEPTION 'setup failed: 828604 was not queued to begin with'; END IF;
    IF v_after <> 0 THEN
      RAISE EXCEPTION 'CONTROL FAILED: a ticket at 3 attempts is still queued, so the budget does nothing';
    END IF;
    IF v_rearmed <> 1 THEN
      RAISE EXCEPTION 'CONTROL FAILED: a new image fingerprint did not re-arm the budget, so a bad scan is terminal';
    END IF;
    RAISE NOTICE 'CONTROL OK: 3 attempts removes a ticket from the queue, and new paper re-arms it';
  END;

  IF EXISTS (SELECT 1 FROM derm.row_ocr_attempts) THEN
    RAISE EXCEPTION 'the rolled-back control leaked an attempt row';
  END IF;

  ------------------------------------------------------------------------
  -- 6.4  The cron exists, is active, and is offset from the number sweep.
  ------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM cron.job
   WHERE jobname = 'sheet-row-ocr-sweep' AND active
     AND command = 'SELECT public.fn_request_sheet_row_ocr()';
  IF v_n <> 1 THEN RAISE EXCEPTION 'sheet-row-ocr-sweep is not scheduled and active'; END IF;

  SELECT schedule INTO v_txt FROM cron.job WHERE jobname = 'sheet-row-ocr-sweep';
  IF v_txt = (SELECT schedule FROM cron.job WHERE jobname = 'sheet-number-ocr-sweep') THEN
    RAISE EXCEPTION 'the row sweep shares a schedule with the number sweep';
  END IF;

  ------------------------------------------------------------------------
  -- 6.5  Nothing anon or authenticated can reach any of it.
  ------------------------------------------------------------------------
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    IF has_function_privilege('anon', 'public.fn_request_sheet_row_ocr()', 'EXECUTE')
       OR has_function_privilege('anon', 'derm.fn_sheet_row_ocr_targets(integer)', 'EXECUTE')
       OR has_table_privilege('anon', 'derm.row_ocr_attempts', 'SELECT') THEN
      RAISE EXCEPTION 'anon can reach the row-OCR sweep';
    END IF;
  END IF;
  IF has_function_privilege('authenticated', 'public.fn_request_sheet_row_ocr()', 'EXECUTE')
     OR has_table_privilege('authenticated', 'derm.row_ocr_attempts', 'INSERT') THEN
    RAISE EXCEPTION 'authenticated can reach the row-OCR sweep';
  END IF;

  RAISE NOTICE 'OK: 3 tickets queued, 1 per cycle at 5-55/10, budget 3 attempts per image set';
END $$;

COMMIT;
