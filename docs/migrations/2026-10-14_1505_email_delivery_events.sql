-- ============================================================================
-- 2026-10-14_1505 What Resend reports back about every email we send: public.email_events + the status views
-- ============================================================================
-- THE ASK (Fred, 2026-10-14): a chip "Opened" or "Delivered (when is not opened)" on every email the Admin Review app
-- and the DERM Tracker send. Plan + audit: docs/superpowers/specs/2026-10-14-email-delivery-status-audit.md (read it:
-- why city emails never show Opened yet, the D2 "open unknown" look, the 4-week D5 gate). Fred's answers there.
-- "yes, build the back end now".
--
-- WHAT IT ADDS
--   1. public.email_events: one row per Resend event per recipient, written by edge fn webhook-resend (Svix-signed
--      webhook) and by its backfill mode (one 'backfill_summary' row per email, recipient ''). Key (svix_id, recipient).
--      APPEND ONLY (a trigger refuses UPDATE and DELETE) and never purged: Resend keeps emails 30 days, this table is
--      the long-term record. service_role only.
--      Rule 8: OPT-OUT of audit.logs. It is a sync-only append table (the Jobber/Samsara default): every row is
--      written once by the webhook and can never change, so an audit row would only duplicate it.
--   2. app_config: email_open_tracking_since (2026-10-14 17:54 UTC, the first send with the open pixel),
--      email_open_tracking_until (empty = still on; set it in the same minute tracking is switched off),
--      email_events_live_since (empty until the webhook is proven live; then a send with no event after 2 hours
--      reads no_status and reaches the health email).
--   3. public.v_email_delivery (service_role only): one row per resend_email_id over BOTH send logs, counted on the
--      To line only (city rows split their comma list; client rows are one row per address sharing one id).
--      delivery_status: not_delivered, partly_bounced, spam, opened, delivered, delivered_open_unknown,
--      partly_delivered, delayed, sending, no_status, no_record. Opens are NEVER credited on a city email (the archive
--      Bcc rides on every one, and Resend credits an open to every recipient: step 0, 2026-10-14), nor before
--      tracking started, nor on a summary-only row, nor when another address got the same email.
--      delivery_detail (jsonb, what the apps read) carries opened_at ONLY when the open is creditable.
--   4. public.v_visit_city_email_sends: 3 columns APPENDED (delivery_status, delivery_at, delivery_detail); every old
--      column unchanged (asserted). Both apps already read it.
--   5. public.v_client_email_sends (authenticated + service_role): one row per real DERM Tracker client send, no
--      addresses (DERM Tracker rule 13), same 3 columns.
--   6. public.fn_notification_health_items: 3 new kinds in Fred's daily health email (D4): email_not_delivered,
--      email_status_missing, email_delivery_incomplete. Real sends, real customers, last 7 days.
--
-- HOW TO RUN: one call, one transaction. Rehearse: node scripts/probes/apply_sql_file.mjs <file> rehearse
-- FIXTURES (every chip state, run apart from this DDL): scripts/probes/email_delivery_fixtures.sql (rolls back)
-- ROLLBACK: 2026-10-14_rollback_email_delivery_events.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
BEGIN
  IF md5(pg_get_viewdef('public.v_visit_city_email_sends'::regclass)) <> '7f694ca2c9748e2a2e93d2ac168a1d7a' THEN
    RAISE EXCEPTION 'v_visit_city_email_sends changed since 2026-10-14 15:00 ET: re-read it'; END IF;
  IF md5(pg_get_functiondef('public.fn_notification_health_items(jsonb, timestamptz)'::regprocedure)) <> '8b23fee8f29bab68c27f129dec9408a9' THEN
    RAISE EXCEPTION 'fn_notification_health_items changed since 2026-10-14 15:00 ET: re-read it'; END IF;
END $g$;

CREATE TEMP TABLE _sends0 ON COMMIT DROP AS
  SELECT visit_id, sent_at, via, sent_by_email, sent_by_name, app_label, recipients, with_manifest, with_photos, send_id, source_table
    FROM public.v_visit_city_email_sends;

