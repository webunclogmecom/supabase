-- 2026-09-01_2000_include_revives_a_removed_inclusion.sql
--
-- WHY. 2026-09-01_1900 made a manual inclusion removable by SOFT-removing its row
-- (removed_at / removed_by / removed_reason) and teaching in_review_scope to require
-- removed_at IS NULL. It did not touch include_visits_in_review, which still does a bare
-- INSERT against a table whose PRIMARY KEY is visit_id. So a removed visit reads
-- out-of-scope, reaches the INSERT branch, and collides.
--
-- MEASURED BEFORE THE FIX, in a rolled-back probe with a positive control:
--   subject V-7375 | include#1 included=1 | remove removed=1 in_scope_now=false
--   CONTROL V-7279 included=1                       <- the include path was healthy
--   RE-INCLUDE RAISED 23505: duplicate key value violates unique constraint
--                            "review_scope_inclusions_pkey"
-- The control is what makes that meaningful: the failure is about the REMOVED row, not
-- about a broken probe.
--
-- TWO CONSEQUENCES, and the second is worse than the first:
--   1. Removal was ONE-WAY. An operator who removed a visit by mistake could never put it
--      back, which is precisely the "we made a mistake" case 1900 was built to answer.
--   2. The raise is NOT caught per visit. include_visits_in_review is partial by design --
--      each visit gets its own verdict -- but a 23505 aborts the whole function, so ONE
--      previously removed visit in a batch of ten killed the other nine and surfaced a raw
--      duplicate-key string in the app.
--
-- WHAT CHANGES. Only the INSERT branch of include_visits_in_review. A row that exists and
-- is removed is REVIVED (removal columns cleared, new reason and actor recorded,
-- included_at restamped); a visit with no row still INSERTs exactly as before. Every other
-- byte of the function is the 1800 body, copied rather than retyped (CLAUDE.md rule) and
-- diffed to two hunks: the v_revived declaration and this branch.
--
-- WHAT DOES NOT CHANGE. The active-inclusion refusal ('already in the review queue') still
-- fires first, because in_review_scope is true for an active row, so the revive branch is
-- unreachable for one. The reason is still required on every include. remove_visits_from_review,
-- in_review_scope, scope_source, review_work_started and v_review_scope_picker are untouched.
--
-- RULE 8 (audit): no new table. public.review_scope_inclusions already carries
-- audit_review_scope_inclusions (verified: 1 trigger), so include -> remove -> include is
-- recoverable from audit.logs.old_row even though the row itself only holds the latest state.
--
-- Grants unchanged: CREATE OR REPLACE keeps them, and the VERIFY re-asserts EXECUTE.

