// 31_calendar_column_inventory.mjs
// Column inventory for tables the Calendar view will read from.

import 'dotenv/config';

const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}

const tables = ['visits', 'clients', 'properties', 'service_configs', 'gdos', 'vehicles', 'employees', 'visit_assignments', 'line_items'];

for (const t of tables) {
  console.log(`\n=== public.${t} ===`);
  const cols = await pg(`
    SELECT column_name, data_type, is_nullable
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='${t}'
    ORDER BY ordinal_position;
  `);
  for (const c of cols) console.log(`  ${c.column_name.padEnd(32)} ${c.data_type.padEnd(28)} ${c.is_nullable === 'YES' ? 'null' : 'NOT NULL'}`);
}

console.log('\n=== ops.v_service_due (existing — for sidebar shape) ===');
const opsCols = await pg(`
  SELECT column_name, data_type FROM information_schema.columns
  WHERE table_schema='ops' AND table_name='v_service_due'
  ORDER BY ordinal_position;
`);
for (const c of opsCols) console.log(`  ${c.column_name.padEnd(32)} ${c.data_type}`);

console.log('\n=== sample visits row ===');
console.log(await pg(`SELECT id, client_id, vehicle_id, visit_date, visit_status, start_at, completed_at, service_type FROM public.visits WHERE visit_status='scheduled' ORDER BY visit_date LIMIT 3;`));

console.log('\n=== sample service_configs ===');
console.log(await pg(`SELECT id, client_id, property_id, service_type, frequency_days, gt_size_gallons, manholes FROM public.service_configs LIMIT 3;`));

console.log('\n=== sample gdos ===');
console.log(await pg(`SELECT id, client_id, property_id, gdo_number, permit_status, permit_expiration, max_frequency_days FROM public.gdos LIMIT 3;`));
