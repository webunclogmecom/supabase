-- 2026-07-15_security_invoker_views.sql
-- Set security_invoker=true on the 3 public views flagged by the Supabase
-- "security_definer_view" advisor: v_visits_live, visits_with_status, manifest_pickable_visits.
--
-- WHY: these views are owner=postgres with no `security_invoker` option (=> SECURITY DEFINER),
-- so a query runs with the view owner's rights and bypasses RLS on the underlying tables. The
-- advisor flags any such view in the API-exposed `public` schema.
--
-- LATENT, not live: no anon/authenticated/service_role grant exists on any of these 3 views NOR
-- on public.visits (verified 2026-07-15) — no untrusted role can query them today, so there is
-- no current RLS-bypass exposure. This change is defense-in-depth: if a grant is ever added, the
-- view will then respect the caller's RLS instead of silently running as postgres.
--
-- SAFE (no functional change): the entire read chain is postgres-owned SECURITY DEFINER views —
--   v_visits_live       <- ops.{v_driver_kpi,v_revenue_summary,v_route_today,v_service_due,
--                            v_truck_utilization} + ops.visits
--   manifest_pickable_visits <- derm.v_stamp_unlinked_visits
-- all owner=postgres, opts=null, zero untrusted grants. A DEFINER parent sets current_user=postgres,
-- so an invoker=true child still reads public.visits as postgres (which owns it). Verified: post-change
-- re-query of the views + ops.v_route_today returns data unchanged. PG17 (security_invoker supported).
--
-- AUDIT (ADR 010): view-option change only, no table/business-data DML => no audit trigger applies.
-- REVERSIBLE: ALTER VIEW <v> SET (security_invoker = false);

ALTER VIEW public.v_visits_live          SET (security_invoker = true);
ALTER VIEW public.visits_with_status     SET (security_invoker = true);
ALTER VIEW public.manifest_pickable_visits SET (security_invoker = true);
