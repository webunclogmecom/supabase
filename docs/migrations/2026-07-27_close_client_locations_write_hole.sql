-- ============================================================================
-- 2026-07-27 — SECURITY: close the client_locations write hole + drop a latent
--              anon UPDATE policy on gdos
-- ============================================================================
-- FOUND: Building Apps session while scoping Client App phase 2 (2026-07-26).
-- VERIFIED here against live Prod before applying.
--
-- THE HOLE (live, exploitable by any logged-in staff user of ANY of the 5 apps):
--   public.client_locations had RLS enabled but NOT forced, a fully permissive
--   policy `client_locations_authenticated_all` (FOR ALL TO authenticated,
--   USING true / WITH CHECK true), AND INSERT/UPDATE/DELETE/TRUNCATE granted to
--   `authenticated`. `public` is PostgREST-exposed, so a plain
--   DELETE /rest/v1/client_locations?id=eq.N with any staff JWT would delete a
--   location row. Blast radius (447 rows):
--     * gdos.client_location_id FK is ON DELETE SET NULL -> a DERM compliance
--       permit silently loses its location (113 of 220 gdos carry one);
--     * visit_locations FK is ON DELETE CASCADE -> visit<->location links vanish.
--   anon additionally held TRUNCATE (RLS does NOT gate TRUNCATE).
--
-- PROVABLY NON-BREAKING: audit.logs shows every client_locations write ever came
-- from db_role `postgres` (sql/scripts: 421 INSERT + 100 UPDATE) or the Jobber
-- webhook (26 INSERT, service_role). ZERO writes from `authenticated`. Same for
-- gdos (all postgres/sql). Revoking app-role writes changes no working path;
-- postgres + service_role keep full write access, so the webhook, the edge fns
-- and every sync script are unaffected.
--
-- ALSO: `anon_update_gdo_labels` on public.gdos (FOR UPDATE TO {anon,authenticated}
-- USING true WITH CHECK true) is inert TODAY only because neither role holds
-- UPDATE on gdos. It is a live landmine: the moment phase 2 grants any UPDATE on
-- gdos it becomes unrestricted write on all 220 permits. Dropped now, before the
-- phase-1 GDO work grants anything. (Writes will go through SECDEF RPCs instead —
-- see the phase-2 contract: no client.* view is ever writable.)
--
-- Rollback (if ever needed): re-GRANT the privileges + re-CREATE the two policies
-- with the same USING/WITH CHECK. Reversible, no data touched.
-- AUDIT (ADR 010): grant/policy change only; both tables keep their audit triggers.
-- ============================================================================

begin;

-- 1) client_locations — app roles become READ-ONLY (SELECT policies stay).
drop policy if exists "client_locations_authenticated_all" on public.client_locations;
revoke insert, update, delete, truncate on public.client_locations from authenticated;
revoke insert, update, delete, truncate on public.client_locations from anon;

-- 2) gdos — remove the latent permissive UPDATE policy before phase 2 grants anything.
drop policy if exists "anon_update_gdo_labels" on public.gdos;

commit;
