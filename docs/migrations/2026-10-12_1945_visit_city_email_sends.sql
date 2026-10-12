-- ============================================================================
-- 2026-10-12_1945 public.v_visit_city_email_sends: the FULL city email history of a visit, from both apps and the
--                 automatic sweep, one row per real send. Read-only view, nothing else changes.
--                 (HHMM is stamped at apply, in the file name and in the COMMENT below, so the file sorts after
--                 every migration already in docs/migrations: sorted order = apply order.)
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-12 evening ET, on the next round after the duplicate city emails (Hallandale Beach got 6247 three times and
--   6138 twice): "we can send multiple emails that doesn't matter, but it's good to know who has sent an email even
--   if it's from across other apps, also show if the email was sent by the system because of the automatic email
--   sending". So NO duplicate guard and no blocking: each app shows every city send of the visit, when, who, from
--   which app (or the system), and whether the manifest went with it.
--
-- WHAT CHANGES
--   NEW VIEW public.v_visit_city_email_sends, one row per REAL city send per live visit:
--     visit_id
--     sent_at          timestamptz (show it in ET)
--     via              'admin_review'  Admin Review "Send email to City" (public.visit_photo_email_sends)
--                      'derm_tracker'  DERM Tracker "Send to city" (public.derm_email_sends, recipient_type city), with a
--                                      sender, or with no sender and sent before the go-live instant
--                      'automatic'     derm_email_sends city with NO sender, sent at or after the go-live instant
--                                      2026-09-15 13:07:34.336825 UTC. That is the hourly city-email-sweep, but the rule
--                                      really means "any service-key caller with no sender": a real city send made by a
--                                      script or a session holding the service key would also read 'automatic'. Today
--                                      there is exactly one such row (189, the sweep), and v_visit_city_email_state has the
--                                      same rule (its sent_via), so the two cannot disagree about it
--     sent_by_email    as logged. NULL for the automatic email, and for the 17 June/July DERM Tracker rows of the log that
--                      were sent before sender logging existed (16 of them reach this view: row 50 credits no live visit).
--                      derm_email_sends began logging the sender on 2026-07-21 13:40 ET (row 87, the first row with one);
--                      the first REAL city send with a sender is 2026-09-22 14:37 ET. Those 16 rows stay via
--                      'derm_tracker' with sent_by_name NULL, and the app prints "sender not recorded"
--     sent_by_name     employees.full_name by lower(btrim(email)), else the email; NULL when sent_by_email is NULL.
--                      The same rule as v_visit_photo_email_status.last_sent_by_name (ORDER BY emp.id LIMIT 1), so
--                      the two apps never name the same sender differently (contact@unclogme.com reads Diego)
--     app_label        plain words for the UI: 'Admin Review' | 'DERM Tracker' | 'Automatic (system)'
--     recipients       the To line ONLY, as logged (recipient_email; both logs store it comma-joined, one row per send).
--                      Never cc_emails or bcc_emails, which both logs also hold
--     with_manifest    the city got the manifest with this email. Admin Review: include_manifest true, or NULL and
--                      sent at or after the pair's FOG document (the reconstruction v_visit_city_email_state uses,
--                      copied verbatim). DERM Tracker / automatic: true unless the reason starts
--                      'attachment:manifest_images' (a letter that went with NOTHING attached). Never NULL
--     with_photos      the report carried the photos. Admin Review: include_photos (NOT NULL there). DERM Tracker /
--                      automatic: include_photos, NULL = not recorded (rows before 2026-09-03); false for a letter
--                      with nothing attached
--     send_id, source_table   the log row (visit_photo_email_sends | derm_email_sends), for tracing. send_id alone
--                      repeats across the two logs: an app's list key is source_table + send_id
--   It reads public.v_visit_city_email_state for the visit population (one row per live visit), the client and the
--   LIVE manifest list, so the attribution is the state view's by construction, not a second copy of it. The only
--   copied rules are the two the state view keeps inside expressions: the Admin Review NULL reconstruction and the
--   automatic literal. VERIFY proves agreement over every live visit (check 4) and under every fixture (check 6):
--     state.city_email_sent_at  = min(sent_at) of this view's with_manifest rows
--     state.sent_via            = via of the first of them (ties: Admin Review first, as the state view)
--     state.ar_sent_at / ar_manifest_sent_at / dt_sent_at = the matching minimums here
--   and proves the comparator can fire (check 4b, arm by arm: moving one history minimum by 1 microsecond, or changing
--   the first via, must flag exactly the visits whose matching state column is set), and that every row reads back
--   its own log row (check 2b: sent_at, sent_by_email, recipients, with_photos, joined by source_table + send_id).
--   Owner-rights view (owner postgres, no security_invoker), SELECT to authenticated and service_role only (both
--   staff apps sign in as authenticated; the DERM Tracker has a public-schema client too), anon and PUBLIC nothing.
--
-- WHAT IT SUPERSEDES FOR DISPLAY (no change to it here)
--   Admin Review ALREADY reads public.v_visit_city_email_status (live chunk App-BMWz0BDv.js: its dialog's view of
--   DERM Tracker sends; a bundle scan for "v_visit_city_email" matches it only as a substring, which is how the first
--   draft missed it). Its rules differ from both v_visit_city_email_state and this view: it keeps soft-deleted
--   manifests (no derm_manifests.deleted_at filter), uses visits.deleted_at instead of v_visits_live, counts a letter
--   that went with nothing attached, and returns the LAST send, not the first. It agrees with this history on every
--   visit today (rolled-back check, 2026-10-12), but nothing keeps it so. The Admin Review round should replace that
--   read with this view, so the card cannot disagree with the list. Until then both exist; neither changes here.
--
-- DECISIONS (each from evidence or from Fred)
--   1. TEST SENDS ARE HIDDEN, not listed with a flag. Fred asked who emailed THE CITY; a test send went to a staff
--      inbox (fred@ayache.com), never to a municipality, and every one of them is from before go-live (Fred, on
--      pre-go-live history: "we don't care about the old for this"). Both apps already say so today: the DERM Tracker
--      visit page reads "Test email sent on ... Not sent to the city yet." (derm.visits.city_last_test_at, a separate
--      column), and Admin Review's send gate and "already sent" sentence read last_real_sent_at, with the amber "Test"
--      pill only on its own last-send line. Every "sent" reader excludes them (state view, both apps, the sweep since
--      go-live). Measured 2026-10-12: 0 test sends on either log since go-live (DERM Tracker test copies are still
--      possible by typing an internal address). Those labels keep reading their own views, unchanged. To list tests
--      later: drop the two NOT s.is_test lines and append an is_test column; check 4 must then filter it.
--   2. A letter with NOTHING attached is listed (with_manifest false, with_photos false): an email did reach the
--      city, it just did not carry the manifest. The state view ignores it for "sent", and so does check 4.
--   3. Per visit, not per pair, for Admin Review; per (manifest, client) for the DERM Tracker and the sweep, because
--      derm_email_sends has no visit_id (KNOWN LIMIT 1). Same grains as the state view.
--   4. v_visit_city_email_state is NOT changed (no last_sent_* columns): its only reader (fn_admin_review_pending)
--      needs none of them, an app that shows the history gets "last send" and "how many" from these rows, and a
--      CREATE OR REPLACE of an app-read view could not be tested before apply under this cycle's rules.
--   5. NO SENDER: before go-live = an old DERM Tracker send (via 'derm_tracker', sent_by_name NULL, "sender not
--      recorded"); at or after go-live = 'automatic'. Fixtures f5, f6 and f14 pin both sides (f14: a no-sender send
--      on Sep 16, the first day, is automatic).
--
-- KNOWN LIMITS
--   1. (manifest, client) credit. A DERM Tracker or sweep send is listed on every live visit of that client on that
--      live manifest. Measured 2026-10-12: 29 real city sends; 28 credit exactly one live visit, 1 (row 50, June)
--      credits none, 0 credit two or more. 37 live pairs have 2+ live visits, none dated since go-live. A nullable
--      derm_email_sends.visit_id written by send-derm-email is drafted in notes.md, not shipped here.
--   2. A LANGUAGE sql reader of this view leaves no pg_depend edge (same as the state view, its KNOWN LIMIT 6).
--      This view itself DOES depend on v_visit_city_email_state, so DROP VIEW v_visit_city_email_state without
--      CASCADE is now refused (good) and with CASCADE silently drops this one (never do that). That includes the
--      ROLLBACK documented in 2026-10-12_1305 (DROP VIEW public.v_visit_city_email_state): from apply on, it is
--      refused until public.v_visit_city_email_sends is dropped first (and that only after the apps stop reading it).
--      Change either view with CREATE OR REPLACE only, new columns at the end. At apply, the Supabase CLAUDE.md
--      section '"HAS THIS VISIT'S CITY EMAIL GONE?" HAS ONE ANSWER' needs a line for this view (the history, read it
--      for "who sent it and when"; the state view stays the one answer for "has it gone").
--   3. Row order is the reader's: ORDER BY sent_at DESC, send_id DESC for "newest first".
--
-- WHY THE CONTROLS ARE TIME-BOUNDED
--   Fred now says re-sending is fine, and Admin Review still shows "not sent" for 6218, 6270 and 6284 (they went from
--   the DERM Tracker), so one more send on a control visit before apply must not make this file refuse. Every
--   control and fixture therefore judges history sent before 2026-10-13 00:00 UTC (20:00 ET Oct 12), which cannot
--   change: check 3 reads only rows sent before it, and the fixture harness first marks any send logged at or after it
--   as a test inside its own always-rolled-back subtransaction, so the state view and this one both judge the
--   fixtures on the bounded history. Completeness (2), read-back (2b) and agreement (4, 4b) still read everything.
--   Proven by a scenario run: the file with a later real Admin Review send on 6218 and a later DERM Tracker send on
--   6275's pair inserted first (rolled back) passes; the previous draft under the same scenario refuses.
--
-- MEASURED BEFORE WRITING (2026-10-12 19:10 to 19:32 ET by the DB clock: a rolled-back run of this whole file, 43
--   deliberately broken copies of it and 3 "a new send lands before apply" scenarios, all in tests/results.txt)
--   39 rows on 32 visits (the 32 the state view reads sent): Admin Review 11 (7 with the manifest, 4 the report
--   only), DERM Tracker 27 (16 of them June/July with no sender recorded), automatic 1 (row 189, 112-YA visit 8113).
--   23 since go-live. Six visits have 2+ rows: 6247 (DERM Tracker 184 Sep 25 13:29:24, DERM Tracker 185 13:29:58,
--   Admin Review 186 Oct 8 11:18:28) and 6138 (DERM Tracker 186 Sep 25, Admin Review 185 Oct 8) got the manifest more
--   than once; 5974, 6087, 6582 got the Admin Review report first and the manifest from the DERM Tracker after it (the
--   intended order); 8113 is the test client (report, then the automatic email). Names: Diego 20
--   (contact@unclogme.com), Serena Natali 1, Fred 1, no sender 17 (16 DERM Tracker rows, 1 automatic). Test rows
--   that would show if tests were listed: 47 Admin Review + 69 DERM Tracker, all before go-live. Sends logged at or
--   after the controls' bound: 0 (newest send Oct 9 11:24 ET). Full read with every row built 25 ms, one visit 3 ms;
--   the whole file holds its transaction 2.2 to 2.4 s.
--   VERIFY refused all 39 broken copies that change behaviour (the draft's 19, the review's 15, and 5 that drop one
--   comparison of the agreement check or all of them). The review's 4 copies that are equivalent on today's data
--   pass, as expected (notes.md says why each is not a test gap). With a later send on 6218 and on 6275's pair
--   inserted first, this file passes and the previous draft refuses ("control visits wrong: {6218,6275}").
--
-- NOT CHANGED: v_visit_city_email_state, v_visit_city_email_status, fn_admin_review_pending, log_notification_health
--   and fn_notification_health_items (they read the raw logs, never this view; the separate
--   notification_health_drop_duplicate_item migration removes item G from the latter), derm.v_city_email_candidates,
--   v_visit_photo_email_status, derm.visits, both send logs, both edge functions, both apps. Nothing reads the new
--   view until the app changes ship.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table created or altered; a view holds no rows. The VERIFY fixtures write
--   ONLY to visit_photo_email_sends and derm_email_sends (audit trigger only), inside subtransactions that always
--   roll back (their audit rows with them), and check 7 re-reads the touched rows afterwards.
-- LOCKS: CREATE VIEW on a new name blocks no reader. The fixtures hold row locks on derm_email_sends 191,
--   visit_photo_email_sends 187, one test row, and any send logged at or after the bound (none at writing) for
--   milliseconds each. Refuses to run 10:55 to 11:05 ET (the 11 AM post reads the state view this one reads).
--   REPEATABLE READ: one snapshot for every check; a concurrent change to a fixture row aborts the file, which is safe.
-- ROLLBACK: DROP VIEW public.v_visit_city_email_sends; only after the apps stop reading it (grep both live bundles
--   for v_visit_city_email_sends first: a dropped view is a 404 on the visit page, not an empty list).
-- ============================================================================

BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL lock_timeout = '3s';

DO $pre$
BEGIN
  -- the state view this file reads and whose two inline rules it copies; re-read it if this fails
  IF md5(pg_get_viewdef('public.v_visit_city_email_state'::regclass)) <> '512f2c5dd46717edb1e063d7ca5e6923' THEN
    RAISE EXCEPTION 'v_visit_city_email_state changed since this file was written: re-read it and re-check the copied rules';
  END IF;
  IF to_regclass('public.v_visit_city_email_sends') IS NOT NULL THEN
    RAISE EXCEPTION 'public.v_visit_city_email_sends already exists';
  END IF;
  IF (now() AT TIME ZONE 'America/New_York')::time BETWEEN time '10:55' AND time '11:05' THEN
    RAISE EXCEPTION 'the 11 AM Admin Review post runs now: apply after 11:05 ET';
  END IF;
END $pre$;

CREATE VIEW public.v_visit_city_email_sends AS
SELECT st.visit_id,
       h.sent_at,
       h.via,
       h.sent_by_email,
       coalesce(e.full_name, h.sent_by_email) AS sent_by_name,
       CASE h.via WHEN 'admin_review' THEN 'Admin Review' WHEN 'derm_tracker' THEN 'DERM Tracker'
                  ELSE 'Automatic (system)' END AS app_label,
       h.recipients,
       h.with_manifest,
       h.with_photos,
       h.send_id,
       h.source_table
