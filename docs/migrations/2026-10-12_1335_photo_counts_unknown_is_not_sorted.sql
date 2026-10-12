-- ============================================================================
-- 2026-10-12_1335 Photos: an 'unknown' classification is NOT sorted (public.v_visit_photo_counts)
-- ============================================================================
-- THE ASK
--   The 2026-10-12 notification audit, after the 11 AM "Admin Review: photos and city emails" post: "Untagged photos
--   saved as 'unknown' count as sorted in v_visit_photo_counts (Slack line, queue chip, city list, send gate) but
--   show as untagged on the review page: 32 visits / 62 photos hidden from the count." The critic: "The fix has to
--   change the view and the gate together."
--   Decision for this cycle: v_visit_photo_counts counts 'unknown' as NOT sorted (as the review page does), and the
--   send-visit-photos-email gate READS this view instead of keeping its own copy of the rule.
--
-- WHAT WAS WRONG (measured 2026-10-12 13:05 ET)
--   When a reviewer presses Confirm with photos left untagged, Admin Review saves service_phase = 'unknown' for each
--   of them (that is also how a removed tag gets cleared). The review page shows those as untagged, the Field Portal
--   (customer.wo_photos) and the city attachment show only real phases, but this view set is_classified = "a row
--   exists", so 'unknown' counted as sorted: 63 photos on 33 visits at 13:26 ET. Example: 8013
--   (168-AVA) reads 16 of 16 sorted with all 16 'unknown'.
--
-- WHAT CHANGES (body copied from pg_get_viewdef, md5 pinned; diff = ONE line)
--   is_classified = the phase is one of the 4 a reviewer can pick (before, after, internal, extra), the same 4 the
--   review page and the attachment use. COALESCE keeps a photo with no row at false (without it the 'late' count
--   would lose those photos). Same columns, same rows, same grants.
--   send-visit-photos-email changes in the same cycle to read this view (it counted rows itself); deploy it right
--   after this file. Until then the app's pre-check (which reads this view) is stricter than the server, which is
--   the safe direction.
--
-- EFFECT, per reader (measured with this body as a TEMP view, in a rolled-back transaction)
--   Measured 13:26 ET. Reviewers were sorting at the time (the chip read 106 at 12:22 and 84 at 13:26), so the
--   absolute numbers move; the 33 visits that change are the visits holding an 'unknown' tag, and nothing else moves.
--   - The view: 1234 rows before and after, total_images and Reopened unchanged on every visit, classified_images
--     falls on exactly the 33 visits with an 'unknown' tag (by the 63 tags), on no other visit.
--   - Admin Review queue chip "N photos unclassified" and the "Photos Not Sorted" filter: 84 -> 117 visits (the 33,
--     all review_status pending), 742 -> 805 unsorted photos. No visit loses its chip; no existing chip changes number.
--   - Admin Review "Send email to City" pre-check (reads total_images / classified_images): the 33 now get "N of the M
--     photos haven't been classified yet" when "Send email with photos" is ticked.
--   - fn_admin_review_pending (the 11 AM Slack post): photos 84 -> 117, last 7 days 21 -> 21, oldest Jul 27 -> Jul 3
--     (6710); 46 of the 117 are DERM-required. City list: unchanged (empty today, identical before and after). Of the 33,
--     the 3 with a city inbox (6217, 6252, 6350) are dated before 2026-09-15, outside its window.
--   - v_derm_manifest_email_readiness (DERM Tracker "Send to city" dialog): classified_images moves on 24 of 838
--     manifests; has_classified_photos turns false on 1 (manifest 1843, white 834986, visit 8013, never sent to the
--     city), which the dialog then marks "Photos not classified" and refuses with photos ticked. send_blocker: 0 moves.
--   - send-visit-photos-email gate (after its deploy, it reads this view): 33 visits go from allowed to not_classified
--     (409) when photos are included. 24 are DERM-required; 3 have a city inbox (6217, 6252, 6350, all before
--     2026-09-15), 2 are not for the city (6503, 6710), 0 were ever sent. 0 of them are a city email due since go-live.
--   - Applied BEFORE this file in the 2026-10-12 order (1305 city-state, 1310 and 1315 edge-fns, 1400 health, then
--     1330 and this file): 1305 rewrites fn_admin_review_pending and 1400 adds fn_notification_health_items /
--     log_notification_health(); both read this view, so they take the same rule with no copy of it.
--     v_visit_city_email_state (1305) does not read it. Re-measured 14:22 ET with 1305's photos rule (the same
--     queue, test and fixture clients left out): 65 -> 98 visits, the same +33 (0 of the 33 are test clients), last 7
--     days 21 -> 21, oldest Jul 27 -> Jul 3; city list unchanged. Health: 0 items move (no 'unknown' visit is a city
--     email due since go-live; 4 of the 33 are dated since 2026-09-15 and none of them has a city inbox to send to).
--   - Nothing else reads it: pg_depend finds only v_derm_manifest_email_readiness, pg_proc only fn_admin_review_pending,
--     0 edge functions before this cycle, and of the 11 live app bundles crawled only Admin Review names it.
--
-- HOW TO RUN: three parts, each its own transaction, sent as TWO calls in order. Never send the whole file at once:
--   a body containing COMMIT is not atomic, so PART C goes on its own and its error is its own.
--   Call 1 = PART A + PART B.
--     PART A  proves the new body on a TEMP copy, then ROLLBACK. No lock on the live view. An error here stops the
--             call before PART B, so nothing changes.
--     PART B  the DDL and catalog-only checks, then COMMIT. CREATE OR REPLACE VIEW takes ACCESS EXCLUSIVE on a view
--             an app reads (Admin Review, DERM Tracker), so nothing heavy runs inside it (Supabase CLAUDE.md, "DDL ON
--             A VIEW AN APP READS"). lock_timeout 3 s: if it times out (the backup dump runs at HH:17 UTC on even
--             hours), send call 1 again.
--   Call 2 = PART C, read-only: the committed view against a raw count of the same photos, in one statement (one
--             snapshot, so a reviewer sorting at that moment cannot fail it). If it fails, put the old body back
--             (ROLLBACK below).
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): a view change, no table. photo_classifications stays audited
--   (audit_photo_classifications). The 'unknown' rows are left as they are (the view now reads them right, and
--   Confirm must keep writing them: skipping untagged photos would leave a removed tag in place).
-- GRANTS: CREATE OR REPLACE VIEW keeps the ACL; PART B compares relacl before and after, keeps reloptions NULL
--   (owner-rights, as before), and asserts anon cannot read it while authenticated (Admin Review) and service_role
--   (send-visit-photos-email) can.
-- ROLLBACK: CREATE OR REPLACE VIEW public.v_visit_photo_counts with the vpc_old body of PART A (md5
--   47b46112548f53e4c7aff95c7baf8c3a) and put back its previous COMMENT (the one that begins "Per-visit image counts using the SAME
--   predicate as send-visit-photos-email"), under lock_timeout 3 s, then redeploy the previous
--   send-visit-photos-email (git revert of its commit). The previous gate counted 'unknown' as sorted again, so
--   revert both or neither.
-- ============================================================================

-- PART A (no lock on the live view): the new body as a TEMP view, proven against the live one, then rolled back
BEGIN;
SET LOCAL lock_timeout = '3s';
CREATE TEMP VIEW vpc_old AS
WITH links AS (
         SELECT l.entity_id AS visit_id,
            l.created_at AS arrived_at,
            c.created_at AS classified_at,
            (p.content_type ~~ 'image/%'::text) AS is_image,
            (c.photo_link_id IS NOT NULL) AS is_classified
           FROM ((photo_links l
             JOIN photos p ON ((p.id = l.photo_id)))
             LEFT JOIN photo_classifications c ON ((c.photo_link_id = l.id)))
          WHERE ((l.entity_type = 'visit'::text) AND (l.deleted_at IS NULL))
        ), agg AS (
         SELECT links.visit_id,
            count(*) FILTER (WHERE links.is_image) AS total_images,
            count(*) FILTER (WHERE (links.is_image AND links.is_classified)) AS classified_images,
            max(links.classified_at) FILTER (WHERE links.is_image) AS last_classified_at,
            max(links.arrived_at) FILTER (WHERE links.is_image) AS last_image_at
           FROM links
          GROUP BY links.visit_id
        ), late AS (
         SELECT l.visit_id,
            count(*) AS late_unclassified_images
           FROM (links l
             JOIN agg a_1 ON ((a_1.visit_id = l.visit_id)))
          WHERE (l.is_image AND (NOT l.is_classified) AND (a_1.last_classified_at IS NOT NULL) AND (l.arrived_at > a_1.last_classified_at))
          GROUP BY l.visit_id
        )
 SELECT a.visit_id,
    a.total_images,
    a.classified_images,
    a.last_classified_at,
    a.last_image_at,
    COALESCE(lt.late_unclassified_images, (0)::bigint) AS late_unclassified_images,
    (COALESCE(lt.late_unclassified_images, (0)::bigint) > 0) AS is_reopened
   FROM (agg a
     LEFT JOIN late lt ON ((lt.visit_id = a.visit_id)));
CREATE TEMP VIEW vpc_new AS
WITH links AS (
         SELECT l.entity_id AS visit_id,
            l.created_at AS arrived_at,
            c.created_at AS classified_at,
            (p.content_type ~~ 'image/%'::text) AS is_image,
            COALESCE((c.service_phase = ANY (ARRAY['before'::text, 'after'::text, 'internal'::text, 'extra'::text])), false) AS is_classified
           FROM ((photo_links l
             JOIN photos p ON ((p.id = l.photo_id)))
             LEFT JOIN photo_classifications c ON ((c.photo_link_id = l.id)))
          WHERE ((l.entity_type = 'visit'::text) AND (l.deleted_at IS NULL))
        ), agg AS (
         SELECT links.visit_id,
            count(*) FILTER (WHERE links.is_image) AS total_images,
            count(*) FILTER (WHERE (links.is_image AND links.is_classified)) AS classified_images,
            max(links.classified_at) FILTER (WHERE links.is_image) AS last_classified_at,
            max(links.arrived_at) FILTER (WHERE links.is_image) AS last_image_at
           FROM links
          GROUP BY links.visit_id
        ), late AS (
         SELECT l.visit_id,
            count(*) AS late_unclassified_images
           FROM (links l
             JOIN agg a_1 ON ((a_1.visit_id = l.visit_id)))
          WHERE (l.is_image AND (NOT l.is_classified) AND (a_1.last_classified_at IS NOT NULL) AND (l.arrived_at > a_1.last_classified_at))
          GROUP BY l.visit_id
        )
 SELECT a.visit_id,
    a.total_images,
    a.classified_images,
    a.last_classified_at,
    a.last_image_at,
    COALESCE(lt.late_unclassified_images, (0)::bigint) AS late_unclassified_images,
    (COALESCE(lt.late_unclassified_images, (0)::bigint) > 0) AS is_reopened
   FROM (agg a
     LEFT JOIN late lt ON ((lt.visit_id = a.visit_id)));

DO $pre$
DECLARE
  v_unknown int; v_drop bigint; v_outside int; v_tot int; v_reo int; v_rows_o int; v_rows_n int;
  v_link bigint; v_visit bigint; v_before int; v_after int; v_arrived timestamptz;
BEGIN
  IF md5(pg_get_viewdef('public.v_visit_photo_counts'::regclass)) <> '47b46112548f53e4c7aff95c7baf8c3a' THEN
    RAISE EXCEPTION 'A: v_visit_photo_counts moved since 2026-10-12 13:05 ET: copy the live body again'; END IF;
  IF md5(pg_get_viewdef('pg_temp.vpc_old'::regclass)) <> '47b46112548f53e4c7aff95c7baf8c3a' THEN
    RAISE EXCEPTION 'A control: the TEMP copy of the old body does not match the live view, so the md5 method is not proven'; END IF;
  IF md5(pg_get_viewdef('pg_temp.vpc_new'::regclass)) <> '1ea4dddc38859a4e95dd7a2c7b5c72f3' THEN
    RAISE EXCEPTION 'A: the new body does not render to the md5 PART B expects'; END IF;

  -- one statement, so the unknown count and the drop come from the same snapshot while reviewers sort
  SELECT (SELECT count(*) FROM public.photo_links l JOIN public.photos p ON p.id = l.photo_id
            JOIN public.photo_classifications c ON c.photo_link_id = l.id
           WHERE l.entity_type = 'visit' AND l.deleted_at IS NULL AND p.content_type LIKE 'image/%' AND c.service_phase = 'unknown'),
         count(*), sum(o.classified_images - n.classified_images),
         count(*) FILTER (WHERE o.classified_images <> n.classified_images AND NOT EXISTS (
           SELECT 1 FROM public.photo_links l JOIN public.photo_classifications c ON c.photo_link_id = l.id
            WHERE l.entity_type = 'visit' AND l.entity_id = o.visit_id AND l.deleted_at IS NULL AND c.service_phase = 'unknown')),
         count(*) FILTER (WHERE o.total_images <> n.total_images),
         count(*) FILTER (WHERE o.is_reopened <> n.is_reopened OR o.late_unclassified_images <> n.late_unclassified_images)
    INTO v_unknown, v_rows_o, v_drop, v_outside, v_tot, v_reo
    FROM pg_temp.vpc_old o JOIN pg_temp.vpc_new n USING (visit_id);
  SELECT count(*) INTO v_rows_n FROM pg_temp.vpc_new;
  -- (0 unknown rows would make the numbers above vacuous; the mutation control below still proves the rule)
  IF v_drop <> v_unknown THEN RAISE EXCEPTION 'A: classified fell by %, expected the % unknown rows', v_drop, v_unknown; END IF;
  IF v_outside <> 0 THEN RAISE EXCEPTION 'A: % visits without an unknown row changed', v_outside; END IF;
  IF v_tot <> 0 OR v_rows_o <> v_rows_n THEN RAISE EXCEPTION 'A: totals or row count moved (% / % vs %)', v_tot, v_rows_o, v_rows_n; END IF;
  IF v_reo <> 0 THEN RAISE EXCEPTION 'A: % visits changed Reopened state: look before applying', v_reo; END IF;

  -- mutation control, in a subtransaction that undoes itself: turn one real tag into 'unknown'; the new body must
  -- drop it from the sorted count, the old body must not. A quiet row: tagged more than a day ago, on a visit that
  -- got no photo in the last day, so a reviewer sorting right now is not on it.
  SELECT c.photo_link_id, l.entity_id INTO v_link, v_visit FROM public.photo_classifications c
    JOIN public.photo_links l ON l.id = c.photo_link_id JOIN public.photos p ON p.id = l.photo_id
   WHERE l.entity_type = 'visit' AND l.deleted_at IS NULL AND p.content_type LIKE 'image/%' AND c.service_phase = 'before'
     AND coalesce(c.updated_at, c.created_at) < now() - interval '1 day'
     AND NOT EXISTS (SELECT 1 FROM public.photo_links l2 WHERE l2.entity_type = 'visit' AND l2.entity_id = l.entity_id
                      AND l2.created_at > now() - interval '1 day')
   ORDER BY c.photo_link_id DESC LIMIT 1;
  IF v_link IS NULL THEN RAISE EXCEPTION 'A control: no quiet before tag to test with'; END IF;
  BEGIN
    SELECT classified_images INTO v_before FROM pg_temp.vpc_new WHERE visit_id = v_visit;
    UPDATE public.photo_classifications SET service_phase = 'unknown' WHERE photo_link_id = v_link;
    SELECT classified_images INTO v_after FROM pg_temp.vpc_new WHERE visit_id = v_visit;
    IF v_after <> v_before - 1 THEN RAISE EXCEPTION 'A: an unknown tag still counts as sorted (% -> %)', v_before, v_after; END IF;
    IF (SELECT classified_images FROM pg_temp.vpc_old WHERE visit_id = v_visit) <> v_before THEN
      RAISE EXCEPTION 'A control: the old body should still count it'; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'verify-undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'verify-undo' THEN RAISE; END IF;
  END;

  -- mutation control 2, undone: a photo that arrives after the last classification must still read as late (the
  -- Reopened chip), as it does today. No visit is Reopened right now, so the row checks above cannot see this; without
  -- the COALESCE a photo with no row would read as NULL and drop out of 'late'.
  SELECT l.entity_id INTO v_visit FROM public.photo_links l JOIN public.photos p ON p.id = l.photo_id
    JOIN public.photo_classifications c ON c.photo_link_id = l.id
   WHERE l.entity_type = 'visit' AND l.deleted_at IS NULL AND p.content_type LIKE 'image/%'
   GROUP BY l.entity_id HAVING count(*) >= 2
   ORDER BY max(l.id) DESC LIMIT 1;
  SELECT l.id, l.created_at INTO v_link, v_arrived FROM public.photo_links l JOIN public.photos p ON p.id = l.photo_id
   WHERE l.entity_type = 'visit' AND l.entity_id = v_visit AND l.deleted_at IS NULL AND p.content_type LIKE 'image/%'
   ORDER BY l.created_at DESC, l.id DESC LIMIT 1;
  BEGIN
    DELETE FROM public.photo_classifications WHERE photo_link_id = v_link;
    UPDATE public.photo_classifications c SET created_at = v_arrived - interval '1 minute'
      FROM public.photo_links l WHERE l.id = c.photo_link_id AND l.entity_type = 'visit' AND l.entity_id = v_visit;
    SELECT late_unclassified_images INTO v_before FROM pg_temp.vpc_old WHERE visit_id = v_visit;
    SELECT late_unclassified_images INTO v_after FROM pg_temp.vpc_new WHERE visit_id = v_visit;
    IF v_before < 1 THEN RAISE EXCEPTION 'A control 2: the setup did not make a late photo on visit %', v_visit; END IF;
    IF v_after IS DISTINCT FROM v_before THEN
      RAISE EXCEPTION 'A: a photo that arrived after the last classification is no longer late (% -> %)', v_before, v_after; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'verify-undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'verify-undo' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'A passed: % unknown rows now unsorted, nothing else moved', v_unknown;
END $pre$;
ROLLBACK;

-- PART B: the DDL, with catalog-only checks, in a short transaction
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $pin$
BEGIN
  IF md5(pg_get_viewdef('public.v_visit_photo_counts'::regclass)) <> '47b46112548f53e4c7aff95c7baf8c3a' THEN
    RAISE EXCEPTION 'B: v_visit_photo_counts moved since 2026-10-12 13:05 ET: copy the live body again'; END IF;
END $pin$;
CREATE TEMP TABLE _vpc_acl ON COMMIT DROP AS
  SELECT relacl::text AS acl FROM pg_class WHERE oid = 'public.v_visit_photo_counts'::regclass;

CREATE OR REPLACE VIEW public.v_visit_photo_counts AS
WITH links AS (
         SELECT l.entity_id AS visit_id,
            l.created_at AS arrived_at,
            c.created_at AS classified_at,
            (p.content_type ~~ 'image/%'::text) AS is_image,
            COALESCE((c.service_phase = ANY (ARRAY['before'::text, 'after'::text, 'internal'::text, 'extra'::text])), false) AS is_classified
           FROM ((photo_links l
             JOIN photos p ON ((p.id = l.photo_id)))
             LEFT JOIN photo_classifications c ON ((c.photo_link_id = l.id)))
          WHERE ((l.entity_type = 'visit'::text) AND (l.deleted_at IS NULL))
        ), agg AS (
         SELECT links.visit_id,
            count(*) FILTER (WHERE links.is_image) AS total_images,
            count(*) FILTER (WHERE (links.is_image AND links.is_classified)) AS classified_images,
            max(links.classified_at) FILTER (WHERE links.is_image) AS last_classified_at,
            max(links.arrived_at) FILTER (WHERE links.is_image) AS last_image_at
           FROM links
          GROUP BY links.visit_id
        ), late AS (
         SELECT l.visit_id,
            count(*) AS late_unclassified_images
           FROM (links l
             JOIN agg a_1 ON ((a_1.visit_id = l.visit_id)))
          WHERE (l.is_image AND (NOT l.is_classified) AND (a_1.last_classified_at IS NOT NULL) AND (l.arrived_at > a_1.last_classified_at))
          GROUP BY l.visit_id
        )
 SELECT a.visit_id,
    a.total_images,
    a.classified_images,
    a.last_classified_at,
    a.last_image_at,
    COALESCE(lt.late_unclassified_images, (0)::bigint) AS late_unclassified_images,
    (COALESCE(lt.late_unclassified_images, (0)::bigint) > 0) AS is_reopened
   FROM (agg a
     LEFT JOIN late lt ON ((lt.visit_id = a.visit_id)));
COMMENT ON VIEW public.v_visit_photo_counts IS 'Per-visit image counts. A photo counts as sorted only when its phase is before, after, internal or extra: ''unknown'', which Admin Review saves for a photo left untagged at Confirm, is NOT sorted (2026-10-12_1335). send-visit-photos-email reads this view for its not_classified gate, and the Admin Review queue and its send pre-check read it too, so they cannot disagree. is_reopened = an unclassified image arrived AFTER the most recent classification (defect D2). Not the same as partially classified, which is an abandoned half-done job.';

DO $verify$
BEGIN
  IF position('''unknown''' in coalesce(obj_description('public.v_visit_photo_counts'::regclass, 'pg_class'), '')) = 0 THEN
    RAISE EXCEPTION 'B: the view comment still describes the old rule'; END IF;
  -- the live view is now exactly the body PART A proved (same pg_get_viewdef md5)
  IF md5(pg_get_viewdef('public.v_visit_photo_counts'::regclass)) <> '1ea4dddc38859a4e95dd7a2c7b5c72f3' THEN
    RAISE EXCEPTION 'B: the live view is not the proven body'; END IF;
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'public.v_visit_photo_counts'::regclass) IS DISTINCT FROM (SELECT acl FROM _vpc_acl) THEN
    RAISE EXCEPTION 'B: grants changed'; END IF;
  IF (SELECT reloptions FROM pg_class WHERE oid = 'public.v_visit_photo_counts'::regclass) IS NOT NULL THEN
    RAISE EXCEPTION 'B: reloptions changed (it must stay an owner-rights view)'; END IF;
  IF has_table_privilege('anon', 'public.v_visit_photo_counts', 'SELECT') THEN
    RAISE EXCEPTION 'B: anon can read the view'; END IF;
  IF NOT has_table_privilege('authenticated', 'public.v_visit_photo_counts', 'SELECT')
  OR NOT has_table_privilege('service_role', 'public.v_visit_photo_counts', 'SELECT') THEN
    RAISE EXCEPTION 'B: Admin Review (authenticated) or send-visit-photos-email (service_role) lost SELECT'; END IF;
