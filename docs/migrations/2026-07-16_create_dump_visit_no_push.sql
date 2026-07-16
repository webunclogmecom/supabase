-- 2026-07-16_create_dump_visit_no_push.sql
-- public.create_dump_visit — create a DUMP-app visit that lands in the DB (and the Calendar) but is
-- NOT pushed to Jobber, until the app goes to production.
--
-- WHY (Fred, 2026-07-16): "we're building this from the ground up, so every visit created is only for
-- testing purposes and should be deleted until this is done for production. So do not put the visits
-- on jobber yet." Test visits must not appear on the real Jobber schedule the crew works from.
--
-- ⚠ WHY A WRAPPER AND NOT JUST A FLAG IN THE EDGE FN: there are TWO independent paths that push a
-- visit to Jobber, and suppressing only the first leaves the second live:
--   1. trg_push_visit_insert  — AFTER INSERT WHEN source IN ('visit-calendar','supabase_cron')
--                               -> fn_push_visit_to_jobber -> net.http_post to jobber-push-visit.
--   2. pg_cron 'resolve-stale-visit-sync-pending' (*/3) — re-drives ANY visit left at
--      sync_state='pending' with source IN ('visit-calendar','supabase_cron'). Since
--      trg_mark_visit_sync_pending stamps exactly those sources 'pending' on INSERT, a visit whose
--      insert-push we suppressed would be pushed by the cron ~3 minutes later. Silently.
-- This wrapper closes both.
--
-- HOW (test mode, p_push_to_jobber = false — the default):
--   a. set_config('app.suppress_jobber_push','on', TRUE) — transaction-LOCAL. fn_push_visit_to_jobber
--      opens with `IF current_setting('app.suppress_jobber_push', true) = 'on' THEN RETURN NEW`, and
--      the AFTER INSERT trigger runs inside this same transaction, so path 1 is skipped.
--   b. create_calendar_visit runs UNCHANGED — we get its validation, its line_items/visit_team/
--      visit_locations children, and its BEFORE-INSERT triggers (incl. trg_prefix_visit_title, which
--      still fires because source is 'visit-calendar' AT INSERT TIME).
--   c. THEN flip the row to source='manual' + sync_state='confirmed'. 'manual' is CHECK-legal and is
--      in NEITHER trigger's WHEN nor the cron's filter nor jobber-push-visit's source gate, so the
--      row is inert to every Jobber path — now and on any future edit. sync_state='confirmed' is the
--      belt to that braces: it also drops the row out of the */3 cron's predicate.
--      (The 'manual' source is normally a TRAP — it is why a hand-inserted visit never reaches Jobber.
--       Here that trap is exactly the feature we want.)
--   d. The UPDATE itself cannot push: trg_push_visit_update's WHEN requires source IN
--      ('visit-calendar','supabase_cron') and NEW.source is now 'manual'; sync_state is not in its
--      watched-field list either; and the suppress GUC is still set for this transaction.
--
-- PRODUCTION (p_push_to_jobber = true): no suppression, no source flip -> the row stays
-- source='visit-calendar' and pushes to Jobber exactly as it does today. Flip the PUSH_TO_JOBBER
-- constant in supabase/functions/dump-visit-create/index.ts. Nothing else changes.
--
-- Visits created this way STILL show in the Visit Calendar (ops.v_calendar_visit reads every source
-- where deleted_at IS NULL), which is how the app is verified while it is being built.
--
-- AUDIT (ADR 010): audit_visits fires on the INSERT + the UPDATE as normal — attribution is unchanged
-- by this migration.
-- GRANTS: service_role only (the edge fn's identity). NOT anon — anon is WRITE-NONE by design
-- (2026-07-11 phase3 lock + 2026-07-12 harden) and this must not widen that surface.
-- REVERSIBLE: DROP FUNCTION public.create_dump_visit(...); the edge fn then calls
-- create_calendar_visit directly again (which pushes).

CREATE OR REPLACE FUNCTION public.create_dump_visit(
  p_client_id              bigint,
  p_job_id                 bigint,
  p_service_line_item_ids  bigint[],
  p_visit_date             date,
  p_property_id            bigint  DEFAULT NULL,
  p_start_at               timestamptz DEFAULT NULL,
  p_end_at                 timestamptz DEFAULT NULL,
  p_title                  text    DEFAULT NULL,
  p_notes                  text    DEFAULT NULL,
  p_driver_id              bigint  DEFAULT NULL,
  p_team_ids               bigint[] DEFAULT NULL,
  p_push_to_jobber         boolean DEFAULT false
)
RETURNS public.visits
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v public.visits;
BEGIN
  -- TEST MODE: suppress the AFTER INSERT push for THIS transaction only.
  IF NOT p_push_to_jobber THEN
    PERFORM set_config('app.suppress_jobber_push', 'on', true);
  END IF;

  -- The one sanctioned visit-creating path. Unchanged, so all its validation + children still apply.
  v := public.create_calendar_visit(
         p_client_id, p_job_id, p_service_line_item_ids, p_visit_date,
         p_property_id, NULL, p_start_at, p_end_at, p_title, p_notes,
         NULL, p_driver_id, NULL, p_team_ids, NULL);

  -- TEST MODE: make the row permanently inert to every Jobber path (trigger, cron, and push gate).
  IF NOT p_push_to_jobber THEN
    UPDATE public.visits
       SET source = 'manual', sync_state = 'confirmed'
     WHERE id = v.id;
    SELECT * INTO v FROM public.visits WHERE id = v.id;
  END IF;

  RETURN v;
END $$;

COMMENT ON FUNCTION public.create_dump_visit(bigint,bigint,bigint[],date,bigint,timestamptz,timestamptz,text,text,bigint,bigint[],boolean) IS
  'DUMP Schedule app visit creator. p_push_to_jobber=false (default) = TEST MODE: creates the visit in the DB/Calendar but keeps it OFF Jobber by suppressing the insert push AND flipping the row to source=manual + sync_state=confirmed so the */3 retry cron cannot pick it up either. Set true for production (Fred 2026-07-16: "do not put the visits on jobber yet"). service_role only.';

REVOKE ALL ON FUNCTION public.create_dump_visit(bigint,bigint,bigint[],date,bigint,timestamptz,timestamptz,text,text,bigint,bigint[],boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_dump_visit(bigint,bigint,bigint[],date,bigint,timestamptz,timestamptz,text,text,bigint,bigint[],boolean) TO service_role;
