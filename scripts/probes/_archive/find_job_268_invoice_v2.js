require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error(`PG ${r.status}: ${r.body.slice(0,300)}`); return JSON.parse(r.body); }
(async () => {
  console.log('=== invoices columns ===');
  const cols = await pg(`SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='invoices' ORDER BY ordinal_position;`);
  console.log(cols.map(c => c.column_name).join(', '));

  console.log('\n=== line_items columns (already known but confirming) ===');
  const liCols = await pg(`SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='line_items' ORDER BY ordinal_position;`);
  console.log(liCols.map(c => c.column_name).join(', '));

  console.log('\n=== 042-MT invoices around 2026-04-15 (using whatever date columns exist) ===');
  // Try common variants
  const inv = await pg(`SELECT * FROM invoices i JOIN clients c ON c.id=i.client_id WHERE c.client_code='042-MT' ORDER BY i.created_at DESC LIMIT 10;`);
  for (const r of inv) console.log(JSON.stringify(r, null, 2));
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
