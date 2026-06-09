// 61_visit_driver_schema.mjs
// Confirm visits table driver wiring + check current state of a sample visit.

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

console.log('=== A. visits table columns related to driver ===');
console.log(await pg(`
  SELECT column_name, data_type, is_nullable
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='visits'
    AND column_name ILIKE '%driver%' OR column_name ILIKE '%employee%'
  ORDER BY ordinal_position;
`));

console.log('\n=== B. visits table ALL columns (look for driver_id) ===');
console.log(await pg(`
  SELECT column_name, data_type
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='visits'
  ORDER BY ordinal_position;
`));

console.log('\n=== C. RLS policies on public.visits ===');
console.log(await pg(`
  SELECT policyname, cmd, qual, with_check
  FROM pg_policies
  WHERE schemaname='public' AND tablename='visits'
  ORDER BY policyname;
`));

console.log('\n=== D. Bagel Cove May 4 raw row ===');
console.log(await pg(`
  SELECT id, client_id, vehicle_id, visit_status, source
  FROM public.visits
  WHERE id = 3910;
`));

console.log('\n=== E. ops.v_calendar_visit driver columns for Bagel Cove May 4 ===');
console.log(await pg(`
  SELECT id, client_name, truck_name, driver_id, driver_name, driver_role
  FROM ops.v_calendar_visit
  WHERE id = 3910;
`));

console.log('\n=== F. Available active employees (drivers) ===');
console.log(await pg(`
  SELECT id, full_name, role, status
  FROM public.employees
  WHERE status = 'ACTIVE'
  ORDER BY full_name
  LIMIT 15;
`));

console.log('\n=== G. Recent audit.logs UPDATEs to visits via visit-calendar ===');
console.log(await pg(`
  SELECT id, app_source, operation, changed_at,
         (new_row->>'id') AS visit_id,
         (new_row->>'vehicle_id') AS new_vehicle,
         (old_row->>'vehicle_id') AS old_vehicle
  FROM audit.logs
  WHERE table_name='visits' AND app_source='visit-calendar' AND operation='UPDATE'
  ORDER BY changed_at DESC
  LIMIT 10;
`));
