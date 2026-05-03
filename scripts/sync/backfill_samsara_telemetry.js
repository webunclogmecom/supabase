// ============================================================================
// backfill_samsara_telemetry.js — pull historical Samsara stats
// ============================================================================
// One-shot complement to cron_samsara_telemetry.js (which only captures live
// snapshots every 10 min going forward). Hits Samsara's /fleet/vehicles/stats/
// history endpoint and writes any missing rows back into Supabase.
//
// Idempotent: INSERT ... ON CONFLICT (vehicle_id, recorded_at) DO NOTHING in
// the same shape as the live cron.
//
// Default window: last 30 days (Samsara's standard retention for stats history).
// Override with --start=YYYY-MM-DD --end=YYYY-MM-DD.
//
// Required env (or GitHub Actions secrets):
//   SAMSARA_API_TOKEN
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY
//
// CLI:
//   node scripts/sync/backfill_samsara_telemetry.js
//   node scripts/sync/backfill_samsara_telemetry.js --start=2026-04-01
//   node scripts/sync/backfill_samsara_telemetry.js --start=2026-04-01 --end=2026-04-15
//   node scripts/sync/backfill_samsara_telemetry.js --dry-run
// ============================================================================

const https = require('https');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') }); } catch (_) {}

const SAMSARA_TOKEN = process.env.SAMSARA_API_TOKEN;
const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SAMSARA_TOKEN) throw new Error('SAMSARA_API_TOKEN required');
if (!SUPABASE_URL || !SVC) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY required');

const DRY_RUN = process.argv.includes('--dry-run');
const startArg = process.argv.find(a => a.startsWith('--start='));
const endArg = process.argv.find(a => a.startsWith('--end='));

const END_TIME = endArg ? new Date(endArg.split('=')[1] + 'T23:59:59Z') : new Date();
const START_TIME = startArg
  ? new Date(startArg.split('=')[1] + 'T00:00:00Z')
  : new Date(END_TIME.getTime() - 30 * 24 * 60 * 60 * 1000);

const TYPES = 'gps,engineStates,fuelPercents,obdOdometerMeters';
const PAGE_LIMIT = 100;

// ---- helpers ----------------------------------------------------------------

function http(opts, body) {
  return new Promise((res, rej) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({
      ...opts,
      headers: { ...opts.headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) },
    }, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej);
    req.setTimeout(60000, () => req.destroy(new Error('Samsara timeout')));
    if (payload) req.write(payload);
    req.end();
  });
}

async function samsara(path) {
  const r = await http({
    hostname: 'api.samsara.com',
    path,
    method: 'GET',
    headers: { Authorization: `Bearer ${SAMSARA_TOKEN}` },
  });
  if (r.status === 429) {
    // Samsara rate limit — back off and retry once
    await new Promise(rs => setTimeout(rs, 5000));
    return samsara(path);
  }
  if (r.status >= 300) throw new Error(`Samsara ${path} → ${r.status}: ${r.body.slice(0, 300)}`);
  return JSON.parse(r.body);
}

async function rest(path, opts = {}) {
  const u = new URL(SUPABASE_URL + '/rest/v1' + path);
  return http({
    hostname: u.hostname,
    path: u.pathname + u.search,
    method: opts.method || 'GET',
    headers: {
      apikey: SVC,
      Authorization: `Bearer ${SVC}`,
      'Content-Type': 'application/json',
      Prefer: opts.prefer || 'return=minimal',
      ...(opts.headers || {}),
    },
  }, opts.body);
}

async function loadVehicleIdMap() {
  const r = await rest('/entity_source_links?entity_type=eq.vehicle&source_system=eq.samsara&select=entity_id,source_id');
  if (r.status !== 200) throw new Error(`vehicle ID map fetch failed: ${r.status} ${r.body.slice(0, 200)}`);
  const links = JSON.parse(r.body);
  const map = new Map();
  for (const l of links) map.set(String(l.source_id), l.entity_id);
  return map;
}

// ---- pull stats history ------------------------------------------------------

async function pullStatsHistory() {
  const startISO = START_TIME.toISOString();
  const endISO = END_TIME.toISOString();
  const all = [];
  let after = null, pages = 0;
  do {
    const cursor = after ? `&after=${encodeURIComponent(after)}` : '';
    const path = `/fleet/vehicles/stats/history?types=${TYPES}&startTime=${encodeURIComponent(startISO)}&endTime=${encodeURIComponent(endISO)}&limit=${PAGE_LIMIT}${cursor}`;
    const r = await samsara(path);
    all.push(...(r.data || []));
    after = r.pagination?.hasNextPage ? r.pagination.endCursor : null;
    pages++;
    if (pages % 10 === 0) process.stdout.write(`  ...page ${pages}, accumulated vehicles: ${all.length}\n`);
    if (pages > 1000) {
      console.warn('hit safety cap of 1000 pages');
      break;
    }
  } while (after);
  console.log(`  pulled ${all.length} vehicle history snapshots across ${pages} pages`);
  return all;
}

