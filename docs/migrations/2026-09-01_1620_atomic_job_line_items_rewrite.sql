-- 2026-09-01_1620_atomic_job_line_items_rewrite.sql
--
-- WHAT: public.rewrite_job_line_items(p_job_id bigint, p_lines jsonb) — one atomic, per-job
--   serialized rewrite of a job's JOB-SCOPE line items (job_id set; visit_id/invoice_id/quote_id NULL).
--
-- WHY: the line-item duplication reported live on job 99900756 (117-BH) is a concurrency race, not a
--   code bug in any single writer. public.line_items has NO unique key BY DESIGN — jobs legitimately
--   carry 2-3 same-name rows at split prices — so the fix is serialization, not a constraint. Three
--   inbound writers rewrite job-scope lines as a NON-ATOMIC delete-then-insert:
--     - webhook-jobber.handleJob (the */5 Jobber poll)
--     - sync-jobber-job-drift (the 30-min drift reconciler)
--     - public.fn_record_client_job (create/edit via save-client-job)
--   A reopen bumps Jobber's updatedAt (forcing a poll pass) AND flips the job back out of the terminal
--   states the drift reconciler excludes, so two of those cycles overlap and interleave
--   (delete-A, delete-B, insert-A, insert-B) -> the set is written twice. It self-heals but is visible.
--
-- HOW: this RPC takes a per-job advisory XACT lock (serializes concurrent rewrites of the SAME job,
--   auto-released at txn end), then does the delete and the insert as one statement each inside one
--   transaction, so no other writer can observe the deleted-but-not-yet-reinserted window. Task A3
--   routes all three writers through it. The reopen handler itself writes no line items and is unchanged.
--
-- COLUMN CONTRACT (preserves each caller's CURRENT behavior exactly, verified 2026-09-01):
--   webhook-jobber inserts {name, description, quantity, unit_price, total_price, taxable};
--   drift and fn_record_client_job insert {name, quantity, unit_price, total_price} (no description/
--   taxable). line_items defaults: taxable=false, all others NULL. So:
--     description -> x.description  (NULL when a caller omits it, matching drift/fn_record today)
--     quantity    -> COALESCE(x.quantity, 1)   (all three default 1)
--     unit_price / total_price -> passed through verbatim (webhook uses 0, the others allow NULL)
--     taxable     -> COALESCE(x.taxable, false) (matches the column default drift/fn_record rely on)
--   jsonb_to_recordset maps absent keys to NULL, which is why the COALESCEs above are load-bearing.
--
-- SCHEMA: lives in public because both edge-function clients use the default (public) PostgREST
--   schema, so `db.rpc('rewrite_job_line_items')` resolves here. Callers all run as service_role.
--
-- DELETE PREDICATE: job_id = X AND visit_id IS NULL AND invoice_id IS NULL AND quote_id IS NULL.
--   This is the widest-SAFE form. webhook-jobber currently deletes by job_id alone, but job-scope rows
--   carry NULL visit_id/invoice_id/quote_id, so this deletes exactly the same rows and additionally
--   refuses to touch any row that also carries a visit/invoice/quote id.

BEGIN;

CREATE OR REPLACE FUNCTION public.rewrite_job_line_items(p_job_id bigint, p_lines jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF p_job_id IS NULL THEN
    RETURN;
  END IF;

  -- serialize concurrent rewrites of the SAME job; auto-released at transaction end
  PERFORM pg_advisory_xact_lock(hashtextextended('public.rewrite_job_line_items', p_job_id));

  DELETE FROM public.line_items
   WHERE job_id = p_job_id
     AND visit_id IS NULL
     AND invoice_id IS NULL
     AND quote_id IS NULL;

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' AND jsonb_array_length(p_lines) > 0 THEN
    INSERT INTO public.line_items (job_id, name, description, quantity, unit_price, total_price, taxable)
    SELECT p_job_id,
           x.name,
           x.description,
           COALESCE(x.quantity, 1),
           x.unit_price,
           x.total_price,
           COALESCE(x.taxable, false)
      FROM jsonb_to_recordset(p_lines)
        AS x(name text, description text, quantity numeric, unit_price numeric, total_price numeric, taxable boolean);
  END IF;
END
$fn$;

REVOKE ALL ON FUNCTION public.rewrite_job_line_items(bigint, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rewrite_job_line_items(bigint, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.rewrite_job_line_items(bigint, jsonb) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
