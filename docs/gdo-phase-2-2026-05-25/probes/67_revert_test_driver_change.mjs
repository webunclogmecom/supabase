// 67_revert_test_driver_change.mjs
// Revert the test-induced driver change on visit 3910 (Bagel Cove May 4)
// back to Steven (employee_id 24). My earlier test changed it to Aaron (30).
// Per Fred's rule: when testing, anything I change I must revert.

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

console.log('=== Before ===');
console.log(await pg(`
  SELECT va.visit_id, va.employee_id, e.full_name
  FROM public.visit_assignments va
  JOIN public.employees e ON e.id = va.employee_id
  WHERE va.visit_id = 3910;
`));

console.log('\n=== Revert: DELETE Aaron + INSERT Steven ===');
console.log(await pg(`
  DELETE FROM public.visit_assignments WHERE visit_id = 3910;
  INSERT INTO public.visit_assignments (visit_id, employee_id) VALUES (3910, 24);
`));

console.log('\n=== After ===');
console.log(await pg(`
  SELECT va.visit_id, va.employee_id, e.full_name
  FROM public.visit_assignments va
  JOIN public.employees e ON e.id = va.employee_id
  WHERE va.visit_id = 3910;
`));

console.log('\n=== Audit trail for visit 3910 today ===');
console.log(await pg(`
  SELECT id, app_source, operation, changed_at,
         old_row->>'employee_id' AS old_emp,
         new_row->>'employee_id' AS new_emp
  FROM audit.logs
  WHERE table_name='visit_assignments'
    AND COALESCE(new_row->>'visit_id', old_row->>'visit_id') = '3910'
    AND changed_at::date = CURRENT_DATE
  ORDER BY changed_at ASC;
`));
