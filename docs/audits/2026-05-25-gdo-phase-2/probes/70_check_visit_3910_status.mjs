import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  return JSON.parse(await r.text());
}
console.log(await pg(`SELECT id, visit_status, completed_at FROM public.visits WHERE id=3910;`));
console.log('\n--- audit ---');
console.log(await pg(`
  SELECT id, app_source, operation, changed_at,
         old_row->>'visit_status' AS old_status,
         new_row->>'visit_status' AS new_status,
         old_row->>'completed_at' AS old_cmp,
         new_row->>'completed_at' AS new_cmp
  FROM audit.logs
  WHERE table_name='visits' AND (new_row->>'id')::int = 3910 AND changed_at > NOW() - INTERVAL '5 min'
  ORDER BY changed_at DESC LIMIT 3;
`));
