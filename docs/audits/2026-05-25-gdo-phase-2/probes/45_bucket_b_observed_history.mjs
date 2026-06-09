import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, { method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'}, body:JSON.stringify({query:sql})});
  return JSON.parse(await r.text());
}

const targets = [
  { id: 350, name: 'Brook Eadler', service_type: 'CL' },
  { id: 448, name: 'Carne en Vara', service_type: 'CL' },
  { id: 376, name: 'Tower 41 Association  Building', service_type: 'CL' },
  { id: 233, name: 'Wynd 28', service_type: 'GT' },
  { id: 354, name: 'YASU', service_type: 'CL' },
];

console.log('=== Bucket B clients — observed history + line_item hints ===\n');
for (const t of targets) {
  console.log(`--- ${t.name} (client_id=${t.id}, ${t.service_type}) ---`);
  const visits = await pg(`
    SELECT id, visit_date, visit_status, service_type, title, job_id, invoice_id,
           visit_date - LAG(visit_date) OVER (PARTITION BY service_type ORDER BY visit_date) AS days_since_prev
    FROM public.visits
    WHERE client_id=${t.id}
    ORDER BY visit_date;
  `);
  console.log(`  ${visits.length} visits total:`);
  for (const v of visits) console.log(`    [${v.id}] ${v.visit_date}  ${(v.service_type || '--').padEnd(2)}  ${v.visit_status.padEnd(10)}  gap=${v.days_since_prev}  job=${v.job_id}  inv=${v.invoice_id}  "${(v.title || '').slice(0,50)}"`);

  const lineItems = await pg(`
    SELECT li.id, li.name, li.quantity, li.unit_price, li.total_price, li.invoice_id, li.job_id
    FROM public.line_items li
    WHERE li.invoice_id IN (SELECT invoice_id FROM public.visits WHERE client_id=${t.id} AND invoice_id IS NOT NULL)
       OR li.job_id IN (SELECT job_id FROM public.visits WHERE client_id=${t.id} AND job_id IS NOT NULL);
  `);
  if (lineItems.length) {
    console.log(`  ${lineItems.length} line items on associated invoices/jobs:`);
    for (const li of lineItems) console.log(`    "${li.name}" qty=${li.quantity} unit=$${li.unit_price} total=$${li.total_price}`);
  }
  console.log('');
}
