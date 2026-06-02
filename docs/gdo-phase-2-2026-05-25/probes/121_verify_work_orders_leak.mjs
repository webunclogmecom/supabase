// 121_verify_work_orders_leak.mjs
// Cold-verify the Path C diagnosis on visit 5079:
//   1. customer.work_orders for visit 5079 currently exposes the address PDF
//      (`derm_manifest_url` is non-null and points at derm/1043/address.jpg).
//   2. manifest 1043 is linked only to 009-CN's own visits (5079 + 5082),
//      so the distinct-client-count via manifest_visits = 1.
//   3. The current Path C predicate (COUNT > 1 over derm_manifests sharing
//      white_manifest_number) returns 1 → gate lets it through.
//   4. Live view definition still uses the broken predicate (sanity check
//      against 2026-05-25b).
//
// Read-only. Touches nothing.
import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 800)}`);
  return JSON.parse(body);
}

console.log('=== 1. visit 5079 row ===');
console.log(await pg(`
  SELECT v.id, v.client_id, c.client_code, c.name,
         v.visit_date, v.visit_status, v.service_type, v.derm_required
  FROM public.visits v JOIN public.clients c ON c.id = v.client_id
  WHERE v.id = 5079;
`));

console.log('\n=== 2. manifest 1043 row ===');
console.log(await pg(`
  SELECT id, white_manifest_number, derm_address_url, derm_manifest_url,
         service_date, deleted_at
  FROM public.derm_manifests WHERE id = 1043;
`));

console.log('\n=== 3. manifest_visits for manifest 1043 (and distinct-client count) ===');
console.log(await pg(`
  SELECT mv.manifest_id, mv.visit_id, v.client_id, c.client_code, c.name,
         v.visit_date, v.service_type
  FROM public.manifest_visits mv
  JOIN public.visits v ON v.id = mv.visit_id
  JOIN public.clients c ON c.id = v.client_id
  WHERE mv.manifest_id = 1043
  ORDER BY mv.visit_id;
`));
console.log(await pg(`
  SELECT COUNT(DISTINCT v.client_id) AS distinct_clients
  FROM public.manifest_visits mv
  JOIN public.visits v ON v.id = mv.visit_id
  WHERE mv.manifest_id = 1043;
`));

console.log('\n=== 4. broken Path C predicate state (derm_manifests sharing white_manifest_number=824273) ===');
console.log(await pg(`
  SELECT id, client_id, service_date, derm_address_url
  FROM public.derm_manifests
  WHERE white_manifest_number = '824273'
  ORDER BY id;
`));
console.log(await pg(`
  SELECT COUNT(*)::int AS same_wmn_rows
  FROM public.derm_manifests
  WHERE white_manifest_number = '824273';
`));

console.log('\n=== 5a. Resolve customer.uuid_from_bigint(5079) and look up by id ===');
console.log(await pg(`SELECT customer.uuid_from_bigint(5079) AS wo_id;`));

console.log('\n=== 5b. customer.work_orders for client 369 around 2026-05-12 (find by client+date) ===');
console.log(await pg(`
  SELECT id, client_id, visit_date, derm_manifest_number,
         derm_manifest_url AS exposed_address_url,
         wwtp_receipt_url, manifest_jurisdiction
  FROM customer.work_orders
  WHERE client_id::text = customer.uuid_from_bigint(369)::text
    AND visit_date = '2026-05-12'
  ORDER BY visit_date;
`));

console.log('\n=== 5c. Direct id match (text-cast both) ===');
console.log(await pg(`
  SELECT id, client_id, visit_date, derm_manifest_number,
         derm_manifest_url AS exposed_address_url,
         wwtp_receipt_url, manifest_jurisdiction
  FROM customer.work_orders
  WHERE id::text = customer.uuid_from_bigint(5079)::text;
`));

console.log('\n=== 6. Live view definition sanity check (look for the broken predicate) ===');
const def = await pg(`
  SELECT pg_get_viewdef('customer.work_orders'::regclass, true) AS def;
`);
// Print just the gate snippet
const text = def[0]?.def || '';
const m = text.match(/CASE[^E]*WHEN dm\.id IS NULL[\s\S]*?END AS derm_manifest_url/);
console.log(m ? m[0].slice(0, 600) : '(predicate snippet not found, full def below)');
if (!m) console.log(text.slice(0, 1200));

console.log('\n=== 7. Scope of broader leak — other manifest_visits with manifest_id linking to single derm_manifests row but multi-client when shared sheet ===');
// Heuristic: count work_orders that currently EXPOSE derm_manifest_url where
// the underlying manifest is the only derm_manifests row but multi-client via
// other paths (other manifests sharing the same physical sheet). Hard to know
// without the multi-client flag; instead count visits currently exposing the
// address PDF (will be the affected universe after option 1).
console.log(await pg(`
  SELECT COUNT(*) FILTER (WHERE derm_manifest_url IS NOT NULL) AS currently_exposed_address_urls,
         COUNT(*) FILTER (WHERE wwtp_receipt_url IS NOT NULL) AS currently_exposed_manifest_urls,
         COUNT(*) AS total_work_orders
  FROM customer.work_orders;
`));
