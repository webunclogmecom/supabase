// 124_apply_zones_table.mjs
// Apply docs/migrations/2026-05-27_zones_reference_table.sql to Prod
// + run verification queries from the migration footer.
import 'dotenv/config';
import { readFileSync } from 'node:fs';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 1200)}`);
  return JSON.parse(body);
}

const sql = readFileSync('docs/migrations/2026-05-27_zones_reference_table.sql', 'utf8');

console.log('=== Applying 2026-05-27_zones_reference_table.sql ===');
console.log(await pg(sql));

console.log('\n=== Verify 1: 11 active zones ===');
console.log(await pg(`
  SELECT code, label, color_hex, color_token, sort_order
  FROM public.zones
  WHERE is_active
  ORDER BY sort_order;
`));

console.log('\n=== Verify 2: properties.zone coverage check ===');
console.log(await pg(`
  SELECT p.zone AS property_zone,
         (z.code IS NULL) AS missing_in_zones_table,
         COUNT(*)::int AS n_properties
  FROM public.properties p
  LEFT JOIN public.zones z ON z.code = p.zone
  WHERE p.zone IS NOT NULL
  GROUP BY p.zone, missing_in_zones_table
  ORDER BY n_properties DESC;
`));

console.log('\n=== Verify 3: audit trigger captured the inserts ===');
console.log(await pg(`
  SELECT operation, COUNT(*)::int AS n
  FROM audit.logs
  WHERE table_name='zones'
    AND changed_at >= now() - INTERVAL '5 minutes'
  GROUP BY operation;
`));

console.log('\n=== Verify 4: grants ===');
console.log(await pg(`
  SELECT grantee, privilege_type
  FROM information_schema.role_table_grants
  WHERE table_schema='public' AND table_name='zones'
  ORDER BY grantee, privilege_type;
`));
