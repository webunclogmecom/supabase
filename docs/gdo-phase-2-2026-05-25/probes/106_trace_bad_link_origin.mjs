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
// Original INSERT of the bad Claudie link (visit 5124 ←→ manifest 1041)
console.log('=== Original INSERT of CL←GT mismatched link ===');
console.log(await pg(`
  SELECT id, app_source, operation, changed_at, request_context
  FROM audit.logs
  WHERE table_name='manifest_visits'
    AND operation='INSERT'
    AND new_row->>'visit_id'='5124'
    AND new_row->>'manifest_id'='1041'
  ORDER BY changed_at;
`));
console.log('\n=== Any other recent INSERTs of CL-visit DERM links ===');
console.log(await pg(`
  SELECT al.id, al.app_source, al.operation, al.changed_at,
         al.new_row->>'visit_id' AS visit_id,
         al.new_row->>'manifest_id' AS manifest_id,
         v.service_type, v.title
  FROM audit.logs al
  JOIN public.visits v ON v.id = (al.new_row->>'visit_id')::int
  WHERE al.table_name='manifest_visits' AND al.operation='INSERT'
    AND v.service_type IN ('CL', 'LS')
  ORDER BY al.changed_at DESC LIMIT 20;
`));
