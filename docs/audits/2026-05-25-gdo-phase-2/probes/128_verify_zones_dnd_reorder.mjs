// 128_verify_zones_dnd_reorder.mjs
// After dragging AVE from position 2 down to position 5 in the modal, verify:
//   1. New sort_order assignment is contiguous 10/20/30/... in the order
//      SOUTH → NMB → BRO → SF/BH → AVE → DOWN → MIAMI BEACH → SUNNY → PALM → MID/EDG → WEST
//   2. audit.logs captured the per-row UPDATEs with app_source='visit-calendar'
//   3. REVERT via batch CASE statement (X-App-Source=sql)
//   4. Final state back to original 10/20/30/.../110 order
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

console.log('=== 1. New order after drag (should be SOUTH NMB BRO SF/BH AVE DOWN MIAMI BEACH SUNNY PALM MID/EDG WEST) ===');
console.log(await pg(`
  SELECT code, sort_order, updated_at
  FROM public.zones
  WHERE is_active
  ORDER BY sort_order;
`));

console.log('\n=== 2. audit.logs rows from the drag (last 2 min) with app_source ===');
console.log(await pg(`
  SELECT operation, app_source, changed_at,
         (new_row->>'code') AS code,
         (old_row->>'sort_order') AS old_so,
         (new_row->>'sort_order') AS new_so
  FROM audit.logs
  WHERE table_name='zones'
    AND changed_at >= now() - INTERVAL '3 minutes'
  ORDER BY changed_at;
`));

console.log('\n=== 3. REVERT — restore canonical 10/20/30/.../110 via single CASE UPDATE ===');
console.log(await pg(`
  UPDATE public.zones SET sort_order = CASE code
    WHEN 'SOUTH' THEN 10
    WHEN 'AVE' THEN 20
    WHEN 'NMB' THEN 30
    WHEN 'BRO' THEN 40
    WHEN 'SF/BH' THEN 50
    WHEN 'DOWN' THEN 60
    WHEN 'MIAMI BEACH' THEN 70
    WHEN 'SUNNY' THEN 80
    WHEN 'PALM' THEN 90
    WHEN 'MID/EDG' THEN 100
    WHEN 'WEST' THEN 110
    ELSE sort_order END
  WHERE code IN ('SOUTH','AVE','NMB','BRO','SF/BH','DOWN','MIAMI BEACH','SUNNY','PALM','MID/EDG','WEST')
  RETURNING code, sort_order;
`));

console.log('\n=== 4. Final state (should be canonical) ===');
console.log(await pg(`
  SELECT code, sort_order FROM public.zones
  WHERE is_active ORDER BY sort_order;
`));
