// 58_calendar_address_audit.mjs
// Identify May 2026 visits with missing address → Google Maps button would be broken.
// Plus inspect ops.v_calendar_visit columns to see how UI sources address.

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

console.log('=== A. May 2026 visits with NO property address (Maps would 404) ===');
console.log(await pg(`
  SELECT v.id, v.visit_date, v.visit_status, c.name AS client,
         v.property_id, p.address, p.city
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  LEFT JOIN public.properties p ON p.id = v.property_id
  WHERE v.visit_date >= '2026-05-01' AND v.visit_date < '2026-06-01'
    AND (p.address IS NULL OR p.address = '' OR p.city IS NULL OR p.city = '')
  ORDER BY v.visit_date;
`));

console.log('\n=== B. ops.v_calendar_visit columns (to see how address is exposed) ===');
console.log(await pg(`
  SELECT column_name, data_type
  FROM information_schema.columns
  WHERE table_schema = 'ops' AND table_name = 'v_calendar_visit'
  ORDER BY ordinal_position;
`));