// ---- flatten history into rows -----------------------------------------------
// stats/history returns per-vehicle ARRAYS of values for each type. Each
// type's array entries have their own .time. Build one telemetry row per
// distinct GPS sample (since gps is the densest signal), and pull the most
// recent fuel/engine/odometer value at-or-before that GPS timestamp.

function buildRows(stats, vehicleIdMap) {
  const rows = [];
  for (const v of stats) {
    const our_id = vehicleIdMap.get(String(v.id));
    if (!our_id) continue;

    const gpsArr = v.gps || [];
    const fuelArr = v.fuelPercents || [];
    const engArr = v.engineStates || [];
    const odoArr = v.obdOdometerMeters || [];

    // Sort each by time ascending so the at-or-before lookup is monotone
    const byTime = a => [...a].sort((x, y) => new Date(x.time) - new Date(y.time));
    const gps = byTime(gpsArr);
    const fuel = byTime(fuelArr);
    const eng = byTime(engArr);
    const odo = byTime(odoArr);

    function latestAtOrBefore(arr, t) {
      let lo = 0, hi = arr.length - 1, best = null;
      const target = new Date(t).getTime();
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        const midT = new Date(arr[mid].time).getTime();
        if (midT <= target) { best = arr[mid]; lo = mid + 1; }
        else { hi = mid - 1; }
      }
      return best;
    }

    for (const g of gps) {
      const f = latestAtOrBefore(fuel, g.time);
      const e = latestAtOrBefore(eng, g.time);
      const o = latestAtOrBefore(odo, g.time);
      rows.push({
        vehicle_id: our_id,
        fuel_percent: f?.value ?? null,
        odometer_meters: o?.value ?? null,
        engine_state: e?.value ?? null,
        engine_hours_seconds: null,
        latitude: g.latitude ?? null,
        longitude: g.longitude ?? null,
        speed_meters_per_sec: g.speedMetersPerSecond ?? null,
        heading_degrees: g.headingDegrees ?? null,
        recorded_at: g.time,
      });
    }
  }
  return rows;
}

// ---- bulk insert -------------------------------------------------------------

async function insertBatch(rows) {
  if (!rows.length) return 0;
  // PostgREST's resolution=ignore-duplicates only catches PK conflicts, not
  // arbitrary UNIQUE constraints. Our table uses UNIQUE(vehicle_id, recorded_at)
  // — so dupes throw 23505. Fall back to a row-by-row strategy on conflict.
  const r = await rest('/vehicle_telemetry_readings', {
    method: 'POST',
    headers: { Prefer: 'resolution=ignore-duplicates,return=minimal' },
    body: JSON.stringify(rows),
  });
  if (r.status === 409) {
    // Bulk failed on dupe; insert one-by-one, ignoring 23505 per row
    let okCount = 0;
    for (const row of rows) {
      const rr = await rest('/vehicle_telemetry_readings', {
        method: 'POST',
        headers: { Prefer: 'resolution=ignore-duplicates,return=minimal' },
        body: JSON.stringify(row),
      });
      if (rr.status < 300 || rr.status === 409) okCount++;
      else throw new Error(`insert failed: ${rr.status} ${rr.body.slice(0, 200)}`);
    }
    return okCount;
  }
  if (r.status >= 300) throw new Error(`insert failed: ${r.status} ${r.body.slice(0, 200)}`);
  return rows.length;
}

// ---- main --------------------------------------------------------------------

(async () => {
  console.log('='.repeat(70));
  console.log(`backfill_samsara_telemetry  Mode: ${DRY_RUN ? 'DRY-RUN' : 'EXECUTE'}`);
  console.log(`  Window: ${START_TIME.toISOString()} → ${END_TIME.toISOString()}`);
  console.log(`  Types : ${TYPES}`);
  console.log('='.repeat(70));

  console.log('\n[1/3] Loading vehicle ID map…');
  const vehMap = await loadVehicleIdMap();
  console.log(`  ${vehMap.size} Samsara → Supabase vehicle mappings`);

  console.log('\n[2/3] Pulling Samsara /fleet/vehicles/stats/history…');
  const stats = await pullStatsHistory();
  const rows = buildRows(stats, vehMap);
  console.log(`  built ${rows.length} telemetry rows from history`);

  if (rows.length === 0) {
    console.log('\nNothing to insert.');
    return;
  }

  if (DRY_RUN) {
    // Show distribution
    const byVeh = {};
    for (const r of rows) byVeh[r.vehicle_id] = (byVeh[r.vehicle_id] || 0) + 1;
    console.log('\n[3/3] DRY-RUN — would insert (idempotent on conflict):');
    for (const [vid, n] of Object.entries(byVeh)) console.log(`  vehicle_id ${vid}: ${n} rows`);
    return;
  }

  console.log('\n[3/3] Inserting in batches of 500…');
  let inserted = 0;
  for (let i = 0; i < rows.length; i += 500) {
    const batch = rows.slice(i, i + 500);
    inserted += await insertBatch(batch);
    if (inserted % 5000 === 0) console.log(`  ...${inserted}/${rows.length} sent`);
  }
  console.log(`  ✓ ${inserted} rows sent to vehicle_telemetry_readings (duplicates ignored by ON CONFLICT)`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