END $verify$;
COMMIT;

-- PART C (call 2, after the commit, read-only): the committed view against a raw count of the same photos. The
-- rule itself was proven by PART A's mutation control on the same body (PART B checked the live md5 equals it).
DO $post$
DECLARE v_bad int; v_unknown_visits int; v_shown int;
BEGIN
  WITH raw AS (
    SELECT l.entity_id AS visit_id,
           count(*) FILTER (WHERE p.content_type LIKE 'image/%') AS t,
           count(*) FILTER (WHERE p.content_type LIKE 'image/%' AND c.service_phase IN ('before','after','internal','extra')) AS s
      FROM public.photo_links l JOIN public.photos p ON p.id = l.photo_id
      LEFT JOIN public.photo_classifications c ON c.photo_link_id = l.id
     WHERE l.entity_type = 'visit' AND l.deleted_at IS NULL
     GROUP BY 1)
  SELECT count(*) INTO v_bad FROM raw r FULL JOIN public.v_visit_photo_counts pc USING (visit_id)
   WHERE pc.visit_id IS NULL OR r.visit_id IS NULL OR pc.total_images <> r.t OR pc.classified_images <> r.s;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'C: % visits where the view disagrees with the raw count: run the rollback', v_bad; END IF;
  -- positive control: every visit holding an 'unknown' image tag now shows at least that many photos not sorted
  SELECT count(*), count(*) FILTER (WHERE pc.total_images - pc.classified_images >= u.n) INTO v_unknown_visits, v_shown
    FROM (SELECT l.entity_id AS visit_id, count(*) AS n FROM public.photo_links l JOIN public.photos p ON p.id = l.photo_id
            JOIN public.photo_classifications c ON c.photo_link_id = l.id
           WHERE l.entity_type = 'visit' AND l.deleted_at IS NULL AND p.content_type LIKE 'image/%' AND c.service_phase = 'unknown'
           GROUP BY 1) u
    JOIN public.v_visit_photo_counts pc USING (visit_id);
  IF v_shown <> v_unknown_visits THEN RAISE EXCEPTION 'C: % of % visits with unknown tags still count them as sorted: run the rollback', v_unknown_visits - v_shown, v_unknown_visits; END IF;
  RAISE NOTICE 'C passed: % visits with unknown tags show them as not sorted', v_unknown_visits;
END $post$;
