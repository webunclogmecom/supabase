// Enumerate all distinct Service Type multi-select values in AT Clients.
// Also: find Sbx clients with CL service_configs that came from "Main CL" only
// (i.e., AT Service Type does NOT include "AUX Cleaning" or any other true-CL signal).
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
async function listAT(table, fields) {
  const out=[]; let offset; const enc=encodeURIComponent;
  do {
    const fp = (fields||[]).map(f => 'fields%5B%5D='+enc(f)).join('&');
    const path = '/v0/'+AT_BASE+'/'+enc(table)+'?'+fp+'&pageSize=100'+(offset?'&offset='+enc(offset):'');
    const r = await http({hostname:'api.airtable.com',path,method:'GET',headers:{Authorization:'Bearer '+AT_KEY}});
    if (r.status>=300) throw new Error('AT '+r.status+': '+r.body.slice(0,200));
    const j = JSON.parse(r.body);
    for (const rec of (j.records||[])) out.push({id:rec.id, ...rec.fields});
    offset = j.offset;
  } while (offset);
  return out;
}

(async () => {
  const at = await listAT('Clients', ['Client Name','Client Code #3','ACTIVE/INACTIVE','Service Type']);
  console.log('AT clients fetched:', at.length);

  // 1. Tally distinct Service Type values
  const tally = new Map();
  for (const c of at) {
    const st = c['Service Type'];
    if (!Array.isArray(st)) continue;
    for (const v of st) {
      const name = (v && typeof v === 'object' && 'name' in v) ? v.name : String(v);
      tally.set(name, (tally.get(name) || 0) + 1);
    }
  }
  console.log('\n==== Distinct Service Type values in AT (count) ====');
  console.table([...tally.entries()].map(([v, n]) => ({ value: v, count: n })).sort((a,b) => b.count - a.count));

  // 2. Per-client list — which clients have "Main CL"? (any case)
  const mainCL = at.filter(c => {
    const st = c['Service Type']; if (!Array.isArray(st)) return false;
    return st.some(v => {
      const name = ((v && v.name) || v || '').toString().toLowerCase();
      return name.includes('main cl');
    });
  });
  console.log('\n==== Clients with "Main CL" in Service Type ====');
  console.log('count:', mainCL.length);
  console.table(mainCL.slice(0, 50).map(c => ({
    code: c['Client Code #3'],
    name: (c['Client Name']||'').slice(0,50),
    status: c['ACTIVE/INACTIVE']?.name || c['ACTIVE/INACTIVE'],
    serviceTypes: (c['Service Type']||[]).map(v => v.name || v).join(', '),
  })));

  // 3. Of those, which ones DON'T also have "AUX Cleaning"? These are the
  //    ones who got bogus CL configs from the old "main cl → CL" rule.
  const bogus = mainCL.filter(c => {
    const st = c['Service Type'];
    const hasAux = st.some(v => {
      const name = ((v && v.name) || v || '').toString().toLowerCase();
      return name.includes('aux cleaning');
    });
    return !hasAux;
  });
  console.log('\n==== "Main CL" clients WITHOUT also "AUX Cleaning" (bogus CL config candidates) ====');
  console.log('count:', bogus.length);
  console.table(bogus.slice(0, 50).map(c => ({
    code: c['Client Code #3'],
    name: (c['Client Name']||'').slice(0,50),
    status: c['ACTIVE/INACTIVE']?.name || c['ACTIVE/INACTIVE'],
    serviceTypes: (c['Service Type']||[]).map(v => v.name || v).join(', '),
  })));

  // 4. Cross-ref: do these have a CL service_config in Sbx?
  const codes = bogus.map(c => c['Client Code #3']).filter(Boolean);
  if (codes.length) {
    const codeList = codes.map(c => `'${c.replace(/'/g, "''")}'`).join(',');
    const sbxRows = await pg(`
      SELECT c.client_code, c.name, c.status,
        sc.service_type, sc.frequency_days, sc.price_per_visit, sc.last_visit::text,
        (SELECT COUNT(*)::int FROM visits v WHERE v.client_id = c.id AND v.service_type = sc.service_type) AS total_visits,
        (SELECT COUNT(*)::int FROM visits v WHERE v.client_id = c.id AND v.service_type = sc.service_type AND v.visit_date >= CURRENT_DATE) AS upcoming_visits
      FROM clients c
      JOIN service_configs sc ON sc.client_id = c.id
      WHERE c.client_code IN (${codeList})
        AND sc.service_type = 'CL'
      ORDER BY c.client_code;
    `);
    console.log('\n==== Bogus CL service_configs in Sbx ====');
    console.log('count:', sbxRows.length);
    console.table(sbxRows);
  }
})().catch(e => { console.error(e); process.exit(1); });
