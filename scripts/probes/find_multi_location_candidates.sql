-- find_multi_location_candidates.sql  (READ-ONLY probe)
--
-- Surfaces clients that may need public.client_locations rows, and flags the dirty
-- GDO data that must be cleaned BEFORE any bulk per-GDO backfill. Casa Neos (3) and
-- Wynd 28 (5) are already seeded by 2026-06-01b. Everything else is Phase-2 work:
-- triage each candidate BY HAND -> a multi-GDO client is sometimes a real
-- multi-location set (Casa Neos) and sometimes just a duplicate GDO to merge.

-- H1. Multi-GDO clients = the primary location candidates. n_dirty_gdo_numbers > 0
--     means "dedup/clean the GDOs first, do NOT fan them into locations as-is".
SELECT c.id AS client_id, c.client_code, c.name, c.status,
       count(DISTINCT g.id)                                              AS n_gdos,
       count(*) FILTER (WHERE g.gdo_number !~ '^GDO-0*[0-9]+$')          AS n_dirty_gdo_numbers,
       count(DISTINCT cl.id)                                             AS n_locations_seeded,
       array_agg(g.gdo_number ORDER BY g.gdo_number)                     AS gdo_numbers
FROM public.gdos g
JOIN public.clients c ON c.id = g.client_id
LEFT JOIN public.client_locations cl ON cl.client_id = c.id
GROUP BY c.id, c.client_code, c.name, c.status
HAVING count(DISTINCT g.id) > 1
ORDER BY n_dirty_gdo_numbers DESC, n_gdos DESC, c.client_code;

-- H2. Malformed GDO numbers anywhere (a cleanup queue independent of locations).
SELECT g.id, c.client_code, c.name, g.gdo_number, g.location_label, g.property_id
FROM public.gdos g JOIN public.clients c ON c.id = g.client_id
WHERE g.gdo_number !~ '^GDO-0*[0-9]+$'
ORDER BY c.client_code, g.gdo_number;

-- H3. Same normalized street address, multiple DISTINCT clients. Catches the legacy
--     "tenants modelled as separate clients" pattern (what Wynd 28 was in Airtable).
WITH norm AS (
  SELECT p.client_id, c.name AS client_name, c.client_code, p.city, p.zip,
         regexp_replace(lower(regexp_replace(coalesce(p.address,''),
           '\m(ste|suite|unit|apt|#|no\.?)\M.*$','','i')),'\s+',' ','g') AS addr_key
  FROM public.properties p JOIN public.clients c ON c.id = p.client_id
  WHERE p.address IS NOT NULL
)
SELECT addr_key, city, zip, count(DISTINCT client_id) AS distinct_clients,
       array_agg(DISTINCT client_code ORDER BY client_code) FILTER (WHERE client_code IS NOT NULL) AS codes,
       array_agg(DISTINCT client_name ORDER BY client_name) AS names
FROM norm GROUP BY addr_key, city, zip
HAVING count(DISTINCT client_id) > 1
ORDER BY distinct_clients DESC, addr_key;

-- H4. Coverage gap: clients whose GDO count exceeds their seeded client_locations
--     (i.e. still under-seeded). Empty for Casa Neos after 2026-06-01b.
SELECT c.id, c.client_code, c.name,
       count(DISTINCT g.id)  AS n_gdos,
       count(DISTINCT cl.id) AS n_locations
FROM public.gdos g
JOIN public.clients c ON c.id = g.client_id
LEFT JOIN public.client_locations cl ON cl.client_id = c.id
GROUP BY c.id, c.client_code, c.name
HAVING count(DISTINCT g.id) > greatest(count(DISTINCT cl.id), 1)
ORDER BY n_gdos DESC, c.client_code;
