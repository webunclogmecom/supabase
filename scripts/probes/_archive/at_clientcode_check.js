require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
function http(opts) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); req.end();
});}
const enc = encodeURIComponent;
(async () => {
  const fields = ['Client Code #3','CLIENT XX','DO NOT DELETE CLIENT CODE','Client Name','ACTIVE/INACTIVE','Service Type'];
  const fp = fields.map(f => `fields%5B%5D=${enc(f)}`).join('&');
  const r = await http({hostname:'api.airtable.com',path:`/v0/${AT_BASE}/Clients?${fp}&pageSize=5`,method:'GET',headers:{Authorization:`Bearer ${AT_KEY}`}});
  const j = JSON.parse(r.body);
  for (const rec of (j.records || [])) {
    console.log(JSON.stringify(rec.fields, null, 2));
    console.log('---');
  }
})().catch(e => { console.error('FATAL:', e.message); });
