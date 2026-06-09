// 29_final_sandbox_smoke.mjs
// Final smoke test on HR sandbox after schema clone + topup + grants.

import 'dotenv/config';

const PAT = process.env.SUPABASE_PAT;
const FP = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${FP}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 300)}`);
  return JSON.parse(body);
}

console.log('=== FINAL HR SANDBOX STATE ===\n');

console.log('-- All schemas --');
console.log(await pg(`SELECT schema_name FROM information_schema.schemata
  WHERE schema_name NOT LIKE 'pg_%' AND schema_name NOT IN ('information_schema')
  ORDER BY 1;`));

console.log('\n-- Tables in public --');
const tables = await pg(`SELECT table_name FROM information_schema.tables
  WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1;`);
console.log(`  ${tables.length} tables`);

console.log('\n-- Tables in audit --');
const auditTables = await pg(`SELECT table_name FROM information_schema.tables
  WHERE table_schema='audit' ORDER BY 1;`);
console.log(`  ${auditTables.length} tables: ${auditTables.map(t => t.table_name).join(', ')}`);

console.log('\n-- Triggers calling audit.log_change() --');
const triggers = await pg(`SELECT event_object_table, count(*) AS n FROM information_schema.triggers
  WHERE action_statement ILIKE '%audit.log_change%'
  GROUP BY event_object_table ORDER BY 1;`);
console.log(`  ${triggers.length} tables audit-wired: ${triggers.map(t => t.event_object_table).join(', ')}`);

console.log('\n-- service_role grants on public.employees --');
console.log(await pg(`SELECT grantee, privilege_type FROM information_schema.role_table_grants
  WHERE table_schema='public' AND table_name='employees' AND grantee='service_role'
  ORDER BY 2;`));

console.log('\n-- anon statement_timeout --');
console.log(await pg(`SELECT rolname, rolconfig FROM pg_roles WHERE rolname='anon';`));

console.log('\n-- Key table counts --');
const counts = await pg(`SELECT
  (SELECT count(*) FROM public.employees) AS employees,
  (SELECT count(*) FROM public.vehicles) AS vehicles,
  (SELECT count(*) FROM public.clients) AS clients,
  (SELECT count(*) FROM public.visits) AS visits,
  (SELECT count(*) FROM public.gdos) AS gdos,
  (SELECT count(*) FROM public.derm_manifests) AS derm_manifests,
  (SELECT count(*) FROM public.entity_source_links) AS entity_source_links;`);
console.log(counts);

console.log('\nDONE.');