-- 1 ---------------------------------------------------------------------------------------------------------
CREATE TABLE public.email_events (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  svix_id         text NOT NULL,
  resend_email_id text NOT NULL,
  event_type      text NOT NULL CHECK (event_type IN ('delivered', 'opened', 'bounced', 'delivery_delayed', 'complained',
                                                      'failed', 'suppressed', 'backfill_summary')),
  recipient       text NOT NULL DEFAULT '',
  occurred_at     timestamptz NOT NULL,
  received_at     timestamptz NOT NULL DEFAULT now(),
  detail          jsonb,
  CONSTRAINT email_events_svix_recipient_key UNIQUE (svix_id, recipient)
);
CREATE INDEX email_events_resend_email_id_idx ON public.email_events (resend_email_id);
ALTER TABLE public.email_events ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.email_events IS
  'What Resend reported about each email we sent, one row per event per recipient (2026-10-14_1505). Written by edge fn '
  'webhook-resend (Svix-signed) and its backfill (event_type backfill_summary, recipient ''''). Append only, never purged: '
  'Resend keeps 30 days, this is the long-term record. Read through public.v_email_delivery. Not audited (rule 8 opt-out).';

CREATE FUNCTION public.fn_email_events_append_only() RETURNS trigger
LANGUAGE plpgsql SET search_path TO 'public', 'pg_temp' AS $f$
BEGIN
  RAISE EXCEPTION 'public.email_events is append only (% refused): it is the record of what Resend reported', TG_OP;
END $f$;
CREATE TRIGGER email_events_append_only BEFORE UPDATE OR DELETE ON public.email_events
  FOR EACH ROW EXECUTE FUNCTION public.fn_email_events_append_only();

REVOKE ALL ON public.email_events FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.email_events TO service_role;
REVOKE ALL ON FUNCTION public.fn_email_events_append_only() FROM PUBLIC, anon, authenticated;

-- 2 ---------------------------------------------------------------------------------------------------------
INSERT INTO public.app_config (key, value) VALUES
  ('email_open_tracking_since', '2026-10-14 17:54:00+00'),
  ('email_open_tracking_until', ''),
  ('email_events_live_since', '')
ON CONFLICT (key) DO NOTHING;

-- 3 ---------------------------------------------------------------------------------------------------------
CREATE VIEW public.v_email_delivery AS
WITH cfg AS (
  -- an unparseable value reads as 'infinity' (fail safe), never raises: two apps read this through
  -- v_visit_city_email_sends, and a raise would blank their history.
  SELECT coalesce((SELECT CASE WHEN btrim(c.value) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}(:[0-9]{2}([.][0-9]+)?)?)?([+-][0-9]{2}(:?[0-9]{2})?)?$' THEN btrim(c.value)::timestamptz END
                       FROM public.app_config c WHERE c.key = 'email_open_tracking_since'), 'infinity'::timestamptz) AS track_since,
         coalesce((SELECT CASE WHEN btrim(c.value) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}(:[0-9]{2}([.][0-9]+)?)?)?([+-][0-9]{2}(:?[0-9]{2})?)?$' THEN btrim(c.value)::timestamptz END
                       FROM public.app_config c WHERE c.key = 'email_open_tracking_until'), 'infinity'::timestamptz) AS track_until,
         coalesce((SELECT CASE WHEN btrim(c.value) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}(:[0-9]{2}([.][0-9]+)?)?)?([+-][0-9]{2}(:?[0-9]{2})?)?$' THEN btrim(c.value)::timestamptz END
                       FROM public.app_config c WHERE c.key = 'email_events_live_since'), 'infinity'::timestamptz) AS live_since
),
rows AS (
  SELECT 'derm_email_sends'::text AS source_table, d.id AS send_id, d.resend_email_id, d.recipient_type AS target,
         d.sent_at, d.client_id, NULL::bigint AS visit_id, d.manifest_id, coalesce(d.is_test, false) AS is_test,
         d.recipient_email, d.cc_emails, d.bcc_emails
    FROM public.derm_email_sends d
   WHERE d.status = 'sent' AND nullif(btrim(d.resend_email_id), '') IS NOT NULL
  UNION ALL
  SELECT 'visit_photo_email_sends'::text, s.id, s.resend_email_id, 'city'::text, s.sent_at, v.client_id, s.visit_id,
         NULL::bigint, coalesce(s.is_test, false), s.recipient_email, s.cc_emails, s.bcc_emails
    FROM public.visit_photo_email_sends s
    LEFT JOIN public.visits v ON v.id = s.visit_id
   WHERE s.status = 'sent' AND nullif(btrim(s.resend_email_id), '') IS NOT NULL
),
sends AS (
  SELECT r.resend_email_id, min(r.source_table) AS source_table, min(r.send_id) AS send_id,
         array_agg(r.send_id ORDER BY r.send_id) AS send_ids, min(r.target) AS target, min(r.sent_at) AS sent_at,
         min(r.client_id) AS client_id, min(r.visit_id) AS visit_id, min(r.manifest_id) AS manifest_id,
         bool_or(r.is_test) AS is_test,
         -- a POSITIVE marker: client rows log the copies they really sent (send-derm-email :1396). City rows do not
         -- (the archive Bcc is never logged), which is why a city email is never creditable below, whatever this says.
         bool_and(coalesce(cardinality(r.cc_emails), 0) = 0 AND coalesce(cardinality(r.bcc_emails), 0) = 0) AS no_copies
    FROM rows r
   GROUP BY r.resend_email_id
),
to_list AS (
  SELECT DISTINCT r.resend_email_id, lower(btrim(a.addr)) AS addr
    FROM rows r
    CROSS JOIN LATERAL unnest(string_to_array(coalesce(r.recipient_email, ''), ',')) a(addr)
   WHERE position('@' IN a.addr) > 0
),
addr AS (
  SELECT t.resend_email_id, t.addr,
         coalesce(bool_or(e.event_type IN ('bounced', 'failed', 'suppressed')), false) AS refused,
         coalesce(bool_or(e.event_type IN ('delivered', 'complained')), false) AS delivered,
         coalesce(bool_or(e.event_type = 'complained'), false) AS complained,
         coalesce(bool_or(e.event_type = 'delivery_delayed'), false) AS delayed,
         max(e.occurred_at) FILTER (WHERE e.event_type IN ('delivered', 'complained')) AS delivered_at,
         min(e.occurred_at) FILTER (WHERE e.event_type IN ('bounced', 'failed', 'suppressed')) AS refused_at,
         (array_agg(e.detail ORDER BY e.occurred_at)
            FILTER (WHERE e.event_type IN ('bounced', 'failed', 'suppressed') AND e.detail IS NOT NULL))[1] AS refused_detail
    FROM to_list t
    LEFT JOIN public.email_events e ON e.resend_email_id = t.resend_email_id AND e.recipient = t.addr
   GROUP BY t.resend_email_id, t.addr
),
agg AS (
  SELECT a.resend_email_id, count(*) AS to_count,
         count(*) FILTER (WHERE a.delivered AND NOT a.refused) AS delivered_count,
         count(*) FILTER (WHERE a.refused) AS refused_count,
         bool_or(a.complained) AS complained,
         bool_or(a.delayed AND NOT a.delivered AND NOT a.refused) AS delayed,
         max(a.delivered_at) AS delivered_at, min(a.delivered_at) AS first_delivered_at, min(a.refused_at) AS refused_at,
         (array_agg(a.refused_detail ORDER BY a.refused_at) FILTER (WHERE a.refused_detail IS NOT NULL))[1] AS refused_detail
    FROM addr a
   GROUP BY a.resend_email_id
),
ev AS (
  SELECT e.resend_email_id,
         count(*) FILTER (WHERE e.event_type <> 'backfill_summary') AS event_count,
         min(e.occurred_at) FILTER (WHERE e.event_type = 'opened') AS opened_at,
         -- an event for an address NOT on the To line (an archive or internal copy): the email had other recipients
         coalesce(bool_or(e.event_type <> 'backfill_summary' AND e.recipient <> '' AND t.addr IS NULL), false) AS other_recipient,
         (array_agg(e.detail ORDER BY e.received_at DESC) FILTER (WHERE e.event_type = 'backfill_summary'))[1] AS summary
    FROM public.email_events e
    LEFT JOIN to_list t ON t.resend_email_id = e.resend_email_id AND t.addr = e.recipient
   GROUP BY e.resend_email_id
),
base AS (
  SELECT s.*, cfg.track_since, cfg.track_until, cfg.live_since,
         coalesce(g.to_count, 0) AS to_count, coalesce(g.delivered_count, 0) AS delivered_count,
         coalesce(g.refused_count, 0) AS refused_count, coalesce(g.complained, false) AS complained,
         coalesce(g.delayed, false) AS delayed, g.delivered_at, g.first_delivered_at, g.refused_at, g.refused_detail,
         coalesce(ev.event_count, 0) AS event_count, ev.opened_at, coalesce(ev.other_recipient, false) AS other_recipient,
         ev.summary, (ev.summary IS NOT NULL AND coalesce(ev.event_count, 0) = 0) AS summary_only
    FROM sends s
    CROSS JOIN cfg
    LEFT JOIN agg g ON g.resend_email_id = s.resend_email_id
    LEFT JOIN ev ON ev.resend_email_id = s.resend_email_id
),
reasoned AS (
  SELECT b.*,
         CASE WHEN b.sent_at < b.track_since THEN 'before_tracking'
              WHEN b.sent_at >= b.track_until THEN 'tracking_off'
              WHEN b.summary_only THEN 'summary_only'
              WHEN b.target = 'city' THEN 'archive_copy'
              WHEN NOT b.no_copies OR b.other_recipient THEN 'other_recipients'
         END AS open_unknown_reason
    FROM base b
),
st AS (
  SELECT r.*,
         CASE
           -- a backfill summary (Resend's last_event, or assumed for an email Resend no longer holds): Fred,
           -- 2026-10-14, "Mark them all as Delivered", except what Resend itself reports as refused
           WHEN r.summary_only THEN
             CASE WHEN r.summary->>'last_event' IN ('bounced', 'failed', 'suppressed') THEN 'not_delivered'
                  ELSE 'delivered_open_unknown' END
           WHEN r.refused_count > 0 AND r.delivered_count = 0 AND r.refused_count = r.to_count THEN 'not_delivered'
           WHEN r.refused_count > 0 THEN 'partly_bounced'
           WHEN r.complained THEN 'spam'
           WHEN r.to_count > 0 AND r.delivered_count = r.to_count THEN
             CASE WHEN r.open_unknown_reason IS NOT NULL THEN 'delivered_open_unknown'
                  WHEN r.opened_at IS NOT NULL THEN 'opened'
                  ELSE 'delivered' END
           WHEN r.delivered_count > 0 THEN 'partly_delivered'
           WHEN r.delayed THEN 'delayed'
           WHEN r.sent_at > now() - interval '2 hours' THEN 'sending'
           WHEN r.sent_at >= r.live_since THEN 'no_status'
           ELSE 'no_record'
         END AS delivery_status,
         CASE WHEN r.opened_at >= r.first_delivered_at
              THEN floor(extract(epoch FROM r.opened_at - r.first_delivered_at))::int END AS open_gap_seconds,
         regexp_replace(coalesce(r.refused_detail->'bounce'->>'message', r.refused_detail->'failed'->>'reason',
                                 r.refused_detail->'suppressed'->>'message', r.refused_detail->>'message',
                                 r.refused_detail->>'reason'),
                        '[^[:space:]<>@]+@[^[:space:]<>]+', 'an inbox', 'g') AS bounce_reason
    FROM reasoned r
),
fin AS (
  SELECT st.*,
         CASE st.delivery_status
           WHEN 'opened' THEN st.opened_at
           WHEN 'not_delivered' THEN coalesce(st.refused_at, CASE WHEN st.summary_only THEN st.sent_at END)
           WHEN 'partly_bounced' THEN st.refused_at
           WHEN 'delivered_open_unknown' THEN coalesce(st.delivered_at, st.sent_at)
           WHEN 'delivered' THEN st.delivered_at
           WHEN 'spam' THEN st.delivered_at
           WHEN 'partly_delivered' THEN st.delivered_at
         END AS delivery_at
    FROM st
)
SELECT fin.resend_email_id, fin.source_table, fin.send_id, fin.send_ids, fin.target, fin.sent_at, fin.client_id,
       fin.visit_id, fin.manifest_id, fin.is_test, fin.delivery_status, fin.delivery_at, fin.to_count,
       fin.delivered_count, fin.refused_count, fin.delivered_at, fin.opened_at, fin.open_gap_seconds,
       fin.open_unknown_reason IS NULL AS open_creditable, fin.open_unknown_reason, fin.bounce_reason,
       fin.summary_only, fin.summary->>'basis' AS summary_basis, fin.summary->>'last_event' AS summary_last_event,
       fin.event_count,
       -- what the apps read. opened_at and the gap ONLY when the open is creditable: a city open is stored above
       -- (for the D5 gate) and must never reach a screen.
       jsonb_strip_nulls(jsonb_build_object(
         'target', fin.target, 'to_count', fin.to_count, 'delivered_count', fin.delivered_count,
         'refused_count', fin.refused_count, 'delivered_at', fin.delivered_at,
         'opened_at', CASE WHEN fin.open_unknown_reason IS NULL THEN fin.opened_at END,
         'open_gap_seconds', CASE WHEN fin.open_unknown_reason IS NULL THEN fin.open_gap_seconds END,
         'open_unknown_reason', fin.open_unknown_reason, 'bounce_reason', fin.bounce_reason,
         'summary_only', fin.summary_only, 'summary_basis', fin.summary->>'basis')) AS delivery_detail
  FROM fin;
COMMENT ON VIEW public.v_email_delivery IS
  'One row per email we sent (resend_email_id), with what Resend reported (2026-10-14_1505). Counted on the To line only. '
  'Opens never creditable on a city email (archive Bcc), before tracking, or on a summary. service_role only; the apps '
  'read it through v_visit_city_email_sends and v_client_email_sends (delivery_status, delivery_at, delivery_detail).';
REVOKE ALL ON public.v_email_delivery FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_email_delivery TO service_role;

-- 4 ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_visit_city_email_sends AS
 SELECT st.visit_id,
    h.sent_at,
    h.via,
    h.sent_by_email,
    COALESCE(e.full_name, h.sent_by_email) AS sent_by_name,
        CASE h.via
            WHEN 'admin_review'::text THEN 'Admin Review'::text
            WHEN 'derm_tracker'::text THEN 'DERM Tracker'::text
            ELSE 'Automatic (system)'::text
        END AS app_label,
    h.recipients,
    h.with_manifest,
    h.with_photos,
    h.send_id,
    h.source_table,
    ed.delivery_status,
    ed.delivery_at,
    ed.delivery_detail
   FROM (((v_visit_city_email_state st
     CROSS JOIN LATERAL ( SELECT s.sent_at,
            'admin_review'::text AS via,
            s.sent_by_email,
            s.recipient_email AS recipients,
            ((s.include_manifest IS TRUE) OR ((s.include_manifest IS NULL) AND (EXISTS ( SELECT 1
                   FROM unnest(st.manifest_ids) m(id)
                  WHERE (s.sent_at >= COALESCE(( SELECT max(r.generated_at) AS max
                           FROM derm.redacted_manifest_docs r
                          WHERE ((r.manifest_id = m.id) AND (r.client_id = st.client_id))), ( SELECT max(COALESCE(sh.uploaded_at, sh.generated_at, sh.created_at)) AS max
                           FROM derm.manifest_visit_sheets sh
                          WHERE ((sh.manifest_id = m.id) AND (sh.client_id = st.client_id) AND (sh.deleted_at IS NULL) AND (COALESCE(sh.photo_bucket, ''::text) <> ''::text) AND (COALESCE(sh.photo_path, ''::text) <> ''::text))))))))) AS with_manifest,
            s.include_photos AS with_photos,
            s.id AS send_id,
            'visit_photo_email_sends'::text AS source_table,
            s.resend_email_id
           FROM visit_photo_email_sends s
          WHERE ((s.visit_id = st.visit_id) AND (s.status = 'sent'::text) AND (NOT s.is_test))
        UNION ALL
         SELECT s.sent_at,
                CASE
                    WHEN ((s.sent_by_email IS NULL) AND (s.sent_at >= '2026-09-15 13:07:34.336825+00'::timestamp with time zone)) THEN 'automatic'::text
                    ELSE 'derm_tracker'::text
                END AS "case",
            s.sent_by_email,
            s.recipient_email,
            (COALESCE(s.reason, ''::text) !~~ 'attachment:manifest_images%'::text),
                CASE
                    WHEN (COALESCE(s.reason, ''::text) ~~ 'attachment:manifest_images%'::text) THEN false
                    ELSE s.include_photos
                END AS include_photos,
            s.id,
            'derm_email_sends'::text AS text,
            s.resend_email_id
           FROM derm_email_sends s
          WHERE ((s.manifest_id = ANY (st.manifest_ids)) AND (s.client_id = st.client_id) AND (s.recipient_type = 'city'::text) AND (s.status = 'sent'::text) AND (NOT s.is_test))) h)
     LEFT JOIN LATERAL ( SELECT emp.full_name
           FROM employees emp
          WHERE ((h.sent_by_email IS NOT NULL) AND (lower(btrim(emp.email)) = lower(btrim(h.sent_by_email))))
          ORDER BY emp.id
         LIMIT 1) e ON (true))
     LEFT JOIN public.v_email_delivery ed ON ((ed.resend_email_id = h.resend_email_id)));

-- 5 ---------------------------------------------------------------------------------------------------------
CREATE VIEW public.v_client_email_sends AS
SELECT ed.manifest_id, ed.client_id, ed.sent_at, d.sent_by_email,
       COALESCE(emp.full_name, d.sent_by_email) AS sent_by_name, ed.to_count, d.include_photos AS with_photos,
       ed.send_id, ed.send_ids, ed.delivery_status, ed.delivery_at, ed.delivery_detail
  FROM public.v_email_delivery ed
  JOIN public.derm_email_sends d ON d.id = ed.send_id
  LEFT JOIN LATERAL (SELECT e.full_name FROM public.employees e
                      WHERE d.sent_by_email IS NOT NULL AND lower(btrim(e.email)) = lower(btrim(d.sent_by_email))
                      ORDER BY e.id LIMIT 1) emp ON true
 WHERE ed.source_table = 'derm_email_sends' AND ed.target = 'client' AND NOT ed.is_test;
COMMENT ON VIEW public.v_client_email_sends IS
  'One row per real DERM Tracker client email (2026-10-14_1505), with its delivery status. No addresses (DERM Tracker '
  'rule 13). For the visit page client line and the Manifests Emailed chip.';
REVOKE ALL ON public.v_client_email_sends FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_client_email_sends TO authenticated, service_role;

-- 6 ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_notification_health_items(p_city jsonb, p_as_of timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH cfg AS (
    SELECT public.fn_city_email_delay() AS delay,
           coalesce((SELECT nullif(btrim(value), '')::timestamptz FROM public.app_config WHERE key = 'city_email_start_from'),
                    'infinity'::timestamptz) AS go_live,
           -- the first visit date the city email covers: the same constant as public.fn_admin_review_pending
           DATE '2026-09-15' AS scope_from,
           (p_as_of AT TIME ZONE 'America/New_York')::date AS today
  ),
  listed AS (
    SELECT DISTINCT (e->>'visit_id')::bigint AS visit_id
    FROM jsonb_array_elements(coalesce(p_city, '[]'::jsonb)) e
  ),
  -- real Admin Review sends (send-visit-photos-email)
  ar_rows AS (
    SELECT s.visit_id, s.sent_at, s.include_manifest IS TRUE AS with_manifest
    FROM public.visit_photo_email_sends s
    WHERE s.status = 'sent' AND NOT coalesce(s.is_test, false) AND s.sent_at <= p_as_of
  ),
  -- real city sends from the DERM Tracker or the automatic email, for a LIVE manifest linked to the visit and the
  -- visit's own client (derm_email_sends has no visit_id; that pair is the finest grain it has). A row whose reason
  -- starts 'attachment:manifest_images' is a letter that went with NOTHING attached (send-derm-email could build no
  -- report), so it does not count as the city having the manifest. A client copy (recipient_type 'client') never counts.
  dt_rows AS (
    SELECT mv.visit_id, d.sent_at, (d.sent_by_email IS NULL AND d.sent_at >= cfg.go_live) AS automatic
    FROM public.manifest_visits mv
    JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL
    JOIN public.visits v ON v.id = mv.visit_id
    JOIN public.derm_email_sends d ON d.manifest_id = mv.manifest_id AND d.client_id = v.client_id
    CROSS JOIN cfg
    WHERE d.recipient_type = 'city' AND d.status = 'sent' AND NOT coalesce(d.is_test, false)
      AND coalesce(d.reason, '') NOT LIKE 'attachment:manifest_images%'
      AND d.sent_at <= p_as_of
  ),
  ar AS (
    SELECT visit_id, min(sent_at) AS first_at, bool_or(with_manifest) AS any_with_manifest,
           max(sent_at) FILTER (WHERE NOT with_manifest) AS last_without_at
    FROM ar_rows GROUP BY visit_id
  ),
  dt AS (
    SELECT visit_id, min(sent_at) AS first_at, (array_agg(automatic ORDER BY sent_at))[1] AS first_automatic
    FROM dt_rows GROUP BY visit_id
  ),
  base AS (
    SELECT v.id AS visit_id FROM public.visits v, cfg
     WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.visit_date >= cfg.scope_from
    UNION SELECT visit_id FROM listed
    UNION SELECT ar.visit_id FROM ar, cfg WHERE ar.last_without_at >= cfg.go_live
  ),
  f AS (
    SELECT b.visit_id, v.client_id, c.client_code, v.property_id, coalesce(p.city, 'no city') AS city,
           v.visit_date, v.visit_status, v.deleted_at, v.derm_required,
           EXISTS (SELECT 1 FROM listed l WHERE l.visit_id = b.visit_id) AS listed,
           EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e
                    WHERE e IS NOT NULL AND position('@' IN e) > 0) AS has_inbox,
           EXISTS (SELECT 1 FROM public.v_visit_not_for_city n WHERE n.visit_id = b.visit_id) AS grey_water,
           EXISTS (SELECT 1 FROM public.manifest_visits mv
                     JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL
                    WHERE mv.visit_id = b.visit_id) AS has_manifest,
           coalesce(public.fn_is_non_customer(v.client_id, ARRAY['test', 'fixture']), false) AS test_client,
           ar.first_at AS ar_first_at, coalesce(ar.any_with_manifest, false) AS ar_with_manifest, ar.last_without_at,
           dt.first_at AS dt_first_at, dt.first_automatic,
           coalesce(pc.total_images, 0) AS photos_total, coalesce(pc.classified_images, 0) AS photos_sorted
    FROM base b
    LEFT JOIN public.visits v ON v.id = b.visit_id
    LEFT JOIN public.clients c ON c.id = v.client_id
    LEFT JOIN public.properties p ON p.id = v.property_id
    LEFT JOIN ar ON ar.visit_id = b.visit_id
    LEFT JOIN dt ON dt.visit_id = b.visit_id
    LEFT JOIN public.v_visit_photo_counts pc ON pc.visit_id = b.visit_id
  ),
  label AS (
    SELECT f.*, format('Visit %s (%s, %s, %s)', f.visit_id, coalesce(f.client_code, 'no client'), f.city,
                       coalesce(to_char(f.visit_date, 'Mon FMDD'), 'no date')) AS who
    FROM f
  ),
  -- A. listed, although the raw tables say no city email is due or one already went
  a AS (
    SELECT l.*, array_remove(ARRAY[
             CASE WHEN l.visit_status IS DISTINCT FROM 'completed' OR l.deleted_at IS NOT NULL
                  THEN 'the visit is not a live completed visit' END,
             CASE WHEN l.visit_date < cfg.scope_from
                  THEN 'it is dated before the city email started (Sep 15)' END,
             CASE WHEN l.test_client THEN 'it belongs to a test client' END,
             CASE WHEN l.derm_required IS FALSE
                  THEN 'it is not a DERM job (DERM required is off), so no city email is due' END,
             CASE WHEN l.ar_first_at IS NOT NULL
                  THEN 'Admin Review already sent its city email on ' || to_char(l.ar_first_at AT TIME ZONE 'America/New_York', 'Mon FMDD') END,
             CASE WHEN l.dt_first_at IS NOT NULL
                  THEN 'its manifest already went to the city on ' || to_char(l.dt_first_at AT TIME ZONE 'America/New_York', 'Mon FMDD')
                       || CASE WHEN l.first_automatic THEN ' (the automatic email)' ELSE ' (DERM Tracker, Send to city)' END END,
             CASE WHEN l.grey_water THEN 'it is grey water, which never goes to the city' END,
             CASE WHEN NOT l.has_inbox THEN 'its property has no city inbox on file' END
           ], NULL) AS why
    FROM label l CROSS JOIN cfg WHERE l.listed
  ),
  -- C. the city has the report but not the manifest, the manifest IS linked, and it has not followed well past the
  --    automatic email's delay. (No manifest linked at all is F, not C.) Dated since go-live only.
  c0 AS (
    SELECT l.* FROM label l, cfg
    WHERE l.last_without_at IS NOT NULL AND NOT l.ar_with_manifest AND l.dt_first_at IS NULL AND l.has_manifest
      AND l.deleted_at IS NULL AND l.visit_status = 'completed' AND l.visit_date >= cfg.scope_from AND NOT l.test_client
      AND l.derm_required IS NOT FALSE AND NOT l.grey_water
      AND l.last_without_at >= cfg.go_live
      AND l.last_without_at < p_as_of - (cfg.delay + interval '2 days')
  ),
  c AS (
    SELECT c0.*,
           (SELECT string_agg(DISTINCT k.status, ', ')
              FROM public.manifest_visits mv
              JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL
              JOIN derm.v_city_email_candidates k ON k.manifest_id = mv.manifest_id AND k.client_id = c0.client_id
             WHERE mv.visit_id = c0.visit_id) AS sweep_status
    FROM c0
  ),
  -- D. a property with a DERM visit since go-live and no city inbox, in a city where 3+ other properties have one
  props AS (
    SELECT p.id, p.client_id, p.city, lower(btrim(p.city)) AS ck,
           EXISTS (SELECT 1 FROM unnest(coalesce(p.city_emails, '{}'::text[])) e
                    WHERE e IS NOT NULL AND position('@' IN e) > 0) AS has_inbox
    FROM public.properties p
    WHERE p.deleted_at IS NULL AND NOT coalesce(p.is_billing, false) AND nullif(btrim(p.city), '') IS NOT NULL
  ),
  d0 AS (
    SELECT x.id, x.city, x.ck, cl.client_code,
           (SELECT string_agg(v.id || ' (' || to_char(v.visit_date, 'Mon FMDD') || ')', ', ' ORDER BY v.visit_date, v.id)
              FROM public.visits v, cfg
             WHERE v.property_id = x.id AND v.deleted_at IS NULL AND v.visit_status = 'completed'
               AND v.derm_required IS TRUE AND v.visit_date >= cfg.scope_from) AS derm_visits
    FROM props x
    JOIN public.clients cl ON cl.id = x.client_id
    WHERE NOT x.has_inbox
      AND NOT coalesce(public.fn_is_non_customer(x.client_id, ARRAY['test', 'fixture']), false)
  ),
  d AS (
    SELECT d0.*, (SELECT count(*) FROM props y WHERE y.ck = d0.ck AND y.id <> d0.id AND y.has_inbox) AS city_inboxes
    FROM d0 WHERE d0.derm_visits IS NOT NULL
  ),
  -- E. the two 11 AM reminders' own run records (one public.sync_log row per real run, written by the edge functions
  --    and, when the vault key is missing, by the cron wrappers). A [TEST] run logs under '<source>_test' and carries
  --    details.test = true, and never counts. Clean word 'success'; failure word 'error'.
  e AS (
    SELECT s.src, s.label, s.job, r.last_at, r.last_status, r.last_error
    FROM (VALUES ('admin_review_reminder', 'Admin Review', 'admin-review-reminder'),
                 ('stamp_sheets_reminder', 'Stamp Studio', 'stamp-sheets-reminder'),
                 ('time_on_site_reminder', 'time on site', 'time-on-site-reminder')) s(src, label, job)
    LEFT JOIN LATERAL (
      SELECT l.started_at AS last_at, l.status AS last_status,
             coalesce(l.error_details->>'message', l.details->>'reason', 'no reason recorded') AS last_error
      FROM public.sync_log l
      WHERE l.sync_source = s.src AND coalesce(l.details->>'test', 'false') <> 'true' AND l.started_at <= p_as_of
      ORDER BY l.started_at DESC LIMIT 1) r ON true
  ),
  items AS (
    SELECT jsonb_build_object(
             'kind', 'city_list_false_positive:visit-' || a.visit_id, 'issue', 'city_list_false_positive',
             'visit', a.visit_id, 'client_code', a.client_code, 'property', a.property_id,
             'reason', a.who || ' is on the Admin Review "city email not sent" list, but ' || array_to_string(a.why, '; ') || '.',
             'what_to_do', 'Do not send it to the city before checking. The 11 AM list (public.fn_admin_review_pending) and '
                           'this check disagree about this visit: find which of the two is wrong and fix that one.') AS item
      FROM a WHERE cardinality(a.why) > 0
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'city_list_missed:visit-' || l.visit_id, 'issue', 'city_list_missed',
             'visit', l.visit_id, 'client_code', l.client_code, 'property', l.property_id,
             'reason', l.who || ' is a completed DERM job with a city inbox, a manifest and all ' || l.photos_total
                       || ' photos sorted, and nothing has gone to the city, but the Admin Review list leaves it out, so nobody is reminded.',
             'what_to_do', 'Send it to the city from Admin Review, then find out why public.fn_admin_review_pending skipped it.')
      FROM label l CROSS JOIN cfg
     WHERE NOT l.listed AND l.deleted_at IS NULL AND l.visit_status = 'completed' AND l.visit_date >= cfg.scope_from
       AND l.derm_required IS TRUE AND NOT l.test_client AND l.has_inbox AND NOT l.grey_water AND l.has_manifest
       AND l.ar_first_at IS NULL AND l.dt_first_at IS NULL
       AND l.photos_total > 0 AND l.photos_sorted >= l.photos_total
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'manifest_follow_stalled:visit-' || c.visit_id, 'issue', 'manifest_follow_stalled',
             'visit', c.visit_id, 'client_code', c.client_code, 'property', c.property_id, 'sweep_status', c.sweep_status,
             'reason', c.who || ': Admin Review sent the city report without the manifest on '
                       || to_char(c.last_without_at AT TIME ZONE 'America/New_York', 'Mon FMDD') || ', and the manifest has still not gone to the city '
                       || floor(extract(epoch FROM p_as_of - c.last_without_at) / 86400)::int || ' days later. '
                       || CASE WHEN c.sweep_status IS NULL THEN 'Its manifest has no blacked-out copy yet, so the automatic email cannot send it.'
                               ELSE 'The automatic email for its manifest reads "' || c.sweep_status || '".' END,
             'what_to_do', 'Open the manifest in the DERM Tracker and press Send to city, or fix what holds the automatic email.')
      FROM c
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'city_inbox_missing:property-' || d.id, 'issue', 'city_inbox_missing',
             'property', d.id, 'client_code', d.client_code,
             'reason', 'Property ' || d.id || ' (' || d.client_code || ', ' || d.city || ') has DERM visits but no city inbox, while '
                       || d.city_inboxes || ' other ' || d.city || ' properties have one, so its city emails cannot go and the 11 AM list never shows them. '
                       || 'Completed DERM visits since Sep 15: ' || d.derm_visits || '.',
             'what_to_do', 'Add the city inbox to property ' || d.id || ' (the address the other ' || d.city
                           || ' properties use), then send its DERM visits to the city from Admin Review.')
      FROM d WHERE d.city_inboxes >= 3
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'reminder_not_run:' || e.src, 'issue', 'reminder_not_run', 'source', e.src,
             'reason', 'The ' || e.label || ' 11 AM Slack reminder has written no run record since '
                       || to_char(e.last_at AT TIME ZONE 'America/New_York', 'Mon FMDD FMHH12:MI AM') || ' ET. It writes one every day, '
                       'also when there is nothing to post, so the cron job did not run or the call never reached the reminder.',
             'what_to_do', 'Check cron job ' || e.job || ' in cron.job_run_details, the pg_net responses, and the logs of the edge function ' || e.job || '.')
      FROM e WHERE e.last_at IS NOT NULL AND e.last_at < p_as_of - interval '26 hours'
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'reminder_failed:' || e.src, 'issue', 'reminder_failed', 'source', e.src,
             'reason', 'The ' || e.label || ' 11 AM Slack reminder failed on its last run ('
                       || to_char(e.last_at AT TIME ZONE 'America/New_York', 'Mon FMDD FMHH12:MI AM') || ' ET): ' || left(e.last_error, 300) || '.',
             'what_to_do', 'Read that run''s row in public.sync_log (sync_source ' || e.src || ') and the logs of the edge function '
                           || e.job || ', fix the cause, and check Slack got the next post.')
      FROM e WHERE e.last_status = 'error'
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'no_manifest_after_14_days:visit-' || l.visit_id, 'issue', 'no_manifest_after_14_days',
             'visit', l.visit_id, 'client_code', l.client_code, 'property', l.property_id,
             'reason', l.who || ' is a completed DERM job with a city inbox, and ' || (cfg.today - l.visit_date)
                       || ' days later no manifest is linked to it, so its city email cannot go and the 11 AM list holds it.'
                       || coalesce(' Admin Review sent the city report without the manifest on '
                                   || to_char(l.last_without_at AT TIME ZONE 'America/New_York', 'Mon FMDD') || '.', ''),
             'what_to_do', 'Link this pumping''s manifest to the visit (DERM Tracker, or log the dump in the DUMP app) so the city '
                           'email can go. If there is no manifest for it, ask Fred whether the visit still needs a city email.')
      FROM label l CROSS JOIN cfg
     WHERE l.deleted_at IS NULL AND l.visit_status = 'completed' AND l.visit_date >= cfg.scope_from
       AND l.derm_required IS TRUE AND NOT l.test_client AND l.has_inbox AND NOT l.grey_water
       AND NOT l.has_manifest AND NOT l.ar_with_manifest
       AND l.visit_date < cfg.today - 14
    UNION ALL
    -- 2026-10-14_1505: what Resend reported back (public.v_email_delivery). Real sends to real customers only, last 7
    -- days, so a stale item ages out. Never an address in the text: bounce_reason is masked in the view.
    SELECT jsonb_build_object(
             'kind', 'email_not_delivered:' || ed.source_table || '-' || ed.send_id, 'issue', 'email_not_delivered',
             'client_code', cl.client_code, 'visit', ed.visit_id, 'manifest', ed.manifest_id, 'target', ed.target,
             'reason', CASE ed.target WHEN 'city' THEN 'The city email' ELSE 'The client email' END || ' for '
                       || coalesce(cl.client_code, 'no client') || ' sent '
                       || to_char(ed.sent_at AT TIME ZONE 'America/New_York', 'Mon FMDD FMHH12:MI AM') || ' ET '
                       || CASE ed.delivery_status
                            WHEN 'spam' THEN 'was reported as spam by the receiving email system.'
                            WHEN 'partly_bounced' THEN 'was refused by ' || ed.refused_count || ' of ' || ed.to_count || ' inboxes'
                                                       || coalesce(': ' || ed.bounce_reason, '') || '.'
                            ELSE 'was not delivered' || coalesce(': ' || ed.bounce_reason, '') || '.' END,
             'what_to_do', CASE ed.target
                             WHEN 'city' THEN 'Check the city emails on the property in the Client App, then send it to the city again.'
                             ELSE 'Check the client''s report email in the Client App, then send it again.' END)
      FROM public.v_email_delivery ed
      LEFT JOIN public.clients cl ON cl.id = ed.client_id
     WHERE NOT ed.is_test AND NOT coalesce(public.fn_is_non_customer(ed.client_id, ARRAY['test', 'fixture']), false)
       AND ed.delivery_status IN ('not_delivered', 'partly_bounced', 'spam')
       AND ed.sent_at > p_as_of - interval '7 days' AND ed.sent_at <= p_as_of
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'email_status_missing:' || ed.source_table || '-' || ed.send_id, 'issue', 'email_status_missing',
             'client_code', cl.client_code, 'visit', ed.visit_id, 'manifest', ed.manifest_id, 'target', ed.target,
             'reason', 'The ' || ed.target || ' email for ' || coalesce(cl.client_code, 'no client') || ' sent '
                       || to_char(ed.sent_at AT TIME ZONE 'America/New_York', 'Mon FMDD FMHH12:MI AM')
                       || ' ET has no delivery report from Resend after 2 hours, so the Resend webhook may have stopped.',
             'what_to_do', 'Check the webhook in the Resend dashboard (Webhooks, its recent attempts) and the logs of the edge '
                           'function webhook-resend. Once it works, run its backfill ({"backfill": true} with the service key) to fill the gap.')
      FROM public.v_email_delivery ed
      LEFT JOIN public.clients cl ON cl.id = ed.client_id
     WHERE NOT ed.is_test AND NOT coalesce(public.fn_is_non_customer(ed.client_id, ARRAY['test', 'fixture']), false)
       AND ed.delivery_status = 'no_status'
       AND ed.sent_at > p_as_of - interval '7 days' AND ed.sent_at < p_as_of - interval '2 hours'
    UNION ALL
    SELECT jsonb_build_object(
             'kind', 'email_delivery_incomplete:' || ed.source_table || '-' || ed.send_id, 'issue', 'email_delivery_incomplete',
             'client_code', cl.client_code, 'visit', ed.visit_id, 'manifest', ed.manifest_id, 'target', ed.target,
             'reason', 'The ' || ed.target || ' email for ' || coalesce(cl.client_code, 'no client') || ' sent '
                       || to_char(ed.sent_at AT TIME ZONE 'America/New_York', 'Mon FMDD FMHH12:MI AM') || ' ET reached '
                       || ed.delivered_count || ' of ' || ed.to_count || ' inboxes and is still '
                       || CASE ed.delivery_status WHEN 'delayed' THEN 'being held by the receiving email system' ELSE 'waiting for the rest' END
                       || ' a day later.',
             'what_to_do', 'Look the email up in the Resend dashboard (Emails). If an inbox keeps refusing it, check that address on the '
                           'property or client, then send again.')
      FROM public.v_email_delivery ed
      LEFT JOIN public.clients cl ON cl.id = ed.client_id
     WHERE NOT ed.is_test AND NOT coalesce(public.fn_is_non_customer(ed.client_id, ARRAY['test', 'fixture']), false)
       AND ed.delivery_status IN ('partly_delivered', 'delayed')
       AND ed.sent_at > p_as_of - interval '7 days' AND ed.sent_at < p_as_of - interval '24 hours'
  )
  -- one item per key: the health scan upserts on (check, key), and a repeated key in one run would abort it
  SELECT coalesce(jsonb_agg(u.item ORDER BY u.item->>'kind'), '[]'::jsonb)
  FROM (SELECT DISTINCT ON (i.item->>'kind') i.item FROM items i ORDER BY i.item->>'kind') u
$function$;

-- VERIFY ----------------------------------------------------------------------------------------------------
DO $v$
DECLARE n int; a text;
BEGIN
  -- V1 grants, by privilege AND by the stored ACL
  IF has_table_privilege('anon', 'public.email_events', 'SELECT') OR has_table_privilege('authenticated', 'public.email_events', 'SELECT')
     OR has_table_privilege('authenticated', 'public.email_events', 'INSERT')
     OR NOT has_table_privilege('service_role', 'public.email_events', 'INSERT') THEN RAISE EXCEPTION 'V1 email_events grants'; END IF;
  IF has_table_privilege('anon', 'public.v_email_delivery', 'SELECT') OR has_table_privilege('authenticated', 'public.v_email_delivery', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.v_email_delivery', 'SELECT') THEN RAISE EXCEPTION 'V1 v_email_delivery grants'; END IF;
  IF has_table_privilege('anon', 'public.v_client_email_sends', 'SELECT') OR NOT has_table_privilege('authenticated', 'public.v_client_email_sends', 'SELECT')
     THEN RAISE EXCEPTION 'V1 v_client_email_sends grants'; END IF;
  SELECT relacl::text INTO a FROM pg_class WHERE oid = 'public.v_visit_city_email_sends'::regclass;
  IF a <> '{postgres=arwdDxtm/postgres,db_backup_reader=r/postgres,authenticated=r/postgres,service_role=r/postgres}' THEN
    RAISE EXCEPTION 'V1 v_visit_city_email_sends ACL changed: %', a; END IF;
  IF has_function_privilege('authenticated', 'public.fn_email_events_append_only()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.fn_email_events_append_only()', 'EXECUTE') THEN RAISE EXCEPTION 'V1 trigger fn grants'; END IF;
  SELECT proacl::text INTO a FROM pg_proc WHERE oid = 'public.fn_notification_health_items(jsonb, timestamptz)'::regprocedure;
  IF a <> '{postgres=X/postgres,service_role=X/postgres}' THEN RAISE EXCEPTION 'V1 fn_notification_health_items ACL changed: %', a; END IF;

  -- V2 every old column of v_visit_city_email_sends is unchanged, both ways, and no row was added or lost
  SELECT count(*) INTO n FROM (
    (SELECT visit_id, sent_at, via, sent_by_email, sent_by_name, app_label, recipients, with_manifest, with_photos, send_id, source_table
       FROM public.v_visit_city_email_sends EXCEPT ALL SELECT * FROM _sends0)
    UNION ALL
    (SELECT * FROM _sends0 EXCEPT ALL
     SELECT visit_id, sent_at, via, sent_by_email, sent_by_name, app_label, recipients, with_manifest, with_photos, send_id, source_table
       FROM public.v_visit_city_email_sends)) x;
  IF n <> 0 THEN RAISE EXCEPTION 'V2 v_visit_city_email_sends old columns changed in % row(s)', n; END IF;

  -- V3 nothing is stored yet, so every real send reads no_record (live_since is empty) or sending; none is lost
  SELECT count(*) INTO n FROM public.v_email_delivery WHERE delivery_status NOT IN ('no_record', 'sending');
  IF n <> 0 THEN RAISE EXCEPTION 'V3 % send(s) have a status with no events', n; END IF;
  SELECT count(*) INTO n FROM public.v_visit_city_email_sends WHERE delivery_status IS NULL;
  IF n <> 0 THEN RAISE EXCEPTION 'V3 % city send(s) found no delivery row', n; END IF;

  -- V4 append only
  BEGIN
    INSERT INTO public.email_events (svix_id, resend_email_id, event_type, occurred_at) VALUES ('v4', 'v4', 'delivered', now());
    UPDATE public.email_events SET recipient = 'x' WHERE svix_id = 'v4';
    RAISE EXCEPTION 'V4 an UPDATE went through';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'public.email_events is append only%' THEN RAISE; END IF;
  END;
  IF EXISTS (SELECT 1 FROM public.email_events) THEN RAISE EXCEPTION 'V4 left a row behind'; END IF;

  -- V5 the health function still returns an array and none of the new kinds fires today
  IF jsonb_typeof(public.fn_notification_health_items('[]'::jsonb)) <> 'array' THEN RAISE EXCEPTION 'V5 not an array'; END IF;
  SELECT count(*) INTO n FROM jsonb_array_elements(public.fn_notification_health_items('[]'::jsonb)) i
   WHERE i->>'issue' IN ('email_not_delivered', 'email_status_missing', 'email_delivery_incomplete');
  IF n <> 0 THEN RAISE EXCEPTION 'V5 % new item(s) fired with no events', n; END IF;
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
