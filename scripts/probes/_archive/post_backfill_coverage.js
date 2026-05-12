require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error(`PG ${r.status}: ${r.body.slice(0,300)}`); return JSON.parse(r.body); }
(async () => {
  const r = await pg(`
    SELECT to_char(visit_date,'YYYY-MM') AS month,
      COUNT(*) AS total_completed,
      COUNT(invoice_id) AS with_inv,
      ROUND(100.0 * COUNT(invoice_id) / NULLIF(COUNT(*),0), 1) AS pct
    FROM visits WHERE visit_status='completed' AND visit_date>='2026-01-01'
    GROUP BY 1 ORDER BY 1;`);
  console.log('After backfill — invoice_id coverage by month:');
  console.log('  month   | completed | linked | %');
  console.log('  ' + '-'.repeat(40));
  for (const row of r) console.log(`  ${row.month} | ${String(row.total_completed).padStart(9)} | ${String(row.with_inv).padStart(6)} | ${row.pct}%`);

  // Visit 1713 update?
  const v1713 = await pg(`SELECT id, invoice_id, (SELECT invoice_number FROM invoices WHERE id=visits.invoice_id) AS inv_no FROM visits WHERE id=1713;`);
  console.log('\nVisit 1713 (the original case):');
  console.log(JSON.stringify(v1713, null, 2));
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
