// 65_apply_audit_visit_assignments.mjs
// Apply the audit trigger migration to public.visit_assignments.
// Re-runnable: uses DO block + pg_trigger existence check.
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

const sql = readFileSync('docs/migrations/2026-05-27_audit_visit_assignments.sql', 'utf8');

console.log('=== Applying audit trigger migration ===');
console.log(await pg(sql));

console.log('\n=== Verify trigger exists ===');
console.log(await pg(`
  SELECT tgname, pg_get_triggerdef(oid) AS def
  FROM pg_trigger
  WHERE tgrelid = 'public.visit_assignments'::regclass AND NOT tgisinternal;
`));
