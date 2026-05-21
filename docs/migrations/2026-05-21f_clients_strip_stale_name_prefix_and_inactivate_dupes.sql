-- 2026-05-21f_clients_strip_stale_name_prefix_and_inactivate_dupes.sql
--
-- Two cleanups after Yannick code changes propagated through AT/Jobber:
--
-- A) Stale name prefix on 3 clients. Their client_code was updated to the
--    current AT-canonical value, but the name still carries the OLD code
--    as a prefix → derm.visits view double-prefixes ("001-VIN 1-VIN
--    Vincenzos Pizzeria"). Strip the stale prefix; restore the clean
--    AT-canonical name.
--
--    id=226  client_code=001-VIN  name "1-VIN Vincenzos Pizzeria"  → "Vincenzos Pizzeria"
--    id=289  client_code=019-G7   name "019-GT G7 Kitchens 34"     → "G7 Kitchen 34"
--    id=458  client_code=215-GT   name "215-G7 Kitchen 35"         → "G7 Kitchen 35"
--
-- B) Three orphan duplicate clients (left over from Yannick consolidating
--    in AT). Each has a canonical sibling with the proper client_code; the
--    orphan has either no code or a name explicitly marked "NOT USE". Flip
--    them to INACTIVE per rule #6 (never hard-delete). Reassign client
--    265's single visit to the canonical 199-JZ row first.
--
--    id=119  "128- Meir Fellig"             → INACTIVE (canonical = 331 128-MF)
--    id=153  "145- International Foods..."  → INACTIVE (canonical = 152 145-NON)
--    id=265  "JZ Steak House NOT USE"       → INACTIVE (canonical = 363 199-JZ); 1 visit reassigned
--
-- Audit (Rule 8): triggers fire on clients UPDATE — captured in audit.logs.

BEGIN;

-- A) Strip stale prefixes from names
UPDATE clients SET name = 'Vincenzos Pizzeria'  WHERE id = 226 AND name = '1-VIN Vincenzos Pizzeria';
UPDATE clients SET name = 'G7 Kitchen 34'        WHERE id = 289 AND name = '019-GT G7 Kitchens 34';
UPDATE clients SET name = 'G7 Kitchen 35'        WHERE id = 458 AND name = '215-G7 Kitchen 35';

-- B) Reassign client 265's lone visit to canonical 199-JZ (id=363)
UPDATE visits SET client_id = 363
WHERE client_id = 265 AND id IN (SELECT id FROM visits WHERE client_id = 265);

-- B) Deactivate the 3 orphan dupes
UPDATE clients SET status = 'INACTIVE', name = name || ' [merged into id ' || canonical_id::text || ']'
FROM (VALUES (119, 331), (153, 152), (265, 363)) AS m(orphan_id, canonical_id)
WHERE clients.id = m.orphan_id AND clients.status <> 'INACTIVE';

COMMIT;

-- Verification:
--   SELECT id, client_code, name, status FROM clients WHERE id IN (226, 289, 458, 119, 153, 265);
--   SELECT id, client_name FROM derm.visits WHERE client_id IN (226, 289, 458)
--     ORDER BY id DESC LIMIT 6;
--   -- Expect: clean single-prefix names like "001-VIN Vincenzos Pizzeria"
