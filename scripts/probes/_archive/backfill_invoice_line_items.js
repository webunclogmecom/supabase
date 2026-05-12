// ============================================================================
// Backfill invoice-scoped line_items from Jobber.
//
// For every invoice in our DB with a Jobber GID, pull its line items from
// Jobber's invoice.lineItems and INSERT them into our line_items table with
// invoice_id set (and job_id NULL — invoice line items are scope-distinct
// from job line items, even when they describe the same physical service).
//
// Idempotent: before inserting per invoice, delete any existing rows with
// matching invoice_id. (Invoice line items have no stable Jobber ID we sync,
// so the cleanest dedup is "wipe this invoice's existing rows, re-insert
// from Jobber.")
//
// Safe to re-run.
//
// CLI:
//   node scripts/probes/backfill_invoice_line_items.js              # full
//   node scripts/probes/backfill_invoice_line_items.js --dry-run
//   node scripts/probes/backfill_invoice_line_items.js --limit=N
// ============================================================================
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const { gql, refreshAccessToken } = require('../sync/lib/jobber');
const https = require('https');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROD = process.env.SUPABASE_PROJECT_ID;
const DRY_RUN = process.argv.includes('--dry-run');
const limitArg = process.argv.find(a => a.startsWith('--limit='));
const LIMIT = limitArg ? parseInt(limitArg.split('=')[1], 10) : null;

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error(`PG ${r.status}: ${r.body.slice(0,300)}`); return JSON.parse(r.body); }
async function rest(path, opts={}) {
  const u = new URL(SUPABASE_URL + '/rest/v1' + path);
  const r = await http({hostname: u.hostname, path: u.pathname + u.search, method: opts.method||'GET', headers: {apikey: SVC, Authorization: `Bearer ${SVC}`, 'Content-Type':'application/json', ...(opts.headers||{})}}, opts.body);
  if (r.status >= 300) throw new Error(`REST ${path}: ${r.status} ${r.body.slice(0,300)}`);
  return r.body ? JSON.parse(r.body) : null;
}

(async () => {
  console.log(`Mode: ${DRY_RUN ? 'DRY-RUN' : 'EXECUTE'}${LIMIT ? `  Limit: ${LIMIT}` : ''}`);

  console.log('\n[1/2] Loading invoices with Jobber GID...');
  const invs = await pg(`
    SELECT i.id AS invoice_id, i.invoice_number, esl.source_id AS invoice_gid
    FROM invoices i
    JOIN entity_source_links esl ON esl.entity_type='invoice' AND esl.entity_id=i.id AND esl.source_system='jobber'
    ORDER BY i.id ASC
    ${LIMIT ? `LIMIT ${LIMIT}` : ''};`);
  console.log(`  ${invs.length} invoices`);

  await refreshAccessToken();
  console.log('\n[2/2] Pulling line items from Jobber per invoice + inserting...');

  let totalLineItems = 0, processed = 0, emptyInvoices = 0, errors = 0;
  for (const inv of invs) {
    processed++;
    if (processed % 100 === 0) console.log(`  ${processed}/${invs.length}  line_items_inserted=${totalLineItems}  errors=${errors}`);
    try {
      const data = await gql(`
        query Q($id: EncodedId!) {
          invoice(id: $id) {
            lineItems(first: 50) {
              nodes { name description quantity unitPrice totalPrice taxable }
            }
          }
        }`, { id: inv.invoice_gid });
      const nodes = data.invoice?.lineItems?.nodes || [];
      if (nodes.length === 0) { emptyInvoices++; continue; }

      if (DRY_RUN) { totalLineItems += nodes.length; continue; }

      // Idempotent: delete existing invoice-scoped rows for this invoice
      await rest(`/line_items?invoice_id=eq.${inv.invoice_id}`, { method: 'DELETE', headers: { Prefer: 'return=minimal' } });

      // Insert new rows
      const rows = nodes.map(n => ({
        invoice_id: inv.invoice_id,
        name: n.name || null,
        description: n.description || null,
        quantity: n.quantity != null ? String(n.quantity) : null,
        unit_price: n.unitPrice != null ? String(n.unitPrice) : null,
        total_price: n.totalPrice != null ? String(n.totalPrice) : null,
        taxable: n.taxable ?? null,
      }));
      await rest(`/line_items`, { method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify(rows) });
      totalLineItems += rows.length;
    } catch (e) {
      errors++;
      if (errors <= 5) console.log(`  ✗ inv${inv.invoice_id}: ${e.message.slice(0,150)}`);
    }
  }

  console.log('\n=== SUMMARY ===');
  console.log(`  Invoices processed: ${processed}`);
  console.log(`  ✓ Line items ${DRY_RUN ? 'would-be inserted' : 'inserted'}: ${totalLineItems}`);
  console.log(`  ⚠ Invoices with no line items: ${emptyInvoices}`);
  console.log(`  ✗ Errors: ${errors}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
