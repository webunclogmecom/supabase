// insert_service_configs_for_missing_clients.js
//
// One-off backfill: for clients with visits in 2026-05 (or upcoming) but
// ZERO public.service_configs rows, INSERT GT/CL/WD configs from Airtable
// "Service Type" multi-select + per-service Frequency / Price / Size fields.
//
// Uses the same TYPE_MAP + AT field names as backfill_service_configs_from_at.js
// but creates new rows instead of updating null columns.
//
// Idempotent: ON CONFLICT (client_id, service_type) DO NOTHING.
//
// Usage:
//   node scripts/sync/insert_service_configs_for_missing_clients.js          # dry-run
//   node scripts/sync/insert_service_configs_for_missing_clients.js --execute

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const EXECUTE = process.argv.includes('--execute');
const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x)); r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({ hostname: 'api.supabase.com', path: `/v1/projects/${PROD}/database/query`, method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' } }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 400)}`);
  return JSON.parse(r.body);
}
async function listAT(table, fields, filter) {
  const out = []; let offset; const enc = encodeURIComponent;
  do {
    const fp = (fields || []).map(f => 'fields%5B%5D=' + enc(f)).join('&');
    const ff = filter ? '&filterByFormula=' + enc(filter) : '';
    const path = `/v0/${AT_BASE}/${enc(table)}?${fp}&pageSize=100${ff}${offset ? '&offset=' + enc(offset) : ''}`;
    const r = await http({ hostname: 'api.airtable.com', path, method: 'GET', headers: { Authorization: `Bearer ${AT_KEY}` } });
    if (r.status >= 300) throw new Error(`AT ${r.status}: ${r.body.slice(0, 200)}`);
    const j = JSON.parse(r.body);
    for (const rec of (j.records || [])) out.push({ id: rec.id, ...rec.fields });
    offset = j.offset;
  } while (offset);
  return out;
}

function numOrNull(v) { if (v === null || v === undefined || v === '') return null; const n = Number(v); return Number.isFinite(n) ? n : null; }
function dateOnly(v) { if (!v) return null; return String(v).slice(0, 10) || null; }
function sqlNum(v) { return v === null ? 'NULL' : String(v); }
function sqlDate(v) { return v === null ? 'NULL' : `DATE '${v}'`; }
function sqlStr(v) { return v === null ? 'NULL' : `'${String(v).replace(/'/g, "''")}'`; }

const TYPE_MAP = {
  GT: { freq: 'GT Frequency', price: 'GT $ per Visit', first: 'GT First Visit Date', size: 'Size GT in Gallon' },
  CL: { freq: 'CL Frequency', price: 'CL$ Price per Visit', first: 'CL First Visit Date' },
  WD: { freq: 'WD Frequency', price: 'WD$ Price per Visit', first: 'WD Contract Date' },
};

(async () => {
  console.log('='.repeat(72));
  console.log(`insert_service_configs_for_missing_clients   mode=${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}`);
  console.log('='.repeat(72));

  // 1. Identify clients with visits in May 2026 but zero service_configs for the visit's service_type
  console.log('\n[1] Finding clients with visits but no matching service_configs...');
  const missing = await pg(`
    SELECT DISTINCT v.client_id, c.name AS client_name, c.client_code, v.service_type
    FROM public.visits v
    JOIN public.clients c ON c.id = v.client_id
    WHERE v.visit_date >= '2026-05-01'
      AND v.service_type IS NOT NULL
      AND v.service_type IN ('GT','CL','WD')
      AND NOT EXISTS (
        SELECT 1 FROM public.service_configs sc
        WHERE sc.client_id = v.client_id AND sc.service_type = v.service_type
      )
    ORDER BY c.name, v.service_type;
  `);
  console.log(`  ${missing.length} (client_id, service_type) pairs need a service_config row`);
  if (missing.length === 0) { console.log('Nothing to backfill.'); return; }

  // 2. Pull AT client mapping
  console.log('\n[2] Loading client → AT id mapping...');
  const links = await pg(`
    SELECT entity_id AS client_id, source_id AS at_id
    FROM public.entity_source_links
    WHERE entity_type='client' AND source_system='airtable';
  `);
  const sbxToAt = new Map(links.map(l => [String(l.client_id), l.at_id]));
  console.log(`  ${links.length} client links loaded`);

  // 3. Pull AT records for the missing clients only
  const neededAtIds = new Set();
  for (const m of missing) {
    const atId = sbxToAt.get(String(m.client_id));
    if (atId) neededAtIds.add(atId);
  }
  console.log(`\n[3] Fetching ${neededAtIds.size} AT Clients records...`);
  const atClients = await listAT('Clients', [
    'Client Name', 'Service Type',
    'GT Frequency', 'CL Frequency', 'WD Frequency',
    'GT $ per Visit', 'CL$ Price per Visit', 'WD$ Price per Visit',
    'Size GT in Gallon',
    'GT First Visit Date', 'CL First Visit Date', 'WD Contract Date',
  ]);
  const atById = new Map(atClients.map(c => [c.id, c]));
  console.log(`  ${atClients.length} AT Clients loaded (${atClients.filter(c => neededAtIds.has(c.id)).length} match our needed set)`);

  // 4. Plan inserts — one row per (client_id, service_type) pair where AT has at least frequency OR price
  console.log('\n[4] Planning INSERTs...');
  const plan = [];
  const skipped = { no_at_link: 0, no_at_record: 0, no_at_data: 0, planned: 0 };
  for (const m of missing) {
    const atId = sbxToAt.get(String(m.client_id));
    if (!atId) { skipped.no_at_link++; continue; }
    const ac = atById.get(atId);
    if (!ac) { skipped.no_at_record++; continue; }
    const T = TYPE_MAP[m.service_type];
    if (!T) continue;
    const freq = numOrNull(ac[T.freq]);
    const price = numOrNull(ac[T.price]);
    const size = m.service_type === 'GT' ? numOrNull(ac['Size GT in Gallon']) : null;
    const first = dateOnly(ac[T.first]);

    if (freq === null && price === null && size === null) {
      skipped.no_at_data++;
      continue;
    }
    plan.push({
      client_id: m.client_id,
      client_name: m.client_name,
      service_type: m.service_type,
      frequency_days: freq,
      price_per_visit: price,
      equipment_size_gallons: size,
      first_visit: first,
    });
    skipped.planned++;
  }

  console.log(`  Planned: ${plan.length} INSERTs`);
  console.log(`  Skipped: ${JSON.stringify(skipped)}`);

  if (plan.length === 0) { console.log('Nothing actionable from AT.'); return; }

  console.log('\n[5] Sample of planned inserts (first 10):');
  plan.slice(0, 10).forEach(p => {
    console.log(`  ${p.client_name.padEnd(40)} ${p.service_type}  freq=${p.frequency_days}  price=${p.price_per_visit}  size=${p.equipment_size_gallons}`);
  });

  if (!EXECUTE) {
    console.log('\nDRY-RUN — no writes performed. Re-run with --execute to apply.');
    return;
  }

  // 5. Execute INSERTs in one batch with ON CONFLICT DO NOTHING
  console.log('\n[6] Executing INSERTs...');
  const values = plan.map(p => `(${p.client_id}, ${sqlStr(p.service_type)}, ${sqlNum(p.frequency_days)}, ${sqlNum(p.price_per_visit)}, ${sqlNum(p.equipment_size_gallons)}, ${sqlDate(p.first_visit)})`).join(',');
  const sql = `
    INSERT INTO public.service_configs
      (client_id, service_type, frequency_days, price_per_visit, equipment_size_gallons, first_visit)
    VALUES ${values}
    ON CONFLICT (client_id, service_type) DO NOTHING
    RETURNING id, client_id, service_type;
  `;
  const inserted = await pg(sql);
  console.log(`  Inserted ${inserted.length} rows.`);
  inserted.slice(0, 8).forEach(r => console.log(`    sc.id=${r.id}  client_id=${r.client_id}  service_type=${r.service_type}`));

  // 6. Refresh the v_calendar_visit + report new state
  console.log('\n[7] Re-check v_calendar_visit missing counts (May 2026):');
  const after = await pg(`
    SELECT
      count(*)::int AS total,
      sum(CASE WHEN frequency_days IS NULL THEN 1 ELSE 0 END)::int AS missing_frequency,
      sum(CASE WHEN equipment_size_gallons IS NULL THEN 1 ELSE 0 END)::int AS missing_equipment_size,
      sum(CASE WHEN amount IS NULL THEN 1 ELSE 0 END)::int AS missing_amount
    FROM ops.v_calendar_visit
    WHERE visit_date BETWEEN '2026-05-01' AND '2026-05-31';
  `);
  console.log(after);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
