-- ============================================================================
-- 2026-10-12_1305 public.v_visit_city_email_state: ONE per-visit answer to "has this visit's city email gone?",
--                 and the 11 AM Admin Review post (fn_admin_review_pending) reads its city list from it
-- ============================================================================
-- THE ASK
--   Diego replied to the 11 AM post "Admin Review: photos and city emails" (Slack, 2026-10-12) that the 5 visits it
--   listed were not his to send: "plug in is a unclog", "kc is waiting manifest so off course I can not sent it",
--   "a la carte, I already sent it o october 9". 2026-10-12_1120 patched three predicates in the function. The audit
--   that followed (2026-10-12, read-only) measured SEVEN different readings of "sent" across the reminder, the two
--   apps and the two senders, and duplicate regulator emails (Hallandale Beach got 6247 three times, 6138 twice).
--   Its first prevention item: one "city email done" answer that the reminder, both apps and both senders read.
--   This file builds that answer and moves the post's city list onto it. Nothing else reads it yet.
--   Pre-go-live visits (dated before 2026-09-15) are not city-email work: Fred, 2026-10-12, "we don't care about the
--   old for this". They read before_go_live unless a state above it applies (sent, report_sent_manifest_follows,
--   not_derm, not_for_city, no_city_email).
--
--   The post does NOT change in this cycle: same keys (city, photos), same item shape, same visits. Any new line
--   waits for Fred to pick it on a mockup. The manifest hold (a visit with no manifest linked is not listed) is
--   Diego's practice, kept from 2026-10-12_1120; whether the post should hold for the manifest or follow the
--   Admin-Review-first rule is still an open question for Fred. A visit held too long is caught by the notification
--   health check (public.log_notification_health, item no_manifest_after_14_days, its own migration), not here.
--
-- WHAT CHANGES
--   A. NEW VIEW public.v_visit_city_email_state, one row per live visit (public.v_visits_live):
--      visit_id, client_id, property_id, visit_date, visit_status, derm_required,
--      not_for_city, city_email_on_file, regulator_municipality   (from public.v_visit_city_email, unchanged)
--      manifest_ids bigint[]   live linked manifests (manifest_visits + derm_manifests.deleted_at IS NULL), '{}' if none
--      has_manifest
--      ar_sent_at              first REAL Admin Review send of this visit (visit_photo_email_sends sent, not test)
--      ar_sent_with_manifest   a real Admin Review send carried the manifest: include_manifest true, or NULL and sent
--                              at or after the pair's FOG document (blacked_at as derm.v_city_email_candidates' docs
--                              CTE: latest redacted doc, else latest uploaded FDEP sheet). false (never NULL) when none
--      ar_manifest_sent_at     first such send
--      dt_sent_at              first REAL city derm_email_sends row (sent, not test) for a LIVE manifest of this visit
--                              and this client (DERM Tracker "Send to city" or the automatic sweep)
--      city_email_sent_at      first moment the city had the manifest = least(dt_sent_at, ar_manifest_sent_at)
--      sent_via                'admin_review' | 'derm_tracker' | 'automatic' | NULL, for the send at city_email_sent_at
--      state, first match wins:
--        not_completed                 visit_status is not 'completed'
--        sent                          the city has the manifest (city_email_sent_at is set)
--        report_sent_manifest_follows  a real Admin Review send WITHOUT the manifest and no DERM Tracker send yet: the
--                                      automatic sweep sends the manifest (2026-09-11 rule)
--        not_derm                      derm_required IS FALSE (NULL counts as required, as in both senders)
--        not_for_city                  grey water list (public.v_visit_not_for_city)
--        no_city_email                 no '@' inbox on the property
--        before_go_live                dated before 2026-09-15, the city email go-live day (Fred, 2026-10-12). Below
--                                      sent, so an old visit that was sent still reads sent; above the last two, so
--                                      waiting_manifest and needs_city_email never apply before go-live
--        waiting_manifest              no live manifest linked
--        needs_city_email              everything is ready and nothing carrying the manifest has gone
--      Owner-rights view (owner postgres, no security_invoker), SELECT to authenticated and service_role only, anon
--      and PUBLIC nothing (asserted below, including a real read as authenticated and a refused read as anon).
--   B. public.fn_admin_review_pending(): ONLY the pend CTE changes. city = state 'needs_city_email', dated 2026-09-15
--      or later (a second guard on purpose: the view already reads before_go_live there), test and fixture clients
--      left out (public.fn_is_non_customer, as before). The rest of the body (today, unsorted, the output) is the live
--      pg_get_functiondef text, md5 pinned in $pre$. Output keys stay exactly city + photos. VERIFY runs the 11:20
--      function and the new one on the same 13 inputs (live data and 12 rolled-back mutations of the send logs) and
--      requires the WHOLE city list, items included, to be equal on all of them except m8, the first intended
--      difference, where it requires them to differ. Two INTENDED differences, each 0 rows today:
--        1. a city row labelled 'attachment:manifest_images%' no longer counts as sent (DEVIATION 2). Fixture m8.
--        2. a city send on a SOFT-DELETED manifest no longer counts (the 11:20 body read
--           public.v_visit_city_email_status, which does not check derm_manifests.deleted_at). Measured: 0 real sends
--           on a deleted manifest. Fixture m5 shows the view not crediting it.
--      Grants re-asserted by name: EXECUTE for service_role only.
--
-- DEVIATIONS FROM THE AGREED INTERFACE (each from evidence, each changes 0 rows today)
--   1. Extra column ar_manifest_sent_at: city_email_sent_at needs WHEN the Admin Review send carried the manifest,
--      not only whether one did (6138 and 6247: the DERM Tracker went first on 09-25, Admin Review on 10-08).
--   2. A derm_email_sends row whose reason starts 'attachment:manifest_images' is NOT counted as the city having the
--      manifest. send-derm-email (since 2026-08-26) sends the city letter with NOTHING attached when it cannot build
--      the report (for example ambiguous_visit: 2 or more DERM visits of the client on the manifest) and logs it
--      'sent' with that label. Real rows with that label: 0 (all 6 are tests).
--   3. sent_via 'automatic' needs sent_by_email NULL AND sent_at at or after 2026-09-15 13:07:34.336825 UTC, the
--      value of app_config.city_email_start_from when the sweep went live. A FIXED literal on purpose: the config is
--      the sweep's switch and moves if the sweep is paused and restarted, and moving it must not relabel history. The
--      17 real June/July city sends also have sent_by_email NULL (actor logging starts 2026-09-22) and predate the
--      sweep, so they read 'derm_tracker'.
--   4. ar_sent_with_manifest is false, never NULL, when there is no Admin Review send, so NOT x is safe in an app.
--
-- KNOWN LIMITS (recorded here so nobody rediscovers them)
--   1. (manifest, client) attribution. derm_email_sends has no visit_id, so a DERM Tracker or sweep send is credited
--      to every visit of that client on that manifest. Measured 2026-10-12: 29 real city sends, 0 whose pair has more
--      than one live visit of the client, 0 on a deleted manifest, 0 links made after the send; 19 live pairs have 2+
--      completed DERM visits, 0 dated since 09-15, none with a send. What is left after DEVIATION 2: a report sent
--      while the pair had ONE completed DERM visit is also credited to a visit linked to the same manifest later.
--      CYCLE-2 PLAN (not in this file, it needs an edge function deploy):
--        a. ALTER TABLE public.derm_email_sends ADD COLUMN visit_id bigint REFERENCES public.visits(id), nullable, no
--           default (metadata only, but ACCESS EXCLUSIVE for a moment: lock_timeout 3s, tiny transaction; the table
--           is audited, so rule 8 is already met).
--        b. send-derm-email writes the attached report's visit (rv.id from buildReportAttachment) on a 'sent' row when
--           a report went, NULL otherwise.
--        c. here, one predicate in the dt lateral: AND (s.visit_id IS NULL OR s.visit_id = v.id). NULL keeps today's
--           pair rule, measured safe for all 29 rows.
--   2. Admin Review credit is per VISIT, DERM Tracker credit is per PAIR, and derm.v_city_email_candidates'
--      suppressed_manual is per pair. Visit B of a pair whose visit A went from Admin Review WITH the manifest reads
--      needs_city_email here while the sweep calls the pair suppressed_manual. 0 cases today, and VERIFY refuses to
--      apply if one exists. Which grain is right is Fred's call.
--   3. Differs from the sweep on DEVIATION 2: derm.v_city_email_candidates counts an 'attachment:manifest_images%'
--      row as already_sent (the sweep never sends again), this view says the city does not have the manifest. Real
--      rows: 0. The sweep is not changed in this cycle. Also in COMMENT ON VIEW. VERIFY 5a leaves such a pair out, so
--      one that appears before apply does not stop this file with a false "candidates says sent".
--   4. Scope. The view covers every live visit. The go-live date is IN the view (state before_go_live, Fred
--      2026-10-12): the 119 completed visits dated 2026-09-14 or earlier that would otherwise read needs_city_email
--      read before_go_live. Test clients are NOT left out (112-YA's visits are in the view): each reader leaves them
--      out itself, as fn_admin_review_pending does (fn_is_non_customer test/fixture).
--   5. Two rules are COPIED, not referenced: blacked_at mirrors the candidates docs CTE (reading candidates is not
--      possible here: it calls fn_city_email_delay and fn_city_email_retry_after, which authenticated cannot EXECUTE,
--      so an authenticated read of this view would fail 42501), and the go-live literal (DEVIATION 3). VERIFY checks
--      agreement with candidates in both directions over every live visit, so a drift stops this file at apply.
--   6. A LANGUAGE sql function body leaves NO pg_depend edge on the view. DROP VIEW ... CASCADE, or a drop and
--      re-create for a column change (which also drops the grants), is not refused and breaks the 11 AM post
--      silently. COMMENT ON VIEW names the reader. Change this view with CREATE OR REPLACE VIEW only, columns added
--      at the end. The rollback refuses while any other function's text names the view, for the same reason.
--   7. What VERIFY cannot see today (measured with deliberate breaks, tests/eqmut_*): a deleted FDEP sheet counted
--      in the include_manifest NULL path (0 real sends have include_manifest NULL, and a fixture would have to write
--      derm.manifest_visit_sheets), and before_go_live moved below waiting_manifest (0 pre-go-live visits without a
--      manifest pass the lines above it; check 9c catches it the day one exists). Dropping the post's own date line
--      changes nothing while the view reads before_go_live, which is what a second guard is.
--
-- MEASURED BEFORE WRITING (2026-10-12 14:04 to 14:16 ET by the DB clock, a rolled-back test built from this exact
--   text, test_city_email_state.sql, and a rolled-back run of this whole file): 2252 live visits, one row each.
--   States: not_completed 833, no_city_email 676, not_derm 560, before_go_live 119, sent 32, not_for_city 30,
--   waiting_manifest 2 (8741, 8764), needs_city_email 0. The 119 before_go_live (dated 2026-01-06 to 2026-09-14) all
--   have a manifest, so without that line they read needs_city_email (as in the 13:10 run); 18 sent visits are dated
--   before go-live and still read sent. The 18 completed visits since 09-15 with a city inbox: 14 sent, 2 not_derm
--   (8575, 8744), 2 waiting_manifest.
--   6218/6270/6284 sent via derm_tracker; 6275/8133/6237/6253/8232 sent via admin_review; 6138 and 6247 read the
--   09-25 DERM Tracker send (rows 186 and 184), the earliest. Estate-wide the view agrees with
--   derm.v_city_email_candidates both ways and with the 11:20 function's "done" test (32 sent, 0 disagreements).
--   New function output == 11:20 output (city [] today; photos 65, 21 in the last 7 days, oldest Jul 27). The view
--   reads in 17 ms (one visit 2 ms); the function takes 114 ms against 108 ms for the 11:20 body. The whole file,
--   VERIFY included, holds its transaction for about 4.3 s.
--
-- NOT CHANGED: the Admin Review and DERM Tracker apps, send-visit-photos-email, send-derm-email, derm.visits,
--   derm.manifest_recipients, public.v_visit_city_email_status, derm.v_city_email_candidates (the sweep), the
--   admin-review-reminder edge function, and public.fn_request_admin_review_reminder (the output keys do not change,
--   so its "nothing waiting" test on city and photos.count is still right; the run-record migration rewrites it).
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table created or altered; a view holds no rows. The two send logs it reads
--   are audited (audit_visit_photo_email_sends, audit_derm_email_sends; each has no other trigger). The VERIFY
--   fixtures write ONLY to those two tables, inside subtransactions that always roll back (their audit rows roll
--   back with them), and VERIFY re-reads the touched rows afterwards.
-- LOCKS: CREATE VIEW on a new name and CREATE OR REPLACE FUNCTION block no app reader. The fixtures hold row locks
--   on derm_email_sends 189, 191 and visit_photo_email_sends 180, 187 and one test row for milliseconds each. The
--   AccessShare locks on the views this one reads last until COMMIT (about 4.3 s), so apply the other 2026-10-12
--   migrations one after another, never at the same time. Refuses to run from 10:55 to 11:05 ET (the 11 AM post).
--   REPEATABLE READ: VERIFY compares the 11:20 and the new output on ONE snapshot. If one of the five fixture rows
--   is changed by someone else during those 4 s, the file stops with a serialization error: just run it again.
-- ROLLBACK: check the live body is this file's (pg_get_functiondef md5 0c87852b0765f00ed76ff970c2a0b5ba), re-apply the
--           CREATE OR REPLACE FUNCTION of 2026-10-12_1120 (md5 fc907c5c3b4c9f4c33f74281ccf5f7f5), then
--           DROP VIEW public.v_visit_city_email_state; (in that order: the function reads the view). The rollback
--           file refuses while any other function's text names the view (KNOWN LIMIT 6). Tested rolled back.
-- ============================================================================

-- ONE snapshot for the whole file, so the before/after comparison in VERIFY cannot be moved by someone else's commit
-- (measured while testing: the photos count changed between the two reads of one run, twice).
BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL lock_timeout = '3s';

DO $pre$
BEGIN
  IF md5(pg_get_functiondef('public.fn_admin_review_pending()'::regprocedure)) <> 'fc907c5c3b4c9f4c33f74281ccf5f7f5' THEN
    RAISE EXCEPTION 'fn_admin_review_pending changed since this file was written: re-copy the live body';
  END IF;
  IF to_regclass('public.v_visit_city_email_state') IS NOT NULL THEN
    RAISE EXCEPTION 'public.v_visit_city_email_state already exists';
  END IF;
  IF (now() AT TIME ZONE 'America/New_York')::time BETWEEN time '10:55' AND time '11:05' THEN
    RAISE EXCEPTION 'the 11 AM Admin Review post runs now: apply after 11:05 ET';
  END IF;
END $pre$;

-- ---------------------------------------------------------------------------- A. the state view
CREATE VIEW public.v_visit_city_email_state AS
SELECT v.id AS visit_id,
       v.client_id,
       v.property_id,
       v.visit_date,
       v.visit_status,
       v.derm_required,
       ce.not_for_city,
       ce.city_email_on_file,
       ce.regulator_municipality,
       mf.manifest_ids,
       cardinality(mf.manifest_ids) > 0 AS has_manifest,
       ar.ar_sent_at,
       ar.ar_manifest_sent_at IS NOT NULL AS ar_sent_with_manifest,
       ar.ar_manifest_sent_at,
       dt.dt_sent_at,
       least(dt.dt_sent_at, ar.ar_manifest_sent_at) AS city_email_sent_at,
       CASE
         WHEN ar.ar_manifest_sent_at IS NOT NULL
              AND (dt.dt_sent_at IS NULL OR ar.ar_manifest_sent_at <= dt.dt_sent_at) THEN 'admin_review'
         -- the sweep sends with the service key, so no actor. Before go-live (and before actor logging, 09-22) a NULL
         -- actor was a DERM Tracker send. Fixed literal = app_config.city_email_start_from at go-live, on purpose:
         -- the config can move, history must not change label when it does.
         WHEN dt.dt_sent_at IS NOT NULL AND dt.dt_sent_by_email IS NULL
              AND dt.dt_sent_at >= timestamptz '2026-09-15 13:07:34.336825+00' THEN 'automatic'
         WHEN dt.dt_sent_at IS NOT NULL THEN 'derm_tracker'
       END AS sent_via,
       CASE
         WHEN v.visit_status IS DISTINCT FROM 'completed' THEN 'not_completed'
         WHEN dt.dt_sent_at IS NOT NULL OR ar.ar_manifest_sent_at IS NOT NULL THEN 'sent'
         WHEN ar.ar_sent_at IS NOT NULL THEN 'report_sent_manifest_follows'
         WHEN v.derm_required IS FALSE THEN 'not_derm'
         WHEN ce.not_for_city THEN 'not_for_city'
         WHEN NOT ce.city_email_on_file THEN 'no_city_email'
         -- Fred, 2026-10-12, on the visits from before the city email went live: "we don't care about the old for this"
         WHEN v.visit_date < DATE '2026-09-15' THEN 'before_go_live'
         WHEN cardinality(mf.manifest_ids) = 0 THEN 'waiting_manifest'
         ELSE 'needs_city_email'
       END AS state
FROM public.v_visits_live v
JOIN public.v_visit_city_email ce ON ce.visit_id = v.id
-- live manifests linked to the visit
CROSS JOIN LATERAL (
  SELECT coalesce(array_agg(mv.manifest_id ORDER BY mv.manifest_id), '{}'::bigint[]) AS manifest_ids
  FROM public.manifest_visits mv
  JOIN public.derm_manifests dm ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL
  WHERE mv.visit_id = v.id
) mf
-- real Admin Review sends of THIS visit. A send carried the manifest when include_manifest is true, or (rows from
-- before that column existed) when it is NULL and the send came at or after the pair's FOG document: blacked_at is
-- derm.v_city_email_candidates' docs CTE (latest redacted doc, else latest uploaded FDEP sheet). Keep them in step.
CROSS JOIN LATERAL (
  SELECT min(s.sent_at) AS ar_sent_at,
         min(s.sent_at) FILTER (WHERE s.include_manifest IS TRUE
           OR (s.include_manifest IS NULL AND EXISTS (
                SELECT 1 FROM unnest(mf.manifest_ids) m(id)
                WHERE s.sent_at >= coalesce(
                  (SELECT max(r.generated_at) FROM derm.redacted_manifest_docs r
                    WHERE r.manifest_id = m.id AND r.client_id = v.client_id),
                  (SELECT max(coalesce(sh.uploaded_at, sh.generated_at, sh.created_at)) FROM derm.manifest_visit_sheets sh
                    WHERE sh.manifest_id = m.id AND sh.client_id = v.client_id AND sh.deleted_at IS NULL
                      AND coalesce(sh.photo_bucket, '') <> '' AND coalesce(sh.photo_path, '') <> ''))))) AS ar_manifest_sent_at
  FROM public.visit_photo_email_sends s
  WHERE s.visit_id = v.id AND s.status = 'sent' AND NOT s.is_test
) ar
-- first real DERM Tracker / sweep city send of a live manifest of this visit, for this client. derm_email_sends has
-- no visit_id, so a send is credited to every visit of that client on that manifest (KNOWN LIMIT 1). A row labelled
-- 'attachment:manifest_images:...' is a letter that went out with NOTHING attached, so it does not count.
LEFT JOIN LATERAL (
  SELECT s.sent_at AS dt_sent_at, s.sent_by_email AS dt_sent_by_email
  FROM public.derm_email_sends s
  WHERE s.manifest_id = ANY (mf.manifest_ids) AND s.client_id = v.client_id
    AND s.recipient_type = 'city' AND s.status = 'sent' AND NOT s.is_test
    AND coalesce(s.reason, '') NOT LIKE 'attachment:manifest_images%'
  ORDER BY s.sent_at, s.id
  LIMIT 1
) dt ON true;

COMMENT ON VIEW public.v_visit_city_email_state IS
  'One row per live visit: has its city email gone? state (first match wins): not_completed, sent (the city has the '
  'manifest, from Admin Review with the manifest or the DERM Tracker / automatic sweep), report_sent_manifest_follows, '
  'not_derm, not_for_city, no_city_email, before_go_live (dated before 2026-09-15 and not sent: not city email '
  'work, Fred 2026-10-12), waiting_manifest, needs_city_email. Read this, never rebuild the rule. '
  'Every live visit is here, test clients included: each reader leaves those out itself. '
  'Differs from derm.v_city_email_candidates on purpose: a city row labelled attachment:manifest_images (a letter '
  'with nothing attached) is not "sent" here, while the sweep counts it as already_sent. '
  'READ BY public.fn_admin_review_pending (the 11 AM Slack post). A sql function leaves no dependency, so never DROP '
  'or re-create this view: CREATE OR REPLACE only, new columns at the end. 2026-10-12_1305.';

REVOKE ALL ON public.v_visit_city_email_state FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.v_visit_city_email_state TO authenticated, service_role;

-- ---------------------------------------------------------------------------- fixtures for VERIFY
-- Applies ONE mutation inside a subtransaction that ALWAYS rolls back and returns what the post's function and this
-- view said while it was applied. Run once with the 11:20 function (before the replace) and once with the new one.
-- Writes only to derm_email_sends and visit_photo_email_sends (audit trigger only). Dropped before COMMIT.
CREATE FUNCTION pg_temp.cse_fixture(k text) RETURNS jsonb LANGUAGE plpgsql AS $fx$
DECLARE fn jsonb; payload text;
BEGIN
  BEGIN
    CASE k
      WHEN 'live' THEN NULL;
      -- 6218's only send (DERM Tracker row 191) failed: it needs a city email and the post lists it
      WHEN 'm1_dt_send_failed' THEN UPDATE public.derm_email_sends SET status = 'error' WHERE id = 191;
      -- 6275's Admin Review send (row 187) without the manifest: the report went, the sweep sends the manifest
      WHEN 'm2_ar_without_manifest' THEN UPDATE public.visit_photo_email_sends SET include_manifest = false WHERE id = 187;
      -- row 187 from before include_manifest existed (NULL), sent after the FOG document (09-25): carried the manifest
      WHEN 'm3_ar_null_after_doc' THEN UPDATE public.visit_photo_email_sends SET include_manifest = NULL WHERE id = 187;
      -- the same, sent before the FOG document: did not carry it
      WHEN 'm4_ar_null_before_doc' THEN
        UPDATE public.visit_photo_email_sends SET include_manifest = NULL, sent_at = timestamptz '2026-09-01 12:00+00' WHERE id = 187;
      -- row 191 moved onto soft-deleted manifest 1969 (client 329, linked to live visit 6279): a deleted manifest
      -- does not count, and 6218 has lost its only send
      WHEN 'm5_send_on_deleted_manifest' THEN UPDATE public.derm_email_sends SET manifest_id = 1969, client_id = 329 WHERE id = 191;
      -- a real Admin Review send without the manifest on an unclog visit (8575, derm_required false), using a borrowed
      -- test row: report_sent_manifest_follows outranks not_derm
      WHEN 'm6_ar_on_non_derm' THEN
        UPDATE public.visit_photo_email_sends SET visit_id = 8575, is_test = false, status = 'sent', include_manifest = false
         WHERE id = (SELECT min(id) FROM public.visit_photo_email_sends WHERE is_test);
      -- row 191 with no actor after go-live: the automatic sweep
      WHEN 'm7_no_actor_after_go_live' THEN UPDATE public.derm_email_sends SET sent_by_email = NULL WHERE id = 191;
      -- row 191 with no actor before go-live: a DERM Tracker send from before actor logging
      WHEN 'm7b_no_actor_before_go_live' THEN
        UPDATE public.derm_email_sends SET sent_by_email = NULL, sent_at = timestamptz '2026-07-01 12:00+00' WHERE id = 191;
      -- INTENDED DIFFERENCE 1: row 191 is a letter that went with nothing attached
      WHEN 'm8_nothing_attached' THEN
        UPDATE public.derm_email_sends SET reason = 'attachment:manifest_images:ambiguous_visit' WHERE id = 191;
      -- the test client 112-YA (visit 8113) with no send at all (rows 189 and 180 failed): never listed
      WHEN 'm9_test_client' THEN
        UPDATE public.derm_email_sends SET status = 'error' WHERE id = 189;
        UPDATE public.visit_photo_email_sends SET status = 'error' WHERE id = 180;
      -- 6275's only send (Admin Review row 187) failed. 6275 is dated 2026-09-15, the go-live day itself: both
      -- bodies must list it (the boundary of before_go_live and of the post's own date line)
      WHEN 'm10_go_live_day_send_failed' THEN UPDATE public.visit_photo_email_sends SET status = 'error' WHERE id = 187;
      -- a borrowed test row as a second, LATER Admin Review send with the manifest on 6275: the first one still counts
      WHEN 'm11_second_later_ar_send' THEN
        UPDATE public.visit_photo_email_sends SET visit_id = 6275, is_test = false, status = 'sent', include_manifest = true,
               sent_at = (SELECT s2.sent_at + interval '1 day' FROM public.visit_photo_email_sends s2 WHERE s2.id = 187)
         WHERE id = (SELECT min(id) FROM public.visit_photo_email_sends WHERE is_test);
      ELSE RAISE EXCEPTION 'no such fixture %', k;
    END CASE;
    EXECUTE 'SELECT public.fn_admin_review_pending()' INTO fn;
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'cse_fixture:' || jsonb_build_object(
      'fn', fn,
      'st', (SELECT jsonb_object_agg(visit_id, jsonb_build_object('state', state, 'sent_via', sent_via, 'dt_sent_at', dt_sent_at,
                                                                  'city_email_sent_at', city_email_sent_at))
               FROM public.v_visit_city_email_state WHERE visit_id IN (6218, 6275, 6279, 8113, 8575)))::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'cse_fixture:%' THEN RAISE; END IF;
    payload := substr(SQLERRM, length('cse_fixture:') + 1);
  END;
  RETURN payload::jsonb;
END $fx$;

CREATE TEMP TABLE _cse_rows ON COMMIT DROP AS
SELECT 'des:' || s.id AS k, md5(to_jsonb(s)::text) AS h FROM public.derm_email_sends s WHERE s.id IN (189, 191)
UNION ALL
SELECT 'vpes:' || s.id, md5(to_jsonb(s)::text) FROM public.visit_photo_email_sends s
 WHERE s.id IN (180, 187) OR s.id = (SELECT min(id) FROM public.visit_photo_email_sends WHERE is_test);

CREATE TEMP TABLE _cse_old ON COMMIT DROP AS
SELECT k, pg_temp.cse_fixture(k) AS r
FROM unnest(ARRAY['live', 'm1_dt_send_failed', 'm2_ar_without_manifest', 'm3_ar_null_after_doc', 'm4_ar_null_before_doc',
                  'm5_send_on_deleted_manifest', 'm6_ar_on_non_derm', 'm7_no_actor_after_go_live',
                  'm7b_no_actor_before_go_live', 'm8_nothing_attached', 'm9_test_client',
                  'm10_go_live_day_send_failed', 'm11_second_later_ar_send']) k;

-- ---------------------------------------------------------------------------- B. the 11 AM post reads it
CREATE OR REPLACE FUNCTION public.fn_admin_review_pending()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH today AS (SELECT (now() AT TIME ZONE 'America/New_York')::date AS d),
  pend AS (
    -- completed since the city email went live (2026-09-15 09:07 ET), read from public.v_visit_city_email_state, the
    -- one per-visit answer (2026-10-12_1305). needs_city_email = DERM-required (NULL counts as required), not grey
    -- water, the city has an email on file, dated 2026-09-15 or later (older visits read before_go_live), a live
    -- manifest is linked, and nothing carrying the manifest has gone yet (Admin Review with the manifest, the DERM
    -- Tracker "Send to city", or the automatic sweep). The date line below repeats before_go_live on purpose, so no
    -- later change to the view can put a pre-go-live visit on the post. Not listed:
    -- waiting_manifest (no manifest linked yet, held: Diego, 2026-10-12, "kc is waiting manifest so off course I can
    -- not sent it") and report_sent_manifest_follows (Admin Review sent the report without the manifest; the sweep
    -- sends the manifest). A visit held too long is a health-check item (log_notification_health), not a post line.
    SELECT st.visit_id, c.client_code, c.name AS client_name, st.regulator_municipality AS city,
           st.visit_date, e.full_name AS driver,
           coalesce(pc.total_images, 0) AS photos_total, coalesce(pc.classified_images, 0) AS photos_sorted
    FROM public.v_visit_city_email_state st
    JOIN public.visits v ON v.id = st.visit_id
    JOIN public.clients c ON c.id = st.client_id
    LEFT JOIN public.v_visit_photo_counts pc ON pc.visit_id = st.visit_id
    LEFT JOIN public.employees e ON e.id = v.assigned_driver_id
    WHERE st.state = 'needs_city_email'
      AND st.visit_date >= DATE '2026-09-15'
      AND NOT public.fn_is_non_customer(st.client_id, ARRAY['test', 'fixture'])
  ),
  unsorted AS (
    -- the Admin Review queue's "Photos Not Sorted": in the queue, and some photo not classified yet
    SELECT w.id, w.visit_date
    FROM public.visits_with_review w
    JOIN public.v_visit_photo_counts pc ON pc.visit_id = w.id
    WHERE w.visit_status = 'completed' AND w.in_review_scope
      AND w.visit_date <= (SELECT d FROM today)
      AND pc.total_images > pc.classified_images
      AND NOT public.fn_is_non_customer(w.client_id, ARRAY['test', 'fixture'])
  )
  SELECT jsonb_build_object(
    'city', coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.city, p.visit_date, p.client_code) FROM pend p), '[]'::jsonb),
    'photos', jsonb_build_object(
      'count', (SELECT count(*) FROM unsorted),
      'last_7_days', (SELECT count(*) FROM unsorted WHERE visit_date > (SELECT d FROM today) - 7),
      'oldest', (SELECT min(visit_date) FROM unsorted)))
