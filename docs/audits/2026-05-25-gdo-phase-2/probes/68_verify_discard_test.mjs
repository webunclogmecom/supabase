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

console.log('=== Current driver for visit 3910 (should still be Steven) ===');
console.log(await pg(`
  SELECT va.visit_id, va.employee_id, e.full_name
  FROM public.visit_assignments va
  JOIN public.employees e ON e.id = va.employee_id
  WHERE va.visit_id = 3910;
`));

console.log('\n=== Audit log for last 5 min on visit 3910 (should show NO new entries from this test) ===');
console.log(await pg(`
  SELECT id, app_source, operation, changed_at,
         old_row->>'employee_id' AS old_emp, new_row->>'employee_id' AS new_emp
  FROM audit.logs
  WHERE table_name='visit_assignments'
    AND COALESCE(new_row->>'visit_id', old_row->>'visit_id') = '3910'
    AND changed_at > NOW() - INTERVAL '5 min'
  ORDER BY changed_at DESC;
`));
