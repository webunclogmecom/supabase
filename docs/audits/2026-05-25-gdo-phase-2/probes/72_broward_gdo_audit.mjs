// 72_broward_gdo_audit.mjs
// Broward county has no GDO program (Miami-Dade DERM only).
// Find any GDO records linked to clients/properties in Broward.
// Show what we find — don't mutate yet.
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

console.log('=== A. gdos table columns ===');
console.log(await pg(`
  SELECT column_name, data_type
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='gdos'
  ORDER BY ordinal_position;
`));

console.log('\n=== B. All distinct county values in properties ===');
console.log(await pg(`
  SELECT county, COUNT(*)::int AS n
  FROM public.properties
  GROUP BY county
  ORDER BY n DESC;
`));

console.log('\n=== C. GDOs linked to properties in Broward ===');
console.log(await pg(`
  SELECT g.id AS gdo_id, g.gdo_number, g.status AS gdo_status,
         g.client_id, c.name AS client_name, c.client_code,
         g.property_id, p.address, p.city, p.county
  FROM public.gdos g
  LEFT JOIN public.clients c ON c.id = g.client_id
  LEFT JOIN public.properties p ON p.id = g.property_id
  WHERE p.county ILIKE 'broward'
  ORDER BY c.name;
`));

console.log('\n=== D. GDOs linked to clients whose PRIMARY property is in Broward (covers null property_id case) ===');
console.log(await pg(`
  SELECT g.id AS gdo_id, g.gdo_number, g.status AS gdo_status,
         g.client_id, c.name AS client_name, c.client_code,
         pp.address AS primary_addr, pp.city AS primary_city, pp.county AS primary_county
  FROM public.gdos g
  JOIN public.clients c ON c.id = g.client_id
  JOIN public.properties pp ON pp.client_id = c.id AND pp.is_primary = true
  WHERE g.property_id IS NULL
    AND pp.county ILIKE 'broward'
  ORDER BY c.name;
`));

console.log('\n=== E. Clients with "BW" in their client_code (Broward indicator?) ===');
console.log(await pg(`
  SELECT id, client_code, name, status
  FROM public.clients
  WHERE client_code ILIKE '%BW%' OR client_code ILIKE '%-BW%'
  ORDER BY client_code;
`));

console.log('\n=== F. service_configs with permit_number where client primary property is Broward ===');
console.log(await pg(`
  SELECT sc.client_id, c.name AS client_name, c.client_code, sc.service_type,
         sc.permit_number, sc.permit_document_path,
         pp.city AS primary_city, pp.county AS primary_county
  FROM public.service_configs sc
  JOIN public.clients c ON c.id = sc.client_id
  LEFT JOIN public.properties pp ON pp.client_id = c.id AND pp.is_primary = true
  WHERE sc.permit_number IS NOT NULL
    AND pp.county ILIKE 'broward'
  ORDER BY c.name;
`));
