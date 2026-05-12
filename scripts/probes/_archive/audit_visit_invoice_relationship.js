require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const { gql, refreshAccessToken } = require('../sync/lib/jobber');
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error(`PG ${r.status}: ${r.body.slice(0,300)}`); return JSON.parse(r.body); }
(async () => {
  console.log('=== PART 1: Does our visits table have an invoice_id column? ===');
  const visitsCols = await pg(`SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='visits' ORDER BY ordinal_position;`);
  console.log('visits columns:', visitsCols.map(c => c.column_name).join(', '));
  const hasInvId = visitsCols.some(c => c.column_name === 'invoice_id');
  console.log(`Has invoice_id column? ${hasInvId ? 'YES' : 'NO — gap'}`);

  console.log('\n=== PART 2: Any bridge table (visit_invoices, etc.)? ===');
  const bridges = await pg(`SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND (table_name ILIKE '%visit%invoice%' OR table_name ILIKE '%invoice%visit%');`);
  console.log('Bridge tables:', bridges.length ? bridges.map(t => t.table_name) : '(none)');

  console.log('\n=== PART 3: How visits/invoices relate today (via job_id) — distribution ===');
  const dist = await pg(`
    WITH a AS (
      SELECT v.id AS visit_id, v.job_id,
        (SELECT COUNT(*) FROM invoices WHERE job_id = v.job_id) AS inv_count
      FROM visits v
      WHERE v.visit_date >= '2026-01-01' AND v.visit_status='completed' AND v.job_id IS NOT NULL
    )
    SELECT inv_count, COUNT(*) AS n_visits FROM a GROUP BY inv_count ORDER BY inv_count;`);
  console.log('Invoices per 2026 visit (via job_id):');
  for (const r of dist) console.log(`  ${r.inv_count} invoice(s): ${r.n_visits} visits`);

  console.log('\n=== PART 4: Jobs that have MULTIPLE invoices (where visit→job→invoice is ambiguous) ===');
  const multiInv = await pg(`
    SELECT j_count.job_id, j_count.n_invoices, c.client_code, c.name AS client_name,
      ARRAY_AGG(DISTINCT i.invoice_number ORDER BY i.invoice_number) AS invoice_numbers
    FROM (
      SELECT job_id, COUNT(*) AS n_invoices FROM invoices WHERE job_id IS NOT NULL GROUP BY job_id HAVING COUNT(*) > 1
    ) j_count
    JOIN invoices i ON i.job_id = j_count.job_id
    LEFT JOIN clients c ON c.id = i.client_id
    GROUP BY j_count.job_id, j_count.n_invoices, c.client_code, c.name
    ORDER BY j_count.n_invoices DESC LIMIT 10;`);
  console.log(`Jobs with >1 invoice: ${multiInv.length} (showing top 10)`);
  for (const r of multiInv) console.log(`  job=${r.job_id} (${r.client_code||'-'}): ${r.n_invoices} invoices = [${r.invoice_numbers.join(', ')}]`);

  console.log('\n=== PART 5: What Jobber actually exposes — does a Jobber Visit have an invoice ref? ===');
  await refreshAccessToken();
  // Use the visit 1713's GID to inspect
  const vGid = await pg(`SELECT source_id FROM entity_source_links WHERE entity_type='visit' AND entity_id=1713 AND source_system='jobber' LIMIT 1;`);
  if (!vGid[0]) { console.log('  No Jobber GID for visit 1713'); return; }

  // Introspect Jobber's Visit type
  console.log('\nIntrospecting Jobber Visit type fields...');
  const introspect = await gql(`
    {
      __type(name: "Visit") {
        name
        fields { name type { name kind ofType { name kind } } }
      }
    }`);
  const fields = introspect.__type?.fields || [];
  const invoiceFields = fields.filter(f => /invoice|bill/i.test(f.name));
  console.log(`Visit fields mentioning "invoice" or "bill":`);
  for (const f of invoiceFields) console.log(`  - ${f.name}  (${f.type.name || f.type.ofType?.name || f.type.kind})`);
  if (!invoiceFields.length) console.log('  (none — Visit has no direct invoice field in Jobber GraphQL)');

  // Now try fetching the visit's invoice in case the field name is different
  console.log('\nFetching visit 1713 from Jobber with all relations...');
  try {
    const v = await gql(`
      query GetVisit($id: EncodedId!) {
        visit(id: $id) {
          id
          title
          job { id title }
        }
      }`, { id: vGid[0].source_id });
    console.log('Visit object:');
    console.log(JSON.stringify(v, null, 2));
  } catch (e) {
    console.log('  Visit query error:', e.message.slice(0, 200));
  }

  // Also check Job's invoices field
  console.log('\nIntrospecting Jobber Job type for invoice-related fields...');
  const jobIntrospect = await gql(`
    {
      __type(name: "Job") {
        fields { name type { name kind ofType { name kind } } }
      }
    }`);
  const jobInvoiceFields = (jobIntrospect.__type?.fields || []).filter(f => /invoice/i.test(f.name));
  for (const f of jobInvoiceFields) console.log(`  - Job.${f.name}  (${f.type.name || f.type.ofType?.name || f.type.kind})`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
