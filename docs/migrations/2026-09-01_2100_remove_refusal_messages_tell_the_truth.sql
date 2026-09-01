-- 2026-09-01_2100_remove_refusal_messages_tell_the_truth.sql
--
-- WHY. Fred: "check the refusal shows correctly with two tabs." It does: with the Remove
-- dialog open in tab A, tab B removed the same visit, and tab A's confirm correctly kept
-- the dialog open, kept the card in the list, and rendered the server's own
-- skipped_because text rather than a generic failure.
--
-- The RENDERING was right and the TEXT was wrong. Tab A read:
--     "no such visit, or it was never included"
-- for visit 1542, which exists, and whose inclusion row was sitting there carrying a
-- reason, an included_by, a removed_by and a removed_at. An operator reading that would
-- go looking for a row that is not missing.
--
-- THE CAUSE. The chain keyed "does this visit exist" off `visits_with_review.scope_source`,
-- which is NULL for ANY out-of-scope visit, not just an absent one. So a removed inclusion
-- landed in the arm meant for a bad id.
--
-- AND THE ARM THAT SHOULD HAVE CAUGHT IT WAS UNREACHABLE. The old ELSE read
-- "it was not included, or the inclusion was already removed" and required scope_source to
-- be non-null, not 'convention', and no active inclusion. Measured on live Prod with a
-- control, because a 0 on its own proves nothing:
--     visits reading scope_source='manual' with NO active inclusion   0   <- the ELSE's precondition
--     visits reading scope_source='manual' WITH an active inclusion   1   <- CONTROL, non-empty
-- `scope_source = 'manual'` IS "an active inclusion exists" (the view defines it that way),
-- so that branch could never run. Dead code that read like a handled case.
--
-- WHAT CHANGES. Only the refusal chain in remove_visits_from_review. Existence now comes
-- from the visit lookup (FOUND) and from whether an inclusion ROW exists, so the four
-- refusals are distinguishable and each says one true thing:
--
--   | state                                   | message                                                        |
--   |-----------------------------------------|----------------------------------------------------------------|
--   | no such visit                           | no such visit, or it is soft-deleted                           |
--   | in scope by convention                  | this visit is in the queue because its job follows ...          |
--   | inclusion row exists, already removed   | the inclusion was already removed                              |
--   | no inclusion row, not convention        | this visit was never included in the queue                     |
--
-- The convention arm is deliberately checked BEFORE the already-removed arm: when both are
-- true, "removing an inclusion would not take this out of the queue" is the fact the caller
-- needs. Ordering is asserted in VERIFY 6.
--
-- NO BEHAVIOUR CHANGE beyond the wording: the same calls are refused, the same calls
-- succeed, and `removed` counts are untouched. The body was copied from 2026-09-01_1900
-- rather than retyped (CLAUDE.md rule); the diff is three hunks.
--
-- RULE 8 (audit): no new table, no trigger change. public.review_scope_inclusions keeps
-- audit_review_scope_inclusions.
--
-- NO APP CHANGE NEEDED: the app already renders whatever skipped_because it is handed,
-- which is exactly why fixing it here is enough.

