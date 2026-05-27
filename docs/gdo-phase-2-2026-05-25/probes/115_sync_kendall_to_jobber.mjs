// Sync visit 4836 to the live Jobber state.
import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${(await r.text()).slice(0, 600)}`);
  return JSON.parse(await r.text());
}
console.log('=== Before ===');
console.log(await pg(`
  SELECT id, visit_date, start_at, end_at, completed_at, visit_status
  FROM public.visits WHERE id=4836;
`));
console.log('\n=== Sync to Jobber state ===');
console.log(await pg(`
  UPDATE public.visits
  SET visit_date='2026-05-19',
      start_at='2026-05-19T08:00:00+00'::timestamptz,
      end_at='2026-05-19T09:00:00+00'::timestamptz,
      completed_at=NULL,
      visit_status='scheduled'
  WHERE id=4836
  RETURNING id, visit_date, start_at, end_at, completed_at, visit_status;
`));
