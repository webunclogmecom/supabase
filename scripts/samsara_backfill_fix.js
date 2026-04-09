#!/usr/bin/env node
/**
 * samsara_backfill_fix.js
 * Re-runs only the tables/windows that failed in the initial backfill:
 *   - odometer_readings (all 3 trucks) — was failing on generated column
 *   - engine_seconds    (all 3 trucks) — was failing on generated column
 *   - Moises GPS from Oct 9 → now     — initial run showed 0 (start of data)
 */

require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });
const https = require('https');

const SAMSARA_TOKEN = process.env.SAMSARA_API_TOKEN;
const SUPABASE_PAT  = process.env.SUPABASE_PAT;
const PROJECT_ID    = 'infbofuilnqqviyjlwul';
const DRY_RUN       = process.argv.includes('--dry-run');

const VEHICLES = {
  Moises: '281474998706262',
  Cloggy: '281474998706263',
  David:  '281474998706264',
};

const sleep = ms => new Promise(r => setTimeout(r, ms));
function esc(s) {
  if (s === null || s === undefined) return 'NULL';
  return "'" + String(s).replace(/'/g, "''") + "'";
}

function httpsRequest(options, body = null) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, res => {
      let data = '';
      res.on('data', d => data += d);
      res.on('end', () => {
        try { resolve({ status: res.statusCode, body: JSON.parse(data) }); }
        catch (e) { reject(new Error(`JSON parse (${res.statusCode}): ${data.slice(0, 200)}`)); }
      });
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function samsaraGet(path) {
  const { status, body } = await httpsRequest({
    hostname: 'api.samsara.com', path, method: 'GET',
    headers: { 'Authorization': `Bearer ${SAMSARA_TOKEN}` },
  });
  if (status !== 200) throw new Error(`Samsara ${status}: ${JSON.stringify(body).slice(0, 200)}`);
  return body;
}

async function runSQL(query) {
  if (DRY_RUN) { console.log('  [DRY RUN]', query.slice(0, 100) + '…'); return []; }
  const bodyStr = JSON.stringify({ query });
  const { body } = await httpsRequest({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROJECT_ID}/database/query`,
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${SUPABASE_PAT}`,
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(bodyStr),
    },
  }, bodyStr);
  if (body && body.message) throw new Error(body.message);
  return body;
}

async function batchUpsert(table, columns, rows, conflict) {
  if (rows.length === 0) return 0;
  const BATCH = 200;
  let n = 0;
  for (let i = 0; i < rows.length; i += BATCH) {
    const batch = rows.slice(i, i + BATCH);
    const values = batch.map(r => `(${r.join(', ')})`).join(',\n');
    await runSQL(`INSERT INTO ${table} (${columns.join(', ')}) VALUES\n${values}\nON CONFLICT ${conflict} DO NOTHING`);
    n += batch.length;
    await sleep(80);
  }
  return n;
}

function* timeWindows(startISO, endISO, hours = 6) {
  let cur = new Date(startISO);
  const end = new Date(endISO);
  while (cur < end) {
    const next = new Date(cur.getTime() + hours * 3_600_000);
    yield { start: cur.toISOString(), end: (next < end ? next : end).toISOString() };
    cur = next;
  }
}

async function backfillOdometer(vehicleName, vehicleId, startISO, endISO) {
  console.log(`\n▶ Odometer / ${vehicleName}  ${startISO.slice(0,10)} → ${endISO.slice(0,10)}`);
  let total = 0;
  for (const { start, end } of timeWindows(startISO, endISO)) {
    try {
      const url = `/fleet/vehicles/stats/history?types=obdOdometerMeters&vehicleIds=${vehicleId}`
                + `&startTime=${encodeURIComponent(start)}&endTime=${encodeURIComponent(end)}`;
      const data = await samsaraGet(url);
      const pts = (data.data || []).find(v => v.id === vehicleId)?.obdOdometerMeters || [];
      if (pts.length === 0) { process.stdout.write('.'); await sleep(100); continue; }
      const rows = pts.map(p => [esc(vehicleId), esc(p.time), p.value, 'NOW()']);
      const n = await batchUpsert(
        'samsara.odometer_readings',
        ['vehicle_id','time','value_meters','synced_at'],
        rows, '(vehicle_id, time)',
      );
      total += n; process.stdout.write(`+${n}`);
    } catch (e) { console.error(`\n  ✗ ${start}: ${e.message}`); }
    await sleep(180);
  }
  console.log(`\n  ✓ ${total} rows`);
  return total;
}

