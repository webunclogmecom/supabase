-- ============================================================================
-- 2026-10-12_1600 Lift station pumping (line items 04 and 11) is no longer DERM required; the manifest is
--                 optional, and the client keeps seeing the visit in the Field Portal
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-12: "LS do not need DERM, it's optional." and, asked whether lift station visits should stay
--   in the client's Field Portal: "LS keep them visible". Lift station = catalogue 04 ("04 - Service Agreement -
--   Pumping - Lift Station & Tank Cleaning") and 11 ("11 - Service Call - Pumping - Lift Station & Tank
--   Cleaning"), plus free-text lift station pumping lines. Precedent: grey water, 2026-09-24 (_1220, _1353,
--   _1600, _1615, _1920, _2110). This file mirrors that design; where it differs, the reason is stated.
--
-- WHAT CHANGES
--   1. public.service_line_items: requires_derm = false for 04 and 11 (catalogue Pumping + 'Lift Station & Tank
--      Cleaning', asserted to be exactly {04, 11}). The DERM-required set becomes {01, 02, 09}. The catalogue is
--      the one source: fn_line_item_requires_derm, the Calendar's DERM badge (ops.service_line_items,
--      ops.service_options, ops.client_service_options, ops.v_visit_requests) and the Client App's
--      client.service_line_items all read it.
--   2. NEW public.fn_line_item_is_free_text_lift_station(text): IMMUTABLE, pure. An EXACT-PHRASE allowlist anchored
--      at both ends (like fn_line_item_is_free_text_grey_water): the WHOLE line must be lift station pumping
--      ("Lyft station cleaning and Pump out", "Lift station pump out and cleaning", "Lift station tank pump out",
--      "Lyft Station Pump out" are the 4 live names it matches). A MIXED line ("Grease Trap Pumping & Lift
--      Station Cleaning", "Grease Trap Pumping & Lift Station", "Lift station and grey water pumping") is NOT
--      matched and keeps its TRUE: it may be a grease trap too. A bare "Lyft station" / "Lift Station" (NULL
--      today, 16 rows) is not pumping by its words and stays NULL. "Lift station pump repair" / "pumps" (the
--      station's pump, not a pump-out) are not matched. Typos beyond Lyft ("Lif", "statin", "stations", a
--      trailing period) keep TRUE, the safe side. EXECUTE to PUBLIC: every reader of the classifier and of the
--      views below needs it (a function inside a view is checked against the CALLER), and it reads nothing.
--   3. public.fn_line_item_requires_derm: ONE arm (b1) spliced after (b0): such a line answers the catalogue's
--      lift station flag (bool_and over Pumping + 'Lift Station & Tank Cleaning', FALSE after part 1), so the
--      policy stays in the catalogue. Spliced from the live body (md5 pinned, anchor counted to once).
--      fn_visit_requires_derm is NOT changed: its fold (any TRUE -> TRUE) already keeps a visit that also has
--      grease trap pumping DERM required, and the fee/admin abstention (2026-09-24) already lets 04 + 25 fold to
--      FALSE.
--   4. NEW public.v_visit_lift_station_pumping (visit_id, tier): THE lift station rule, once. Shaped like
--      public.v_visit_grey_water_pumping (live visits; nearest tier decides: own lines 1, else job 2, else invoice
--      3; no status filter), with two differences, both from review 2026-10-12:
--        (a) a line counts as a service when it says something about DERM (fn_line_item_requires_derm not NULL),
--            coded or not: fee/admin codes and unknown free text abstain, an uncoded "Hydrojet Unclogging
--            Commercial" counts. Grey water counts only coded services and free-text grey water lines.
--        (b) the deciding tier must hold lift station pumping and NOTHING ELSE that needs DERM. Grey water's rule
--            admits a mixed tier (and v_visit_not_for_city adds this test on top of it).
--      Measured: the grey water shape would have shown the client 4 visits that are not lift station visits by
--      their own lines, all switched to "not required" by a person: 5844 (168-AVA, own 01 + 04), 7087 (186-PV,
--      own 02 + 04), 3890 and 3919 (274-CEV, own "Hydrojet Unclogging Commercial"; lift station only on the shared
--      invoice 1889). Grey water has 0 live visits of either shape, so its rule never decided these cases. The
--      tightening only removes rows (60 instead of 157; every removed row but those 4 is stored TRUE, so no
--      reader moves for it). V4 proves the body against an independent computation, with a live discriminator
--      for each branch.
--      ACL differs from grey water's on purpose: SELECT to service_role AND authenticated, because
--      public.manifest_pickable_visits is security_invoker=true and reads it as the caller (the DERM Tracker,
--      authenticated). authenticated already reads public.visits, line_items and service_line_items (asserted;
--      RLS on all three is USING (true) for authenticated), so the grant exposes nothing new. anon gets nothing.
--      Resulting ACL: {postgres=arwdDxtm, db_backup_reader=r, service_role=r, authenticated=r}; db_backup_reader
--      comes from the public schema default privileges, as on every sibling (v_visit_grey_water_pumping,
--      v_visit_not_for_city). The dry run's TEMP copy does not show it (TEMP objects get no default privileges).
--   5. customer.work_orders (Field Portal): the WHERE gains the lift station arm next to the grey water one:
--        COALESCE(derm_required, true) = true OR <grey water> OR <lift station>
--      Its derm_required column (FALSE only on an admitted not-required visit) already drives Field Portal rule 11
--      (DERM paperwork parts hidden on === false with no manifest number); no app change.
--   6. public.manifest_pickable_visits (DERM Tracker /upload matcher and "Adding a visit" picker; Stamp Studio
--      Add-client modal through derm.v_stamp_unlinked_visits): admits a completed, unlinked lift station visit
--      stored FALSE, so an OPTIONAL manifest can still be filed on it ("it's optional"). Filing one turns the visit
--      DERM required and locked (trg_zy_link_marks_derm_required, 2026-10-06_1240), so it then follows the normal
--      flow. Grey water does NOT get this arm (it left the picker on 2026-09-24 and nobody asked otherwise).
--      🛑 security_invoker=true is restated in the CREATE OR REPLACE: that statement REPLACES reloptions, and
--      dropping it would turn the picker into an owner-rights view (asserted both ways).
--      ⚠ The picker has no derm_required column, so the apps cannot tell an optional visit from a required one
--      (follow-up: a trailing column + a badge). A mis-pick turns that visit TRUE and locked.
--      ⚠ "Optional" is OFFICE-ONLY: dump_manifest_link / _mark / _handout_confirm all gate through
--      dump_outstanding_visits (part 7), so a driver cannot attach an optional manifest in the DUMP app.
--   7. public.dump_outstanding_visits (the DUMP app: crib-sheet 'load'/'outstanding', VIEW ADDRESSES 'pickable',
--      and the gate of dump_manifest_mark / _link / _handout_confirm) gains `vis.derm_required IS NOT FALSE`, so
--      the DUMP lists stay exactly what they are today (asserted set-equal, plus a 112-YA stored-NULL fixture that
--      tells IS NOT FALSE from IS TRUE): a not-required lift station pickup must not read as a pickup owing a
--      manifest (needs_office after 14 days). This is the same outcome grey water got by leaving the picker. Its
--      comment is corrected to say so.
--   8. Backfill (PART B2, its own transaction): PENDING visits only (scheduled, dated today or later in ET),
--      stored TRUE, NOT locked, now deriving FALSE. Completed visits are left alone ("leave the filed ones alone").
--
-- WHAT MOVES (measured 2026-10-12 16:57 to 17:40 ET, DB clock, in rolled-back runs; PART A re-asserts the shapes)
--   - Catalogue rows 04, 11 (and the Calendar DERM badge on those two services). Classifier: 8 live names move
--     TRUE -> FALSE (the 4 coded 04/11 titles, the 4 free-text names above); nothing else.
--   - The rule: 60 visits (39 completed, 21 scheduled). Of the 15 live jobs with a lift station line, 3 are lift
--     station only: 031-KRU job 1304, 013-DIM 1338, 057-BAY 1444 (031-KRU also has grease trap SA job 1722 and an
--     ACTIVE GDO-13141, so it is not a lift-station-only client); the other 12 also pump a grease trap.
--   - fn_visit_requires_derm: 60 visits TRUE -> FALSE, every one reaching a lift station line and no grease trap
--     pumping: 21 scheduled (all backfilled), 19 completed stored TRUE (18 filed, + 6576 013-DIM 2026-10-11 with
--     no manifest: LEFT TRUE, still in DERM Tracker Missing Docs: use the per-visit toggle), 20 completed stored
--     FALSE and locked by a person (they now agree with the derive). No other change of any kind (V2).
--     52 pending visits that reach lift station AND grease trap stay TRUE. 0 NULL -> FALSE (the nightly fill
--     writes nothing new). 0 TRUE -> NULL.
--   - Backfill: 21 visits, 031-KRU x8 (2026-10-29 .. 2027-05-27), 057-BAY x7 (2026-10-30 .. 2027-04-28),
--     013-DIM x6 (2026-11-10 .. 2027-04-09); all source supabase_cron, sync_state confirmed, no manifest.
--   - Field Portal: +19 completed lift station visits a person had switched to "not required" (013-DIM 1242,
--     6575; 031-KRU 5775, 6605, 6841, 6842, 6843; 053-PV 5734, 5736; 057-BAY 1344, 1352, 1498, 1507, 1514, 6629;
--     168-AVA 1355, 5144, 6989, 7840; dated 2026-01-03 .. 2026-09-30), shown without DERM paperwork, with 49
--     classified photos on 8 of them (6989 31, 6575 4, 6629 4, 7840 3, 6605 2, 6841 2, 6843 2, 6842 1). 6989's
--     own lines are lift station; its shared invoice 2135 bills a grease trap (it still derives TRUE), shown like grey water 7085.
--     Nothing leaves. Existing rows unchanged but visit_num: 30 renumber in the measured run (29 with a manifest):
--     057-BAY 9, 168-AVA 7, 013-DIM 6, 031-KRU 3, 053-PV 3 because an added visit sits before them in the same
--     client and year, and 225-PV 2 with no cause (row_number orders by visit_date only, so two work orders on one
--     date swap with the plan; the review run also saw 177-PV). Kept hidden (stored FALSE, reach a lift station
--     line, out of the rule): 3890, 3919, 5844, 7087 (above), and 6955, 8041, 8047 (168-AVA), 7822 (112-YA, the
--     test client), whose own lines are other services.
--   - Picker: +the same 19 (offerable for an optional manifest; also the Stamp Studio Add-client modal through
--     derm.v_stamp_unlinked_visits). DUMP lists: unchanged (V7; without the new filter they would gain those 19).
--   - DERM Tracker Missing Docs (completed, COALESCE(derm_required, true), no manifest): 11 -> 11; the only lift
--     station visit in it is 6576 (left TRUE, see below).
--   - Calendar: the DERM badge leaves services 04 and 11 (ops.service_line_items, ops.service_options); the 21
--     backfilled visits read derm_required false and keep service_label 'Pumping' (from their job's 04 line).
--   - SA generator (fn_generate_sa_visits, dry run): jobs 1304, 1338, 1444 now generate derm_required FALSE; the 12
--     mixed jobs TRUE; no lift station job has a new visit planned in the next 6 months. Calendar RPCs
--     (create_calendar_visit, edit_calendar_visit on a pending visit) write FALSE for a 04/11-only service list,
--     through the same classifier.
--   - LWT monthly filing: 18 of its 869 rows (Jan to Sep 2026, about 2 a month) were lift-station-only pickups;
--     new ones stop reaching it unless a manifest is filed (2026-10-12_1610 lists them). GDO portal queue: 0 lift-station-only
--     rows, and 0 portal submissions ever for those visits. Admin Review pending and the notification-health items
--     (2 duplicates, 6138, 6247): identical before and after.
--   - ops.v_derm_human_override_conflict 66 -> 46 (the 20 locked lift station visits now agree); never gains.
--   - customer.permits: 1 row: 057-BAY PSO-00025 (expired 2019-09-30) loses
--     "Every 30 days" (its job fallback looks for a DERM pumping line; the only one was 04). Accepted, listed.
--   - client.fn_client_has_derm_activity: 274-CEV TRUE -> FALSE (the Client App stops warning about a DERM
--     service report on its contact edit). Correct: it has no manifest and only lift station and hydrojet work.
--   - Unchanged (asserted): public.v_gdo_reporting_derm_mismatch (0 before and after; the 13 visits reaching a lift
--     station line and a 27 GDO Online Reporting line all still derive TRUE, so the rpa-derm-health
--     'gdo_code27_not_derm_required' counter cannot fire from this today; it would only if a visit-scoped 27 line
--     lands on a lift-station-only visit, i.e. on 031-KRU or 057-BAY), public.v_visit_not_for_city (97 rows),
--     the stored derm_required of every non-candidate, every sync_state, the pg_net queue (no Jobber push),
--     derm.v_lwt_monthly_rows, public.v_visit_city_email_state (none of the clients of the 3 lift-station-only jobs
--     has a city inbox; a not-required visit reads not_derm, a filed one follows the normal flow, D6), and
--     public.v_visit_grey_water_pumping (97 rows).
--
-- NOT CHANGED, on purpose, and what that means
--   - derm.visits (DERM Tracker list): its grey_water_pumping column drives the bulk "Hide these visits from the
--     client portal?" count. Lift station has no such column, so that dialog now OVERSTATES for a lift station
--     visit (it says hidden; it stays visible). Follow-up if wanted: a lift_station_pumping column + app change.
--   - dump_route_today: it already drops a visit stored FALSE ("DERM manifest reference: drop non-DERM"), so a
--     lift-station-only stop leaves the driver's VIEW ADDRESSES list once it is FALSE (the 21 backfilled visits,
--     about 3 a month), exactly as grey water did.
--   - The Miami-Dade LWT monthly filing (derm.v_lwt_monthly_rows) is built from manifest links, so a lift station
--     pickup with no (optional) manifest no longer reaches it. 2026-10-12_1610 lists them with grey water in ONE view,
--     derm.v_lwt_pickups_without_manifest (Fred: "yes put the LS in that list ... have better naming"); the drafted
--     separate 1605 view was never applied.
--   - v_visit_not_for_city (grey water never goes to the city) is unchanged (D6).
--   - 6576 (013-DIM, completed 2026-10-11, stored TRUE, no manifest): completed, so not backfilled.
--   - Readers that follow without a change: customer.get_work_order, get_client_portal, get_visit_by_slug_and_token,
--     v_visit_report_manifest and log_blackout_health follow customer.work_orders (the blackout customer_impact
--     does not move: the 19 have no manifest number). derm.audit_pack / audit_pack_client and fn_check_gdo_on_visit
--     (gt_visit_no_gdo) now skip lift station visits stored FALSE, the right direction. ops.v_derm_compliance (no
--     app, edge function or DB reader) will drift lift-station-only Pumping clients toward overdue and then
--     derm_violation as optional manifests stop (013-DIM and 057-BAY already read overdue, 031-KRU due_soon).
--
-- HOW TO RUN: four parts, each its own transaction, sent as THREE calls in order (never the whole file at once:
--   a body containing COMMIT is not atomic, Supabase CLAUDE.md).
--   Call 1 = PART A + PART B.
--     PART A  proves everything on TEMP copies of the three app-read views (no lock on them), with the classifier,
--             catalogue and backfill applied for real and then ROLLED BACK. REPEATABLE READ (the pg_net guard
--             compares two counts). Takes ~16 s. An error stops the call before PART B, so nothing changes. It
--             holds row locks on catalogue rows 04/11 and the 21 pending visits while it runs.
--     PART B  the DDL and catalog-only checks, then COMMIT. CREATE OR REPLACE VIEW takes ACCESS EXCLUSIVE on views
--             the Field Portal, DERM Tracker and DUMP read, so nothing heavy runs in it, and the views are taken in
--             the order DUMP, picker, work_orders (no deadlock with a DUMP reader; the Field Portal waits on one
--             lock only). lock_timeout 3 s: if it times out (the backup dump runs at HH:17 UTC on even hours),
--             send call 1 again.
--   Call 2 = PART B2, the backfill (rows only; no view lock). Idempotent: safe to resend.
--   Call 3 = PART C, read-only, against the committed objects. If it fails, run the rollback file.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): public.service_line_items and public.visits are both audited
--   (audit_service_line_items, audit_visits); every write here lands in audit.logs with old_row intact (the
--   rollback record; the rollback file finds the backfilled rows there). The new objects are a pure function and a
--   view (nothing to audit). Triggers on public.visits that fire on the backfill, read 2026-10-12: audit_visits;
--   trg_aa_derm_required_shadow and trg_derm_required_lock (act only on a LOCKED old row; candidates are
--   unlocked); trg_mark_visit_sync_pending (ignores derm_required); trg_visits_updated_at (bumps updated_at);
--   zzz_broadcast_inval (apps refetch). trg_push_visit_update's WHEN does not name derm_required, so no Jobber
--   push; trg_zz_queue_start_recheck and the other UPDATE OF triggers do not list it. PART A and PART B2 pin the
--   WHOLE trigger set (17 names + an md5 of each definition), so a new trigger, or a changed one with no column
--   list, stops the backfill; and the pg_net queue is counted before and after it.
-- GRANTS (Supabase default privileges grant new objects BY NAME): the new view is REVOKEd by name and granted
--   SELECT to service_role + authenticated (db_backup_reader keeps r, see part 4); the helper is EXECUTE to
--   PUBLIC; relacl/reloptions of the three replaced views are compared before and after; has_*_privilege asserts
--   the result for anon / authenticated / service_role / pg_read_all_data.
-- ROLLBACK: docs/migrations/_baseline/2026-10-12_lift_station.before.sql holds the four previous bodies;
--   2026-10-12_rollback_lift_station_not_derm_required.sql refuses unless the five objects are still on 1600's md5s, then puts the
--   classifier and catalogue back, re-promotes the backfilled visits from audit.logs, restores the three views in
--   lock order and drops the rule and the helper, in that order. Roll 2026-10-12_1610 back FIRST (its view reads the rule).
-- ============================================================================

