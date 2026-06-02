// 126_apply_zones_crud.mjs
// Apply docs/migrations/2026-05-28_zones_allow_crud_from_calendar.sql
// + verify all gates including the immutable-code trigger.
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

console.log('=== Apply ===');
console.log(await pg(readFileSync('docs/migrations/2026-05-28_zones_allow_crud_from_calendar.sql', 'utf8')));

console.log('\n=== Verify 1: grants ===');
console.log(await pg(`
  SELECT grantee, privilege_type
  FROM information_schema.role_table_grants
  WHERE table_schema='public' AND table_name='zones'
    AND grantee IN ('anon','authenticated')
  ORDER BY grantee, privilege_type;
`));

console.log('\n=== Verify 2: policies ===');
console.log(await pg(`
  SELECT policyname, cmd FROM pg_policies WHERE tablename='zones' ORDER BY cmd, policyname;
`));

console.log('\n=== Verify 3: zones_with_usage view ===');
console.log(await pg(`
  SELECT code, label, is_active, n_properties
  FROM public.zones_with_usage
  ORDER BY sort_order;
`));

console.log('\n=== Verify 4: code immutability trigger should reject rename ===');
try {
  await pg(`UPDATE public.zones SET code='SOUTH_TEST' WHERE code='SOUTH';`);
  console.log('  FAIL — rename allowed, trigger missing or broken.');
} catch (e) {
  console.log('  OK — rename blocked:', e.message.split('ERROR:')[1]?.slice(0, 220).trim());
}

console.log('\n=== Verify 5: code immutability does NOT block other updates ===');
console.log(await pg(`
  UPDATE public.zones SET sort_order = sort_order WHERE code='SOUTH'
  RETURNING code, label, sort_order, updated_at;
`));

console.log('\n=== Verify 6: hard DELETE should be blocked (no DELETE policy) ===');
// Direct service-role pg() bypasses RLS, so we test via the policy listing.
// The absence of a DELETE policy means anon/authenticated DELETEs are denied.
console.log(await pg(`
  SELECT (SELECT count(*) FROM pg_policies WHERE tablename='zones' AND cmd='DELETE') AS delete_policy_count;
`));
