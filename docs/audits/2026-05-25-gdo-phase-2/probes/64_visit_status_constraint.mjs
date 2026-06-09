// 64_visit_status_constraint.mjs
// What visit_status values are allowed? Needed for delete-button semantics.
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

console.log('=== visit_status CHECK constraint ===');
console.log(await pg(`
  SELECT con.conname, pg_get_constraintdef(con.oid) AS def
  FROM pg_constraint con
  JOIN pg_class cls ON cls.oid = con.conrelid
  WHERE cls.relname = 'visits' AND con.contype = 'c'
    AND pg_get_constraintdef(con.oid) ILIKE '%visit_status%';
`));

console.log('\n=== Distinct visit_status values in use ===');
console.log(await pg(`
  SELECT visit_status, COUNT(*)::int AS n
  FROM public.visits
  GROUP BY visit_status
  ORDER BY n DESC;
`));