FROM public.v_visit_city_email_state st
CROSS JOIN LATERAL (
  -- Admin Review "Send email to City", real sends of THIS visit. with_manifest: the state view's ar lateral FILTER,
  -- verbatim (include_manifest true, or NULL and sent at or after the pair's FOG document)
  SELECT s.sent_at,
         'admin_review'::text AS via,
         s.sent_by_email,
         s.recipient_email AS recipients,
         (s.include_manifest IS TRUE
           OR (s.include_manifest IS NULL AND EXISTS (
                SELECT 1 FROM unnest(st.manifest_ids) m(id)
                WHERE s.sent_at >= coalesce(
                  (SELECT max(r.generated_at) FROM derm.redacted_manifest_docs r
                    WHERE r.manifest_id = m.id AND r.client_id = st.client_id),
                  (SELECT max(coalesce(sh.uploaded_at, sh.generated_at, sh.created_at)) FROM derm.manifest_visit_sheets sh
                    WHERE sh.manifest_id = m.id AND sh.client_id = st.client_id AND sh.deleted_at IS NULL
                      AND coalesce(sh.photo_bucket, '') <> '' AND coalesce(sh.photo_path, '') <> ''))))) AS with_manifest,
         s.include_photos AS with_photos,
         s.id AS send_id,
         'visit_photo_email_sends'::text AS source_table
  FROM public.visit_photo_email_sends s
  WHERE s.visit_id = st.visit_id AND s.status = 'sent' AND NOT s.is_test
  UNION ALL
  -- DERM Tracker "Send to city" and the automatic sweep, real city sends of a LIVE manifest of this visit for this
  -- client (the state view's dt lateral, without its LIMIT 1 and without its nothing-attached filter, which becomes
  -- with_manifest). No actor after go-live = the sweep (service key); before it = a DERM Tracker send from before
  -- actor logging. Fixed literal on purpose (state view DEVIATION 3)
  SELECT s.sent_at,
         CASE WHEN s.sent_by_email IS NULL AND s.sent_at >= timestamptz '2026-09-15 13:07:34.336825+00'
              THEN 'automatic' ELSE 'derm_tracker' END,
         s.sent_by_email,
         s.recipient_email,
         coalesce(s.reason, '') NOT LIKE 'attachment:manifest_images%',
         CASE WHEN coalesce(s.reason, '') LIKE 'attachment:manifest_images%' THEN false ELSE s.include_photos END,
         s.id,
         'derm_email_sends'::text
  FROM public.derm_email_sends s
  WHERE s.manifest_id = ANY (st.manifest_ids) AND s.client_id = st.client_id
    AND s.recipient_type = 'city' AND s.status = 'sent' AND NOT s.is_test
) h
-- v_visit_photo_email_status.last_sent_by_name's rule
LEFT JOIN LATERAL (
  SELECT emp.full_name
  FROM public.employees emp
  WHERE h.sent_by_email IS NOT NULL AND lower(btrim(emp.email)) = lower(btrim(h.sent_by_email))
  ORDER BY emp.id
  LIMIT 1
) e ON true;

COMMENT ON VIEW public.v_visit_city_email_sends IS
  'Every REAL city email of a live visit, one row per send, from Admin Review (visit_photo_email_sends), the DERM '
  'Tracker and the automatic sweep (derm_email_sends, city). via admin_review | derm_tracker | automatic, app_label in '
  'plain words, sent_by_name (employees, else the email; NULL for the automatic email and for old DERM Tracker sends '
  'with no sender recorded), recipients (the To line only), with_manifest, with_photos. '
  'Test sends are not listed (they never reach a city). A DERM Tracker or sweep send is credited to every live visit '
  'of that client on that manifest (no visit_id in derm_email_sends). Agrees with v_visit_city_email_state by '
  'construction (it reads it): city_email_sent_at = min(sent_at) of the with_manifest rows. No order: sort by '
  'sent_at. Supersedes v_visit_city_email_status for display. CREATE OR REPLACE only, new columns at the end. '
  '2026-10-12_1945.';

REVOKE ALL ON public.v_visit_city_email_sends FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.v_visit_city_email_sends TO authenticated, service_role;

-- ---------------------------------------------------------------------------- fixtures for VERIFY
-- The state-vs-history disagreements over every live visit (empty = they agree). Used live and under every fixture.
-- arm 0 is the real comparison. Arms 1 to 5 are must-fire controls (check 4b), one per compared column: arm 1 to 4
-- move that one history minimum by 1 microsecond, arm 5 changes the first via. Each must flag exactly the visits whose
-- matching state column is set, so a comparison that can never fire, or one dropped from the WHERE, is caught.
CREATE FUNCTION pg_temp.cses_disagree(arm int) RETURNS bigint[] LANGUAGE sql AS $f$
  SELECT array_agg(st.visit_id ORDER BY st.visit_id)
  FROM public.v_visit_city_email_state st
  LEFT JOIN LATERAL (
    SELECT min(h.sent_at + CASE WHEN arm = 1 THEN interval '1 microsecond' ELSE interval '0' END)
             FILTER (WHERE h.with_manifest) AS first_with_manifest,
           min(h.sent_at + CASE WHEN arm = 2 THEN interval '1 microsecond' ELSE interval '0' END)
             FILTER (WHERE h.via = 'admin_review') AS ar_first,
           min(h.sent_at + CASE WHEN arm = 3 THEN interval '1 microsecond' ELSE interval '0' END)
             FILTER (WHERE h.via = 'admin_review' AND h.with_manifest) AS ar_manifest_first,
           min(h.sent_at + CASE WHEN arm = 4 THEN interval '1 microsecond' ELSE interval '0' END)
             FILTER (WHERE h.via <> 'admin_review' AND h.with_manifest) AS dt_first,
           (array_agg(h.via ORDER BY h.sent_at, (h.via = 'admin_review') DESC, h.send_id) FILTER (WHERE h.with_manifest))[1]
             || CASE WHEN arm = 5 THEN '?' ELSE '' END AS first_via
    FROM public.v_visit_city_email_sends h WHERE h.visit_id = st.visit_id
  ) x ON true
  WHERE st.city_email_sent_at IS DISTINCT FROM x.first_with_manifest
     OR st.sent_via IS DISTINCT FROM x.first_via
     OR st.ar_sent_at IS DISTINCT FROM x.ar_first
     OR st.ar_manifest_sent_at IS DISTINCT FROM x.ar_manifest_first
     OR st.dt_sent_at IS DISTINCT FROM x.dt_first
$f$;

-- Applies ONE mutation inside a subtransaction that ALWAYS rolls back and returns what the view (and the
-- disagreement check) said while it was applied. Writes only to the two send logs (audit trigger only).
-- Every fixture judges the history sent before 2026-10-13 00:00 UTC: a send logged at or after it is first marked a
-- test (hidden by both views), inside the same rolled-back subtransaction, so a new send on 6218 or 6275 before apply
-- cannot change what a fixture reads.
CREATE FUNCTION pg_temp.cses_fixture(k text) RETURNS jsonb LANGUAGE plpgsql AS $fx$
DECLARE payload text;
BEGIN
  BEGIN
    UPDATE public.visit_photo_email_sends SET is_test = true WHERE sent_at >= timestamptz '2026-10-13 00:00+00' AND NOT is_test;
    UPDATE public.derm_email_sends SET is_test = true WHERE sent_at >= timestamptz '2026-10-13 00:00+00' AND NOT is_test;
    CASE k
      WHEN 'live' THEN NULL;
      -- 6275's Admin Review send (row 187) without the manifest and without the photos: listed, with_manifest false,
      -- with_photos false (every real Admin Review row carries the photos today, so only this fixture sees that column)
      WHEN 'f1_ar_without_manifest' THEN
        UPDATE public.visit_photo_email_sends SET include_manifest = false, include_photos = false WHERE id = 187;
      -- row 187 from before include_manifest existed (NULL), sent after the FOG document: carried it
      WHEN 'f2_ar_null_after_doc' THEN UPDATE public.visit_photo_email_sends SET include_manifest = NULL WHERE id = 187;
      -- the same, sent before the FOG document: did not
      WHEN 'f3_ar_null_before_doc' THEN
        UPDATE public.visit_photo_email_sends SET include_manifest = NULL, sent_at = timestamptz '2026-09-01 12:00+00' WHERE id = 187;
      -- 6218's DERM Tracker send (row 191) went with nothing attached: listed, no manifest, no photos
      WHEN 'f4_nothing_attached' THEN
        UPDATE public.derm_email_sends SET reason = 'attachment:manifest_images:ambiguous_visit', include_photos = true WHERE id = 191;
      -- row 191 with no actor after go-live: the automatic sweep, no name
      WHEN 'f5_no_actor_after_go_live' THEN UPDATE public.derm_email_sends SET sent_by_email = NULL WHERE id = 191;
      -- row 191 with no actor before go-live: a DERM Tracker send from before actor logging
      WHEN 'f6_no_actor_before_go_live' THEN
        UPDATE public.derm_email_sends SET sent_by_email = NULL, sent_at = timestamptz '2026-07-01 12:00+00' WHERE id = 191;
      -- row 191 was a test send: hidden
      WHEN 'f7_test_send' THEN UPDATE public.derm_email_sends SET is_test = true WHERE id = 191;
      -- row 191 failed: hidden
      WHEN 'f8_failed_send' THEN UPDATE public.derm_email_sends SET status = 'error' WHERE id = 191;
      -- row 191 moved onto soft-deleted manifest 1969 (client 329, linked to live visit 6279): listed nowhere
      WHEN 'f9_deleted_manifest' THEN UPDATE public.derm_email_sends SET manifest_id = 1969, client_id = 329 WHERE id = 191;
      -- the name lookup ignores case and spaces (Serena), and an unknown sender reads as the email (row 187)
      WHEN 'f10_names' THEN
        UPDATE public.derm_email_sends SET sent_by_email = '  Serena@Unclogme.COM ' WHERE id = 191;
        UPDATE public.visit_photo_email_sends SET sent_by_email = 'nobody.here@unclogme.com' WHERE id = 187;
      -- a borrowed test row as a second, LATER Admin Review send with the manifest on 6275: two rows, first still counts
      WHEN 'f11_second_later_ar_send' THEN
        UPDATE public.visit_photo_email_sends SET visit_id = 6275, is_test = false, status = 'sent', include_manifest = true,
               sent_at = (SELECT s2.sent_at + interval '1 day' FROM public.visit_photo_email_sends s2 WHERE s2.id = 187)
         WHERE id = (SELECT min(id) FROM public.visit_photo_email_sends WHERE is_test);
      -- row 191 relabelled a CLIENT send: not a city email
      WHEN 'f12_client_send' THEN UPDATE public.derm_email_sends SET recipient_type = 'client' WHERE id = 191;
      -- 6275's only send (Admin Review row 187) failed: hidden (every failed Admin Review row today is a test, so
      -- only this fixture sees the status line)
      WHEN 'f13_ar_failed_send' THEN UPDATE public.visit_photo_email_sends SET status = 'error' WHERE id = 187;
      -- row 191 with no sender on Sep 16, the first day after go-live: automatic (decision 5, the boundary's near side)
      WHEN 'f14_no_actor_first_week' THEN
        UPDATE public.derm_email_sends SET sent_by_email = NULL, sent_at = timestamptz '2026-09-16 12:00+00' WHERE id = 191;
      ELSE RAISE EXCEPTION 'no such fixture %', k;
    END CASE;
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'cses_fixture:' || jsonb_build_object(
      'disagree', to_jsonb(pg_temp.cses_disagree(0)),
      'rows', (SELECT jsonb_object_agg(visit_id, r) FROM (
                 SELECT h.visit_id, jsonb_agg(jsonb_build_object('via', h.via, 'src', h.source_table, 'id', h.send_id,
                          'at', h.sent_at, 'name', h.sent_by_name, 'label', h.app_label, 'man', h.with_manifest,
                          'ph', h.with_photos) ORDER BY h.sent_at, h.send_id) r
                 FROM public.v_visit_city_email_sends h WHERE h.visit_id IN (6218, 6275, 6279) GROUP BY h.visit_id) z),
      'st', (SELECT jsonb_object_agg(visit_id, jsonb_build_object('state', state, 'sent_via', sent_via,
                                                                  'city_email_sent_at', city_email_sent_at))
               FROM public.v_visit_city_email_state WHERE visit_id IN (6218, 6275, 6279)))::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'cses_fixture:%' THEN RAISE; END IF;
    payload := substr(SQLERRM, length('cses_fixture:') + 1);
  END;
  RETURN payload::jsonb;
END $fx$;

-- every row a fixture may write: 191, 187, the borrowed test row, and any send logged at or after the bound
CREATE TEMP TABLE _cses_rows ON COMMIT DROP AS
SELECT 'des:' || s.id AS k, md5(to_jsonb(s)::text) AS h FROM public.derm_email_sends s
 WHERE s.id = 191 OR s.sent_at >= timestamptz '2026-10-13 00:00+00'
UNION ALL
SELECT 'vpes:' || s.id, md5(to_jsonb(s)::text) FROM public.visit_photo_email_sends s
 WHERE s.id = 187 OR s.id = (SELECT min(id) FROM public.visit_photo_email_sends WHERE is_test)
    OR s.sent_at >= timestamptz '2026-10-13 00:00+00';

-- ---------------------------------------------------------------------------- VERIFY
DO $verify$
DECLARE
  acl text[];
  bad bigint[];
  want bigint[];
  a int;
  n bigint;
  n2 bigint;
  e_anon text := 'no error';
  fk text;
  w jsonb;
  r jsonb;
BEGIN
  -- 1. owner rights, owned by postgres, exactly SELECT for authenticated and service_role (plus the backup reader
  --    from the schema default), nothing for anon or PUBLIC
  IF (SELECT relowner FROM pg_class WHERE oid = 'public.v_visit_city_email_sends'::regclass) <> 'postgres'::regrole
     OR (SELECT reloptions FROM pg_class WHERE oid = 'public.v_visit_city_email_sends'::regclass) IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY: the view must be owned by postgres with no reloptions (owner rights)'; END IF;
  SELECT array_agg(coalesce(nullif(a.grantee::regrole::text, '-'), 'PUBLIC') || ':' || a.privilege_type
                   ORDER BY coalesce(nullif(a.grantee::regrole::text, '-'), 'PUBLIC'), a.privilege_type)
    INTO acl
    FROM pg_class c, aclexplode(c.relacl) a
   WHERE c.oid = 'public.v_visit_city_email_sends'::regclass AND a.grantee <> c.relowner;
  IF acl IS DISTINCT FROM ARRAY['authenticated:SELECT', 'db_backup_reader:SELECT', 'service_role:SELECT'] THEN
    RAISE EXCEPTION 'VERIFY: view grants are %', acl; END IF;
  IF has_table_privilege('anon', 'public.v_visit_city_email_sends', 'SELECT') THEN RAISE EXCEPTION 'VERIFY: anon reads the view'; END IF;
  IF has_table_privilege('authenticated', 'public.v_visit_city_email_sends', 'INSERT,UPDATE,DELETE,TRUNCATE') THEN RAISE EXCEPTION 'VERIFY: authenticated can write'; END IF;
  -- a real read as authenticated (nothing inside needs a grant it lacks) and a refused read as anon
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM public.v_visit_city_email_sends;
  RESET ROLE;
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM count(*) FROM public.v_visit_city_email_sends;
  EXCEPTION WHEN insufficient_privilege THEN e_anon := SQLSTATE;
  END;
  RESET ROLE;
  IF n = 0 OR n <> (SELECT count(*) FROM public.v_visit_city_email_sends) OR e_anon <> '42501' THEN
    RAISE EXCEPTION 'VERIFY: as authenticated % rows, as anon %', n, e_anon; END IF;

  -- 2. completeness, counted from the SEND side: every real Admin Review send of a live visit is here once, and
  --    every real city send of a live (manifest, client) once per live visit of that client on that manifest
  SELECT count(*) INTO n FROM public.visit_photo_email_sends s
   WHERE s.status = 'sent' AND NOT s.is_test AND EXISTS (SELECT 1 FROM public.v_visits_live v WHERE v.id = s.visit_id);
  SELECT count(*) INTO n2 FROM public.derm_email_sends s
    JOIN public.derm_manifests dm ON dm.id = s.manifest_id AND dm.deleted_at IS NULL
    JOIN public.manifest_visits mv ON mv.manifest_id = s.manifest_id
    JOIN public.v_visits_live v ON v.id = mv.visit_id AND v.client_id = s.client_id
   WHERE s.recipient_type = 'city' AND s.status = 'sent' AND NOT s.is_test;
  IF n = 0 OR n2 = 0
     OR n <> (SELECT count(*) FROM public.v_visit_city_email_sends WHERE source_table = 'visit_photo_email_sends')
     OR n2 <> (SELECT count(*) FROM public.v_visit_city_email_sends WHERE source_table = 'derm_email_sends')
     OR (SELECT count(*) - count(DISTINCT (visit_id, source_table, send_id)) FROM public.v_visit_city_email_sends) <> 0 THEN
    RAISE EXCEPTION 'VERIFY: completeness: AR % DT % expected, view %', n, n2,
      (SELECT jsonb_object_agg(source_table, c) FROM (SELECT source_table, count(*) c FROM public.v_visit_city_email_sends GROUP BY 1) z); END IF;
  -- no NULL where the UI needs a value
  IF EXISTS (SELECT 1 FROM public.v_visit_city_email_sends
              WHERE sent_at IS NULL OR via IS NULL OR app_label IS NULL OR with_manifest IS NULL OR recipients IS NULL
                 OR (via <> 'automatic' AND sent_by_email IS NOT NULL AND sent_by_name IS NULL)
                 OR (via = 'automatic' AND (sent_by_email IS NOT NULL OR sent_by_name IS NOT NULL))
                 OR (app_label, via) NOT IN (('Admin Review', 'admin_review'), ('DERM Tracker', 'derm_tracker'),
                                             ('Automatic (system)', 'automatic'))) THEN
    RAISE EXCEPTION 'VERIFY: a row is missing a value the UI shows'; END IF;
  -- 2b. every row reads back its own log row (source_table + send_id): sent_at, sent_by_email, recipients (the To line,
  --     recipient_email, never cc or bcc) and with_photos. Catches a wrong column copied into any of them.
  IF EXISTS (SELECT 1 FROM public.v_visit_city_email_sends h
               LEFT JOIN public.visit_photo_email_sends a ON h.source_table = 'visit_photo_email_sends' AND a.id = h.send_id
               LEFT JOIN public.derm_email_sends d ON h.source_table = 'derm_email_sends' AND d.id = h.send_id
              WHERE num_nonnulls(a.id, d.id) <> 1
                 OR h.sent_at IS DISTINCT FROM coalesce(a.sent_at, d.sent_at)
                 OR h.sent_by_email IS DISTINCT FROM CASE WHEN a.id IS NOT NULL THEN a.sent_by_email ELSE d.sent_by_email END
                 OR h.recipients IS DISTINCT FROM CASE WHEN a.id IS NOT NULL THEN a.recipient_email ELSE d.recipient_email END
                 OR h.with_photos IS DISTINCT FROM CASE WHEN a.id IS NOT NULL THEN a.include_photos
                                                        WHEN coalesce(d.reason, '') LIKE 'attachment:manifest_images%' THEN false
                                                        ELSE d.include_photos END) THEN
    RAISE EXCEPTION 'VERIFY: a row does not read back its own log row'; END IF;

  -- 3. positive controls on history that cannot change: only rows sent before 2026-10-13 00:00 UTC are read, so a
  --    new send on a control visit before apply does not make the file refuse
  --    6247 (Hallandale Beach got it three times): DERM Tracker 184 and 185 on Sep 25, Admin Review 186 on Oct 8
  SELECT jsonb_agg(jsonb_build_object('id', send_id, 'via', via, 'at', (sent_at AT TIME ZONE 'America/New_York')::text,
                                      'name', sent_by_name, 'man', with_manifest) ORDER BY sent_at, send_id) INTO r
    FROM public.v_visit_city_email_sends WHERE visit_id = 6247 AND sent_at < timestamptz '2026-10-13 00:00+00';
  IF r IS DISTINCT FROM '[{"id": 184, "via": "derm_tracker", "at": "2026-09-25 13:29:24.775344", "name": "Diego", "man": true},
                          {"id": 185, "via": "derm_tracker", "at": "2026-09-25 13:29:58.407446", "name": "Diego", "man": true},
                          {"id": 186, "via": "admin_review", "at": "2026-10-08 11:18:28.886789", "name": "Diego", "man": true}]'::jsonb THEN
    RAISE EXCEPTION 'VERIFY: 6247 reads %', r; END IF;
  --    6138 (twice): DERM Tracker 186 on Sep 25, Admin Review 185 on Oct 8
  SELECT jsonb_agg(jsonb_build_object('id', send_id, 'via', via) ORDER BY sent_at, send_id) INTO r
    FROM public.v_visit_city_email_sends WHERE visit_id = 6138 AND sent_at < timestamptz '2026-10-13 00:00+00';
  IF r IS DISTINCT FROM '[{"id": 186, "via": "derm_tracker"}, {"id": 185, "via": "admin_review"}]'::jsonb THEN
    RAISE EXCEPTION 'VERIFY: 6138 reads %', r; END IF;
  --    the three DERM Tracker sends Diego was told were missing; the five Admin Review sends with the manifest
  SELECT array_agg(v ORDER BY v) INTO bad FROM unnest(ARRAY[6218, 6270, 6284, 6275, 8133, 6237, 6253, 8232]::bigint[]) v
   WHERE (SELECT count(*) FROM public.v_visit_city_email_sends h
           WHERE h.visit_id = v AND h.sent_at < timestamptz '2026-10-13 00:00+00') <> 1
      OR NOT EXISTS (SELECT 1 FROM public.v_visit_city_email_sends h
                      WHERE h.visit_id = v AND h.sent_at < timestamptz '2026-10-13 00:00+00' AND h.with_manifest
                        AND h.via = CASE WHEN v IN (6218, 6270, 6284) THEN 'derm_tracker' ELSE 'admin_review' END);
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: control visits wrong: %', bad; END IF;
  --    112-YA visit 8113: the automatic email (row 189, no person) and the Admin Review report without the manifest (180)
  SELECT jsonb_agg(jsonb_build_object('id', send_id, 'via', via, 'label', app_label, 'name', sent_by_name, 'man', with_manifest)
                   ORDER BY sent_at, send_id) INTO r
    FROM public.v_visit_city_email_sends WHERE visit_id = 8113 AND sent_at < timestamptz '2026-10-13 00:00+00';
  IF r IS DISTINCT FROM '[{"id": 180, "via": "admin_review", "label": "Admin Review", "name": "Fred", "man": false},
                          {"id": 189, "via": "automatic", "label": "Automatic (system)", "name": null, "man": true}]'::jsonb THEN
    RAISE EXCEPTION 'VERIFY: 8113 reads %', r; END IF;

  -- 4. the state view and this one agree on every live visit (and the check sees sent visits)
  IF (SELECT count(*) FROM public.v_visit_city_email_state WHERE state = 'sent') = 0 THEN
    RAISE EXCEPTION 'VERIFY: no sent visit, the agreement check proves nothing'; END IF;
  bad := pg_temp.cses_disagree(0);
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: state and history disagree on %', bad[1:10]; END IF;
  -- 4b. the comparator can fire, arm by arm: moving ONE history minimum by 1 microsecond (arms 1 to 4), or changing
  --     the first via (arm 5), must flag exactly the visits whose matching state column is set, and that set is not empty
  FOR a IN 1..5 LOOP
    SELECT array_agg(visit_id ORDER BY visit_id) INTO want FROM public.v_visit_city_email_state
     WHERE CASE a WHEN 1 THEN city_email_sent_at IS NOT NULL WHEN 2 THEN ar_sent_at IS NOT NULL
                  WHEN 3 THEN ar_manifest_sent_at IS NOT NULL WHEN 4 THEN dt_sent_at IS NOT NULL ELSE sent_via IS NOT NULL END;
    bad := pg_temp.cses_disagree(a);
    IF want IS NULL OR bad IS DISTINCT FROM want THEN
      RAISE EXCEPTION 'VERIFY: the agreement check cannot fire on arm %: it flagged % visit(s), expected %', a, cardinality(bad), cardinality(want); END IF;
  END LOOP;

  -- 5. live fixture equals a plain read (the fixture harness itself is sound)
  w := pg_temp.cses_fixture('live');
  IF w->'disagree' IS DISTINCT FROM 'null'::jsonb OR jsonb_array_length(w#>'{rows,6218}') IS DISTINCT FROM 1
     OR jsonb_array_length(w#>'{rows,6275}') IS DISTINCT FROM 1 OR w#>'{rows,6279}' IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY: live fixture reads %', w; END IF;

  -- 6. every fixture: the two views still agree everywhere, and the history reads what the mutation means
  FOR fk IN SELECT unnest(ARRAY['f1_ar_without_manifest', 'f2_ar_null_after_doc', 'f3_ar_null_before_doc',
                                'f4_nothing_attached', 'f5_no_actor_after_go_live', 'f6_no_actor_before_go_live',
                                'f7_test_send', 'f8_failed_send', 'f9_deleted_manifest', 'f10_names',
                                'f11_second_later_ar_send', 'f12_client_send', 'f13_ar_failed_send',
                                'f14_no_actor_first_week']) LOOP
    w := pg_temp.cses_fixture(fk);
    IF w->'disagree' IS DISTINCT FROM 'null'::jsonb THEN RAISE EXCEPTION 'VERIFY: % state and history disagree on %', fk, w->'disagree'; END IF;
    IF (CASE fk
      WHEN 'f1_ar_without_manifest' THEN w#>>'{rows,6275,0,man}' = 'false' AND w#>>'{rows,6275,0,ph}' = 'false'
                                         AND w#>>'{st,6275,state}' = 'report_sent_manifest_follows'
      WHEN 'f2_ar_null_after_doc' THEN w#>>'{rows,6275,0,man}' = 'true' AND w#>>'{st,6275,sent_via}' = 'admin_review'
      WHEN 'f3_ar_null_before_doc' THEN w#>>'{rows,6275,0,man}' = 'false' AND w#>>'{st,6275,state}' = 'report_sent_manifest_follows'
      WHEN 'f4_nothing_attached' THEN jsonb_array_length(w#>'{rows,6218}') = 1 AND w#>>'{rows,6218,0,man}' = 'false'
                                      AND w#>>'{rows,6218,0,ph}' = 'false' AND w#>>'{st,6218,state}' = 'needs_city_email'
      WHEN 'f5_no_actor_after_go_live' THEN w#>>'{rows,6218,0,via}' = 'automatic' AND w#>'{rows,6218,0,name}' = 'null'::jsonb
                                            AND w#>>'{rows,6218,0,label}' = 'Automatic (system)' AND w#>>'{st,6218,sent_via}' = 'automatic'
      WHEN 'f6_no_actor_before_go_live' THEN w#>>'{rows,6218,0,via}' = 'derm_tracker' AND w#>'{rows,6218,0,name}' = 'null'::jsonb
                                             AND w#>>'{rows,6218,0,label}' = 'DERM Tracker'
      WHEN 'f7_test_send' THEN w#>'{rows,6218}' IS NULL
      WHEN 'f8_failed_send' THEN w#>'{rows,6218}' IS NULL
      WHEN 'f9_deleted_manifest' THEN w#>'{rows,6218}' IS NULL AND w#>'{rows,6279}' IS NULL
      WHEN 'f10_names' THEN w#>>'{rows,6218,0,name}' = 'Serena Natali' AND w#>>'{rows,6275,0,name}' = 'nobody.here@unclogme.com'
      WHEN 'f11_second_later_ar_send' THEN jsonb_array_length(w#>'{rows,6275}') = 2
                                           AND (w#>>'{st,6275,city_email_sent_at}')::timestamptz = (w#>>'{rows,6275,0,at}')::timestamptz
      WHEN 'f12_client_send' THEN w#>'{rows,6218}' IS NULL
      WHEN 'f13_ar_failed_send' THEN w#>'{rows,6275}' IS NULL AND w#>>'{st,6275,state}' = 'needs_city_email'
      WHEN 'f14_no_actor_first_week' THEN w#>>'{rows,6218,0,via}' = 'automatic' AND w#>'{rows,6218,0,name}' = 'null'::jsonb
                                          AND w#>>'{st,6218,sent_via}' = 'automatic'
      ELSE false
    END) IS NOT TRUE THEN
      RAISE EXCEPTION 'VERIFY: fixture % read %', fk, w;
    END IF;
  END LOOP;

  -- 7. nothing the fixtures touched leaked out of their subtransactions
  IF EXISTS (SELECT 1 FROM _cses_rows x
              WHERE x.h IS DISTINCT FROM CASE
                WHEN x.k LIKE 'des:%' THEN (SELECT md5(to_jsonb(s)::text) FROM public.derm_email_sends s WHERE 'des:' || s.id = x.k)
                ELSE (SELECT md5(to_jsonb(s)::text) FROM public.visit_photo_email_sends s WHERE 'vpes:' || s.id = x.k) END)
     OR (SELECT count(*) FROM _cses_rows WHERE k IN ('des:191', 'vpes:187')) <> 2 OR (SELECT count(*) FROM _cses_rows) < 3 THEN
    RAISE EXCEPTION 'VERIFY: a fixture leaked'; END IF;

  RAISE NOTICE 'VERIFY ok: % rows', (SELECT count(*) FROM public.v_visit_city_email_sends);
END $verify$;

DROP FUNCTION pg_temp.cses_fixture(text);
DROP FUNCTION pg_temp.cses_disagree(int);
NOTIFY pgrst, 'reload schema';

COMMIT;

-- read-only receipt (the Management API returns the last result)
SELECT jsonb_build_object(
  'applied', to_regclass('public.v_visit_city_email_sends') IS NOT NULL,
  'viewdef_md5', md5(pg_get_viewdef('public.v_visit_city_email_sends'::regclass)),
  'relacl', (SELECT relacl::text FROM pg_class WHERE oid = 'public.v_visit_city_email_sends'::regclass),
  'rows', (SELECT jsonb_object_agg(via, n) FROM (SELECT via, count(*) n FROM public.v_visit_city_email_sends GROUP BY 1) z)) AS receipt;
