-- email_delivery_fixtures.sql (2026-10-14): every chip state of public.v_email_delivery, on fixture sends, ROLLED BACK.
-- Run after 2026-10-14_1505_email_delivery_events.sql:  node scripts/probes/apply_sql_file.mjs scripts/probes/email_delivery_fixtures.sql
-- (it ends in ROLLBACK, so nothing stays). Fixture addresses are example.gov / example.com; ids start 'fx-'.
BEGIN;

-- time-independent: tracking and the webhook both 'started' a day ago (fx-g, dated Oct 1, stays before tracking)
UPDATE public.app_config SET value = (now() - interval '1 day')::text WHERE key IN ('email_events_live_since', 'email_open_tracking_since');

-- city sends (DERM Tracker log: one row, comma-joined To). Client 330 is a real customer, so the health kinds can fire.
INSERT INTO public.derm_email_sends (manifest_id, client_id, recipient_email, resend_email_id, status, is_test, sent_at, recipient_type, bcc_emails)
VALUES
  (2037, 330, 'a@example.gov, B@example.gov', 'fx-a', 'sent', false, now() - interval '3 hours', 'city', '{}'),
  (2037, 330, 'a@example.gov, b@example.gov', 'fx-b', 'sent', false, now() - interval '3 hours', 'city', '{}'),
  (2037, 330, 'a@example.gov, b@example.gov', 'fx-c', 'sent', false, now() - interval '3 hours', 'city', '{}'),
  (2037, 330, 'a@example.gov, b@example.gov', 'fx-k', 'sent', false, now() - interval '3 hours', 'city', '{}'),
  (2037, 330, 'a@example.gov, b@example.gov', 'fx-l', 'sent', false, now() - interval '30 hours', 'city', '{}'),
  (2037, 330, 'a@example.gov, b@example.gov', 'fx-m', 'sent', false, now() - interval '30 hours', 'city', '{}'),
  (2037, 330, 'a@example.gov, b@example.gov', 'fx-j', 'sent', false, now() - interval '10 minutes', 'city', '{}'),
  (2037, 330, 'a@example.gov, b@example.gov', 'fx-q', 'sent', false, now() - interval '3 hours', 'city', '{}'),
-- client sends (one row per To address, shared id)
  (2037, 330, 'c@example.com', 'fx-d', 'sent', false, now() - interval '90 minutes', 'client', '{}'),
  (2037, 330, 'c@example.com', 'fx-e', 'sent', false, now() - interval '90 minutes', 'client', '{}'),
  (2037, 330, 'c@example.com', 'fx-f', 'sent', false, now() - interval '90 minutes', 'client', '{fred@ayache.com}'),
  (2037, 330, 'c@example.com', 'fx-g', 'sent', false, timestamptz '2026-10-01 15:00+00', 'client', '{}'),
  (2037, 330, 'c@example.com', 'fx-n', 'sent', false, now() - interval '90 minutes', 'client', '{}'),
  (2037, 330, 'c@example.com', 'fx-o', 'sent', false, now() - interval '90 minutes', 'client', '{}'),
  (2037, 330, 'd@example.com', 'fx-o', 'sent', false, now() - interval '90 minutes', 'client', '{}'),
-- summaries (backfill)
  (2037, 330, 'a@example.gov, b@example.gov', 'fx-h', 'sent', false, timestamptz '2026-07-01 15:00+00', 'city', '{}'),
  (2037, 330, 'a@example.gov, b@example.gov', 'fx-i', 'sent', false, timestamptz '2026-07-02 15:00+00', 'city', '{}');

