require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error(`PG ${r.status}: ${r.body.slice(0,300)}`); return JSON.parse(r.body); }
(async () => {
  // Compare sum(line_items.total_price) for job vs invoices.total for the same job
  const r = await pg(`
    SELECT
      i.id AS invoice_id, i.invoice_number, i.total AS invoice_total,
      i.job_id, c.client_code,
      (SELECT COALESCE(SUM(total_price),0) FROM line_items li WHERE li.job_id = i.job_id) AS sum_job_line_items
    FROM invoices i
    LEFT JOIN clients c ON c.id = i.client_id
    WHERE i.job_id IS NOT NULL
    ORDER BY i.invoice_number;`);
  let matchCount = 0, mismatchCount = 0, mismatchSum = 0;
  const samples = [];
  for (const row of r) {
    const diff = Number(row.invoice_total) - Number(row.sum_job_line_items);
    if (Math.abs(diff) < 0.01) matchCount++;
    else {
      mismatchCount++;
      mismatchSum += Math.abs(diff);
      if (samples.length < 10) samples.push({...row, diff: diff.toFixed(2)});
    }
  }
  console.log(`Total invoices with linked job: ${r.length}`);
  console.log(`Match (invoice.total = sum of job's line_items): ${matchCount}`);
  console.log(`Mismatch (divergence): ${mismatchCount}  (${(mismatchCount*100/Math.max(r.length,1)).toFixed(1)}%)`);
  console.log(`Total |divergence| dollars across mismatches: $${mismatchSum.toFixed(2)}`);
  console.log('\nSample mismatches:');
  for (const s of samples) console.log(`  inv#${s.invoice_number}  ${s.client_code||'-'}  invoice=$${s.invoice_total}  job_line_sum=$${s.sum_job_line_items}  diff=$${s.diff}`);

  // Also count how many invoices have job_id IS NULL (un-linked)
  const orphans = await pg(`SELECT COUNT(*) AS n FROM invoices WHERE job_id IS NULL;`);
  console.log(`\nInvoices with NULL job_id (can't compare): ${orphans[0].n}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
