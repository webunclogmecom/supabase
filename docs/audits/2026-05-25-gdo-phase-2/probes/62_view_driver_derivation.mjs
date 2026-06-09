// 62_view_driver_derivation.mjs
// Where does ops.v_calendar_visit derive driver_id from?
// Critical to know before recommending a fix for the broken Driver dropdown.

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

console.log('=== A. ops.v_calendar_visit definition ===');
console.log(await pg(`
  SELECT pg_get_viewdef('ops.v_calendar_visit'::regclass, true) AS definition;
`));

console.log('\n=== B. Does vehicles table have a default-driver column? ===');
console.log(await pg(`
  SELECT column_name, data_type
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='vehicles'
  ORDER BY ordinal_position;
`));

console.log('\n=== C. Driver-vehicle association lookup ===');
console.log(await pg(`
  SELECT id, name, primary_driver_employee_id
  FROM public.vehicles
  WHERE primary_driver_employee_id IS NOT NULL
  ORDER BY id;
`));
