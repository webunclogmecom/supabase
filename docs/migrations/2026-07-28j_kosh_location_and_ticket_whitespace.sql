-- ============================================================================
-- 2026-07-28j — (1) Kosh visit_locations repair  (2) ticket 831102 whitespace
-- ============================================================================
-- PART 1 — 150-KOS "Kosh" visits pointed at the NEIGHBOUR's location.
-- Fred verified in Jobber: 150-KOS is "9477 Harding Avenue, Surfside, Florida
-- 33154", NOT 9467. Visits 1402 (2026-02-18) and 1773 (2026-04-23) were linked
-- via visit_locations to client_location 9 = "9467 Harding Avenue", which belongs
-- to a DIFFERENT client, 025-GRO Grove Kosher LLC.
--
-- Why it mattered: public.fn_resolve_gdo_id resolves the permit from the visit's
-- LOCATION (2026-07-28g/h), so both visits resolved to 025-GRO's GDO-13447 instead
-- of Kosh's own GDO-01958 (registered at 9477 Harding Avenue). That is another
-- client's permit number on a DERM compliance form. Found by the cross-client
-- guard while shipping 2026-07-28i, confirmed against Jobber by Fred.
--
-- Repointed to Kosh's OWN location, client_location 260 ("Main", client 336).
-- Both visits are completed and historical, and the filed manifests (tickets
-- 817533 and 822621) are unchanged: this corrects which permit our surfaces
-- REPORT, it does not alter a document already sent to the city.
--
-- Deliberately NOT touched: the other cross-client pair, 144-LTG -> 139-LTG
-- location 155. Those two client records share ONE address (17070 West Dixie
-- Highway), so the permit really is that location's permit and the link is
-- correct. Only the Kosh pair is a genuine mis-link.
--
-- PART 2 — ticket "831102" carries a LEADING SPACE in three places.
-- Fred: "remove the space to ticket-831102 and check if we have others like that".
-- A full scan of the DERM key columns found this ticket and no other:
--   derm.address_row_map.dump_folder            'ticket- 831102'  5 rows
--   derm.address_row_map.white_manifest_number  ' 831102'         5 rows
--   public.derm_manifests.white_manifest_number ' 831102'         5 rows
-- Pre-flight verified no clean '831102' exists, so this is a pure rename with no
-- merge and no ticket-key collision (trg_ae_ticket_key_unambiguous would raise).
--
-- AUDIT (ADR 010): derm_manifests is audited, so the number change is captured.
-- address_row_map is Stamp-Studio working state (unaudited by design).
-- ============================================================================

begin;

-- PART 1
update public.visit_locations
   set client_location_id = 260
 where visit_id in (1402, 1773) and client_location_id = 9;

-- PART 2 — ⚠ ORDER MATTERS, AND NOT THE WAY YOU'D EXPECT.
-- First attempt did derm_manifests first and hit
--   23505 address_row_map_natural_key (dump_folder,page,row_index)=(ticket-831102,1,1)
-- Renaming the manifest number fires the card-materialisation trigger, which
-- creates FRESH Studio cards under the now-clean 'ticket-831102' key; the
-- subsequent card rename then collided with the trigger's own rows. So rename the
-- CARDS first (they land on the clean key while the manifest is still spaced), and
-- only then the manifests, at which point the trigger finds the cards already
-- present and no-ops.
update derm.address_row_map
   set dump_folder = 'ticket-831102',
       white_manifest_number = btrim(white_manifest_number)
 where dump_folder = 'ticket- 831102';

update public.derm_manifests
   set white_manifest_number = btrim(white_manifest_number)
 where white_manifest_number <> btrim(white_manifest_number);

commit;
