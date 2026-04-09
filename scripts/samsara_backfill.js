#!/usr/bin/env node
/**
 * samsara_backfill.js
 * Backfills missing Samsara data into Supabase.
 *
 * Covers:
 *   - David GPS: Oct 13 2025 → now  (was interrupted during Viktor's initial sync)
 *   - Moises/Cloggy GPS: Mar 31 → now  (April partition empty)
 *   - All trucks engine_state / odometer / fuel / engine_seconds: Mar 19-25 → now
 *
 * Usage:
 *   node scripts/samsara_backfill.js [--dry-run]
 *
 * All upserts use ON CONFLICT DO NOTHING — safe to re-run.
 */

require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });
const https = require('https');

const SAMSARA_TOKEN = process.env.SAMSARA_API_TOKEN;
const SUPABASE_PAT  = process.env.SUPABASE_PAT;
const PROJECT_ID    = 'infbofuilnqqviyjlwul';
const DRY_RUN       = process.argv.includes('--dry-run');

if (!SAMSARA_TOKEN || !SUPABASE_PAT) {
  console.error('Missing SAMSARA_API_TOKEN or SUPABASE_PAT in .env');
  process.exit(1);
}

const VEHICLES = {
  Moises: '281474998706262',
  Cloggy: '281474998706263',
  David:  '281474998706264',
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

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
        catch (e) { reject(new Error(`JSON parse error (${res.statusCode}): ${data.slice(0, 300)}`)); }
      });
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function samsaraGet(path) {
  const { status, body } = await httpsRequest({
    hostname: 'api.samsara.com',
    path,
    method: 'GET',
    headers: { 'Authorization': `Bearer ${SAMSARA_TOKEN}` },
  });
  if (status !== 200) throw new Error(`Samsara ${status}: ${JSON.stringify(body).slice(0, 200)}`);
  return body;
}

async function runSQL(query) {
  if (DRY_RUN) {
    console.log('  [DRY RUN SQL]', query.slice(0, 120) + (query.length > 120 ? '…' : ''));
    return [];
  }
  const bodyStr = JSON.stringify({ query });
  const { status, body } = await httpsRequest({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROJECT_ID}/database/query`,
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${SUPABASE_PAT}`,
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(bodyStr),
    },
  }, bodyStr);
  if (body && body.message) throw new Error(`SQL error: ${body.message}`);
  return body;
}

// Insert rows in batches of BATCH_SIZE, with ON CONFLICT DO NOTHING
async function batchUpsert(table, columns, rows, conflictTarget) {
  if (rows.length === 0) return 0;
  const BATCH_SIZE = 200;
  let inserted = 0;
  for (let i = 0; i < rows.length; i += BATCH_SIZE) {
    const batch = rows.slice(i, i + BATCH_SIZE);
    const values = batch.map(r => `(${r.join(', ')})`).join(',\n');
    const sql = `INSERT INTO ${table} (${columns.join(', ')}) VALUES\n${values}\nON CONFLICT ${conflictTarget} DO NOTHING`;
    await runSQL(sql);
    inserted += batch.length;
    await sleep(80);
  }
  return inserted;
}

// Yields { start, end } ISO strings in hoursPerWindow-sized chunks
function* timeWindows(startISO, endISO, hoursPerWindow = 4) {
  let cur = new Date(startISO);
  const end = new Date(endISO);
  while (cur < end) {
    const next = new Date(cur.getTime() + hoursPerWindow * 3_600_000);
    const winEnd = next < end ? next : end;
    yield { start: cur.toISOString(), end: winEnd.toISOString() };
    cur = next;
  }
}

// ─── Per-type backfill functions ───────────────────────────────────────────

async function backfillGPS(vehicleName, vehicleId, startISO, endISO) {
  const label = `GPS / ${vehicleName}`;
  console.log(`\n▶ ${label}  ${startISO.slice(0,10)} → ${endISO.slice(0,10)}`);
  let total = 0, windows = 0;

  for (const { start, end } of timeWindows(startISO, endISO, 4)) {
    windows++;
    try {
      const url = `/fleet/vehicles/stats/history?types=gps&vehicleIds=${vehicleId}`
                + `&startTime=${encodeURIComponent(start)}&endTime=${encodeURIComponent(end)}`;
      const data = await samsaraGet(url);
      const vehicle = (data.data || []).find(v => v.id === vehicleId);
      const pts = vehicle?.gps || [];

      if (pts.length === 0) { process.stdout.write('.'); await sleep(120); continue; }

      const rows = pts.map(p => [
        esc(vehicleId),
        esc(p.time),
        p.latitude  ?? 'NULL',
        p.longitude ?? 'NULL',
        p.headingDegrees      !== undefined ? p.headingDegrees      : 'NULL',
        p.speedMilesPerHour   !== undefined ? p.speedMilesPerHour   : 'NULL',
        esc(p.reverseGeo?.formattedLocation ?? null),
        esc(p.address?.id   ?? null),
        esc(p.address?.name ?? null),
        p.isEcuSpeed ? 'true' : 'false',
        'NOW()',
      ]);

      const n = await batchUpsert(
        'samsara.gps_history',
        ['vehicle_id','time','latitude','longitude','heading_degrees','speed_mph',
         'reverse_geo','address_id','address_name','is_ecu_speed','synced_at'],
        rows,
        '(vehicle_id, time)',
      );
      total += n;
      process.stdout.write(`+${n}`);
    } catch (e) {
      console.error(`\n  ✗ window ${start}: ${e.message}`);
    }
    await sleep(180);
  }
  console.log(`\n  ✓ ${total} rows inserted | ${windows} windows`);
  return total;
}

