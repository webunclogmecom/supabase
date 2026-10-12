-- 2026-10-12_1315 derm.fn_stamp_open_sheets: leave out a sheet whose clients are all test or fixture clients
--
-- THE ASK
--   Audit 2026-10-12, finding stamp-sheets-3 (confirmed by its verifier): "a 112-YA test sheet left open would land in
--   the real post that tags Diego and Serena". Since 2026-10-12 the real 11 AM Stamp Studio post starts with
--   <@U0AL9JZ4V7C> <@U0BKM57UPSS> (Fred, 2026-10-12: tag Diego and Serena), and the Slack guide's rule 10 says a test
--   must never ping them. A test sheet has been listed before: the 2026-10-05 [TEST] post showed
--   "Manifest 111113 · dumped Sep 15 · 1 of 1 stamped" (112-YA, manifest 1941).
--   The critic's ranking, item 6: "exclude test clients with the existing fn_is_non_customer, not a new predicate".
--   Integrator decision D4: exclude test/fixture clients in derm.fn_stamp_open_sheets via
--   public.fn_is_non_customer(..., ARRAY['test','fixture']).
--
-- WHAT CHANGES
--   One CROSS JOIN LATERAL and one predicate; every other byte of the body is the live pg_get_functiondef text (its
--   md5 is asserted before the replace, so a body changed since this file was written aborts it; diff in the bundle's
--   tests/derm_fn_stamp_open_sheets.diff).
--   A sheet leaves the list only when it names at least one client AND every client it names is a test or fixture
--   client. The clients a sheet names: each live manifest under its number (public.derm_manifests.client_id, the
--   coalesce(white, yellow) + deleted_at rule of derm.v_stamp_sheets) and each card matched to a client or carrying a
--   manual code (derm.address_row_map). A manifest with no client, and a card known only by its manual code, count as
--   real clients (fn_is_non_customer(NULL) is false), and so does one real card, so this rule can never hide a real
--   sheet. (0 cards carry a manual code today.)
--   NOT CHANGED: derm.v_stamp_sheets, so the Stamp Studio app still lists a test sheet; only the Slack post leaves it
--   out. Whether the Studio should hide them too is Fred's call (open question in the audit). The function's one
--   caller is the edge function stamp-sheets-reminder (the cron wrapper stopped reading it in 2026-10-12_1310).
--
-- MEASURED 2026-10-12 13:10 ET: 154 sheets, 2 open (837868 names 7 clients, 838133 names client 378), neither
--   test-only, so tomorrow's post is unchanged. Test-only sheets today: 111111 and 111112 (112-YA), both completed.
--
-- VERIFY (below):
--   V1 the result is an array.
--   V2 the result is exactly the open sheets minus the test-only ones, the test-only set computed a second way
--      (bool_and over public.v_non_customer_clients, not the function): no real sheet lost, no test sheet kept.
--   V3 MUTATION CONTROLS, always rolled back: on the listed sheet naming the most clients, none of them registered in
--      any kind (so the insert cannot hit the client_id unique index) and no manifest without a client, register all
--      but one as test clients -> still listed (the rule is "all", not "any"); register the last one -> it leaves the
--      list and every other listed sheet stays, except one whose named clients are then ALL test clients too (each in
--      the target's set or already a test / fixture client), which correctly leaves with it; no sheet appears. Registry
--      rows use negative ids and are asserted gone afterwards. Skipped with a NOTICE only if no listed sheet qualifies
--      (V5 and V6 still run).
--   V4 grants: EXECUTE for service_role only, none for PUBLIC, anon or authenticated (REVOKEd by name above).
--   V5 POSITIVE CONTROL THAT DOES NOT DEPEND ON WHAT IS OPEN TODAY: a pg_temp copy of the NEW body with only
--      "not s.completed" switched off (built from pg_proc.prosrc, the replace asserted to hit) must return every Studio
--      sheet except the test-only ones, computed the second way over all sheets, and that test-only set must not be
--      empty (today 111111, 111112). So on a day with 0 open sheets the predicate is still exercised.
--   V6 FIXTURE COPY, NO REAL ROW WRITTEN: a pg_temp copy of the NEW body whose three tables (derm.v_stamp_sheets,
--      public.derm_manifests, derm.address_row_map, each replace asserted to hit once) are pg_temp fixture tables, run
--      on 12 made-up sheets with real registry clients (a test, a fixture, a dump_site and an unregistered client, read
--      from public.v_non_customer_clients). It must list exactly: a sheet naming no client, one whose only manifest is
--      deleted, a real manifest beside a test card, a test manifest beside a manual-code card, a manifest with no
--      client beside a test card, one test and one real manifest, a dump_site client; and leave out: test + fixture, a
--      yellow-number test manifest, a fixture-only sheet, a test manifest beside an unmatched card, a completed sheet.
--      This is what kills the mutants today's data cannot (manifests ignored, manual-code cards ignored, "named > 0"
--      dropped, deleted manifests counted, any registry kind, test kind only). The dump_site case is skipped with a
--      NOTICE only if no client is registered as dump_site alone.
--
-- Rule 8: no table changes; nothing to audit. V3 writes public.non_customer_clients (audited) inside a sub-block that
--   always raises and rolls back, so neither the rows nor their audit rows survive. V6 writes only pg_temp tables
--   (ON COMMIT DROP, and dropped at the end of V6).
-- Grants: CREATE OR REPLACE keeps the ACL (postgres, service_role); REVOKE from PUBLIC, anon, authenticated by name.
-- Locks: a function replace takes no lock an app reader waits on, and no app reads this function. lock_timeout 3s.
--   VERIFY reads derm.v_stamp_sheets about 5 times (a few seconds); it changes no view.
-- ROLLBACK: re-apply the live body saved in the bundle (work/live_derm_fn_stamp_open_sheets__.sql, md5 below).

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$
BEGIN
  IF md5(pg_get_functiondef('derm.fn_stamp_open_sheets()'::regprocedure)) <> 'cc4f77efd6577de3931e6c7044bf0912' THEN
    RAISE EXCEPTION 'derm.fn_stamp_open_sheets changed since this migration was written: copy the new live body';
  END IF;