INSERT INTO public.email_events (svix_id, resend_email_id, event_type, recipient, occurred_at, detail) VALUES
  -- A: both city inboxes delivered, archive copy delivered, an open credited to everyone -> open unknown
  ('a1', 'fx-a', 'delivered', 'a@example.gov', now() - interval '170 minutes', NULL),
  ('a2', 'fx-a', 'delivered', 'b@example.gov', now() - interval '170 minutes', NULL),
  ('a3', 'fx-a', 'delivered', 'derm@ayache.com', now() - interval '170 minutes', NULL),
  ('a4', 'fx-a', 'opened', 'a@example.gov', now() - interval '160 minutes', NULL),
  ('a4', 'fx-a', 'opened', 'b@example.gov', now() - interval '160 minutes', NULL),
  ('a4', 'fx-a', 'opened', 'derm@ayache.com', now() - interval '160 minutes', NULL),
  -- B: one delivered, one bounced (reason names an address: must be masked)
  ('b1', 'fx-b', 'delivered', 'a@example.gov', now() - interval '170 minutes', NULL),
  ('b2', 'fx-b', 'bounced', 'b@example.gov', now() - interval '169 minutes',
   '{"bounce": {"message": "550 5.1.1 <b@example.gov>: Recipient address rejected", "type": "Permanent"}}'),
  -- C: both bounced
  ('c1', 'fx-c', 'bounced', 'a@example.gov', now() - interval '170 minutes', '{"bounce": {"message": "mailbox full"}}'),
  ('c2', 'fx-c', 'bounced', 'b@example.gov', now() - interval '170 minutes', '{"bounce": {"message": "mailbox full"}}'),
  -- D: client delivered then opened 2 minutes later -> opened, gap 120
  ('d1', 'fx-d', 'delivered', 'c@example.com', now() - interval '85 minutes', NULL),
  ('d2', 'fx-d', 'opened', 'c@example.com', now() - interval '83 minutes', NULL),
  -- E: client delivered, no open -> delivered
  ('e1', 'fx-e', 'delivered', 'c@example.com', now() - interval '85 minutes', NULL),
  -- F: client with a logged Bcc, opened -> open unknown (other_recipients)
  ('f1', 'fx-f', 'delivered', 'c@example.com', now() - interval '85 minutes', NULL),
  ('f2', 'fx-f', 'delivered', 'fred@ayache.com', now() - interval '85 minutes', NULL),
  ('f3', 'fx-f', 'opened', 'c@example.com', now() - interval '80 minutes', NULL),
  ('f3', 'fx-f', 'opened', 'fred@ayache.com', now() - interval '80 minutes', NULL),
  -- G: client before tracking, delivered + opened -> open unknown (before_tracking)
  ('g1', 'fx-g', 'delivered', 'c@example.com', timestamptz '2026-10-01 15:01+00', NULL),
  ('g2', 'fx-g', 'opened', 'c@example.com', timestamptz '2026-10-01 15:05+00', NULL),
  -- H: summary, assumed (Resend no longer holds it) -> Delivered, open unknown
  ('backfill:fx-h', 'fx-h', 'backfill_summary', '', timestamptz '2026-07-01 15:00+00', '{"basis": "assumed_before_reports", "last_event": null}'),
  -- I: summary, Resend says bounced -> not delivered
  ('backfill:fx-i', 'fx-i', 'backfill_summary', '', timestamptz '2026-07-02 15:00+00', '{"basis": "resend_last_event", "last_event": "bounced"}'),
  -- L: 1 of 2 delivered, 30 hours old -> partly_delivered + health incomplete
  ('l1', 'fx-l', 'delivered', 'a@example.gov', now() - interval '29 hours', NULL),
  -- M: delayed only, 30 hours old -> delayed + health incomplete
  ('m1', 'fx-m', 'delivery_delayed', 'a@example.gov', now() - interval '29 hours', NULL),
  -- N: client, open recorded BEFORE delivered (out of order) -> opened, gap NULL (never negative)
  ('n1', 'fx-n', 'delivered', 'c@example.com', now() - interval '85 minutes', NULL),
  ('n2', 'fx-n', 'opened', 'c@example.com', now() - interval '86 minutes', NULL),
  -- O: client email to 2 addresses (2 log rows, 1 id), both delivered -> delivered 2 of 2
  ('o1', 'fx-o', 'delivered', 'c@example.com', now() - interval '85 minutes', NULL),
  ('o2', 'fx-o', 'delivered', 'd@example.com', now() - interval '85 minutes', NULL),
  -- Q: city, a spam complaint -> spam
  ('q1', 'fx-q', 'delivered', 'a@example.gov', now() - interval '170 minutes', NULL),
  ('q2', 'fx-q', 'delivered', 'b@example.gov', now() - interval '170 minutes', NULL),
  ('q3', 'fx-q', 'complained', 'b@example.gov', now() - interval '100 minutes', NULL);
-- K and J: no events (K 3 hours old after live_since -> no_status; J 10 minutes -> sending)

DO $t$
DECLARE r record; n int; h jsonb;
  expect CONSTANT jsonb := '{
    "fx-a": "delivered_open_unknown", "fx-b": "partly_bounced", "fx-c": "not_delivered", "fx-d": "opened",
    "fx-e": "delivered", "fx-f": "delivered_open_unknown", "fx-g": "delivered_open_unknown",
    "fx-h": "delivered_open_unknown", "fx-i": "not_delivered", "fx-j": "sending", "fx-k": "no_status",
    "fx-l": "partly_delivered", "fx-m": "delayed", "fx-n": "opened", "fx-o": "delivered", "fx-q": "spam"}';
