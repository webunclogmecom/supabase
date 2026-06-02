// 125_lock_zones_writes.mjs
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
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 800)}`);
  return JSON.parse(body);
}
console.log('=== Apply ===');
console.log(await pg(readFileSync('docs/migrations/2026-05-27_zones_lock_anon_writes.sql', 'utf8')));

console.log('\n=== Verify 1: anon/authenticated grants ===');
console.log(await pg(`
  SELECT grantee, privilege_type
  FROM information_schema.role_table_grants
  WHERE table_schema='public' AND table_name='zones'
    AND grantee IN ('anon','authenticated')
  ORDER BY grantee, privilege_type;
`));

console.log('\n=== Verify 2: RLS enabled ===');
console.log(await pg(`SELECT relname, relrowsecurity FROM pg_class WHERE relname='zones';`));

console.log('\n=== Verify 3: policies ===');
console.log(await pg(`SELECT policyname, cmd, roles, qual FROM pg_policies WHERE tablename='zones';`));

console.log('\n=== Verify 4: anon SELECT still works (count via SQL) ===');
console.log(await pg(`SELECT COUNT(*)::int AS n FROM public.zones WHERE is_active;`));
