-- 2026-08-25_0110_portal_queue_held_visibility.sql
-- ---------------------------------------------------------------------------
-- Make "the queue is empty" distinguishable from "a filing is stuck".
--
-- Jonathan, in-thread 2026-08-25: "could the hourly digest show rows held out by a
-- gate? From our side the queue read empty on the 21st-23rd while 11024 sat excluded,
-- so 'empty' and 'stuck' looked identical. Even a one-line count like '1 row excluded
-- (data-error)' would have saved the archaeology on both ends."
--
-- He is right, and it is the same defect shape as everything else this week:
-- 🛑 A CONFIDENT ZERO THAT CANNOT BE TOLD APART FROM A BROKEN INSTRUMENT.
--    `{"count": 0}` means BOTH "nothing to file" and "one filing is stuck and nobody
--    can see it". GDO-11024 sat excluded for three days behind exactly that zero.
--
-- WHAT THIS ADDS: one view that says, per candidate (visit, permit) pair, why it is
-- not being served. The rpa-derm-queue response gains a `held` block computed from it.
-- The gate logic itself is NOT touched, and `count`/`reports` keep their exact current
-- meaning, so nothing John already parses can break.
--
-- 🛑 THE LABELS MIRROR THE VIEW'S PREDICATES, THEY DO NOT PARAPHRASE THEM.
--    That distinction is not pedantry: `was_blocked_by_gate3` in fn_requeue_derm_portal
--    paraphrased gate 3 by omitting its anchor clause and over-reported on 1 of 59 pairs
--    before it was fixed the same day. Each branch below is copied from
--    pg_get_viewdef(v_derm_portal_queue) rather than re-derived. If a gate ever changes,
--    THIS VIEW MUST CHANGE WITH IT or it will confidently report the wrong reason.
--
-- 🛑 TWO DIFFERENT REASONS FOR ABSENCE, AND CONFLATING THEM WOULD BE A NEW LIE.
--    v_derm_portal_fields holds 59 candidate PAIRS across 37 manifests, but the queue is
--    DISTINCT ON (manifest_id) - one permit per manifest per pass. So a pair can be
--    absent because:
--      (a) a GATE held it            -> a real hold, possibly needing a human
--      (b) a SIBLING permit won      -> nothing is wrong, it comes up next pass
--    13 manifests currently carry 2+ unfiled permits, so (b) is common, not theoretical.
--    Reporting (b) as "held" would send Jonathan hunting a problem that does not exist,
--    which is the exact failure this view exists to prevent. They get separate labels.
--
-- ⚠ Precedence follows the order the view applies the gates, so a pair blocked by two
--   things reports the FIRST one - the same one the operator has to clear first.
--
-- Audit (Rule 8): one view. No table, column, or grant on any audited table changes.
--
-- Grants: service_role (the edge function reads it) plus authenticated, matching the
-- other operational read-only views. It exposes visit/permit ids and a reason string;
-- no client PII beyond the client_code already present throughout the ops surface.
--
-- @Building Apps. Claimed in WORKING-NOW.md.

BEGIN;