async function backfillEngineSeconds(vehicleName, vehicleId, startISO, endISO) {
  console.log(`\n▶ EngineSeconds / ${vehicleName}  ${startISO.slice(0,10)} → ${endISO.slice(0,10)}`);
  let total = 0;
  for (const { start, end } of timeWindows(startISO, endISO)) {
    try {
      const url = `/fleet/vehicles/stats/history?types=obdEngineSeconds&vehicleIds=${vehicleId}`
                + `&startTime=${encodeURIComponent(start)}&endTime=${encodeURIComponent(end)}`;
      const data = await samsaraGet(url);
      const pts = (data.data || []).find(v => v.id === vehicleId)?.obdEngineSeconds || [];
      if (pts.length === 0) { process.stdout.write('.'); await sleep(100); continue; }
      const rows = pts.map(p => [esc(vehicleId), esc(p.time), p.value, 'NOW()']);
      const n = await batchUpsert(
        'samsara.engine_seconds',
        ['vehicle_id','time','seconds_total','synced_at'],
        rows, '(vehicle_id, time)',
      );
      total += n; process.stdout.write(`+${n}`);
    } catch (e) { console.error(`\n  ✗ ${start}: ${e.message}`); }
    await sleep(180);
  }
  console.log(`\n  ✓ ${total} rows`);
  return total;
}

async function backfillGPS(vehicleName, vehicleId, startISO, endISO) {
  console.log(`\n▶ GPS / ${vehicleName}  ${startISO.slice(0,10)} → ${endISO.slice(0,10)}`);
  let total = 0;
  for (const { start, end } of timeWindows(startISO, endISO, 4)) {
    try {
      const url = `/fleet/vehicles/stats/history?types=gps&vehicleIds=${vehicleId}`
                + `&startTime=${encodeURIComponent(start)}&endTime=${encodeURIComponent(end)}`;
      const data = await samsaraGet(url);
      const pts = (data.data || []).find(v => v.id === vehicleId)?.gps || [];
      if (pts.length === 0) { process.stdout.write('.'); await sleep(120); continue; }
      const rows = pts.map(p => [
        esc(vehicleId), esc(p.time),
        p.latitude ?? 'NULL', p.longitude ?? 'NULL',
        p.headingDegrees !== undefined ? p.headingDegrees : 'NULL',
        p.speedMilesPerHour !== undefined ? p.speedMilesPerHour : 'NULL',
        esc(p.reverseGeo?.formattedLocation ?? null),
        esc(p.address?.id ?? null), esc(p.address?.name ?? null),
        p.isEcuSpeed ? 'true' : 'false',
        'NOW()',
      ]);
      const n = await batchUpsert(
        'samsara.gps_history',
        ['vehicle_id','time','latitude','longitude','heading_degrees','speed_mph',
         'reverse_geo','address_id','address_name','is_ecu_speed','synced_at'],
        rows, '(vehicle_id, time)',
      );
      total += n; process.stdout.write(`+${n}`);
    } catch (e) { console.error(`\n  ✗ ${start}: ${e.message}`); }
    await sleep(180);
  }
  console.log(`\n  ✓ ${total} rows`);
  return total;
}

async function main() {
  const NOW = new Date().toISOString();
  console.log('═══════════════════════════════════════════════════════');
  console.log(`Samsara backfill FIX run  |  ${NOW}`);
  if (DRY_RUN) console.log('DRY RUN');
  console.log('═══════════════════════════════════════════════════════');

  const results = {};

  // Odometer — full history for all trucks (generated column fix)
  results.moisesOdo = await backfillOdometer('Moises', VEHICLES.Moises, '2025-10-15T12:15:00Z', NOW);
  results.cloggyOdo = await backfillOdometer('Cloggy', VEHICLES.Cloggy, '2025-12-18T14:57:00Z', NOW);
  results.davidOdo  = await backfillOdometer('David',  VEHICLES.David,  '2025-10-09T17:38:00Z', NOW);

  // Engine seconds — full history (generated column fix)
  results.moisesEC = await backfillEngineSeconds('Moises', VEHICLES.Moises, '2025-10-15T12:14:00Z', NOW);
  results.cloggyEC = await backfillEngineSeconds('Cloggy', VEHICLES.Cloggy, '2025-12-18T00:25:00Z', NOW);
  results.davidEC  = await backfillEngineSeconds('David',  VEHICLES.David,  '2025-10-09T17:37:00Z', NOW);

  // Moises GPS — from beginning (Oct 9) to pick up any missed windows
  results.moisesGPS = await backfillGPS('Moises', VEHICLES.Moises, '2025-10-09T17:26:00Z', NOW);

  const total = Object.values(results).reduce((a, b) => a + b, 0);
  console.log('\n═══════════════════════════════════════════════════════');
  console.log('FIX SUMMARY');
  for (const [k, n] of Object.entries(results)) console.log(`  ${k.padEnd(12)}: ${n.toLocaleString()}`);
  console.log(`  ${'TOTAL'.padEnd(12)}: ${total.toLocaleString()}`);
  console.log('═══════════════════════════════════════════════════════');
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });
