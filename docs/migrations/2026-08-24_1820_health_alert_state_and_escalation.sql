-- 2026-08-24_1820_health_alert_state_and_escalation.sql
-- ---------------------------------------------------------------------------
-- Escalate a health problem BY EMAIL when it has been open too long, instead of
-- posting every change into a Slack channel.
--
-- Fred, 2026-08-24: "3 days, email only." / "for now just send an email to
-- fred@ayache.com" / "you can use the resend.com".
--
-- WHY THIS AND NOT WHAT SHIPPED THIS MORNING. The Slack digest posts only when
-- something CHANGES, which leaves a real hole: a problem that appears once and then
-- sits produces exactly ONE message and then silence for ever. rpa-derm-health has
-- been unchanged for 11 straight runs; after the first post it would have gone quiet
-- while a Miami-Dade report stayed unfiled. "It has been broken for N days" is the
-- trigger that was missing.
--
-- ⚠ AND "just save it in the DB" IS ALREADY WHAT WE HAD. The verdicts have been in
--   public.sync_log all along and nobody read them for days. A record nothing pushes
--   is a record nothing reads. The escalation is the whole fix; the storage was never
--   the problem.
--
-- SIZING, MEASURED before choosing 3 days. Every attention streak of 3+ days in the
-- previous two months:
--     calendar-push-health  29d  2026-06-27..07-25      calendar-push-health  7d  07-31..08-06
--     rpa-derm-health       11d  2026-08-15..08-24      calendar-push-health  6d  08-19..08-24
--     blackout-health        8d  2026-08-19..08-24      calendar-push-health  3d  08-13..08-15
--     calendar-push-health   3d  2026-07-27..07-29
-- Seven emails in two months, about one every eight days, each a genuine unresolved
-- problem. rpa-derm-health would have escalated on 2026-08-18, six days before it was
-- found by hand.
--
-- 🛑 ACKNOWLEDGEMENT WITH AN EXPIRY IS LOAD-BEARING, NOT A NICETY. blackout-health's
--   ticket-833049 is frozen ON PURPOSE by CHECK page_block_extents_no_ticket_833049
--   and will NEVER resolve. A pure staleness rule mails about it every cycle for ever
--   and becomes the new wallpaper -- the exact disease that made sync_log unreadable.
--   So an item can be acknowledged, but ONLY until a date. There is deliberately no
--   permanent mute: nothing can be silenced and then forgotten.
--
-- ARCHITECTURE, and it is dictated by what the database can actually reach:
--   RESEND_API_KEY is an EDGE-FUNCTION secret and is NOT in vault, so Postgres cannot
--   POST to Resend itself. Vault holds edge_invoke_service_key, already used by four
--   fn_request_* helpers. So: pg_cron -> net.http_post -> edge fn health-escalate ->
--   Resend. That is also how both existing email senders work. unclogme.com is Verified.
--
-- 🛑 THE SEND IS NOT MARKED UNTIL IT SUCCEEDS, AND THAT ASYMMETRY IS DELIBERATE.
--   fn_health_alert_scan() decides and returns the payload WITHOUT recording that
--   anything was alerted; the edge function marks it only after Resend accepts.
--   A failed send therefore REPEATS tomorrow rather than vanishing. For a watchdog,
--   a duplicate is cheap and a miss is the entire failure mode.
--
-- Audit (Rule 8): one NEW table, public.health_alert_state. It is operational
-- bookkeeping for the watchdog, holds no client data, and is deliberately NOT audited
-- -- an audit trigger on it would write a row every single day for every open item and
-- bury audit.logs for no forensic gain. Explicit opt-OUT, recorded here so the next
-- audit sweep does not read the absence as an oversight.
--
-- Grants: state table and functions are service_role only. ops.v_health_items follows
-- the other 33 ops views (authenticated + service_role) since it is read-only status.
--
-- @Building Apps. Claimed in WORKING-NOW.md. No Lovable project touched.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. One row per (check, item) for the LATEST run of each check.
--    Extracted so the normaliser CASE lives in exactly ONE place; ops.v_health_status
--    has its own copy and the two must not drift.
--    ⚠ A new health check MUST be added to this CASE or it silently contributes zero
--      items and can never escalate.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW ops.v_health_items AS
WITH latest AS (
  SELECT DISTINCT ON (l.sync_source)
         l.sync_source, l.status, l.started_at, l.details
  FROM public.sync_log l
  WHERE l.sync_source IN ('calendar-push-health','blackout-health','rpa-derm-health','sa-schedule-gap-check')
  ORDER BY l.sync_source, l.started_at DESC
)
SELECT
  la.sync_source                                                   AS check_name,
  la.status,
  la.started_at                                                    AS last_run_at,
  coalesce(i->>'visit_id', i->>'dump_folder', i->>'kind', i->>'client_code', i::text) AS item_key,
  i                                                                AS item
FROM latest la
CROSS JOIN LATERAL jsonb_array_elements(
  CASE la.sync_source
    WHEN 'calendar-push-health'  THEN coalesce(la.details->'items',   '[]'::jsonb)
    WHEN 'blackout-health'       THEN coalesce(la.details->'sheets',  '[]'::jsonb)
    WHEN 'rpa-derm-health'       THEN coalesce(la.details->'reasons', '[]'::jsonb)
    WHEN 'sa-schedule-gap-check' THEN coalesce(la.details->'sample',  '[]'::jsonb)
    ELSE '[]'::jsonb
  END) i;

COMMENT ON VIEW ops.v_health_items IS
  'One row per (check, item) for the latest run of each health check. The item-key normaliser lives here so it is defined once; ⚠ a new health check must be added to the CASE or it contributes zero items and can never escalate. Added 2026-08-24.';

GRANT SELECT ON ops.v_health_items TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Watchdog bookkeeping: how long has each item been open, and when did we last
--    say so.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.health_alert_state (
  check_name          text        NOT NULL,
  item_key            text        NOT NULL,
  first_seen_at       timestamptz NOT NULL DEFAULT now(),
  last_seen_at        timestamptz NOT NULL DEFAULT now(),
  last_alerted_at     timestamptz,
  alert_count         integer     NOT NULL DEFAULT 0,
  resolved_at         timestamptz,
  -- ⚠ ALWAYS a date, never a boolean. A permanent mute is how a known problem becomes
  --   an unknown one. Silence expires; the item comes back.
  acknowledged_until  timestamptz,
  ack_reason          text,
  ack_by              text,
  PRIMARY KEY (check_name, item_key)
);

COMMENT ON TABLE public.health_alert_state IS
  'Per-(check,item) watchdog bookkeeping for the health escalation email: when it was first seen, when we last emailed about it, and any time-boxed acknowledgement. acknowledged_until is deliberately a TIMESTAMP and never a boolean - there is no permanent mute, because a permanently silenced problem is an unknown problem. Deliberately NOT audited (Rule 8 opt-out): an audit trigger here would write a row per open item per day and bury audit.logs for no forensic gain.';

CREATE INDEX IF NOT EXISTS health_alert_state_open_idx
  ON public.health_alert_state (check_name, first_seen_at)
  WHERE resolved_at IS NULL;

