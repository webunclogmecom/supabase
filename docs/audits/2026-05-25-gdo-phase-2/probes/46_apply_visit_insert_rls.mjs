// 46_apply_visit_insert_rls.mjs
// Apply 2026-05-26_calendar_visit_anon_insert_rls.sql + smoke test
// the anon INSERT path with + without source='visit-calendar'.

import 'dotenv/config';
import { readFile } from 'node:fs/promises';

const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const PROD_URL = process.env.SUPABASE_URL;

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

// Anon key
const keys = await (await fetch(`https://api.supabase.com/v1/projects/${PROD}/api-keys`, { headers: { Authorization: `Bearer ${PAT}` } })).json();
const ANON = keys.find(k => k.name === 'anon')?.api_key;

const sql = await readFile(
  'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/docs/migrations/2026-05-26_calendar_visit_anon_insert_rls.sql',
  'utf8'
);

console.log('=== APPLYING anon INSERT RLS ===');
console.log('Result:', await pg(sql));

console.log('\n=== VERIFY (1) policies on visits ===');
console.log(await pg(`
  SELECT policyname, cmd, roles::text[] FROM pg_policies
  WHERE schemaname='public' AND tablename='visits' AND cmd='INSERT'
  ORDER BY policyname;
`));

console.log('\n=== VERIFY (2) INSERT column grants ===');
console.log(await pg(`
  SELECT column_name FROM information_schema.column_privileges
  WHERE table_schema='public' AND table_name='visits' AND grantee='anon'
    AND privilege_type='INSERT'
  ORDER BY column_name;
`));

console.log('\n=== VERIFY (3) Smoke INSERT with source=visit-calendar (should succeed) ===');
const goodPayload = {
  client_id: 1794 ? 51 : 51,  // safe known-active client id (Pura Vida something)
  visit_date: '2027-01-15',
  service_type: 'GT',
  visit_status: 'scheduled',
  source: 'visit-calendar',
  title: 'SMOKE TEST — should be deleted immediately',
};
let r = await fetch(`${PROD_URL}/rest/v1/visits`, {
  method: 'POST',
  headers: {
    apikey: ANON, Authorization: `Bearer ${ANON}`,
    'Content-Type': 'application/json',
    Prefer: 'return=representation',
    'X-App-Source': 'visit-calendar',
  },
  body: JSON.stringify(goodPayload),
});
let body = await r.text();
console.log(`  HTTP ${r.status}`);
console.log(`  body: ${body.slice(0, 500)}`);

// Capture id for cleanup
let createdId = null;
try {
  const parsed = JSON.parse(body);
  if (Array.isArray(parsed) && parsed[0]?.id) createdId = parsed[0].id;
} catch {}

console.log('\n=== VERIFY (4) Smoke INSERT WITHOUT source=visit-calendar (should be REJECTED) ===');
const badPayload = { ...goodPayload, source: 'jobber' };
r = await fetch(`${PROD_URL}/rest/v1/visits`, {
  method: 'POST',
  headers: { apikey: ANON, Authorization: `Bearer ${ANON}`, 'Content-Type': 'application/json' },
  body: JSON.stringify(badPayload),
});
body = await r.text();
console.log(`  HTTP ${r.status} (expect 4xx)`);
console.log(`  body: ${body.slice(0, 300)}`);

console.log('\n=== CLEAN UP smoke test row ===');
if (createdId) {
  console.log(`  Deleting test visit id=${createdId} (via Management API, bypasses RLS)...`);
  console.log(await pg(`DELETE FROM public.visits WHERE id=${createdId} RETURNING id, title;`));
} else {
  console.log('  No row to delete.');
}

console.log('\nDONE.');