create or replace function public.include_visits_in_review(
  p_visit_ids bigint[],
  p_reason    text
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_reason  text;
  v_actor   text;
  v_id      bigint;
  v_out     jsonb := '[]'::jsonb;
  v_status  text;
  v_scope   boolean;
  v_ok      boolean;
  v_revived boolean;
BEGIN
  -- Same whitespace class as the CHECK and as fn_requeue_derm_portal.
  v_reason := btrim(translate(coalesce(p_reason,''), chr(9)||chr(10)||chr(13)||chr(160), '    '), ' ');
  IF v_reason = '' THEN
    RAISE EXCEPTION 'include_visits_in_review: a reason is required - the next person to read this row has to know why a pre-convention visit was pulled into the queue'
      USING ERRCODE = '22023';
  END IF;

  IF p_visit_ids IS NULL OR array_length(p_visit_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'include_visits_in_review: no visits were passed'
      USING ERRCODE = '22023';
  END IF;

  -- Prefer the JWT over anything the caller could supply. Same shape as
  -- fn_requeue_derm_portal. NOTE request.jwt.claims, PLURAL: the singular key is never
  -- set by PostgREST, which is why audit.logs.changed_by has been NULL on every row.
  BEGIN
    v_actor := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email';
  EXCEPTION WHEN others THEN
    v_actor := NULL;
  END;
  v_actor := coalesce(nullif(v_actor,''), session_user);

  -- PARTIAL, not all-or-nothing: one already-in-scope visit in a batch of ten must not
  -- abort the other nine. Every requested visit gets its own verdict, and the caller
  -- renders them, so a partly applied batch is visible rather than assumed.
  FOREACH v_id IN ARRAY p_visit_ids LOOP
    SELECT w.visit_status, w.in_review_scope INTO v_status, v_scope
      FROM public.visits_with_review w WHERE w.id = v_id;

    v_ok := false;
    IF v_status IS NULL THEN
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'included', false,
                 'skipped_because', 'no such visit, or it is soft-deleted');
    ELSIF v_status <> 'completed' THEN
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'included', false,
                 'skipped_because', format('visit is %s, and the queue only reviews completed visits', v_status));
    ELSIF v_scope THEN
      -- An inclusion that changes nothing while reporting success is the "operator
      -- believes they acted" failure fn_requeue_derm_portal exists to prevent.
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'included', false,
                 'skipped_because', 'already in the review queue');
    ELSE
      -- 2026-09-01_2000. A row can already EXIST and be soft-removed. in_review_scope
      -- requires removed_at IS NULL, so such a visit arrives here reading out-of-scope,
      -- and the bare INSERT below raised 23505 against the visit_id PRIMARY KEY. That
      -- error is not caught per visit, so it aborted the WHOLE batch: one previously
      -- removed visit in a batch of ten killed the other nine, and removal was one-way.
      -- Reset per iteration: a stale true from the previous visit would skip the INSERT
      -- and report an inclusion that never happened.
      v_revived := NULL;
      SELECT (inc.removed_at IS NOT NULL) INTO v_revived
        FROM public.review_scope_inclusions inc WHERE inc.visit_id = v_id;

      IF v_revived THEN
        -- Revive rather than insert. The table is audited, so include -> remove ->
        -- include stays legible in audit.logs.old_row even though the row itself only
        -- ever holds the latest state. The removed_at IS NOT NULL predicate is repeated
        -- on the UPDATE so it cannot rewrite an ACTIVE inclusion's reason if the world
        -- changed between the read and the write.
        UPDATE public.review_scope_inclusions
           SET removed_at = NULL, removed_by = NULL, removed_reason = NULL,
               reason = v_reason, included_by = v_actor, included_at = now()
         WHERE visit_id = v_id AND removed_at IS NOT NULL;
      ELSE
        INSERT INTO public.review_scope_inclusions (visit_id, reason, included_by)
        VALUES (v_id, v_reason, v_actor);
      END IF;

      v_ok := true;
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'included', true,
                 'skipped_because', NULL);
    END IF;

    -- Report the POST-CONDITION, not "ok".
    v_out := jsonb_set(v_out, ARRAY[(jsonb_array_length(v_out)-1)::text, 'in_scope_now'],
             to_jsonb(coalesce((SELECT w.in_review_scope FROM public.visits_with_review w WHERE w.id = v_id), false)));
  END LOOP;

  RETURN jsonb_build_object(
    'requested', array_length(p_visit_ids,1),
    'included',  (SELECT count(*) FROM jsonb_array_elements(v_out) e WHERE (e->>'included')::boolean),
    'reason',    v_reason,
    'by',        v_actor,
    'results',   v_out);
END $function$;

comment on function public.include_visits_in_review(bigint[], text) is
  'Pull completed visits into the Admin Review queue despite their job predating the Service Agreement / Service Call naming convention. A reason is required. Partial by design: each visit carries its own verdict in results[], so render them rather than assuming success. A visit whose inclusion was previously removed by remove_visits_from_review is REVIVED rather than re-inserted (2026-09-01_2000): the bare INSERT collided with the visit_id primary key and aborted the whole batch.';

comment on table public.review_scope_inclusions is
  'One row per visit deliberately pulled into the Admin Review queue despite its job predating the Service Agreement / Service Call naming convention. One row per visit, for ever: the PK on visit_id makes inclusion idempotent. Removal is SOFT (removed_at / removed_by / removed_reason, 2026-09-01_1900) and re-inclusion REVIVES the same row (2026-09-01_2000), so the row holds only the latest state and the include/remove history lives in audit.logs.';


-- ---------------------------------------------------------------------------
-- VERIFY
--
-- Every mutation below happens inside a BEGIN..EXCEPTION block, which is a real
-- SAVEPOINT: the deliberate RAISE at the end unwinds all of it while the CREATE OR
-- REPLACE above stays committed. A bare DO block COMMITS, so the savepoint is the whole
-- reason this is safe to run against Prod. Findings are collected into a variable declared
-- OUTSIDE that block, because variable assignments are not transactional and therefore
-- survive the unwind.
-- ---------------------------------------------------------------------------
DO $verify$
DECLARE
  fails    text := '';
  notes    text := '';
  v_a      bigint;
  v_b      bigint;
  v_before integer;
  v_after  integer;
  r        jsonb;
