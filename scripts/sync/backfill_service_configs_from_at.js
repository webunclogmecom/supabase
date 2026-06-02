// backfill_service_configs_from_at.js
//
// Targeted UPDATE-only backfill: fills NULL columns on existing service_configs
// rows from the Airtable Clients table. Uses the canonical field mappings from
// populate.js step 5 + matches AT clients via entity_source_links.
//
// Only touches columns that ARE NULL — never overwrites existing values.
//
// Fields covered:
//   frequency_days, price_per_visit, first_visit, last_visit (GT/CL/WD)
//   equipment_size_gallons (GT only)
//   permit_number, permit_expiration (GT only — GDO)
//
// NOT covered (no AT mapping yet — Fred decision pending):
//   material_type
//   permit_document_path (would need AT attachments → Storage migration)
//   schedule_notes, stop_date
//
// Idempotent. Safe to re-run.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const DRY_RUN = process.argv.includes('--dry-run');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x)); r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({ hostname: 'api.supabase.com', path: '/v1/projects/' + PROD + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json' } }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error('PG ' + r.status + ': ' + r.body.slice(0, 300));
  return JSON.parse(r.body);
}
async function listAT(table, fields, filter) {
  const out = []; let offset; const enc = encodeURIComponent;
  do {
    const fp = (fields || []).map(f => 'fields%5B%5D=' + enc(f)).join('&');
    const ff = filter ? '&filterByFormula=' + enc(filter) : '';
    const path = '/v0/' + AT_BASE + '/' + enc(table) + '?' + fp + '&pageSize=100' + ff + (offset ? '&offset=' + enc(offset) : '');
    const r = await http({ hostname: 'api.airtable.com', path, method: 'GET', headers: { Authorization: 'Bearer ' + AT_KEY } });
    if (r.status >= 300) throw new Error('AT ' + r.status + ': ' + r.body.slice(0, 200));
    const j = JSON.parse(r.body);
    for (const rec of (j.records || [])) out.push({ id: rec.id, ...rec.fields });
    offset = j.offset;
  } while (offset);
  return out;
}

