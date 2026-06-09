// 118_apply_derm_schema.mjs
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
const sql = readFileSync('docs/migrations/2026-05-27_derm_multipage_and_softdelete.sql', 'utf8');
console.log('=== Applying ===');
console.log(await pg(sql));
console.log('\n=== Verify derm_manifests new columns ===');
console.log(await pg(`
  SELECT column_name, data_type, column_default
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='derm_manifests'
    AND column_name IN ('derm_manifest_extra_urls','derm_address_extra_urls','deleted_at')
  ORDER BY column_name;
`));
console.log('\n=== Verify manifest_pickable_visits view ===');
console.log(await pg(`
  SELECT COUNT(*)::int AS pickable_count
  FROM public.manifest_pickable_visits
  WHERE visit_date >= CURRENT_DATE - INTERVAL '60 days';
`));
