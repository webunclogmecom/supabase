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
  console.log('=== PART A: Is visits.invoice_id populated at all? ===');
  const cov = await pg(`
    SELECT
      COUNT(*) AS total,
      COUNT(invoice_id) AS with_inv,
      COUNT(*) FILTER (WHERE visit_status='completed' AND visit_date>='2026-01-01') AS completed_2026,
      COUNT(invoice_id) FILTER (WHERE visit_status='completed' AND visit_date>='2026-01-01') AS completed_2026_with_inv
    FROM visits;`);
  console.log(JSON.stringify(cov, null, 2));

  console.log('\n=== PART B: Visit 1713 (042-MT) — what does our DB say its invoice_id is? ===');
  const v1713 = await pg(`SELECT id, invoice_id, job_id, visit_date::text, title FROM visits WHERE id=1713;`);
  console.log(JSON.stringify(v1713, null, 2));

  console.log('\n=== PART C: What does Jobber say visit 1713\'s invoice is? ===');
  await refreshAccessToken();
  const vData = await gql(`
    query GetVisit($id: EncodedId!) {
      visit(id: $id) {
        id title
        invoice { id invoiceNumber subject total }
        job { id title }
      }
    }`, { id: 'Z2lkOi8vSm9iYmVyL1Zpc2l0LzIxMzEzMjAyNjc=' });
  console.log(JSON.stringify(vData, null, 2));

  console.log('\n=== PART D: How many 2026 completed visits have invoice_id populated in our DB? ===');
  const byMonth = await pg(`
    SELECT
      to_char(visit_date, 'YYYY-MM') AS month,
      COUNT(*) AS total_completed,
      COUNT(invoice_id) AS with_invoice_id,
      ROUND(100.0 * COUNT(invoice_id) / NULLIF(COUNT(*),0), 1) AS pct
    FROM visits
    WHERE visit_status='completed' AND visit_date>='2026-01-01'
    GROUP BY 1 ORDER BY 1;`);
  for (const r of byMonth) console.log(`  ${r.month}: ${r.with_invoice_id}/${r.total_completed} have invoice_id (${r.pct}%)`);

  console.log('\n=== PART E: When invoice_id IS populated, does it actually match what Jobber says? ===');
  const sample = await pg(`
    SELECT v.id AS visit_id, v.invoice_id, v.title,
      esl.source_id AS visit_gid
    FROM visits v
    LEFT JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
    WHERE v.invoice_id IS NOT NULL AND v.visit_date >= '2026-04-01'
    ORDER BY v.visit_date DESC LIMIT 5;`);
  console.log(`  ${sample.length} samples`);
  for (const v of sample) {
    if (!v.visit_gid) { console.log(`  v${v.visit_id}: no GID`); continue; }
    try {
      const j = await gql(`query Get($id: EncodedId!) { visit(id: $id) { invoice { id invoiceNumber } } }`, { id: v.visit_gid });
      const jobberInv = j.visit.invoice;
      // Get our invoice_number from invoice_id
      const ourInv = await pg(`SELECT invoice_number FROM invoices WHERE id=${v.invoice_id};`);
      const match = ourInv[0]?.invoice_number === jobberInv?.invoiceNumber ? '✓' : '✗';
      console.log(`  ${match} v${v.visit_id}: our_invoice_number=${ourInv[0]?.invoice_number}  jobber=${jobberInv?.invoiceNumber || '(null)'}`);
    } catch (e) { console.log(`  v${v.visit_id}: error ${e.message.slice(0,80)}`); }
  }

  console.log('\n=== PART F: How many visits should have an invoice but don\'t in our DB? ===');
  // Sample 5 recent visits with NULL invoice_id, check Jobber
  const noInv = await pg(`
    SELECT v.id AS visit_id, esl.source_id AS visit_gid, v.title, v.visit_date::text
    FROM visits v
    LEFT JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
    WHERE v.invoice_id IS NULL AND v.visit_status='completed' AND v.visit_date >= '2026-04-01'
    ORDER BY v.visit_date DESC LIMIT 10;`);
  console.log(`  Checking ${noInv.length} recent completed visits with NULL invoice_id...`);
  let fixableCount = 0;
  for (const v of noInv) {
    if (!v.visit_gid) continue;
    try {
      const j = await gql(`query Get($id: EncodedId!) { visit(id: $id) { invoice { id invoiceNumber total } } }`, { id: v.visit_gid });
      const inv = j.visit?.invoice;
      if (inv) {
        fixableCount++;
        console.log(`  ★ v${v.visit_id} (${v.visit_date}) HAS invoice in Jobber: #${inv.invoiceNumber} $${inv.total} — our DB has NULL`);
      } else {
        console.log(`    v${v.visit_id} (${v.visit_date}): no invoice in Jobber either (legitimately uninvoiced)`);
      }
    } catch (e) { console.log(`  v${v.visit_id}: error ${e.message.slice(0,80)}`); }
  }
  console.log(`\n  Of 10 sampled NULL-invoice_id visits, ${fixableCount} actually have a Jobber invoice (sync gap)`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
