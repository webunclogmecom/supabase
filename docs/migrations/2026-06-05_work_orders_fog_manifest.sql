-- Wire customer.work_orders to expose the per-client FOG Manifest on the Field
-- Portal. The previously-hidden `NULL::text AS derm_manifest_url` (the FP's "DERM
-- FOG eManifest" slot, blanked because the raw derm_address_url is the full
-- multi-client sheet) now serves derm_manifests.fog_manifest_url — the per-client
-- generated DERM Address (only the workorder's own client facility).
--
-- Rebuilt from the live view definition with 2 surgical string edits so the rest
-- of the large definition is preserved verbatim. CREATE OR REPLACE keeps the
-- view's owner + grants (owner-run, bypasses RLS per the schema-per-app pattern).
DO $$
DECLARE d text;
BEGIN
  SELECT pg_get_viewdef('customer.work_orders'::regclass, true) INTO d;
  -- 1. pull fog_manifest_url into the LATERAL manifest pick
  d := replace(d, 'dm_inner.derm_address_url,', 'dm_inner.derm_address_url, dm_inner.fog_manifest_url,');
  -- 2. expose it as the FP's derm_manifest_url (was NULL)
  d := replace(d, 'NULL::text AS derm_manifest_url', 'dm.fog_manifest_url AS derm_manifest_url');
  EXECUTE 'CREATE OR REPLACE VIEW customer.work_orders AS ' || d;
END $$;
