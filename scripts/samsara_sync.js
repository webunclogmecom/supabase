#!/usr/bin/env node
/**
 * samsara_sync.js
 * Nightly incremental sync: Samsara → Supabase
 * Scheduled: 6:30 AM UTC daily
 *
 * Syncs ALL 5 time-series tables for all 3 vehicles:
 *   gps_history, engine_state_events, odometer_readings,
 *   fuel_readings, engine_seconds
 *
 * Also refreshes static tables (vehicles, drivers, addresses, etc.)
 * and updates vehicle_locations_latest.
 *
 * Reads last sync time from samsara.sync_cursors.
 * Writes results to console (pipe to a log file via cron).
 *
 * Usage:
 *   node scripts/samsara_sync.js [--dry-run] [--hours N]
 *   --hours N  override lookback window (default: reads from sync_cursors,
 *              falls back to 26h to cover overnight ops + buffer)
 */

require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });
const https = require('https');

const SAMSARA_TOKEN = process.env.SAMSARA_API_TOKEN;
const SUPABASE_PAT  = process.env.SUPABASE_PAT;
const PROJECT_ID    = 'infbofuilnqqviyjlwul';
const DRY_RUN       = process.argv.includes('--dry-run');
const HOURS_ARG     = (() => {
  const idx = process.argv.indexOf('--hours');
  return idx !== -1 ? parseInt(process.argv[idx + 1]) : null;
})();

if (!SAMSARA_TOKEN || !SUPABASE_PAT) {
  console.error('Missing SAMSARA_API_TOKEN or SUPABASE_PAT in .env');
  process.exit(1);
}

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
    hostname: 'api.samsara.com',
    path,
    method: 'GET',
    headers: { 'Authorization': `Bearer ${SAMSARA_TOKEN}` },
  });
  if (status !== 200) throw new Error(`Samsara ${status}: ${JSON.stringify(body).slice(0, 200)}`);
  return body;
}

async function samsaraGetPaginated(basePath) {
  const all = [];
  let cursor = null;
  do {
    const url = cursor ? `${basePath}&after=${cursor}` : basePath;
    const data = await samsaraGet(url);
    all.push(...(data.data || []));
    cursor = data.pagination?.hasNextPage ? data.pagination.endCursor : null;
    if (cursor) await sleep(100);
  } while (cursor);
  return all;
}

