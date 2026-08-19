-- ============================================================================
-- 2026-08-19  photo_links: close the approval-proof forgery hole
-- ============================================================================
-- WHY. docs/audits/2026-08-19_approval_proof_image_architecture_audit.md found that the
-- approval-proof RECORD is forgeable from a browser even though the storage bucket is
-- sealed. `authenticated` holds INSERT on public.photo_links, the INSERT policy checks
-- only `auth.uid() IS NOT NULL`, and fn_photo_link_target_exists validates
-- entity_type='visit' ONLY. So a signed-in staff browser can POST
--   {entity_type:'job_frequency_change', entity_id:<any>, role:'approval_proof'}
-- and client.job_frequency_changes.proof_count -- which is exactly
--   count(*) ... where entity_type='job_frequency_change' and role='approval_proof'
--   and deleted_at is null
-- -- counts it. No image, no mime/size check, no 3-image cap, no client-ownership check,
-- and `caption` (the documented author field) is caller-chosen. The feature is defeated
-- against precisely the person it exists to hold accountable.
--
-- 🛑 THE AUDIT'S OWN RECOMMENDATION WAS TOO BROAD AND IS DELIBERATELY NOT FOLLOWED.
-- It said "revoke INSERT on photo_links from authenticated". Measured first, per the
-- CLAUDE.md rule to check audit.logs BEFORE revoking a grant that looks unused:
--   app_source='admin-review'  6 INSERTs, ALL entity_type='visit'   <- a LIVE browser feature
--   app_source='client-app'    9 INSERTs, all job_frequency_change  <- via save-client-job,
--                                                                      which uses the SERVICE ROLE
--   app_source='sql'         488 INSERTs (crons, scripts, backfills)
-- A blanket revoke would have broken Admin Review's "Add image", which is documented as a
-- deliberate app write path (2026-08-14_1400_photos_insert_policy_for_app_upload.sql).
-- So: keep the grant, refuse the DANGEROUS SHAPE only.
--
-- WHAT THIS CHANGES
--   1. The INSERT policy for `authenticated` additionally refuses
--      entity_type='job_frequency_change' OR role='approval_proof'.
--      service_role is untouched, so save-client-job keeps working unchanged.
--   2. fn_photo_link_target_exists also validates job_frequency_change targets, closing the
--      dangling-link class that 2026-08-18_1450 repaired for visits and left open here.
--      🛑 Body COPIED from pg_get_functiondef and extended; the visit branch is byte-identical.
--
-- WHAT THIS DOES NOT FIX (recorded so nobody assumes the audit is closed):
--   * "Remove proof" still leaves the storage object and the public.photos row behind.
--   * public.photos still has no audit trigger, no soft-delete and no content hash.
--   * EXIF stripping is still browser-only.
--   * There is still no permit gate on cadence.
--
-- RULE 8 (audit): photo_links already carries audit_photo_links -> audit.log_change.
-- No trigger work needed; this migration adds a validation trigger function, not an audit one.
-- ============================================================================

BEGIN;
SET LOCAL search_path = public, pg_catalog;

-- 1. the guard trigger, extended -------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_photo_link_target_exists()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.entity_type = 'visit' then
    if not exists (select 1 from public.visits v
                    where v.id = new.entity_id and v.deleted_at is null) then
      raise exception 'photo_links: visit % does not exist or is soft-deleted', new.entity_id
        using errcode = '23503';
    end if;
  elsif new.entity_type = 'job_frequency_change' then
    -- added 2026-08-19. Same class the visit branch closes: a link must not point at a
    -- record that does not exist. Three job_frequency_changes rows have already been deleted.
    if not exists (select 1 from public.job_frequency_changes f
                    where f.id = new.entity_id) then
      raise exception 'photo_links: job_frequency_change % does not exist', new.entity_id
        using errcode = '23503';
    end if;
  end if;
  return new;
end
$function$;

-- 2. the INSERT policy, narrowed for authenticated ONLY --------------------------
DROP POLICY IF EXISTS "Authenticated insert photo_links" ON public.photo_links;
CREATE POLICY "Authenticated insert photo_links"
  ON public.photo_links
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (select auth.uid()) IS NOT NULL
    -- 🛑 approval proof is COMPLIANCE EVIDENCE and may only be created by the edge
    -- function (service_role), which validates mime, size, the 3-image cap, the staff
    -- domain and client ownership. A browser must not be able to assert it.
    AND entity_type IS DISTINCT FROM 'job_frequency_change'
    AND coalesce(role, '') IS DISTINCT FROM 'approval_proof'
  );

COMMIT;
