-- 2026-06-02 — derm_manifests: make (client_id, white/yellow number) uniqueness apply to LIVE rows only.
--
-- Why: the two unique constraints were FULL unique indexes, so a soft-deleted manifest
-- (deleted_at IS NOT NULL) kept occupying its (client_id, number) slot forever — you could
-- not re-file a number after soft-deleting its manifest (INSERT failed with 23505 on the dead row).
-- Fred-approved fix (option A): soft-delete should FREE the slot. Swap the full unique constraints
-- for PARTIAL unique indexes (WHERE deleted_at IS NULL): uniqueness is enforced only among LIVE
-- rows, so two live duplicates are still blocked (DERM rule #10) but a soft-deleted row no longer
-- blocks re-filing. Soft-delete row is kept for audit (rule #7); hard-delete deferred to role-based work.
--
-- Applied from the Building Apps session via the Management API (Fred-approved; Supabase session busy).
-- Pre-change backup: docs/backups/derm_softdelete_views_constraints_backup_2026-06-02.json
-- Safe on existing data: the old full constraint already guaranteed uniqueness across ALL rows,
-- so live rows are a unique subset — the partial indexes build without violation.

BEGIN;

ALTER TABLE public.derm_manifests DROP CONSTRAINT IF EXISTS derm_manifests_client_wm_unique;
CREATE UNIQUE INDEX derm_manifests_client_wm_unique
  ON public.derm_manifests (client_id, white_manifest_number)
  WHERE deleted_at IS NULL;

ALTER TABLE public.derm_manifests DROP CONSTRAINT IF EXISTS derm_manifests_client_yt_unique;
CREATE UNIQUE INDEX derm_manifests_client_yt_unique
  ON public.derm_manifests (client_id, yellow_ticket_number)
  WHERE deleted_at IS NULL;

COMMIT;