-- PART A (no lock on the app-read views): the change applied for real on the functions/catalogue/rows, the three
-- views as TEMP copies, everything measured, then ROLLBACK. REPEATABLE READ: the pg_net queue guard (V3) compares two
-- counts ~10 s apart, so it must see one snapshot (only this transaction's own enqueues can then move it).
BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET LOCAL lock_timeout = '3s';

DO $pin$
DECLARE v_set text; v_n int;
BEGIN
  IF md5(pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure)) <> '4c11514fe282b48e82e4a0e6268556ff' THEN
    RAISE EXCEPTION 'A: fn_line_item_requires_derm changed since 2026-10-12 15:32 ET: copy the live body again'; END IF;
  IF md5(pg_get_functiondef('public.fn_visit_requires_derm(bigint)'::regprocedure)) <> '0183ea6412123ee4c0fd5c7663142221' THEN
    RAISE EXCEPTION 'A: fn_visit_requires_derm changed: re-read its fold before shipping'; END IF;
  IF md5(pg_get_viewdef('customer.work_orders'::regclass)) <> 'a78a3815fff23c00d2100b963b159260' THEN
    RAISE EXCEPTION 'A: customer.work_orders changed: copy the live body again'; END IF;
  IF md5(pg_get_viewdef('public.manifest_pickable_visits'::regclass)) <> 'd5513224f7b2220c8c1ec0c0de1129a9' THEN
    RAISE EXCEPTION 'A: manifest_pickable_visits changed: copy the live body again'; END IF;
  IF md5(pg_get_viewdef('public.dump_outstanding_visits'::regclass)) <> '5eb6eed9069a38f7557175a279b3c13f' THEN
    RAISE EXCEPTION 'A: dump_outstanding_visits changed: copy the live body again'; END IF;
  IF md5(pg_get_viewdef('public.v_visit_grey_water_pumping'::regclass)) <> 'a7683bbb68fd00a9aeb0fc1680abc8b8' THEN
    RAISE EXCEPTION 'A: v_visit_grey_water_pumping (the rule mirrored here) changed: re-read it'; END IF;
  -- the writers whose behaviour the backfill reasoning rests on
  IF md5(pg_get_functiondef('public.set_visit_derm_required(bigint)'::regprocedure)) <> '2e239819e04c7aa19a5e379ac883ef69'
     OR md5(pg_get_functiondef('public.rederive_visits_derm_required()'::regprocedure)) <> '352b0e7f4799f2240a29496c4b7ca7fe'
     OR md5(pg_get_functiondef('public.fn_lock_manual_derm_required()'::regprocedure)) <> 'b8b50b65be89acaee77e1b799e140f48'
     OR md5(pg_get_functiondef('public.fn_mark_visit_sync_pending()'::regprocedure)) <> 'f607c3772a444f8fe275380e44651fb4' THEN
    RAISE EXCEPTION 'A: a derm_required writer or the sync-pending trigger changed: re-read them'; END IF;
  -- triggers on visits: exactly two react to derm_required, and the Jobber push WHEN does not name it
  SELECT string_agg(t.tgname, ',' ORDER BY t.tgname) INTO v_set FROM pg_trigger t
   WHERE t.tgrelid = 'public.visits'::regclass AND NOT t.tgisinternal AND pg_get_triggerdef(t.oid) ~ 'derm_required';
  IF v_set IS DISTINCT FROM 'trg_aa_derm_required_shadow,trg_derm_required_lock' THEN
    RAISE EXCEPTION 'A: triggers on visits naming derm_required are now %', v_set; END IF;
  IF (SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t WHERE t.tgrelid = 'public.visits'::regclass AND t.tgname = 'trg_push_visit_update') !~ 'line_items_rev' THEN
    RAISE EXCEPTION 'A control: trg_push_visit_update WHEN not found as read'; END IF;
  -- the WHOLE trigger set on visits (17, names + definitions): a trigger with no column list whose function reacts
  -- to derm_required would not name it in its definition, so the regex above alone cannot see it
  IF (SELECT md5(string_agg(t.tgname || ':' || md5(pg_get_triggerdef(t.oid)), ',' ORDER BY t.tgname)) FROM pg_trigger t
       WHERE t.tgrelid = 'public.visits'::regclass AND NOT t.tgisinternal) IS DISTINCT FROM '5653e3e326b0f63c27a8c62e7689371f' THEN
    RAISE EXCEPTION 'A: the trigger set on public.visits changed since 2026-10-12 16:57 ET: re-read every trigger before the backfill'; END IF;
  -- catalogue
  IF (SELECT array_agg(code::text ORDER BY code) FROM public.service_line_items
       WHERE service_type = 'Pumping' AND location_target = 'Lift Station & Tank Cleaning' AND requires_derm IS TRUE) IS DISTINCT FROM ARRAY['04','11'] THEN
    RAISE EXCEPTION 'A: lift station pumping is no longer exactly {04,11} and DERM required: re-measure'; END IF;
  SELECT string_agg(code, ',' ORDER BY code) INTO v_set FROM public.service_line_items WHERE requires_derm;
  IF v_set IS DISTINCT FROM '01,02,04,09,11' THEN RAISE EXCEPTION 'A: DERM-required codes are %', v_set; END IF;
  SELECT string_agg(code, ',' ORDER BY code) INTO v_set FROM public.service_line_items WHERE reason IN ('fee','other');
  IF v_set IS DISTINCT FROM '25,26,27' THEN RAISE EXCEPTION 'A: fee/other codes are %', v_set; END IF;
  -- new objects absent, no temp shadows, reloptions as read
  IF to_regprocedure('public.fn_line_item_is_free_text_lift_station(text)') IS NOT NULL
     OR to_regclass('public.v_visit_lift_station_pumping') IS NOT NULL THEN
    RAISE EXCEPTION 'A: the new objects already exist'; END IF;
  IF to_regclass('pg_temp.work_orders') IS NOT NULL OR to_regclass('pg_temp.manifest_pickable_visits') IS NOT NULL
     OR to_regclass('pg_temp.dump_outstanding_visits') IS NOT NULL OR to_regclass('pg_temp.v_visit_lift_station_pumping') IS NOT NULL THEN
    RAISE EXCEPTION 'A: a temp object shadows a view name in this session'; END IF;
  IF (SELECT reloptions::text FROM pg_class WHERE oid = 'public.manifest_pickable_visits'::regclass) IS DISTINCT FROM '{security_invoker=true}'
     OR (SELECT reloptions FROM pg_class WHERE oid = 'public.dump_outstanding_visits'::regclass) IS NOT NULL
     OR (SELECT reloptions FROM pg_class WHERE oid = 'customer.work_orders'::regclass) IS NOT NULL THEN
    RAISE EXCEPTION 'A: reloptions of the three views are not as read'; END IF;
  IF NOT (has_table_privilege('authenticated', 'public.visits', 'SELECT') AND has_table_privilege('authenticated', 'public.line_items', 'SELECT')
          AND has_table_privilege('authenticated', 'public.service_line_items', 'SELECT')) THEN
    RAISE EXCEPTION 'A: authenticated no longer reads the base tables, so granting it the new view would widen access'; END IF;
