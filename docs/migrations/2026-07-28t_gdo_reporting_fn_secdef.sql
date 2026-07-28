-- ============================================================================
-- 2026-07-28t — fn_visit_is_gdo_reporting SECURITY DEFINER (unblocks the Field
--               Portal from the public-schema anon revoke)
-- ============================================================================
-- Found while testing whether Field Portal survives revoking anon SELECT on
-- public.*. 8 of its 9 customer.* views survive; customer.gdo_reports does not:
--   ERROR 42501: permission denied for table visits
--   CONTEXT: SQL function "fn_visit_is_gdo_reporting"
--
-- ⚠ THE ASYMMETRY, AGAIN: an owner-rights view LAUNDERS table grants, so
-- customer.* views read public.* fine as anon. A FUNCTION does not — a SECURITY
-- INVOKER function called from inside that view still reads with the CALLER's
-- privileges. Same trap as 2026-07-28h (fn_resolve_gdo_id granted to service_role
-- only, which would have 42501'd the Calendar for every staff user). Tables
-- launder, functions do not. It is worth stating every time because the intuition
-- is wrong in a way that is invisible until the grant is removed.
--
-- Field Portal is customer-facing with NO LOGIN by design, so it must keep working
-- as anon. Making this helper SECURITY DEFINER removes its dependency on the
-- caller's grants and takes FP out of the blast radius of the coming public-schema
-- revoke entirely.
--
-- SAFE: the function is a read-only predicate (does this visit belong to a
-- GDO-reporting client). SECURITY DEFINER here grants no new data reach — the
-- calling view already exposes the row via owner rights; this only stops the
-- helper from failing for a caller that legitimately cannot read public.visits.
-- search_path is pinned, which is the actual hardening requirement for SECDEF.
--
-- AUDIT (ADR 010): read-only function, no audit trigger applies.
-- ============================================================================

begin;

alter function public.fn_visit_is_gdo_reporting(bigint) security definer;
alter function public.fn_visit_is_gdo_reporting(bigint) set search_path = public, pg_temp;

commit;