async function backfillEngineStates(vehicleName, vehicleId, startISO, endISO) {
  console.log(`\n▶ EngineStates / ${vehicleName}  ${startISO.slice(0,10)} → ${endISO.slice(0,10)}`);
  let total = 0;
  for (const { start, end } of timeWindows(startISO, endISO, 6)) {
    try {
      const url = `/fleet/vehicles/stats/history?types=engineStates&vehicleIds=${vehicleId}`
                + `&startTime=${encodeURIComponent(start)}&endTime=${encodeURIComponent(end)}`;
      const data = await samsaraGet(url);
      const vehicle = (data.data || []).find(v => v.id === vehicleId);
      const pts = vehicle?.engineStates || [];
      if (pts.length === 0) { process.stdout.write('.'); await sleep(120); continue; }

      const rows = pts.map(p => [esc(vehicleId), esc(p.time), esc(p.value), 'NOW()']);
      const n = await batchUpsert(
        'samsara.engine_state_events',
        ['vehicle_id','time','state','synced_at'],
        rows, '(vehicle_id, time)',
      );
      total += n;
      process.stdout.write(`+${n}`);
    } catch (e) { console.error(`\n  ✗ ${start}: ${e.message}`); }
    await sleep(180);
  }
  console.log(`\n  ✓ ${total} rows`);
  return total;
}

async function backfillOdometer(vehicleName, vehicleId, startISO, endISO) {
  console.log(`\n▶ Odometer / ${vehicleName}  ${startISO.slice(0,10)} → ${endISO.slice(0,10)}`);
  let total = 0;
  for (const { start, end } of timeWindows(startISO, endISO, 6)) {
    try {
      const url = `/fleet/vehicles/stats/history?types=obdOdometerMeters&vehicleIds=${vehicleId}`
                + `&startTime=${encodeURIComponent(start)}&endTime=${encodeURIComponent(end)}`;
      const data = await samsaraGet(url);
      const vehicle = (data.data || []).find(v => v.id === vehicleId);
      const pts = vehicle?.obdOdometerMeters || [];
      if (pts.length === 0) { process.stdout.write('.'); await sleep(120); continue; }

      const rows = pts.map(p => [
        esc(vehicleId), esc(p.time),
        p.value,
        'NOW()',
      ]);
      const n = await batchUpsert(
        'samsara.odometer_readings',
        ['vehicle_id','time','value_meters','synced_at'],
        rows, '(vehicle_id, time)',
      );
      total += n;
      process.stdout.write(`+${n}`);
    } catch (e) { console.error(`\n  ✗ ${start}: ${e.message}`); }
    await sleep(180);
  }
  console.log(`\n  ✓ ${total} rows`);
  return total;
}

async function backfillFuel(vehicleName, vehicleId, startISO, endISO) {
  console.log(`\n▶ Fuel / ${vehicleName}  ${startISO.slice(0,10)} → ${endISO.slice(0,10)}`);
  let total = 0;
  for (const { start, end } of timeWindows(startISO, endISO, 6)) {
    try {
      const url = `/fleet/vehicles/stats/history?types=fuelPercents&vehicleIds=${vehicleId}`
                + `&startTime=${encodeURIComponent(start)}&endTime=${encodeURIComponent(end)}`;
      const data = await samsaraGet(url);
      const vehicle = (data.data || []).find(v => v.id === vehicleId);
      const pts = vehicle?.fuelPercents || [];
      if (pts.length === 0) { process.stdout.write('.'); await sleep(120); continue; }

      const rows = pts.map(p => [esc(vehicleId), esc(p.time), p.value, 'NOW()']);
      const n = await batchUpsert(
        'samsara.fuel_readings',
        ['vehicle_id','time','fuel_pct','synced_at'],
        rows, '(vehicle_id, time)',
      );
      total += n;
      process.stdout.write(`+${n}`);
    } catch (e) { console.error(`\n  ✗ ${start}: ${e.message}`); }
    await sleep(180);
  }
  console.log(`\n  ✓ ${total} rows`);
  return total;
}