$function$;

REVOKE ALL ON FUNCTION public.fn_admin_review_pending() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_admin_review_pending() TO service_role;

-- ---------------------------------------------------------------------------- VERIFY
DO $verify$
DECLARE
  acl text[];
  bad bigint[];
  n bigint;
  e_anon text := 'no error';
  fk text;
  o jsonb;
  w jsonb;
  intended constant text[] := ARRAY['m8_nothing_attached'];
BEGIN
  -- 1. the view: owner-rights, owned by postgres, exactly SELECT for authenticated and service_role (plus the
  --    backup reader from the schema default), nothing for anon or PUBLIC
  IF (SELECT relowner FROM pg_class WHERE oid = 'public.v_visit_city_email_state'::regclass) <> 'postgres'::regrole
     OR (SELECT reloptions FROM pg_class WHERE oid = 'public.v_visit_city_email_state'::regclass) IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY: the view must be owned by postgres with no reloptions (owner rights)'; END IF;
  SELECT array_agg(coalesce(nullif(a.grantee::regrole::text, '-'), 'PUBLIC') || ':' || a.privilege_type
                   ORDER BY coalesce(nullif(a.grantee::regrole::text, '-'), 'PUBLIC'), a.privilege_type)
    INTO acl
    FROM pg_class c, aclexplode(c.relacl) a
   WHERE c.oid = 'public.v_visit_city_email_state'::regclass AND a.grantee <> c.relowner;
  IF acl IS DISTINCT FROM ARRAY['authenticated:SELECT', 'db_backup_reader:SELECT', 'service_role:SELECT'] THEN
    RAISE EXCEPTION 'VERIFY: view grants are %', acl; END IF;
  IF has_table_privilege('anon', 'public.v_visit_city_email_state', 'SELECT') THEN RAISE EXCEPTION 'VERIFY: anon reads the view'; END IF;
  IF has_table_privilege('authenticated', 'public.v_visit_city_email_state', 'INSERT,UPDATE,DELETE,TRUNCATE') THEN RAISE EXCEPTION 'VERIFY: authenticated can write'; END IF;
  IF NOT has_table_privilege('service_role', 'public.v_visit_city_email_state', 'SELECT') THEN RAISE EXCEPTION 'VERIFY: service_role cannot read'; END IF;
  -- a real read as authenticated (nothing inside needs a grant it lacks) and a refused read as anon
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM public.v_visit_city_email_state;
  RESET ROLE;
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM count(*) FROM public.v_visit_city_email_state;
  EXCEPTION WHEN insufficient_privilege THEN e_anon := SQLSTATE;
  END;
  RESET ROLE;
  IF n <> (SELECT count(*) FROM public.v_visits_live) OR e_anon <> '42501' THEN
    RAISE EXCEPTION 'VERIFY: as authenticated % rows, as anon %', n, e_anon; END IF;

  -- 2. the function: EXECUTE for service_role only (it sits in the notification chain)
  IF has_function_privilege('anon', 'public.fn_admin_review_pending()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_admin_review_pending()', 'EXECUTE')
     OR has_function_privilege('public', 'public.fn_admin_review_pending()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.fn_admin_review_pending()', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY: fn_admin_review_pending grants moved'; END IF;

  -- 3. one row per live visit
  IF (SELECT count(*) FROM public.v_visit_city_email_state) <> (SELECT count(*) FROM public.v_visits_live)
     OR (SELECT count(*) - count(DISTINCT visit_id) FROM public.v_visit_city_email_state) <> 0 THEN
    RAISE EXCEPTION 'VERIFY: not one row per live visit'; END IF;

  -- 4. positive controls on history that cannot change: the 5 false alarms of 10-12, the 5 Admin Review sends that
  --    carried the manifest, the earliest send for the two duplicates
  SELECT array_agg(visit_id ORDER BY visit_id) INTO bad FROM public.v_visit_city_email_state
   WHERE (visit_id IN (6218, 6270, 6284) AND (state, sent_via) IS DISTINCT FROM ('sent', 'derm_tracker'))
      OR (visit_id IN (6275, 8133, 6237, 6253, 8232) AND ((state, sent_via) IS DISTINCT FROM ('sent', 'admin_review') OR NOT ar_sent_with_manifest))
      OR (visit_id IN (8575, 8744) AND state <> 'not_derm')
      OR (visit_id = 6138 AND city_email_sent_at IS DISTINCT FROM (SELECT sent_at FROM public.derm_email_sends WHERE id = 186))
      OR (visit_id = 6247 AND city_email_sent_at IS DISTINCT FROM (SELECT sent_at FROM public.derm_email_sends WHERE id = 184));
  IF bad IS NOT NULL OR (SELECT count(*) FROM public.v_visit_city_email_state
                          WHERE visit_id IN (6218,6270,6284,6275,8133,6237,6253,8232,8575,8744,6138,6247)) <> 12 THEN
    RAISE EXCEPTION 'VERIFY: control visits wrong: %', bad; END IF;

  -- 5. the sweep's own pair answer, both directions, over every live visit
  --    a. a pair the sweep calls sent: no visit of it still needs a city email (the join must see rows). A pair
  --       whose only real city sends are letters with nothing attached is left out: that is INTENDED DIFFERENCE 1
  --       (KNOWN LIMIT 3), not a drift
  SELECT count(*), array_agg(DISTINCT st2.visit_id) FILTER (WHERE st2.state NOT IN ('sent', 'not_completed'))
    INTO n, bad
    FROM derm.v_city_email_candidates c
    JOIN public.manifest_visits mv ON mv.manifest_id = c.manifest_id
    JOIN public.v_visit_city_email_state st2 ON st2.visit_id = mv.visit_id AND st2.client_id = c.client_id
   WHERE c.status IN ('already_sent', 'suppressed_manual')
     AND NOT (c.status = 'already_sent' AND NOT EXISTS (
           SELECT 1 FROM public.derm_email_sends d
            WHERE d.manifest_id = c.manifest_id AND d.client_id = c.client_id AND d.recipient_type = 'city'
              AND d.status = 'sent' AND NOT d.is_test AND coalesce(d.reason, '') NOT LIKE 'attachment:manifest_images%'));
  IF n = 0 THEN RAISE EXCEPTION 'VERIFY: the candidates join saw no sent pair (an empty check proves nothing)'; END IF;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: candidates says sent, the view does not: %', bad; END IF;
  --    b. a visit this view calls sent: the sweep calls at least one of its pairs sent
  SELECT array_agg(st3.visit_id ORDER BY st3.visit_id) INTO bad
    FROM public.v_visit_city_email_state st3
   WHERE st3.state = 'sent'
     AND NOT EXISTS (SELECT 1 FROM derm.v_city_email_candidates c
                      WHERE c.manifest_id = ANY (st3.manifest_ids) AND c.client_id = st3.client_id
                        AND c.status IN ('already_sent', 'suppressed_manual'));
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: the view says sent, candidates does not: %', bad; END IF;

  -- 6. live: exactly the keys city + photos, the city list is exactly the view's needs_city_email in scope, and the
  --    whole output equals the 11:20 output
  w := (SELECT pg_temp.cse_fixture('live'))->'fn';
  IF (SELECT array_agg(x ORDER BY x) FROM jsonb_object_keys(w) x) IS DISTINCT FROM ARRAY['city', 'photos'] THEN
    RAISE EXCEPTION 'VERIFY: output keys are %, must be exactly city and photos', (SELECT array_agg(x) FROM jsonb_object_keys(w) x); END IF;
  IF jsonb_typeof(w->'city') <> 'array' OR jsonb_typeof(w->'photos'->'count') <> 'number' THEN
    RAISE EXCEPTION 'VERIFY: output shape %', w; END IF;
  IF (SELECT array_agg((e->>'visit_id')::bigint ORDER BY (e->>'visit_id')::bigint) FROM jsonb_array_elements(w->'city') e)
     IS DISTINCT FROM (SELECT array_agg(visit_id ORDER BY visit_id) FROM public.v_visit_city_email_state
                        WHERE state = 'needs_city_email' AND visit_date >= DATE '2026-09-15'
                          AND NOT public.fn_is_non_customer(client_id, ARRAY['test', 'fixture'])) THEN
    RAISE EXCEPTION 'VERIFY: the city list is not the view'; END IF;
  IF w IS DISTINCT FROM (SELECT r->'fn' FROM _cse_old WHERE k = 'live') THEN
    RAISE EXCEPTION 'VERIFY: live output moved: old % new %', (SELECT r->'fn' FROM _cse_old WHERE k = 'live'), w; END IF;

  -- 7. the fixtures: the city list equals the 11:20 body's on every one except the intended difference, and the view
  --    reads what each one means
  FOR fk, o IN SELECT x.k, x.r FROM _cse_old x WHERE x.k <> 'live' ORDER BY x.k LOOP
    w := pg_temp.cse_fixture(fk);
    IF (SELECT array_agg(x ORDER BY x) FROM jsonb_object_keys(w->'fn') x) IS DISTINCT FROM ARRAY['city', 'photos'] THEN
      RAISE EXCEPTION 'VERIFY: % output keys %', fk, (SELECT array_agg(x) FROM jsonb_object_keys(w->'fn') x); END IF;
    IF fk = ANY (intended) THEN
      IF (w->'fn'->'city') = (o->'fn'->'city') THEN RAISE EXCEPTION 'VERIFY: % should differ from the 11:20 body', fk; END IF;
    ELSIF (w->'fn'->'city') IS DISTINCT FROM (o->'fn'->'city') THEN
      RAISE EXCEPTION 'VERIFY: % city list moved: old % new %', fk, o->'fn'->'city', w->'fn'->'city';
    END IF;
    IF (CASE fk
      WHEN 'm1_dt_send_failed' THEN w#>>'{st,6218,state}' = 'needs_city_email' AND w->'fn'->'city' @> '[{"visit_id": 6218}]'
      WHEN 'm2_ar_without_manifest' THEN w#>>'{st,6275,state}' = 'report_sent_manifest_follows' AND NOT w->'fn'->'city' @> '[{"visit_id": 6275}]'
      WHEN 'm3_ar_null_after_doc' THEN w#>>'{st,6275,state}' = 'sent' AND w#>>'{st,6275,sent_via}' = 'admin_review'
      WHEN 'm4_ar_null_before_doc' THEN w#>>'{st,6275,state}' = 'report_sent_manifest_follows'
      WHEN 'm5_send_on_deleted_manifest' THEN w#>'{st,6279,dt_sent_at}' = 'null'::jsonb AND w#>>'{st,6279,state}' <> 'sent'
                                             AND w#>>'{st,6218,state}' = 'needs_city_email' AND w->'fn'->'city' @> '[{"visit_id": 6218}]'
      WHEN 'm6_ar_on_non_derm' THEN w#>>'{st,8575,state}' = 'report_sent_manifest_follows'
      WHEN 'm7_no_actor_after_go_live' THEN w#>>'{st,6218,state}' = 'sent' AND w#>>'{st,6218,sent_via}' = 'automatic'
      WHEN 'm7b_no_actor_before_go_live' THEN w#>>'{st,6218,state}' = 'sent' AND w#>>'{st,6218,sent_via}' = 'derm_tracker'
      WHEN 'm8_nothing_attached' THEN w#>>'{st,6218,state}' = 'needs_city_email' AND w->'fn'->'city' @> '[{"visit_id": 6218}]'
                                      AND NOT o->'fn'->'city' @> '[{"visit_id": 6218}]'
      WHEN 'm9_test_client' THEN w#>>'{st,8113,state}' = 'needs_city_email' AND NOT w->'fn'->'city' @> '[{"visit_id": 8113}]'
      WHEN 'm10_go_live_day_send_failed' THEN w#>>'{st,6275,state}' = 'needs_city_email' AND w->'fn'->'city' @> '[{"visit_id": 6275}]'
                                              AND jsonb_array_length(w->'fn'->'city')
                                                  = 1 + jsonb_array_length((SELECT r->'fn'->'city' FROM _cse_old WHERE k = 'live'))
      WHEN 'm11_second_later_ar_send' THEN w#>>'{st,6275,state}' = 'sent' AND w#>>'{st,6275,sent_via}' = 'admin_review'
                                           AND (w#>>'{st,6275,city_email_sent_at}')::timestamptz
                                               = (SELECT sent_at FROM public.visit_photo_email_sends WHERE id = 187)
      ELSE false
    END) IS NOT TRUE THEN
      RAISE EXCEPTION 'VERIFY: fixture % read %', fk, w->'st';
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM _cse_old WHERE k <> 'live') <> 12 THEN RAISE EXCEPTION 'VERIFY: fixtures did not all run'; END IF;

  -- 8. nothing the fixtures touched leaked out of their subtransactions
  IF EXISTS (SELECT 1 FROM _cse_rows x
              WHERE x.h IS DISTINCT FROM CASE
                WHEN x.k LIKE 'des:%' THEN (SELECT md5(to_jsonb(s)::text) FROM public.derm_email_sends s WHERE 'des:' || s.id = x.k)
                ELSE (SELECT md5(to_jsonb(s)::text) FROM public.visit_photo_email_sends s WHERE 'vpes:' || s.id = x.k) END)
     OR (SELECT count(*) FROM _cse_rows) <> 5 THEN
    RAISE EXCEPTION 'VERIFY: a fixture leaked'; END IF;

  -- 9. invariants over every live visit, for the state lines no control above reaches. Each must also see rows.
  --    a. not completed <=> not_completed
  SELECT count(*) FILTER (WHERE visit_status IS DISTINCT FROM 'completed'),
         array_agg(visit_id ORDER BY visit_id) FILTER (WHERE (visit_status IS DISTINCT FROM 'completed') <> (state = 'not_completed'))
    INTO n, bad FROM public.v_visit_city_email_state;
  IF n = 0 OR bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: not_completed wrong (% not completed): %', n, bad[1:10]; END IF;
  --    b. a grey water visit reads not_for_city or a state above it, and not_for_city means grey water
  SELECT count(*) FILTER (WHERE state = 'not_for_city'),
         array_agg(visit_id ORDER BY visit_id) FILTER (WHERE
           (not_for_city AND state NOT IN ('not_completed', 'sent', 'report_sent_manifest_follows', 'not_derm', 'not_for_city'))
           OR (state = 'not_for_city' AND NOT not_for_city))
    INTO n, bad FROM public.v_visit_city_email_state;
  IF n = 0 OR bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: not_for_city wrong (% read it): %', n, bad[1:10]; END IF;
  --    c. before go-live nothing is due (Fred, 2026-10-12): no visit dated before 2026-09-15 reads waiting_manifest or
  --       needs_city_email, and before_go_live means exactly "old, and none of the states above it"
  SELECT count(*) FILTER (WHERE state = 'before_go_live'),
         array_agg(visit_id ORDER BY visit_id) FILTER (WHERE
           (visit_date < DATE '2026-09-15' AND state IN ('waiting_manifest', 'needs_city_email'))
           OR (state = 'before_go_live' AND NOT (visit_date < DATE '2026-09-15' AND visit_status = 'completed'
                 AND city_email_sent_at IS NULL AND ar_sent_at IS NULL AND derm_required IS NOT FALSE
                 AND NOT not_for_city AND city_email_on_file)))
    INTO n, bad FROM public.v_visit_city_email_state;
  IF n = 0 OR bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: before_go_live wrong (% read it): %', n, bad[1:10]; END IF;

  RAISE NOTICE 'VERIFY ok: city % visits, photos %', jsonb_array_length((SELECT r FROM _cse_old WHERE k = 'live')->'fn'->'city'),
    (SELECT r FROM _cse_old WHERE k = 'live')->'fn'->'photos';
END $verify$;

DROP FUNCTION pg_temp.cse_fixture(text);
NOTIFY pgrst, 'reload schema';

COMMIT;

-- read-only receipt (the Management API returns the last result)
SELECT jsonb_build_object(
  'applied', to_regclass('public.v_visit_city_email_state') IS NOT NULL,
  'fn_md5', md5(pg_get_functiondef('public.fn_admin_review_pending()'::regprocedure)),
  'relacl', (SELECT relacl::text FROM pg_class WHERE oid = 'public.v_visit_city_email_state'::regclass),
  'output', public.fn_admin_review_pending()) AS receipt;
