-- 2026-10-18_1340 One-time 2026 duration fix: a split pair must not touch at one instant
--
-- WHY. Stage 2 split one parking between visits 6217 and 6223 (Q1/Q5, Fred 2026-10-18) at 2026-09-10 04:03:10 UTC:
-- 6217 departs and 6223 arrives at the same second. public.v_visit_shared_time pairs visits whose intervals overlap
-- with <= (touching counts), so Admin Review still shows both as a shared stop. The resolver meant to set split parts
-- 1 s apart; this pair was missed. Measured: it is the only pair of completed 2026 visits on one truck touching at
-- one instant. Fix: 6223 arrives 1 s later (220 min unchanged), in the visit and in its ledger row, so T7 stays 0.
-- Rollback: the same UPDATE with 04:03:10 (guarded the same way).
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $w$
DECLARE v_hdr text := current_setting('request.headers', true); n int;
BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-fix-2026',
         'x-change-reason', 'One-time 2026 duration fix: split parts of one parking set 1 s apart so they are not read as a shared stop (6217/6223).'))::text, true);
  UPDATE public.visits SET actual_arrival_at = '2026-09-10 04:03:11+00'
   WHERE id = 6223 AND actual_arrival_at = '2026-09-10 04:03:10+00' AND duration_minutes = 220 AND time_on_site_source = 'review';
  GET DIAGNOSTICS n = row_count;
  IF n <> 1 THEN RAISE EXCEPTION 'visit 6223 not in the expected state (% rows)', n; END IF;
  UPDATE public.visit_time_on_site_corrections SET new_arrival = '2026-09-10 04:03:11+00'
   WHERE visit_id = 6223 AND superseded_at IS NULL AND status = 'applied' AND new_arrival = '2026-09-10 04:03:10+00';
  GET DIAGNOSTICS n = row_count;
  IF n <> 1 THEN RAISE EXCEPTION 'ledger row of 6223 not in the expected state (% rows)', n; END IF;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $w$;

DO $v$
DECLARE c jsonb := public.fn_time_on_site_checks(); s int;
BEGIN
  IF (c->>'T7')::int <> 0 OR (c->>'T8')::int <> 0 THEN RAISE EXCEPTION 'T7/T8 not 0: %', c; END IF;
  SELECT shared_with_count INTO s FROM public.v_visit_shared_time WHERE visit_id = 6217;
  IF s <> 0 THEN RAISE EXCEPTION '6217 still shared (%)', s; END IF;
END $v$;

COMMIT;