END $pin$;

-- ---------- snapshots, before any change
CREATE TEMP TABLE _ls_report (k text PRIMARY KEY, v jsonb) ON COMMIT DROP;
-- the DUMP body as text, read now: once a TEMP picker shadows the name, pg_get_viewdef prints it schema-qualified
CREATE TEMP TABLE _ls_defs ON COMMIT DROP AS SELECT pg_get_viewdef('public.dump_outstanding_visits'::regclass) AS dov;
CREATE TEMP TABLE _ls_snap ON COMMIT DROP AS
  SELECT v.id, public.fn_visit_requires_derm(v.id) AS d0, v.derm_required AS s0, v.derm_required_locked AS lk0,
         v.visit_status AS st, v.visit_date AS dt, v.client_id, v.job_id, v.invoice_id, v.sync_state AS sync0,
         EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests m ON m.id = mv.manifest_id AND m.deleted_at IS NULL
                  WHERE mv.visit_id = v.id) AS man
    FROM public.visits v WHERE v.deleted_at IS NULL;
CREATE TEMP TABLE _ls_names ON COMMIT DROP AS
  WITH n AS (SELECT DISTINCT name AS nm FROM public.line_items WHERE name IS NOT NULL
             UNION SELECT title FROM public.service_line_items
             UNION SELECT unnest(ARRAY['Lift Station Pumping','Lift station pumping & tank cleaning','Pump out the lift station',
               'Lift-station pump out','Liftstation pumping','  lyft station pump-out  ','Pumping lift station','Lift station tank pumping',
               'Lift station & grease trap pump out','Grease trap and lift station pump out','Lift station pump out (GT)',
               'Lift station pump','Lift station pumps','Lift station pump replacement','Lift station and grey water pumping']))
  SELECT nm, public.fn_line_item_requires_derm(nm) AS d0 FROM n;
CREATE TEMP TABLE _ls_wo0  ON COMMIT DROP AS SELECT * FROM customer.work_orders;
CREATE TEMP TABLE _ls_mpv0 ON COMMIT DROP AS SELECT * FROM public.manifest_pickable_visits;
CREATE TEMP TABLE _ls_dov0 ON COMMIT DROP AS SELECT * FROM public.dump_outstanding_visits;
CREATE TEMP TABLE _ls_hoc0 ON COMMIT DROP AS SELECT visit_id FROM ops.v_derm_human_override_conflict;
CREATE TEMP TABLE _ls_perm0 ON COMMIT DROP AS SELECT to_jsonb(p) AS j FROM customer.permits p;
CREATE TEMP TABLE _ls_nfc0 ON COMMIT DROP AS SELECT visit_id FROM public.v_visit_not_for_city;
CREATE TEMP TABLE _ls_city0 ON COMMIT DROP AS SELECT visit_id, state FROM public.v_visit_city_email_state;
CREATE TEMP TABLE _ls_gw0 ON COMMIT DROP AS SELECT visit_id, tier FROM public.v_visit_grey_water_pumping;
CREATE TEMP TABLE _ls_misc0 ON COMMIT DROP AS
  SELECT (SELECT count(*) FROM derm.v_lwt_monthly_rows) AS lwt, (SELECT count(*) FROM public.v_gdo_reporting_derm_mismatch) AS gdo,
         (SELECT jsonb_object_agg(code, requires_derm) FROM ops.service_line_items) AS sli;
CREATE TEMP TABLE _ls_acl0 ON COMMIT DROP AS
  SELECT oid AS reloid, relacl::text AS acl, reloptions::text AS opts FROM pg_class
   WHERE oid IN ('customer.work_orders'::regclass, 'public.manifest_pickable_visits'::regclass, 'public.dump_outstanding_visits'::regclass);

-- the previous bodies under temp names (the "old body" controls)
DO $old$
DECLARE dl text := pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure);
BEGIN
  EXECUTE replace(dl, 'CREATE OR REPLACE FUNCTION public.fn_line_item_requires_derm(', 'CREATE FUNCTION pg_temp.old_line_derm(');
END $old$;

-- ---------- the change (identical text to PART B; real here, rolled back)
CREATE FUNCTION public.fn_line_item_is_free_text_lift_station(p_name text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  -- 2026-10-12 (Fred: "LS do not need DERM, it's optional."). An UNCODED line whose WHOLE text is lift station
  -- pumping: lift/lyft station (or "liftstation", "lift-station"), an optional "tank", then pump out / pumping /
  -- pumped, optionally "and (tank) cleaning"; or "lift station (tank) cleaning and pump out"; or the reverse
  -- order ("pump out the lift station"). An ALLOWLIST anchored at both ends, on purpose: a line naming anything
  -- else too ("Grease Trap Pumping & Lift Station") may be a grease trap and keeps its old answer, and "lift
  -- station pump" / "pumps" / "pump repair" name the station's pump, not a pump-out. A code-prefixed line never
  -- matches. Read by fn_line_item_requires_derm (arm b1) and public.v_visit_lift_station_pumping. Change it here only.
  SELECT COALESCE(btrim(p_name) ~* '^(l[iy]ft[-[:space:]]*station([[:space:]]+tank)?[[:space:]]+(pump(ing|ed)?[[:space:]]*-?[[:space:]]*out|pumping|pumped)([[:space:]]+(and|&)[[:space:]]+(tank[[:space:]]+)?clean(ing)?)?|l[iy]ft[-[:space:]]*station([[:space:]]+tank)?[[:space:]]+clean(ing)?[[:space:]]+(and|&)[[:space:]]+(pump(ing|ed)?[[:space:]]*-?[[:space:]]*out|pumping)|(pump(ing|ed)?[[:space:]]*-?[[:space:]]*out|pumping)[[:space:]]+(the[[:space:]]+)?l[iy]ft[-[:space:]]*station([[:space:]]+tank)?)$', false)
$function$;
GRANT EXECUTE ON FUNCTION public.fn_line_item_is_free_text_lift_station(text) TO PUBLIC;

DO $cls$
DECLARE
  d text := pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure);
  a text := '    -- (b) free-text PUMPING:';
  b text := '    -- (b1) 2026-10-12: a free-text line that is exactly LIFT STATION pumping answers what the catalogue' || chr(10)
         || '    --      says for lift station pumping (codes 04 and 11; FALSE since 2026-10-12_1600), so the policy' || chr(10)
         || '    --      stays in one place. The phrase list is public.fn_line_item_is_free_text_lift_station.' || chr(10)
         || '    WHEN public.fn_line_item_is_free_text_lift_station(p_name) THEN' || chr(10)
         || '      (SELECT bool_and(s.requires_derm) FROM public.service_line_items s' || chr(10)
         || '        WHERE s.service_type = ''Pumping'' AND s.location_target = ''Lift Station & Tank Cleaning'')' || chr(10)
         || '    -- (b) free-text PUMPING:';
BEGIN
  IF length(d) - length(replace(d, a, '')) <> length(a) THEN RAISE EXCEPTION 'classifier anchor is not unique'; END IF;
  EXECUTE replace(d, a, b);
END $cls$;

DO $cat$
DECLARE v_n int;
BEGIN
  UPDATE public.service_line_items SET requires_derm = false
   WHERE code IN ('04','11') AND requires_derm IS TRUE AND service_type = 'Pumping' AND location_target = 'Lift Station & Tank Cleaning';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 2 THEN RAISE EXCEPTION 'catalogue: expected 2 rows, updated %', v_n; END IF;
END $cat$;

CREATE TEMP VIEW v_visit_lift_station_pumping AS
SELECT v.id AS visit_id, t.tier
  FROM public.visits v
  CROSS JOIN LATERAL (
   -- every line the visit reaches that SAYS something about DERM (dr not NULL; fee/admin codes and unknown free text
   -- abstain), with its tier: 1 own line, 2 the job's, 3 the invoice's
   WITH svc AS (
     SELECT CASE WHEN li.visit_id = v.id THEN 1 WHEN v.job_id IS NOT NULL AND li.job_id = v.job_id THEN 2 ELSE 3 END AS tier,
            CASE WHEN s.code IS NOT NULL THEN COALESCE(s.service_type = 'Pumping' AND s.location_target = 'Lift Station & Tank Cleaning', false)
                 ELSE public.fn_line_item_is_free_text_lift_station(li.name) END AS ls,
            CASE WHEN s.code IS NULL THEN public.fn_line_item_requires_derm(li.name)
                 WHEN s.reason IN ('fee','other') THEN NULL
                 ELSE s.requires_derm END AS dr
       FROM public.line_items li
       LEFT JOIN public.service_line_items s
         ON s.code = lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0')
      WHERE li.name IS NOT NULL
        AND (li.visit_id = v.id OR (v.job_id IS NOT NULL AND li.job_id = v.job_id)
             OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id))
   )
   -- the nearest tier decides; it must hold lift station pumping and nothing else that needs DERM
   SELECT min(svc.tier) AS tier
     FROM svc
    WHERE svc.dr IS NOT NULL
      AND svc.tier = (SELECT min(svc2.tier) FROM svc svc2 WHERE svc2.dr IS NOT NULL)
   HAVING bool_or(svc.ls) AND NOT bool_or(svc.dr AND NOT svc.ls)
  ) t
 WHERE v.deleted_at IS NULL;
GRANT SELECT ON pg_temp.v_visit_lift_station_pumping TO authenticated, service_role;

DO $views$
DECLARE
  d_wo  text := pg_get_viewdef('customer.work_orders'::regclass);
  d_mpv text := pg_get_viewdef('public.manifest_pickable_visits'::regclass);
  d_dov text := pg_get_viewdef('public.dump_outstanding_visits'::regclass);
  ls    text := 'pg_temp.v_visit_lift_station_pumping';
  a_wo  text := '(EXISTS ( SELECT 1' || chr(10) || '           FROM v_visit_grey_water_pumping gwp' || chr(10) || '          WHERE (gwp.visit_id = v.id)))';
  a_mpv text := '((v.derm_required IS NULL) OR (v.derm_required = true))';
  a_dov text := '  WHERE (NOT (EXISTS ( SELECT 1';
BEGIN
  IF length(d_wo)  - length(replace(d_wo,  a_wo,  '')) <> length(a_wo)  THEN RAISE EXCEPTION 'work_orders: anchor not found exactly once'; END IF;
  IF length(d_mpv) - length(replace(d_mpv, a_mpv, '')) <> length(a_mpv) THEN RAISE EXCEPTION 'picker: anchor not found exactly once'; END IF;
  IF length(d_dov) - length(replace(d_dov, a_dov, '')) <> length(a_dov) THEN RAISE EXCEPTION 'dump_outstanding: anchor not found exactly once'; END IF;
  EXECUTE 'CREATE TEMP VIEW work_orders AS ' || rtrim(replace(d_wo, a_wo,
           a_wo || ' OR (EXISTS ( SELECT 1 FROM ' || ls || ' lsp WHERE (lsp.visit_id = v.id)))'), ';');
  EXECUTE 'CREATE TEMP VIEW manifest_pickable_visits WITH (security_invoker = true) AS ' || rtrim(replace(d_mpv, a_mpv,
           '((v.derm_required IS NULL) OR (v.derm_required = true) OR (EXISTS ( SELECT 1 FROM ' || ls || ' lsp WHERE (lsp.visit_id = v.id))))'), ';');
  -- unqualified "manifest_pickable_visits" in this body resolves to the TEMP copy above (pg_temp is searched first)
  EXECUTE 'CREATE TEMP VIEW dump_outstanding_visits AS ' || rtrim(replace(d_dov, a_dov,
           '  WHERE (vis.derm_required IS NOT FALSE) AND (NOT (EXISTS ( SELECT 1'), ';');
END $views$;
GRANT SELECT ON pg_temp.work_orders, pg_temp.manifest_pickable_visits, pg_temp.dump_outstanding_visits TO authenticated, service_role;

-- ---------- the backfill (identical predicate to PART B2; real here, rolled back)
CREATE TEMP TABLE _ls_q0 ON COMMIT DROP AS SELECT count(*) AS q_n FROM net.http_request_queue;
CREATE TEMP TABLE _ls_bf (id bigint PRIMARY KEY) ON COMMIT DROP;
DO $bf$
DECLARE v_pre int; v_n int;
BEGIN
  INSERT INTO _ls_bf (id) SELECT v.id FROM public.visits v WHERE v.deleted_at IS NULL
     AND v.visit_status = 'scheduled' AND v.visit_date >= (now() AT TIME ZONE 'America/New_York')::date
     AND v.derm_required IS TRUE AND v.derm_required_locked IS NOT TRUE
     AND public.fn_visit_requires_derm(v.id) IS FALSE;
  GET DIAGNOSTICS v_pre = ROW_COUNT;
  UPDATE public.visits v SET derm_required = false FROM _ls_bf b WHERE v.id = b.id AND v.deleted_at IS NULL
     AND v.visit_status = 'scheduled' AND v.visit_date >= (now() AT TIME ZONE 'America/New_York')::date
     AND v.derm_required IS TRUE AND v.derm_required_locked IS NOT TRUE
     AND public.fn_visit_requires_derm(v.id) IS FALSE;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> v_pre THEN RAISE EXCEPTION 'A backfill: updated % rows, expected %', v_n, v_pre; END IF;
