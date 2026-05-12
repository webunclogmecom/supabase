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
async function listAT(table, fields, filter) {
  const out=[]; let offset; const enc=encodeURIComponent;
  do {
    const fp = (fields||[]).map(f => `fields%5B%5D=${enc(f)}`).join('&');
    const ff = filter ? `&filterByFormula=${enc(filter)}` : '';
    const path = `/v0/${AT_BASE}/${enc(table)}?${fp}&pageSize=100${ff}${offset?`&offset=${enc(offset)}`:''}`;
    const r = await http({hostname:'api.airtable.com',path,method:'GET',headers:{Authorization:`Bearer ${AT_KEY}`}});
    if (r.status>=300) throw new Error(`AT ${r.status}: ${r.body.slice(0,200)}`);
    const j = JSON.parse(r.body); for (const rec of (j.records||[])) out.push({id:rec.id, ...rec.fields}); offset = j.offset;
  } while (offset);
  return out;
}
(async () => {
  const atClients = await listAT('Clients',
    ['Client Code #3','Client Name','Service Type','ACTIVE/INACTIVE','GT Frequency'],
    `AND(OR({ACTIVE/INACTIVE}='ACTIVE',{ACTIVE/INACTIVE}='Recurring'),FIND('Grease Trap',ARRAYJOIN({Service Type}))>0)`);
  const gtSubs = new Map();
  for (const c of atClients) if (c['Client Code #3']) gtSubs.set(c['Client Code #3'], c);
  const codeList = [...gtSubs.keys()].map(c => `'${c.replace(/'/g,"''")}'`).join(',');

  const dbRows = await pg(`
    WITH gt_clients AS (SELECT id, client_code, name FROM clients WHERE client_code IN (${codeList})),
    last_gt AS (
      SELECT DISTINCT ON (v.client_id) v.client_id, v.visit_date AS last_visit_date
      FROM visits v WHERE v.service_type='GT' AND v.visit_status='completed'
      ORDER BY v.client_id, v.visit_date DESC),
    next_gt AS (
      SELECT DISTINCT ON (v.client_id) v.client_id, v.visit_date AS next_visit_date
      FROM visits v WHERE v.service_type='GT' AND v.visit_status IN ('scheduled','late','today')
        AND v.visit_date >= CURRENT_DATE - INTERVAL '14 days'
      ORDER BY v.client_id, v.visit_date ASC),
    freq AS (SELECT client_id, frequency_days FROM service_configs WHERE service_type='GT' AND frequency_days > 0)
    SELECT g.client_code, g.name AS client_name, f.frequency_days,
      lg.last_visit_date::text AS last_visit_date,
      ng.next_visit_date::text AS next_visit_date,
      (CURRENT_DATE - lg.last_visit_date)::int AS days_since_last,
      (CURRENT_DATE - lg.last_visit_date)::int - f.frequency_days AS overdue_by
    FROM gt_clients g
    LEFT JOIN last_gt lg ON lg.client_id = g.id
    LEFT JOIN next_gt ng ON ng.client_id = g.id
    LEFT JOIN freq f ON f.client_id = g.id
    WHERE f.frequency_days IS NOT NULL AND lg.last_visit_date IS NOT NULL
      AND ng.next_visit_date IS NULL
      AND (CURRENT_DATE - lg.last_visit_date)::int > f.frequency_days + 7
    ORDER BY ((CURRENT_DATE - lg.last_visit_date)::int - f.frequency_days) DESC;`);

  console.log(`GT subscribers past cadence with NO upcoming visit: ${dbRows.length}\n`);
  console.log('Rank | code        | freq | last GT visit | days since | days overdue | client');
  console.log('-'.repeat(95));
  for (let i = 0; i < Math.min(dbRows.length, 10); i++) {
    const r = dbRows[i];
    console.log(`  ${(i+1).toString().padStart(2)} | ${r.client_code.padEnd(11)} | ${String(r.frequency_days).padStart(3)}d | ${r.last_visit_date} | ${String(r.days_since_last).padStart(3)}d ago | +${String(r.overdue_by).padStart(3)}d   | ${(r.client_name||'').slice(0,40)}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
