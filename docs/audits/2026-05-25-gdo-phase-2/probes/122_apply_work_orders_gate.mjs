// 122_apply_work_orders_gate.mjs
// Apply docs/migrations/2026-05-27_customer_work_orders_hide_dump_run_sheet.sql
// to Prod via Management API, then re-probe visit 5079 to confirm the fix.
import 'dotenv/config';
import { readFileSync } from 'node:fs';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 1200)}`);
  return JSON.parse(body);
}

const sql = readFileSync('docs/migrations/2026-05-27_customer_work_orders_hide_dump_run_sheet.sql', 'utf8');

console.log('=== Applying 2026-05-27_customer_work_orders_hide_dump_run_sheet.sql ===');
console.log(await pg(sql));

console.log('\n=== Verify: visit 5079 (client 369, 2026-05-12) post-fix ===');
console.log(await pg(`
  SELECT id, client_id, visit_date, derm_manifest_number,
         derm_manifest_url AS should_be_null,
         wwtp_receipt_url, manifest_jurisdiction
  FROM customer.work_orders
  WHERE client_id::text = customer.uuid_from_bigint(369)::text
    AND visit_date = '2026-05-12';
`));

console.log('\n=== Aggregate: derm_manifest_url should now always be NULL ===');
console.log(await pg(`
  SELECT COUNT(*) FILTER (WHERE derm_manifest_url IS NOT NULL) AS exposed_addrs,
         COUNT(*) FILTER (WHERE wwtp_receipt_url IS NOT NULL)  AS exposed_manifs,
         COUNT(*) AS total_work_orders
  FROM customer.work_orders;
`));

console.log('\n=== Live view definition — derm_manifest_url expression ===');
const def = await pg(`SELECT pg_get_viewdef('customer.work_orders'::regclass, true) AS def;`);
const text = def[0]?.def || '';
const m = text.match(/[^,]+AS derm_manifest_url/);
console.log(m ? m[0].trim() : '(not found, full def below)');
if (!m) console.log(text.slice(0, 2000));

console.log('\n=== Grants ===');
console.log(await pg(`
  SELECT grantee, privilege_type
  FROM information_schema.role_table_grants
  WHERE table_schema='customer' AND table_name='work_orders'
  ORDER BY grantee, privilege_type;
`));
