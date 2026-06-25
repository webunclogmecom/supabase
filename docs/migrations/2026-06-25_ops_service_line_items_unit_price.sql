-- ============================================================================
-- 2026-06-25 — Expose service_line_items.unit_price through the ops view
-- ----------------------------------------------------------------------------
-- The Calendar New-Visit form (price-field build) reads the SC service catalog
-- from ops.service_line_items and now selects unit_price to pre-fill the price.
-- That view has a FIXED column list created before unit_price was added to
-- public.service_line_items, so the query 400'd and the form hung on
-- "Loading services...". Append unit_price (CREATE OR REPLACE allows adding
-- columns at the end).
-- ============================================================================
CREATE OR REPLACE VIEW ops.service_line_items AS
  SELECT id, code, title, requires_derm, reason, service_kind, location_target,
         method, service_type, schedulable, active, created_at, updated_at,
         unit_price
  FROM service_line_items;
