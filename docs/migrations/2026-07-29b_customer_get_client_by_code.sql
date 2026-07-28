-- ============================================================================
-- 2026-07-29b — customer.get_client_by_code(): remove the Field Portal login's
--               dependency on which env var happens to be populated, AND close
--               a pattern-injection in the code lookup
-- ============================================================================
-- ADDITIVE AND HARMLESS UNTIL CALLED, exactly like 28v. Nothing changes until
-- Building Apps wires it, so there is no half-applied window and no need to
-- co-ordinate timing. Requested by BA 2026-07-29.
--
-- ── WHY IT EXISTS: the fragility ───────────────────────────────────────────
-- Field Portal's /login client-code lookup lives in `src/lib/auth.functions.ts`,
-- a TanStack Start SERVER function. It ships in NO browser chunk, which is why
-- two independent bundle audits (mine and BA's) both concluded "all customer
-- reads live in portal-*.js" and both were wrong. It resolves its key as:
--
--     process.env.PERSONAL_SUPABASE_SERVICE_ROLE_KEY
--       || process.env.PERSONAL_SUPABASE_ANON_KEY
--
-- so whether the 28w revoke killed every customer login depended entirely on
-- which side of that `||` was populated at runtime — not knowable from source.
-- BA settled it against the edge log with a real login (jwt_role = service_role),
-- so it is safe today. It is a landmine: clear that env var and login silently
-- falls back to the anon key, which now holds nothing on `customer`, and dies
-- with no code change to blame.
--
-- With this SECURITY DEFINER function the server function needs NO table grant
-- at all, and the SERVICE_ROLE-or-ANON fallback stops mattering entirely.
--
-- ── ⚠ AND IT FIXES A REAL DEFECT, NOT JUST A REFACTOR ──────────────────────
-- The existing lookup is `.ilike("client_code", code)` on RAW USER INPUT from
-- the login box. In `ilike`, `%` and `_` are WILDCARDS, so the login field is a
-- pattern-injection point. Measured on live data:
--
--     client_code ilike '%'        -> 276 of 439 clients match (first: 053-PV)
--     client_code ilike '16_-AVA'  -> 1 match  (underscore wildcard)
--     lower(client_code) = lower('%') -> 0     (the safe form)
--
-- A bare `%` may or may not authenticate depending on how the caller consumes
-- the result — 276 rows would make a `.maybeSingle()` throw. But that is luck,
-- not protection, and it does NOT save the general case: a NARROWING pattern
-- such as `168-A%` matches exactly ONE client and sails through any consumer.
-- So client codes are discoverable by narrowing (`1%` -> `16%` -> `168-A%`)
-- rather than needing to be known up front, which is precisely the property the
-- portal's security model assumes they do not have.
--
-- This function therefore does an EXACT, case-insensitive match and trims
-- whitespace. `%` and `_` become ordinary characters that simply match nothing.
-- ⚠ DO NOT "restore parity" by putting `ilike` back — the difference is the point.
--
-- ── SHAPE (per BA's spec) ──────────────────────────────────────────────────
--   customer.get_client_by_code('168-AVA') -> {"id":"…","slug":"168-ava","client_code":"168-AVA"}
--   customer.get_client_by_code('168-ava') -> same (case-insensitive)
--   customer.get_client_by_code('  168-AVA  ') -> same (trimmed)
--   customer.get_client_by_code('%')       -> NULL
--   customer.get_client_by_code('nope')    -> NULL
-- NULL on miss maps to the caller's existing `.maybeSingle()` null branch.
-- `slug` lives ONLY on customer.clients (public.clients has client_code but no
-- slug), so this reads the customer view — which is correct: it is the same
-- object the portal routes on.
--
-- ── SECURITY NOTES ─────────────────────────────────────────────────────────
-- SECURITY DEFINER with a pinned empty search_path (the pinning is the actual
-- hardening; SECDEF without it is the footgun). Every reference is
-- schema-qualified because of that. EXECUTE is stated explicitly rather than
-- inherited, since Supabase default privileges hand out EXECUTE nobody wrote.
--
-- ⚠ EXECUTE IS GRANTED TO anon DELIBERATELY, and it is a small existence oracle:
-- an anon caller can test whether a client code exists and learn its slug. That
-- is granted knowingly because (a) it is the entire point — the login must not
-- depend on which key is populated — and (b) it adds nothing beyond the residual
-- risk already documented in 28w: the /$clientSlug route is gated by the slug
-- alone, the slug is just the lowercased client_code, and it is printed on
-- invoices and manifests. It is NOT a secret today. If and when a per-client
-- secret is added to the portal link (the proper fix for that residual risk),
-- this grant should be narrowed to service_role in the same migration.
-- Note it returns ONE row and no contact/address data, so it is strictly weaker
-- than the pre-28w state where anon could enumerate all 439 clients outright.
--
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS customer.get_client_by_code(text);
--
-- AUDIT (ADR 010): read-only function, no business table touched.
-- ============================================================================

begin;

create or replace function customer.get_client_by_code(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'id',          c.id,
           'slug',        c.slug,
           'client_code', c.client_code)
    from customer.clients c
   where p_code is not null
     and length(btrim(p_code)) > 0
     -- EXACT case-insensitive match on purpose: `%` / `_` must NOT be wildcards
     and lower(c.client_code) = lower(btrim(p_code));
$$;

revoke execute on function customer.get_client_by_code(text) from public;
grant  execute on function customer.get_client_by_code(text) to anon, authenticated;

commit;