END $bf$;

-- ---------- VERIFY (heavy, on the TEMP copies)
DO $verify$
DECLARE
  n int; n2 int; n3 int; n_ctl int; r text; v_j jsonb; v_fx bigint;
  today date := (now() AT TIME ZONE 'America/New_York')::date;
BEGIN
  -- V1 the classifier moves ONLY on lift station names (coded 04/11 or the free-text allowlist), only TRUE -> FALSE
  SELECT count(*) FILTER (WHERE x.d0 IS DISTINCT FROM x.d1 AND NOT (x.ls AND x.d0 IS TRUE AND x.d1 IS FALSE)),
         count(*) FILTER (WHERE x.d0 IS DISTINCT FROM x.d1),
         count(*) FILTER (WHERE x.ls AND x.d1 IS NOT FALSE)
    INTO n, n2, n3
    FROM (SELECT nm, d0, public.fn_line_item_requires_derm(nm) AS d1,
                 (lpad(substring(btrim(nm) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN ('04','11')
                  OR public.fn_line_item_is_free_text_lift_station(nm)) AS ls
            FROM _ls_names) x;
  IF n <> 0 THEN RAISE EXCEPTION 'V1: % names changed classification for another reason', n; END IF;
  IF n2 < 8 THEN RAISE EXCEPTION 'V1 control: only % names changed (the 4 coded titles + 4 free-text names must)', n2; END IF;
  IF n3 <> 0 THEN RAISE EXCEPTION 'V1: % lift station names do not answer FALSE', n3; END IF;
  SELECT string_agg(format('%s=%s(want %s)', f.nm, public.fn_line_item_requires_derm(f.nm), f.want), '; ') INTO r
    FROM (VALUES ('04 - Service Agreement - Pumping - Lift Station & Tank Cleaning', false), ('04 - Service Agreement - Pumping - Lift Station', false),
                 ('11 - Service Call - Pumping - Lift Station & Tank Cleaning', false), ('11 - Service Call - Pumping - Lift Station', false),
                 ('Lyft station cleaning and Pump out', false), ('Lift station pump out and cleaning', false), ('Lift station tank pump out', false),
                 ('Lyft Station Pump out', false), ('Lift Station Pumping', false), ('Pump out the lift station', false), ('Lift-station pump out', false),
                 ('Liftstation pumping', false), ('  lyft station pump-out  ', false), ('Lift station pumping & tank cleaning', false),
                 ('Grease Trap Pumping & Lift Station Cleaning', true), ('Grease Trap Pumping & Lift Station', true),
                 ('Lift station & grease trap pump out', true), ('Grease trap and lift station pump out', true), ('Lift station pump out (GT)', true),
                 ('Lift station and grey water pumping', true), ('Lift station pump repair', true), ('Lift station pumps', true),
                 ('Lyft station cleaning', false), ('Lyft Station Hydrojet Cleaning', false),
                 ('01 - Service Agreement - Pumping - Grease Trap & Tank Cleaning', true), ('09 - Service Call - Pumping - Grease Trap & Tank Cleaning', true),
                 ('03 - Service Agreement - Pumping - Grey Water', false), ('Grey Water Pumping', false)) f(nm, want)
   WHERE public.fn_line_item_requires_derm(f.nm) IS DISTINCT FROM f.want;
  IF r IS NOT NULL THEN RAISE EXCEPTION 'V1 fixtures: %', r; END IF;
  IF public.fn_line_item_requires_derm('Lyft station') IS NOT NULL OR public.fn_line_item_requires_derm('25 - Credit card fee (3.53%)') IS NOT NULL THEN
    RAISE EXCEPTION 'V1: a bare "Lyft station" or a fee line no longer answers NULL'; END IF;
  IF public.fn_line_item_is_free_text_lift_station(NULL) IS NOT FALSE THEN RAISE EXCEPTION 'V1: NULL input must answer false'; END IF;
  -- (b1) answers the catalogue flag, not a literal; and the old body on the new catalogue still says TRUE for
  -- free text (the control proving the arm, not part 1 alone, moves those names)
  IF public.fn_line_item_requires_derm('Lyft Station Pump out') IS DISTINCT FROM
       (SELECT bool_and(s.requires_derm) FROM public.service_line_items s WHERE s.service_type = 'Pumping' AND s.location_target = 'Lift Station & Tank Cleaning') THEN
    RAISE EXCEPTION 'V1: arm (b1) does not answer the catalogue lift station flag'; END IF;
  IF pg_temp.old_line_derm('Lyft Station Pump out') IS NOT TRUE THEN
    RAISE EXCEPTION 'V1 control: the old classifier on the new catalogue should still say TRUE for free text'; END IF;
  -- mutation control, undone: flip the catalogue back to TRUE; the free-text arm must follow it (a literal FALSE
  -- would pass the equality above and fail here)
  BEGIN
    UPDATE public.service_line_items SET requires_derm = true WHERE code IN ('04','11');
    IF public.fn_line_item_requires_derm('Lyft Station Pump out') IS NOT TRUE THEN
      RAISE EXCEPTION 'V1: arm (b1) does not follow the catalogue flag'; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'verify-undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'verify-undo' THEN RAISE; END IF;
  END;

  -- V2 visit derive: every change is TRUE -> FALSE on a visit reaching a lift station line and no grease trap pumping
  CREATE TEMP TABLE _ls_after ON COMMIT DROP AS
    SELECT s.*, public.fn_visit_requires_derm(s.id) AS d1,
           EXISTS (SELECT 1 FROM public.line_items li WHERE li.name IS NOT NULL
                    AND (li.visit_id = s.id OR (s.job_id IS NOT NULL AND li.job_id = s.job_id) OR (s.invoice_id IS NOT NULL AND li.invoice_id = s.invoice_id))
                    AND (lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN ('04','11')
                         OR public.fn_line_item_is_free_text_lift_station(li.name))) AS reaches_ls,
           EXISTS (SELECT 1 FROM pg_temp.v_visit_lift_station_pumping l WHERE l.visit_id = s.id) AS is_ls
      FROM _ls_snap s;
  SELECT count(*) FILTER (WHERE d0 IS DISTINCT FROM d1 AND NOT (reaches_ls AND d0 IS TRUE AND d1 IS FALSE)),
         count(*) FILTER (WHERE d0 IS TRUE AND d1 IS FALSE),
         count(*) FILTER (WHERE d0 IS NULL AND d1 IS FALSE AND s0 IS DISTINCT FROM false)
    INTO n, n2, n3 FROM _ls_after;
  IF n <> 0 THEN RAISE EXCEPTION 'V2: % derive changes of an unintended kind', n; END IF;
  IF n2 < 1 THEN RAISE EXCEPTION 'V2 control: no derive moved TRUE -> FALSE'; END IF;
  IF n3 <> 0 THEN RAISE EXCEPTION 'V2: % visits would newly be filled FALSE by the nightly job', n3; END IF;
  -- every visit reaching a grease trap pumping code (01, 02, 09) still derives TRUE
  SELECT count(*), count(*) FILTER (WHERE a.d1 IS NOT TRUE) INTO n_ctl, n FROM _ls_after a
   WHERE EXISTS (SELECT 1 FROM public.line_items li WHERE li.name IS NOT NULL
                  AND (li.visit_id = a.id OR (a.job_id IS NOT NULL AND li.job_id = a.job_id) OR (a.invoice_id IS NOT NULL AND li.invoice_id = a.invoice_id))
                  AND lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN ('01','02','09'));
  IF n_ctl < 1000 THEN RAISE EXCEPTION 'V2 control: only % visits reach a grease trap pumping code', n_ctl; END IF;
  IF n <> 0 THEN RAISE EXCEPTION 'V2: % visits with grease trap pumping no longer derive TRUE', n; END IF;
  -- a mixed pending visit (lift station + grease trap) stays TRUE: the control that the fold, not the rule, decides
  IF NOT EXISTS (SELECT 1 FROM _ls_after WHERE st = 'scheduled' AND dt >= today AND reaches_ls AND d1 IS TRUE AND s0 IS TRUE) THEN
    RAISE EXCEPTION 'V2 control: no mixed pending visit to prove grease trap still wins'; END IF;

  -- V3 the backfill: only pending, unlocked, stored TRUE, lift station, unfiled; nothing else moved; no push queued
  SELECT count(*) INTO n FROM _ls_bf;
  IF n < 1 OR n > 40 THEN RAISE EXCEPTION 'V3: % backfill candidates, expected 1 to 40', n; END IF;
  SELECT count(*) INTO n FROM _ls_bf b JOIN _ls_after a USING (id) WHERE NOT a.reaches_ls OR NOT a.is_ls OR a.man OR a.lk0 OR a.st <> 'scheduled';
  IF n <> 0 THEN RAISE EXCEPTION 'V3: % candidates are not pending, unfiled, unlocked lift station visits', n; END IF;
  SELECT count(*) INTO n FROM _ls_snap s JOIN public.visits v ON v.id = s.id
   WHERE (v.derm_required IS DISTINCT FROM s.s0 AND s.id NOT IN (SELECT id FROM _ls_bf))
      OR v.derm_required_locked IS DISTINCT FROM s.lk0 OR v.sync_state IS DISTINCT FROM s.sync0;
  IF n <> 0 THEN RAISE EXCEPTION 'V3: % visits changed stored value, lock or sync_state beyond the candidates', n; END IF;
  SELECT count(*) INTO n FROM public.visits v WHERE v.deleted_at IS NULL AND v.visit_status = 'scheduled'
     AND v.visit_date >= today AND v.derm_required IS TRUE AND v.derm_required_locked IS NOT TRUE AND public.fn_visit_requires_derm(v.id) IS FALSE;
  IF n <> 0 THEN RAISE EXCEPTION 'V3: % pending visits still TRUE while deriving FALSE', n; END IF;
  IF (SELECT count(*) FROM net.http_request_queue) <> (SELECT q_n FROM _ls_q0) THEN
    RAISE EXCEPTION 'V3: the backfill queued an HTTP call (a Jobber push?)'; END IF;
  -- the SA generator's own verdict (bool_or over job lines) agrees
  SELECT count(*) INTO n FROM (SELECT v.job_id, bool_or(public.fn_line_item_requires_derm(li.name)) AS gen
      FROM public.visits v JOIN _ls_bf b USING (id) JOIN public.line_items li ON li.job_id = v.job_id AND li.name IS NOT NULL
     GROUP BY v.job_id) x WHERE x.gen IS NOT FALSE;
  IF n <> 0 THEN RAISE EXCEPTION 'V3: % backfilled jobs would still generate DERM-required visits', n; END IF;

  -- V4 the rule. (a) Not empty. (b) It equals an independent computation (the classifier on every reached line, codes
  -- 04/11 as literals, grouped instead of LATERAL), both directions, tier included. Then three live discriminators,
  -- each with a control that the shape exists today, proving the branch is exercised: (c) own lines first: own
  -- services that are not lift station keep a visit out although its job or invoice bills lift station; (d) a
  -- deciding tier that also holds grease trap pumping keeps a visit out (5844, 7087: own 01/02 + 04); (e) an own
  -- UNCODED service claims tier 1 (3890, 3919: own "Hydrojet Unclogging Commercial", lift station only on the
  -- shared invoice). (d) and (e) are where this rule is tighter than grey water's (which has 0 live visits of
  -- either shape), measured in review 2026-10-12.
  CREATE TEMP TABLE _ls_lines ON COMMIT DROP AS
    SELECT v.id AS visit_id,
           CASE WHEN li.visit_id = v.id THEN 1 WHEN v.job_id IS NOT NULL AND li.job_id = v.job_id THEN 2 ELSE 3 END AS tier,
           (substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]') IS NOT NULL) AS coded,
           public.fn_line_item_requires_derm(li.name) AS cls,
           (COALESCE(lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') IN ('04','11'), false)
            OR public.fn_line_item_is_free_text_lift_station(li.name)) AS ls
      FROM public.visits v JOIN public.line_items li ON li.name IS NOT NULL
       AND (li.visit_id = v.id OR (v.job_id IS NOT NULL AND li.job_id = v.job_id) OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id))
     WHERE v.deleted_at IS NULL;
  CREATE INDEX ON _ls_lines (visit_id, tier);
  ANALYZE _ls_lines;
  CREATE TEMP TABLE _ls_rule_ind ON COMMIT DROP AS
    SELECT g.visit_id, g.tier FROM (
      SELECT x.visit_id, x.tier, bool_or(x.ls) AS any_ls, bool_or(x.cls AND NOT x.ls) AS other_dr,
             rank() OVER (PARTITION BY x.visit_id ORDER BY x.tier) AS rk
        FROM _ls_lines x WHERE x.cls IS NOT NULL GROUP BY x.visit_id, x.tier) g
     WHERE g.rk = 1 AND g.any_ls AND NOT g.other_dr;
  SELECT count(*) INTO n_ctl FROM pg_temp.v_visit_lift_station_pumping;
  IF n_ctl < 50 THEN RAISE EXCEPTION 'V4 control: only % lift station visits', n_ctl; END IF;
  SELECT count(*) INTO n FROM ((SELECT visit_id, tier FROM pg_temp.v_visit_lift_station_pumping EXCEPT SELECT visit_id, tier FROM _ls_rule_ind)
                               UNION ALL (SELECT visit_id, tier FROM _ls_rule_ind EXCEPT SELECT visit_id, tier FROM pg_temp.v_visit_lift_station_pumping)) x;
  IF n <> 0 THEN RAISE EXCEPTION 'V4: the rule differs from the independent computation on % rows', n; END IF;
  -- (c) own lines first
  SELECT count(DISTINCT x.visit_id), count(DISTINCT x.visit_id) FILTER (WHERE EXISTS (SELECT 1 FROM pg_temp.v_visit_lift_station_pumping l WHERE l.visit_id = x.visit_id))
    INTO n_ctl, n FROM _ls_lines x
   WHERE x.tier = 1 AND x.cls IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM _ls_lines y WHERE y.visit_id = x.visit_id AND y.tier = 1 AND y.ls)
     AND EXISTS (SELECT 1 FROM _ls_lines y WHERE y.visit_id = x.visit_id AND y.tier > 1 AND y.ls AND y.cls IS NOT NULL);
  IF n_ctl < 1 THEN RAISE EXCEPTION 'V4 control: no own-lines-first discriminator on live data'; END IF;
  IF n <> 0 THEN RAISE EXCEPTION 'V4: % visits decided by their own non lift station lines entered the rule', n; END IF;
  INSERT INTO _ls_report VALUES ('own_lines_first_discriminators', to_jsonb(n_ctl));
  -- (d) mixed deciding tier
  SELECT count(DISTINCT x.visit_id), count(DISTINCT x.visit_id) FILTER (WHERE EXISTS (SELECT 1 FROM pg_temp.v_visit_lift_station_pumping l WHERE l.visit_id = x.visit_id))
    INTO n_ctl, n FROM _ls_lines x
   WHERE x.tier = 1 AND x.ls AND x.cls IS NOT NULL
     AND EXISTS (SELECT 1 FROM _ls_lines y WHERE y.visit_id = x.visit_id AND y.tier = 1 AND y.cls AND NOT y.ls);
  IF n_ctl < 1 THEN RAISE EXCEPTION 'V4 control: no visit with lift station and grease trap pumping on its own lines'; END IF;
  IF n <> 0 THEN RAISE EXCEPTION 'V4: % visits whose own lines also pump a grease trap entered the rule', n; END IF;
  INSERT INTO _ls_report VALUES ('mixed_own_tier_kept_out', to_jsonb(n_ctl));
  -- (e) an own uncoded service claims tier 1
  SELECT count(DISTINCT x.visit_id), count(DISTINCT x.visit_id) FILTER (WHERE EXISTS (SELECT 1 FROM pg_temp.v_visit_lift_station_pumping l WHERE l.visit_id = x.visit_id))
    INTO n_ctl, n FROM _ls_lines x
   WHERE x.tier = 1 AND NOT x.coded AND x.cls IS NOT NULL AND NOT x.ls
     AND NOT EXISTS (SELECT 1 FROM _ls_lines y WHERE y.visit_id = x.visit_id AND y.tier = 1 AND (y.coded OR y.ls) AND y.cls IS NOT NULL)
     AND EXISTS (SELECT 1 FROM _ls_lines y WHERE y.visit_id = x.visit_id AND y.tier > 1 AND y.ls AND y.cls IS NOT NULL);
  IF n_ctl < 1 THEN RAISE EXCEPTION 'V4 control: no visit whose only own service is uncoded while its job or invoice bills lift station'; END IF;
  IF n <> 0 THEN RAISE EXCEPTION 'V4: % visits whose own uncoded service is not lift station entered the rule', n; END IF;
  INSERT INTO _ls_report VALUES ('own_uncoded_service_kept_out', to_jsonb(n_ctl));
  -- the completed visits a person stored FALSE that reach a lift station line but stay OUT of the rule (so stay
  -- hidden from the Field Portal and the picker): reported for Fred
  SELECT jsonb_agg(jsonb_build_object('visit_id', v.id, 'client', c.client_code, 'date', v.visit_date) ORDER BY v.visit_date, v.id) INTO v_j
    FROM public.visits v JOIN public.clients c ON c.id = v.client_id
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.derm_required IS FALSE
     AND EXISTS (SELECT 1 FROM _ls_lines x WHERE x.visit_id = v.id AND x.ls)
     AND NOT EXISTS (SELECT 1 FROM pg_temp.v_visit_lift_station_pumping l WHERE l.visit_id = v.id)
     AND NOT EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping g WHERE g.visit_id = v.id);
  INSERT INTO _ls_report VALUES ('ls_stored_false_kept_hidden', coalesce(v_j, '[]'::jsonb));
  -- grey water rule untouched
  IF EXISTS ((SELECT visit_id, tier FROM _ls_gw0 EXCEPT SELECT visit_id, tier FROM public.v_visit_grey_water_pumping)
             UNION ALL (SELECT visit_id, tier FROM public.v_visit_grey_water_pumping EXCEPT SELECT visit_id, tier FROM _ls_gw0)) THEN
    RAISE EXCEPTION 'V4: the grey water rule moved'; END IF;

  -- V5 Field Portal (TEMP copy): nothing leaves; the added set = completed, client-set lift station visits stored
  -- FALSE that grey water did not already admit, both directions; pre-existing rows unchanged but visit_num; added
  -- rows read derm_required = false. And the LIVE view fails the same test (the control).
  SELECT count(*) INTO n FROM _ls_wo0 b WHERE NOT EXISTS (SELECT 1 FROM pg_temp.work_orders w WHERE w.id = b.id);
  IF n <> 0 THEN RAISE EXCEPTION 'V5: % work orders disappeared', n; END IF;
  CREATE TEMP TABLE _ls_wo_expect ON COMMIT DROP AS
    SELECT v.public_id AS id FROM public.visits v
     WHERE v.visit_status = 'completed' AND v.client_id IS NOT NULL AND v.deleted_at IS NULL AND v.derm_required IS FALSE
       AND EXISTS (SELECT 1 FROM pg_temp.v_visit_lift_station_pumping l WHERE l.visit_id = v.id)
       AND NOT EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping g WHERE g.visit_id = v.id);
  SELECT count(*) INTO n_ctl FROM _ls_wo_expect;
  IF n_ctl < 1 THEN RAISE EXCEPTION 'V5 control: no stored-FALSE completed lift station visit to admit'; END IF;
  SELECT count(*) INTO n FROM ((SELECT id FROM pg_temp.work_orders EXCEPT SELECT id FROM _ls_wo0) EXCEPT SELECT id FROM _ls_wo_expect) x;
  SELECT count(*) INTO n2 FROM (SELECT id FROM _ls_wo_expect EXCEPT (SELECT id FROM pg_temp.work_orders EXCEPT SELECT id FROM _ls_wo0)) x;
  IF n <> 0 OR n2 <> 0 THEN RAISE EXCEPTION 'V5: added work orders differ from the expected set (% extra, % missing)', n, n2; END IF;
  SELECT count(*) INTO n FROM (SELECT id FROM _ls_wo_expect EXCEPT SELECT id FROM customer.work_orders) x;
  IF n <> n_ctl THEN RAISE EXCEPTION 'V5 control: the live view already shows % of the % expected rows, so the test cannot tell the bodies apart', n_ctl - n, n_ctl; END IF;
  SELECT count(*) INTO n FROM _ls_wo0 b JOIN pg_temp.work_orders w ON w.id = b.id
   WHERE (to_jsonb(w) - 'visit_num') IS DISTINCT FROM (to_jsonb(b) - 'visit_num');
  IF n <> 0 THEN RAISE EXCEPTION 'V5: % pre-existing work orders changed beyond visit_num', n; END IF;
  SELECT count(*) INTO n FROM pg_temp.work_orders w WHERE w.id IN (SELECT id FROM _ls_wo_expect) AND w.derm_required IS NOT FALSE;
  IF n <> 0 THEN RAISE EXCEPTION 'V5: % added rows do not read derm_required = false', n; END IF;
  -- no not-required visit outside grey water / lift station appears (the 2026-08-05 rule still holds)
  SELECT count(*) INTO n FROM pg_temp.work_orders w JOIN public.visits v ON v.public_id = w.id
   WHERE v.derm_required IS FALSE
     AND NOT EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping g WHERE g.visit_id = v.id)
     AND NOT EXISTS (SELECT 1 FROM pg_temp.v_visit_lift_station_pumping l WHERE l.visit_id = v.id);
  IF n <> 0 THEN RAISE EXCEPTION 'V5: % not-required visits outside the two rules appear', n; END IF;
  SELECT jsonb_agg(jsonb_build_object('visit_id', v.id, 'client', c.client_code, 'date', v.visit_date) ORDER BY v.visit_date, v.id) INTO v_j
    FROM _ls_wo_expect e JOIN public.visits v ON v.public_id = e.id JOIN public.clients c ON c.id = v.client_id;
  INSERT INTO _ls_report VALUES ('field_portal_added', v_j);

  -- V6 the picker (TEMP copy): nothing leaves; added = completed, unlinked lift station visits stored FALSE (not
  -- dump sites); the LIVE picker lacks them (control); authenticated can read the copy, anon cannot read either.
  SELECT count(*) INTO n FROM _ls_mpv0 b WHERE NOT EXISTS (SELECT 1 FROM pg_temp.manifest_pickable_visits p WHERE p.visit_id = b.visit_id);
  IF n <> 0 THEN RAISE EXCEPTION 'V6: % pickable visits disappeared', n; END IF;
  SELECT count(*), count(*) FILTER (WHERE NOT (a.st = 'completed' AND NOT a.man AND a.is_ls AND v.derm_required IS FALSE))
    INTO n_ctl, n
    FROM (SELECT visit_id FROM pg_temp.manifest_pickable_visits EXCEPT SELECT visit_id FROM _ls_mpv0) x
    JOIN _ls_after a ON a.id = x.visit_id JOIN public.visits v ON v.id = x.visit_id;
  IF n_ctl < 1 THEN RAISE EXCEPTION 'V6 control: the picker gained nothing'; END IF;
  IF n <> 0 THEN RAISE EXCEPTION 'V6: % added pickable visits are not completed, unlinked, not-required lift station visits', n; END IF;
  SELECT count(*) INTO n FROM _ls_after a JOIN public.visits v ON v.id = a.id
   WHERE a.st = 'completed' AND NOT a.man AND a.is_ls AND v.derm_required IS FALSE
     AND NOT public.fn_is_non_customer(v.client_id, ARRAY['dump_site'])
     AND NOT EXISTS (SELECT 1 FROM pg_temp.manifest_pickable_visits p WHERE p.visit_id = a.id);
  IF n <> 0 THEN RAISE EXCEPTION 'V6: % not-required lift station visits are still not offerable', n; END IF;
  IF (SELECT count(*) FROM (SELECT visit_id FROM public.manifest_pickable_visits EXCEPT SELECT visit_id FROM _ls_mpv0) x) <> 0 THEN
    RAISE EXCEPTION 'V6 control: the live picker moved inside this transaction'; END IF;
  SELECT jsonb_agg(x.visit_id ORDER BY x.visit_id) INTO v_j FROM (SELECT visit_id FROM pg_temp.manifest_pickable_visits EXCEPT SELECT visit_id FROM _ls_mpv0) x;
  INSERT INTO _ls_report VALUES ('picker_added', v_j);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM pg_temp.manifest_pickable_visits;
  EXECUTE 'RESET ROLE';
  IF n < n_ctl THEN RAISE EXCEPTION 'V6: authenticated reads only % picker rows', n; END IF;

  -- V7 DUMP lists (TEMP copy reading the TEMP picker): exactly the same rows as before. Control: the same body
  -- WITHOUT the new filter would gain the not-required lift station visits.
  IF EXISTS ((SELECT to_jsonb(d) FROM _ls_dov0 d EXCEPT ALL SELECT to_jsonb(d) FROM pg_temp.dump_outstanding_visits d)
             UNION ALL (SELECT to_jsonb(d) FROM pg_temp.dump_outstanding_visits d EXCEPT ALL SELECT to_jsonb(d) FROM _ls_dov0 d)) THEN
    RAISE EXCEPTION 'V7: the DUMP outstanding list changed'; END IF;
  EXECUTE 'CREATE TEMP VIEW _ls_dov_nofilter AS ' || rtrim((SELECT dov FROM _ls_defs), ';');
  SELECT count(*) INTO n FROM (SELECT visit_id FROM pg_temp._ls_dov_nofilter EXCEPT SELECT visit_id FROM _ls_dov0) x;
  IF n < 1 THEN RAISE EXCEPTION 'V7 control: without the filter the DUMP list would gain nothing, so the filter is not proven'; END IF;
  INSERT INTO _ls_report VALUES ('dump_rows_the_filter_keeps_out', to_jsonb(n));
  -- fixture, undone at once: no visit is stored NULL on the DUMP list today, so the live rows cannot tell the filter
  -- IS NOT FALSE (a NULL = unknown still owes a manifest) from IS TRUE. A completed, unlocked, unlinked 112-YA visit
  -- (the sanctioned test client) set to NULL must appear on the DUMP copy, and set to FALSE must not.
  SELECT v.id INTO v_fx FROM public.visits v JOIN public.clients c ON c.id = v.client_id
   WHERE c.client_code = '112-YA' AND v.visit_status = 'completed' AND v.deleted_at IS NULL AND v.derm_required_locked IS NOT TRUE
     AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests m ON m.id = mv.manifest_id AND m.deleted_at IS NULL WHERE mv.visit_id = v.id)
     AND NOT EXISTS (SELECT 1 FROM derm.address_sheet_clients a JOIN derm.address_sheets sh ON sh.id = a.sheet_id AND sh.deleted_at IS NULL WHERE a.visit_id = v.id)
   ORDER BY v.id LIMIT 1;
  IF v_fx IS NULL THEN RAISE EXCEPTION 'V7 control: no 112-YA fixture visit (completed, unlocked, unlinked)'; END IF;
  BEGIN
    UPDATE public.visits SET derm_required = NULL WHERE id = v_fx;
    IF NOT EXISTS (SELECT 1 FROM pg_temp.dump_outstanding_visits d WHERE d.visit_id = v_fx) THEN
      RAISE EXCEPTION 'V7: a stored-NULL visit (%) is not on the DUMP list: the filter must be IS NOT FALSE', v_fx; END IF;
    UPDATE public.visits SET derm_required = false WHERE id = v_fx;
    IF EXISTS (SELECT 1 FROM pg_temp.dump_outstanding_visits d WHERE d.visit_id = v_fx) THEN
      RAISE EXCEPTION 'V7: a stored-FALSE visit (%) is on the DUMP list', v_fx; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'verify-undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'verify-undo' THEN RAISE; END IF;
  END;

  -- V8 the other readers: GDO reporting check empty, not-for-city list unchanged, override review only shrinks
  -- and only by lift station visits, city email state unchanged, LWT unchanged, Calendar badge only on 04/11,
  -- permit card: only job-sourced rows lose their job frequency
  IF EXISTS (SELECT 1 FROM public.v_gdo_reporting_derm_mismatch) THEN
    RAISE EXCEPTION 'V8: v_gdo_reporting_derm_mismatch is not empty (the rpa-derm-health alert would fire): decide before shipping'; END IF;
  IF EXISTS ((SELECT visit_id FROM _ls_nfc0 EXCEPT SELECT visit_id FROM public.v_visit_not_for_city)
             UNION ALL (SELECT visit_id FROM public.v_visit_not_for_city EXCEPT SELECT visit_id FROM _ls_nfc0)) THEN
    RAISE EXCEPTION 'V8: v_visit_not_for_city moved'; END IF;
  IF EXISTS (SELECT visit_id FROM ops.v_derm_human_override_conflict EXCEPT SELECT visit_id FROM _ls_hoc0) THEN
    RAISE EXCEPTION 'V8: the human override review gained a visit'; END IF;
  SELECT count(*) INTO n FROM (SELECT visit_id FROM _ls_hoc0 EXCEPT SELECT visit_id FROM ops.v_derm_human_override_conflict) x
   WHERE NOT EXISTS (SELECT 1 FROM _ls_after a WHERE a.id = x.visit_id AND a.reaches_ls);
  IF n <> 0 THEN RAISE EXCEPTION 'V8: % visits left the override review without a lift station line', n; END IF;
  INSERT INTO _ls_report VALUES ('override_review', jsonb_build_object('before', (SELECT count(*) FROM _ls_hoc0), 'after', (SELECT count(*) FROM ops.v_derm_human_override_conflict)));
  IF EXISTS ((SELECT visit_id, state FROM _ls_city0 EXCEPT SELECT visit_id, state FROM public.v_visit_city_email_state)
             UNION ALL (SELECT visit_id, state FROM public.v_visit_city_email_state EXCEPT SELECT visit_id, state FROM _ls_city0)) THEN
    RAISE EXCEPTION 'V8: v_visit_city_email_state moved'; END IF;
  IF (SELECT count(*) FROM derm.v_lwt_monthly_rows) <> (SELECT lwt FROM _ls_misc0) THEN RAISE EXCEPTION 'V8: LWT rows moved'; END IF;
  SELECT count(*) INTO n FROM jsonb_each((SELECT sli FROM _ls_misc0)) e JOIN ops.service_line_items s ON s.code = e.key
   WHERE s.requires_derm IS DISTINCT FROM (e.value)::boolean AND NOT (s.code IN ('04','11') AND s.requires_derm IS FALSE);
  IF n <> 0 THEN RAISE EXCEPTION 'V8: % Calendar catalogue rows moved besides 04/11', n; END IF;
  SELECT count(*) INTO n FROM (SELECT j FROM _ls_perm0 EXCEPT ALL SELECT to_jsonb(p) FROM customer.permits p) x
   WHERE x.j->>'frequency_source' IS DISTINCT FROM 'job';
  IF n <> 0 THEN RAISE EXCEPTION 'V8: % permit rows changed that were not job-sourced', n; END IF;
  SELECT jsonb_agg(jsonb_build_object('permit', x.j->>'permit_number', 'was_every_days', x.j->'our_frequency_days')) INTO v_j
    FROM (SELECT j FROM _ls_perm0 EXCEPT ALL SELECT to_jsonb(p) FROM customer.permits p) x;
  INSERT INTO _ls_report VALUES ('permits_changed', coalesce(v_j, '[]'::jsonb));

  -- report
  INSERT INTO _ls_report VALUES
    ('rule_rows', (SELECT jsonb_object_agg(st, c) FROM (SELECT a.st, count(*) c FROM _ls_after a WHERE a.is_ls GROUP BY 1) x)),
    ('derive_moves', (SELECT jsonb_agg(jsonb_build_object('status', st, 'stored', s0, 'locked', lk0, 'filed', man, 'n', c)) FROM
       (SELECT st, s0, lk0, man, count(*) c FROM _ls_after WHERE d0 IS DISTINCT FROM d1 GROUP BY 1,2,3,4 ORDER BY 1,2,3,4) x)),
    ('backfilled', (SELECT jsonb_agg(jsonb_build_object('visit_id', b.id, 'client', c.client_code, 'date', a.dt) ORDER BY a.dt, b.id)
       FROM _ls_bf b JOIN _ls_after a ON a.id = b.id JOIN public.clients c ON c.id = a.client_id)),
    ('completed_true_now_false', (SELECT jsonb_agg(jsonb_build_object('visit_id', a.id, 'filed', a.man) ORDER BY a.id) FROM _ls_after a
       WHERE a.st = 'completed' AND a.s0 IS TRUE AND a.d0 IS TRUE AND a.d1 IS FALSE)),
    ('pending_mixed_stay_true', (SELECT to_jsonb(count(*)) FROM _ls_after WHERE st = 'scheduled' AND dt >= today AND reaches_ls AND d1 IS TRUE)),
    ('md5', jsonb_build_object(
       'classifier', md5(pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure)),
       'ls_view', md5(pg_get_viewdef('pg_temp.v_visit_lift_station_pumping'::regclass)),
       'work_orders', md5(pg_get_viewdef('pg_temp.work_orders'::regclass)),
       'picker', md5(pg_get_viewdef('pg_temp.manifest_pickable_visits'::regclass)),
       'dump_outstanding', md5(pg_get_viewdef('pg_temp.dump_outstanding_visits'::regclass))));
  -- the bodies PART B will create must render to exactly these (PART B re-checks the live result)
  IF md5(pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure)) <> '7e889e8f135a808080eea4da88e25cdb'
     OR md5(pg_get_viewdef('pg_temp.v_visit_lift_station_pumping'::regclass)) <> '646c58880a808ecf00a6d468062d049b'
     OR md5(pg_get_viewdef('pg_temp.work_orders'::regclass)) <> '2cb2720c0a935f36ab37debfb7ac7a25'
     OR md5(pg_get_viewdef('pg_temp.manifest_pickable_visits'::regclass)) <> '09c9282e54442afea7c5412741e8476f'
     OR md5(pg_get_viewdef('pg_temp.dump_outstanding_visits'::regclass)) <> '9cd9caec1e8fee8e5185b1d89c27fdfe' THEN
    RAISE EXCEPTION 'A: a new body does not render to the md5 PART B expects: %', (SELECT v FROM _ls_report WHERE k = 'md5'); END IF;
  RAISE NOTICE 'A passed: %', (SELECT jsonb_object_agg(k, v) FROM _ls_report WHERE k IN ('rule_rows','pending_mixed_stay_true','override_review'));