create or replace function public.remove_visits_from_review(
  p_visit_ids bigint[],
  p_reason    text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_reason text;
  v_actor  text;
  v_id     bigint;
  v_out    jsonb := '[]'::jsonb;
  v_src    text;
  v_work   boolean;
  v_active boolean;
  v_row    boolean;
  v_exists  boolean;
BEGIN
  v_reason := btrim(translate(coalesce(p_reason,''), chr(9)||chr(10)||chr(13)||chr(160), '    '), ' ');

  IF p_visit_ids IS NULL OR array_length(p_visit_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'remove_visits_from_review: no visits were passed' USING ERRCODE = '22023';
  END IF;

  BEGIN
    v_actor := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email';
  EXCEPTION WHEN others THEN
    v_actor := NULL;
  END;
  v_actor := coalesce(nullif(v_actor,''), session_user);

  FOREACH v_id IN ARRAY p_visit_ids LOOP
    SELECT w.scope_source, w.review_work_started INTO v_src, v_work
      FROM public.visits_with_review w WHERE w.id = v_id;
    v_exists := FOUND;
    SELECT (inc.visit_id IS NOT NULL AND inc.removed_at IS NULL),
           (inc.visit_id IS NOT NULL)
      INTO v_active, v_row
      FROM public.review_scope_inclusions inc WHERE inc.visit_id = v_id;

    -- 2026-09-01_2100. This chain used to key "does the visit exist" off scope_source,
    -- which is NULL for ANY out-of-scope visit. A visit whose inclusion had been REMOVED
    -- therefore took the first arm and was told it had never been included, while its
    -- inclusion row sat there carrying a reason, a removed_by and a removed_at. Observed
    -- live in a two-tab race: tab B removed the visit, tab A confirmed a moment later and
    -- read "no such visit, or it was never included".
    -- The old ELSE ("it was not included, or the inclusion was already removed") was
    -- UNREACHABLE: it needed scope_source non-null, not 'convention', and no active
    -- inclusion, but scope_source = 'manual' IS "an active inclusion exists" (measured:
    -- 0 visits read 'manual' without one, against a control of 1 that does).
    -- Existence now comes from the visit lookup and the row lookup, so the four cases are
    -- distinguishable and each gets its own sentence.
    IF NOT coalesce(v_exists,false) THEN
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', false,
                 'skipped_because', 'no such visit, or it is soft-deleted');
    ELSIF NOT coalesce(v_active,false) AND v_src = 'convention' THEN
      -- Checked BEFORE the already-removed arm: when both are true this is the one that
      -- explains why removing anything would not help, which is what the caller needs.
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', false,
                 'skipped_because', 'this visit is in the queue because its job follows the convention, not because it was included');
    ELSIF NOT coalesce(v_active,false) AND coalesce(v_row,false) THEN
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', false,
                 'skipped_because', 'the inclusion was already removed');
    ELSIF NOT coalesce(v_active,false) THEN
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', false,
                 'skipped_because', 'this visit was never included in the queue');
    ELSIF coalesce(v_work,false) AND v_reason = '' THEN
      -- Fred's rule: one click while nothing has been done, a reason once it has.
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', false,
                 'skipped_because', 'work has already been done on this visit, so a reason is required to take it back out');
    ELSE
      UPDATE public.review_scope_inclusions
         SET removed_at = now(), removed_by = v_actor,
             removed_reason = nullif(v_reason,'')
       WHERE visit_id = v_id AND removed_at IS NULL;
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', true,
                 'skipped_because', NULL);
    END IF;

    v_out := jsonb_set(v_out, ARRAY[(jsonb_array_length(v_out)-1)::text, 'in_scope_now'],
             to_jsonb(coalesce((SELECT w.in_review_scope FROM public.visits_with_review w WHERE w.id = v_id), false)));
  END LOOP;

  RETURN jsonb_build_object(
    'requested', array_length(p_visit_ids,1),
    'removed',   (SELECT count(*) FROM jsonb_array_elements(v_out) e WHERE (e->>'removed')::boolean),
    'by',        v_actor,
    'results',   v_out);
END $function$;

comment on function public.remove_visits_from_review(bigint[], text) is
  'Reverse a manual inclusion. Soft: the row is kept with removed_at/by/reason. A reason is required ONLY when review_work_started is true (classified photos or a real decision), per Fred 2026-09-01. Refuses a visit that is in the queue on its own merits, because removing an inclusion would not take it out. Partial per visit: read results[] and render skipped_because rather than assuming success. Since 2026-09-01_2100 the four refusals are distinguishable (absent visit / convention / already removed / never included); before that a removed inclusion was wrongly reported as a visit that never existed.';


-- ---------------------------------------------------------------------------
-- VERIFY. Every mutation is inside a BEGIN..EXCEPTION block, which is a real SAVEPOINT:
-- the deliberate RAISE unwinds it while the CREATE OR REPLACE above stays committed.
-- Findings are collected in variables declared OUTSIDE that block, because variable
-- assignments are not transactional and survive the unwind.
-- ---------------------------------------------------------------------------
DO $verify$
DECLARE
  fails    text := '';
  notes    text := '';
  v_a      bigint;   -- will be included then removed
  v_b      bigint;   -- never included
  v_conv   bigint;   -- in scope by convention
  v_before integer;
  v_after  integer;
  v_old    boolean;
  r        jsonb;
  msg      text;
