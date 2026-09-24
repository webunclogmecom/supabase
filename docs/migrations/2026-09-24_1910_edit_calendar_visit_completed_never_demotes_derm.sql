-- ============================================================================
-- 2026-09-24 · edit_calendar_visit: a line edit on a COMPLETED or FILED visit only ever promotes derm_required
-- ============================================================================
-- APPLIED 2026-09-24 ~19:50 ET (dry run first: 54/54 cells, the old body failed its expected 16). Live check
-- after: the public body carries the rule twice; proacl, SECURITY DEFINER and search_path unchanged; the ops.
-- wrapper untouched.
-- THE ASK
--   Fred, 2026-09-24, on the grey water follow-ups: "Go ahead with all these, but skip 11." Item 9 was:
--   "If someone edits the line items of a completed visit in the Calendar, the 'required' value is
--   recalculated. Doing that on one of the filed grey water visits would switch it to 'not required'."
--
-- WHAT WAS WRONG
--   public.edit_calendar_visit has two line-edit paths (catalogue services, arbitrary lines). Both ended
--   with `derm_required = v_derm`, whatever the visit's status and whatever it held. v_derm is a bool_or of
--   fn_line_item_requires_derm over the new lines, so on a COMPLETED visit a line edit could:
--     - demote TRUE to FALSE: the 23 filed grey water visits Fred kept TRUE ("leave the filed ones alone")
--       now derive FALSE, and 10 more completed visits with free-text grey water lines will after
--       2026-09-24_1920. A demoted visit leaves "Missing Docs" logic and, for a non-grey visit, the client's
--       Field Portal;
--     - set NULL: an arbitrary line with an unrecognised name makes v_derm NULL.
--   Every other automatic writer is monotonic (set_visit_derm_required: never demote a known TRUE; the
--   nightly rederive: fill NULL only). This was the one writer that was not, and the one path where a
--   person editing an old visit's services could silently change its DERM status.
--
-- WHAT CHANGES (one function body, spliced; the ops.edit_calendar_visit wrapper is untouched)
--   Both `derm_required = v_derm` become
--     derm_required = CASE WHEN v_derm IS NOT TRUE AND (visit_status = 'completed' OR <a live manifest link>)
--                          THEN derm_required ELSE v_derm END
--   so on a COMPLETED or FILED visit a line edit may only PROMOTE (FALSE/NULL -> TRUE). It never demotes a
--   TRUE, never blanks a value, and never fills NULL with FALSE: NULL is the fail-safe value there
--   (customer.work_orders and derm.visits.needs_manifest read COALESCE(derm_required, true)), and measured
--   2026-09-24 all 29 completed unlocked NULL visits are filed, so a FALSE fill would take a filed work order,
--   manifest included, off the client's Field Portal. (A first draft allowed that fill, mirroring
--   set_visit_derm_required; the pre-apply review caught it.) "Filed" also covers a visit that was
--   un-completed (set_visit_status allows completed -> scheduled) and then edited: its link stays, so it stays
--   protected. On any other visit (scheduled or cancelled, no link) the full recompute stays, because a
--   pending visit whose services change must follow them. trg_derm_required_lock still guards human-locked
--   values on top. A person who really wants a completed visit not required uses the DERM Tracker toggle.
--   Known and accepted: the CASE reads the column as it stands, so a single patch carrying BOTH
--   service_line_item_ids and line_items on a completed visit keeps a TRUE set by the first path. No caller
--   sends both (the Calendar sends one or the other; save-calendar-visit refuses line patches).
--
-- VERIFY: a rolled-back 54-case matrix (visit {completed, scheduled, un-completed but filed} x stored {TRUE,
--   FALSE, NULL} x new services {grease trap 01 -> TRUE, grey water 03 -> FALSE, fee 25 only -> NULL} x path
--   {catalogue, arbitrary lines}) on [TEST] 112-YA visits inside a subtransaction (the filed ones linked to the
--   112-YA test manifest 1941, then set back to scheduled); the OLD body runs the same matrix and must FAIL
--   exactly the 16 protected cells (positive control). Jobber push is suppressed and the fixture rolls back.
-- 🛑 Spliced from the live pg_get_functiondef (md5 pinned, the anchor counted to exactly two), never retyped.
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table changes.
-- ROLLBACK: docs/migrations/_baseline/2026-09-24_edit_calendar_visit.before.sql.
-- ============================================================================

BEGIN;

SET LOCAL app.suppress_jobber_push = 'on';

CREATE TEMP TABLE _acl_before ON COMMIT DROP AS
  SELECT proacl::text AS acl, prosecdef, proconfig::text AS cfg FROM pg_proc WHERE oid = 'public.edit_calendar_visit(bigint, jsonb)'::regprocedure;

