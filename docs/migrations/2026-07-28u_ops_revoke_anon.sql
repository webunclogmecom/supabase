-- ============================================================================
-- 2026-07-28u — stop the `ops` schema serving A/R and customer contact details
--               to anyone holding the publishable key
-- ============================================================================
-- ⚠ STAGED, NOT APPLIED. Gate: Building Apps confirms the Visit Calendar's reads
-- and its calendar_day_markers writes arrive as `authenticated`. Same gate that
-- preceded 28r (Stamp Studio) and 28s (DERM Tracker).
--
-- ── WHAT THIS IS ───────────────────────────────────────────────────────────
-- ALL 30 of 30 objects in `ops` are anon-readable, and `ops` is one of the
-- schemas PostgREST exposes. So anyone with the publishable key — which ships in
-- every Lovable bundle and is readable from page source — can query it directly.
-- Retrieved live as role anon during the 2026-07-28 audit:
--
--   ops.v_ar_aging  ->  client_name        | primary_email                  | primary_phone | balance_due
--                       Casa Neos          | ali@rivieradininggroup.com     | 3057446038    | 5297.28
--                       Pura Vida Bakery   | marcel@puravidamiami.com       | (null)        | 3999.96
--
-- That is customer NAME + EMAIL + PHONE + OUTSTANDING BALANCE. Also reachable:
--   ops.properties          817  street, city, zip, latitude, longitude
--   ops.clients             439  name, balance, notes
--   ops.service_configs     270  price_per_visit, permit_number
--   ops.v_revenue_summary   176  gross_revenue, outstanding_ar, collected_revenue by month + truck
--   ops.invoice_locations  2485  ·  ops.v_billing_by_location 378  ·  ops.v_gdo_expiry 128
--   ops.v_calendar_driver     7  staff full_name / email / phone
--
-- This is a materially worse exposure than the `derm` one closed earlier today:
-- accounts receivable with contact details is the kind of record that is directly
-- useful to whoever finds it.
--
-- ── WHERE THE GRANT CAME FROM ──────────────────────────────────────────────
-- docs/migrations/2026-05-23a_visit_calendar_ops_wiring.sql:99-103
--   line  99  -- 4. GRANTS — anon SELECT on ops schema (prototype anon model)
--   line 101  GRANT USAGE ON SCHEMA ops TO anon, authenticated;
--   line 102  GRANT SELECT ON ALL TABLES IN SCHEMA ops TO anon, authenticated;
--   line 103  ALTER DEFAULT PRIVILEGES IN SCHEMA ops GRANT SELECT ON TABLES TO anon, authenticated;
-- Line 103 is why this keeps regenerating: every new ops object is born
-- anon-readable with no GRANT written by anyone. Revoking the default is the
-- half that stops this recurring, and it is the half that is easy to forget.
--
-- ── WHY IT IS SAFE ─────────────────────────────────────────────────────────
-- The Visit Calendar is the only consumer of `ops` (grep of Building Apps for
-- `schema: 'ops'` / `Accept-Profile: ops` returns Visit Calendar only). It runs as
-- `authenticated` — stated outright in 2026-07-28h and consistent with the app
-- being live while `ops.v_calendar_visit.gdo_number` already 401s for anon
-- (fn_resolve_gdo_id is not granted to anon).
-- DUMP Schedule reaches ops.v_calendar_visit through the `dump_route_today`
-- SECURITY DEFINER RPC inside the `dump-visit-create` edge function, which runs
-- as service_role, so it is unaffected.
--
-- ⚠ ops.calendar_day_markers is the ONLY ops object with anon WRITE (full CRUD,
-- Supabase 2's shared Day Start/End/Dump markers, commit 334577a). `authenticated`
-- ALREADY holds SELECT/INSERT/UPDATE/DELETE on it, so revoking anon does not
-- remove the capability — it just requires the Calendar to be signed in, which it
-- is. Verified rather than assumed.
--
-- USAGE ON SCHEMA is deliberately KEPT for anon: revoking it would give a
-- confusing "permission denied for schema ops" instead of a per-object error, and
-- it grants no data by itself.
--
-- Dry run (rolled back): ops objects anon can read 30 -> 0, authenticated stays 30.
--
-- ROLLBACK:
--   GRANT SELECT ON ALL TABLES IN SCHEMA ops TO anon;
--   GRANT INSERT, UPDATE, DELETE ON ops.calendar_day_markers TO anon;
--   ALTER DEFAULT PRIVILEGES IN SCHEMA ops GRANT SELECT ON TABLES TO anon;
--
-- ⚠ AND THIS STILL DOES NOT CLOSE THE EXPOSURE. Remaining after this migration:
--   customer  9 of 9 objects anon-readable — the WHOLE client book (2,258 rows)
--             enumerable without a slug+token, though Field Portal was designed to
--             serve one visit per token. That needs an app change, not a revoke.
--   public   51 of 73 objects anon-readable.
--   storage  manifests / GT - Visits Images / gdo-permits are PUBLIC buckets with
--            predictable paths, so scanned sheets stay fetchable regardless.
-- Report this as one door closed, not as the problem solved.
--
-- AUDIT (ADR 010): grant-only change, no data touched.
-- ============================================================================

begin;

revoke select on all tables in schema ops from anon;
revoke insert, update, delete on ops.calendar_day_markers from anon;

-- stop it regenerating on the next object added to the schema
alter default privileges in schema ops revoke select on tables from anon;

commit;
