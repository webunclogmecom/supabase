// ============================================================================
// cron_samsara_telemetry.js — periodic Samsara → Supabase telemetry sync
// ============================================================================
// Runs every 10 minutes via GitHub Actions. Pulls latest stats per vehicle
// (engineStates, fuelPercents, obdOdometerMeters, gps) and inserts one row per
// vehicle per cycle into vehicle_telemetry_readings.
//
// Why polling not webhook: Samsara's webhook offering covers driver/address/
// alert events, NOT vehicle stats. Stats are polling-only via /fleet/vehicles/
// stats. Per ADR 011 + 2026-04-30 design discussion, we collect telemetry now
// (vs. defer until fuel-burn model is built) so historical data accumulates
// for eventual modeling.
//
// Token handling: SAMSARA_API_TOKEN is a static long-lived API token. Read
// from env (GitHub Actions secret). No refresh flow.
//
// Idempotency: INSERT ... ON CONFLICT (vehicle_id, recorded_at) DO NOTHING.
// Repeated cron fires that fetch the same Samsara sample produce no dup rows.
//
// Required process.env (set as GitHub Actions secrets):
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY
//   SAMSARA_API_TOKEN
//
// CLI:
//   node scripts/sync/cron_samsara_telemetry.js
// ============================================================================

const https = require('https');
// Load .env when available (local dev). GitHub Actions injects secrets as env
// directly so this is a no-op there.
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') }); } catch (_) {}

const SUPABASE_URL    = process.env.SUPABASE_URL;
const SERVICE_KEY     = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SAMSARA_TOKEN   = process.env.SAMSARA_API_TOKEN;

if (!SUPABASE_URL || !SERVICE_KEY) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');
if (!SAMSARA_TOKEN) throw new Error('SAMSARA_API_TOKEN is required');

// ---- HTTPS helpers ----------------------------------------------------------

function request({ host, path, method = 'GET', headers = {}, body = null }) {
  return new Promise((resolve, reject) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({
      hostname: host, path, method,
      headers: { ...headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) },
    }, (res) => {
      let d = ''; res.on('data', (c) => (d += c));
      res.on('end', () => resolve({ status: res.statusCode, body: d }));
    });
    req.on('error', reject);
    req.setTimeout(30_000, () => req.destroy(new Error('Samsara request timeout')));
    if (payload) req.write(payload);
    req.end();
  });
}

async function samsara(path) {
  const r = await request({
    host: 'api.samsara.com',
    path,
    headers: { Authorization: `Bearer ${SAMSARA_TOKEN}` },
  });
  if (r.status < 200 || r.status >= 300) {
    throw new Error(`Samsara ${path} → HTTP ${r.status}: ${r.body.slice(0, 300)}`);
  }
  return JSON.parse(r.body);
}

async function rest(path, opts = {}) {
  const u = new URL(SUPABASE_URL + '/rest/v1' + path);
  return request({
    host: u.hostname,
    path: u.pathname + u.search,
    method: opts.method || 'GET',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
      Prefer: opts.prefer || 'return=minimal',
      ...(opts.headers || {}),
    },
    body: opts.body,
  });
}

// ---- Resolve Samsara vehicle ID → our vehicle.id via entity_source_links ----

async function loadVehicleIdMap() {
  const r = await rest('/entity_source_links?entity_type=eq.vehicle&source_system=eq.samsara&select=entity_id,source_id');
  if (r.status !== 200) throw new Error(`vehicle ID map fetch failed: HTTP ${r.status} ${r.body.slice(0,200)}`);
  const links = JSON.parse(r.body);
  const map = new Map();
  for (const l of links) map.set(String(l.source_id), l.entity_id);
  return map;
}

// ---- Pull current stats from Samsara ----------------------------------------

