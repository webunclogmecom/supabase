// 73_deactivate_broward_gdos.mjs
// Soft-delete the 7 invalid Broward GDOs identified in probe 72.
// Broward county has no GDO program (Miami-Dade DERM only).
// Action: status='INACTIVE' + notes appended. Idempotent.
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

const BROWARD_GDO_IDS = [137, 138, 139, 140, 151, 152, 153];

console.log('=== Before ===');
console.log(await pg(`
  SELECT id, gdo_number, client_id, property_id, status,
         COALESCE(notes, '') AS notes
  FROM public.gdos
  WHERE id = ANY(ARRAY[${BROWARD_GDO_IDS.join(',')}])
  ORDER BY id;
`));

console.log('\n=== Deactivate (idempotent — only flip if ACTIVE) ===');
console.log(await pg(`
  UPDATE public.gdos
  SET status = 'INACTIVE',
      notes = TRIM(BOTH FROM
        COALESCE(notes, '') ||
        E'\\n[2026-05-27] Deactivated: Broward county has no GDO program (Miami-Dade DERM only). Placeholder gdo_number was BW/bw, not a real permit.'
      ),
      updated_at = NOW()
  WHERE id = ANY(ARRAY[${BROWARD_GDO_IDS.join(',')}])
    AND status = 'ACTIVE'
  RETURNING id, gdo_number, status;
`));

console.log('\n=== After ===');
console.log(await pg(`
  SELECT id, gdo_number, client_id, property_id, status
  FROM public.gdos
  WHERE id = ANY(ARRAY[${BROWARD_GDO_IDS.join(',')}])
  ORDER BY id;
`));

console.log('\n=== Final check — any remaining ACTIVE GDOs with Broward properties? ===');
console.log(await pg(`
  SELECT g.id, g.gdo_number, c.name, c.client_code, p.county
  FROM public.gdos g
  JOIN public.clients c ON c.id = g.client_id
  LEFT JOIN public.properties p ON p.id = g.property_id
  WHERE g.status = 'ACTIVE'
    AND p.county ILIKE 'broward';
`));
