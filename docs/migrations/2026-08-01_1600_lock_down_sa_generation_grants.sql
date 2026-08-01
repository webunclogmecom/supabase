-- ============================================================================
-- 2026-08-01_1600 — Revoke the DESTRUCTIVE sweep from `authenticated`
-- ============================================================================
-- 🛑 A HOLE I SHIPPED 90 MINUTES AGO, caught by exercising the function AS THE
-- ROLE rather than as postgres.
--
-- `2026-08-01_1450` ended with:
--     revoke all on function public.fn_generate_sa_visits(...) from public, anon;
-- and I assumed that was enough. It is not, and this workspace already had the
-- rule written down: Supabase's DEFAULT PRIVILEGES grant EXECUTE on every new
-- function in `public` to BOTH `authenticated` and `service_role`, and
-- `REVOKE ... FROM PUBLIC` does not touch a grant held directly by a role.
--
-- Measured after the fact:
--   public.fn_generate_sa_visits  acl = {postgres=X/postgres,
--                                        authenticated=X/postgres,   <-- HOLE
--                                        service_role=X/postgres}
--
-- ⚠ WHY THIS PARTICULAR ONE MATTERS. Called with p_client_id = NULL the function
-- runs the FULL SWEEP, and the full sweep is the only branch that is destructive:
-- it soft-deletes stale future visits, which fires trg_push_visit_update ->
-- jobber-push-visit -> visitDelete. So any signed-in staff session could have
-- removed visits from Jobber by calling one RPC. The per-client path deliberately
-- cannot reach that branch — which is exactly why the app must go through
-- client.generate_visits_for_client, and why the raw function must not be
-- reachable from the app at all.
--
-- The callers that legitimately need it are unaffected:
--   * pg_cron runs as `postgres` (owner);
--   * client.generate_visits_for_client is SECURITY DEFINER owned by postgres,
--     so it executes the inner function with the DEFINER's rights, not the
--     caller's — a revoke here cannot break the Client App button.
--
-- Same treatment for fn_promote_sa_visits_to_jobber: pg_cron-only, and it pushes
-- to Jobber, so it has no business being callable from a browser session.
--
-- ROLLBACK (do not — this is the safe state):
--   grant execute on function public.fn_generate_sa_visits(bigint,int,boolean) to authenticated;
-- ============================================================================

begin;

revoke all on function public.fn_generate_sa_visits(bigint, int, boolean)
  from public, anon, authenticated, service_role;

revoke all on function public.fn_promote_sa_visits_to_jobber(int)
  from public, anon, authenticated, service_role;

-- The app's ONLY entry point stays callable. It is per-client, INSERT-only, and
-- refuses a NULL client_id precisely so it can never reach the sweep.
grant execute on function client.generate_visits_for_client(bigint) to authenticated;

commit;