async function backfillEngineSeconds(vehicleName, vehicleId, startISO, endISO) {
  console.log(`\n▶ EngineSeconds / ${vehicleName}  ${startISO.slice(0,10)} → ${endISO.slice(0,10)}`);
  let total = 0;
  for (const { start, end } of timeWindows(startISO, endISO, 6)) {
    try {
      const url = `/fleet/vehicles/stats/history?types=obdEngineSeconds&vehicleIds=${vehicleId}`
                + `&startTime=${encodeURIComponent(start)}&endTime=${encodeURIComponent(end)}`;
      const data = await samsaraGet(url);
      const vehicle = (data.data || []).find(v => v.id === vehicleId);
      const pts = vehicle?.obdEngineSeconds || [];
      if (pts.length === 0) { process.stdout.write('.'); await sleep(120); continue; }

      const rows = pts.map(p => [
        esc(vehicleId), esc(p.time),
        p.value,
        'NOW()',
      ]);
      const n = await batchUpsert(
        'samsara.engine_seconds',
        ['vehicle_id','time','seconds_total','synced_at'],
        rows, '(vehicle_id, time)',
      );
      total += n;
      process.stdout.write(`+${n}`);
    } catch (e) { console.error(`\n  ✗ ${start}: ${e.message}`); }
    await sleep(180);
  }
  console.log(`\n  ✓ ${total} rows`);
  return total;
}

// ─── Main ──────────────────────────────────────────────────────────────────

async function main() {
  const NOW = new Date().toISOString();
  console.log('═══════════════════════════════════════════════════════');
  console.log(`Samsara → Supabase backfill  |  ${NOW}`);
  if (DRY_RUN) console.log('DRY RUN — no writes to database');
  console.log('═══════════════════════════════════════════════════════');

  const results = {};

  // ── GPS ────────────────────────────────────────────────────────────────
  // David: interrupted at Oct 13 04:57 UTC during Viktor's initial sync
  results.davidGPS  = await backfillGPS('David',  VEHICLES.David,  '2025-10-13T05:00:00Z', NOW);
  // Moises/Cloggy: April partition is empty
  results.moisesGPS = await backfillGPS('Moises', VEHICLES.Moises, '2026-03-31T01:05:00Z', NOW);
  results.cloggyGPS = await backfillGPS('Cloggy', VEHICLES.Cloggy, '2026-03-31T05:42:00Z', NOW);

  // ── Engine states ───────────────────────────────────────────────────────
  results.moisesES = await backfillEngineStates('Moises', VEHICLES.Moises, '2026-03-25T00:26:00Z', NOW);
  results.cloggyES = await backfillEngineStates('Cloggy', VEHICLES.Cloggy, '2026-03-24T21:29:00Z', NOW);
  results.davidES  = await backfillEngineStates('David',  VEHICLES.David,  '2026-03-19T12:31:00Z', NOW);

  // ── Odometer ────────────────────────────────────────────────────────────
  results.moisesOdo = await backfillOdometer('Moises', VEHICLES.Moises, '2026-03-25T00:25:00Z', NOW);
  results.cloggyOdo = await backfillOdometer('Cloggy', VEHICLES.Cloggy, '2026-03-24T21:24:00Z', NOW);
  results.davidOdo  = await backfillOdometer('David',  VEHICLES.David,  '2026-03-19T12:31:00Z', NOW);

  // ── Fuel ────────────────────────────────────────────────────────────────
  results.moisesF = await backfillFuel('Moises', VEHICLES.Moises, '2026-03-25T01:44:00Z', NOW);
  results.cloggyF = await backfillFuel('Cloggy', VEHICLES.Cloggy, '2026-03-24T21:29:00Z', NOW);
  results.davidF  = await backfillFuel('David',  VEHICLES.David,  '2026-03-19T12:31:00Z', NOW);

  // ── Engine seconds ──────────────────────────────────────────────────────
  results.moisesEC = await backfillEngineSeconds('Moises', VEHICLES.Moises, '2026-03-25T02:57:00Z', NOW);
  results.cloggyEC = await backfillEngineSeconds('Cloggy', VEHICLES.Cloggy, '2026-03-24T21:29:00Z', NOW);
  results.davidEC  = await backfillEngineSeconds('David',  VEHICLES.David,  '2026-03-19T12:30:00Z', NOW);

  console.log('\n═══════════════════════════════════════════════════════');
  console.log('BACKFILL SUMMARY');
  console.log('═══════════════════════════════════════════════════════');
  const total = Object.values(results).reduce((a, b) => a + b, 0);
  for (const [key, n] of Object.entries(results)) {
    console.log(`  ${key.padEnd(12)}: ${n.toLocaleString()} rows`);
  }
  console.log(`  ${'TOTAL'.padEnd(12)}: ${total.toLocaleString()} rows`);
  console.log('═══════════════════════════════════════════════════════');
}

main().catch(err => {
  console.error('\nFatal error:', err.message);
  process.exit(1);
});
