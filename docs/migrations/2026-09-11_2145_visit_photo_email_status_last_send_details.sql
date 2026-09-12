-- 2026-09-11 21:45 ET · public.v_visit_photo_email_status: what the last successful send carried
--
-- Fred, 2026-09-11 (city-email rework): "when we send an email to the city we can select to send it
-- with or without the classified photos so the automatic email should follow the same selection".
-- The Admin Review "Email to the City" block therefore has to SHOW that selection next to the
-- date and the sender, or an operator cannot tell what the automatic email is about to copy.
--
-- Appends four columns at the END of public.v_visit_photo_email_status, all taken from the SAME
-- row as last_sent_at (newest status='sent'), so they can never describe a different send:
--   last_sent_include_photos   boolean  NULL on rows older than 2026-08-20 (column added later)
--   last_sent_include_manifest boolean  NULL on rows older than 2026-08-2x (same reason)
--   last_sent_is_test          boolean
--   last_sent_photo_count      integer
--
-- ⚠ last_photo_count (existing) is the newest attempt of ANY status, like last_sent_by. Neither is
--    changed here and neither should be used for the block. The comment already says so for
--    last_sent_by; it now says so for last_photo_count too.
-- ⚠ Column order: appended at the end only. CREATE OR REPLACE VIEW refuses a reorder, and the
--    Admin Review app selects '*' from this view (see Building Apps/Admin Review/docs/11-city-email.md).
-- Body copied from pg_get_viewdef on 2026-09-11 21:39 ET, not retyped. Verified in a rolled-back
-- dry run: every pre-existing column identical on all rows (EXCEPT ALL both directions), the four
-- new columns equal to a direct correlated read of visit_photo_email_sends on all 62 log rows.

begin;

create or replace view public.v_visit_photo_email_status as
 WITH agg AS (
         SELECT s.visit_id,
            count(*) AS send_count,
            count(*) FILTER (WHERE s.status = 'sent'::text) AS sent_count,
            max(s.sent_at) FILTER (WHERE s.status = 'sent'::text) AS last_sent_at,
            max(s.sent_at) FILTER (WHERE s.status = 'sent'::text AND s.is_test = false) AS last_real_sent_at,
            (array_agg(s.status ORDER BY s.sent_at DESC))[1] AS last_status,
            (array_agg(s.reason ORDER BY s.sent_at DESC))[1] AS last_reason,
            (array_agg(s.sent_by_email ORDER BY s.sent_at DESC))[1] AS last_sent_by,
            (array_agg(s.photo_count ORDER BY s.sent_at DESC))[1] AS last_photo_count,
            (array_agg(s.sent_by_email ORDER BY s.sent_at DESC) FILTER (WHERE s.status = 'sent'::text))[1] AS last_sent_by_success_email,
            (array_agg(s.include_photos ORDER BY s.sent_at DESC) FILTER (WHERE s.status = 'sent'::text))[1] AS last_sent_include_photos,
            (array_agg(s.include_manifest ORDER BY s.sent_at DESC) FILTER (WHERE s.status = 'sent'::text))[1] AS last_sent_include_manifest,
            (array_agg(s.is_test ORDER BY s.sent_at DESC) FILTER (WHERE s.status = 'sent'::text))[1] AS last_sent_is_test,
            (array_agg(s.photo_count ORDER BY s.sent_at DESC) FILTER (WHERE s.status = 'sent'::text))[1] AS last_sent_photo_count
           FROM visit_photo_email_sends s
          GROUP BY s.visit_id
        )
 SELECT a.visit_id,
    a.send_count,
    a.sent_count,
    a.last_sent_at,
    a.last_real_sent_at,
    a.last_status,
    a.last_reason,
    a.last_sent_by,
    a.last_photo_count,
    a.last_sent_by_success_email,
    COALESCE(e.full_name, a.last_sent_by_success_email) AS last_sent_by_name,
    a.last_sent_include_photos,
    a.last_sent_include_manifest,
    a.last_sent_is_test,
    a.last_sent_photo_count
   FROM agg a
     LEFT JOIN LATERAL ( SELECT emp.full_name
           FROM employees emp
          WHERE a.last_sent_by_success_email IS NOT NULL AND lower(btrim(emp.email)) = lower(btrim(a.last_sent_by_success_email))
          ORDER BY emp.id
         LIMIT 1) e ON true;

comment on view public.v_visit_photo_email_status is
  'Per-visit city-email status. last_sent_at, last_sent_by_name, last_sent_include_photos, '
  'last_sent_include_manifest, last_sent_is_test and last_sent_photo_count all describe the SAME '
  'row, the newest status=sent. last_sent_by and last_photo_count are the newest attempt of ANY '
  'status and can describe a different send; do not pair them with last_sent_at.';

commit;
