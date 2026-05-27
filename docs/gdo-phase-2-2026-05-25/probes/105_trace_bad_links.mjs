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
// Look at audit log for the swapped link (visit 5099, manifest 1041) to confirm
// fix landed, and trace earlier history for the WRONG link.
console.log('=== Recent manifest_visits audit for Claudie ===');
console.log(await pg(`
  SELECT id, app_source, operation, changed_at,
         old_row->>'visit_id' AS old_v, new_row->>'visit_id' AS new_v,
         old_row->>'manifest_id' AS old_m, new_row->>'manifest_id' AS new_m
  FROM audit.logs
  WHERE table_name='manifest_visits'
    AND ( (new_row->>'manifest_id')::int IN (1041,988,991,1061)
       OR (old_row->>'manifest_id')::int IN (1041,988,991,1061) )
  ORDER BY changed_at DESC LIMIT 20;
`));
