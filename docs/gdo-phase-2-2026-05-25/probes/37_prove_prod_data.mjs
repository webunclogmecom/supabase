// 37_prove_prod_data.mjs
// Side-by-side: the Pura Vida May 1 visit in the drawer = exact Prod canonical
// row. AND show the empty service_configs evidence for clients showing "—".

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

console.log(`Project ID in use: ${PROD}  (Prod)\n`);

console.log('=== A) Pura Vida Bakery May 1 visit row (what the drawer shows) ===');
console.log(await pg(`
  SELECT id, visit_date, client_name, service_type, amount, frequency_days,
         equipment_size_gallons, gdo_number, truck_name, driver_name, late_status
  FROM ops.v_calendar_visit
  WHERE id = 1794;
`));

console.log('\n=== B) Same row from RAW Prod tables (the underlying truth) ===');
console.log(await pg(`
  SELECT
    v.id, v.visit_date, c.name AS client_name, v.service_type,
    sc.price_per_visit AS sc_price, sc.frequency_days AS sc_freq, sc.equipment_size_gallons AS sc_size,
    g.gdo_number, veh.name AS truck, emp.full_name AS driver
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  LEFT JOIN public.service_configs sc ON sc.client_id=v.client_id AND sc.service_type=v.service_type
  LEFT JOIN public.properties p ON p.id=v.property_id
  LEFT JOIN public.gdos g ON g.client_id=v.client_id AND g.status='ACTIVE'
  LEFT JOIN public.vehicles veh ON veh.id=v.vehicle_id
  LEFT JOIN public.visit_assignments va ON va.visit_id=v.id
  LEFT JOIN public.employees emp ON emp.id=va.employee_id
  WHERE v.id = 1794;
`));

console.log('\n=== C) Why Aromas del Peru shows blank — service_configs is empty in Prod ===');
console.log(await pg(`
  SELECT
    (SELECT name FROM public.clients WHERE id=450) AS client,
    (SELECT count(*) FROM public.service_configs WHERE client_id=450) AS service_configs_in_prod,
    (SELECT array_agg(service_type) FROM public.service_configs WHERE client_id=450) AS service_types;
`));

console.log('\n=== D) Confirm we are NOT on the FP/HR sandbox by accident ===');
console.log('Current SUPABASE_URL:', process.env.SUPABASE_URL);
console.log('FP/HR sandbox URL (different):', process.env.FIELD_PORTAL_SUPABASE_URL);
