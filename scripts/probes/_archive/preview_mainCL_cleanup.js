// Preview the cleanup of "bogus CL" data: clients whose AT Service Type
// contains "MAIN CL" but NOT "AUX Cleaning" — they shouldn't have CL configs
// or CL visits (main pipe cleaning is part of GT, not a separate service).
//
// Analyzes for each bogus client:
//   - Their CL service_config in Sbx
//   - Their CL visits (past completed vs future scheduled)
//   - Whether CL visit dates align with GT visit dates (= same-day = duplicate visit)
//
// NO writes. Run with --execute later when Fred approves.
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
  // 1. Find AT clients with MAIN CL but NOT AUX Cleaning
  const at = await listAT('Clients', ['Client Name','Client Code #3','Service Type']);
  const targetCodes = at.filter(c => {
    const st = c['Service Type']; if (!Array.isArray(st)) return false;
    const hasMain = st.some(v => ((v && v.name) || v || '').toString().toLowerCase().includes('main cl'));
    const hasAux  = st.some(v => ((v && v.name) || v || '').toString().toLowerCase().includes('aux cleaning'));
    return hasMain && !hasAux;
  }).map(c => c['Client Code #3']).filter(Boolean);
  console.log('AT clients with MAIN CL (no AUX Cleaning):', targetCodes.length);

  if (!targetCodes.length) { console.log('Nothing to clean up.'); return; }

  const codeList = targetCodes.map(c => `'${c.replace(/'/g, "''")}'`).join(',');

  // 2. Summary counts
  const summary = await pg(`
    WITH targets AS (
      SELECT id, client_code FROM clients WHERE client_code IN (${codeList})
    ),
    cl_visits AS (
      SELECT v.client_id, v.id AS visit_id, v.visit_date::date AS vd, v.visit_status, v.source
      FROM visits v
      WHERE v.client_id IN (SELECT id FROM targets)
        AND v.service_type = 'CL'
    ),
    gt_visits AS (
      SELECT v.client_id, v.visit_date::date AS vd
      FROM visits v
      WHERE v.client_id IN (SELECT id FROM targets)
        AND v.service_type = 'GT'
    )
    SELECT
      (SELECT COUNT(*)::int FROM service_configs WHERE client_id IN (SELECT id FROM targets) AND service_type='CL') AS bogus_cl_configs,
      (SELECT COUNT(*)::int FROM cl_visits) AS cl_visits_total,
      (SELECT COUNT(*)::int FROM cl_visits WHERE vd < CURRENT_DATE) AS cl_past,
      (SELECT COUNT(*)::int FROM cl_visits WHERE vd >= CURRENT_DATE) AS cl_future,
      (SELECT COUNT(*)::int FROM cl_visits WHERE source='supabase_cron') AS cl_cron_generated,
      (SELECT COUNT(*)::int FROM cl_visits WHERE source='jobber') AS cl_from_jobber,
      (SELECT COUNT(*)::int FROM cl_visits c WHERE EXISTS (SELECT 1 FROM gt_visits g WHERE g.client_id=c.client_id AND g.vd = c.vd)) AS cl_with_same_day_gt;
  `);
  console.log('\n==== Summary ====');
  console.table(summary);

  // 3. Sample: per-client visit breakdown (first 15)
  const detail = await pg(`
    SELECT c.client_code, c.name,
      (SELECT COUNT(*)::int FROM visits WHERE client_id=c.id AND service_type='CL' AND visit_date < CURRENT_DATE) AS cl_past,
      (SELECT COUNT(*)::int FROM visits WHERE client_id=c.id AND service_type='CL' AND visit_date >= CURRENT_DATE) AS cl_future,
      (SELECT COUNT(*)::int FROM visits WHERE client_id=c.id AND service_type='CL' AND source='jobber') AS cl_jobber,
      (SELECT COUNT(*)::int FROM visits WHERE client_id=c.id AND service_type='CL' AND source='supabase_cron') AS cl_cron,
      (SELECT COUNT(*)::int FROM visits WHERE client_id=c.id AND service_type='GT') AS gt_total,
      -- CL visits where SAME date also has a GT visit (= duplicate-ish)
      (SELECT COUNT(*)::int FROM visits v1
         WHERE v1.client_id=c.id AND v1.service_type='CL'
           AND EXISTS (SELECT 1 FROM visits v2 WHERE v2.client_id=c.id AND v2.service_type='GT' AND v2.visit_date = v1.visit_date)
      ) AS cl_with_same_day_gt
    FROM clients c
    WHERE c.client_code IN (${codeList})
      AND EXISTS (SELECT 1 FROM visits v WHERE v.client_id=c.id AND v.service_type='CL')
    ORDER BY c.client_code
    LIMIT 15;
  `);
  console.log('\n==== Per-client breakdown (first 15) ====');
  console.table(detail);
})().catch(e => { console.error(e); process.exit(1); });
