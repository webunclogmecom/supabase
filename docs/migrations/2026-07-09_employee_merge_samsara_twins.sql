-- 2026-07-09_employee_merge_samsara_twins.sql
-- Merge the Samsara-created employee twins into their Jobber-created canonical rows
-- (Diego confirmed same humans; found by the 2026-07-09 push-safety audit).
--
-- WHY: employees enter from two sources. Jobber sync created 35 'Mark' (Jobber user
-- "Mark Noltion") and 37 'Anthony' (Jobber user "Anthony"). When the same drivers were
-- added to Samsara, webhook-samsara's DriverCreated handler found no employee with a
-- samsara link and CREATED new rows: 36 'Mark noltion' (2026-06-29) and 38 'Anthony
-- Clark' (2026-07-08). Canonical model = Grecia (id 1): ONE employee row carrying BOTH
-- jobber + samsara links (source-agnostic rule #1 — identity in entity_source_links).
-- The twins split each human across two rows: crew pickers showed 4 techs where there
-- are 2, and picking the Samsara twin made the Jobber crew push fail (no Jobber user
-- link — silently pre-2aa8215, loudly since).
--
-- MERGE:
--   1. Move the samsara link 36 -> 35 and 38 -> 37 (plain entity_id UPDATE; PK is
--      (entity_type, source_system, source_id) so no conflict). webhook-samsara resolves
--      drivers via findEntityBySourceId -> future Samsara updates land on 35/37 and the
--      twins are NOT recreated.
--   2. Re-point the single reference: visit_assignments (visit 6835, 168-AVA) 36 -> 35
--      (same human; full 11-FK-column sweep found NOTHING else referencing 36/38).
--   3. Soft-retire 36 + 38 (status='INACTIVE', note; never hard-delete — rule 6).
--
-- NOTES: touches employees / entity_source_links / one visit_assignments row — ZERO
-- visit schedule data, nothing pushes to Jobber (no push trigger on these tables).
-- Cosmetic (matches Grecia's precedent): the next Samsara driver update overwrites the
-- merged row's full_name with Samsara's spelling ("Mark noltion"/"Anthony Clark").
-- employees is audited (ADR 010); writes attributed below (ADR 016).
-- Backup: backups/2026-07-09_employee_merge_3638_backup.json (9 rows).
-- Reversal: restore links' entity_id to 36/38, visit_assignments row to 36, status ACTIVE.

BEGIN;
SELECT set_config('request.headers', '{"x-app-source":"employee-dedup-merge"}', true);

-- 1) move the samsara identities onto the canonical rows
UPDATE entity_source_links SET entity_id = 35
 WHERE entity_type='employee' AND source_system='samsara' AND entity_id = 36;
UPDATE entity_source_links SET entity_id = 37
 WHERE entity_type='employee' AND source_system='samsara' AND entity_id = 38;

-- 2) re-point the single reference (visit 6835 assignment; same human)
UPDATE visit_assignments SET employee_id = 35 WHERE employee_id = 36;

-- 3) soft-retire the twins
UPDATE employees SET status='INACTIVE',
  notes = coalesce(notes||' | ','') || 'merged into employee 35 (Mark) 2026-07-09 — Samsara twin, Diego-confirmed same person'
 WHERE id = 36;
UPDATE employees SET status='INACTIVE',
  notes = coalesce(notes||' | ','') || 'merged into employee 37 (Anthony) 2026-07-09 — Samsara twin, Diego-confirmed same person'
 WHERE id = 38;

COMMIT;