END $pin$;

CREATE OR REPLACE FUNCTION derm.fn_stamp_open_sheets()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'manifest', s.white_manifest_number,
           'service_date', s.service_date,
           'dump_date', s.dump_date,
           'placed', s.placed_rows,
           'total', s.total_rows,
           'pages', s.page_count,
           'status', case when s.placed_rows > 0 then 'In progress' else 'Not started' end,
           'days_waiting', (now() at time zone 'America/New_York')::date - coalesce(s.dump_date, s.service_date))
         order by coalesce(s.dump_date, s.service_date) nulls last, s.white_manifest_number), '[]'::jsonb)
    from derm.v_stamp_sheets s
    -- 2026-10-12: the clients the sheet names (its live manifests and its cards) and how many of them are test or
    -- fixture clients (public.fn_is_non_customer, the shared registry). A manifest with no client, or a card known only
    -- by its manual code, counts as a real client, so this can never hide a real sheet.
    cross join lateral (
      select count(*) as named,
             count(*) filter (where public.fn_is_non_customer(c.client_id, array['test', 'fixture'])) as test
        from (select m.client_id from public.derm_manifests m
               where coalesce(m.white_manifest_number, m.yellow_ticket_number) = s.white_manifest_number
                 and m.deleted_at is null
              union all
              select r.matched_client_id from derm.address_row_map r
               where r.white_manifest_number = s.white_manifest_number
                 and (r.matched_client_id is not null or r.manual_code is not null)) c) k
   where not s.completed
     -- a sheet whose clients are ALL test or fixture clients is not posted: the real post tags Diego and Serena
     and not (k.named > 0 and k.test = k.named);
$function$;

