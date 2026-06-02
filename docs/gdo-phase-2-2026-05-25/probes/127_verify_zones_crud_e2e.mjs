// 127_verify_zones_crud_e2e.mjs
// 1. Confirm the Calendar's edit to AVE.sort_order persisted (should be 21 now).
// 2. Confirm audit.logs captured the UPDATE with app_source='visit-calendar'.
// 3. REVERT sort_order back to 20 (per the always-revert-test-mutations rule).
// 4. Re-check final state.
import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json','X-App-Source':'sql'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0,1200)}`);
  return JSON.parse(body);
}

console.log('=== 1. AVE current state (should be 21 if persisted) ===');
console.log(await pg(`
  SELECT code, label, sort_order, updated_at
  FROM public.zones WHERE code='AVE';
`));

console.log('\n=== 2. audit.logs row for the UPDATE — should show app_source="visit-calendar" ===');
console.log(await pg(`
  SELECT operation, table_name, app_source, changed_at,
         (new_row->>'sort_order') AS new_sort_order,
         (old_row->>'sort_order') AS old_sort_order,
         request_context
  FROM audit.logs
  WHERE table_name='zones'
    AND new_row->>'code'='AVE'
    AND changed_at >= now() - INTERVAL '5 minutes'
  ORDER BY changed_at DESC
  LIMIT 5;
`));

console.log('\n=== 3. REVERT — set sort_order back to 20 (X-App-Source=sql) ===');
console.log(await pg(`
  UPDATE public.zones SET sort_order=20 WHERE code='AVE' AND sort_order=21
  RETURNING code, sort_order, updated_at;
`));

console.log('\n=== 4. Final state — should be back to 20 ===');
console.log(await pg(`
  SELECT code, sort_order, updated_at FROM public.zones WHERE code='AVE';
`));

console.log('\n=== 5. Audit trail for AVE last 5 min (both changes should be there) ===');
console.log(await pg(`
  SELECT operation, app_source, changed_at,
         (new_row->>'sort_order') AS new_sort_order,
         (old_row->>'sort_order') AS old_sort_order
  FROM audit.logs
  WHERE table_name='zones'
    AND new_row->>'code'='AVE'
    AND changed_at >= now() - INTERVAL '10 minutes'
  ORDER BY changed_at;
`));
