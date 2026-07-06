-- 2026-07-06_derm_manifest_visits_county_property_fix.sql
-- Fix: the DERM app manifest page showed a BLANK county (and address) for a linked visit
-- whenever that visit's client has no property flagged is_billing = false.
--
-- Symptom (Fred): manifest #822621 -> visit "150-KOS Kosh" showed no county in the DERM app.
--
-- Root cause: derm.manifest_visits derived county/address via a LATERAL that HARD-filtered the
-- property list with `AND p2.is_billing = false`:
--     LEFT JOIN LATERAL (SELECT p2.address, p2.county FROM properties p2
--                        WHERE p2.client_id = c.id AND p2.is_billing = false
--                        ORDER BY p2.id LIMIT 1) p ON true
--   ... then COALESCE(p.county,'') / COALESCE(p.address,'').
-- A client whose ONLY property is is_billing = true (150-KOS / client 336: property 841,
-- is_billing=true, is_primary=true, county='Dade', '9477 Harding Avenue') matches ZERO rows ->
-- the LEFT JOIN yields NULL -> COALESCE blanks BOTH county and address.
--
-- Proven a VIEW bug, NOT missing data: derm.visits (whose LATERAL has no hard is_billing filter)
-- returns county='Dade', address='9477 Harding Avenue' for the very same visit 1773.
-- (Adversarially verified via a 3-skeptic workflow: controlled A/B on the is_billing predicate
-- flips the outcome; no soft-delete/RLS/lost-row alternative explains it.)
--
-- Breadth: 8 clients / ~12 manifest-visit rows were blank on BOTH county and address, ALL the same
-- filter bug, 0 genuine data gaps: 144-LTG, 150-KOS, 231-CHE, 232-AC, 234-PV, 238-PV, 241-WYN, and
-- "Bay Harborview Condo" (client 480, code NULL). Same "service vs billing property" class as the
-- 2026-07-05 customer.permits address-aware fix.
--
-- Fix: drop the hard `is_billing = false` predicate and demote it to an ORDER BY *preference*, so the
-- view still prefers a non-billing (service) property but NEVER excludes a client's only property.
-- Ordering is deliberately non-billing-FIRST (not is_primary-first like derm.visits) so the fix is
-- strictly surgical:
--   Simulated over all 523 rows -> changes EXACTLY the ~12 blank rows (blank -> populated), 0 collateral
--   (no currently-populated county/address row moves). An is_primary-first ordering (mirroring
--   derm.visits) would additionally shift 5 rows' address from the service addr to the billing addr for
--   3 clients whose is_primary=true sits on their billing property (148-MOR, 198-ARY, 215-G7); this
--   ordering avoids that. (Minor known divergence: for those 3 clients derm.visits still shows the
--   billing address while the manifest correctly shows the service address -- out of scope here.)
--
-- CREATE OR REPLACE VIEW preserves grants (anon + authenticated SELECT) and the exact column
-- shape/order (manifest_id, visit_id, visit_date, client_id, client_name, address, county).
-- Applied + verified 2026-07-06: before_blank 11 -> after_blank 0, total rows 521 unchanged;
-- 150-KOS/#822621 -> Dade / '9477 Harding Avenue'; whole 822621 group resolves; known-correct rows
-- (008-CV, 049-PV) unchanged. Backup of the prior definition:
--   backups/2026-07-06_derm_manifest_visits_view_before.sql
--
-- Coordination: derm.* is the parallel Stamp Studio session's active lane (2026-07-06 cross-client
-- mis-link fixes on the manifest_visits/derm_manifests ROWS, incl. ticket 822621). This migration
-- changes ONLY the derm.manifest_visits VIEW definition (the county/address LATERAL) -- a distinct
-- object from their row/linkage work -- so it is orthogonal and does not clobber their changes.

CREATE OR REPLACE VIEW derm.manifest_visits AS
 SELECT mv.manifest_id,
    mv.visit_id,
    v.visit_date::text AS visit_date,
    v.client_id,
        CASE
            WHEN c.client_code IS NOT NULL AND c.name !~~ (c.client_code || '%'::text) THEN (c.client_code || ' '::text) || c.name
            ELSE c.name
        END AS client_name,
    COALESCE(p.address, ''::text) AS address,
    COALESCE(p.county, ''::text) AS county
   FROM manifest_visits mv
     JOIN visits v ON v.id = mv.visit_id
     JOIN clients c ON c.id = v.client_id
     LEFT JOIN LATERAL ( SELECT p2.address,
            p2.county
           FROM properties p2
          WHERE p2.client_id = c.id
          ORDER BY (p2.is_billing IS NOT TRUE) DESC, p2.is_primary DESC NULLS LAST, p2.id
         LIMIT 1) p ON true
  WHERE (EXISTS ( SELECT 1
           FROM derm_manifests dm
          WHERE dm.id = mv.manifest_id AND dm.deleted_at IS NULL));
