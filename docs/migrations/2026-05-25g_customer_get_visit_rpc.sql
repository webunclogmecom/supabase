-- 2026-05-25g_customer_get_visit_rpc.sql
--
-- IDOR fix Layer 2: server-enforced ownership check via RPC.
--
-- Even with 10-char base62 public_ids (1-in-8.4×10^17), nothing stops a
-- determined attacker from harvesting valid tokens (e.g. from a leak,
-- screenshot, share link) and then trying them under the wrong client slug.
-- The customer.work_orders view doesn't know about the URL slug — it just
-- returns the row matching the id filter. Without server-side ownership
-- enforcement, /001-vin/visit/{token-from-092-tce} would still return the
-- 092-tce visit's data.
--
-- This RPC enforces the ownership join: a visit is returned ONLY when the
-- caller's slug matches the visit's client. Empty result otherwise.
--
-- USAGE (Lovable / supabase-js):
--   const { data } = await supabase
--     .schema('customer')
--     .rpc('get_visit_by_slug_and_token', { p_slug: slug, p_token: token })
--     .single();
--
-- SECURITY DEFINER lets the function run with the view owner's privileges
-- (necessary to read clients.client_code, which anon may not have direct
-- access to). SET search_path = '' prevents schema-shadowing attacks.
-- STABLE allows query-plan caching within a transaction.

BEGIN;

CREATE OR REPLACE FUNCTION customer.get_visit_by_slug_and_token(
  p_slug  TEXT,
  p_token TEXT
)
RETURNS SETOF customer.work_orders
LANGUAGE SQL STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT wo.*
  FROM customer.work_orders wo
  JOIN public.clients c ON customer.uuid_from_bigint(c.id) = wo.client_id
  WHERE lower(c.client_code) = lower(p_slug)
    AND wo.id = p_token;
$function$;

COMMENT ON FUNCTION customer.get_visit_by_slug_and_token(TEXT, TEXT) IS
  'Server-enforced visit lookup: returns the work_order row ONLY if the visit''s client matches the slug. Used by Field Portal''s visit detail page to prevent IDOR (cross-client visit access via guessed/leaked tokens).';

-- Grant execute to the anon role (FP uses anon) and authenticated for future
-- expansion. Members of the customer.work_orders SELECT grant are already
-- covered transitively by SECURITY DEFINER, but we still need anon to be
-- able to invoke the function itself.
GRANT EXECUTE ON FUNCTION customer.get_visit_by_slug_and_token(TEXT, TEXT)
  TO anon, authenticated;

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================
-- 1. Valid lookup returns one row:
--    SELECT (customer.get_visit_by_slug_and_token('092-tce', (
--      SELECT id FROM customer.work_orders LIMIT 1
--    ))).id;
--    Expected: 0 or 1 rows depending on whether the sampled wo belongs to 092-tce.
--
-- 2. Wrong slug returns zero rows (IDOR test):
--    SELECT * FROM customer.get_visit_by_slug_and_token('wrong-slug',
--      (SELECT id FROM customer.work_orders LIMIT 1));
--    Expected: 0 rows.
--
-- 3. PostgREST end-to-end (anon role):
--    curl -X POST \
--      "https://wbasvhvvismukaqdnouk.supabase.co/rest/v1/rpc/get_visit_by_slug_and_token" \
--      -H "Accept-Profile: customer" \
--      -H "Content-Profile: customer" \
--      -H "Content-Type: application/json" \
--      -H "apikey: $ANON_KEY" \
--      -H "Authorization: Bearer $ANON_KEY" \
--      -d '{"p_slug": "092-tce", "p_token": "<valid-token>"}'
--    Expected: 200 with single-element array.