REVOKE ALL ON FUNCTION derm.fn_stamp_open_sheets() FROM PUBLIC, anon, authenticated;

DO $verify$
DECLARE
  v jsonb := derm.fn_stamp_open_sheets();
  got text[]; want text[]; tgt text; tgt_clients bigint[]; others text[]; after_some text[]; after_all text[];
  src text; all_src text; got_all text[]; want_all text[]; test_only_all text[];
  listed_named jsonb; fx_src text; fx_got text[]; fx_want text[];
  c_test bigint; c_fixture bigint; c_dump bigint; c_real bigint;
BEGIN
  -- V1
  IF jsonb_typeof(v) <> 'array' THEN RAISE EXCEPTION 'VERIFY V1: fn_stamp_open_sheets is not an array'; END IF;

  -- V2 and V5 share the second calculation: the test-only sheets of the whole Studio list
  WITH named AS (
    SELECT s.white_manifest_number AS wm, m.client_id
      FROM derm.v_stamp_sheets s
      JOIN public.derm_manifests m ON coalesce(m.white_manifest_number, m.yellow_ticket_number) = s.white_manifest_number
                                  AND m.deleted_at IS NULL
    UNION ALL
    SELECT s.white_manifest_number, r.matched_client_id
      FROM derm.v_stamp_sheets s
      JOIN derm.address_row_map r ON r.white_manifest_number = s.white_manifest_number
                                 AND (r.matched_client_id IS NOT NULL OR r.manual_code IS NOT NULL)
  )
  SELECT coalesce(array_agg(wm ORDER BY wm), '{}') INTO test_only_all
    FROM (SELECT wm FROM named GROUP BY wm
          HAVING bool_and(client_id IS NOT NULL AND client_id IN
                          (SELECT client_id FROM public.v_non_customer_clients WHERE kind IN ('test', 'fixture')))) t;

  -- V2
  SELECT coalesce(array_agg(e->>'manifest' ORDER BY e->>'manifest'), '{}') INTO got FROM jsonb_array_elements(v) e;
  SELECT coalesce(array_agg(s.white_manifest_number ORDER BY s.white_manifest_number), '{}') INTO want
    FROM derm.v_stamp_sheets s
   WHERE NOT s.completed AND NOT s.white_manifest_number = ANY (test_only_all);
  IF got IS DISTINCT FROM want THEN
    RAISE EXCEPTION 'VERIFY V2: the reminder lists % but the open real sheets are %', got, want;
  END IF;

  -- V3: mutation controls on a listed sheet whose named clients are all real and unregistered, always rolled back.
  -- The clients each LISTED sheet names (its live manifests and its matched or manual-code cards), kept for V3b.
  SELECT coalesce(jsonb_agg(jsonb_build_object('wm', n.wm, 'c', n.client_id)), '[]'::jsonb) INTO listed_named
    FROM (SELECT e->>'manifest' AS wm, m.client_id
            FROM jsonb_array_elements(v) e
            JOIN public.derm_manifests m ON coalesce(m.white_manifest_number, m.yellow_ticket_number) = e->>'manifest'
                                        AND m.deleted_at IS NULL
          UNION ALL
          SELECT e->>'manifest', r.matched_client_id
            FROM jsonb_array_elements(v) e
            JOIN derm.address_row_map r ON r.white_manifest_number = e->>'manifest'
                                       AND (r.matched_client_id IS NOT NULL OR r.manual_code IS NOT NULL)) n;
  SELECT n.wm, array_agg(DISTINCT n.c ORDER BY n.c) INTO tgt, tgt_clients
    FROM jsonb_to_recordset(listed_named) AS n(wm text, c bigint)
   GROUP BY n.wm
  HAVING NOT bool_or(n.c IS NULL OR EXISTS (SELECT 1 FROM public.v_non_customer_clients x WHERE x.client_id = n.c))
   ORDER BY count(DISTINCT n.c) DESC, n.wm
   LIMIT 1;
  IF tgt IS NULL THEN
    RAISE NOTICE 'VERIFY V3 skipped: no listed sheet names only unregistered real clients today (V5 and V6 still run)';
  ELSE
    -- the listed sheets that must STAY once all of tgt's clients are test clients: every one except tgt and except a
    -- sheet whose named clients would then all be test clients (in tgt_clients, or already test / fixture), which
    -- correctly leaves with it (a sheet naming no client always stays)
    SELECT coalesce(array_agg(g ORDER BY g), '{}') INTO others
      FROM unnest(got) AS g
     WHERE g <> tgt
       AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(listed_named) AS n(wm text, c bigint)
                        WHERE n.wm = g
                       HAVING bool_and(n.c IS NOT NULL
                                       AND (n.c = ANY (tgt_clients)
                                            OR n.c IN (SELECT client_id FROM public.v_non_customer_clients
                                                        WHERE kind IN ('test', 'fixture')))));
    BEGIN
      IF cardinality(tgt_clients) > 1 THEN
        INSERT INTO public.non_customer_clients (id, client_id, kind, reason, added_by)
        SELECT -o, c, 'test', '[TEST] VERIFY mutation control, rolled back', 'migration 2026-10-12_1315'
          FROM unnest(tgt_clients[1:cardinality(tgt_clients) - 1]) WITH ORDINALITY AS u(c, o);
        SELECT coalesce(array_agg(e->>'manifest'), '{}') INTO after_some FROM jsonb_array_elements(derm.fn_stamp_open_sheets()) e;
        IF NOT tgt = ANY (after_some) THEN
          RAISE EXCEPTION 'VERIFY V3a: sheet % left the list when only some of its clients are test clients', tgt;
        END IF;
      END IF;
      INSERT INTO public.non_customer_clients (id, client_id, kind, reason, added_by)
      VALUES (-1000, tgt_clients[cardinality(tgt_clients)], 'test', '[TEST] VERIFY mutation control, rolled back',
              'migration 2026-10-12_1315');
      SELECT coalesce(array_agg(e->>'manifest'), '{}') INTO after_all FROM jsonb_array_elements(derm.fn_stamp_open_sheets()) e;
      IF tgt = ANY (after_all) THEN
        RAISE EXCEPTION 'VERIFY V3b: sheet % is still listed with every client registered as a test client', tgt;
      END IF;
      IF NOT others <@ after_all THEN
        RAISE EXCEPTION 'VERIFY V3b: another sheet left the list too: want kept %, after %', others, after_all;
      END IF;
      IF NOT after_all <@ got THEN
        RAISE EXCEPTION 'VERIFY V3b: a sheet appeared: before %, after %', got, after_all;
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'UCM01', MESSAGE = 'roll back the mutation control';
    EXCEPTION WHEN SQLSTATE 'UCM01' THEN NULL;
    END;
    IF EXISTS (SELECT 1 FROM public.non_customer_clients WHERE id < 0) THEN
      RAISE EXCEPTION 'VERIFY V3: a mutation-control row survived';
    END IF;
    RAISE NOTICE 'VERIFY V3 ran on sheet % (% clients)', tgt, cardinality(tgt_clients);
  END IF;

  -- V4
  IF has_function_privilege('anon', 'derm.fn_stamp_open_sheets()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'derm.fn_stamp_open_sheets()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'derm.fn_stamp_open_sheets()', 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
                 WHERE p.oid = 'derm.fn_stamp_open_sheets()'::regprocedure AND a.grantee = 0) THEN
    RAISE EXCEPTION 'VERIFY V4: fn_stamp_open_sheets grants changed (want service_role only)';
  END IF;

  -- V5: the new predicate over EVERY Studio sheet (a copy of the new body with "not completed" switched off)
  SELECT prosrc INTO src FROM pg_proc WHERE oid = 'derm.fn_stamp_open_sheets()'::regprocedure;
  all_src := replace(src, 'where not s.completed', 'where true');
  IF (length(src) - length(all_src)) <> length('where not s.completed') - length('where true') THEN
    RAISE EXCEPTION 'VERIFY V5: "where not s.completed" must appear exactly once in the new body';
  END IF;
  EXECUTE format('CREATE OR REPLACE FUNCTION pg_temp.verify_all_sheets() RETURNS jsonb LANGUAGE sql STABLE '
                 'SET search_path TO derm, public AS %L', all_src);
  SELECT coalesce(array_agg(e->>'manifest' ORDER BY e->>'manifest'), '{}') INTO got_all
    FROM jsonb_array_elements(pg_temp.verify_all_sheets()) e;
  DROP FUNCTION pg_temp.verify_all_sheets();
  SELECT coalesce(array_agg(s.white_manifest_number ORDER BY s.white_manifest_number), '{}') INTO want_all
    FROM derm.v_stamp_sheets s WHERE NOT s.white_manifest_number = ANY (test_only_all);
  IF cardinality(test_only_all) = 0 THEN
    RAISE EXCEPTION 'VERIFY V5: no test-only sheet exists in the Studio list, so the rule is untested; pick another control';
  END IF;
  IF got_all IS DISTINCT FROM want_all THEN
    RAISE EXCEPTION 'VERIFY V5: over every sheet the rule keeps % but should keep % (test-only: %)', got_all, want_all, test_only_all;
  END IF;

  -- V6: the new body on made-up sheets (pg_temp tables only; real registry clients, read here)
  SELECT min(x.client_id) INTO c_test FROM public.v_non_customer_clients x WHERE x.kind = 'test';
  SELECT min(x.client_id) INTO c_fixture FROM public.v_non_customer_clients x WHERE x.kind = 'fixture'
     AND NOT EXISTS (SELECT 1 FROM public.v_non_customer_clients y WHERE y.client_id = x.client_id AND y.kind <> 'fixture');
  SELECT min(x.client_id) INTO c_dump FROM public.v_non_customer_clients x WHERE x.kind = 'dump_site'
     AND NOT EXISTS (SELECT 1 FROM public.v_non_customer_clients y WHERE y.client_id = x.client_id AND y.kind <> 'dump_site');
  SELECT min(c.id) INTO c_real FROM public.clients c
   WHERE NOT EXISTS (SELECT 1 FROM public.v_non_customer_clients x WHERE x.client_id = c.id);
  IF c_test IS NULL OR c_fixture IS NULL OR c_real IS NULL THEN
    RAISE EXCEPTION 'VERIFY V6: need a test client, a fixture-only client and an unregistered client (got %, %, %)',
      c_test, c_fixture, c_real;
  END IF;
  CREATE TEMP TABLE verify_fx_sheets (white_manifest_number text, service_date date, dump_date date, placed_rows bigint,
                                      total_rows bigint, page_count bigint, completed boolean) ON COMMIT DROP;
  CREATE TEMP TABLE verify_fx_manifests (white_manifest_number text, yellow_ticket_number text, client_id bigint,
                                         deleted_at timestamptz) ON COMMIT DROP;
  CREATE TEMP TABLE verify_fx_rows (white_manifest_number text, matched_client_id bigint, manual_code text) ON COMMIT DROP;
  INSERT INTO pg_temp.verify_fx_sheets (white_manifest_number, service_date, dump_date, placed_rows, total_rows,
                                        page_count, completed)
  SELECT wm, date '2026-10-01', date '2026-10-02', 0, 1, 1, wm = 'FX12-DONE'
    FROM unnest(ARRAY['FX01-NONE', 'FX02-DELETED', 'FX03-REALMAN', 'FX04-MANUAL', 'FX05-ALLTEST', 'FX06-NULLMAN',
                      'FX07-MIX', 'FX08-YELLOW', 'FX09-DUMPSITE', 'FX10-FIXTURE', 'FX11-UNMATCHED', 'FX12-DONE']) AS wm;
  INSERT INTO pg_temp.verify_fx_manifests (white_manifest_number, yellow_ticket_number, client_id, deleted_at) VALUES
    ('FX02-DELETED', NULL, c_test, now()),
    ('FX03-REALMAN', NULL, c_real, NULL),
    ('FX04-MANUAL', NULL, c_test, NULL),
    ('FX05-ALLTEST', NULL, c_test, NULL),
    ('FX06-NULLMAN', NULL, NULL, NULL),
    ('FX07-MIX', NULL, c_test, NULL), ('FX07-MIX', NULL, c_real, NULL),
    (NULL, 'FX08-YELLOW', c_test, NULL),
    ('FX09-DUMPSITE', NULL, c_dump, NULL),
    ('FX10-FIXTURE', NULL, c_fixture, NULL),
    ('FX11-UNMATCHED', NULL, c_test, NULL),
    ('FX12-DONE', NULL, c_real, NULL);
  INSERT INTO pg_temp.verify_fx_rows (white_manifest_number, matched_client_id, manual_code) VALUES
    ('FX03-REALMAN', c_test, NULL),
    ('FX04-MANUAL', NULL, 'VERIFY-MANUAL'),
    ('FX05-ALLTEST', c_fixture, NULL),
    ('FX06-NULLMAN', c_test, NULL),
    ('FX11-UNMATCHED', NULL, NULL);
  fx_src := replace(replace(replace(src,
              'derm.v_stamp_sheets', 'pg_temp.verify_fx_sheets'),
              'public.derm_manifests', 'pg_temp.verify_fx_manifests'),
              'derm.address_row_map', 'pg_temp.verify_fx_rows');
  IF (length(src) - length(replace(src, 'derm.v_stamp_sheets', ''))) <> length('derm.v_stamp_sheets')
     OR (length(src) - length(replace(src, 'public.derm_manifests', ''))) <> length('public.derm_manifests')
     OR (length(src) - length(replace(src, 'derm.address_row_map', ''))) <> length('derm.address_row_map') THEN
    RAISE EXCEPTION 'VERIFY V6: each of the three tables must appear exactly once in the new body';
  END IF;
  EXECUTE format('CREATE OR REPLACE FUNCTION pg_temp.verify_fx_open_sheets() RETURNS jsonb LANGUAGE sql STABLE '
                 'SET search_path TO derm, public AS %L', fx_src);
  SELECT coalesce(array_agg(e->>'manifest' ORDER BY e->>'manifest'), '{}') INTO fx_got
    FROM jsonb_array_elements(pg_temp.verify_fx_open_sheets()) e;
  DROP FUNCTION pg_temp.verify_fx_open_sheets();
  DROP TABLE pg_temp.verify_fx_sheets, pg_temp.verify_fx_manifests, pg_temp.verify_fx_rows;
  fx_want := ARRAY['FX01-NONE', 'FX02-DELETED', 'FX03-REALMAN', 'FX04-MANUAL', 'FX06-NULLMAN', 'FX07-MIX']
             || CASE WHEN c_dump IS NULL THEN '{}'::text[] ELSE ARRAY['FX09-DUMPSITE'] END;
  IF c_dump IS NULL THEN
    -- no dump_site client: FX09 has a NULL client and is listed as a real one, which tests nothing new
    fx_got := array_remove(fx_got, 'FX09-DUMPSITE');
    RAISE NOTICE 'VERIFY V6: no client is registered as dump_site alone, the any-kind case is skipped';
  END IF;
  IF fx_got IS DISTINCT FROM fx_want THEN
    RAISE EXCEPTION 'VERIFY V6: on the fixture sheets the rule lists % but should list %', fx_got, fx_want;
  END IF;

  RAISE NOTICE 'VERIFY ok: % open sheets listed: %; over all % sheets the rule leaves out the test-only %; V6 lists %',
    cardinality(got), got, cardinality(want_all) + cardinality(test_only_all), test_only_all, fx_got;
END $verify$;

COMMIT;