END $verify$;
ROLLBACK;

-- PART B: the DDL, with catalog-only checks, in a short transaction
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $pin$
BEGIN
  IF md5(pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure)) <> '4c11514fe282b48e82e4a0e6268556ff'
     OR md5(pg_get_viewdef('customer.work_orders'::regclass)) <> 'a78a3815fff23c00d2100b963b159260'
     OR md5(pg_get_viewdef('public.manifest_pickable_visits'::regclass)) <> 'd5513224f7b2220c8c1ec0c0de1129a9'
     OR md5(pg_get_viewdef('public.dump_outstanding_visits'::regclass)) <> '5eb6eed9069a38f7557175a279b3c13f' THEN
    RAISE EXCEPTION 'B: an object moved since PART A was built: re-read and rebuild'; END IF;
  IF to_regprocedure('public.fn_line_item_is_free_text_lift_station(text)') IS NOT NULL OR to_regclass('public.v_visit_lift_station_pumping') IS NOT NULL THEN
    RAISE EXCEPTION 'B: the new objects already exist (applied twice?)'; END IF;
  IF to_regclass('pg_temp.work_orders') IS NOT NULL OR to_regclass('pg_temp.manifest_pickable_visits') IS NOT NULL
     OR to_regclass('pg_temp.dump_outstanding_visits') IS NOT NULL OR to_regclass('pg_temp.v_visit_lift_station_pumping') IS NOT NULL THEN
    RAISE EXCEPTION 'B: a temp object shadows a view name in this session'; END IF;
