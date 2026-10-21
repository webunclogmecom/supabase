-- 2026-10-21_1630_inspection_merge_only_a_redo.sql
--
-- Fred (2026-10-21): "public.photo_links rows with entity_type='inspection' and entity_id=545 carry 26 live rows for 13
-- roles (each role twice) ... find the cause ... fix the cause so it cannot recur ... soft-delete the duplicate links".
--
-- MEASURED FIRST. The 26 links are NOT the same photo stored twice: 26 different photos, 26 different Fillout file URLs.
-- They are two different POST forms folded into one row:
--   b0a82be0 (the row's own fillout link) 07:30 ET Oct 20, Michael E, Moises, sludge 2000, water 450: closes his night
--            shift (PRE 544, 22:00 ET Oct 19). Photos 07:29-07:35 ET, queue rows 444-456.
--   4778b4dc                              19:00 ET Oct 20, Michael E, Moises, sludge 0, water 0. Filed AFTER Steven's PRE
--            546 on the same truck (12:45 ET). Photos 18:48-18:51 ET, queue rows 464-476.
-- Cause: fillout-inspection's 23505 arm. idx_inspections_shift_unique keyed a shift on (ET clock date, truck, driver,
-- type), so the 19:00 form hit 23505 and was MERGED as a "redo": it overwrote 545's answers (545 read 0 / 0 / 23:00Z) and
-- its 13 photos were queued onto 545 next to the 13 it already had. Not a retried webhook (submission_id idempotency
-- held: each submission processed once) and not a double import (the Airtable backfill never touched 545).
-- Reach, all inspections: 0 live links repeat (inspection, role, photo) (the unique key forbids it); 0 repeat a source URL;
-- 0 repeat (inspection, role, size). Only 545 holds forms from two submissions. Same-role repeats elsewhere are real extra
-- photos: 63 Airtable-era inspections (a field takes up to 5 files) and 529-532 (two issue pictures each). 109 Airtable-era
-- POSTs (2025-06-05 to 2026-03-19, 91 on David) link ONE photo as both sludge_level and water_level: the Airtable record
-- carried that attachment in both fields; left as the source has it.
--
-- 1. idx_inspections_shift_unique (shift_date, vehicle_id, employee_id, inspection_type) is REPLACED by
--    idx_inspections_submission_unique (vehicle_id, employee_id, inspection_type, submitted_at), same partial predicate.
--    A shift is not "one form per ET date" (shifts are public.v_inspection_shifts since 2026-10-21_1553); the new key
--    still stops a concurrent re-delivery of one form from making two rows. 0 existing rows collide on it.
-- 2. NEW public.fn_inspection_redo_of: the old key PLUS "nothing filed in between by that driver or on that truck".
--    The edge function merges only into what this returns; anything else is its own inspection.
-- 3. NEW public.fn_supersede_inbound_files: on a real redo the later form wins whole, photos too. The earlier form's
--    links are soft-deleted and its unfetched files skipped ('superseded: ...').
-- 4. public.fn_settle_inbound_file: a file superseded while a worker was fetching it stays skipped, and the link the
--    worker just made is soft-deleted. Without it a redo inside the drain window leaves stray photos behind.
-- 5. Repair 545 (pinned to its merged state): answers back to b0a82be0; 4778b4dc gets its own POST row and fillout link;
--    its 13 links on 545 are soft-deleted and re-made on the new row; queue rows 464-476 point at the new row so a replay
--    of 4778b4dc downloads nothing. The form names Michael; it is stored as filed, not re-assigned to Steven.
--
-- Rule 8: no new table. photo_links is audited (audit_photo_links). public.inspections and sync.inbound_file_queue are
-- NOT audited: the rows changed here were backed up to backups/2026-10-21_inspection_545_split.json first, and 545's
-- overwritten answers are also in webhook_events_log 482066's payload.
-- Rollback (functions only): 2026-10-21_rollback_inspection_merge_only_a_redo.sql. The old index cannot come back while
-- 545 and the new row share (2026-10-20, Moises, Michael, POST); that is the point.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF md5(regexp_replace(pg_get_functiondef('public.fn_settle_inbound_file(bigint,text,bigint,text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'ea9a1e0f969a9b2636c55bba67737463' THEN RAISE EXCEPTION 'guard: fn_settle_inbound_file changed'; END IF;
  IF to_regclass('public.idx_inspections_shift_unique') IS NULL THEN RAISE EXCEPTION 'guard: idx_inspections_shift_unique missing'; END IF;
  IF to_regproc('public.fn_inspection_redo_of') IS NOT NULL OR to_regproc('public.fn_supersede_inbound_files') IS NOT NULL THEN RAISE EXCEPTION 'guard: functions exist'; END IF;
END $g$;

-- 1 ---------------------------------------------------------------------------------------------------------------------
DROP INDEX public.idx_inspections_shift_unique;
CREATE UNIQUE INDEX idx_inspections_submission_unique ON public.inspections (vehicle_id, employee_id, inspection_type, submitted_at)
  WHERE vehicle_id IS NOT NULL AND employee_id IS NOT NULL;

-- 2 ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION public.fn_inspection_redo_of(p_vehicle_id bigint, p_employee_id bigint, p_type text, p_submitted_at timestamptz)
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  -- A form is a REDO of a held one only when it is the same driver, truck, type and ET date AND nothing was filed in
  -- between by that driver or on that truck. 545 (2026-10-21): Michael's 07:30 and 19:00 POSTs matched the first half,
  -- and Steven's 12:45 PRE on the same truck is what says they are two shifts. Nearest held form wins.
  -- ponytail: no time cap; two same-type forms on one date with nothing filed between them still merge.
  select h.id
    from public.inspections h
   where h.vehicle_id = p_vehicle_id
     and h.employee_id = p_employee_id
     and h.inspection_type = p_type
     and h.shift_date = (p_submitted_at at time zone 'America/New_York')::date
     and not exists (
           select 1 from public.inspections x
            where x.id <> h.id
              and (x.employee_id = p_employee_id or x.vehicle_id = p_vehicle_id)
              and x.submitted_at > least(h.submitted_at, p_submitted_at)
              and x.submitted_at < greatest(h.submitted_at, p_submitted_at))
   order by abs(extract(epoch from h.submitted_at - p_submitted_at)), h.id
   limit 1
$function$;

-- 3 ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION public.fn_supersede_inbound_files(p_entity_type text, p_entity_id bigint, p_keep_urls text[], p_reason text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'sync', 'public', 'pg_temp'
AS $function$
DECLARE
  v_reason text := 'superseded: ' || p_reason;
  v_rows   integer;
  v_links  integer;
BEGIN
  IF p_keep_urls IS NULL OR coalesce(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'keep list and reason are required'
      USING DETAIL = 'blocker=bad_args in public.fn_supersede_inbound_files';
  END IF;

  -- Queue rows FIRST: a row a worker holds is locked here, so its settle waits and then sees 'skipped'
  -- (fn_settle_inbound_file takes the link back). Then links, in a fresh snapshot that sees any settle that won the race.
  UPDATE sync.inbound_file_queue q
     SET status = 'skipped', last_error = v_reason, processed_at = now(), updated_at = now()
   WHERE q.entity_type = p_entity_type AND q.entity_id = p_entity_id
     AND q.status IN ('pending', 'claimed', 'error')
     AND NOT (q.source_url = ANY (p_keep_urls));
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  UPDATE public.photo_links pl
     SET deleted_at = now(), deleted_reason = v_reason
   WHERE pl.entity_type = p_entity_type AND pl.entity_id = p_entity_id AND pl.deleted_at IS NULL
     AND pl.photo_id IN (SELECT q.photo_id FROM sync.inbound_file_queue q
                          WHERE q.entity_type = p_entity_type AND q.entity_id = p_entity_id
                            AND q.photo_id IS NOT NULL AND NOT (q.source_url = ANY (p_keep_urls)));
  GET DIAGNOSTICS v_links = ROW_COUNT;

  RETURN v_rows + v_links;
END
$function$;

-- 4 ---------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_settle_inbound_file(p_id bigint, p_status text, p_photo_id bigint DEFAULT NULL::bigint, p_error text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'sync', 'public', 'pg_temp'
AS $function$
DECLARE
  v_max_attempts CONSTANT INTEGER := 3;
  v_rows INTEGER;
  v_cur  sync.inbound_file_queue%ROWTYPE;
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

  -- A redo superseded this file (fn_supersede_inbound_files) while the worker was fetching it. The worker has already
  -- linked the photo, so take that link back and keep the row skipped; any other outcome must not re-open the row.
  SELECT * INTO v_cur FROM sync.inbound_file_queue WHERE id = p_id FOR UPDATE;
  IF v_cur.status = 'skipped' AND v_cur.last_error LIKE 'superseded:%' THEN
    IF p_photo_id IS NOT NULL THEN
      UPDATE public.photo_links
         SET deleted_at = now(), deleted_reason = v_cur.last_error
       WHERE photo_id = p_photo_id AND entity_type = v_cur.entity_type AND entity_id = v_cur.entity_id
         AND deleted_at IS NULL;
      UPDATE sync.inbound_file_queue SET photo_id = p_photo_id, updated_at = now() WHERE id = p_id;
    END IF;
    RETURN true;
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

REVOKE ALL ON FUNCTION public.fn_inspection_redo_of(bigint, bigint, text, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_supersede_inbound_files(text, bigint, text[], text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_inspection_redo_of(bigint, bigint, text, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_supersede_inbound_files(text, bigint, text[], text) TO service_role;

-- 5 ---------------------------------------------------------------------------------------------------------------------
DO $repair$
DECLARE
  c_merged  CONSTANT text := '4778b4dc-f2b1-45c4-983f-e0cff17faf5e';
  c_own     CONSTANT text := 'b0a82be0-411f-4eba-b2eb-24ea6734f87a';
  v_new     bigint;
  v_n       integer;
  v_reason  text;
BEGIN
  -- 545 must still be in the merged state, and the two logged payloads must say what this repair writes.
  IF NOT EXISTS (SELECT 1 FROM public.inspections WHERE id = 545 AND submitted_at = '2026-10-20T23:00:00Z'
                   AND sludge_gallons = 0 AND water_gallons = 0 AND vehicle_id = 1 AND employee_id = 40 AND inspection_type = 'POST')
  THEN RAISE EXCEPTION 'repair guard: 545 is not in the merged state'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.webhook_events_log WHERE id = 480338 AND event_id = c_own
                   AND payload->>'date' = '2026-10-20T11:30:00.000Z' AND (payload->>'sludge_gallons')::numeric = 2000
                   AND (payload->>'water_gallons')::numeric = 450 AND payload->>'gas_level' = '1/2' AND payload->>'has_issue' = 'No')
  THEN RAISE EXCEPTION 'repair guard: payload 480338'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.webhook_events_log WHERE id = 482066 AND event_id = c_merged
                   AND payload->>'date' = '2026-10-20T23:00:00.000Z' AND (payload->>'sludge_gallons')::numeric = 0
                   AND (payload->>'water_gallons')::numeric = 0 AND payload->>'gas_level' = '1/2' AND payload->>'has_issue' = 'No')
  THEN RAISE EXCEPTION 'repair guard: payload 482066'; END IF;
  IF EXISTS (SELECT 1 FROM public.entity_source_links WHERE entity_type = 'inspection' AND source_system = 'fillout' AND source_id = c_merged)
  THEN RAISE EXCEPTION 'repair guard: 4778b4dc already linked'; END IF;

  UPDATE public.inspections
     SET submitted_at = '2026-10-20T11:30:00Z', sludge_gallons = 2000, water_gallons = 450, gas_level = '1/2',
         has_issue = false, issue_note = NULL, is_valve_closed = NULL
   WHERE id = 545 AND submitted_at = '2026-10-20T23:00:00Z';
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n <> 1 THEN RAISE EXCEPTION 'repair: 545 restore hit % rows', v_n; END IF;

  INSERT INTO public.inspections (vehicle_id, employee_id, shift_date, inspection_type, submitted_at, sludge_gallons,
                                  water_gallons, gas_level, is_valve_closed, has_issue, issue_note)
  VALUES (1, 40, '2026-10-20', 'POST', '2026-10-20T23:00:00Z', 0, 0, '1/2', NULL, false, NULL)
  RETURNING id INTO v_new;

  INSERT INTO public.entity_source_links (entity_type, entity_id, source_system, source_id)
  VALUES ('inspection', v_new, 'fillout', c_merged);

  -- The 19:00 form's files are exactly the queue rows on 545 whose URL is in its own payload.
  CREATE TEMP TABLE _moved ON COMMIT DROP AS
  SELECT q.id AS queue_id, q.photo_id, q.role
    FROM sync.inbound_file_queue q
   WHERE q.entity_type = 'inspection' AND q.entity_id = 545
     AND q.source_url IN (SELECT e->>'url' FROM public.webhook_events_log w, jsonb_each(w.payload) f, jsonb_array_elements(f.value) e
                           WHERE w.id = 482066 AND f.key LIKE 'photo\_%' AND jsonb_typeof(f.value) = 'array');
  SELECT count(*) INTO v_n FROM _moved WHERE photo_id IS NOT NULL;
  IF v_n <> 13 OR (SELECT count(*) FROM _moved) <> 13 THEN RAISE EXCEPTION 'repair: expected 13 files of 4778b4dc on 545, got %', v_n; END IF;

  v_reason := format('moved to inspection %s: Fillout submission %s (19:00 ET POST) was merged into 545 by the shift-date rule (2026-10-21_1630)', v_new, c_merged);
  UPDATE public.photo_links pl SET deleted_at = now(), deleted_reason = v_reason
    FROM _moved m
   WHERE pl.photo_id = m.photo_id AND pl.entity_type = 'inspection' AND pl.entity_id = 545 AND pl.role = m.role AND pl.deleted_at IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n <> 13 THEN RAISE EXCEPTION 'repair: soft-deleted % links on 545', v_n; END IF;

  INSERT INTO public.photo_links (photo_id, entity_type, entity_id, role)
  SELECT photo_id, 'inspection', v_new, role FROM _moved;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n <> 13 THEN RAISE EXCEPTION 'repair: linked % photos to %', v_n, v_new; END IF;

  UPDATE sync.inbound_file_queue q SET entity_id = v_new, updated_at = now()
    FROM _moved m WHERE q.id = m.queue_id AND q.entity_id = 545;
  GET DIAGNOSTICS v_n = ROW_COUNT; IF v_n <> 13 THEN RAISE EXCEPTION 'repair: repointed % queue rows', v_n; END IF;

  RAISE NOTICE 'repair: 4778b4dc is inspection %', v_new;
END
$repair$;

-- VERIFY ----------------------------------------------------------------------------------------------------------------
DO $v$
DECLARE v_new bigint; v_bad integer;
BEGIN
  SELECT entity_id INTO v_new FROM public.entity_source_links
   WHERE entity_type = 'inspection' AND source_system = 'fillout' AND source_id = '4778b4dc-f2b1-45c4-983f-e0cff17faf5e';

  -- each of the two rows: 13 live links, one per role
  IF (SELECT count(*) FROM public.photo_links WHERE entity_type = 'inspection' AND entity_id = 545 AND deleted_at IS NULL) <> 13
  OR (SELECT count(DISTINCT role) FROM public.photo_links WHERE entity_type = 'inspection' AND entity_id = 545 AND deleted_at IS NULL) <> 13
  OR (SELECT count(*) FROM public.photo_links WHERE entity_type = 'inspection' AND entity_id = v_new AND deleted_at IS NULL) <> 13
  OR (SELECT count(DISTINCT role) FROM public.photo_links WHERE entity_type = 'inspection' AND entity_id = v_new AND deleted_at IS NULL) <> 13
  THEN RAISE EXCEPTION 'verify: link counts'; END IF;

  -- THE INVARIANT, estate-wide: every live link of a Fillout inspection comes from a file its OWN linked submission sent.
  -- (Positive control: before this repair it counted 13, the 19:00 files on 545.)
  SELECT count(*) INTO v_bad
    FROM public.photo_links pl
    JOIN sync.inbound_file_queue q ON q.photo_id = pl.photo_id AND q.entity_type = pl.entity_type AND q.entity_id = pl.entity_id
    JOIN public.entity_source_links e ON e.entity_type = 'inspection' AND e.entity_id = pl.entity_id AND e.source_system = 'fillout'
   WHERE pl.entity_type = 'inspection' AND pl.deleted_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.webhook_events_log w, jsonb_each(w.payload) f, jsonb_array_elements(f.value) el
                      WHERE w.source_system = 'fillout' AND w.event_id = e.source_id AND w.status = 'processed'
                        AND f.key LIKE 'photo\_%' AND jsonb_typeof(f.value) = 'array' AND el->>'url' = q.source_url);
  IF v_bad <> 0 THEN RAISE EXCEPTION 'verify: % live links not from their own submission', v_bad; END IF;

  -- the shifts: Michael's night of Oct 19 is 544 + 545, the 19:00 form is a POST-only shift of Oct 20
  IF NOT EXISTS (SELECT 1 FROM public.v_inspection_shifts WHERE employee_id = 40 AND shift_date = '2026-10-19' AND pre_inspection_id = 544 AND post_inspection_id = 545)
  OR NOT EXISTS (SELECT 1 FROM public.v_inspection_shifts WHERE employee_id = 40 AND shift_date = '2026-10-20' AND pre_inspection_id IS NULL AND post_inspection_id = v_new)
  THEN RAISE EXCEPTION 'verify: shifts'; END IF;

  -- the redo rule on the live rows: the 19:00 form is NOT a redo of 545 (Steven's PRE 546 is in between) ...
  IF public.fn_inspection_redo_of(1, 40, 'POST', '2026-10-20T23:00:00Z') IS DISTINCT FROM v_new THEN RAISE EXCEPTION 'verify: redo_of(19:00)'; END IF;
  IF public.fn_inspection_redo_of(1, 40, 'POST', '2026-10-20T11:45:00Z') IS DISTINCT FROM 545 THEN RAISE EXCEPTION 'verify: redo_of(07:45)'; END IF;
  -- ... and no form filed after Steven's 12:45 PRE can ever be a redo of 545
  IF public.fn_inspection_redo_of(1, 40, 'POST', '2026-10-20T17:00:00Z') = 545 THEN RAISE EXCEPTION 'verify: redo_of(13:00)'; END IF;

  -- only service_role may call the two new functions
  IF has_function_privilege('authenticated', 'public.fn_inspection_redo_of(bigint,bigint,text,timestamptz)', 'EXECUTE')
  OR has_function_privilege('anon', 'public.fn_inspection_redo_of(bigint,bigint,text,timestamptz)', 'EXECUTE')
  OR has_function_privilege('authenticated', 'public.fn_supersede_inbound_files(text,bigint,text[],text)', 'EXECUTE')
  OR has_function_privilege('anon', 'public.fn_supersede_inbound_files(text,bigint,text[],text)', 'EXECUTE')
  OR NOT has_function_privilege('service_role', 'public.fn_inspection_redo_of(bigint,bigint,text,timestamptz)', 'EXECUTE')
  OR NOT has_function_privilege('service_role', 'public.fn_supersede_inbound_files(text,bigint,text[],text)', 'EXECUTE')
  THEN RAISE EXCEPTION 'verify: grants'; END IF;
END
$v$;

COMMIT;
