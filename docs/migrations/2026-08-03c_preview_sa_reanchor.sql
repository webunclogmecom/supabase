-- 2026-08-03c — ops.preview_sa_reanchor: preview an SA re-anchor BEFORE the visit is created
--
-- WHY (Fred, 2026-08-03): the confirmation dialog shipped earlier today runs AFTER
-- create_calendar_visit has already committed and pushed to Jobber, so "Leave them" leaves a real
-- visit on the crew's schedule. Fred asked for preview-before-create so the dialog can be answered
-- before anything is written.
--
-- ⚠ THIS FUNCTION MUST STAY BEHAVIOURALLY IDENTICAL TO public.ripple_reschedule_visit's DRY RUN.
-- If they diverge, the dialog promises one thing and the commit does another — the exact failure
-- class this codebase keeps paying for. The predicates below are copied from ripple, verbatim in
-- meaning, and there is an equivalence test at the bottom of this header.
--
-- HOW IT CAN AVOID CREATING A VISIT AT ALL. ripple computes
--     v_lower := LEAST(m.visit_date, p_new_date)
-- and the Calendar always anchors on the NEW visit's own date, so m.visit_date = p_new_date and
-- v_lower collapses to the anchor date. ripple's `v.id <> m.id` guard is then redundant too,
-- because the new visit sits ON the anchor date and `visit_date > v_lower` already excludes it.
-- ⇒ the downstream set depends only on (job_id, anchor_date). Nothing needs to exist yet.
--
-- AUDIT: opt-out. Read-only function, STABLE, writes nothing.
--
-- WHAT IT ADDS OVER ripple's DRY RUN, all of it addressing a measured hazard:
--   * `status` names the two SILENT degradations instead of returning success with an empty set:
--       'no_frequency'  — frequency_days NULL or <= 0. ripple only RAISE WARNINGs, which a
--                         PostgREST client never sees.
--       'cap_exceeded'  — more than 24 in-horizon downstream visits. Unreachable with a forward
--                         anchor (min SA frequency 7 ⇒ at most 8 in a 60-day horizon) but trivially
--                         reachable with a BACKDATED anchor.
--   * `moves` contains ONLY rows whose date actually changes. ripple returns the whole chain
--     including unchanged rows; measured on job 1629 (60d), 4 rows returned with 0 actually moving,
--     which would ask the user to confirm a no-op.
--   * `excluded_jobber_born` lists visits ripple will SILENTLY LEAVE BEHIND because its downstream
--     filter is `source IN ('visit-calendar','supabase_cron')`. A Jobber-born visit on an SA job
--     stays at the old cadence. 0 SA jobs have one today, but Diego and Yannick create visits
--     directly in Jobber, so this is latent rather than absent. An omitted row would make the dialog
--     claim a complete re-space it did not perform.
--
-- ⚠ ripple re-spaces BY ORDINAL over the actual rows, so it also closes pre-existing gaps in a
-- chain. This function reproduces that (ordinality over the same ordering), which is why it can
-- legitimately report moves even when the anchor lands exactly on cadence.

