require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error(`PG ${r.status}: ${r.body.slice(0,300)}`); return JSON.parse(r.body); }
(async () => {
  // For each VISIT (anchored on visit_date), find the linked invoice and compare
  console.log('=== Visits 2026+ → invoice line-item drift (anchored on visit_date) ===\n');

  const r = await pg(`
    WITH visit_job_inv AS (
      SELECT
        v.id AS visit_id,
        v.visit_date,
        v.title AS visit_title,
        v.service_type AS canonical_service,
        v.job_id,
        c.client_code,
        c.name AS client_name,
        i.id AS invoice_id,
        i.invoice_number,
        i.total::numeric AS invoice_total,
        (SELECT COALESCE(SUM(total_price),0)::numeric FROM line_items li WHERE li.job_id = v.job_id) AS sum_job_line_items
      FROM visits v
      LEFT JOIN clients c ON c.id = v.client_id
      LEFT JOIN invoices i ON i.job_id = v.job_id
      WHERE v.visit_date >= '2026-01-01'
        AND v.visit_status = 'completed'
        AND v.job_id IS NOT NULL
    )
    SELECT
      visit_date,
      visit_id, visit_title, canonical_service, client_code, client_name,
      invoice_number, invoice_total, sum_job_line_items,
      (invoice_total - sum_job_line_items) AS diff,
      CASE WHEN ABS(invoice_total - sum_job_line_items) < 0.01 THEN 'MATCH' ELSE 'MISMATCH' END AS state
    FROM visit_job_inv
    WHERE invoice_id IS NOT NULL
    ORDER BY visit_date DESC;`);

  let matchCount = 0, mismatchCount = 0, mismatchSum = 0;
  const byMonth = {};
  for (const row of r) {
    const monthKey = String(row.visit_date).slice(0,7);
    if (!byMonth[monthKey]) byMonth[monthKey] = {match:0, mismatch:0, sum:0};
    if (row.state === 'MATCH') { matchCount++; byMonth[monthKey].match++; }
    else { mismatchCount++; byMonth[monthKey].mismatch++; mismatchSum += Math.abs(Number(row.diff)); byMonth[monthKey].sum += Math.abs(Number(row.diff)); }
  }
  console.log(`Total 2026 completed visits with linked invoice: ${r.length}`);
  console.log(`MATCH:    ${matchCount} (${(matchCount*100/Math.max(r.length,1)).toFixed(1)}%)`);
  console.log(`MISMATCH: ${mismatchCount} (${(mismatchCount*100/Math.max(r.length,1)).toFixed(1)}%)`);
  console.log(`Cumulative |divergence| dollars: $${mismatchSum.toFixed(2)}\n`);

  console.log('By month:');
  for (const [m, v] of Object.entries(byMonth).sort()) {
    console.log(`  ${m}: match=${v.match} mismatch=${v.mismatch}  drift=$${v.sum.toFixed(2)}`);
  }

  console.log('\nSample 10 most-recent mismatches:');
  const mismatches = r.filter(x => x.state === 'MISMATCH');
  for (const s of mismatches.slice(0, 10)) {
    console.log(`  ${s.visit_date}  v${s.visit_id}  ${s.client_code||'-'}  ${(s.client_name||'').slice(0,30)}`);
    console.log(`    invoice #${s.invoice_number}  total=$${s.invoice_total}  job_line_sum=$${s.sum_job_line_items}  diff=$${Number(s.diff).toFixed(2)}  svc=${s.canonical_service||'?'}`);
  }

  // Also: how many 2026 visits have NO linked invoice at all?
  const noInvoice = await pg(`
    SELECT COUNT(*) AS n
    FROM visits v
    LEFT JOIN invoices i ON i.job_id = v.job_id
    WHERE v.visit_date >= '2026-01-01'
      AND v.visit_status = 'completed'
      AND v.job_id IS NOT NULL
      AND i.id IS NULL;`);
  console.log(`\n2026 completed visits with linked JOB but NO invoice: ${noInvoice[0].n}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
