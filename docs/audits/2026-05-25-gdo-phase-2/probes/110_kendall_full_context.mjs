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
console.log('=== Visits attached to Job #66 ===');
console.log(await pg(`
  SELECT v.id, v.visit_date, v.visit_status, v.start_at, v.completed_at, v.title, c.client_code
  FROM public.visits v
  JOIN public.clients c ON c.id=v.client_id
  WHERE v.job_id=66
  ORDER BY v.visit_date;
`));

console.log('\n=== All Kendall completed visits in DB (077-TCE) ===');
console.log(await pg(`
  SELECT v.id, v.visit_date, v.start_at, v.completed_at, v.title, v.job_id
  FROM public.visits v
  JOIN public.clients c ON c.id=v.client_id
  WHERE c.client_code='077-TCE' AND v.visit_status='completed'
  ORDER BY v.visit_date DESC LIMIT 10;
`));

console.log('\n=== DERM Tracker would surface — any completed GT visit linked OR derm_required=true OR missing manifest ===');
console.log(await pg(`
  SELECT v.id, v.visit_date, v.start_at, v.completed_at, v.title, v.derm_required,
         (SELECT manifest_id FROM public.manifest_visits mv WHERE mv.visit_id=v.id LIMIT 1) AS manifest_id
  FROM public.visits v
  JOIN public.clients c ON c.id=v.client_id
  WHERE c.client_code='077-TCE'
    AND v.visit_status='completed'
    AND v.service_type='GT'
    AND v.visit_date >= '2026-05-01'
  ORDER BY v.visit_date;
`));
