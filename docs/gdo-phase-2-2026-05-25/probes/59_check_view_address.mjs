// 59_check_view_address.mjs
// Check what ops.v_calendar_visit returns for visits with NULL property_id.
// If view's `address` column is null → UI Maps button is broken for that visit.

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

console.log('=== A. May 2026 view rows where address is NULL (Maps broken) ===');
console.log(await pg(`
  SELECT id, visit_date, visit_status, client_name, client_code, address, city, latitude, longitude
  FROM ops.v_calendar_visit
  WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01'
    AND (address IS NULL OR address = '')
  ORDER BY visit_date
  LIMIT 30;
`));

console.log('\n=== B. Total May 2026 visits with NULL address in the view ===');
console.log(await pg(`
  SELECT COUNT(*)::int AS broken_maps
  FROM ops.v_calendar_visit
  WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01'
    AND (address IS NULL OR address = '');
`));

console.log("\n=== C. Specific check — Yan's Restaurant May 4 (visit id 1624) ===");
console.log(await pg(`
  SELECT id, client_name, client_code, address, city, county, latitude, longitude
  FROM ops.v_calendar_visit
  WHERE id = 1624;
`));

console.log("\n=== D. Same client (Yan's Restaurant) primary property check ===");
console.log(await pg(`
  SELECT p.id, p.address, p.city, p.is_primary
  FROM public.properties p
  JOIN public.clients c ON c.id = p.client_id
  WHERE c.name = 'Yan''s Restaurant';
`));