REVOKE ALL ON public.health_alert_state FROM PUBLIC;
REVOKE ALL ON public.health_alert_state FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.health_alert_state TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Decide what deserves an email. Records what it SAW; does NOT record that it
--    alerted -- see the header on why that asymmetry matters.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_health_alert_scan(
  p_stale_days   integer DEFAULT 3,
  p_renotify_days integer DEFAULT 7
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'ops', 'pg_temp'
AS $fn$
DECLARE
  v_new      jsonb;
  v_stale    jsonb;
  v_resolved jsonb;
BEGIN
  -- (a) record everything currently open
  INSERT INTO public.health_alert_state (check_name, item_key, first_seen_at, last_seen_at)
  SELECT i.check_name, i.item_key, now(), now()
    FROM ops.v_health_items i
  ON CONFLICT (check_name, item_key) DO UPDATE
    SET last_seen_at = now(),
        -- an item that comes BACK starts its clock again; it is a new occurrence,
        -- not a continuation of the one that was fixed.
        first_seen_at   = CASE WHEN public.health_alert_state.resolved_at IS NOT NULL
                               THEN now() ELSE public.health_alert_state.first_seen_at END,
        alert_count     = CASE WHEN public.health_alert_state.resolved_at IS NOT NULL
                               THEN 0 ELSE public.health_alert_state.alert_count END,
        last_alerted_at = CASE WHEN public.health_alert_state.resolved_at IS NOT NULL
                               THEN NULL ELSE public.health_alert_state.last_alerted_at END,
        resolved_at     = NULL;

  -- (b) anything we knew about that is no longer reported has resolved
  UPDATE public.health_alert_state s
     SET resolved_at = now()
   WHERE s.resolved_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM ops.v_health_items i
                      WHERE i.check_name = s.check_name AND i.item_key = s.item_key);

  -- (c) NEW: open, never emailed about
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'check_name', s.check_name, 'item_key', s.item_key,
           'open_days', floor(extract(epoch FROM now() - s.first_seen_at)/86400)::int,
           'item', i.item) ORDER BY s.check_name, s.item_key), '[]'::jsonb)
    INTO v_new
    FROM public.health_alert_state s
    JOIN ops.v_health_items i ON i.check_name = s.check_name AND i.item_key = s.item_key
   WHERE s.resolved_at IS NULL AND s.alert_count = 0
     AND (s.acknowledged_until IS NULL OR s.acknowledged_until < now());

  -- (d) STALE: open >= p_stale_days, already emailed at least once, and due again
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'check_name', s.check_name, 'item_key', s.item_key,
           'open_days', floor(extract(epoch FROM now() - s.first_seen_at)/86400)::int,
           'alert_count', s.alert_count,
           'item', i.item) ORDER BY s.first_seen_at), '[]'::jsonb)
    INTO v_stale
    FROM public.health_alert_state s
    JOIN ops.v_health_items i ON i.check_name = s.check_name AND i.item_key = s.item_key
   WHERE s.resolved_at IS NULL AND s.alert_count > 0
     AND (s.acknowledged_until IS NULL OR s.acknowledged_until < now())
     AND now() - s.first_seen_at >= make_interval(days => p_stale_days)
     AND (s.last_alerted_at IS NULL
          OR now() - s.last_alerted_at >= make_interval(days => p_renotify_days));

  -- (e) RESOLVED since we last spoke. Rides along; never triggers a send by itself.
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'check_name', s.check_name, 'item_key', s.item_key) ORDER BY s.check_name), '[]'::jsonb)
    INTO v_resolved
    FROM public.health_alert_state s
   WHERE s.resolved_at IS NOT NULL
     AND s.alert_count > 0
     AND (s.last_alerted_at IS NULL OR s.resolved_at > s.last_alerted_at);

  RETURN jsonb_build_object(
    'should_send', (jsonb_array_length(v_new) > 0 OR jsonb_array_length(v_stale) > 0),
    'stale_days', p_stale_days,
    'new', v_new, 'stale', v_stale, 'resolved', v_resolved);
END $fn$;

