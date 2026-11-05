-- Undo of 2026-11-05_0600_intake_slack_posts.sql.
-- Stops every post at once. The health body goes back to the pinned md5 or this file refuses.
-- public.slack_event_posts stays on purpose: it holds only ids and Slack timestamps, nothing reads it after this, and a
-- re-apply refuses while it exists, so drop it by hand then (it has no audit trigger: export it first if anyone wants it).
BEGIN;
SET LOCAL lock_timeout = '3s';

DROP TRIGGER IF EXISTS zz_slack_form_back ON public.property_intakes;
DROP TRIGGER IF EXISTS zz_slack_version_waiting ON public.property_pages;
DROP FUNCTION IF EXISTS public.trg_slack_event_request();
DROP FUNCTION IF EXISTS public.fn_slack_event_claim(text, bigint, boolean, boolean);

DO $undo$
DECLARE
  v_def text := pg_get_functiondef('public.fn_notification_health_items(jsonb,timestamp with time zone)'::regprocedure);
  v_start int := position(E'\n    UNION ALL\n    -- intake_post_missing (' IN v_def);
  v_tail text := $t$y.event_at < p_as_of - interval '15 minutes'$t$;
  v_end int := position(v_tail IN v_def);
BEGIN
  IF v_start = 0 OR v_end = 0 OR v_end < v_start THEN RAISE EXCEPTION 'the item is not where this file expects it'; END IF;
  EXECUTE left(v_def, v_start - 1) || substr(v_def, v_end + length(v_tail));
  IF md5(pg_get_functiondef('public.fn_notification_health_items(jsonb,timestamp with time zone)'::regprocedure))
     IS DISTINCT FROM '8acedc59f5879ad060d7957f3c18dff7' THEN
    RAISE EXCEPTION 'the health function did not go back to its old body';
  END IF;
END $undo$;

DELETE FROM public.app_config WHERE key = 'intake_slack_posts_since';

NOTIFY pgrst, 'reload schema';
COMMIT;