async function runSQL(query) {
  if (DRY_RUN) {
    console.log('  [DRY RUN]', query.slice(0, 120) + (query.length > 120 ? '…' : ''));
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
  if (body && body.message) throw new Error(body.message);
  return body;
}

async function batchUpsert(table, columns, rows, conflictTarget, doUpdate = false) {
  if (rows.length === 0) return 0;
  const BATCH = 200;
  let n = 0;
  for (let i = 0; i < rows.length; i += BATCH) {
    const batch = rows.slice(i, i + BATCH);
    const values = batch.map(r => `(${r.join(', ')})`).join(',\n');
    let onConflict = `ON CONFLICT ${conflictTarget} DO NOTHING`;
    if (doUpdate) {
      // Update all non-conflict columns on conflict
      const updateCols = columns.filter(c => !conflictTarget.includes(c));
      const setClauses = updateCols.map(c => `${c} = EXCLUDED.${c}`).join(', ');
      onConflict = `ON CONFLICT ${conflictTarget} DO UPDATE SET ${setClauses}`;
    }
    await runSQL(
      `INSERT INTO ${table} (${columns.join(', ')}) VALUES\n${values}\n${onConflict}`
    );
    n += batch.length;
    await sleep(60);
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

// ─── Sync cursor helpers ───────────────────────────────────────────────────

async function getCursor(entityType, vehicleId) {
  const rows = await runSQL(
    `SELECT last_synced_at FROM samsara.sync_cursors WHERE entity_type=${esc(entityType)} AND vehicle_id=${esc(vehicleId)}`
  );
  return (rows && rows[0]) ? rows[0].last_synced_at : null;
}

async function setCursor(entityType, vehicleId, lastSyncedAt) {
  await runSQL(`
    INSERT INTO samsara.sync_cursors (entity_type, vehicle_id, last_synced_at, updated_at)
    VALUES (${esc(entityType)}, ${esc(vehicleId)}, ${esc(lastSyncedAt)}, NOW())
    ON CONFLICT (entity_type, vehicle_id) DO UPDATE
      SET last_synced_at = EXCLUDED.last_synced_at, updated_at = NOW()
  `);
}

// ─── Static entity syncs ───────────────────────────────────────────────────

async function syncVehicles() {
  const vehicles = await samsaraGetPaginated('/fleet/vehicles');
  const n = await batchUpsert(
    'samsara.vehicles',
    ['id','name','synced_at'],
    vehicles.map(v => [esc(v.id), esc(v.name), 'NOW()']),
    '(id)', true,
  );
  console.log(`  vehicles: ${n} upserted`);
  return n;
}

async function syncDrivers() {
  const drivers = await samsaraGetPaginated('/fleet/drivers');
  const n = await batchUpsert(
    'samsara.drivers',
    ['id','name','synced_at'],
    drivers.map(d => [esc(d.id), esc(d.name), 'NOW()']),
    '(id)', true,
  );
  console.log(`  drivers: ${n} upserted`);
  return n;
}

async function syncAddresses() {
  const addresses = await samsaraGetPaginated('/addresses?limit=512');
  const n = await batchUpsert(
    'samsara.addresses',
    ['id','name','synced_at'],
    addresses.map(a => [esc(a.id), esc(a.name), 'NOW()']),
    '(id)', true,
  );
  console.log(`  addresses: ${n} upserted`);
  return n;
}

async function syncLocationLatest() {
  const data = await samsaraGet('/fleet/vehicles/locations');
  const locations = data.data || [];
  const rows = locations.map(v => {
    const loc = v.location || {};
    return [
      esc(v.id),
      esc(loc.time || null),
      loc.latitude  ?? 'NULL',
      loc.longitude ?? 'NULL',
      loc.heading   !== undefined ? loc.heading : 'NULL',
      loc.speed     !== undefined ? loc.speed   : 'NULL',
      esc(loc.reverseGeo?.formattedLocation || null),
      esc(loc.address?.id   || null),
      esc(loc.address?.name || null),
      'NOW()',
    ];
  });
  const n = await batchUpsert(
    'samsara.vehicle_locations_latest',
    ['vehicle_id','location_time','latitude','longitude','heading_degrees','speed_mph',
     'reverse_geo','geofence_address_id','geofence_address_name','synced_at'],
    rows,
    '(vehicle_id)',
  );
  console.log(`  vehicle_locations_latest: ${n} upserted`);
  return n;
}

// ─── Time-series syncs ─────────────────────────────────────────────────────

async function syncGPS(vehicleName, vehicleId, startISO, endISO) {
  let total = 0;
  for (const { start, end } of timeWindows(startISO, endISO, 6)) {
    try {
      const url = `/fleet/vehicles/stats/history?types=gps&vehicleIds=${vehicleId}`
                + `&startTime=${encodeURIComponent(start)}&endTime=${encodeURIComponent(end)}`;
      const data = await samsaraGet(url);
      const vehicle = (data.data || []).find(v => v.id === vehicleId);
      const pts = vehicle?.gps || [];
      if (pts.length === 0) { await sleep(100); continue; }

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
      total += await batchUpsert(
        'samsara.gps_history',
        ['vehicle_id','time','latitude','longitude','heading_degrees','speed_mph',
         'reverse_geo','address_id','address_name','is_ecu_speed','synced_at'],
        rows, '(vehicle_id, time)',
      );
    } catch (e) { console.error(`    ✗ GPS ${vehicleName} ${start}: ${e.message}`); }
    await sleep(150);
  }
  console.log(`  GPS / ${vehicleName}: ${total} new rows`);
  return total;
}

async function syncEngineStates(vehicleName, vehicleId, startISO, endISO) {
  let total = 0;
  for (const { start, end } of timeWindows(startISO, endISO, 6)) {
    try {
      const url = `/fleet/vehicles/stats/history?types=engineStates&vehicleIds=${vehicleId}`
                + `&startTime=${encodeURIComponent(start)}&endTime=${encodeURIComponent(end)}`;
      const data = await samsaraGet(url);
      const vehicle = (data.data || []).find(v => v.id === vehicleId);
      const pts = vehicle?.engineStates || [];
      if (pts.length === 0) { await sleep(100); continue; }
      const rows = pts.map(p => [esc(vehicleId), esc(p.time), esc(p.value), 'NOW()']);
      total += await batchUpsert(
        'samsara.engine_state_events',
        ['vehicle_id','time','state','synced_at'],
        rows, '(vehicle_id, time)',
      );
    } catch (e) { console.error(`    ✗ EngineStates ${vehicleName} ${start}: ${e.message}`); }
    await sleep(150);
  }
  console.log(`  EngineStates / ${vehicleName}: ${total} new rows`);
  return total;
}

async function syncOdometer(vehicleName, vehicleId, startISO, endISO) {
  let total = 0;
  for (const { start, end } of timeWindows(startISO, endISO, 6)) {
    try {
      const url = `/fleet/vehicles/stats/history?types=obdOdometerMeters&vehicleIds=${vehicleId}`
                + `&startTime=${encodeURIComponent(start)}&endTime=${encodeURIComponent(end)}`;
      const data = await samsaraGet(url);
      const vehicle = (data.data || []).find(v => v.id === vehicleId);
      const pts = vehicle?.obdOdometerMeters || [];
      if (pts.length === 0) { await sleep(100); continue; }
      const rows = pts.map(p => [
        esc(vehicleId), esc(p.time),
        p.value, 'NOW()',
      ]);
      total += await batchUpsert(
        'samsara.odometer_readings',
        ['vehicle_id','time','value_meters','synced_at'],
        rows, '(vehicle_id, time)',
      );
    } catch (e) { console.error(`    ✗ Odometer ${vehicleName} ${start}: ${e.message}`); }
    await sleep(150);
  }
  console.log(`  Odometer / ${vehicleName}: ${total} new rows`);
  return total;
}

async function syncFuel(vehicleName, vehicleId, startISO, endISO) {
  let total = 0;
  for (const { start, end } of timeWindows(startISO, endISO, 6)) {
    try {
      const url = `/fleet/vehicles/stats/history?types=fuelPercents&vehicleIds=${vehicleId}`
                + `&startTime=${encodeURIComponent(start)}&endTime=${encodeURIComponent(end)}`;
      const data = await samsaraGet(url);
      const vehicle = (data.data || []).find(v => v.id === vehicleId);
      const pts = vehicle?.fuelPercents || [];
      if (pts.length === 0) { await sleep(100); continue; }
      const rows = pts.map(p => [esc(vehicleId), esc(p.time), p.value, 'NOW()']);
      total += await batchUpsert(
        'samsara.fuel_readings',
        ['vehicle_id','time','fuel_pct','synced_at'],
        rows, '(vehicle_id, time)',
      );
    } catch (e) { console.error(`    ✗ Fuel ${vehicleName} ${start}: ${e.message}`); }
    await sleep(150);
  }
  console.log(`  Fuel / ${vehicleName}: ${total} new rows`);
  return total;
}

async function syncEngineSeconds(vehicleName, vehicleId, startISO, endISO) {
  let total = 0;
  for (const { start, end } of timeWindows(startISO, endISO, 6)) {
    try {
      const url = `/fleet/vehicles/stats/history?types=obdEngineSeconds&vehicleIds=${vehicleId}`
                + `&startTime=${encodeURIComponent(start)}&endTime=${encodeURIComponent(end)}`;
      const data = await samsaraGet(url);
      const vehicle = (data.data || []).find(v => v.id === vehicleId);
      const pts = vehicle?.obdEngineSeconds || [];
      if (pts.length === 0) { await sleep(100); continue; }
      const rows = pts.map(p => [
        esc(vehicleId), esc(p.time),
        p.value, 'NOW()',
      ]);
      total += await batchUpsert(
        'samsara.engine_seconds',
        ['vehicle_id','time','seconds_total','synced_at'],
        rows, '(vehicle_id, time)',
      );
    } catch (e) { console.error(`    ✗ EngineSeconds ${vehicleName} ${start}: ${e.message}`); }
    await sleep(150);
  }
  console.log(`  EngineSeconds / ${vehicleName}: ${total} new rows`);
  return total;
}

// ─── Main ──────────────────────────────────────────────────────────────────

async function main() {
  const syncStart = Date.now();
  const NOW = new Date().toISOString();
  const DEFAULT_LOOKBACK_HOURS = 26; // covers overnight ops + 2h buffer

  console.log('═══════════════════════════════════════════════════════');
  console.log(`Samsara nightly sync started  |  ${NOW}`);
  if (DRY_RUN) console.log('DRY RUN — no writes');
  console.log('═══════════════════════════════════════════════════════');

  let totalRows = 0;

  // ── Ensure next month's GPS partition exists ────────────────────────────
  const nextMonth = new Date(Date.now() + 30 * 86_400_000);
  const y = nextMonth.getUTCFullYear();
  const m = String(nextMonth.getUTCMonth() + 1).padStart(2, '0');
  const mNext = nextMonth.getUTCMonth() + 2 > 12
    ? `${y + 1}-01` : `${y}-${String(nextMonth.getUTCMonth() + 2).padStart(2, '0')}`;
  try {
    await runSQL(
      `CREATE TABLE IF NOT EXISTS samsara.gps_history_${y}_${m} `
      + `PARTITION OF samsara.gps_history FOR VALUES FROM ('${y}-${m}-01') TO ('${mNext}-01')`
    );
    console.log(`[Partition] samsara.gps_history_${y}_${m} ensured`);
  } catch (e) { /* already exists */ }

  // ── Static entities (full sync, fast) ───────────────────────────────────
  console.log('\n[Static entities]');
  try { totalRows += await syncVehicles(); } catch (e) { console.error('  ✗ vehicles:', e.message); }
  try { totalRows += await syncDrivers();  } catch (e) { console.error('  ✗ drivers:',  e.message); }
  try { totalRows += await syncAddresses(); } catch (e) { console.error('  ✗ addresses:', e.message); }

  // ── Real-time snapshot ───────────────────────────────────────────────────
  console.log('\n[Real-time location snapshot]');
  try { totalRows += await syncLocationLatest(); } catch (e) { console.error('  ✗ locations_latest:', e.message); }

  // ── Time-series: determine window per vehicle per type ───────────────────
  console.log('\n[Time-series sync]');

  for (const [vehicleName, vehicleId] of Object.entries(VEHICLES)) {
    console.log(`\n  ── ${vehicleName} (${vehicleId}) ──`);

    // GPS
    const gpsCursorRaw = await getCursor('gps', vehicleId);
    const gpsStart = gpsCursorRaw
      ? new Date(gpsCursorRaw).toISOString()
      : new Date(Date.now() - DEFAULT_LOOKBACK_HOURS * 3_600_000).toISOString();
    totalRows += await syncGPS(vehicleName, vehicleId, gpsStart, NOW);
    await setCursor('gps', vehicleId, NOW);

    // Engine states
    const esCursorRaw = await getCursor('engine_states', vehicleId);
    const esStart = esCursorRaw
      ? new Date(esCursorRaw).toISOString()
      : new Date(Date.now() - DEFAULT_LOOKBACK_HOURS * 3_600_000).toISOString();
    totalRows += await syncEngineStates(vehicleName, vehicleId, esStart, NOW);
    await setCursor('engine_states', vehicleId, NOW);

    // Odometer
    const odoCursorRaw = await getCursor('odometer', vehicleId);
    const odoStart = odoCursorRaw
      ? new Date(odoCursorRaw).toISOString()
      : new Date(Date.now() - DEFAULT_LOOKBACK_HOURS * 3_600_000).toISOString();
    totalRows += await syncOdometer(vehicleName, vehicleId, odoStart, NOW);
    await setCursor('odometer', vehicleId, NOW);

    // Fuel
    const fuelCursorRaw = await getCursor('fuel', vehicleId);
    const fuelStart = fuelCursorRaw
      ? new Date(fuelCursorRaw).toISOString()
      : new Date(Date.now() - DEFAULT_LOOKBACK_HOURS * 3_600_000).toISOString();
    totalRows += await syncFuel(vehicleName, vehicleId, fuelStart, NOW);
    await setCursor('fuel', vehicleId, NOW);

    // Engine seconds
    const ecCursorRaw = await getCursor('engine_seconds', vehicleId);
    const ecStart = ecCursorRaw
      ? new Date(ecCursorRaw).toISOString()
      : new Date(Date.now() - DEFAULT_LOOKBACK_HOURS * 3_600_000).toISOString();
    totalRows += await syncEngineSeconds(vehicleName, vehicleId, ecStart, NOW);
    await setCursor('engine_seconds', vehicleId, NOW);

    await sleep(200);
  }

  const elapsed = ((Date.now() - syncStart) / 1000).toFixed(1);
  console.log('\n═══════════════════════════════════════════════════════');
  console.log(`Sync complete  |  ${totalRows.toLocaleString()} total rows  |  ${elapsed}s`);
  console.log('═══════════════════════════════════════════════════════');
}

main().catch(err => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
