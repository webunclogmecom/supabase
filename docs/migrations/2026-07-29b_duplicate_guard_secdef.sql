-- 2026-07-29b  fn_visit_push_duplicate_of must be SECURITY DEFINER, not INVOKER
--
-- FIX for a 403 the @Building Apps session caught on the live Calendar: every request to
-- ops.v_calendar_push_health_by_visit returned HTTP 403, so the amber sync box never rendered.
--
-- ROOT CAUSE — and it is the exact trap CLAUDE.md documents, which I wrote into my own spec (§4.1)
-- and then verified the wrong half of:
--
--     ERROR: 42501: permission denied for table entity_source_links
--     CONTEXT: SQL function "fn_visit_push_duplicate_of" statement 1
--
-- ops.v_calendar_push_health_by_visit is postgres-owned with reloptions NULL, i.e. an OWNER-RIGHTS
-- view, so its TABLE reads launder fine. But a SECURITY INVOKER **function** called from inside that
-- view still executes with the CALLER's privileges. `authenticated` holds EXECUTE on the function —
-- I checked that — but has no SELECT on `public.entity_source_links`, which the function reads.
-- Granting EXECUTE was necessary and not sufficient; I confirmed the grant existed and stopped there.
--
-- ⚠ WHY MY TESTS MISSED IT. Every test in 2026-07-29 ran through the Management API, i.e. as
-- `postgres`, which can read everything. The function was never once exercised as the role that
-- actually calls it. A grant matrix proves who may EXECUTE; it says nothing about what the function
-- touches once it runs. **Test as the role, not as the owner.**
--
-- FIX. SECURITY DEFINER with a pinned search_path — the pattern CLAUDE.md already prescribes for a
-- helper called from an owner-rights view ("SECDEF without a pinned search_path is the footgun").
-- Chosen over `GRANT SELECT ON entity_source_links TO authenticated`, which would widen access to the
-- whole cross-system bridge table for every staff user just to answer one boolean-ish question.
--
-- ⚠ WHY THIS ESCALATES NOTHING. The function returns one `visits.id` for a visit belonging to the
-- SAME client on the SAME date, and every caller already holds SELECT on `visits`. It exposes no row
-- a caller could not already read, and it takes no user input beyond a visit id. The pinned
-- search_path is what makes the definer context safe, and it is set below.
--
-- Note `public.retry_visit_push` was already SECURITY DEFINER and calls this same function, which is
-- why the RPC path worked in testing while the view path did not — the two differ only in whose
-- privileges the inner call runs under. That asymmetry is what made the failure look like a grant
-- problem rather than a context problem.
--
-- RULE 8 (ADR 010): no table or column change. RULE 1: no source-prefixed columns.

CREATE OR REPLACE FUNCTION public.fn_visit_push_duplicate_of(p_visit_id bigint)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT sib.id
  FROM public.visits me
  JOIN public.visits sib
    ON sib.id         <> me.id
   AND sib.client_id   = me.client_id
   AND sib.visit_date  = me.visit_date
   AND sib.job_id IS NOT DISTINCT FROM me.job_id
   AND sib.deleted_at IS NULL
  WHERE me.id = p_visit_id
    AND me.deleted_at IS NULL
    AND NOT EXISTS (SELECT 1 FROM public.entity_source_links e
                     WHERE e.entity_type='visit' AND e.source_system='jobber' AND e.entity_id = me.id)
    AND EXISTS (SELECT 1 FROM public.entity_source_links e2
                 WHERE e2.entity_type='visit' AND e2.source_system='jobber' AND e2.entity_id = sib.id)
  ORDER BY sib.created_at DESC
  LIMIT 1;
$function$;

-- CREATE OR REPLACE preserves existing grants, but restate them so this file is self-contained and
-- anon exclusion is explicit rather than inherited.
REVOKE ALL     ON FUNCTION public.fn_visit_push_duplicate_of(bigint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_visit_push_duplicate_of(bigint) TO service_role, authenticated, yannick_readonly;

-- Post-condition, and the test that should have existed the first time. Run BOTH:
--   BEGIN; SET LOCAL ROLE authenticated;    SELECT * FROM ops.v_calendar_push_health_by_visit LIMIT 1; ROLLBACK;
--   BEGIN; SET LOCAL ROLE yannick_readonly; SELECT * FROM ops.v_calendar_push_health_by_visit LIMIT 1; ROLLBACK;
-- Both must return rows, not 42501.
