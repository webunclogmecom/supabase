// 27_prod_audit_schema_inspect.mjs
// Inspect Prod's audit schema via Supabase Management API SQL endpoint.

import 'dotenv/config';

const PAT  = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}

console.log('=== Prod audit schema inspection ===\n');

console.log('-- schemas containing "audit" --');
console.log(await pg(`SELECT schema_name FROM information_schema.schemata WHERE schema_name ILIKE '%audit%' ORDER BY 1;`));

console.log('\n-- tables in audit schema --');
console.log(await pg(`SELECT table_name FROM information_schema.tables WHERE table_schema='audit' ORDER BY 1;`));

console.log('\n-- functions in audit schema --');
console.log(await pg(`SELECT routine_name FROM information_schema.routines WHERE routine_schema='audit' ORDER BY 1;`));

console.log('\n-- public objects referencing audit schema (count) --');
console.log(await pg(`SELECT count(*) AS refs FROM pg_catalog.pg_depend d
  JOIN pg_catalog.pg_namespace ns ON ns.oid = d.refobjid
  WHERE ns.nspname = 'audit';`));