-- The previous body, kept under a temp name as the positive control.
DO $old$
DECLARE d text := pg_get_functiondef('public.edit_calendar_visit(bigint, jsonb)'::regprocedure);
BEGIN
  IF md5(d) <> '8e339fbdcabf88ada4d3fe29791869ef' THEN
    RAISE EXCEPTION 'public.edit_calendar_visit changed since this migration was built; rebuild it'; END IF;
  EXECUTE replace(d, 'CREATE OR REPLACE FUNCTION public.edit_calendar_visit(', 'CREATE FUNCTION pg_temp.edit_calendar_visit_old(');
END
$old$;

DO $mig$
DECLARE
  d text := pg_get_functiondef('public.edit_calendar_visit(bigint, jsonb)'::regprocedure);
  a text := 'derm_required = v_derm';
  b text := 'derm_required = CASE WHEN v_derm IS NOT TRUE AND (visit_status = ''completed'' OR EXISTS (SELECT 1'
            || ' FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL'
            || ' WHERE mv.visit_id = p_visit_id)) THEN derm_required ELSE v_derm END'
            || ' /* 2026-09-24: a completed or filed visit is only ever promoted */';
BEGIN
  IF md5(d) <> '8e339fbdcabf88ada4d3fe29791869ef' THEN
    RAISE EXCEPTION 'public.edit_calendar_visit changed since this migration was built; rebuild it'; END IF;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 2 THEN
    RAISE EXCEPTION 'edit_calendar_visit: expected exactly 2 "%" assignments', a; END IF;
  EXECUTE replace(d, a, b);
END
$mig$;

DO $verify$
DECLARE
  d_new text := pg_get_functiondef('public.edit_calendar_visit(bigint, jsonb)'::regprocedure);
  id01 bigint := (SELECT id FROM public.service_line_items WHERE code = '01');
  id03 bigint := (SELECT id FROM public.service_line_items WHERE code = '03');
  id25 bigint := (SELECT id FROM public.service_line_items WHERE code = '25');
  t01 text := (SELECT title FROM public.service_line_items WHERE code = '01');
  t03 text := (SELECT title FROM public.service_line_items WHERE code = '03');
  t25 text := (SELECT title FROM public.service_line_items WHERE code = '25');
  -- the 112-YA test manifest the "filed" cells link to (resolved, never hard-coded by id)
  m_test bigint := (SELECT id FROM public.derm_manifests WHERE client_id = 381 AND white_manifest_number = '111113'
                      AND deleted_at IS NULL AND dump_ticket_date = DATE '2026-09-15');
  fn text; st text; sv text; inp text; pth text; vid bigint; got boolean; want boolean; stored boolean; inval boolean;
  patch jsonb; bad_new int := 0; bad_old int := 0; cells int := 0; r_new text := ''; r_old text := '';
