-- ============================================================================
-- 2026-10-14_1531 The Resend webhook is proven live: switch on the "no report received" health check
-- ============================================================================
-- After 2026-10-14_1505. Fred added the webhook in Resend and the secret RESEND_WEBHOOK_SECRET; proven the same
-- minute on 112-YA test sends (fred@ayache.com only):
--   city test 01a13be4-85b6-...: delivered for fred@ayache.com AND the archive Bcc derm@ayache.com, about 1.5 s after
--     Resend's event; opened (by a person, in Gmail) credited to BOTH addresses (one svix message per address);
--     status stays delivered_open_unknown / archive_copy, and delivery_detail carries no opened_at.
--   client test 01a13be4-a8dc-...: delivered, then "opened" 8 s later although the email is still UNREAD in Gmail
--     (an automatic open by a mail client or Google). Recorded in the audit doc: the fast-open question goes to the
--     mockup step.
--   forged signature -> 401 bad_signature; unsigned -> 401; stale timestamp -> 401; nothing written.
-- WHAT CHANGES: app_config.email_events_live_since = now(). From now on a real send with no Resend event after 2
-- hours reads no_status and reaches the health email (email_status_missing). Sends before this keep no_record.
-- ROLLBACK: update public.app_config set value = '' where key = 'email_events_live_since';
-- ============================================================================
BEGIN;

UPDATE public.app_config SET value = now()::text, updated_at = now()
 WHERE key = 'email_events_live_since' AND btrim(value) = '';

DO $v$
DECLARE n int;
BEGIN
  IF (SELECT nullif(btrim(value), '') FROM public.app_config WHERE key = 'email_events_live_since') IS NULL THEN
    RAISE EXCEPTION 'V1 email_events_live_since not set'; END IF;
  -- nothing turns into no_status at apply: every real send so far has an event or a backfill summary
  SELECT count(*) INTO n FROM public.v_email_delivery WHERE delivery_status = 'no_status';
  IF n <> 0 THEN RAISE EXCEPTION 'V2 % send(s) read no_status at apply', n; END IF;
  SELECT count(*) INTO n FROM public.v_email_delivery WHERE NOT is_test AND delivery_status IN ('no_record', 'sending');
  IF n <> 0 THEN RAISE EXCEPTION 'V3 % real send(s) have no status', n; END IF;
END $v$;

COMMIT;
