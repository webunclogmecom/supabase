-- 2026-05-27_derm_multipage_and_softdelete.sql
-- Two related additions to public.derm_manifests:
--
-- 1. Multi-page support: some AT DERM records have 2+ pages of attachments
--    (manifest copies + address pages). Webhook-airtable used to only take
--    attachments[0], losing pages 2+. Add TEXT[] columns for the extra pages,
--    keeping the singular *_url columns as page 1 for backward compatibility.
--    Per CLAUDE.md rule 1 (source-agnostic): plain `*_extra_urls` naming, no
--    "airtable" prefix even though that's the origin.
--
-- 2. Soft-delete: DERM Tracker needs a "Delete manifest" action. Per
--    CLAUDE.md rule 6 (no hard-delete on business data), add deleted_at
--    timestamptz. Views/queries downstream filter `deleted_at IS NULL`.
--    Linked manifest_visits rows are NOT cascaded — they become orphans
--    that the UI can flag for re-attachment.
--
-- Audit: derm_manifests is already audited (per CLAUDE.md rule 8). New
-- columns are automatically captured in audit.logs full-row JSONB.

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='derm_manifests'
                   AND column_name='derm_manifest_extra_urls') THEN
    ALTER TABLE public.derm_manifests ADD COLUMN derm_manifest_extra_urls TEXT[] DEFAULT '{}';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='derm_manifests'
                   AND column_name='derm_address_extra_urls') THEN
    ALTER TABLE public.derm_manifests ADD COLUMN derm_address_extra_urls TEXT[] DEFAULT '{}';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='derm_manifests'
                   AND column_name='deleted_at') THEN
    ALTER TABLE public.derm_manifests ADD COLUMN deleted_at TIMESTAMPTZ;
  END IF;
END $$;

-- Helper view used by DERM Tracker /upload to filter the visit picker.
-- Surfaces only completed GT visits that NEED a manifest (derm_required isn't
-- explicitly false) AND don't already have one linked. Keep the JOIN/filter
-- logic centralized so the UI can swap to this view without re-implementing
-- the filter per surface.
CREATE OR REPLACE VIEW public.manifest_pickable_visits AS
  SELECT v.id AS visit_id,
         v.visit_date,
         v.start_at,
         v.completed_at,
         v.service_type,
         v.title,
         c.id AS client_id,
         c.client_code,
         c.name AS client_name,
         COALESCE(p.address, primary_p.address) AS address,
         COALESCE(p.city, primary_p.city) AS city,
         COALESCE(p.county, primary_p.county) AS county
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  LEFT JOIN public.properties p ON p.id = v.property_id
  LEFT JOIN public.properties primary_p
    ON primary_p.client_id = v.client_id AND primary_p.is_primary = true
  WHERE v.visit_status = 'completed'
    AND v.service_type = 'GT'
    AND (v.derm_required IS NULL OR v.derm_required = true)
    AND NOT EXISTS (
      SELECT 1 FROM public.manifest_visits mv
      JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
      WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL
    );

GRANT SELECT ON public.manifest_pickable_visits TO anon, authenticated;