END $pin$;
CREATE TEMP TABLE _ls_acl ON COMMIT DROP AS
  SELECT oid AS reloid, relacl::text AS acl, reloptions::text AS opts FROM pg_class
   WHERE oid IN ('customer.work_orders'::regclass, 'public.manifest_pickable_visits'::regclass, 'public.dump_outstanding_visits'::regclass);

-- 1. catalogue
DO $cat$
DECLARE v_n int;
BEGIN
  UPDATE public.service_line_items SET requires_derm = false
   WHERE code IN ('04','11') AND requires_derm IS TRUE AND service_type = 'Pumping' AND location_target = 'Lift Station & Tank Cleaning';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 2 THEN RAISE EXCEPTION 'catalogue: expected 2 rows, updated %', v_n; END IF;
END $cat$;

-- 2. the free-text lift station test (pure)
CREATE FUNCTION public.fn_line_item_is_free_text_lift_station(p_name text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  -- 2026-10-12 (Fred: "LS do not need DERM, it's optional."). An UNCODED line whose WHOLE text is lift station
  -- pumping: lift/lyft station (or "liftstation", "lift-station"), an optional "tank", then pump out / pumping /
  -- pumped, optionally "and (tank) cleaning"; or "lift station (tank) cleaning and pump out"; or the reverse
  -- order ("pump out the lift station"). An ALLOWLIST anchored at both ends, on purpose: a line naming anything
  -- else too ("Grease Trap Pumping & Lift Station") may be a grease trap and keeps its old answer, and "lift
  -- station pump" / "pumps" / "pump repair" name the station's pump, not a pump-out. A code-prefixed line never
  -- matches. Read by fn_line_item_requires_derm (arm b1) and public.v_visit_lift_station_pumping. Change it here only.
  SELECT COALESCE(btrim(p_name) ~* '^(l[iy]ft[-[:space:]]*station([[:space:]]+tank)?[[:space:]]+(pump(ing|ed)?[[:space:]]*-?[[:space:]]*out|pumping|pumped)([[:space:]]+(and|&)[[:space:]]+(tank[[:space:]]+)?clean(ing)?)?|l[iy]ft[-[:space:]]*station([[:space:]]+tank)?[[:space:]]+clean(ing)?[[:space:]]+(and|&)[[:space:]]+(pump(ing|ed)?[[:space:]]*-?[[:space:]]*out|pumping)|(pump(ing|ed)?[[:space:]]*-?[[:space:]]*out|pumping)[[:space:]]+(the[[:space:]]+)?l[iy]ft[-[:space:]]*station([[:space:]]+tank)?)$', false)
$function$;
COMMENT ON FUNCTION public.fn_line_item_is_free_text_lift_station(text) IS
  'TRUE when an uncoded line''s whole text is lift station pumping, exact phrase list anchored at both ends; a line naming anything else too keeps its old answer. Pure. Read by fn_line_item_requires_derm (arm b1: answers the catalogue lift station flag, FALSE since 2026-10-12_1600) and public.v_visit_lift_station_pumping. 2026-10-12.';
GRANT EXECUTE ON FUNCTION public.fn_line_item_is_free_text_lift_station(text) TO PUBLIC;

-- 3. the classifier: one arm, spliced from the live body
DO $cls$
DECLARE
  d text := pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure);
  a text := '    -- (b) free-text PUMPING:';
  b text := '    -- (b1) 2026-10-12: a free-text line that is exactly LIFT STATION pumping answers what the catalogue' || chr(10)
         || '    --      says for lift station pumping (codes 04 and 11; FALSE since 2026-10-12_1600), so the policy' || chr(10)
         || '    --      stays in one place. The phrase list is public.fn_line_item_is_free_text_lift_station.' || chr(10)
         || '    WHEN public.fn_line_item_is_free_text_lift_station(p_name) THEN' || chr(10)
         || '      (SELECT bool_and(s.requires_derm) FROM public.service_line_items s' || chr(10)
         || '        WHERE s.service_type = ''Pumping'' AND s.location_target = ''Lift Station & Tank Cleaning'')' || chr(10)
         || '    -- (b) free-text PUMPING:';
