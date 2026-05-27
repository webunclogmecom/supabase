// 63_visit_assignments_schema.mjs
// The view derives driver from public.visit_assignments. Confirm schema + RLS + audit setup.
import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}

console.log('=== A. visit_assignments columns ===');
console.log(await pg(`
  SELECT column_name, data_type, is_nullable
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='visit_assignments'
  ORDER BY ordinal_position;
`));

console.log('\n=== B. visit_assignments PK + unique constraints ===');
console.log(await pg(`
  SELECT con.conname, con.contype, pg_get_constraintdef(con.oid) AS def
  FROM pg_constraint con
  JOIN pg_class cls ON cls.oid = con.conrelid
  WHERE cls.relname = 'visit_assignments';
`));

console.log('\n=== C. RLS policies on visit_assignments ===');
console.log(await pg(`
  SELECT policyname, cmd, qual, with_check
  FROM pg_policies
  WHERE schemaname='public' AND tablename='visit_assignments'
  ORDER BY policyname;
`));

console.log('\n=== D. Sample rows for visit 3910 (Bagel Cove May 4) ===');
console.log(await pg(`
  SELECT * FROM public.visit_assignments WHERE visit_id = 3910;
`));

console.log('\n=== E. Is visit_assignments audited? ===');
console.log(await pg(`
  SELECT tgname, pg_get_triggerdef(oid) AS def
  FROM pg_trigger
  WHERE tgrelid = 'public.visit_assignments'::regclass AND NOT tgisinternal;
`));
