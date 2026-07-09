-- 2026-07-09_fn_request_jobber_push_safe_groups.sql
-- Push-safety audit (Fred): fn_request_jobber_push (the */3-min resolve-stale re-driver + the
-- drift HEAL) hardcoded changed=["schedule"], but fn_mark_visit_sync_pending flips
-- sync_state='pending' for title/notes/team_rev/line_items_rev edits too. If a scoped push dies
-- MID-FLIGHT (edge fn killed / pg_net drop — the only way a row stays 'pending'), the re-driver
-- pushed ONLY the schedule and the handler blanket-confirmed — the office's title/line-item edit
-- was silently LOST while the DB claimed 'confirmed'.
--
-- Fix: send the SAFE-IDEMPOTENT groups ["schedule","title","lineitems"] —
--   * title: the edge fn pushes it only when non-empty (never wipes a Jobber title);
--   * lineitems: full reconcile, idempotent (and empty-set no-ops protect SA inherited lines);
--   * schedule: idempotent re-assert.
-- crew + notes stay EXCLUDED: they are empty-clobber-prone (our value is usually empty) and the
-- edge fn's wantsStrict() gate exists precisely so an unscoped re-drive can never wipe a Jobber
-- crew/instruction. Residual (accepted, flagged to Fred): a crew/notes edit whose direct push
-- died mid-flight is still not re-driven — it stays visible as the row's team in the Calendar
-- vs Jobber until re-saved; the alternative (blind crew re-push) risks the exact clobber class
-- this design guards against.
--
-- Audit note (Rule 8): function replace only; no table/trigger changes; no data writes.
-- @Supabase (1): your drift HEAL calls this too — HEAL now re-asserts title+lineitems along
-- with schedule; both are idempotent no-ops when unchanged (title non-empty gate, LI reconcile).

CREATE OR REPLACE FUNCTION public.fn_request_jobber_push(p_visit_id bigint, p_op text DEFAULT 'upsert'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_key text;
BEGIN
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'jobber_push_service_key';
  IF v_key IS NULL THEN RAISE WARNING 'jobber_push_service_key vault secret missing; skipping push for visit %', p_visit_id; RETURN; END IF;
  -- Re-assert the SAFE-IDEMPOTENT groups (schedule/title/lineitems). crew+notes stay excluded:
  -- empty-clobber-prone; the edge fn's strict gate must only ever push them on a deliberate edit.
  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/jobber-push-visit',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body    := jsonb_build_object('op', p_op, 'visit_id', p_visit_id, 'changed', '["schedule","title","lineitems"]'::jsonb));
END; $function$;
