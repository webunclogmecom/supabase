// backfill_properties_from_at.js
//
// Targeted UPDATE-only backfill for primary properties from Airtable Clients.
// Only touches NULL columns — never overwrites existing data.
//
// Fields covered:
//   access_hours_start, access_hours_end, access_days  (AT: 'Hours in', 'Hours out', 'Days of the week')
//   county                                              (AT: 'County')
//   zone                                                (AT: 'Zone')
//   geofence_radius_meters, geofence_type               (Samsara-only — out of scope here)
//
// NOT covered (pending Fred decision on AT mapping):
//   default_disposal_facility_id  (would need facility-name → id lookup)
//   access_notes                  (no clear AT field)
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
async function listAT(table, fields) {
  const out = []; let offset; const enc = encodeURIComponent;
  do {
    const fp = (fields || []).map(f => 'fields%5B%5D=' + enc(f)).join('&');
    const path = '/v0/' + AT_BASE + '/' + enc(table) + '?' + fp + '&pageSize=100' + (offset ? '&offset=' + enc(offset) : '');
    const r = await http({ hostname: 'api.airtable.com', path, method: 'GET', headers: { Authorization: 'Bearer ' + AT_KEY } });
    if (r.status >= 300) throw new Error('AT ' + r.status + ': ' + r.body.slice(0, 200));
    const j = JSON.parse(r.body);
    for (const rec of (j.records || [])) out.push({ id: rec.id, ...rec.fields });
    offset = j.offset;
  } while (offset);
  return out;
}

function atSelectName(rec, name) {
  const v = rec[name];
  if (v === null || v === undefined || v === '') return null;
  if (typeof v === 'object' && v.name) return String(v.name);
  return String(v);
}
function atField(rec, name) {
  const v = rec[name];
  if (v === null || v === undefined || v === '') return null;
  return v;
}
function sqlStr(v) { if (v === null) return 'NULL'; return "'" + String(v).replace(/'/g, "''") + "'"; }
function sqlArr(arr) {
  if (!arr || !Array.isArray(arr) || arr.length === 0) return 'NULL';
  return "ARRAY[" + arr.map(x => sqlStr(String(x))).join(',') + "]::text[]";
}

(async () => {
  console.log('=' .repeat(72));
  console.log('backfill_properties_from_at  Mode:', DRY_RUN ? 'DRY-RUN' : 'EXECUTE');
  console.log('=' .repeat(72));

  console.log('\n[1] Fetching Airtable Clients...');
  const atClients = await listAT('Clients', [
    'Client Name', 'Hours in', 'Hours out', 'Days of the week', 'County', 'Zone'
  ]);
  console.log(`  ${atClients.length} AT Clients`);

  console.log('\n[2] Loading client mapping...');
  const links = await pg(`SELECT entity_id AS client_id, source_id AS at_id FROM entity_source_links WHERE entity_type='client' AND source_system='airtable';`);
  const atToSbx = new Map(links.map(l => [l.at_id, l.client_id]));
  console.log(`  ${links.length} client links`);

  console.log('\n[3] Loading primary properties...');
  const props = await pg(`
    SELECT id, client_id, access_hours_start, access_hours_end, access_days,
           county, zone
    FROM properties WHERE is_primary = true;
  `);
  console.log(`  ${props.length} primary properties`);

  console.log('\n[4] Building UPDATE batch...');
  const updates = [];
  const skipReasons = { no_at_link: 0, all_set: 0, at_has_nothing: 0, planned: 0 };

  for (const p of props) {
    const atId = [...atToSbx.entries()].find(([_, sbxId]) => sbxId === p.client_id)?.[0];
    if (!atId) { skipReasons.no_at_link++; continue; }
    const ac = atClients.find(x => x.id === atId);
    if (!ac) { skipReasons.no_at_link++; continue; }

    const newVals = {};
    if (p.access_hours_start === null) {
      const v = atField(ac, 'Hours in');
      if (v) newVals.access_hours_start = String(v);
    }
    if (p.access_hours_end === null) {
      const v = atField(ac, 'Hours out');
      if (v) newVals.access_hours_end = String(v);
    }
    if (p.access_days === null) {
      const v = atField(ac, 'Days of the week');
      // AT multi-select returns array of {id,name} or array of strings
      if (Array.isArray(v) && v.length > 0) {
        const arr = v.map(x => (typeof x === 'object' && x.name) ? x.name : String(x))
                     .map(s => s.toLowerCase().slice(0, 3));  // 'mon', 'tue', etc.
        if (arr.length > 0) newVals.access_days = arr;
      }
    }
    if (p.county === null) {
      const v = atSelectName(ac, 'County');
      if (v) newVals.county = v;
    }
    if (p.zone === null) {
      const v = atSelectName(ac, 'Zone');
      if (v) newVals.zone = v;
    }

    if (Object.keys(newVals).length === 0) {
      const anyNullFields = p.access_hours_start === null || p.access_hours_end === null || p.access_days === null || p.county === null || p.zone === null;
      if (anyNullFields) skipReasons.at_has_nothing++;
      else skipReasons.all_set++;
      continue;
    }
    updates.push({ id: p.id, vals: newVals });
    skipReasons.planned++;
  }

  console.log(`  Planned: ${updates.length}`);
  console.log(`  Skips: ${JSON.stringify(skipReasons)}`);

  if (updates.length === 0) { console.log('Nothing to do.'); return; }

  console.log('\n[5] Sample (first 5):');
  updates.slice(0, 5).forEach(u => console.log(`  prop.id=${u.id}: ${JSON.stringify(u.vals)}`));

  if (DRY_RUN) { console.log('\nDRY-RUN — no writes performed.'); return; }

  console.log('\n[6] Executing UPDATEs (one row at a time for simpler SQL)...');
  let nUpdated = 0;
  for (const u of updates) {
    const setParts = [];
    if ('access_hours_start' in u.vals) setParts.push(`access_hours_start = COALESCE(access_hours_start, ${sqlStr(u.vals.access_hours_start)})`);
    if ('access_hours_end' in u.vals) setParts.push(`access_hours_end = COALESCE(access_hours_end, ${sqlStr(u.vals.access_hours_end)})`);
    if ('access_days' in u.vals) setParts.push(`access_days = COALESCE(access_days, ${sqlArr(u.vals.access_days)})`);
    if ('county' in u.vals) setParts.push(`county = COALESCE(county, ${sqlStr(u.vals.county)})`);
    if ('zone' in u.vals) setParts.push(`zone = COALESCE(zone, ${sqlStr(u.vals.zone)})`);
    await pg(`UPDATE properties SET ${setParts.join(', ')} WHERE id = ${u.id};`);
    nUpdated++;
    if (nUpdated % 25 === 0) process.stdout.write(`\r  ${nUpdated}/${updates.length}`);
  }
  console.log(`\n  ✓ ${nUpdated} properties updated`);

  console.log('\n[7] Re-audit NULL counts on primary properties...');
  console.log(await pg(`
    SELECT
      COUNT(*) AS total,
      COUNT(*) FILTER(WHERE access_hours_start IS NULL) AS null_hours_start,
      COUNT(*) FILTER(WHERE access_hours_end IS NULL) AS null_hours_end,
      COUNT(*) FILTER(WHERE access_days IS NULL) AS null_days,
      COUNT(*) FILTER(WHERE county IS NULL) AS null_county,
      COUNT(*) FILTER(WHERE zone IS NULL) AS null_zone
    FROM properties WHERE is_primary=true;
  `));
})().catch(e => { console.error('FATAL:', e); process.exit(2); });
