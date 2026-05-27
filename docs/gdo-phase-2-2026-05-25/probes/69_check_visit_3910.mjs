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

console.log('=== Current visit 3910 driver ===');
console.log(await pg(`
  SELECT va.visit_id, va.employee_id, e.full_name
  FROM public.visit_assignments va JOIN public.employees e ON e.id=va.employee_id
  WHERE va.visit_id=3910;
`));
