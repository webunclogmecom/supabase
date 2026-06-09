// 33_apply_visit_write_rls.mjs
// Apply 2026-05-26_calendar_visit_anon_write_rls.sql + verify.

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

// Anon key from Management API
const keysRes = await fetch(`https://api.supabase.com/v1/projects/${PROD}/api-keys`, {
  headers: { Authorization: `Bearer ${PAT}` },
});
const keys = await keysRes.json();
const ANON = keys.find(k => k.name === 'anon')?.api_key;

const sql = await readFile(
  'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/docs/migrations/2026-05-26_calendar_visit_anon_write_rls.sql',
  'utf8'
);

console.log('=== APPLYING RLS migration ===');
console.log('Result:', await pg(sql));

console.log('\n=== VERIFY (1) policies on visits ===');
console.log(await pg(`
  SELECT policyname, cmd, roles::text[] FROM pg_policies
  WHERE schemaname='public' AND tablename='visits' ORDER BY policyname;
`));

console.log('\n=== VERIFY (2) column UPDATE grants on visits ===');
console.log(await pg(`
  SELECT column_name, privilege_type
  FROM information_schema.column_privileges
  WHERE table_schema='public' AND table_name='visits' AND grantee='anon'
    AND privilege_type='UPDATE'
  ORDER BY column_name;
`));

console.log('\n=== VERIFY (3) visit_assignments policies ===');
console.log(await pg(`
  SELECT policyname, cmd, roles::text[] FROM pg_policies
  WHERE schemaname='public' AND tablename='visit_assignments' ORDER BY policyname;
`));

console.log('\n=== VERIFY (4) anon PATCH smoke test ===');
// Pick a scheduled visit and try to UPDATE its visit_date by +1 day, then revert.
const v = (await pg(`
  SELECT id, visit_date FROM public.visits
  WHERE visit_status='scheduled' AND visit_date >= CURRENT_DATE
  ORDER BY visit_date LIMIT 1;
`))[0];
console.log(`  Picked visit ${v.id} (currently visit_date=${v.visit_date})`);
const newDate = (new Date(new Date(v.visit_date).getTime() + 86400_000)).toISOString().slice(0,10);
console.log(`  Trying to UPDATE visit_date to ${newDate} via REST...`);

const upRes = await fetch(
  `${PROD_URL}/rest/v1/visits?id=eq.${v.id}`,
  {
    method: 'PATCH',
    headers: {
      apikey: ANON,
      Authorization: `Bearer ${ANON}`,
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
      'X-App-Source': 'visit-calendar',
    },
    body: JSON.stringify({ visit_date: newDate }),
  }
);
const upBody = await upRes.text();
console.log(`  HTTP ${upRes.status}`);
console.log(`  body: ${upBody.slice(0, 400)}`);

// Revert
const revertRes = await fetch(
  `${PROD_URL}/rest/v1/visits?id=eq.${v.id}`,
  {
    method: 'PATCH',
    headers: {
      apikey: ANON,
      Authorization: `Bearer ${ANON}`,
      'Content-Type': 'application/json',
      'X-App-Source': 'visit-calendar',
    },
    body: JSON.stringify({ visit_date: v.visit_date }),
  }
);
console.log(`  Revert: HTTP ${revertRes.status}`);

console.log('\n=== VERIFY (5) anon should NOT be allowed to UPDATE forbidden columns (e.g. title) ===');
const forbid = await fetch(
  `${PROD_URL}/rest/v1/visits?id=eq.${v.id}`,
  {
    method: 'PATCH',
    headers: {
      apikey: ANON,
      Authorization: `Bearer ${ANON}`,
      'Content-Type': 'application/json',
      'X-App-Source': 'visit-calendar',
    },
    body: JSON.stringify({ title: 'HACK ATTEMPT' }),
  }
);
const forbidBody = await forbid.text();
console.log(`  HTTP ${forbid.status} (expect 4xx)`);
console.log(`  body: ${forbidBody.slice(0, 300)}`);

console.log('\nDONE.');
