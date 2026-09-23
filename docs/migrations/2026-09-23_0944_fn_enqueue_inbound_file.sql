-- 2026-09-23_0944_fn_enqueue_inbound_file.sql
--
-- WHY
-- ---
-- `sync` is NOT an exposed PostgREST schema (measured: public, graphql_public, customer, derm, ops,
-- client, hr). So supabase-js cannot reach sync.inbound_file_queue directly, and the fillout-inspection
-- edge function's enqueue step would fail at runtime with a schema-not-found rather than a compile
-- error. This adds the wrapper.
--
-- 🛑 A WRAPPER, NOT AN EXPOSURE. The tempting one-liner is to add `sync` to db_schema. That would
-- publish every sync table (outbound_queue, source_field_shadow, the Jobber observation tables) to
-- PostgREST in one move, to get at one queue. This estate already settled this shape: sync.outbound_queue
-- is reached through four `public.fn_outbound_*` wrappers for exactly this reason. Follow that.
--
-- SECURITY
-- --------
-- SECURITY DEFINER with a pinned search_path (the pinning is the hardening; SECDEF without it is the
-- footgun this repo documents). EXECUTE is granted to service_role ONLY. No app role can enqueue a
-- file fetch, because "go download this URL and put it in our storage" is a server-side capability:
-- handing it to `authenticated` would let any signed-in browser make our infrastructure fetch
-- arbitrary URLs.
--
-- ⚠ It does NOT validate that source_url is reachable or safe. The DRAINING cron is where a URL is
-- fetched, and that is where host allow-listing belongs. Recorded here so nobody assumes this
-- function sanitised anything.
--
-- RULE 8: the queue opts OUT of audit (machine-only plumbing, same as sync.outbound_queue). This
-- function inherits that and adds no trigger.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_enqueue_inbound_file(
  p_entity_type   TEXT,
  p_entity_id     BIGINT,
  p_source_system TEXT,
  p_role          TEXT,
  p_source_url    TEXT,
  p_target_bucket TEXT
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sync, public, pg_temp
AS $fn$
DECLARE
  v_id BIGINT;
BEGIN
  -- A replayed submission must be a no-op, not a second download. The unique constraint carries
  -- that; DO NOTHING plus the follow-up SELECT returns the existing id either way, so the caller
  -- cannot tell an insert from a replay and does not need to.
  INSERT INTO sync.inbound_file_queue
    (entity_type, entity_id, source_system, role, source_url, target_bucket)
  VALUES
    (p_entity_type, p_entity_id, p_source_system, p_role, p_source_url, p_target_bucket)
  ON CONFLICT (entity_type, entity_id, role, source_url) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT id INTO v_id
      FROM sync.inbound_file_queue
     WHERE entity_type = p_entity_type
       AND entity_id   = p_entity_id
       AND role        = p_role
       AND source_url  = p_source_url;
  END IF;

  RETURN v_id;
END
$fn$;

COMMENT ON FUNCTION public.fn_enqueue_inbound_file(TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT) IS
  'service_role-only wrapper so an edge function can enqueue a file fetch without sync being an '
  'exposed PostgREST schema. Idempotent on (entity_type, entity_id, role, source_url): a replayed '
  'webhook returns the existing queue id rather than queueing a second download.';

-- 🛑 Supabase default privileges make a new public function authenticated-EXECUTABLE. Revoke by
-- name, then assert, because a GRANT cannot remove what CREATE already handed out.
REVOKE ALL ON FUNCTION public.fn_enqueue_inbound_file(TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_enqueue_inbound_file(TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT)
  TO service_role;

DO $verify$
DECLARE
  v_id1 BIGINT;
  v_id2 BIGINT;
  v_rows INTEGER;
BEGIN
  -- 1. Privilege, read off the catalogue rather than off the GRANT statements above.
  IF has_function_privilege('authenticated',
       'public.fn_enqueue_inbound_file(text,bigint,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated can EXECUTE fn_enqueue_inbound_file; default privileges leaked';
  END IF;
  IF has_function_privilege('anon',
       'public.fn_enqueue_inbound_file(text,bigint,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon can EXECUTE fn_enqueue_inbound_file';
  END IF;
  IF NOT has_function_privilege('service_role',
       'public.fn_enqueue_inbound_file(text,bigint,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role cannot EXECUTE it; the edge function would fail at runtime';
  END IF;

  -- 2. EXERCISE IT. PL/pgSQL is not parsed at creation time, so "the migration applied" says
  --    nothing about whether the body runs. Rolled back at the end of the block.
  v_id1 := public.fn_enqueue_inbound_file(
    'inspection', 999999999, 'fillout', 'dashboard',
    'https://example.invalid/verify-probe.jpg', 'GT - Visits Images');
  IF v_id1 IS NULL THEN
    RAISE EXCEPTION 'first enqueue returned NULL';
  END IF;

  -- 3. Idempotency is the whole point, so prove the SECOND call returns the SAME id and adds no row.
  v_id2 := public.fn_enqueue_inbound_file(
    'inspection', 999999999, 'fillout', 'dashboard',
    'https://example.invalid/verify-probe.jpg', 'GT - Visits Images');
  IF v_id2 IS DISTINCT FROM v_id1 THEN
    RAISE EXCEPTION 'replay returned a different id (% vs %); a retry would double-download', v_id2, v_id1;
  END IF;

  SELECT count(*) INTO v_rows FROM sync.inbound_file_queue WHERE entity_id = 999999999;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'replay created % rows, expected exactly 1', v_rows;
  END IF;

  -- 4. Control: a DIFFERENT role on the same file must be a SEPARATE row, or one photo used twice
  --    would silently collapse. This is what proves assertion 3 tests idempotency and not just
  --    an insert that never happens.
  PERFORM public.fn_enqueue_inbound_file(
    'inspection', 999999999, 'fillout', 'issue',
    'https://example.invalid/verify-probe.jpg', 'GT - Visits Images');
  SELECT count(*) INTO v_rows FROM sync.inbound_file_queue WHERE entity_id = 999999999;
  IF v_rows <> 2 THEN
    RAISE EXCEPTION 'a different role did not create its own row (got %)', v_rows;
  END IF;

  DELETE FROM sync.inbound_file_queue WHERE entity_id = 999999999;

  RAISE NOTICE 'VERIFY passed: service_role-only, body runs, replay is a no-op, distinct roles separate';
END
$verify$;

COMMIT;
