-- ============================================================================
-- 2026-11-03_rollback_time_on_site_s3b_overrides_stages_viktor  Undo 2026-11-03_1500 (re-check S3b part 1)
-- ============================================================================
-- WHAT IT DOES: viktor_set_visit_truck back to its pre-S3b body by the reverse anchored edit (pinned on md5 c7cbae66a7d33503688138224cc96feb,
--   back to a07204ef5ad74e0f8d397f2ee1989fdd); the ledger's stage CHECK back to ('2','3','4','catch_up'), refused while a 'nightly' or 'person'
--   row exists (then keep the CHECK, as plan 5.5 b says); the overrides table dropped (its 5 rows are in the forward
--   file; audit.logs holds the inserts). Nothing is written to any visit.
-- REHEARSED: on top of the forward file, rolled back (S3b/rehearse1.mjs r, local).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF to_regclass('public.time_on_site_site_overrides') IS NULL THEN RAISE EXCEPTION 'S3b rollback: the overrides table does not exist (S3b part 1 is not applied)'; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections WHERE stage IN ('nightly', 'person')) THEN
    RAISE EXCEPTION 'S3b rollback: nightly or person ledger rows exist; keep the stage CHECK (plan 5.5 b) and roll back the rest by hand'; END IF;
END $pin$;

DO $vk$
DECLARE
  d text := pg_get_functiondef('public.viktor_set_visit_truck(bigint,text,text,text,boolean)'::regprocedure);
  n text;
  a1 text := $a$  -- 2026-11-03_1500 (re-check S3b, RC6): no any-truck fill here. Right after a person names the truck, another
  -- truck's time is the wrong answer by definition; fn_compute_time_on_site above measures the named truck.
$a$;
  b1 text := $b$  perform public.fn_fill_blank_time_on_site(v.visit_date, v.visit_date + 1, true);
$b$;
  a2 text := $a$      || case
           -- 2026-11-03_1500 (re-check S3b, RC8): say what really happened. A locked time (Fred, Q-E) is not re-measured
           -- by a truck change; a visit of the last 10 days can still be corrected by the nightly Samsara check.
           when public.fn_time_on_site_is_locked(v.id) and v_after.duration_minutes is not null
             then format('Time on site stays %s min: it is a settled value, so a truck change does not re-measure it.', v_after.duration_minutes)
           when public.fn_time_on_site_is_locked(v.id)
             then 'Time on site stays empty: it is a settled value, so a truck change does not re-measure it.'
           when v_after.duration_minutes is not null
             then format('Time on site: %s min (%s to %s).', v_after.duration_minutes,
                          to_char(v_after.actual_arrival_at at time zone 'America/New_York', 'FMHH12:MI AM'),
                          to_char(v_after.actual_departure_at at time zone 'America/New_York', 'FMHH12:MI AM'))
                  || case when v.visit_date >= (now() at time zone 'America/New_York')::date - 10
                          then ' The nightly Samsara check can still correct it.' else '' end
           else format('Time on site is still empty: %s''s GPS shows no stop near the property when the visit was marked complete, nor a stay within 150 m of it that day.', t.name)
                  || case when v.visit_date >= (now() at time zone 'America/New_York')::date - 10
                          then ' The nightly Samsara check looks again.' else '' end
         end);
$a$;
  b2 text := $b$      || case when v_after.duration_minutes is not null
              then format('Time on site: %s min (%s to %s).', v_after.duration_minutes,
                          to_char(v_after.actual_arrival_at at time zone 'America/New_York', 'FMHH12:MI AM'),
                          to_char(v_after.actual_departure_at at time zone 'America/New_York', 'FMHH12:MI AM'))
              else format('Time on site is still empty: %s''s GPS shows no stop near the property when the visit was marked complete, nor a stay within 150 m of it that day.', t.name) end);
$b$;
BEGIN
  IF md5(d) <> 'c7cbae66a7d33503688138224cc96feb' THEN RAISE EXCEPTION 'S3b: viktor_set_visit_truck is not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 THEN RAISE EXCEPTION 'S3b: viktor anchor 1 not found exactly once'; END IF;
  IF (length(d) - length(replace(d, a2, ''))) / length(a2) <> 1 THEN RAISE EXCEPTION 'S3b: viktor anchor 2 not found exactly once'; END IF;
  n := replace(replace(d, a1, b1), a2, b2);
  EXECUTE n;
  IF pg_get_functiondef('public.viktor_set_visit_truck(bigint,text,text,text,boolean)'::regprocedure) <> n THEN RAISE EXCEPTION 'S3b: viktor re-read differs'; END IF;
  IF md5(n) <> 'a07204ef5ad74e0f8d397f2ee1989fdd' THEN RAISE EXCEPTION 'S3b: viktor edited md5 is %', md5(n); END IF;
END $vk$;


ALTER TABLE public.visit_time_on_site_corrections DROP CONSTRAINT visit_time_on_site_corrections_stage_check;
ALTER TABLE public.visit_time_on_site_corrections ADD CONSTRAINT visit_time_on_site_corrections_stage_check
  CHECK (stage = ANY (ARRAY['2'::text, '3'::text, '4'::text, 'catch_up'::text]));
DROP TABLE public.time_on_site_site_overrides;

DO $v$ BEGIN
  IF md5(pg_get_functiondef('public.viktor_set_visit_truck(bigint,text,text,text,boolean)'::regprocedure)) <> 'a07204ef5ad74e0f8d397f2ee1989fdd' THEN
    RAISE EXCEPTION 'VERIFY S3b rollback: viktor_set_visit_truck is not the pre-S3b body'; END IF;
  IF to_regclass('public.time_on_site_site_overrides') IS NOT NULL THEN RAISE EXCEPTION 'VERIFY S3b rollback: the table is still there'; END IF;
  IF position('''nightly''' in (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'public.visit_time_on_site_corrections'::regclass AND conname = 'visit_time_on_site_corrections_stage_check')) > 0 THEN
    RAISE EXCEPTION 'VERIFY S3b rollback: the stage CHECK still allows nightly'; END IF;
END $v$;

COMMIT;
