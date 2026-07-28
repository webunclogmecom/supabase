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
-- ── DEFENCE IN DEPTH: exact match instead of `ilike` ───────────────────────
-- ⚠ READ THIS WHOLE SECTION BEFORE CITING IT. An earlier draft of this header
-- called the old lookup a live pattern injection. THAT WAS WRONG and is
-- corrected here: it is NOT exploitable on the live app.
--
-- The existing lookup is `.ilike("client_code", code)`, and in `ilike` both `%`
-- and `_` are WILDCARDS. At the QUERY level that is genuinely unsafe on raw
-- input — measured on live data:
--
--     client_code ilike '%'        -> 276 of 439 clients match (first: 053-PV)
--     client_code ilike '16_-AVA'  -> 1 match  (underscore wildcard)
--     client_code ilike '168-A%'   -> exactly 1 match
--     lower(client_code) = lower('%') -> 0     (the safe form)
--
-- BUT THE INPUT NEVER REACHES THE QUERY. The same server function validates
-- first, in an `.inputValidator()` I could not see from the DB side:
--     code = data.code.trim().toUpperCase()
--     if (!code || code.length > 32 || !/^[A-Z0-9-]+$/.test(code)) throw
-- `%` and `_` are not in `[A-Z0-9-]`, so they are rejected before PostgREST is
-- called. BA proved it from the edge log rather than by reading the regex, with
-- a positive control so the negatives meant something:
--     168-A%   -> NO DB REQUEST AT ALL (validator threw)
--     %        -> NO DB REQUEST AT ALL
--     16_-AVA  -> NO DB REQUEST AT ALL
--     999-ZZZ  -> GET ...client_code=ilike.999-ZZZ 200  (well-formed, no match)
--     168-AVA  -> GET ...client_code=ilike.168-AVA 200  (positive control)
--
-- So this migration is NOT an incident fix. The exact match is kept anyway, on
-- its own merits: today the only thing between raw login input and a LIKE
-- pattern is one regex in one file, with nothing enforcing that it stays
-- correct. `lower(x) = lower(btrim(p))` removes the class of bug rather than
-- relying on a guard holding. `%` and `_` become ordinary characters.
-- ⚠ DO NOT "restore parity" by putting `ilike` back — the difference is the point.
--
-- LESSON (mine, worth keeping): I reasoned from the query shape to
-- exploitability without being able to see the caller, and asserted a narrowing
-- attack "sails through any consumer" when in fact nothing reached the consumer.
-- The validator was invisible from the DB side for exactly the same reason the
-- `.from("clients")` was invisible to both bundle audits — both live inside that
-- one server function. **A query-level defect is not a vulnerability until you
-- have seen the caller. Say "unsafe shape, reachability unverified" instead.**
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