BEGIN
  FOR r IN SELECT * FROM public.v_email_delivery WHERE resend_email_id LIKE 'fx-%' LOOP
    IF r.delivery_status IS DISTINCT FROM expect->>r.resend_email_id THEN
      RAISE EXCEPTION 'T1 % reads %, expected %', r.resend_email_id, r.delivery_status, expect->>r.resend_email_id; END IF;
  END LOOP;
  SELECT count(*) INTO n FROM public.v_email_delivery WHERE resend_email_id LIKE 'fx-%';
  IF n <> 16 THEN RAISE EXCEPTION 'T1 expected 16 fixture emails, found %', n; END IF;

  SELECT * INTO r FROM public.v_email_delivery WHERE resend_email_id = 'fx-a';
  -- the comma list is split (mutation control: counting the raw string as one address would give 1 of 1)
  IF r.to_count <> 2 OR r.delivered_count <> 2 THEN RAISE EXCEPTION 'T2 fx-a counts %/%', r.delivered_count, r.to_count; END IF;
  IF r.open_unknown_reason <> 'archive_copy' OR r.open_creditable THEN RAISE EXCEPTION 'T2 fx-a reason %', r.open_unknown_reason; END IF;
  IF r.opened_at IS NULL THEN RAISE EXCEPTION 'T2 fx-a: the city open must be STORED (D5 gate)'; END IF;
  IF r.delivery_detail ? 'opened_at' THEN RAISE EXCEPTION 'T2 fx-a: a city open reached delivery_detail'; END IF;

  SELECT * INTO r FROM public.v_email_delivery WHERE resend_email_id = 'fx-b';
  IF r.bounce_reason LIKE '%@%' THEN RAISE EXCEPTION 'T3 bounce reason not masked: %', r.bounce_reason; END IF;
  IF r.bounce_reason NOT LIKE '%an inbox%' THEN RAISE EXCEPTION 'T3 bounce reason lost: %', r.bounce_reason; END IF;
  IF r.refused_count <> 1 OR r.delivered_count <> 1 THEN RAISE EXCEPTION 'T3 fx-b counts'; END IF;

  SELECT * INTO r FROM public.v_email_delivery WHERE resend_email_id = 'fx-d';
  IF r.open_gap_seconds <> 120 OR NOT (r.delivery_detail ? 'opened_at') OR r.delivery_at <> r.opened_at THEN
    RAISE EXCEPTION 'T4 fx-d gap % detail %', r.open_gap_seconds, r.delivery_detail; END IF;
  SELECT * INTO r FROM public.v_email_delivery WHERE resend_email_id = 'fx-f';
  IF r.open_unknown_reason <> 'other_recipients' THEN RAISE EXCEPTION 'T4 fx-f reason %', r.open_unknown_reason; END IF;
  SELECT * INTO r FROM public.v_email_delivery WHERE resend_email_id = 'fx-g';
  IF r.open_unknown_reason <> 'before_tracking' THEN RAISE EXCEPTION 'T4 fx-g reason %', r.open_unknown_reason; END IF;
  SELECT * INTO r FROM public.v_email_delivery WHERE resend_email_id = 'fx-n';
  IF r.open_gap_seconds IS NOT NULL THEN RAISE EXCEPTION 'T4 fx-n negative gap kept: %', r.open_gap_seconds; END IF;
  SELECT * INTO r FROM public.v_email_delivery WHERE resend_email_id = 'fx-o';
  IF r.to_count <> 2 OR r.delivered_count <> 2 THEN RAISE EXCEPTION 'T4 fx-o counts %/%', r.delivered_count, r.to_count; END IF;

  SELECT * INTO r FROM public.v_email_delivery WHERE resend_email_id = 'fx-h';
  IF NOT r.summary_only OR r.summary_basis <> 'assumed_before_reports' OR r.delivery_at IS NULL THEN RAISE EXCEPTION 'T5 fx-h'; END IF;

  -- T6 the app views carry it, and the client view shows no address
  SELECT count(*) INTO n FROM public.v_client_email_sends WHERE send_id IN (SELECT send_id FROM public.v_email_delivery WHERE resend_email_id LIKE 'fx-%');
  IF n <> 6 THEN RAISE EXCEPTION 'T6 v_client_email_sends shows % fixture client emails, expected 6 (fx-o is one email to 2 addresses)', n; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'v_client_email_sends'
              AND column_name ILIKE '%recipient%') THEN RAISE EXCEPTION 'T6 v_client_email_sends exposes recipients'; END IF;
  SELECT count(*) INTO n FROM public.v_visit_city_email_sends WHERE send_id IN (SELECT send_id FROM public.v_email_delivery WHERE resend_email_id LIKE 'fx-%' AND target = 'city') AND source_table = 'derm_email_sends' AND visit_id = 6284;
  IF n <> 10 THEN RAISE EXCEPTION 'T6 visit 6284 shows % fixture city sends, expected 10', n; END IF;

  -- T7 the health email: B, C (not delivered), Q (spam), K (missing), L + M (incomplete); none for A, D, E ...
  h := public.fn_notification_health_items('[]'::jsonb);
  SELECT count(*) INTO n FROM jsonb_array_elements(h) i
   WHERE i->>'issue' IN ('email_not_delivered', 'email_status_missing', 'email_delivery_incomplete');
  IF n <> 6 THEN RAISE EXCEPTION 'T7 expected 6 email health items, got %: %', n,
    (SELECT jsonb_agg(i->>'kind') FROM jsonb_array_elements(h) i WHERE i->>'issue' LIKE 'email%'); END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(h) i WHERE i->>'issue' LIKE 'email%' AND (i->>'reason') LIKE '%@%') THEN
    RAISE EXCEPTION 'T7 an address reached the health email'; END IF;

  RAISE NOTICE 'email_delivery_fixtures: all pass';
END $t$;

ROLLBACK;
