-- ============================================================================
-- 2026-11-03_1600_fp_gdo_report_on_expired_permit  The Field Portal shows a GDO report filed on an EXPIRED permit
-- ============================================================================
-- THE ASK
--   Trello ObKqzi47 (Plan A, last item: "First real button filing shows on its visit in the DERM Tracker and the Field
--   Portal"). The first real "File it with the bot" filing, visit 7849 (2026-10-30, permit GDO-14098, county SUCCESS),
--   shows in the DERM Tracker but NOT in the Field Portal. Fred, 2026-10-30: "even if it's expired or not that's the one
--   we have so we file it with that expired one" (2026-10-30_1135 / _1148 widened the bot side, v_derm_portal_fields, to
--   ACTIVE and EXPIRED); this customer view kept ACTIVE only, so every filing on an expired permit is hidden from the
--   client. Fred, 2026-11-03 (AskUserQuestion): "Show it when filed": an expired permit appears on the visit only when a
--   report was filed on it; an expired permit with nothing filed stays hidden (customer apps hide what we do not have).
-- WHAT CHANGES (anchored edit of the live view body, md5 300a01f7c0eefad6a24f16f039d7fac9)
--   customer.gdo_reports joins ACTIVE and EXPIRED GDO permits, and keeps an EXPIRED one only when it has a filing on the
--   visit (the view's own lateral `s`: SUCCESS or a portal confirmation, not a dry run). INACTIVE permits stay out; the
--   GDO-only number filter stays (permits one table, 2026-11-02). Same columns, owner, grants; comment updated.
-- REACH (measured 2026-11-03): the view goes from 228 to 230 rows: (7849, GDO-14098) and (7992, GDO-14098), both 315-CAP,
--   both filed SUCCESS on 2026-10-30. Every other row is byte-identical (VERIFY). Readers: the Field Portal visit page and
--   customer.get_work_order(_internal) (which the DERM visit report uses).
-- NOT CHANGED: customer.permits and customer.clients also list ACTIVE permits only (the portal's "Permits & Frequency");
--   whether a client sees an expired permit there is a separate question, not this card.
-- VERIFY: the edits landed once; rows = before + exactly those 2, reported; the old rows identical; no EXPIRED row without
--   a filing; owner, grants and options unchanged; get_work_order for 7849 now carries GDO-14098.
-- REHEARSED: (a) as written; (c) the md5 PIN altered raises; the rollback on top restores the md5 and the 228-row hash.
-- LOCKS: CREATE OR REPLACE VIEW takes an exclusive lock on a view the portal reads: lock_timeout 3s, a short transaction,
--   applied clear of the backup (:17 on even UTC hours) and of :30 to :45.
-- ROLLBACK: docs/migrations/2026-11-03_rollback_fp_gdo_report_on_expired_permit.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path = public, extensions;

CREATE TEMP TABLE _gr_before ON COMMIT DROP AS SELECT to_jsonb(r) AS j FROM customer.gdo_reports r;
CREATE TEMP TABLE _gr_ctx ON COMMIT DROP AS SELECT
  (SELECT relacl::text FROM pg_class WHERE oid = 'customer.gdo_reports'::regclass) AS acl,
  (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'customer.gdo_reports'::regclass) AS owner,
  (SELECT reloptions FROM pg_class WHERE oid = 'customer.gdo_reports'::regclass) AS opts;

DO $gr$
DECLARE
  d text := pg_get_viewdef('customer.gdo_reports'::regclass, true);
  n text;
  a1 text := $a$ JOIN gdos g ON g.client_id = v.client_id AND g.status = 'ACTIVE'::text AND g.gdo_number ~ '^GDO-[0-9]+$'::text$a$;
  b1 text := $b$ JOIN gdos g ON g.client_id = v.client_id AND (g.status = ANY (ARRAY['ACTIVE'::text, 'EXPIRED'::text])) AND g.gdo_number ~ '^GDO-[0-9]+$'::text$b$;
  a2 text := $a$WHERE v.deleted_at IS NULL AND fn_visit_is_gdo_reporting(v.id);$a$;
  b2 text := $b$WHERE v.deleted_at IS NULL AND fn_visit_is_gdo_reporting(v.id) AND (g.status = 'ACTIVE'::text OR s.id IS NOT NULL);$b$;
BEGIN
  IF md5(d) <> '300a01f7c0eefad6a24f16f039d7fac9' THEN RAISE EXCEPTION 'gdo_reports: not the expected body (md5 %)', md5(d); END IF;
  IF (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 THEN RAISE EXCEPTION 'gdo_reports: the join anchor is not there exactly once'; END IF;
  IF (length(d) - length(replace(d, a2, ''))) / length(a2) <> 1 THEN RAISE EXCEPTION 'gdo_reports: the where anchor is not there exactly once'; END IF;
  n := replace(replace(d, a1, b1), a2, b2);
  EXECUTE 'CREATE OR REPLACE VIEW customer.gdo_reports AS ' || n;
END $gr$;

COMMENT ON VIEW customer.gdo_reports IS
  'One row per (visit, GDO permit): every ACTIVE permit, and an EXPIRED permit only when a report was filed on it for that visit (2026-11-03_1600, Fred: "Show it when filed"; the bot files an expired permit when it is the one we have, 2026-10-30). Per-permit since 2026-08-24. Never returns screenshot_path; evidence is signed server-side.';

DO $v$
DECLARE n_before int; n_after int; added jsonb; bad int; wo jsonb;
BEGIN
  SELECT count(*) INTO n_before FROM _gr_before;
  SELECT count(*) INTO n_after FROM customer.gdo_reports;
  SELECT jsonb_agg(jsonb_build_object('visit', r.visit_id, 'gdo', r.gdo_number, 'reported', r.reported) ORDER BY r.visit_id) INTO added
    FROM customer.gdo_reports r WHERE NOT EXISTS (SELECT 1 FROM _gr_before b WHERE b.j = to_jsonb(r));
  IF added IS DISTINCT FROM '[{"gdo": "GDO-14098", "visit": 7849, "reported": true}, {"gdo": "GDO-14098", "visit": 7992, "reported": true}]'::jsonb THEN
    RAISE EXCEPTION 'VERIFY gdo_reports: the new rows are %, expected 7849 and 7992 on GDO-14098, reported', added; END IF;
  IF n_after <> n_before + 2 THEN RAISE EXCEPTION 'VERIFY gdo_reports: % rows, expected % + 2', n_after, n_before; END IF;
  SELECT count(*) INTO bad FROM _gr_before b WHERE NOT EXISTS (SELECT 1 FROM customer.gdo_reports r WHERE to_jsonb(r) = b.j);
  IF bad > 0 THEN RAISE EXCEPTION 'VERIFY gdo_reports: % earlier rows changed or left', bad; END IF;
  SELECT count(*) INTO bad FROM customer.gdo_reports r JOIN public.gdos g ON g.id = r.gdo_id WHERE g.status = 'EXPIRED' AND NOT r.reported;
  IF bad > 0 THEN RAISE EXCEPTION 'VERIFY gdo_reports: % expired permits shown with nothing filed', bad; END IF;
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'customer.gdo_reports'::regclass) IS DISTINCT FROM (SELECT acl FROM _gr_ctx)
     OR (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'customer.gdo_reports'::regclass) IS DISTINCT FROM (SELECT owner FROM _gr_ctx)
     OR (SELECT reloptions FROM pg_class WHERE oid = 'customer.gdo_reports'::regclass) IS DISTINCT FROM (SELECT opts FROM _gr_ctx) THEN
    RAISE EXCEPTION 'VERIFY gdo_reports: owner, grants or options changed'; END IF;
  wo := to_jsonb(customer.get_work_order((SELECT public_id FROM public.visits WHERE id = 7849)));
  IF position('GDO-14098' in coalesce(wo::text, '')) = 0 THEN RAISE EXCEPTION 'VERIFY gdo_reports: get_work_order for 7849 does not carry GDO-14098'; END IF;
  RAISE NOTICE 'gdo_reports: % -> % rows, added %', n_before, n_after, added;
END $v$;

COMMIT;