BEGIN
  IF length(d) - length(replace(d, a, '')) <> length(a) THEN RAISE EXCEPTION 'classifier anchor is not unique'; END IF;
  EXECUTE replace(d, a, b);
END $cls$;
COMMENT ON FUNCTION public.fn_visit_requires_derm(bigint) IS
  'DERM required for a visit, from the line items it reaches (visit, invoice or job). Any line classified TRUE -> true; '
  'every line classified and none TRUE -> false; otherwise NULL (unknown, treated as still needing a manifest). '
  'Fee/admin catalogue lines (reason fee/other: 25, 26, 27) abstain: they are left out of the fold, so a visit '
  'reaching only such lines is NULL. Grey water pumping (03, 10) is not DERM required since 2026-09-24; lift station '
  'pumping (04, 11, and a free-text line that is only lift station pumping) since 2026-10-12. A visit that also has '
  'grease trap pumping stays DERM required.';

-- 4. THE lift station rule, once
CREATE VIEW public.v_visit_lift_station_pumping AS
SELECT v.id AS visit_id, t.tier
  FROM public.visits v
  CROSS JOIN LATERAL (
   -- every line the visit reaches that SAYS something about DERM (dr not NULL; fee/admin codes and unknown free text
   -- abstain), with its tier: 1 own line, 2 the job's, 3 the invoice's
   WITH svc AS (
     SELECT CASE WHEN li.visit_id = v.id THEN 1 WHEN v.job_id IS NOT NULL AND li.job_id = v.job_id THEN 2 ELSE 3 END AS tier,
            CASE WHEN s.code IS NOT NULL THEN COALESCE(s.service_type = 'Pumping' AND s.location_target = 'Lift Station & Tank Cleaning', false)
                 ELSE public.fn_line_item_is_free_text_lift_station(li.name) END AS ls,
            CASE WHEN s.code IS NULL THEN public.fn_line_item_requires_derm(li.name)
                 WHEN s.reason IN ('fee','other') THEN NULL
                 ELSE s.requires_derm END AS dr
       FROM public.line_items li
       LEFT JOIN public.service_line_items s
         ON s.code = lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0')
      WHERE li.name IS NOT NULL
        AND (li.visit_id = v.id OR (v.job_id IS NOT NULL AND li.job_id = v.job_id)
             OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id))
   )
   -- the nearest tier decides; it must hold lift station pumping and nothing else that needs DERM
   SELECT min(svc.tier) AS tier
     FROM svc
    WHERE svc.dr IS NOT NULL
      AND svc.tier = (SELECT min(svc2.tier) FROM svc svc2 WHERE svc2.dr IS NOT NULL)
   HAVING bool_or(svc.ls) AND NOT bool_or(svc.dr AND NOT svc.ls)
  ) t
 WHERE v.deleted_at IS NULL;
COMMENT ON VIEW public.v_visit_lift_station_pumping IS
  'THE lift station pumping rule, once (2026-10-12_1600, shaped like public.v_visit_grey_water_pumping): live visits only; the lines a visit reaches that say something about DERM (fn_line_item_requires_derm not NULL: fee/admin codes and unknown free text abstain; uncoded services such as Hydrojet count) are grouped by tier (own lines 1, else job 2, else invoice 3), and the NEAREST tier must hold lift station pumping (catalogue Pumping + Lift Station & Tank Cleaning, 04 and 11, or fn_line_item_is_free_text_lift_station) and NOTHING ELSE that needs DERM. Tighter than the grey water rule on purpose: a deciding tier that also pumps a grease trap, or an own uncoded service that is not lift station, keeps the visit out. No status filter. Read by customer.work_orders (Field Portal keeps not-required lift station visits visible) and public.manifest_pickable_visits (an optional manifest can still be filed). SELECT for authenticated because the picker is security_invoker.';
-- Supabase default privileges grant BY NAME on every new view; revoke them by name, grant back the two reads.
REVOKE ALL ON public.v_visit_lift_station_pumping FROM PUBLIC, anon, authenticated, service_role, yannick_readonly;
GRANT SELECT ON public.v_visit_lift_station_pumping TO service_role, authenticated;

-- 5-7. the three readers, spliced from their live text
DO $views$
DECLARE
  d_wo  text := pg_get_viewdef('customer.work_orders'::regclass);
  d_mpv text := pg_get_viewdef('public.manifest_pickable_visits'::regclass);
  d_dov text := pg_get_viewdef('public.dump_outstanding_visits'::regclass);
  ls    text := 'public.v_visit_lift_station_pumping';
  a_wo  text := '(EXISTS ( SELECT 1' || chr(10) || '           FROM v_visit_grey_water_pumping gwp' || chr(10) || '          WHERE (gwp.visit_id = v.id)))';
  a_mpv text := '((v.derm_required IS NULL) OR (v.derm_required = true))';
  a_dov text := '  WHERE (NOT (EXISTS ( SELECT 1';
BEGIN
  IF length(d_wo)  - length(replace(d_wo,  a_wo,  '')) <> length(a_wo)  THEN RAISE EXCEPTION 'work_orders: anchor not found exactly once'; END IF;
  IF length(d_mpv) - length(replace(d_mpv, a_mpv, '')) <> length(a_mpv) THEN RAISE EXCEPTION 'picker: anchor not found exactly once'; END IF;
  IF length(d_dov) - length(replace(d_dov, a_dov, '')) <> length(a_dov) THEN RAISE EXCEPTION 'dump_outstanding: anchor not found exactly once'; END IF;
  -- 🛑 LOCK ORDER: the DUMP view first, then the picker it reads, then the Field Portal view LAST. A DUMP reader
  -- (dump_route_today, dump-visit-create, the crib sheet) locks dump_outstanding_visits then manifest_pickable_visits,
  -- so this order cannot deadlock with it; and a Field Portal read queues behind the work_orders lock only for that
  -- lock's own wait, not behind the other two (lock_timeout applies per lock). The bodies do not depend on the order.
  EXECUTE 'CREATE OR REPLACE VIEW public.dump_outstanding_visits AS ' || rtrim(replace(d_dov, a_dov,
           '  WHERE (vis.derm_required IS NOT FALSE) AND (NOT (EXISTS ( SELECT 1'), ';');
  -- 🛑 CREATE OR REPLACE VIEW replaces reloptions: security_invoker must be restated or the picker becomes owner-rights
  EXECUTE 'CREATE OR REPLACE VIEW public.manifest_pickable_visits WITH (security_invoker = true) AS ' || rtrim(replace(d_mpv, a_mpv,
           '((v.derm_required IS NULL) OR (v.derm_required = true) OR (EXISTS ( SELECT 1 FROM ' || ls || ' lsp WHERE (lsp.visit_id = v.id))))'), ';');
  EXECUTE 'CREATE OR REPLACE VIEW customer.work_orders AS ' || rtrim(replace(d_wo, a_wo,
           a_wo || ' OR (EXISTS ( SELECT 1 FROM ' || ls || ' lsp WHERE (lsp.visit_id = v.id)))'), ';');
END $views$;
COMMENT ON COLUMN customer.work_orders.derm_required IS
  'COALESCE(visits.derm_required, true), never NULL. FALSE only on a not-required visit the client still sees: grey water pumping (2026-09-24) or lift station pumping (2026-10-12), each decided by the visit''s own coded lines first (public.v_visit_grey_water_pumping, public.v_visit_lift_station_pumping). Apps hide the DERM paperwork parts on === false with no manifest number, never on !== true.';
COMMENT ON VIEW public.dump_outstanding_visits IS
  'Read-only browse list of completed visits that need (or may need: NULL) a DERM manifest and still have no live link, with the address cleaned for copying onto a sheet. A not-required visit is left out (vis.derm_required IS NOT FALSE, 2026-10-12): manifest_pickable_visits also offers lift station visits stored FALSE for an OPTIONAL manifest, and those must not read as owing one on the DUMP crib sheet. Shared projection: dump_manifest_handout_list selects FROM this. Browsing must never record a hand-out, which is why this exists separately.';
COMMENT ON VIEW public.manifest_pickable_visits IS
  'Completed, unlinked, live visits that can take a DERM manifest: DERM required or unknown, plus lift station pumping stored FALSE (the manifest is optional, Fred 2026-10-12; filing one turns the visit DERM required). security_invoker. Read by the DERM Tracker /upload matcher and "Adding a visit" picker, derm.v_stamp_unlinked_visits and public.dump_outstanding_visits (which leaves the optional ones out).';

