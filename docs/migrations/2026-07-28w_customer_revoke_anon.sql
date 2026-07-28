-- ============================================================================
-- 2026-07-28w — stop the `customer` schema serving the entire client book to
--               anyone holding the publishable key
-- ============================================================================
-- ⚠ STAGED, NOT APPLIED. Gate: Building Apps confirms the Field Portal is live
-- on customer.get_client_portal() / customer.get_work_order() (migration 28v)
-- and no longer issues .from("<view>") against the customer schema.
-- Same gate that preceded 28r (Stamp Studio), 28s (DERM Tracker), 28u (ops).
--
-- ⚠⚠ APPLYING THIS BEFORE THE APP SHIPS TAKES THE CUSTOMER-FACING PORTAL DOWN.
-- Field Portal is the one surface a paying client actually looks at. Unlike the
-- three revokes before it, the blast radius here is external. Do not apply it
-- because the migration exists and looks ready.
--
-- ── WHAT THIS CLOSES ───────────────────────────────────────────────────────
-- All 9 of 9 objects in `customer` are anon-readable and `customer` is
-- PostgREST-exposed. Verified live as anon on 2026-07-28 with the project's
-- publishable key:
--     customer.clients          HTTP 206   content-range 0-1/439
-- Full book reachable with no slug and no token:
--     clients 439 · work_orders 591 (carries storage URLs) · scheduled_visits 709
--     wo_photos 313 · permits 128 · gdo_reports 78   = 2,258 rows
-- Grant origin: 2026-05-14c_customer_schema.sql:318-330 (same blanket
-- GRANT + ALTER DEFAULT PRIVILEGES shape as the ops one closed in 28u).
--
-- ── WHY IT IS SAFE ONCE 28v IS WIRED UP ────────────────────────────────────
-- The two RPCs in 28v are SECURITY DEFINER, so they keep reading the views
-- after anon loses SELECT. Verified over real HTTPS as anon 2026-07-28:
--     rpc/get_client_portal   HTTP 200  4,815 bytes
--     rpc/get_work_order      HTTP 200  9,264 bytes
--     miss case               HTTP 200  null      (maps to .maybeSingle() null)
-- Column parity with the views the app reads today is exact: client 17/17,
-- work_order 30/30.
--
-- customer.get_visit_by_slug_and_token(text,text) is also SECURITY DEFINER and
-- survives this revoke. Nothing calls it (zero .rpc() in the FP bundle), but it
-- is left in place rather than dropped — out of scope for a grant migration.
--
-- ── ⚠ WHAT THIS DOES *NOT* CLOSE ───────────────────────────────────────────
-- The /$clientSlug route is gated by the slug ALONE — no token. The slug is the
-- lowercased client_code (e.g. `015-fla`), which is printed on invoices and
-- manifests and is partly sequential. After this migration an attacker can no
-- longer pull 439 clients in one request, but CAN still walk client codes to
-- reach individual client histories one at a time.
-- This migration turns a bulk dump into a per-client guess. That is a real
-- reduction and it is NOT full closure. Closing it needs a per-client secret in
-- the portal link, which is a product + link-distribution decision for Fred.
-- Do not report `customer` as solved on the back of this file.
--
-- ROLLBACK (restores the Field Portal instantly if the app is not ready):
--   GRANT SELECT ON ALL TABLES IN SCHEMA customer TO anon;
--   ALTER DEFAULT PRIVILEGES IN SCHEMA customer GRANT SELECT ON TABLES TO anon;
--
-- USAGE ON SCHEMA is deliberately KEPT for anon — the RPCs live in `customer`
-- and anon must resolve the schema to call them.
--
-- AUDIT (ADR 010): grant-only change, no data touched.
-- ============================================================================

begin;

revoke select on all tables in schema customer from anon;

-- stop it regenerating on the next object added to the schema — this is the
-- half that makes the fix stick, and the half that is easy to forget
alter default privileges in schema customer revoke select on tables from anon;

commit;
