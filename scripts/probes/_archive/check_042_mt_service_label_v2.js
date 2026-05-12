require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error(`PG ${r.status}: ${r.body.slice(0,200)}`); return JSON.parse(r.body); }
(async () => {
  console.log('=== line_items columns ===');
  const cols = await pg(`SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='line_items' ORDER BY ordinal_position;`);
  console.log(cols.map(c => c.column_name).join(', '));

  console.log('\n=== Line items on job 268 (what Lovable is reading for visit 1713) ===');
  const li = await pg(`SELECT * FROM line_items WHERE job_id = 268 ORDER BY id;`);
  console.log(JSON.stringify(li, null, 2));

  console.log('\n=== service_configs for 042-MT ===');
  const sc = await pg(`
    SELECT sc.service_type, sc.frequency_days, sc.price_per_visit, sc.equipment_size_gallons
    FROM service_configs sc JOIN clients c ON c.id = sc.client_id
    WHERE c.client_code = '042-MT' ORDER BY sc.service_type;`);
  console.log(JSON.stringify(sc, null, 2));

  console.log('\n=== Airtable: 042-MT ===');
  const enc = encodeURIComponent;
  const r = await http({hostname:'api.airtable.com',path:`/v0/${AT_BASE}/Clients?filterByFormula=${enc("{Client Code #3}='042-MT'")}&pageSize=1`,method:'GET',headers:{Authorization:`Bearer ${AT_KEY}`}});
  const at = JSON.parse(r.body).records?.[0]?.fields;
  console.log({
    'Client Name': at?.['Client Name'],
    'ACTIVE/INACTIVE': at?.['ACTIVE/INACTIVE'],
    'Service Type': at?.['Service Type'],
    'GT Frequency': at?.['GT Frequency'],
    'CL Frequency': at?.['CL Frequency'],
  });

  console.log('\n=== How widespread is "Residential" appearing in line_items for COMMERCIAL clients? ===');
  const widespread = await pg(`
    SELECT
      COUNT(DISTINCT v.id) AS n_visits,
      COUNT(DISTINCT v.client_id) AS n_clients,
      COUNT(DISTINCT v.job_id) AS n_jobs
    FROM visits v JOIN clients c ON c.id = v.client_id
    JOIN line_items li ON li.job_id = v.job_id
    WHERE c.client_code ~ '^[0-9]{3}-' AND li.name ILIKE '%residential%';`);
  console.log(JSON.stringify(widespread, null, 2));

  console.log('\n=== Top 15 line_item names overall ===');
  const top = await pg(`SELECT name, COUNT(*) AS n FROM line_items GROUP BY name ORDER BY n DESC LIMIT 15;`);
  for (const r of top) console.log(`  ${String(r.n).padStart(5)}  ${r.name}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
