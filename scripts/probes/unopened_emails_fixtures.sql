-- unopened_emails_fixtures.sql (2026-10-20): every rule of public.fn_unopened_emails on fixture sends, ROLLED BACK.
-- Run after 2026-10-20_1930:  node scripts/probes/apply_sql_file.mjs scripts/probes/unopened_emails_fixtures.sql
-- Ids start 'ux-'. Client 330 / manifest 2037 / visit 6284 are a real customer, so the rules run as in production;
-- client 381 (112-YA) is the test client, manifest 2017.
BEGIN;

-- time-independent: tracking and the webhook "started" 5 days ago
UPDATE public.app_config SET value = (now() - interval '5 days')::text WHERE key IN ('email_events_live_since', 'email_open_tracking_since');

INSERT INTO public.derm_email_sends (manifest_id, client_id, recipient_email, resend_email_id, status, is_test, sent_at,
                                     recipient_type, cc_emails, bcc_emails, hidden_copies_separate, archive_resend_email_id)
VALUES
  (2037, 330, 'a@example.gov, b@example.gov', 'ux-a', 'sent', false, now() - interval '2 days', 'city', '{}', '{}', NULL, NULL),
  (2037, 330, 'a@example.gov, b@example.gov', 'ux-b', 'sent', false, now() - interval '2 days', 'city', '{}', '{derm@ayache.com}', true, 'ux-b-arch'),
  (2037, 330, 'a@example.gov, b@example.gov', 'ux-c', 'sent', false, now() - interval '2 days', 'city', '{}', '{derm@ayache.com}', true, 'ux-c-arch'),
  (2037, 330, 'a@example.gov, b@example.gov', 'ux-d', 'sent', false, now() - interval '2 days', 'city', '{}', '{derm@ayache.com}', true, 'ux-d-arch'),
  (2037, 330, 'a@example.gov, b@example.gov', 'ux-e', 'sent', false, now() - interval '12 hours', 'city', '{}', '{derm@ayache.com}', true, 'ux-e-arch'),
  (2037, 330, 'a@example.gov, b@example.gov', 'ux-f', 'sent', false, now() - interval '8 days', 'city', '{}', '{derm@ayache.com}', true, 'ux-f-arch'),
  (2037, 330, 'a@example.gov, b@example.gov', 'ux-g', 'sent', true,  now() - interval '2 days', 'city', '{}', '{}', true, NULL),
  (2037, 330, 'a@example.gov, b@example.gov', 'ux-k', 'sent', false, now() - interval '6 days', 'city', '{}', '{derm@ayache.com}', true, 'ux-k-arch'),
  (2037, 330, 'a@example.gov, b@example.gov', 'ux-l', 'sent', false, now() - interval '2 days', 'city', '{}', '{derm@ayache.com}', true, 'ux-l-arch'),
  (2017, 381, 'a@example.gov', 'ux-j', 'sent', false, now() - interval '2 days', 'city', '{}', '{derm@ayache.com}', true, 'ux-j-arch'),
  (2037, 330, 'c@example.com', 'ux-i', 'sent', false, now() - interval '2 days', 'client', '{}', '{}', NULL, NULL),
  (2037, 330, 'c@example.com', 'ux-m', 'sent', false, now() - interval '2 days', 'client', '{}', '{}', NULL, NULL);
INSERT INTO public.visit_photo_email_sends (visit_id, recipient_email, status, is_test, photo_count, bytes_sent, resend_email_id,
                                            sent_at, cc_emails, bcc_emails, hidden_copies_separate, archive_resend_email_id)
VALUES (6284, 'a@example.gov', 'sent', false, 0, 0, 'ux-h', now() - interval '3 days', '{}', '{derm@ayache.com}', true, 'ux-h-arch');

