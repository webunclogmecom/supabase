#!/usr/bin/env node
/**
 * create_invoice_reconciliation.js
 * Creates ops.invoice_reconciliation materialized view for
 * Jobber <-> QuickBooks invoice reconciliation.
 *
 * Joins jobber_invoices (invoice_number) with quickbooks_invoices (doc_number)
 * and classifies each pair as MATCH, JOBBER_ONLY, QB_ONLY, TAX_DIFF, or MISMATCH.
 *
 * quickbooks_invoices is currently empty but will be populated soon.
 * The view is created now so it's ready.
 *
 * Usage: node scripts/create_invoice_reconciliation.js
 */

require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });
const https = require('https');

const SUPABASE_PAT = process.env.SUPABASE_PAT;
const PROJECT_ID   = 'infbofuilnqqviyjlwul';

if (!SUPABASE_PAT) {
  console.error('Missing SUPABASE_PAT in .env');
  process.exit(1);
}

function httpsRequest(options, body = null) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, res => {
      let data = '';
      res.on('data', d => data += d);
      res.on('end', () => {
        try { resolve({ status: res.statusCode, body: JSON.parse(data) }); }
        catch (e) { reject(new Error(`JSON parse (${res.statusCode}): ${data.slice(0, 500)}`)); }
      });
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function runSQL(query) {
  const bodyStr = JSON.stringify({ query });
  const { status, body } = await httpsRequest({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROJECT_ID}/database/query`,
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${SUPABASE_PAT}`,
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(bodyStr),
    },
  }, bodyStr);
  if (body && body.message) throw new Error(`SQL error: ${body.message}`);
  return body;
}

async function main() {
  console.log('=== Creating ops.invoice_reconciliation Materialized View ===');
  console.log(`Started: ${new Date().toISOString()}\n`);

  // Ensure ops schema exists
  await runSQL('CREATE SCHEMA IF NOT EXISTS ops');

  // Drop existing view if present (so we can recreate with updated definition)
  console.log('[1/3] Dropping existing materialized view if present...');
  await runSQL('DROP MATERIALIZED VIEW IF EXISTS ops.invoice_reconciliation');

  // Create the materialized view
  // Column mapping based on actual schema:
  //   jobber_invoices: invoice_number, subject, total, invoice_status, client_id, created_at
  //   quickbooks_invoices: doc_number, total_amt, qb_id, status, txn_date, customer_name
  //   jobber_clients: id, name
  console.log('[2/3] Creating materialized view...');
  await runSQL(`
    CREATE MATERIALIZED VIEW ops.invoice_reconciliation AS
    SELECT
      COALESCE(ji.invoice_number, qi.doc_number) AS invoice_number,
      ji.subject AS jobber_description,
      ji.total AS jobber_total,
      qi.total_amt AS qb_total,
      COALESCE(qi.total_amt, 0) - COALESCE(ji.total, 0) AS difference,
      CASE
        WHEN qi.qb_id IS NULL THEN 'JOBBER_ONLY'
        WHEN ji.id IS NULL THEN 'QB_ONLY'
        WHEN ABS(COALESCE(qi.total_amt, 0) - COALESCE(ji.total, 0)) < 0.01 THEN 'MATCH'
        WHEN ABS(COALESCE(qi.total_amt, 0) - COALESCE(ji.total, 0) - COALESCE(ji.total, 0) * 0.07) < 1.00 THEN 'TAX_DIFF'
        ELSE 'MISMATCH'
      END AS match_status,
      ji.invoice_status AS jobber_status,
      qi.status AS qb_status,
      ji.created_at AS jobber_date,
      qi.txn_date AS qb_date,
      jc.name AS client_name,
      qi.customer_name AS qb_customer_name,
      ji.outstanding AS jobber_outstanding,
      qi.balance AS qb_balance
    FROM jobber_invoices ji
    FULL OUTER JOIN quickbooks_invoices qi ON qi.doc_number = ji.invoice_number
    LEFT JOIN jobber_clients jc ON jc.id = ji.client_id
    ORDER BY ABS(COALESCE(qi.total_amt, 0) - COALESCE(ji.total, 0)) DESC
  `);
  console.log('  Materialized view created.\n');

  // Create index on invoice_number for fast lookups
  console.log('[3/3] Creating indexes...');
  await runSQL('CREATE INDEX IF NOT EXISTS idx_invoice_recon_number ON ops.invoice_reconciliation(invoice_number)');
  await runSQL('CREATE INDEX IF NOT EXISTS idx_invoice_recon_status ON ops.invoice_reconciliation(match_status)');
  console.log('  Indexes created.\n');

  // Verify
  const countResult = await runSQL('SELECT match_status, COUNT(*) as cnt FROM ops.invoice_reconciliation GROUP BY match_status ORDER BY cnt DESC');
  console.log('=== Verification (match_status counts) ===');
  if (countResult.length === 0) {
    console.log('  (empty - quickbooks_invoices has no data yet, all rows are JOBBER_ONLY)');
    const totalCount = await runSQL('SELECT COUNT(*) as cnt FROM ops.invoice_reconciliation');
    console.log(`  Total rows: ${totalCount[0]?.cnt || 0}`);
  } else {
    for (const row of countResult) {
      console.log(`  ${row.match_status}: ${row.cnt}`);
    }
  }

  // Show sample data
  const samples = await runSQL('SELECT invoice_number, jobber_total, qb_total, match_status, client_name FROM ops.invoice_reconciliation LIMIT 5');
  console.log('\n=== Sample Rows ===');
  for (const s of samples) {
    console.log(`  #${s.invoice_number} | Jobber: $${s.jobber_total || '-'} | QB: $${s.qb_total || '-'} | ${s.match_status} | ${s.client_name || '-'}`);
  }

  console.log('\nDone. View can be refreshed anytime with:');
  console.log('  REFRESH MATERIALIZED VIEW ops.invoice_reconciliation;');
}

main().catch(err => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