BEGIN
  IF id01 IS NULL OR id03 IS NULL OR id25 IS NULL THEN RAISE EXCEPTION 'catalogue codes 01/03/25 not found'; END IF;
  IF m_test IS NULL THEN RAISE EXCEPTION '112-YA test manifest 111113 (dump 2026-09-15) not found'; END IF;
  IF (SELECT requires_derm FROM public.service_line_items WHERE code = '01') IS NOT TRUE
     OR (SELECT requires_derm FROM public.service_line_items WHERE code = '03') IS NOT FALSE
     OR (SELECT reason FROM public.service_line_items WHERE code = '25') <> 'fee' THEN
    RAISE EXCEPTION 'catalogue premise changed (01 required, 03 not required, 25 a fee)'; END IF;
  IF (length(d_new) - length(replace(d_new, 'a completed or filed visit is only ever promoted', ''))) / length('a completed or filed visit is only ever promoted') <> 2 THEN
    RAISE EXCEPTION 'V0: the new body does not carry the rule twice'; END IF;

  FOREACH fn IN ARRAY ARRAY['new', 'old'] LOOP
    BEGIN   -- subtransaction: everything written here is rolled back by the RAISE at its end
      FOREACH st IN ARRAY ARRAY['completed', 'scheduled', 'filed'] LOOP
        FOREACH sv IN ARRAY ARRAY['true', 'false', 'null'] LOOP
          FOREACH inp IN ARRAY ARRAY['01', '03', '25'] LOOP
            FOREACH pth IN ARRAY ARRAY['catalogue', 'lines'] LOOP
              stored := CASE sv WHEN 'true' THEN true WHEN 'false' THEN false END;
              inval  := CASE inp WHEN '01' THEN true WHEN '03' THEN false ELSE NULL END;
              -- 'filed' = completed, linked to the test manifest, then un-completed (set_visit_status allows it)
              INSERT INTO public.visits (client_id, property_id, visit_date, visit_status, title, derm_required, completed_at)
              VALUES (381, 162, CASE WHEN st = 'filed' THEN DATE '2026-09-14' ELSE DATE '2026-09-20' END,
                      CASE WHEN st = 'scheduled' THEN 'scheduled' ELSE 'completed' END,
                      '[TEST] edit_calendar_visit monotonic probe', stored,
                      CASE WHEN st <> 'scheduled' THEN now() END)
              RETURNING id INTO vid;
              IF st = 'filed' THEN
                INSERT INTO public.manifest_visits (visit_id, manifest_id) VALUES (vid, m_test);
                UPDATE public.visits SET visit_status = 'scheduled', completed_at = NULL WHERE id = vid;
              END IF;
              -- seed a line that differs from every input, so each edit is a real change
              INSERT INTO public.line_items (visit_id, name, quantity, unit_price, total_price)
              VALUES (vid, '22 - Service Call - Labor', 1, 0, 0);
              patch := CASE WHEN pth = 'catalogue'
                         THEN jsonb_build_object('service_line_item_ids',
                                jsonb_build_array(CASE inp WHEN '01' THEN id01 WHEN '03' THEN id03 ELSE id25 END))
                         ELSE jsonb_build_object('line_items', jsonb_build_array(jsonb_build_object('name',
                                CASE inp WHEN '01' THEN t01 WHEN '03' THEN t03 ELSE t25 END, 'quantity', 1, 'unit_price', 0)))
                       END;
              IF fn = 'new' THEN PERFORM public.edit_calendar_visit(vid, patch);
              ELSE PERFORM pg_temp.edit_calendar_visit_old(vid, patch); END IF;
              SELECT derm_required INTO got FROM public.visits WHERE id = vid;
              -- completed or filed: only a promotion moves it; plain scheduled: the full recompute
              want := CASE WHEN st = 'scheduled' THEN inval
                           WHEN inval IS TRUE THEN true
                           ELSE stored END;
              cells := cells + 1;
              IF got IS DISTINCT FROM want THEN
                IF fn = 'new' THEN bad_new := bad_new + 1; r_new := r_new || format('%s/%s/%s/%s got %s want %s; ', st, sv, inp, pth, got, want);
                ELSE bad_old := bad_old + 1; r_old := r_old || format('%s/%s/%s/%s; ', st, sv, inp, pth); END IF;
              END IF;
            END LOOP;
          END LOOP;
        END LOOP;
      END LOOP;
      RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = 'probe rollback';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    END;
  END LOOP;

  IF cells <> 108 THEN RAISE EXCEPTION 'V1: ran % cells, expected 108', cells; END IF;
  IF bad_new <> 0 THEN RAISE EXCEPTION 'V1: new body wrong on % of 54 cells: %', bad_new, r_new; END IF;
  -- the old body writes the new lines' answer on every visit, so on completed AND on filed visits it fails
  -- exactly: stored TRUE with 03 or 25, stored FALSE with 25, stored NULL with 03 = 4 cells x 2 paths x 2
  -- kinds = 16. It must fail those, or the matrix proves nothing.
  IF bad_old <> 16 THEN RAISE EXCEPTION 'V1 control: old body failed % cells (expected 16): %', bad_old, r_old; END IF;
  IF EXISTS (SELECT 1 FROM public.visits WHERE title = '[TEST] edit_calendar_visit monotonic probe') THEN
    RAISE EXCEPTION 'V2: probe rows survived the rollback'; END IF;

  -- V3 ACL, SECURITY DEFINER and the pinned search_path are byte-identical to before (CREATE OR REPLACE keeps
  -- them; asserted rather than assumed), and anon still cannot execute it.
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.edit_calendar_visit(bigint, jsonb)'::regprocedure) IS DISTINCT FROM (SELECT acl FROM _acl_before)
     OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.edit_calendar_visit(bigint, jsonb)'::regprocedure) IS DISTINCT FROM (SELECT prosecdef FROM _acl_before)
     OR (SELECT proconfig::text FROM pg_proc WHERE oid = 'public.edit_calendar_visit(bigint, jsonb)'::regprocedure) IS DISTINCT FROM (SELECT cfg FROM _acl_before)
     OR has_function_privilege('anon', 'public.edit_calendar_visit(bigint, jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'V3: edit_calendar_visit ACL / definer / search_path changed, or anon can execute it'; END IF;
  RAISE NOTICE 'OK: 54/54 cells on the new body; the old body failed %: %', bad_old, r_old;
END
$verify$;

COMMIT;