BEGIN
  SELECT count(*) INTO v_before FROM public.review_scope_inclusions;

  BEGIN
    -- Two throwaway subjects: completed, out of scope, never included.
    SELECT w.id INTO v_a FROM public.visits_with_review w
      WHERE w.visit_status = 'completed' AND NOT w.in_review_scope
        AND NOT EXISTS (SELECT 1 FROM public.review_scope_inclusions i WHERE i.visit_id = w.id)
      ORDER BY w.id DESC LIMIT 1;
    SELECT w.id INTO v_b FROM public.visits_with_review w
      WHERE w.visit_status = 'completed' AND NOT w.in_review_scope AND w.id <> v_a
        AND NOT EXISTS (SELECT 1 FROM public.review_scope_inclusions i WHERE i.visit_id = w.id)
      ORDER BY w.id DESC LIMIT 1;
    IF v_a IS NULL OR v_b IS NULL THEN
      fails := fails || 'no out-of-scope subjects available, the probe proves nothing; ';
    END IF;
    notes := notes || format('subjects A=V-%s B=V-%s | ', v_a, v_b);

    -- 1. plain include still works (the branch this migration did NOT touch)
    r := public.include_visits_in_review(ARRAY[v_a]::bigint[], 'verify: first include');
    IF (r->>'included')::int <> 1 OR (r->'results'->0->>'in_scope_now')::boolean IS NOT TRUE THEN
      fails := fails || format('1: plain include did not put V-%s in scope (%s); ', v_a, r);
    END IF;

    -- 2. removal still works
    r := public.remove_visits_from_review(ARRAY[v_a]::bigint[], 'verify: removal');
    IF (r->>'removed')::int <> 1 OR (r->'results'->0->>'in_scope_now')::boolean IS NOT FALSE THEN
      fails := fails || format('2: removal did not take V-%s out of scope (%s); ', v_a, r);
    END IF;

    -- 3. THE FIX. Before this migration this raised 23505 and aborted the function.
    r := public.include_visits_in_review(ARRAY[v_a]::bigint[], 'verify: revive');
    IF (r->>'included')::int <> 1 OR (r->'results'->0->>'in_scope_now')::boolean IS NOT TRUE THEN
      fails := fails || format('3: re-include after removal failed for V-%s (%s); ', v_a, r);
    END IF;

    -- 4. the revived row is a real inclusion, not a half-cleared one
    IF NOT EXISTS (
      SELECT 1 FROM public.review_scope_inclusions
       WHERE visit_id = v_a AND removed_at IS NULL AND removed_by IS NULL
         AND removed_reason IS NULL AND reason = 'verify: revive' AND included_by IS NOT NULL)
    THEN
      fails := fails || format('4: revived row for V-%s is not fully reset; ', v_a);
    END IF;

    -- 5. an ACTIVE inclusion is still refused rather than silently re-stamped, and the
    --    batch does NOT abort. This is the regression the 23505 used to cause: one bad
    --    visit killed every other visit in the call.
    r := public.include_visits_in_review(ARRAY[v_a, v_b]::bigint[], 'verify: batch');
    IF (r->>'requested')::int <> 2 OR (r->>'included')::int <> 1 THEN
      fails := fails || format('5: batch should include exactly 1 of 2 (%s); ', r);
    END IF;
    IF (r->'results'->0->>'skipped_because') IS DISTINCT FROM 'already in the review queue' THEN
      fails := fails || format('5b: active inclusion was not refused with the expected reason (%s); ',
                               r->'results'->0->>'skipped_because');
    END IF;

    -- 6. removing something already removed still changes nothing. Asserted on the COUNT,
    --    not on the message text: paraphrasing the rule into the assertion is how a check
    --    starts passing for the wrong reason.
    PERFORM public.remove_visits_from_review(ARRAY[v_a]::bigint[], 'verify: remove for the second time');
    r := public.remove_visits_from_review(ARRAY[v_a]::bigint[], 'verify: remove for the third time');
    IF (r->>'removed')::int <> 0 THEN
      fails := fails || format('6: a repeat removal reported %s removed; ', r->>'removed');
    END IF;

    -- 7. the audit trail actually captured this. The revive is an UPDATE, and the whole
    --    argument for keeping one row per visit is that audit.logs holds the history.
    IF (SELECT count(*) FROM audit.logs
          WHERE table_name = 'review_scope_inclusions'
            AND changed_at > now() - interval '2 minutes') < 3 THEN
      fails := fails || '7: fewer than 3 audit rows for this probe, the history is not being kept; ';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_PROBE';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'ROLLBACK_PROBE' THEN
      fails := fails || format('UNEXPECTED %s: %s; ', SQLSTATE, SQLERRM);
    END IF;
  END;

  -- 8. the probe left nothing behind
  SELECT count(*) INTO v_after FROM public.review_scope_inclusions;
  IF v_after <> v_before THEN
    fails := fails || format('8: probe leaked rows, %s before and %s after; ', v_before, v_after);
  END IF;

  -- 9. grants survived CREATE OR REPLACE
  IF NOT has_function_privilege('authenticated','public.include_visits_in_review(bigint[], text)','EXECUTE')
     OR NOT has_function_privilege('authenticated','public.remove_visits_from_review(bigint[], text)','EXECUTE') THEN
    fails := fails || '9: authenticated lost EXECUTE on one of the two RPCs; ';
  END IF;
  IF has_function_privilege('anon','public.include_visits_in_review(bigint[], text)','EXECUTE') THEN
    fails := fails || '9b: anon can EXECUTE the include RPC; ';
  END IF;

  IF fails <> '' THEN
    RAISE EXCEPTION 'VERIFY FAILED >>> % [%]', fails, notes;
  END IF;
  RAISE NOTICE 'VERIFY OK >>> %', notes;
END $verify$;