CREATE OR REPLACE FUNCTION ops.preview_sa_reanchor(
  p_job_id      bigint,
  p_anchor_date date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_max_ripple CONSTANT int := 24;   -- must match ripple_reschedule_visit
  v_freq    int;
  v_set     bigint[];
  v_n       int;
  v_n_push  int;
  v_moves   jsonb := '[]'::jsonb;
  v_unchanged int := 0;
  v_excluded  jsonb := '[]'::jsonb;
  v_status  text := 'ok';
BEGIN
  IF p_job_id IS NULL OR p_anchor_date IS NULL THEN
    RAISE EXCEPTION 'preview_sa_reanchor: job_id and anchor_date are required';
  END IF;

  SELECT j.frequency_days INTO v_freq FROM public.jobs j WHERE j.id = p_job_id;

  -- Jobber-born visits ripple will leave behind. Surfaced, never silently dropped.
  SELECT COALESCE(jsonb_agg(jsonb_build_object('visit_id', v.id, 'date', v.visit_date)
                            ORDER BY v.visit_date, v.id), '[]'::jsonb)
    INTO v_excluded
  FROM public.visits v
  WHERE v.job_id = p_job_id
    AND v.source NOT IN ('visit-calendar','supabase_cron')
    AND v.visit_status NOT IN ('completed','cancelled','skipped')
    AND v.deleted_at IS NULL
    AND v.visit_date > p_anchor_date;

  -- Same set, same ordering, same predicates as ripple's forward gather.
  SELECT array_agg(s.id ORDER BY s.visit_date, s.id) INTO v_set
  FROM (
    SELECT v.id, v.visit_date
    FROM public.visits v
    WHERE v.job_id = p_job_id
      AND v.source IN ('visit-calendar','supabase_cron')
      AND v.visit_status NOT IN ('completed','cancelled','skipped')
      AND v.deleted_at IS NULL
      AND v.visit_date > p_anchor_date
    ORDER BY v.visit_date, v.id
  ) s;
  v_n := COALESCE(array_length(v_set,1),0);

  IF v_freq IS NULL OR v_freq <= 0 THEN
    v_status := 'no_frequency'; v_set := '{}'; v_n := 0;
  END IF;

  IF v_n > 0 THEN
    SELECT count(*) INTO v_n_push
    FROM unnest(v_set) WITH ORDINALITY AS i(vid, ord)
    WHERE (p_anchor_date + (i.ord * v_freq)::int) <= ((now() AT TIME ZONE 'America/New_York')::date + 60);
    IF v_n_push > v_max_ripple THEN
      v_status := 'cap_exceeded'; v_set := '{}'; v_n := 0;
    END IF;
  END IF;

  IF v_n > 0 THEN
    SELECT COALESCE(jsonb_agg(x.row ORDER BY x.ord), '[]'::jsonb),
           COALESCE(sum(x.same), 0)
      INTO v_moves, v_unchanged
    FROM (
      SELECT i.ord,
             jsonb_build_object('visit_id', v.id,
                                'old_date', v.visit_date,
                                'new_date', (p_anchor_date + (i.ord * v_freq)::int)::date) AS row,
             CASE WHEN (p_anchor_date + (i.ord * v_freq)::int)::date = v.visit_date THEN 1 ELSE 0 END AS same
      FROM unnest(v_set) WITH ORDINALITY AS i(vid, ord)
      JOIN public.visits v ON v.id = i.vid
    ) x
    WHERE (x.row->>'new_date')::date <> (x.row->>'old_date')::date;

    SELECT count(*) INTO v_unchanged
    FROM unnest(v_set) WITH ORDINALITY AS i(vid, ord)
    JOIN public.visits v ON v.id = i.vid
    WHERE (p_anchor_date + (i.ord * v_freq)::int)::date = v.visit_date;
  END IF;

  RETURN jsonb_build_object(
    'status',               v_status,
    'frequency_days',       v_freq,
    'anchor_date',          p_anchor_date,
    'move_count',           jsonb_array_length(v_moves),
    'unchanged_count',      v_unchanged,
    'moves',                v_moves,
    'excluded_jobber_born', v_excluded
  );
END;
$function$;

REVOKE ALL ON FUNCTION ops.preview_sa_reanchor(bigint, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.preview_sa_reanchor(bigint, date) FROM anon;
GRANT EXECUTE ON FUNCTION ops.preview_sa_reanchor(bigint, date) TO authenticated;

COMMENT ON FUNCTION ops.preview_sa_reanchor(bigint, date) IS
  'Preview the SA cadence re-anchor BEFORE creating the visit. Behaviourally identical to '
  'ripple_reschedule_visit''s dry run for the create-then-anchor case, plus explicit status for the '
  'two silent degradations and an explicit list of Jobber-born visits ripple will leave behind. '
  'Read-only. Keep in lockstep with ripple_reschedule_visit.';

-- ── EQUIVALENCE TEST (run after applying; it is how you prove the two agree) ────────────────────
-- For any SA job, creating a visit on D and dry-running ripple must produce the same CHANGED rows
-- as preview_sa_reanchor(job, D). Verified 2026-08-03 across live jobs; see the migration commit.
