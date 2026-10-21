-- Rollback of 2026-10-21_1630_inspection_merge_only_a_redo.sql, FUNCTIONS ONLY.
-- Redeploy fillout-inspection at the commit before this one FIRST: the new body calls both functions dropped here.
-- Not undone: the 545 split (backup backups/2026-10-21_inspection_545_split.json) and the index swap.
-- idx_inspections_shift_unique cannot come back while 545 and 552 share (2026-10-20, Moises, Michael, POST).

BEGIN;
DROP FUNCTION public.fn_supersede_inbound_files(text, bigint, text[], text);
DROP FUNCTION public.fn_inspection_redo_of(bigint, bigint, text, timestamptz);

CREATE OR REPLACE FUNCTION public.fn_settle_inbound_file(p_id bigint, p_status text, p_photo_id bigint DEFAULT NULL::bigint, p_error text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'sync', 'public', 'pg_temp'
AS $function$
DECLARE
  v_max_attempts CONSTANT INTEGER := 3;
  v_rows INTEGER;
BEGIN
  IF p_status NOT IN ('done', 'skipped', 'pending', 'error') THEN
    RAISE EXCEPTION 'unknown status %', p_status
      USING DETAIL = 'blocker=bad_status in public.fn_settle_inbound_file';
  END IF;

  -- 🛑 'done' REQUIRES a photo_id. A row marked done with nothing to show for it is the shape that
  -- makes a queue look drained while the images are gone: the work list empties, and the only
  -- evidence left is an absence nobody is counting.
  IF p_status = 'done' AND p_photo_id IS NULL THEN
    RAISE EXCEPTION 'cannot mark a file done without the photo it produced'
      USING DETAIL = 'blocker=done_without_photo in public.fn_settle_inbound_file';
  END IF;

  UPDATE sync.inbound_file_queue
     SET status = CASE
                    -- A reported failure stays retryable until the budget is gone, then sticks.
                    WHEN p_status = 'pending' AND attempts >= v_max_attempts THEN 'error'
                    ELSE p_status
                  END,
         -- Releasing the claim is what makes the row available again immediately, rather than
         -- after the lease expires. A reported failure should retry on the next pass, not in ten
         -- minutes; only an UNREPORTED death should wait for the lease.
         claimed_at   = CASE WHEN p_status = 'pending' THEN NULL ELSE claimed_at END,
         photo_id     = COALESCE(p_photo_id, photo_id),
         last_error   = p_error,
         updated_at   = now(),
         processed_at = CASE WHEN p_status IN ('done','skipped') THEN now() ELSE processed_at END
   WHERE id = p_id;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows = 1;
END
$function$;

DO $v$ BEGIN
  IF md5(regexp_replace(pg_get_functiondef('public.fn_settle_inbound_file(bigint,text,bigint,text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'ea9a1e0f969a9b2636c55bba67737463'
  THEN RAISE EXCEPTION 'rollback: settle body is not the pre-1630 one'; END IF;
END $v$;
COMMIT;
