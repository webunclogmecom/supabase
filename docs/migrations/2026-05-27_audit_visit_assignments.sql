-- 2026-05-27_audit_visit_assignments.sql
-- Opt-in audit per CLAUDE.md rule 8 (audit-trail standing check).
-- Triggered now because the Visit Calendar app is about to make visit_assignments
-- human-editable (Driver dropdown writes here via DELETE + INSERT).
-- Reason for opt-in: assignments are user-editable, drive payroll attribution
-- and "who-drove-what" reporting, and were previously untracked.

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'audit_visit_assignments'
      AND tgrelid = 'public.visit_assignments'::regclass
  ) THEN
    CREATE TRIGGER audit_visit_assignments
      AFTER INSERT OR UPDATE OR DELETE ON public.visit_assignments
      FOR EACH ROW EXECUTE FUNCTION audit.log_change();
  END IF;
END $$;
