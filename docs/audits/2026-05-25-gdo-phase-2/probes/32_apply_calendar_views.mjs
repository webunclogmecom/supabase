// 32_apply_calendar_views.mjs
// Apply 2026-05-26_calendar_ops_views.sql to Prod and verify.

import 'dotenv/config';
import { readFile } from 'node:fs/promises';

const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const FP = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;
const PROD_URL = process.env.SUPABASE_URL;
const ANON = (await readFile('C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env', 'utf8'))
  .match(/^SUPABASE_PUBLISHABLE_KEY=(.+)$/m)?.[1];

async function pg(project, sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${project}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${project} ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}

console.log('=== APPLYING ops.v_calendar_visit + truck + driver ===\n');

const sql = await readFile(
  'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/docs/migrations/2026-05-26_calendar_ops_views.sql',
  'utf8'
);

const apply = await pg(PROD, sql);
console.log('Apply result:', apply);

console.log('\n=== VERIFY (1) row count via Management API ===');
console.log(await pg(PROD, `SELECT count(*)::int AS n FROM ops.v_calendar_visit;`));

console.log('\n=== VERIFY (2) May 2026 visits ===');
console.log(await pg(PROD, `
  SELECT count(*)::int AS may_visits, count(DISTINCT client_id)::int AS distinct_clients
  FROM ops.v_calendar_visit
  WHERE visit_date BETWEEN '2026-05-01' AND '2026-05-31';
`));

console.log('\n=== VERIFY (3) late_status samples ===');
console.log(await pg(PROD, `
  SELECT id, visit_date, service_type, client_name, late_status, last_completed_date, frequency_days
  FROM ops.v_calendar_visit
  WHERE late_status IN ('late','will_be_late')
  LIMIT 8;
`));

console.log('\n=== VERIFY (4) Truck list ===');
console.log(await pg(PROD, `SELECT id, name, status FROM ops.v_calendar_truck;`));

console.log('\n=== VERIFY (5) Driver list (sample) ===');
console.log(await pg(PROD, `SELECT id, full_name, role, status FROM ops.v_calendar_driver LIMIT 8;`));

console.log('\n=== VERIFY (6) Sample row showing all denorm fields ===');
console.log(await pg(PROD, `
  SELECT id, visit_date, visit_status, service_type, amount,
         client_code, client_name, zone, city,
         frequency_days, equipment_size_gallons, gdo_number, gdo_expiration,
         truck_name, driver_name, late_status, last_completed_date
  FROM ops.v_calendar_visit
  WHERE visit_date BETWEEN '2026-05-01' AND '2026-05-31'
  ORDER BY visit_date
  LIMIT 5;
`));

console.log('\n=== VERIFY (7) Anon REST smoke (Accept-Profile: ops) ===');
if (!ANON) {
  console.log('  (SUPABASE_PUBLISHABLE_KEY missing from .env — skipping REST smoke)');
} else {
  const url = `${PROD_URL}/rest/v1/v_calendar_visit?select=id,client_name,zone,visit_date,late_status&visit_date=gte.2026-05-01&visit_date=lte.2026-05-31&limit=3`;
  const r = await fetch(url, {
    headers: {
      apikey: ANON,
      Authorization: `Bearer ${ANON}`,
      'Accept-Profile': 'ops',
    },
  });
  const body = await r.text();
  console.log(`  HTTP ${r.status}`);
  console.log('  body:', body.slice(0, 800));
}

console.log('\nDONE.');
