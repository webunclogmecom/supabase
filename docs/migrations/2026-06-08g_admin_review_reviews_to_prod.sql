-- ============================================================================
-- 2026-06-08g — Move Admin Review's review/bonus data to Prod canonical
-- ============================================================================
-- Per Fred 2026-06-08: move the Admin Review app onto Prod. Its review/bonus decisions
-- lived ONLY on Sandbox #1 (app_visit_reviews 18 / app_shift_reviews 2; Prod copies empty,
-- legacy external_* keys, no FKs, unaudited). Audit + plan:
-- docs/audits/2026-06-08_admin_review_db_integration_audit.md.
--
-- This migration (SCHEMA) creates canonical public.visit_reviews / public.shift_reviews
-- (real FKs visit_id->visits / employee_id->employees, CHECK enums, set_updated_at, ADR-010
-- audit, anon-permissive RLS like photo_classifications) and re-points the visits_with_review
-- view onto them (output columns UNCHANGED). The 18+2 rows are copied by the companion script
-- scripts/sync/migrate_admin_reviews_to_prod.js. The legacy app_* tables are KEPT (empty) until
-- the app re-points + a verification window passes, then retired separately. Verified pre-flight:
-- 0 FK orphans, employee 24 present, none soft-deleted.
-- ============================================================================

-- 1) Canonical tables
CREATE TABLE IF NOT EXISTS public.visit_reviews (
  visit_id          bigint PRIMARY KEY REFERENCES public.visits(id) ON DELETE CASCADE,
  review_status     text NOT NULL DEFAULT 'pending' CHECK (review_status = ANY (ARRAY['pending','approved','flagged'])),
  reviewed_at       timestamptz,
  reviewed_by       bigint REFERENCES public.employees(id) ON DELETE SET NULL,
  bonus_status      text NOT NULL DEFAULT 'pending' CHECK (bonus_status = ANY (ARRAY['pending','approved','denied'])),
  bonus_decided_at  timestamptz,
  bonus_decided_by  bigint REFERENCES public.employees(id) ON DELETE SET NULL,
  bonus_denial_note text,
  quality_flag_note text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.shift_reviews (
  employee_id        bigint NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  shift_date         date   NOT NULL,
  review_status      text NOT NULL DEFAULT 'pending' CHECK (review_status = ANY (ARRAY['pending','approved','flagged'])),
  reviewed_at        timestamptz,
  reviewed_by        bigint REFERENCES public.employees(id) ON DELETE SET NULL,
  bonus_status       text NOT NULL DEFAULT 'pending' CHECK (bonus_status = ANY (ARRAY['pending','approved','denied'])),
  bonus_decided_at   timestamptz,
  bonus_decided_by   bigint REFERENCES public.employees(id) ON DELETE SET NULL,
  bonus_denial_note  text,
  shift_quality_note text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (employee_id, shift_date)
);
CREATE INDEX IF NOT EXISTS idx_shift_reviews_employee ON public.shift_reviews(employee_id);

-- 2) updated_at + audit (ADR 010 opt-in: bonus/payroll-affecting + human-edited)
DROP TRIGGER IF EXISTS trg_visit_reviews_updated_at ON public.visit_reviews;
CREATE TRIGGER trg_visit_reviews_updated_at BEFORE UPDATE ON public.visit_reviews FOR EACH ROW EXECUTE FUNCTION set_updated_at();
DROP TRIGGER IF EXISTS trg_shift_reviews_updated_at ON public.shift_reviews;
CREATE TRIGGER trg_shift_reviews_updated_at BEFORE UPDATE ON public.shift_reviews FOR EACH ROW EXECUTE FUNCTION set_updated_at();
DROP TRIGGER IF EXISTS audit_visit_reviews ON public.visit_reviews;
CREATE TRIGGER audit_visit_reviews AFTER INSERT OR UPDATE OR DELETE ON public.visit_reviews FOR EACH ROW EXECUTE FUNCTION audit.log_change();
DROP TRIGGER IF EXISTS audit_shift_reviews ON public.shift_reviews;
CREATE TRIGGER audit_shift_reviews AFTER INSERT OR UPDATE OR DELETE ON public.shift_reviews FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- 3) RLS + grants (anon-permissive write, ship-first — the app upserts via anon like photo_classifications)
ALTER TABLE public.visit_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shift_reviews ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON public.visit_reviews TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.visit_reviews TO authenticated;
GRANT ALL ON public.visit_reviews TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.shift_reviews TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shift_reviews TO authenticated;
GRANT ALL ON public.shift_reviews TO service_role;

DROP POLICY IF EXISTS visit_reviews_anon_select ON public.visit_reviews;  CREATE POLICY visit_reviews_anon_select  ON public.visit_reviews FOR SELECT TO anon          USING (true);
DROP POLICY IF EXISTS visit_reviews_anon_insert ON public.visit_reviews;  CREATE POLICY visit_reviews_anon_insert  ON public.visit_reviews FOR INSERT TO anon          WITH CHECK (true);
DROP POLICY IF EXISTS visit_reviews_anon_update ON public.visit_reviews;  CREATE POLICY visit_reviews_anon_update  ON public.visit_reviews FOR UPDATE TO anon          USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS visit_reviews_auth_all    ON public.visit_reviews;  CREATE POLICY visit_reviews_auth_all     ON public.visit_reviews FOR ALL    TO authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS visit_reviews_service_all ON public.visit_reviews;  CREATE POLICY visit_reviews_service_all  ON public.visit_reviews FOR ALL    TO service_role  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS shift_reviews_anon_select ON public.shift_reviews;  CREATE POLICY shift_reviews_anon_select  ON public.shift_reviews FOR SELECT TO anon          USING (true);
DROP POLICY IF EXISTS shift_reviews_anon_insert ON public.shift_reviews;  CREATE POLICY shift_reviews_anon_insert  ON public.shift_reviews FOR INSERT TO anon          WITH CHECK (true);
DROP POLICY IF EXISTS shift_reviews_anon_update ON public.shift_reviews;  CREATE POLICY shift_reviews_anon_update  ON public.shift_reviews FOR UPDATE TO anon          USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS shift_reviews_auth_all    ON public.shift_reviews;  CREATE POLICY shift_reviews_auth_all     ON public.shift_reviews FOR ALL    TO authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS shift_reviews_service_all ON public.shift_reviews;  CREATE POLICY shift_reviews_service_all  ON public.shift_reviews FOR ALL    TO service_role  USING (true) WITH CHECK (true);

-- 4) Re-point visits_with_review onto the canonical table (output columns UNCHANGED;
--    only the join target swaps app_visit_reviews(external_visit_id) -> visit_reviews(visit_id))
CREATE OR REPLACE VIEW public.visits_with_review AS
 SELECT v.id, v.client_id, v.property_id, v.job_id, v.vehicle_id, v.visit_date, v.start_at, v.end_at,
    v.completed_at, v.duration_minutes, v.title, v.service_type, v.visit_status, v.actual_arrival_at,
    v.actual_departure_at, v.is_gps_confirmed, v.created_at, v.updated_at, v.invoice_id, v.completed_by,
    COALESCE(vr.review_status, 'pending'::text) AS review_status,
    vr.reviewed_at,
    vr.reviewed_by,
    COALESCE(vr.bonus_status, 'pending'::text) AS bonus_status,
    vr.bonus_decided_at,
    vr.bonus_decided_by,
    vr.bonus_denial_note,
    vr.quality_flag_note
   FROM public.visits v
     LEFT JOIN public.visit_reviews vr ON vr.visit_id = v.id;