REVOKE ALL ON FUNCTION public.fn_health_alert_scan(integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_health_alert_scan(integer,integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Record that an email actually went out. Called ONLY after Resend accepts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_health_alert_mark_sent(p_items jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE n integer;
BEGIN
  WITH k AS (
    SELECT x->>'check_name' AS check_name, x->>'item_key' AS item_key
      FROM jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) x
  ), upd AS (
    UPDATE public.health_alert_state s
       SET last_alerted_at = now(), alert_count = s.alert_count + 1
      FROM k
     WHERE s.check_name = k.check_name AND s.item_key = k.item_key
     RETURNING 1
  )
  SELECT count(*) INTO n FROM upd;
  -- Resolved items were reported as good news; stop re-reporting them.
  UPDATE public.health_alert_state s SET last_alerted_at = now()
   WHERE s.resolved_at IS NOT NULL AND s.alert_count > 0
     AND (s.last_alerted_at IS NULL OR s.resolved_at > s.last_alerted_at);
  RETURN n;
END $fn$;

REVOKE ALL ON FUNCTION public.fn_health_alert_mark_sent(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_health_alert_mark_sent(jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Time-boxed acknowledgement. "I know. Remind me on <date>."
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_health_ack(
  p_check_name text,
  p_item_key   text,
  p_days       integer,
  p_reason     text,
  p_by         text DEFAULT NULL
) RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_until timestamptz;
BEGIN
  IF p_days IS NULL OR p_days < 1 OR p_days > 365 THEN
    -- 🛑 No permanent mute, and no accidental decade-long one either. A silence you
    --    cannot remember granting is indistinguishable from a bug.
    RAISE EXCEPTION 'fn_health_ack: p_days must be between 1 and 365 (got %). There is deliberately no permanent mute.', p_days
      USING ERRCODE = '22023';
  END IF;
  IF coalesce(btrim(p_reason),'') = '' THEN
    RAISE EXCEPTION 'fn_health_ack: a reason is required — the next person to see this silence has to know why it is there'
      USING ERRCODE = '22023';
  END IF;
  v_until := now() + make_interval(days => p_days);
  UPDATE public.health_alert_state
     SET acknowledged_until = v_until, ack_reason = p_reason,
         ack_by = coalesce(p_by, current_setting('request.jwt.claims', true)::jsonb->>'email', session_user)
   WHERE check_name = p_check_name AND item_key = p_item_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_health_ack: no open item (%, %) — check ops.v_health_items for the exact key', p_check_name, p_item_key
      USING ERRCODE = 'P0002';
  END IF;
  RETURN v_until;
END $fn$;

REVOKE ALL ON FUNCTION public.fn_health_ack(text,text,integer,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_health_ack(text,text,integer,text,text) TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- VERIFY (run after applying)
--
-- 1. the item view sees the checks that are currently open
--    select check_name, item_key from ops.v_health_items order by 1,2;
--    -- expect rows for blackout-health (2) and rpa-derm-health (1) on 2026-08-24
--
-- 2. first scan: everything currently open is NEW, and it wants to send
--    select jsonb_pretty(public.fn_health_alert_scan());
--    -- expect should_send=true and every open item under "new"
--
-- 3. IDEMPOTENCE: scanning again WITHOUT marking must return the same thing.
--    A scan that mutates its own answer would drop alerts on a failed send.
--    select public.fn_health_alert_scan()->'should_send';   -- expect true, again
--
-- 4. after marking, the same items must NOT re-alert until the re-notify window
--    select public.fn_health_alert_mark_sent(public.fn_health_alert_scan()->'new');
--    select public.fn_health_alert_scan()->'should_send';   -- expect false
--
-- 5. MUTATION TEST the ack guard. Both must RAISE.
--    do $$ begin perform public.fn_health_ack('blackout-health','ticket-833049',0,'x');
--      raise exception 'FAILTEST: accepted 0 days'; exception when others then
--      if sqlerrm like 'FAILTEST%' then raise; end if; raise notice 'ok: %', sqlerrm; end $$;
--    do $$ begin perform public.fn_health_ack('blackout-health','ticket-833049',30,'');
--      raise exception 'FAILTEST: accepted an empty reason'; exception when others then
--      if sqlerrm like 'FAILTEST%' then raise; end if; raise notice 'ok: %', sqlerrm; end $$;
--
-- 6. grants: no anon, no authenticated on the state table or the functions
--    select grantee, privilege_type from information_schema.role_table_grants
--     where table_schema='public' and table_name='health_alert_state';
--    -- expect service_role only (plus the table owner)