DO $verify$
BEGIN
  -- the live objects are exactly the bodies PART A proved
  IF md5(pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure)) <> '7e889e8f135a808080eea4da88e25cdb' THEN RAISE EXCEPTION 'B: classifier is not the proven body'; END IF;
  IF md5(pg_get_viewdef('public.v_visit_lift_station_pumping'::regclass)) <> '646c58880a808ecf00a6d468062d049b' THEN RAISE EXCEPTION 'B: lift station view is not the proven body'; END IF;
  IF md5(pg_get_viewdef('customer.work_orders'::regclass)) <> '2cb2720c0a935f36ab37debfb7ac7a25' THEN RAISE EXCEPTION 'B: work_orders is not the proven body'; END IF;
  IF md5(pg_get_viewdef('public.manifest_pickable_visits'::regclass)) <> '09c9282e54442afea7c5412741e8476f' THEN RAISE EXCEPTION 'B: picker is not the proven body'; END IF;
  IF md5(pg_get_viewdef('public.dump_outstanding_visits'::regclass)) <> '9cd9caec1e8fee8e5185b1d89c27fdfe' THEN RAISE EXCEPTION 'B: dump_outstanding is not the proven body'; END IF;
  -- catalogue
  IF (SELECT string_agg(code, ',' ORDER BY code) FROM public.service_line_items WHERE requires_derm) IS DISTINCT FROM '01,02,09' THEN
    RAISE EXCEPTION 'B: DERM-required codes are not {01,02,09}'; END IF;
  -- the helper, cheap truth table
  IF public.fn_line_item_is_free_text_lift_station('Lyft station cleaning and Pump out') IS NOT TRUE
     OR public.fn_line_item_is_free_text_lift_station('Grease Trap Pumping & Lift Station') IS NOT FALSE
     OR public.fn_line_item_requires_derm('Lyft Station Pump out') IS NOT FALSE
     OR public.fn_line_item_requires_derm('Grease Trap Pumping & Lift Station Cleaning') IS NOT TRUE
     OR public.fn_line_item_requires_derm('04 - Service Agreement - Pumping - Lift Station & Tank Cleaning') IS NOT FALSE THEN
    RAISE EXCEPTION 'B: classifier truth table failed'; END IF;
  -- ACL and reloptions of the replaced views unchanged (picker keeps security_invoker=true)
  IF EXISTS (SELECT 1 FROM _ls_acl a JOIN pg_class c ON c.oid = a.reloid
              WHERE c.relacl::text IS DISTINCT FROM a.acl OR c.reloptions::text IS DISTINCT FROM a.opts)
     OR (SELECT count(*) FROM _ls_acl) <> 3 THEN RAISE EXCEPTION 'B: ACL or reloptions of a replaced view changed'; END IF;
  IF (SELECT reloptions::text FROM pg_class WHERE oid = 'public.manifest_pickable_visits'::regclass) IS DISTINCT FROM '{security_invoker=true}' THEN
    RAISE EXCEPTION 'B: the picker lost security_invoker'; END IF;
  -- grants on the new objects, as the roles
  IF has_table_privilege('anon', 'public.v_visit_lift_station_pumping', 'SELECT')
     OR NOT has_table_privilege('authenticated', 'public.v_visit_lift_station_pumping', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.v_visit_lift_station_pumping', 'SELECT')
     OR has_table_privilege('authenticated', 'public.v_visit_lift_station_pumping', 'INSERT') THEN
    RAISE EXCEPTION 'B: lift station view grants are not as intended: %', (SELECT relacl::text FROM pg_class WHERE oid = 'public.v_visit_lift_station_pumping'::regclass); END IF;
  IF NOT has_function_privilege('anon', 'public.fn_line_item_is_free_text_lift_station(text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.fn_line_item_is_free_text_lift_station(text)', 'EXECUTE')
     OR NOT has_function_privilege('pg_read_all_data', 'public.fn_line_item_is_free_text_lift_station(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'B: a reader of the views cannot execute the pure helper'; END IF;
  IF has_table_privilege('anon', 'customer.work_orders', 'SELECT') OR NOT has_table_privilege('authenticated', 'customer.work_orders', 'SELECT')
     OR has_table_privilege('anon', 'public.manifest_pickable_visits', 'SELECT') OR NOT has_table_privilege('authenticated', 'public.manifest_pickable_visits', 'SELECT')
     OR has_table_privilege('authenticated', 'public.dump_outstanding_visits', 'SELECT') OR NOT has_table_privilege('service_role', 'public.dump_outstanding_visits', 'SELECT') THEN
    RAISE EXCEPTION 'B: grants of the replaced views are not as before'; END IF;
END $verify$;
NOTIFY pgrst, 'reload schema';
COMMIT;

-- PART B2 (call 2): the backfill, PENDING visits only. Rows only, no view lock. Idempotent.
BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET LOCAL lock_timeout = '3s';
CREATE TEMP TABLE _ls_bsnap ON COMMIT DROP AS
  SELECT v.id, v.derm_required AS s0, v.derm_required_locked AS lk0, v.sync_state AS sync0 FROM public.visits v WHERE v.deleted_at IS NULL;
CREATE TEMP TABLE _ls_bq0 ON COMMIT DROP AS SELECT count(*) AS q_n FROM net.http_request_queue;
CREATE TEMP TABLE _ls_bbf (id bigint PRIMARY KEY) ON COMMIT DROP;
DO $bf$
DECLARE v_pre int; v_n int; v_bad int; today date := (now() AT TIME ZONE 'America/New_York')::date;
BEGIN
  IF (SELECT string_agg(code, ',' ORDER BY code) FROM public.service_line_items WHERE requires_derm) IS DISTINCT FROM '01,02,09'
     OR md5(pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure)) <> '7e889e8f135a808080eea4da88e25cdb'
     OR to_regclass('public.v_visit_lift_station_pumping') IS NULL THEN
    RAISE EXCEPTION 'B2: PART B is not committed (catalogue, classifier or view missing)'; END IF;
  IF (SELECT md5(string_agg(t.tgname || ':' || md5(pg_get_triggerdef(t.oid)), ',' ORDER BY t.tgname)) FROM pg_trigger t
       WHERE t.tgrelid = 'public.visits'::regclass AND NOT t.tgisinternal) IS DISTINCT FROM '5653e3e326b0f63c27a8c62e7689371f' THEN
    RAISE EXCEPTION 'B2: the trigger set on public.visits changed since PART A proved the backfill: re-read every trigger'; END IF;
  INSERT INTO _ls_bbf (id) SELECT v.id FROM public.visits v WHERE v.deleted_at IS NULL
     AND v.visit_status = 'scheduled' AND v.visit_date >= today
     AND v.derm_required IS TRUE AND v.derm_required_locked IS NOT TRUE
     AND public.fn_visit_requires_derm(v.id) IS FALSE;
  GET DIAGNOSTICS v_pre = ROW_COUNT;
  IF v_pre > 40 THEN RAISE EXCEPTION 'B2: % candidates, expected at most 40 (21 measured 2026-10-12)', v_pre; END IF;
  SELECT count(*) INTO v_bad FROM _ls_bbf b WHERE NOT EXISTS (SELECT 1 FROM public.v_visit_lift_station_pumping l WHERE l.visit_id = b.id);
  IF v_bad <> 0 THEN RAISE EXCEPTION 'B2: % candidates are not lift station visits', v_bad; END IF;
  SELECT count(*) INTO v_bad FROM _ls_bbf b WHERE EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests m ON m.id = mv.manifest_id
                                                           WHERE mv.visit_id = b.id AND m.deleted_at IS NULL);
  IF v_bad <> 0 THEN RAISE EXCEPTION 'B2: % candidates have a live manifest', v_bad; END IF;

  UPDATE public.visits v SET derm_required = false FROM _ls_bbf b WHERE v.id = b.id AND v.deleted_at IS NULL
     AND v.visit_status = 'scheduled' AND v.visit_date >= today
     AND v.derm_required IS TRUE AND v.derm_required_locked IS NOT TRUE
     AND public.fn_visit_requires_derm(v.id) IS FALSE;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> v_pre THEN RAISE EXCEPTION 'B2: updated % rows, expected %', v_n, v_pre; END IF;

  SELECT count(*) INTO v_bad FROM public.visits v WHERE v.deleted_at IS NULL AND v.visit_status = 'scheduled' AND v.visit_date >= today
     AND v.derm_required IS TRUE AND v.derm_required_locked IS NOT TRUE AND public.fn_visit_requires_derm(v.id) IS FALSE;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'B2: % pending visits still TRUE while deriving FALSE', v_bad; END IF;
  SELECT count(*) INTO v_bad FROM _ls_bsnap s JOIN public.visits v ON v.id = s.id
   WHERE (v.derm_required IS DISTINCT FROM s.s0 AND s.id NOT IN (SELECT id FROM _ls_bbf))
      OR v.derm_required_locked IS DISTINCT FROM s.lk0 OR v.sync_state IS DISTINCT FROM s.sync0;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'B2: % visits changed stored value, lock or sync_state beyond the candidates', v_bad; END IF;
  IF (SELECT count(*) FROM net.http_request_queue) <> (SELECT q_n FROM _ls_bq0) THEN
    RAISE EXCEPTION 'B2: the backfill queued an HTTP call (a Jobber push?)'; END IF;
  SELECT count(*) INTO v_bad FROM (SELECT v.job_id, bool_or(public.fn_line_item_requires_derm(li.name)) AS gen
      FROM public.visits v JOIN _ls_bbf b USING (id) JOIN public.line_items li ON li.job_id = v.job_id AND li.name IS NOT NULL
     GROUP BY v.job_id) x WHERE x.gen IS NOT FALSE;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'B2: % backfilled jobs would still generate DERM-required visits', v_bad; END IF;
  RAISE NOTICE 'B2: % pending lift station visits set derm_required = false: %', v_n, (SELECT string_agg(id::text, ',' ORDER BY id) FROM _ls_bbf);
END $bf$;
COMMIT;

-- PART C (call 3, read-only, after both commits)
DO $post$
DECLARE n int; n_ctl int; v_id bigint; t text;
BEGIN
  -- the Field Portal shows every completed, client-set lift station visit; nothing not-required outside the two rules
  SELECT count(*), count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM customer.work_orders w WHERE w.id = v.public_id))
    INTO n_ctl, n FROM public.visits v
   WHERE v.visit_status = 'completed' AND v.client_id IS NOT NULL AND v.deleted_at IS NULL
     AND EXISTS (SELECT 1 FROM public.v_visit_lift_station_pumping l WHERE l.visit_id = v.id);
  IF n_ctl < 30 THEN RAISE EXCEPTION 'C control: only % completed lift station visits (39 measured 2026-10-12)', n_ctl; END IF;
  IF n <> 0 THEN RAISE EXCEPTION 'C: % completed lift station visits are missing from the Field Portal: run the rollback', n; END IF;
  SELECT count(*) INTO n FROM customer.work_orders w JOIN public.visits v ON v.public_id = w.id
   WHERE v.derm_required IS FALSE
     AND NOT EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping g WHERE g.visit_id = v.id)
     AND NOT EXISTS (SELECT 1 FROM public.v_visit_lift_station_pumping l WHERE l.visit_id = v.id);
  IF n <> 0 THEN RAISE EXCEPTION 'C: % not-required visits outside the two rules are in the Field Portal: run the rollback', n; END IF;
  -- the client path (DEFINER RPC), token resolved at run time and never written down
  SELECT v.id, v.public_id INTO v_id, t FROM public.visits v
   WHERE v.visit_status = 'completed' AND v.deleted_at IS NULL AND v.derm_required IS FALSE AND v.client_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.v_visit_lift_station_pumping l WHERE l.visit_id = v.id)
     AND NOT EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping g WHERE g.visit_id = v.id)
     AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests m ON m.id = mv.manifest_id AND m.deleted_at IS NULL WHERE mv.visit_id = v.id)
   ORDER BY v.id LIMIT 1;
  IF t IS NULL THEN RAISE EXCEPTION 'C control: no not-required lift station visit to open'; END IF;
  IF customer.get_work_order(t) IS NULL OR customer.get_work_order(t)->'work_order'->>'derm_required' IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'C: visit % has no client work order or it does not read derm_required = false', v_id; END IF;
  -- picker offers them, as the DERM Tracker reads it; the DUMP list holds no not-required visit
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM public.manifest_pickable_visits p WHERE p.visit_id = v_id;
  EXECUTE 'RESET ROLE';
  IF n <> 1 THEN RAISE EXCEPTION 'C: visit % is not offerable in the picker as authenticated', v_id; END IF;
  SELECT count(*) INTO n FROM public.dump_outstanding_visits o JOIN public.visits v ON v.id = o.visit_id WHERE v.derm_required IS FALSE;
  IF n <> 0 THEN RAISE EXCEPTION 'C: % not-required visits are on the DUMP outstanding list', n; END IF;
  -- nothing pending left behind, and the GDO reporting check stays empty
  SELECT count(*) INTO n FROM public.visits v WHERE v.deleted_at IS NULL AND v.visit_status = 'scheduled'
     AND v.visit_date >= (now() AT TIME ZONE 'America/New_York')::date
     AND v.derm_required IS TRUE AND v.derm_required_locked IS NOT TRUE AND public.fn_visit_requires_derm(v.id) IS FALSE;
  IF n <> 0 THEN RAISE EXCEPTION 'C: % pending visits TRUE while deriving FALSE: resend PART B2', n; END IF;
  IF EXISTS (SELECT 1 FROM public.v_gdo_reporting_derm_mismatch) THEN RAISE EXCEPTION 'C: v_gdo_reporting_derm_mismatch is not empty'; END IF;
  RAISE NOTICE 'C passed: % completed lift station visits all in the Field Portal; sample visit % opens', n_ctl, v_id;
END $post$;
