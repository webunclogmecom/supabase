-- ============================================================================
-- 2026-08-19 17:25 ET  "Our record" for a visit that has no filing yet
-- ============================================================================
-- The GDO Online Report card shows an "Our record" panel: the values WE hold for the visit, which
-- are the values a person types into the Miami-Dade portal. Today that panel only exists once a
-- filing exists, because it is carried by derm.visit_gdo_report, which is one row per submission.
--
-- Whoever files by hand needs those values BEFORE there is a submission - that is the whole point
-- of the empty state. So the same columns are exposed keyed on the visit alone.
--
-- WHY A NEW derm.* VIEW RATHER THAN GRANTING public.v_derm_portal_fields: the app reads derm.*
-- and holds no grant on that public view (measured: postgres, service_role and yannick_readonly
-- only). Granting it directly would widen a public-schema object for one app panel; a derm view
-- keeps the app surface where the app's surface already lives.
--
-- ⚠ THIS VIEW CAN RETURN MORE THAN ONE ROW PER VISIT, AND THAT IS NOT A BUG. A property with two
-- GDO permits produces two rows - visit 6617 has two permits at one address, which is why its card
-- already fans out to ten rows through visit_gdo_report (5 submissions x 2 permits). The UI must
-- render one block per row rather than assuming .single(), or it will either crash or silently show
-- one permit and hide the other. The wider multi-GDO question is an open item for Fred; this view
-- must not pretend to resolve it by picking a winner.
--
-- No new data is disclosed: derm.visit_gdo_report already exposes exactly these columns to
-- authenticated, just filtered to visits that have a submission.
-- ============================================================================

BEGIN;
SET LOCAL search_path = public, pg_catalog;

CREATE OR REPLACE VIEW derm.visit_gdo_our_record AS
 SELECT f.visit_id,
        f.manifest_id,
        f.gdo_id,
        f.client_code,
        f.client_name,
        f.address,
        f.city,
        f.zip,
        f.county,
        f.gdo_number,
        f.visit_date,
        f.ticket_number,
        f.jurisdiction,
        f.dump_ticket_date,
        f.disposal_facility
   FROM public.v_derm_portal_fields f;

GRANT SELECT ON derm.visit_gdo_our_record TO authenticated, service_role;

COMMIT;
