require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error(`PG ${r.status}: ${r.body.slice(0,200)}`); return JSON.parse(r.body); }
(async () => {
  // Find any invoices linked to client 042-MT around 2026-04-15
  console.log('=== Invoices for 042-MT around 2026-04-15 ===');
  const inv = await pg(`
    SELECT i.id, i.invoice_number, i.issued_date::text, i.subtotal, i.total, i.outstanding_amount,
      i.invoice_status, i.title,
      esl.source_id AS jobber_gid
    FROM invoices i
    JOIN clients c ON c.id = i.client_id
    LEFT JOIN entity_source_links esl ON esl.entity_type='invoice' AND esl.entity_id=i.id AND esl.source_system='jobber'
    WHERE c.client_code = '042-MT'
      AND i.issued_date BETWEEN '2026-04-10' AND '2026-04-30'
    ORDER BY i.issued_date;`);
  for (const r of inv) {
    console.log(`  #${r.invoice_number}  issued=${r.issued_date}  total=$${r.total}  status=${r.invoice_status}  title="${r.title}"  jobber_gid=${r.jobber_gid?.slice(0,50)}`);
  }

  // Find the line items on each invoice
  if (inv.length > 0) {
    console.log('\n=== Line items on those invoices ===');
    for (const i of inv) {
      const li = await pg(`SELECT name, quantity, unit_price, total_price FROM line_items WHERE invoice_id = ${i.id} ORDER BY id;`);
      console.log(`  Invoice #${i.invoice_number}:`);
      for (const l of li) console.log(`    "${l.name}"  qty=${l.quantity}  $${l.unit_price}  total=$${l.total_price}`);
    }
  }

  // Also pull the Jobber invoice URL via decoding the GID
  console.log('\n=== Jobber URL pattern ===');
  for (const r of inv) {
    if (r.jobber_gid) {
      // GIDs are base64 of "gid://Jobber/Invoice/<numeric_id>"
      try {
        const decoded = Buffer.from(r.jobber_gid, 'base64').toString('utf8');
        const m = decoded.match(/Invoice\/(\d+)/);
        if (m) {
          console.log(`  Invoice #${r.invoice_number}: https://secure.getjobber.com/invoices/${m[1]}`);
        } else {
          console.log(`  Invoice #${r.invoice_number}: GID decoded as "${decoded}" — couldn't extract numeric ID`);
        }
      } catch (e) {
        console.log(`  Invoice #${r.invoice_number}: decoding failed`);
      }
    }
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