async function pullSamsaraStats() {
  const types = 'engineStates,fuelPercents,obdOdometerMeters,gps';
  const all = [];
  let after = null, pages = 0;
  do {
    const sep = '?';
    const cursor = after ? `&after=${encodeURIComponent(after)}` : '';
    const path = `/fleet/vehicles/stats${sep}types=${types}&limit=100${cursor}`;
    const r = await samsara(path);
    all.push(...(r.data || []));
    after = r.pagination?.hasNextPage ? r.pagination.endCursor : null;
    pages++;
    if (pages > 20) break;
  } while (after);
  return all;
}

// ---- Build telemetry rows from Samsara response ------------------------------

function buildRows(stats, vehicleIdMap) {
  const rows = [];
  for (const v of stats) {
    const our_id = vehicleIdMap.get(String(v.id));
    if (!our_id) {
      console.log(`  skip Samsara vehicle ${v.id} ("${v.name}") — no matching row in vehicles table`);
      continue;
    }
    // Each stat type has its own .time and .value. Use gps.time as the
    // canonical recorded_at (most precise sample; engine/fuel are coarser).
    // Fall back to fuel time, then engine time, then now() as a last resort.
    const recorded_at = v.gps?.time
      ?? v.fuelPercent?.time
      ?? v.engineState?.time
      ?? v.obdOdometerMeters?.time
      ?? new Date().toISOString();

    rows.push({
      vehicle_id:           our_id,
      fuel_percent:         v.fuelPercent?.value ?? null,
      odometer_meters:      v.obdOdometerMeters?.value ?? null,
      engine_state:         v.engineState?.value ?? null,
      engine_hours_seconds: v.engineHoursMillis?.value != null
                              ? Math.round(v.engineHoursMillis.value / 1000)
                              : null,
      latitude:             v.gps?.latitude ?? null,
      longitude:            v.gps?.longitude ?? null,
      speed_meters_per_sec: v.gps?.speedMetersPerSecond ?? null,
      heading_degrees:      v.gps?.headingDegrees ?? null,
      recorded_at,
    });
  }
  return rows;
}

// ---- Upsert into vehicle_telemetry_readings ---------------------------------

async function insertRows(rows) {
  if (!rows.length) return { inserted: 0 };
  // PostgREST upsert: on_conflict names the unique constraint columns;
  // Prefer: resolution=ignore-duplicates makes conflicts a no-op (HTTP 201).
  const r = await rest('/vehicle_telemetry_readings?on_conflict=vehicle_id,recorded_at', {
    method: 'POST',
    body: rows,
    prefer: 'resolution=ignore-duplicates,return=minimal',
  });
  if (r.status >= 200 && r.status < 300) return { inserted: rows.length };
  throw new Error(`Insert failed: HTTP ${r.status}: ${r.body.slice(0, 300)}`);
}

// ---- Main -------------------------------------------------------------------

(async () => {
  const t0 = Date.now();
  console.log(`[samsara-telemetry] start ${new Date().toISOString()}`);

  const idMap = await loadVehicleIdMap();
  console.log(`  loaded ${idMap.size} vehicle ID mappings (samsara → ours)`);
  if (idMap.size === 0) {
    console.log('  ⚠️ no Samsara-sourced vehicles in entity_source_links — exit (run populate.js step 3 first)');
    process.exit(0);
  }

  const stats = await pullSamsaraStats();
  console.log(`  pulled ${stats.length} vehicle stat records from Samsara`);

  const rows = buildRows(stats, idMap);
  const result = await insertRows(rows);
  console.log(`  inserted ${result.inserted} telemetry rows (dups skipped via ON CONFLICT)`);

  // Log sample for visibility
  for (const r of rows.slice(0, 3)) {
    console.log(`    vehicle_id=${r.vehicle_id}  fuel=${r.fuel_percent}%  engine=${r.engine_state}  gps=(${r.latitude},${r.longitude})  recorded_at=${r.recorded_at}`);
  }

  console.log(`[samsara-telemetry] done in ${Date.now() - t0}ms`);
  process.exit(0);
})().catch((e) => {
  console.error(`[samsara-telemetry] FAIL: ${e.message}`);
  process.exit(1);
});
