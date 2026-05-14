// Check whether the 7 RECURRING clients with no service_configs have ESL rows to Airtable.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) {
  const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROD+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query:sql}));
  if(r.status>=300) throw new Error('PG '+r.status+': '+r.body.slice(0,300));
  return JSON.parse(r.body);
}

(async () => {
  const rows = await pg(`
    SELECT
      c.id, c.client_code, c.name, c.status, c.created_at::text,
      (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='airtable' LIMIT 1) AS at_id,
      (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='jobber'   LIMIT 1) AS jobber_id,
      (SELECT COUNT(*)::int FROM service_configs WHERE client_id = c.id) AS sc_count
    FROM clients c
    WHERE c.client_code IN ('084-ULT','208-HUB','209-TRUE','212-TRUE','213-TRUE','214-MYK','215-GT')
    ORDER BY c.client_code;
  `);
  console.table(rows);
})().catch(e => { console.error(e); process.exit(1); });
