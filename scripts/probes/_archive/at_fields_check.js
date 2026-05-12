require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
function http(opts) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); req.end();
});}
(async () => {
  const r = await http({hostname:'api.airtable.com',path:`/v0/${AT_BASE}/Clients?pageSize=2`,method:'GET',headers:{Authorization:`Bearer ${AT_KEY}`}});
  const j = JSON.parse(r.body);
  if (j.records?.[0]) {
    console.log('Field names on first Airtable Clients record:');
    for (const f of Object.keys(j.records[0].fields).sort()) console.log(`  ${f}`);
  } else console.log('no records or err:', r.body.slice(0,400));
})().catch(e => { console.error('FATAL:', e.message); });
