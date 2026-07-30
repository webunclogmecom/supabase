-- 2026-07-30_0148_add_ops_retry_visit_push_wrapper.sql
--
-- FIXES A DEAD BUTTON: the Visit Calendar's "Retry sync" has NEVER worked.
--
-- The app calls  Me.rpc("retry_visit_push", …)  where `Me` is the Supabase client pinned to
-- db:{schema:'ops'}. PostgREST therefore resolves it as ops.retry_visit_push — which did not exist.
-- The function was only ever created in `public`.
--
-- Measured before this migration:
--   create_calendar_visit      ops + public
--   delete_calendar_visit      ops + public
--   edit_calendar_visit        ops + public
--   get_record_history         ops + public
--   ripple_reschedule_visit    ops + public
--   set_visit_status           ops + public
--   unskip_visit               ops + public
--   retry_visit_push           public ONLY          <-- the sole miss
--
-- Live probe (read-only) confirmed the failure mode discriminates:
--   Accept-Profile: ops     -> 404 PGRST202 "Could not find the function ops.retry_visit_push(...)"
--   Accept-Profile: public  -> 42501 permission denied      (positive control: the codes differ)
--
-- USER-VISIBLE IMPACT. The drawer's catch is `toast.error(err?.message ?? "Retry failed")`, so a
-- dispatcher pressing Retry saw the raw PostgREST string
-- "Could not find the function ops.retry_visit_push(p_visit_id) in the schema cache".
-- The "Possible duplicate / Push anyway" confirm dialog was also unreachable dead code, because it
-- only opens on the RPC's blocked:'duplicate' branch.
--
-- ⚠ WHY EVERY TEST MISSED IT, and this is the reusable part. The feature was verified extensively:
-- all five retry states were read in the live UI, the button's presence/absence was checked per
-- state, and the backend retry was proven end to end. But every backend test ran through the
-- Management API as `postgres` with `public` on the search_path, which is STRUCTURALLY INCAPABLE of
-- catching a PostgREST schema-resolution failure — and the one UI action that would have caught it,
-- pressing the button, was deliberately deferred during the joint test and then never performed.
--   The existing rule is "test as the ROLE, not as the owner".
--   The sibling rule this adds: TEST THROUGH THE TRANSPORT, NOT THE CATALOGUE.
--   A function existing is not the same as the app being able to reach it.
--
-- STANDING CHECK worth automating: extract every `rpc("X")` from the deployed bundle and assert
-- to_regprocedure('ops.X(...)') IS NOT NULL for the ops-pinned client.
--
-- This migration is purely ADDITIVE — it creates a wrapper and grants EXECUTE. It changes no
-- existing object and cannot regress anything. Shape copied verbatim from ops.set_visit_status.
--
-- Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>

BEGIN;

CREATE OR REPLACE FUNCTION ops.retry_visit_push(p_visit_id bigint, p_force boolean DEFAULT false)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.retry_visit_push(p_visit_id, p_force)
$function$;

REVOKE ALL ON FUNCTION ops.retry_visit_push(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.retry_visit_push(bigint, boolean) TO authenticated;

COMMIT;
