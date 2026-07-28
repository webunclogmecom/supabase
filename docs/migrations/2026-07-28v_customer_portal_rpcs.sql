-- ============================================================================
-- 2026-07-28v — two scoped SECURITY DEFINER RPCs so the Field Portal can stop
--               reading the `customer` views directly
-- ============================================================================
-- ⚠ THIS MIGRATION IS ADDITIVE AND SAFE TO APPLY ALONE. It revokes NOTHING.
-- The matching revoke is a SEPARATE migration (28w) gated on Building Apps
-- confirming the Field Portal is live on these RPCs. Same staged pattern as
-- 28r (Stamp Studio) / 28s (DERM Tracker) / 28u (ops).
--
-- ── THE PROBLEM ────────────────────────────────────────────────────────────
-- All 9 objects in `customer` are anon-readable, and `customer` is a
-- PostgREST-exposed schema. Anyone with the publishable key (it ships in every
-- Lovable bundle and is readable from page source) can enumerate the whole
-- client book with no slug and no token:
--     customer.clients          439
--     customer.work_orders      591   (carries storage URLs)
--     customer.scheduled_visits 709
--     customer.wo_photos        313
--     customer.permits          128
--     customer.gdo_reports       78
--   = 2,258 rows
-- Grant origin: 2026-05-14c_customer_schema.sql:318-330.
--
-- ── WHY A REVOKE ALONE CANNOT FIX IT ───────────────────────────────────────
-- The Field Portal is customer-facing with NO login BY DESIGN, so it must keep
-- reading as anon. Measured from the live bundle at fp.unclogme.app 2026-07-28,
-- it reads EIGHT customer views directly and scopes them CLIENT-SIDE:
--
--   route /$clientSlug                     (slug only, NO token)
--     clients               .eq(slug)              .maybeSingle()
--     permits               .eq(client_id)         .order(position)
--     work_orders           .eq(client_id)         .order(visit_date desc)
--     scheduled_visits      .eq(client_id)         .order(scheduled_date asc)
--     client_access_photos  .eq(client_id)         .order(position)
--
--   route /$clientSlug/visit/$visitId      (opaque 10-char work_order id)
--     work_orders           .eq(id)                .maybeSingle()
--     clients               .eq(id = wo.client_id) .single()
--     permits               .eq(client_id)         .order(position)
--     inspection_items      .eq(work_order_id)     .order(position)
--     recommendations       .eq(work_order_id)     .order(position)
--     wo_photos             .eq(work_order_id)     .order(position)
--
-- Client-side scoping is not scoping. Dropping the filter returns everything.
--
-- ⚠ The pre-existing customer.get_visit_by_slug_and_token(text,text) is NOT a
-- drop-in: it returns SETOF customer.work_orders only (no client, no permits,
-- no line detail), and the Field Portal DOES NOT CALL IT — the live bundle
-- contains ZERO .rpc() calls. It was built and never wired up. These two new
-- functions replace what the app actually does, view for view.
--
-- ── WHAT THESE RETURN ──────────────────────────────────────────────────────
-- One jsonb payload per route, keys named for the app's existing state fields,
-- built with to_jsonb(view) so the column shape tracks the views automatically
-- and never needs updating here when a view gains a column.
-- Both return NULL when nothing matches, which maps to .maybeSingle() → null.
--
-- ── SECURITY NOTES ─────────────────────────────────────────────────────────
-- SECURITY DEFINER + `SET search_path = ''` (pinning is the actual hardening;
-- SECDEF without it is the footgun — see CLAUDE.md "Grants, views and functions").
-- Every reference below is schema-qualified because of that empty search_path.
-- EXECUTE is granted to anon deliberately: this is the anon read path.
--
-- ⚠ RESIDUAL RISK, STATED PLAINLY — these RPCs do NOT make the slug route safe,
-- they only stop bulk enumeration. `/$clientSlug` is gated by the slug ALONE
-- (e.g. `015-fla`, the lowercased client_code), which is not a secret: it is
-- printed on invoices and manifests and is partly sequential. After this change
-- an attacker can no longer dump 439 clients in one request, but CAN still walk
-- client codes to reach individual client histories. Closing that needs a
-- per-client secret in the link — a product + link-distribution decision for
-- Fred, tracked separately. Do not describe this migration as closing `customer`.
--
-- The work-order route is gated by an opaque 10-char id (public.visits.public_id,
-- e.g. `nZuHhGhbpc`), which IS a reasonable bearer token. An earlier audit claim
-- that this token is a derivable zero-padded row id was REFUTED on inspection —
-- do not rebuild the token scheme on that theory.
--
-- The slug segment on the work-order route stays decorative (the lookup keys on
-- the opaque id alone), exactly as the app behaves today. Enforcing the pair was
-- considered and rejected: the slug is not secret so it adds no real factor,
-- while it WOULD break every existing link on a client-code renumber.
--
-- AUDIT (ADR 010): read-only functions, no business table touched, no audit
-- trigger applicable.
--
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS customer.get_client_portal(text);
--   DROP FUNCTION IF EXISTS customer.get_work_order(text);
-- ============================================================================

begin;

-- ── route /$clientSlug ──────────────────────────────────────────────────────
create or replace function customer.get_client_portal(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'client', to_jsonb(c),
    'permits', (
      select coalesce(jsonb_agg(to_jsonb(p) order by p.position), '[]'::jsonb)
        from customer.permits p where p.client_id = c.id),
    'work_orders', (
      select coalesce(jsonb_agg(to_jsonb(w) order by w.visit_date desc), '[]'::jsonb)
        from customer.work_orders w where w.client_id = c.id),
    'scheduled_visits', (
      select coalesce(jsonb_agg(to_jsonb(s) order by s.scheduled_date asc), '[]'::jsonb)
        from customer.scheduled_visits s where s.client_id = c.id),
    'access_photos', (
      select coalesce(jsonb_agg(to_jsonb(a) order by a.position), '[]'::jsonb)
        from customer.client_access_photos a where a.client_id = c.id)
  )
  from customer.clients c
  where lower(c.slug) = lower(p_slug);
$$;

-- ── route /$clientSlug/visit/$visitId ───────────────────────────────────────
create or replace function customer.get_work_order(p_work_order_id text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'work_order', to_jsonb(w),
    'client', (
      select to_jsonb(c) from customer.clients c where c.id = w.client_id),
    'permits', (
      select coalesce(jsonb_agg(to_jsonb(p) order by p.position), '[]'::jsonb)
        from customer.permits p where p.client_id = w.client_id),
    'inspection_items', (
      select coalesce(jsonb_agg(to_jsonb(i) order by i.position), '[]'::jsonb)
        from customer.inspection_items i where i.work_order_id = w.id),
    'recommendations', (
      select coalesce(jsonb_agg(to_jsonb(r) order by r.position), '[]'::jsonb)
        from customer.recommendations r where r.work_order_id = w.id),
    'photos', (
      select coalesce(jsonb_agg(to_jsonb(ph) order by ph.position), '[]'::jsonb)
        from customer.wo_photos ph where ph.work_order_id = w.id)
  )
  from customer.work_orders w
  where w.id = p_work_order_id;
$$;

-- Supabase's ALTER DEFAULT PRIVILEGES hands EXECUTE to roles nobody named, so
-- state the grants explicitly rather than inheriting whatever the default is.
revoke execute on function customer.get_client_portal(text) from public;
revoke execute on function customer.get_work_order(text)    from public;

grant execute on function customer.get_client_portal(text) to anon, authenticated;
grant execute on function customer.get_work_order(text)    to anon, authenticated;

commit;
