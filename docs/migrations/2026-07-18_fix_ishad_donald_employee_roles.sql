-- 2026-07-18 — correct Ishad Knight & Donald Barron employee.role (Fred)
--
-- WHY: the 2026-07-17 driver audit surfaced two mislabeled (now-inactive) employees. Evidence:
--   * Ishad Knight (id 8) was role='Office' but is a REAL field driver — 55 PRE/POST inspections,
--     GPS/inspection-confirmed driving the Moises truck through 2026-06-19, completed 48 visits.
--     -> role Office -> Technician.
--   * Donald Barron (id 33) was role='Technician' but shows NO driving: 0 inspections ever, 0
--     GPS-confirmed drives, and on 15 of his 26 solo-assigned visits a DIFFERENT person inspected the
--     truck (someone else drove). He appeared on 53 crews + marked 33 visits complete = dispatch/office
--     activity, not driving. Fred confirmed 2026-07-18: Office / dispatch. -> role Technician -> Office.
-- Both are already status='INACTIVE' (last activity June 2026, nothing since; kept per Fred "inactive now").
--
-- IMPACT: role on an INACTIVE employee is documentation only — neither appears in the active-driver
-- picker (which filters status='ACTIVE'). No functional/app change; corrects the records.
--
-- AUDIT (ADR-010): employees is audited; these 2 UPDATEs are captured (app_source='sql').
-- BACKUP / ROLLBACK: backups/2026-07-18_employee_roles_before.json (pre-change role/status per id).

UPDATE public.employees SET role = 'Technician' WHERE id = 8  AND role = 'Office';
UPDATE public.employees SET role = 'Office'     WHERE id = 33 AND role = 'Technician';
