-- ============================================================================
-- 2026-11-03_rollback_fp_gdo_report_on_expired_permit  Undo 2026-11-03_1600 (customer.gdo_reports back to ACTIVE only)
-- ============================================================================
-- The reverse anchored edit, pinned on the post-1600 body; VERIFY: the pre-1600 md5 (300a01f7c0eefad6a24f16f039d7fac9)
-- and no EXPIRED permit left in the view. Rehearsed on top of the forward file, rolled back.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path = public, extensions;

DO $gr$
DECLARE
  d text := pg_get_viewdef('customer.gdo_reports'::regclass, true);
  n text;
  a1 text := $a$ JOIN gdos g ON g.client_id = v.client_id AND (g.status = ANY (ARRAY['ACTIVE'::text, 'EXPIRED'::text])) AND g.gdo_number ~ '^GDO-[0-9]+$'::text$a$;
  b1 text := $b$ JOIN gdos g ON g.client_id = v.client_id AND g.status = 'ACTIVE'::text AND g.gdo_number ~ '^GDO-[0-9]+$'::text$b$;
  a2 text := $a$WHERE v.deleted_at IS NULL AND fn_visit_is_gdo_reporting(v.id) AND (g.status = 'ACTIVE'::text OR s.id IS NOT NULL);$a$;
  b2 text := $b$WHERE v.deleted_at IS NULL AND fn_visit_is_gdo_reporting(v.id);$b$;
BEGIN
  IF (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 OR (length(d) - length(replace(d, a2, ''))) / length(a2) <> 1 THEN
    RAISE EXCEPTION 'gdo_reports rollback: the 1600 body is not there (anchors missing)'; END IF;
  n := replace(replace(d, a1, b1), a2, b2);
  EXECUTE 'CREATE OR REPLACE VIEW customer.gdo_reports AS ' || n;
  IF md5(pg_get_viewdef('customer.gdo_reports'::regclass, true)) <> '300a01f7c0eefad6a24f16f039d7fac9' THEN
    RAISE EXCEPTION 'VERIFY gdo_reports rollback: not the pre-1600 body'; END IF;
  IF EXISTS (SELECT 1 FROM customer.gdo_reports r JOIN public.gdos g ON g.id = r.gdo_id WHERE g.status <> 'ACTIVE') THEN
    RAISE EXCEPTION 'VERIFY gdo_reports rollback: a non-ACTIVE permit is still in the view'; END IF;
END $gr$;

COMMENT ON VIEW customer.gdo_reports IS
  'One row per (visit, ACTIVE GDO permit). Per-permit since 2026-08-24: the previous body took a single submission per VISIT and ignored gdo_id, so a multi-permit visit showed one permit''s confirmation next to a visit-wide reported=false. Never returns screenshot_path; the customer portal is anon and evidence is signed server-side.';

COMMIT;
