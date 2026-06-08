-- ============================================================================
-- 2026-06-08 — Group chain clients under brand client_groups
-- ============================================================================
-- Per Fred 2026-06-08: "group all the clients" — every multi-store brand becomes
-- ONE client_group (the brand = Fred's "client"); each store stays its own Jobber
-- billing client (= Fred's "location", owning its billing/invoices/GDO/visits).
-- This is the identity foundation for the client -> location model. Additive +
-- reversible (set group_id = NULL).
--
-- Rule 4: each chain store is a SEPARATELY-BILLED Jobber client; we DON'T collapse
-- them (that would destroy per-location billing). We only add the brand parent.
-- clients is audited (ADR 010) -> group_id updates are captured. client_groups is a
-- lookup (unaudited, as originally created). TCE was already grouped (group id 2).
--
-- Grouped (9 brands): Pura Vida (PV), La Granja (LG), Grove Kosher (GRO),
-- Bagel Boss (BB), Myka (MYK), Nu Real Food (NU), Fresko (FRK), Krudo (KRU),
-- Mr. & Mrs. Pasta (MP).
-- HELD for review (NOT grouped) — look like single-venue areas or duplicates, not
-- multi-store chains: G7 (G7 Kitchens/Roof Top/Kitchen 35 — one food hall?),
-- TRUE (True Barista truck/temp-truck/grease-trap — dedup candidate),
-- FIA (two identical "Florida Food Eats LLC Fial" — duplicate candidate).
-- ============================================================================

INSERT INTO public.client_groups (name, status) VALUES
  ('Pura Vida','ACTIVE'),
  ('La Granja','ACTIVE'),
  ('Grove Kosher','ACTIVE'),
  ('Bagel Boss','ACTIVE'),
  ('Myka','ACTIVE'),
  ('Nu Real Food','ACTIVE'),
  ('Fresko','ACTIVE'),
  ('Krudo','ACTIVE'),
  ('Mr. & Mrs. Pasta','ACTIVE')
ON CONFLICT (name) DO NOTHING;

UPDATE public.clients c SET group_id = g.id FROM public.client_groups g
  WHERE g.name = 'Pura Vida'        AND c.client_code ~ '-PV$'  AND c.group_id IS DISTINCT FROM g.id;
UPDATE public.clients c SET group_id = g.id FROM public.client_groups g
  WHERE g.name = 'La Granja'        AND c.client_code ~ '-LG$'  AND c.group_id IS DISTINCT FROM g.id;
UPDATE public.clients c SET group_id = g.id FROM public.client_groups g
  WHERE g.name = 'Grove Kosher'     AND c.client_code ~ '-GRO$' AND c.group_id IS DISTINCT FROM g.id;
UPDATE public.clients c SET group_id = g.id FROM public.client_groups g
  WHERE g.name = 'Bagel Boss'       AND c.client_code ~ '-BB$'  AND c.group_id IS DISTINCT FROM g.id;
UPDATE public.clients c SET group_id = g.id FROM public.client_groups g
  WHERE g.name = 'Myka'             AND c.client_code ~ '-MYK$' AND c.group_id IS DISTINCT FROM g.id;
UPDATE public.clients c SET group_id = g.id FROM public.client_groups g
  WHERE g.name = 'Nu Real Food'     AND c.client_code ~ '-NU$'  AND c.group_id IS DISTINCT FROM g.id;
UPDATE public.clients c SET group_id = g.id FROM public.client_groups g
  WHERE g.name = 'Fresko'           AND c.client_code ~ '-FRK$' AND c.group_id IS DISTINCT FROM g.id;
UPDATE public.clients c SET group_id = g.id FROM public.client_groups g
  WHERE g.name = 'Krudo'            AND c.client_code ~ '-KRU$' AND c.group_id IS DISTINCT FROM g.id;
UPDATE public.clients c SET group_id = g.id FROM public.client_groups g
  WHERE g.name = 'Mr. & Mrs. Pasta' AND c.client_code ~ '-MP$'  AND c.group_id IS DISTINCT FROM g.id;

-- Verify:
-- SELECT g.name, count(c.id) FROM public.client_groups g
--   LEFT JOIN public.clients c ON c.group_id = g.id GROUP BY g.name ORDER BY 2 DESC;
