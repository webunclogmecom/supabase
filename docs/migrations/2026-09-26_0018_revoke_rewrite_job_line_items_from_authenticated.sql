-- ============================================================================
-- 2026-09-26_0018 · public.rewrite_job_line_items: service_role only (revoke from authenticated)
-- ============================================================================
-- FOUND by the adversarial review of 2026-09-25_2350 (whose two sibling functions were created
-- service_role only). rewrite_job_line_items is SECURITY DEFINER and deletes and rewrites ANY job's
-- job-scope line items with whatever content the caller sends, and `authenticated` held EXECUTE:
--   proacl {postgres=X, authenticated=X, service_role=X}
-- 2026-09-01_1620 revoked it from PUBLIC and anon only; Supabase's default privileges had already granted
-- EXECUTE to authenticated BY NAME, which a revoke from PUBLIC does not remove (the trap CLAUDE.md
-- documents). 2026-09-01_1625 then described the grants as "service_role-only", which they were not.
-- So any signed-in staff browser could POST /rest/v1/rpc/rewrite_job_line_items and replace a Service
-- Agreement's agreed services, bypassing save-client-job's Jobber-first saga.
--
-- CALLERS (measured before revoking, 2026-09-26 00:15 ET):
--   * webhook-jobber handleJob and sync-jobber-job-drift, both as service_role;
--   * public.fn_record_client_job (SECURITY DEFINER, owner postgres), which runs as its owner and needs
--     no grant to authenticated;
--   * audit.logs, 90 days: 234 line_items writes through /rpc/rewrite_job_line_items, every one with JWT
--     role service_role; no Building Apps bundle or source names the function.
-- RULE 8: no table change; public.line_items stays audited.
-- ROLLBACK: grant execute on function public.rewrite_job_line_items(bigint, jsonb) to authenticated;
-- ============================================================================

revoke all on function public.rewrite_job_line_items(bigint, jsonb) from public, anon, authenticated;
grant execute on function public.rewrite_job_line_items(bigint, jsonb) to service_role;

-- VERIFY
do $$
begin
  if has_function_privilege('authenticated', 'public.rewrite_job_line_items(bigint,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.rewrite_job_line_items(bigint,jsonb)', 'execute') then
    raise exception 'verify: anon/authenticated can still execute rewrite_job_line_items';
  end if;
  if not has_function_privilege('service_role', 'public.rewrite_job_line_items(bigint,jsonb)', 'execute') then
    raise exception 'verify: service_role lost execute on rewrite_job_line_items';
  end if;
  -- the SECDEF caller keeps working because it runs as its owner (postgres)
  if not (select prosecdef from pg_proc where oid = 'public.fn_record_client_job(jsonb)'::regprocedure) then
    raise exception 'verify: fn_record_client_job is no longer SECURITY DEFINER; re-check before revoking';
  end if;
end $$;
