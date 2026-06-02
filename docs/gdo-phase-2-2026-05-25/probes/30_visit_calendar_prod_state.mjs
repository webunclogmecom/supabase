// 30_visit_calendar_prod_state.mjs
// Discover Prod state for Visit Calendar migration:
//   1. Does ops schema exist?
//   2. What ops.* views exist?
//   3. Does service_configs have property_id column?
//   4. PostgREST db_schema (via Management API)
//   5. RLS state on relevant public tables
//   6. Sample data sanity checks (visit_status values, vehicles, etc.)

import 'dotenv/config';

const PAT = process.env.SUPABASE_PAT;
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

console.log('=== PROD STATE FOR VISIT CALENDAR ===\n');

console.log('-- 1. Does ops schema exist? --');
const opsExists = await pg(`SELECT schema_name FROM information_schema.schemata WHERE schema_name='ops';`);
console.log('  ', opsExists);

console.log('\n-- 2. ops.* objects (tables + views) --');
const opsObjects = await pg(`
  SELECT table_name, table_type FROM information_schema.tables
  WHERE table_schema='ops' ORDER BY table_type, table_name;
`);
console.log(`  ${opsObjects.length} objects:`);
for (const o of opsObjects) console.log(`     ${o.table_type.padEnd(10)} ${o.table_name}`);

console.log('\n-- 3. service_configs.property_id column? --');
const colCheck = await pg(`
  SELECT column_name, data_type, is_nullable FROM information_schema.columns
  WHERE table_schema='public' AND table_name='service_configs' AND column_name='property_id';
`);
console.log('  ', colCheck.length ? colCheck[0] : 'COLUMN MISSING');

console.log('\n-- 4. PostgREST db_schema config --');
const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/postgrest`, {
  headers: { Authorization: `Bearer ${PAT}` },
});
const cfg = await r.json();
console.log(`  db_schema:        "${cfg.db_schema}"`);
console.log(`  db_extra_search_path: "${cfg.db_extra_search_path}"`);
console.log(`  max_rows:         ${cfg.max_rows}`);

console.log('\n-- 5. RLS state on canonical tables Calendar needs --');
const rls = await pg(`
  SELECT n.nspname AS schema, c.relname AS table, c.relrowsecurity AS rls_enabled
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relname IN ('clients','properties','service_configs','visits','vehicles')
  ORDER BY c.relname;
`);
console.log(rls);

console.log('\n-- 6. anon role grants on these tables --');
const grants = await pg(`
  SELECT table_name, privilege_type FROM information_schema.role_table_grants
  WHERE table_schema='public' AND grantee='anon'
    AND table_name IN ('clients','properties','service_configs','visits','vehicles')
  ORDER BY table_name, privilege_type;
`);
console.log(grants);

console.log('\n-- 7. Sample visit_status values (Calendar filters by these) --');
const visitStatus = await pg(`
  SELECT visit_status, count(*) FROM public.visits GROUP BY visit_status ORDER BY 2 DESC;
`);
console.log(visitStatus);

console.log('\n-- 8. Active vehicles --');
const vehicles = await pg(`SELECT id, name, status FROM public.vehicles ORDER BY id;`);
console.log(vehicles);

console.log('\n-- 9. Active employees (drivers) --');
const drivers = await pg(`SELECT id, full_name, role, status FROM public.employees ORDER BY id;`);
console.log(`  ${drivers.length} employees, sample:`);
for (const e of drivers.slice(0, 10)) console.log(`     [${e.id}] ${e.full_name} | role=${e.role} status=${e.status}`);

console.log('\n-- 10. Unique zones in properties --');
const zones = await pg(`SELECT zone, count(*) FROM public.properties WHERE zone IS NOT NULL GROUP BY zone ORDER BY 2 DESC;`);
console.log(zones);

console.log('\n-- 11. Visits in current month --');
const calendarRange = await pg(`
  SELECT count(*) AS visits_in_may, count(DISTINCT client_id) AS distinct_clients
  FROM public.visits
  WHERE visit_date BETWEEN '2026-05-01' AND '2026-05-31';
`);
console.log(calendarRange);

console.log('\n-- 12. anon statement_timeout --');
console.log(await pg(`SELECT rolname, rolconfig FROM pg_roles WHERE rolname='anon';`));

console.log('\nDONE.');