CREATE OR REPLACE VIEW public.v_derm_portal_queue_held AS
SELECT
  f.visit_id,
  f.gdo_id,
  f.gdo_number,
  f.manifest_id,
  f.client_code,
  f.visit_date,
  CASE
    -- Not a gate: the view's own WHERE starts here, so anything before the cutoff was
    -- never a candidate at all.
    WHEN NOT (f.visit_date >= rpa_launch_cutoff())
      THEN 'before_launch_cutoff'

    -- gate 1
    WHEN EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                   JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
                  WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run
                    AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id)
                    AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL))
      THEN 'already_filed'

    -- gate 2
    WHEN EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                   JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
                  WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run
                    AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id)
                    AND s.created_at > now() - interval '20 hours')
      THEN 'cooldown_20h'

    -- gate 3, anchor clause INCLUDED. Omitting it is the paraphrase that over-reports.
    WHEN EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                   JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
                  WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run
                    AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id)
                    AND NOT s.retryable AND s.status <> 'SUCCESS'
                    AND s.created_at > GREATEST(f.updated_at, COALESCE((
                          SELECT max(rq.requeued_at) FROM public.derm_portal_requeue rq
                           WHERE rq.manifest_id = f.manifest_id
                             AND (rq.gdo_id IS NULL OR NOT rq.gdo_id IS DISTINCT FROM f.gdo_id)
                        ), '-infinity'::timestamptz)))
      THEN 'data_error'

    -- gate 4
    WHEN EXISTS (SELECT 1 FROM public.derm_portal_leases l
                   JOIN public.manifest_visits lmv ON lmv.visit_id = l.visit_id
                  WHERE lmv.manifest_id = f.manifest_id
                    AND l.leased_at > now() - interval '20 hours')
      THEN 'leased'

    -- Passed every gate and still not served => a sibling permit won the DISTINCT ON.
    -- NOT a problem, and labelled so nobody chases it.
    WHEN NOT EXISTS (SELECT 1 FROM public.v_derm_portal_queue qq
                      WHERE qq.visit_id = f.visit_id
                        AND NOT qq.gdo_id IS DISTINCT FROM f.gdo_id)
      THEN 'sibling_won_this_pass'

    ELSE NULL          -- being served right now
  END AS held_by
FROM public.v_derm_portal_fields f;

COMMENT ON VIEW public.v_derm_portal_queue_held IS
  'Why each candidate (visit, permit) pair is NOT being served by v_derm_portal_queue. held_by IS NULL means it IS being served. Exists because {"count": 0} means both "nothing to file" and "a filing is stuck", and GDO-11024 sat behind that ambiguity for three days (Jonathan, 2026-08-25). ⚠ Each branch MIRRORS a gate predicate from pg_get_viewdef(v_derm_portal_queue) rather than paraphrasing it - gate 3 includes its anchor clause, whose omission elsewhere over-reported on 1 of 59 pairs. If a gate changes, this view must change with it. ⚠ sibling_won_this_pass is NOT a hold: the queue is DISTINCT ON (manifest_id) and 13 manifests carry 2+ unfiled permits, so reporting it as held would send people hunting a problem that does not exist.';

REVOKE ALL ON public.v_derm_portal_queue_held FROM PUBLIC;
REVOKE ALL ON public.v_derm_portal_queue_held FROM anon;
GRANT SELECT ON public.v_derm_portal_queue_held TO authenticated, service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- VERIFY (run after applying)
--
-- 1. every candidate pair is accounted for, and the served ones are exactly the queue
--    select held_by, count(*) from public.v_derm_portal_queue_held group by 1 order by 2 desc;
--    -- ⚠ DO NOT hard-code an expected breakdown here. Mine went stale between writing the
--    --   migration and running it: GDO-11024 was served, filed at 19:19 ET, and flipped from
--    --   the NULL bucket to 'already_filed' while the verification was being written. The
--    --   assertion below (mirror == queue) is the one that is stable, because it compares two
--    --   live reads of the same instant rather than a live read against a remembered number.
--
-- 2. 🛑 THE SERVED SET MUST MATCH THE QUEUE EXACTLY. If these disagree, the mirror has
--    drifted from the gates and every reason it reports is suspect.
--    select (select count(*) from public.v_derm_portal_queue_held where held_by is null) as mirror_served,
--           (select count(*) from public.v_derm_portal_queue) as actual_served;
--    -- expect equal
--
-- 3. POSITIVE CONTROL that the instrument can SEE a hold, not just report zeros:
--    select visit_id, gdo_number, held_by from public.v_derm_portal_queue_held
--     where held_by is not null order by held_by limit 10;
--    -- expect non-empty; 'already_filed' should dominate (most candidates have filed)
--
-- 4. the sibling label is not being used as a dumping ground for real holds
--    select count(*) from public.v_derm_portal_queue_held h
--     where h.held_by = 'sibling_won_this_pass'
--       and not exists (select 1 from public.v_derm_portal_queue qq
--                        where qq.manifest_id = h.manifest_id);
--    -- expect 0: a pair can only be "shadowed by a sibling" if a sibling is ACTUALLY served
--
-- 5. grants: no anon