INSERT INTO public.email_events (svix_id, resend_email_id, event_type, recipient, occurred_at, detail) VALUES
  -- A: delivered to both, old-style (archive rode along) -> open unknown -> NOT OPENED
  ('xa1', 'ux-a', 'delivered', 'a@example.gov', now() - interval '2 days', NULL),
  ('xa2', 'ux-a', 'delivered', 'b@example.gov', now() - interval '2 days', NULL),
  -- B: D5, delivered then opened 5 minutes later -> left off (opened)
  ('xb1', 'ux-b', 'delivered', 'a@example.gov', now() - interval '2 days', NULL),
  ('xb2', 'ux-b', 'delivered', 'b@example.gov', now() - interval '2 days', NULL),
  ('xb3', 'ux-b', 'opened', 'a@example.gov', now() - interval '2 days' + interval '5 minutes', NULL),
  ('xb3', 'ux-b', 'opened', 'b@example.gov', now() - interval '2 days' + interval '5 minutes', NULL),
  -- C: D5, opened 20 seconds after arriving -> NOT OPENED (most likely their email system)
  ('xc1', 'ux-c', 'delivered', 'a@example.gov', now() - interval '2 days', NULL),
  ('xc2', 'ux-c', 'delivered', 'b@example.gov', now() - interval '2 days', NULL),
  ('xc3', 'ux-c', 'opened', 'a@example.gov', now() - interval '2 days' + interval '20 seconds', NULL),
  ('xc3', 'ux-c', 'opened', 'b@example.gov', now() - interval '2 days' + interval '20 seconds', NULL),
  -- D: both inboxes refused it -> NOT DELIVERED
  ('xd1', 'ux-d', 'bounced', 'a@example.gov', now() - interval '2 days', '{"bounce": {"message": "mailbox full"}}'),
  ('xd2', 'ux-d', 'bounced', 'b@example.gov', now() - interval '2 days', '{"bounce": {"message": "mailbox full"}}'),
  -- E: delivered but only 12 hours old -> left off (gets a day first)
  ('xe1', 'ux-e', 'delivered', 'a@example.gov', now() - interval '12 hours', NULL),
  ('xe2', 'ux-e', 'delivered', 'b@example.gov', now() - interval '12 hours', NULL),
  -- F: delivered, 8 days old -> left off (more than 7 days); also sent before tracking started
  ('xf1', 'ux-f', 'delivered', 'a@example.gov', now() - interval '8 days', NULL),
  ('xf2', 'ux-f', 'delivered', 'b@example.gov', now() - interval '8 days', NULL),
  -- G: a test send -> left off
  ('xg1', 'ux-g', 'delivered', 'a@example.gov', now() - interval '2 days', NULL),
  ('xg2', 'ux-g', 'delivered', 'b@example.gov', now() - interval '2 days', NULL),
  -- K: 6 days old, sent before open tracking started (5 days ago) -> left off
  ('xk1', 'ux-k', 'delivered', 'a@example.gov', now() - interval '6 days', NULL),
  ('xk2', 'ux-k', 'delivered', 'b@example.gov', now() - interval '6 days', NULL),
  -- L: no event at all (no status) -> left off (the health email covers it)
  -- J: the test client 112-YA -> left off
  ('xj1', 'ux-j', 'delivered', 'a@example.gov', now() - interval '2 days', NULL),
  -- H: Admin Review job report, delivered 3 days ago, no open -> NOT OPENED
  ('xh1', 'ux-h', 'delivered', 'a@example.gov', now() - interval '3 days', NULL),
  -- I: client email delivered, no open -> NOT OPENED;  M: client email opened 2 minutes later -> left off
  ('xi1', 'ux-i', 'delivered', 'c@example.com', now() - interval '2 days', NULL),
  ('xm1', 'ux-m', 'delivered', 'c@example.com', now() - interval '2 days', NULL),
  ('xm2', 'ux-m', 'opened', 'c@example.com', now() - interval '2 days' + interval '2 minutes', NULL);

DO $t$
DECLARE r jsonb; got jsonb; e jsonb;
  expect CONSTANT jsonb := '{"ux-a": "not_opened", "ux-c": "not_opened", "ux-d": "not_delivered", "ux-h": "not_opened", "ux-i": "not_opened"}';
BEGIN
  r := public.fn_unopened_emails(now());
  SELECT coalesce(jsonb_object_agg(x->>'resend_email_id', x->>'section'), '{}') INTO got
    FROM jsonb_array_elements(r->'emails') x WHERE x->>'resend_email_id' LIKE 'ux-%';
  IF got <> expect THEN RAISE EXCEPTION 'U1 listed %, expected %', got, expect; END IF;

  SELECT x INTO e FROM jsonb_array_elements(r->'emails') x WHERE x->>'resend_email_id' = 'ux-h';
  IF e->>'kind' <> 'job report' OR e->>'app' <> 'admin_review' OR (e->>'visit_id')::bigint <> 6284 OR e->>'city' IS NULL THEN
    RAISE EXCEPTION 'U2 ux-h fields %', e; END IF;
  SELECT x INTO e FROM jsonb_array_elements(r->'emails') x WHERE x->>'resend_email_id' = 'ux-a';
  IF e->>'kind' <> 'manifest' OR e->>'app' <> 'derm_tracker' OR e->>'client_code' IS NULL OR e->>'city' IS NULL
     OR e->>'open_unknown_reason' <> 'archive_copy' THEN RAISE EXCEPTION 'U2 ux-a fields %', e; END IF;
  SELECT x INTO e FROM jsonb_array_elements(r->'emails') x WHERE x->>'resend_email_id' = 'ux-c';
  IF (e->>'open_gap_seconds')::int <> 20 OR e->>'delivery_status' <> 'opened' THEN RAISE EXCEPTION 'U2 ux-c fields %', e; END IF;
  SELECT x INTO e FROM jsonb_array_elements(r->'emails') x WHERE x->>'resend_email_id' = 'ux-i';
  IF e->>'kind' <> 'report to the client' OR e->>'target' <> 'client' OR (e->>'visit_id')::bigint <> 6284 THEN
    RAISE EXCEPTION 'U2 ux-i fields %', e; END IF;
  SELECT x INTO e FROM jsonb_array_elements(r->'emails') x WHERE x->>'resend_email_id' = 'ux-d';
  IF (e->>'refused_count')::int <> 2 OR e->>'bounce_reason' NOT LIKE '%mailbox full%' THEN RAISE EXCEPTION 'U2 ux-d fields %', e; END IF;

  -- U3 a day later ux-e appears and ux-k (still before tracking) does not; 7 days on, everything has aged out
  r := public.fn_unopened_emails(now() + interval '1 day');
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'emails') x WHERE x->>'resend_email_id' = 'ux-e') THEN
    RAISE EXCEPTION 'U3 ux-e not listed a day later'; END IF;
  r := public.fn_unopened_emails(now() + interval '7 days');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'emails') x WHERE x->>'resend_email_id' IN ('ux-a', 'ux-c', 'ux-d', 'ux-h', 'ux-i')) THEN
    RAISE EXCEPTION 'U3 an email older than 7 days is still listed'; END IF;
  RAISE NOTICE 'unopened_emails_fixtures: all pass';
END $t$;

ROLLBACK;
