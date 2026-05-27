// 117_apply_manifests_bucket.mjs
// Create the missing 'manifests' storage bucket + RLS policies.
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

const sql = readFileSync('docs/migrations/2026-05-27_create_manifests_bucket.sql', 'utf8');

console.log('=== Applying ===');
console.log(await pg(sql));

console.log('\n=== Verify bucket exists ===');
console.log(await pg(`
  SELECT id, name, public, file_size_limit, allowed_mime_types
  FROM storage.buckets WHERE id='manifests';
`));

console.log('\n=== Verify policies on manifests bucket ===');
console.log(await pg(`
  SELECT policyname, cmd, roles
  FROM pg_policies
  WHERE schemaname='storage' AND tablename='objects'
    AND policyname ILIKE '%manifests%'
  ORDER BY cmd, policyname;
`));