BEGIN
  SELECT count(*) INTO v_before FROM public.review_scope_inclusions;

  BEGIN
    SELECT w.id INTO v_a FROM public.visits_with_review w
      WHERE w.visit_status='completed' AND NOT w.in_review_scope
        AND NOT EXISTS (SELECT 1 FROM public.review_scope_inclusions i WHERE i.visit_id=w.id)
      ORDER BY w.id DESC LIMIT 1;
    SELECT w.id INTO v_b FROM public.visits_with_review w
      WHERE w.visit_status='completed' AND NOT w.in_review_scope AND w.id <> v_a
        AND NOT EXISTS (SELECT 1 FROM public.review_scope_inclusions i WHERE i.visit_id=w.id)
      ORDER BY w.id DESC LIMIT 1;
    SELECT w.id INTO v_conv FROM public.visits_with_review w
      WHERE w.visit_status='completed' AND w.scope_source='convention'
      ORDER BY w.id DESC LIMIT 1;
    IF v_a IS NULL OR v_b IS NULL OR v_conv IS NULL THEN
      fails := fails || 'subjects unavailable, the probe proves nothing; ';
    END IF;
    notes := notes || format('A=V-%s B=V-%s conv=V-%s | ', v_a, v_b, v_conv);

    -- arrange: A is included, then removed, so its row EXISTS and is inactive
    PERFORM public.include_visits_in_review(ARRAY[v_a]::bigint[], 'verify 2100 arrange');
    PERFORM public.remove_visits_from_review(ARRAY[v_a]::bigint[], 'verify 2100 arrange removal');

    -- POSITIVE CONTROL: the OLD predicate must misclassify this exact row. Without this,
    -- the assertions below could pass against a defect that never existed.
    SELECT (w.scope_source IS NULL) AND NOT coalesce(
             (SELECT (i.visit_id IS NOT NULL AND i.removed_at IS NULL)
                FROM public.review_scope_inclusions i WHERE i.visit_id = w.id), false)
      INTO v_old FROM public.visits_with_review w WHERE w.id = v_a;
    IF v_old IS NOT TRUE THEN
      fails := fails || 'CONTROL: the old predicate does NOT take the wrong arm here, so this migration is not testing the reported defect; ';
    END IF;

    -- 1. THE FIX: an already-removed inclusion says so, and does not claim the visit is absent
    msg := public.remove_visits_from_review(ARRAY[v_a]::bigint[], NULL)->'results'->0->>'skipped_because';
    IF msg IS DISTINCT FROM 'the inclusion was already removed' THEN
      fails := fails || format('1: already-removed said "%s"; ', msg);
    END IF;

    -- 2. a visit that never had a row, and whose job is not convention
    msg := public.remove_visits_from_review(ARRAY[v_b]::bigint[], NULL)->'results'->0->>'skipped_because';
    IF msg IS DISTINCT FROM 'this visit was never included in the queue' THEN
      fails := fails || format('2: never-included said "%s"; ', msg);
    END IF;

    -- 3. an id that is not a visit at all
    msg := public.remove_visits_from_review(ARRAY[-1]::bigint[], NULL)->'results'->0->>'skipped_because';
    IF msg IS DISTINCT FROM 'no such visit, or it is soft-deleted' THEN
      fails := fails || format('3: absent visit said "%s"; ', msg);
    END IF;

    -- 4. a convention visit is still refused with the convention sentence
    msg := public.remove_visits_from_review(ARRAY[v_conv]::bigint[], NULL)->'results'->0->>'skipped_because';
    IF msg NOT LIKE '%follows the convention%' THEN
      fails := fails || format('4: convention visit said "%s"; ', msg);
    END IF;

    -- 5. the happy path still removes, and the reason gate is untouched
    PERFORM public.include_visits_in_review(ARRAY[v_b]::bigint[], 'verify 2100 happy path');
    r := public.remove_visits_from_review(ARRAY[v_b]::bigint[], 'verify 2100 removal');
    IF (r->>'removed')::int <> 1 THEN
      fails := fails || format('5: the happy path stopped removing (%s); ', r);
    END IF;

    -- 6. ORDERING: a convention visit that ALSO carries a removed inclusion row must get
    --    the convention sentence, not the already-removed one. Both are true; only one is
    --    useful, because removing an inclusion would not take it out of the queue.
    INSERT INTO public.review_scope_inclusions (visit_id, reason, included_by, removed_at, removed_by)
    VALUES (v_conv, 'verify 2100 ordering', 'verify', now(), 'verify');
    msg := public.remove_visits_from_review(ARRAY[v_conv]::bigint[], NULL)->'results'->0->>'skipped_because';
    IF msg NOT LIKE '%follows the convention%' THEN
      fails := fails || format('6: ordering wrong, a convention visit with a removed row said "%s"; ', msg);
    END IF;

    RAISE EXCEPTION 'ROLLBACK_PROBE';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'ROLLBACK_PROBE' THEN
      fails := fails || format('UNEXPECTED %s: %s; ', SQLSTATE, SQLERRM);
    END IF;
  END;

  -- 7. nothing leaked
  SELECT count(*) INTO v_after FROM public.review_scope_inclusions;
  IF v_after <> v_before THEN
    fails := fails || format('7: probe leaked rows, %s before and %s after; ', v_before, v_after);
  END IF;

  -- 8. grants survived CREATE OR REPLACE
  IF NOT has_function_privilege('authenticated','public.remove_visits_from_review(bigint[], text)','EXECUTE') THEN
    fails := fails || '8: authenticated lost EXECUTE; ';
  END IF;
  IF has_function_privilege('anon','public.remove_visits_from_review(bigint[], text)','EXECUTE') THEN
    fails := fails || '8b: anon can EXECUTE it; ';
  END IF;

  IF fails <> '' THEN
    RAISE EXCEPTION 'VERIFY FAILED >>> % [%]', fails, notes;
  END IF;
  RAISE NOTICE 'VERIFY OK >>> %', notes;
END $verify$;
