import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, { method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'}, body:JSON.stringify({query:sql})});
  return JSON.parse(await r.text());
}

console.log('=== visits_source_chk definition ===');
console.log(await pg(`
  SELECT conname, pg_get_constraintdef(oid) AS def
  FROM pg_constraint
  WHERE conname='visits_source_chk';
`));

console.log('\n=== Current distinct values of source in public.visits ===');
console.log(await pg(`SELECT source, count(*)::int FROM public.visits GROUP BY source ORDER BY 2 DESC;`));
