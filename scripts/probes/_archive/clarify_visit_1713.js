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
  console.log('=== All invoices for job 268 (042-MT emergency call) in our DB ===');
  const i = await pg(`
    SELECT i.id, i.invoice_number, i.subject, i.total, i.invoice_status,
      i.sent_at AT TIME ZONE 'America/New_York' AS sent_et,
      esl.source_id AS jobber_gid
    FROM invoices i
    LEFT JOIN entity_source_links esl ON esl.entity_type='invoice' AND esl.entity_id=i.id AND esl.source_system='jobber'
    WHERE i.job_id = 268
    ORDER BY i.invoice_number;`);
  console.log(JSON.stringify(i, null, 2));

  // Visit 1713 → which invoice is it currently linked to?
  console.log('\n=== visit 1713 post-backfill ===');
  const v = await pg(`
    SELECT v.id, v.invoice_id,
      i.invoice_number AS our_invoice_number,
      i.total AS our_invoice_total
    FROM visits v LEFT JOIN invoices i ON i.id = v.invoice_id
    WHERE v.id = 1713;`);
  console.log(JSON.stringify(v, null, 2));

  // Query Jobber for the invoice that the visit is linked to + ITS line items
  await refreshAccessToken();
  console.log('\n=== Line items on the invoice Jobber says is linked to v1713 ===');
  const vInJobber = await gql(`
    query Q($id: EncodedId!) { visit(id: $id) { invoice { id invoiceNumber total lineItems(first: 20) { nodes { name quantity unitPrice totalPrice } } } } }`,
    { id: 'Z2lkOi8vSm9iYmVyL1Zpc2l0LzIxMzEzMjAyNjc=' });
  console.log(JSON.stringify(vInJobber.visit.invoice, null, 2));
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
