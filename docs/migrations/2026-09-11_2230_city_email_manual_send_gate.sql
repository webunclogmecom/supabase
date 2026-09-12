-- 2026-09-11 22:30 ET · The automatic city email waits for a manual send, and copies its photo choice
--
-- Fred, 2026-09-11 (city-email rework, Task 2), verbatim:
--   "An automatic email to the city, can only be send when: We've send an email to the client first
--    without the DERM Manifests, if it has the DERM Manifest when we manually send it, then skip the
--    automatic email to the city for that visit. And it's important ... when we send an email to the
--    city we can select to send it with or without the classified photos so the automatic email
--    should follow the same selection ... So the automatic email shouldn't be send without first a
--    manual sent."
-- Re-stated after round 1: "We need to first send an email from the Admin Review App, before the
-- automatic emails can be send (also it needs the blackout before it can be automatically send)."
--
-- 🛑 THIS REVERSES THE 2026-08-27 RULE ("it ALWAYS fires; a missing email #1 never blocks it").
--    Building Apps/Admin Review/docs/11-city-email.md and Supabase/CLAUDE.md are rewritten in the
--    same commit; do not carry the old sentence forward from anywhere else.
--
-- What changes (four objects, bodies copied from pg_get_viewdef / pg_get_functiondef on
-- 2026-09-11 21:40 ET and patched by scratchpad script t2_build.js with reverse-patch assertions):
--
-- 1. derm.v_city_email_candidates
--    - cfg gains live_sends (app_config.city_email_live_sends = 'true').
--    - suppressed (R2, "the manual report already carried the manifest") now counts TEST rows while
--      the city gate is not live, so the whole pipeline can be exercised end to end before go-live.
--      Once live, only real (is_test = false) manual sends count, as before.
--    - NEW manual CTE: per (manifest, client), the newest status='sent' Admin Review send on a live
--      visit of that client on that manifest whose include_manifest IS FALSE (NULL does NOT count:
--      rows older than 2026-08-2x carry no answer, and a NULL must never unlock a regulator email).
--      Same test-mode rule as suppressed.
--    - NEW status arm 'awaiting_manual_send' after no_city_email and before waiting /
--      before_go_live / ready. Precedence, top to bottom: already_sent, suppressed_manual,
--      recently_attempted, too_many_errors, no_property, ambiguous_property, no_city_email,
--      awaiting_manual_send, waiting, before_go_live, ready.
--    - Appended at the END (never reordered): manual_sent_at, manual_include_photos,
--      manual_visit_id, live_sends.
--    - due_at is unchanged: blacked_at + city_email_delay. A manual send that lands after that
--      point makes the pair ready on the next sweep; one that lands before it waits for the
--      blackout plus the delay ("it needs the blackout before it can be automatically send").
-- 2. derm.v_city_email_queue appends manual_include_photos, manual_visit_id.
-- 3. public.fn_request_city_email_sweep passes include_photos (and manual_visit_id, for the log
--    reader) per recipient. send-derm-email reads it per recipient from the same deploy.
-- 4. public.v_visit_report_manifest.report_has_manifest is derm_manifest_url ONLY. A WWTP receipt
--    is not the DERM manifest; counting it (12 live receipt-only visits today) would both hide the
--    "will be sent separately" note and, via include_manifest, cancel an automatic email the city
--    never received. send-visit-photos-email's hasDermDocs is narrowed identically in the same
--    change so the note, the log and this view cannot disagree.
--
-- Measured before applying (2026-09-11): 742 live manifests; candidates already_sent 16,
-- before_go_live 121, no_city_email 561, no_property 12. Dry-run result on the same data:
-- awaiting_manual_send 118, suppressed_manual 3 (2 from before_go_live, 1 from no_city_email: test
-- sends that already carried the manifest), before_go_live 1 (manifest 1764 / client 34, unlocked by
-- V-6236's 2026-08-28 send without the manifest), no_city_email 560. So the gate holds 118 of the
-- 121 backlog pairs at go-live until someone sends from Admin Review, which is the intended behaviour.
--
-- ⚠ COUPLING TO REMEMBER AT GO-LIVE: send-visit-photos-email still has IS_TEST = true hardcoded,
--    so every Admin Review send is a test row. The day city_email_live_sends flips to 'true', test
--    rows stop counting here and NO manual send would ever unlock an automatic email until IS_TEST
--    is flipped too. Flip both in the same change (the cutover checklist in 11-city-email.md).
--
-- Verified in a rolled-back dry run (scratchpad t2_dry.sql) before applying: every pre-existing
-- column except status and suppressed_at identical on all 710 candidate rows (EXCEPT ALL both
-- directions), suppressed_at equal to a test-aware direct read; every
-- status transition in the allowed set; the new columns equal to a direct read of
-- visit_photo_email_sends; four mutants (manual CTE ignoring test mode, NULL include_manifest
-- counted, arm placed above no_city_email, WWTP receipt still counted) each refused.

begin;

create or replace view derm.v_city_email_candidates as
 WITH cfg AS (
         SELECT COALESCE(( SELECT NULLIF(btrim(app_config.value), ''::text)::timestamp with time zone AS "nullif"
                   FROM app_config
                  WHERE app_config.key = 'city_email_start_from'::text), 'infinity'::timestamp with time zone) AS start_from,
            fn_city_email_delay() AS delay,
            fn_city_email_retry_after() AS retry_after,
            COALESCE(( SELECT btrim(app_config.value) = 'true'::text
                   FROM app_config
                  WHERE app_config.key = 'city_email_live_sends'::text), false) AS live_sends
        ), docs AS (
         SELECT r_1.manifest_id,
            r_1.client_id,
            max(r_1.generated_at) AS blacked_at,
            count(*) AS pages
           FROM derm.redacted_manifest_docs r_1
             JOIN derm_manifests dm ON dm.id = r_1.manifest_id AND dm.deleted_at IS NULL
          GROUP BY r_1.manifest_id, r_1.client_id
        ), resolved AS (
         SELECT d.manifest_id,
            d.client_id,
            d.blacked_at,
            d.pages,
            count(DISTINCT v.property_id) AS properties,
            count(DISTINCT p.id) AS city_properties,
            min(p.id) AS property_id
           FROM docs d
             LEFT JOIN manifest_visits mv ON mv.manifest_id = d.manifest_id
             LEFT JOIN visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL AND v.client_id = d.client_id
             LEFT JOIN properties p ON p.id = v.property_id AND p.deleted_at IS NULL AND p.city_emails IS NOT NULL AND cardinality(p.city_emails) > 0
          GROUP BY d.manifest_id, d.client_id, d.blacked_at, d.pages
        ), sent AS (
         SELECT derm_email_sends.manifest_id,
            derm_email_sends.client_id,
            min(derm_email_sends.sent_at) AS first_sent_at
           FROM derm_email_sends
          WHERE derm_email_sends.recipient_type = 'city'::text AND derm_email_sends.status = 'sent'::text AND COALESCE(derm_email_sends.is_test, false) = false
          GROUP BY derm_email_sends.manifest_id, derm_email_sends.client_id
        ), attempted AS (
         SELECT derm_email_sends.manifest_id,
            derm_email_sends.client_id,
            max(derm_email_sends.sent_at) AS last_attempt_at
           FROM derm_email_sends
          WHERE derm_email_sends.recipient_type = 'city'::text
          GROUP BY derm_email_sends.manifest_id, derm_email_sends.client_id
        ), errored AS (
         SELECT derm_email_sends.manifest_id,
            derm_email_sends.client_id,
            count(*) AS error_count
           FROM derm_email_sends
          WHERE derm_email_sends.recipient_type = 'city'::text AND derm_email_sends.status = 'error'::text
          GROUP BY derm_email_sends.manifest_id, derm_email_sends.client_id
        ), suppressed AS (
         SELECT mv.manifest_id,
            v.client_id,
            min(s_1.sent_at) AS suppressed_at
           FROM visit_photo_email_sends s_1
             JOIN visits v ON v.id = s_1.visit_id AND v.deleted_at IS NULL
             JOIN manifest_visits mv ON mv.visit_id = v.id
          WHERE s_1.status = 'sent'::text AND (COALESCE(s_1.is_test, false) = false OR NOT ( SELECT cfg.live_sends
                   FROM cfg)) AND s_1.include_manifest IS TRUE
          GROUP BY mv.manifest_id, v.client_id
        ), manual AS (
         SELECT DISTINCT ON (mv.manifest_id, v.client_id) mv.manifest_id,
            v.client_id,
            s_2.sent_at AS manual_sent_at,
            s_2.include_photos AS manual_include_photos,
            s_2.visit_id AS manual_visit_id
           FROM visit_photo_email_sends s_2
             JOIN visits v ON v.id = s_2.visit_id AND v.deleted_at IS NULL
             JOIN manifest_visits mv ON mv.visit_id = v.id
          WHERE s_2.status = 'sent'::text AND (COALESCE(s_2.is_test, false) = false OR NOT ( SELECT cfg.live_sends
                   FROM cfg)) AND s_2.include_manifest IS FALSE
          ORDER BY mv.manifest_id, v.client_id, s_2.sent_at DESC
        )
 SELECT r.manifest_id,
    r.client_id,
    r.property_id,
    r.blacked_at,
    r.blacked_at + (( SELECT cfg.delay
           FROM cfg)) AS due_at,
    r.pages,
    r.properties,
    r.city_properties,
    s.first_sent_at,
    sup.suppressed_at,
    ( SELECT cfg.start_from
           FROM cfg) AS start_from,
        CASE
            WHEN s.manifest_id IS NOT NULL THEN 'already_sent'::text
            WHEN sup.manifest_id IS NOT NULL THEN 'suppressed_manual'::text
            WHEN a.last_attempt_at IS NOT NULL AND a.last_attempt_at > (now() - (( SELECT cfg.retry_after
               FROM cfg))) THEN 'recently_attempted'::text
            WHEN COALESCE(e.error_count, 0::bigint) >= 3 THEN 'too_many_errors'::text
            WHEN r.properties = 0 THEN 'no_property'::text
            WHEN r.city_properties > 1 THEN 'ambiguous_property'::text
            WHEN r.city_properties = 0 THEN 'no_city_email'::text
            WHEN m.manifest_id IS NULL THEN 'awaiting_manual_send'::text
            WHEN (r.blacked_at + (( SELECT cfg.delay
               FROM cfg))) > now() THEN 'waiting'::text
            WHEN r.blacked_at <= (( SELECT cfg.start_from
               FROM cfg)) THEN 'before_go_live'::text
            ELSE 'ready'::text
        END AS status,
    COALESCE(e.error_count, 0::bigint) AS error_count,
    ( SELECT cfg.delay
           FROM cfg) AS delay,
    a.last_attempt_at,
    m.manual_sent_at,
    m.manual_include_photos,
    m.manual_visit_id,
    ( SELECT cfg.live_sends
           FROM cfg) AS live_sends
   FROM resolved r
     LEFT JOIN sent s ON s.manifest_id = r.manifest_id AND s.client_id = r.client_id
     LEFT JOIN attempted a ON a.manifest_id = r.manifest_id AND a.client_id = r.client_id
     LEFT JOIN errored e ON e.manifest_id = r.manifest_id AND e.client_id = r.client_id
     LEFT JOIN suppressed sup ON sup.manifest_id = r.manifest_id AND sup.client_id = r.client_id
     LEFT JOIN manual m ON m.manifest_id = r.manifest_id AND m.client_id = r.client_id;

comment on view derm.v_city_email_candidates is
  'Every blacked-out DERM manifest with an explicit status for the automatic city email. status=ready means due now. '
  'Since 2026-09-11 the automatic email needs a MANUAL Admin Review send first: awaiting_manual_send = no status=sent '
  'visit_photo_email_sends row with include_manifest=false on a live visit of that client on that manifest (NULL never counts); '
  'suppressed_manual = a manual send already carried the manifest. Test rows count for both while city_email_live_sends<>true. '
  'manual_include_photos is the photo choice the automatic email copies. Never filters a row away: no_city_email, '
  'ambiguous_property, recently_attempted, too_many_errors, awaiting_manual_send and before_go_live are visible states, not silent '
  'absences. The wait and the retry window both come from app_config, so a test can shorten them.';

create or replace view derm.v_city_email_queue as
 SELECT manifest_id,
    client_id,
    property_id,
    blacked_at,
    due_at,
    pages,
    manual_include_photos,
    manual_visit_id
   FROM derm.v_city_email_candidates
  WHERE status = 'ready'::text;

comment on view derm.v_city_email_queue is
  'The rows fn_request_city_email_sweep sends this hour: v_city_email_candidates WHERE status=ready. '
  'manual_include_photos (from the unlocking Admin Review send) is passed to send-derm-email as include_photos per recipient.';

CREATE OR REPLACE FUNCTION public.fn_request_city_email_sweep()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_key   text;
  v_limit int;
  v_test  text;
  v_recipients jsonb;
  v_body  jsonb;
begin
  select coalesce(nullif(btrim(value), '')::int, 5) into v_limit
    from public.app_config where key = 'city_email_batch_limit';
  v_limit := coalesce(v_limit, 5);

  select jsonb_agg(jsonb_build_object(
           'manifest_id', q.manifest_id,
           'client_id',   q.client_id,
           -- 🛑 property_id is what keeps the email to the municipality that actually covers this
           -- visit. Without it send-derm-email unions city_emails across every property the
           -- client owns, which over-sends on 38 of the 107 sendable manifests.
           'property_id', q.property_id,
           -- 2026-09-11: the automatic email copies the photo choice of the manual send that
           -- unlocked it (Fred: "the automatic email should follow the same selection").
           -- NULL only on pre-2026-08-20 rows; send-derm-email then keeps its default (true).
           'include_photos', q.manual_include_photos,
           'manual_visit_id', q.manual_visit_id))
    into v_recipients
    from (select * from derm.v_city_email_queue order by blacked_at limit v_limit) q;

  if v_recipients is null then
    return;  -- nothing due. No HTTP call, no edge invocation, no log noise.
  end if;

  select decrypted_secret into v_key
    from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping city email sweep';
    return;
  end if;

  v_body := jsonb_build_object('target', 'city', 'recipients', v_recipients);

  select nullif(btrim(value), '') into v_test
    from public.app_config where key = 'city_email_test_recipient';
  if v_test is not null then
    v_body := v_body || jsonb_build_object('test_recipient', v_test);
  end if;

  perform net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/send-derm-email',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body    := v_body,
    timeout_milliseconds := 60000);
end $function$;

create or replace view public.v_visit_report_manifest as
 SELECT v.id AS visit_id,
    v.public_id,
    wo.derm_manifest_url IS NOT NULL AS report_has_manifest
   FROM visits v
     LEFT JOIN customer.work_orders wo ON wo.id = v.public_id
  WHERE v.deleted_at IS NULL;

comment on view public.v_visit_report_manifest is
  'Does the Field Portal Service Report for this visit already carry the DERM manifest (customer.work_orders.derm_manifest_url, '
  'which the blackout pipeline publishes)? Since 2026-09-11 a WWTP receipt alone does NOT count. TRUE means a manual '
  '"Send email to City" carries the manifest and CANCELS the automatic city email for that manifest (suppressed_manual); '
  'FALSE means the manual send UNLOCKS it (awaiting_manual_send -> waiting/ready). Mirrors send-visit-photos-email''s '
  'hasDermDocs exactly so the dialog note, the send log and the sweep cannot disagree.';

commit;