function atField(rec, name) {
  const v = rec[name];
  if (v === null || v === undefined || v === '') return null;
  return v;
}
function numOrNull(v) { if (v === null || v === undefined || v === '') return null; const n = Number(v); return Number.isFinite(n) ? n : null; }
function dateOnly(v) { if (!v) return null; const s = String(v); return s.slice(0, 10) || null; }
function sqlStr(v) { if (v === null) return 'NULL'; return "'" + String(v).replace(/'/g, "''") + "'"; }
function sqlNum(v) { if (v === null) return 'NULL'; return String(v); }
function sqlDate(v) { if (v === null) return 'NULL'; return "DATE '" + v + "'"; }

const TYPE_MAP = {
  GT: { freq: 'GT Frequency', price: 'GT $ per Visit', first: 'GT First Visit Date', last: 'GT Last Visit (visits table)', size: 'Size GT in Gallon', gdoNum: 'GDO Number', gdoExp: 'GDO expiration date' },
  CL: { freq: 'CL Frequency', price: 'CL$ Price per Visit', first: 'CL First Visit Date', last: 'CL Last Visit' },
  WD: { freq: 'WD Frequency', price: 'WD$ Price per Visit', first: 'WD Contract Date' },
};

(async () => {
  console.log('=' .repeat(72));
  console.log('backfill_service_configs_from_at  Mode:', DRY_RUN ? 'DRY-RUN' : 'EXECUTE');
  console.log('=' .repeat(72));

  // 1. Pull AT clients with all relevant fields
  console.log('\n[1] Fetching Airtable Clients...');
  const atClients = await listAT('Clients', [
    'Client Name', 'GT Frequency', 'CL Frequency', 'WD Frequency',
    'GT $ per Visit', 'CL$ Price per Visit', 'WD$ Price per Visit',
    'Size GT in Gallon', 'GDO Number', 'GDO expiration date',
    'GT First Visit Date', 'CL First Visit Date', 'WD Contract Date',
    'GT Last Visit (visits table)', 'CL Last Visit'
  ]);
  console.log(`  ${atClients.length} AT Clients`);

  // 2. Map AT id → Sbx client_id
  console.log('\n[2] Loading client mapping (entity_source_links)...');
  const links = await pg(`SELECT entity_id AS client_id, source_id AS at_id FROM entity_source_links WHERE entity_type='client' AND source_system='airtable';`);
  const atToSbx = new Map(links.map(l => [l.at_id, l.client_id]));
  console.log(`  ${links.length} client links`);

  // 3. Load existing service_configs with any NULLs in the target columns
  console.log('\n[3] Loading existing service_configs with NULL columns...');
  const configs = await pg(`
    SELECT id, client_id, service_type, frequency_days, price_per_visit,
           first_visit, last_visit, equipment_size_gallons, permit_number,
           permit_expiration
    FROM service_configs
    WHERE service_type IN ('GT','CL','WD')
    ORDER BY service_type, client_id;
  `);
  console.log(`  ${configs.length} service_configs`);

  // 4. Build UPDATEs — for each NULL column, fill from AT if AT has it
  console.log('\n[4] Building UPDATE batch...');
  const updates = [];
  const skipReasons = { no_at_link: 0, all_fields_set: 0, at_has_nothing: 0, planned: 0 };

  for (const sc of configs) {
    // Find AT client for this sbx client
    const atId = [...atToSbx.entries()].find(([_, sbxId]) => sbxId === sc.client_id)?.[0];
    if (!atId) { skipReasons.no_at_link++; continue; }
    const ac = atClients.find(x => x.id === atId);
    if (!ac) { skipReasons.no_at_link++; continue; }

    const T = TYPE_MAP[sc.service_type];
    if (!T) continue;

    const newVals = {};
    if (sc.frequency_days === null && T.freq) {
      const v = numOrNull(atField(ac, T.freq));
      if (v !== null) newVals.frequency_days = v;
    }
    if (sc.price_per_visit === null && T.price) {
      const v = numOrNull(atField(ac, T.price));
      if (v !== null) newVals.price_per_visit = v;
    }
    if (sc.first_visit === null && T.first) {
      const v = dateOnly(atField(ac, T.first));
      if (v !== null) newVals.first_visit = v;
    }
    if (sc.last_visit === null && T.last) {
      const v = dateOnly(atField(ac, T.last));
      if (v !== null) newVals.last_visit = v;
    }
    if (sc.equipment_size_gallons === null && T.size) {
      const v = numOrNull(atField(ac, T.size));
      if (v !== null) newVals.equipment_size_gallons = v;
    }
    if (sc.permit_number === null && T.gdoNum) {
      const v = atField(ac, T.gdoNum);
      if (v) newVals.permit_number = String(v);
    }
    if (sc.permit_expiration === null && T.gdoExp) {
      const v = dateOnly(atField(ac, T.gdoExp));
      if (v !== null) newVals.permit_expiration = v;
    }

    if (Object.keys(newVals).length === 0) {
      // Either AT has nothing for these NULLs OR everything is already filled
      const anyNullFields = sc.frequency_days === null || sc.price_per_visit === null || sc.equipment_size_gallons === null || sc.permit_number === null;
      if (anyNullFields) skipReasons.at_has_nothing++;
      else skipReasons.all_fields_set++;
      continue;
    }
    updates.push({ id: sc.id, service_type: sc.service_type, vals: newVals });
    skipReasons.planned++;
  }

  console.log(`  Planned: ${updates.length} updates`);
  console.log(`  Skips: ${JSON.stringify(skipReasons)}`);

  if (updates.length === 0) { console.log('Nothing to do.'); return; }

  // Sample preview
  console.log('\n[5] Sample of planned updates (first 5):');
  updates.slice(0, 5).forEach(u => {
    console.log(`  sc.id=${u.id} (${u.service_type}): ${JSON.stringify(u.vals)}`);
  });

  if (DRY_RUN) {
    console.log('\nDRY-RUN — no writes performed.');
    return;
  }

  // 5. Execute updates in one big SQL with CASE
  console.log('\n[6] Executing UPDATEs...');
  const COLUMNS = ['frequency_days', 'price_per_visit', 'first_visit', 'last_visit', 'equipment_size_gallons', 'permit_number', 'permit_expiration'];
  const numericCols = new Set(['frequency_days', 'price_per_visit', 'equipment_size_gallons']);
  const dateCols = new Set(['first_visit', 'last_visit', 'permit_expiration']);

  let nUpdated = 0;
  const BATCH = 50;
  for (let i = 0; i < updates.length; i += BATCH) {
    const slice = updates.slice(i, i + BATCH);
    const setParts = COLUMNS.map(col => {
      const cases = slice.filter(u => col in u.vals).map(u => {
        const v = u.vals[col];
        const lit = numericCols.has(col) ? sqlNum(v) : dateCols.has(col) ? sqlDate(v) : sqlStr(v);
        return `WHEN ${u.id} THEN ${lit}`;
      });
      if (cases.length === 0) return null;
      return `${col} = COALESCE(${col}, CASE id ${cases.join(' ')} END)`;
    }).filter(Boolean);
    const ids = slice.map(u => u.id).join(',');
    const sql = `UPDATE service_configs SET ${setParts.join(', ')} WHERE id IN (${ids}) RETURNING id;`;
    const result = await pg(sql);
    nUpdated += result.length;
    process.stdout.write(`\r  ${nUpdated}/${updates.length}`);
  }
  console.log(`\n  ✓ ${nUpdated} service_configs updated`);

  // 6. Re-audit
  console.log('\n[7] Re-audit NULL counts on service_configs...');
  console.log(await pg(`
    SELECT service_type, COUNT(*) AS n,
      COUNT(*) FILTER (WHERE frequency_days IS NULL) AS null_freq,
      COUNT(*) FILTER (WHERE price_per_visit IS NULL) AS null_price,
      COUNT(*) FILTER (WHERE equipment_size_gallons IS NULL) AS null_equip,
      COUNT(*) FILTER (WHERE permit_number IS NULL) AS null_permit,
      COUNT(*) FILTER (WHERE permit_expiration IS NULL) AS null_pexp,
      COUNT(*) FILTER (WHERE first_visit IS NULL) AS null_first
    FROM service_configs GROUP BY service_type ORDER BY n DESC;
  `));
})().catch(e => { console.error('FATAL:', e); process.exit(2); });
