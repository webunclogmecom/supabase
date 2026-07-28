-- ============================================================================
-- 2026-07-28x — stop `public` minting anon-writable tables, and drop the
--               unreachable TRUNCATE/write grants
-- ============================================================================
-- This is the ROOT-CAUSE half of the public wave. It changes NOTHING that any
-- running app can observe, so it ships ahead of the SELECT revoke (28y) rather
-- than waiting on the app read maps.
--
-- ── FINDING 1: every new public table is born anon-writable ────────────────
-- `public` still carries TWO ALTER DEFAULT PRIVILEGES entries handing anon the
-- full `arwdDxtm` set, while ops / derm / client were already cleaned to
-- `{authenticated=r}`. Proven by a rolled-back probe, not inferred:
--
--   create table public._zz_privtest (id bigint);
--   -> anon=SIUDT   authenticated=SIUDT
--
-- SELECT/INSERT/UPDATE/DELETE are all exposed through PostgREST, so a table
-- created tomorrow is writable over the internet by anyone holding the
-- publishable key, until a human notices and revokes it. This is why the
-- exposure keeps regenerating: it is the generator behind
-- `derm.address_sheet_clients` coming out anon-readable on 2026-07-28 with no
-- GRANT written anywhere, and it silently undoes every revoke shipped in 28r,
-- 28s, 28u and 28w for the next object added.
--
-- After the revoke below, the same rolled-back probe returns:
--   -> anon=-----   authenticated=S
-- so staff apps are unaffected and anon gets nothing.
--
-- ⚠ There are two default-ACL rows for `public`, one granted by `postgres` and
-- one by `supabase_admin`. ALTER DEFAULT PRIVILEGES is per-grantor and we
-- connect as `postgres`, so this migration can only remove the postgres one.
-- That is the operative one for our migrations: the rolled-back probe created a
-- table as postgres and it came out clean once the postgres default was gone.
-- The supabase_admin row governs tables created by Supabase's own internals and
-- is not ours to change. Do not read its continued presence as this failing.
--
-- ⚠ NOT FIXED HERE: `authenticated` also inherits `arwdDxtm` on every new
-- public table, i.e. any logged-in staff user can write any new table by
-- default. That is a real over-grant but narrowing it can break staff apps
-- mid-flight, so it is deliberately left for a separate gated change rather
-- than smuggled into a root-cause fix.
--
-- ── FINDING 2: anon TRUNCATE on 7 real tables — LATENT, NOT REACHABLE ──────
-- anon holds TRUNCATE on 21 public objects, 7 of which are real tables
-- (service_line_items, visit_locations, visit_team, visit_reviews,
-- shift_reviews, derm_manifest_number_proposals,
-- derm_required_backfill_snapshot_2026_06_24). RLS does NOT gate TRUNCATE, and
-- a rolled-back probe confirmed the privilege is genuinely held:
--
--   set local role anon; truncate public.visit_team;   -- 2 rows -> 0 rows
--
-- (Rolled back; visit_team verified back at 2 rows afterwards. No data lost.)
--
-- ⚠ BUT IT IS NOT REMOTELY EXPLOITABLE TODAY, and this migration should not be
-- described as closing an active hole. Reachability was checked rather than
-- assumed: `anon` is NOLOGIN (rolcanlogin = false) so nobody can connect as it
-- directly; PostgREST exposes no TRUNCATE verb; and no anon-EXECUTE function in
-- `public` runs dynamic SQL (checked across all 39). So the privilege is real
-- but currently unreachable. It is removed as defence in depth, because the
-- moment anyone adds an anon-callable function with dynamic SQL, or a SQL
-- injection appears, it becomes live and destructive.
--
-- ── FINDING 3: an inert write grant ────────────────────────────────────────
-- anon holds INSERT/UPDATE/DELETE on `v_gdo_reporting_derm_mismatch`. It is a
-- VIEW and information_schema reports is_insertable_into = NO and
-- is_updatable = NO, so the grant cannot be exercised — it is not the
-- auto-updatable-view bypass that hit `v_visits_live` during the Phase 3 lock.
-- Removed as hygiene, not as an incident.
--
-- ── WHY THIS IS SAFE TO APPLY WITHOUT THE APP READ MAPS ────────────────────
-- Nothing here touches an existing SELECT grant, an RLS policy, or any object
-- an app reads today. It affects only (a) tables that do not exist yet and
-- (b) privileges that are provably unreachable over the API. The SELECT revoke,
-- which CAN break an app, is a separate migration gated on the read maps.
--
-- ROLLBACK:
--   ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon;
--   GRANT TRUNCATE ON ALL TABLES IN SCHEMA public TO anon;
--   GRANT INSERT, UPDATE, DELETE ON public.v_gdo_reporting_derm_mismatch TO anon;
--
-- AUDIT (ADR 010): grant-only change, no data touched, no table shape changed.
-- ============================================================================

begin;

-- 1. the generator: stop minting anon-privileged tables in `public`
alter default privileges in schema public revoke all on tables from anon;

-- 2. defence in depth: RLS cannot gate TRUNCATE, so the grant is the only guard
revoke truncate on all tables in schema public from anon;

-- 3. hygiene: inert write grant on a non-updatable view
revoke insert, update, delete on public.v_gdo_reporting_derm_mismatch from anon;

commit;
