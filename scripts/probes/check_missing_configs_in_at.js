// Cross-ref the 7 RECURRING clients with NO service_configs against Airtable.
// What Service Type + frequency does AT claim for them?
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) {
  const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROD+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query:sql}));
  if(r.status>=300) throw new Error('PG '+r.status+': '+r.body.slice(0,300));
  return JSON.parse(r.body);
}
async function listAT(table, fields, filter) {
  const out=[]; let offset; const enc=encodeURIComponent;
  do {
    const fp = (fields||[]).map(f => 'fields%5B%5D='+enc(f)).join('&');
    const ff = filter ? '&filterByFormula='+enc(filter) : '';
    const path = '/v0/'+AT_BASE+'/'+enc(table)+'?'+fp+'&pageSize=100'+ff+(offset?'&offset='+enc(offset):'');
    const r = await http({hostname:'api.airtable.com',path,method:'GET',headers:{Authorization:'Bearer '+AT_KEY}});
    if (r.status>=300) throw new Error('AT '+r.status+': '+r.body.slice(0,200));
    const j = JSON.parse(r.body);
    for (const rec of (j.records||[])) out.push({id:rec.id, ...rec.fields});
    offset = j.offset;
  } while (offset);
  return out;
}

const TARGETS = ['084-ULT','208-HUB','209-TRUE','212-TRUE','213-TRUE','214-MYK','215-GT'];

(async () => {
  console.log('Pulling AT clients filtered to target codes...');
  // AT's "Client Code #3" field holds the NNN-XXX code
  const filter = `OR(${TARGETS.map(c => `{Client Code #3}='${c}'`).join(',')})`;
  const atClients = await listAT('Clients',
    ['Client Name','Client Code #3','ACTIVE/INACTIVE','Service Type',
     'GT Frequency','CL Frequency','WD Frequency',
     'GT $ per Visit','CL$ Price per Visit','WD$ Price per Visit',
     'GDO Number','Size GT in Gallon','GT First Visit Date','CL First Visit Date'],
    filter);
  console.log('AT matches:', atClients.length);
  console.log('');
  for (const c of atClients) {
    console.log(`---- ${c['Client Code #3']} ${c['Client Name']} ----`);
    console.log('  AT Status:', c['ACTIVE/INACTIVE']);
    console.log('  AT Service Type (canonical):', c['Service Type']);
    console.log('  GT Frequency:', c['GT Frequency'], '  GT $:', c['GT $ per Visit'], '  GT First:', c['GT First Visit Date']);
    console.log('  CL Frequency:', c['CL Frequency'], '  CL $:', c['CL$ Price per Visit'], '  CL First:', c['CL First Visit Date']);
    console.log('  WD Frequency:', c['WD Frequency'], '  WD $:', c['WD$ Price per Visit']);
    console.log('  GDO:', c['GDO Number'], '  Size GT:', c['Size GT in Gallon']);
  }

  // also show which targets were NOT found in AT
  const foundCodes = new Set(atClients.map(c => c['Client Code #3']));
  const missing = TARGETS.filter(c => !foundCodes.has(c));
  if (missing.length) {
    console.log('\n!! Not found in AT at all:', missing);
  }
})().catch(e => { console.error(e); process.exit(1); });
