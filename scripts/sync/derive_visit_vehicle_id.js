// ============================================================================
// derive_visit_vehicle_id.js — populate visits.vehicle_id by GPS cross-reference
// ============================================================================
// Jobber owns visits but doesn't track which truck did each one.
// Samsara owns truck GPS but doesn't know about Jobber visits.
// We bridge them ourselves.
//
// Algorithm per visit:
//   1. Skip if vehicle_id already set, no start_at, or property has no GPS.
//   2. Define time window: [start_at - 5min, COALESCE(completed_at, start_at + 1h) + 5min].
//   3. Pull vehicle_telemetry_readings in that window with GPS, bounding-box
//      filtered by ±0.0015° lat/lng (~165m at Miami latitude).
//   4. Compute exact Haversine distance for each reading.
//   5. Keep readings within 150m.
//   6. Group surviving readings by vehicle_id. If exactly one truck has a
//      reading → write that vehicle_id to the visit. If multiple → log
//      ambiguity and skip (rare; needs human review). If zero → leave NULL.
//
// Idempotent: only touches rows where vehicle_id IS NULL.
// Safe to re-run hourly.
//
// CLI:
//   node scripts/sync/derive_visit_vehicle_id.js               # all candidates
//   node scripts/sync/derive_visit_vehicle_id.js --dry-run     # report only
//   node scripts/sync/derive_visit_vehicle_id.js --since=YYYY-MM-DD
// ============================================================================

const https = require('https');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') }); } catch (_) {}

const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PAT = process.env.SUPABASE_PAT;
const PROJECT = process.env.SUPABASE_PROJECT_ID;

if (!SUPABASE_URL || !SVC) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY required');

const DRY_RUN = process.argv.includes('--dry-run');
const sinceArg = process.argv.find(a => a.startsWith('--since='));
const SINCE = sinceArg ? sinceArg.split('=')[1] : null;

// Matching tunables
const RADIUS_METERS = 150;          // accept telemetry within this distance
const TIME_PADDING_BEFORE_MS = 5 * 60 * 1000;     // 5 min before start_at
const TIME_PADDING_AFTER_MS = 5 * 60 * 1000;      // 5 min after completed_at
const FALLBACK_DURATION_MS = 60 * 60 * 1000;      // when completed_at is null

// ---- helpers ----------------------------------------------------------------

function http(opts, body) {
  return new Promise((res, rej) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({
      ...opts,
      headers: { ...opts.headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) },
    }, (r) => {
      const chunks = []; r.on('data', c => chunks.push(c));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(chunks).toString() }));
    });
    req.on('error', rej);
    req.setTimeout(60000, () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload);
    req.end();
  });
}

async function pg(sql) {
  if (!PAT || !PROJECT) throw new Error('SUPABASE_PAT and SUPABASE_PROJECT_ID required for queries');
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROJECT}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 300)}`);
  return JSON.parse(r.body);
}

async function rest(path, opts = {}) {
  const u = new URL(SUPABASE_URL + '/rest/v1' + path);
  const r = await http({
    hostname: u.hostname,
    path: u.pathname + u.search,
    method: opts.method || 'GET',
    headers: {
      apikey: SVC,
      Authorization: `Bearer ${SVC}`,
      'Content-Type': 'application/json',
      ...(opts.headers || {}),
    },
  }, opts.body);
  if (r.status >= 300) throw new Error(`REST ${path} → ${r.status}: ${r.body.slice(0, 300)}`);
  return r.body ? JSON.parse(r.body) : null;
}

// Haversine distance in meters
function haversineM(lat1, lng1, lat2, lng2) {
  const R = 6371000; // earth radius m
  const toRad = d => d * Math.PI / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

// ---- main -------------------------------------------------------------------

(async () => {
  console.log('='.repeat(70));
  console.log(`derive_visit_vehicle_id  Mode: ${DRY_RUN ? 'DRY-RUN' : 'EXECUTE'}` + (SINCE ? `  Since: ${SINCE}` : ''));
  console.log('='.repeat(70));

  // Pull candidate visits + their property GPS.
  // Most visits have property_id NULL but their client has a primary property
  // with GPS — we COALESCE to that. Validated 2026-05-02: this unlocks 448
  // additional candidates (vs 13 with strict v.property_id JOIN).
  const sinceFilter = SINCE ? `AND v.visit_date >= '${SINCE}'` : '';
  const candidates = await pg(`
    WITH primary_prop AS (
      SELECT DISTINCT ON (client_id) client_id, id, latitude, longitude
      FROM properties
      WHERE latitude IS NOT NULL AND longitude IS NOT NULL
      ORDER BY client_id, is_primary DESC NULLS LAST, id ASC
    )
    SELECT v.id AS visit_id,
      v.start_at::text AS start_at,
      v.completed_at::text AS completed_at,
      v.visit_date::text AS visit_date,
      COALESCE(p_direct.id, p_fallback.id) AS property_id,
      COALESCE(p_direct.latitude::float,  p_fallback.latitude::float)  AS lat,
      COALESCE(p_direct.longitude::float, p_fallback.longitude::float) AS lng,
      c.client_code,
      CASE WHEN p_direct.id IS NOT NULL THEN 'direct' ELSE 'client-fallback' END AS source
    FROM visits v
    LEFT JOIN properties   p_direct   ON p_direct.id = v.property_id
                                      AND p_direct.latitude IS NOT NULL
    LEFT JOIN primary_prop p_fallback ON p_fallback.client_id = v.client_id
    LEFT JOIN clients c ON c.id = v.client_id
    WHERE v.vehicle_id IS NULL
      AND v.start_at IS NOT NULL
      AND COALESCE(p_direct.latitude,  p_fallback.latitude)  IS NOT NULL
      AND COALESCE(p_direct.longitude, p_fallback.longitude) IS NOT NULL
      ${sinceFilter}
    ORDER BY v.start_at DESC;
  `);
  console.log(`\n[1/3] ${candidates.length} candidate visits (vehicle_id NULL, start_at + property GPS present)`);

  let matched = 0, ambiguous = 0, noMatch = 0;
  const updates = [];

  for (const v of candidates) {
    const startMs = new Date(v.start_at).getTime();
    const endMs = v.completed_at ? new Date(v.completed_at).getTime() : startMs + FALLBACK_DURATION_MS;
    const winStart = new Date(startMs - TIME_PADDING_BEFORE_MS).toISOString();
    const winEnd = new Date(endMs + TIME_PADDING_AFTER_MS).toISOString();

    // Bounding box: ±0.0015° ≈ 165m at Miami latitude
    const lat = v.lat, lng = v.lng;
    const dLat = 0.0015, dLng = 0.0015 / Math.cos(lat * Math.PI / 180);
    const minLat = lat - dLat, maxLat = lat + dLat;
    const minLng = lng - dLng, maxLng = lng + dLng;

    const tel = await pg(`
      SELECT vt.vehicle_id, veh.name AS truck,
        vt.recorded_at::text AS recorded_at,
        vt.latitude::float AS tel_lat,
        vt.longitude::float AS tel_lng
      FROM vehicle_telemetry_readings vt
      JOIN vehicles veh ON veh.id = vt.vehicle_id
      WHERE vt.recorded_at >= '${winStart}'
        AND vt.recorded_at <= '${winEnd}'
        AND vt.latitude  BETWEEN ${minLat} AND ${maxLat}
        AND vt.longitude BETWEEN ${minLng} AND ${maxLng};
    `);

    // Exact Haversine filter
    const within = tel.filter(r => haversineM(lat, lng, r.tel_lat, r.tel_lng) <= RADIUS_METERS);
    const truckIds = [...new Set(within.map(r => r.vehicle_id))];

    if (truckIds.length === 0) {
      noMatch++;
    } else if (truckIds.length === 1) {
      matched++;
      const truckName = within[0].truck;
      updates.push({ visit_id: v.visit_id, vehicle_id: truckIds[0], truck: truckName });
      console.log(`  ✓ v${v.visit_id} ${(v.client_code || '?').padEnd(8)} ${v.visit_date} → ${truckName} (${within.length} GPS pings, min ${Math.round(Math.min(...within.map(r => haversineM(lat, lng, r.tel_lat, r.tel_lng))))}m)`);
    } else {
      ambiguous++;
      const trucks = [...new Set(within.map(r => r.truck))].join(', ');
      console.log(`  ? v${v.visit_id} ${(v.client_code || '?').padEnd(8)} ${v.visit_date} AMBIGUOUS: ${trucks}`);
    }
  }

  console.log(`\n[2/3] Match results:`);
  console.log(`  Matched (1 truck):          ${matched}`);
  console.log(`  Ambiguous (multiple):       ${ambiguous}`);
  console.log(`  No telemetry in window:     ${noMatch}`);

  if (DRY_RUN) {
    console.log(`\n[3/3] DRY-RUN — no writes. Would update ${matched} visit(s).`);
    return;
  }

  console.log(`\n[3/3] Writing ${updates.length} visit.vehicle_id updates...`);
  for (const u of updates) {
    await rest(`/visits?id=eq.${u.visit_id}`, {
      method: 'PATCH',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({ vehicle_id: u.vehicle_id }),
    });
  }
  console.log(`  ✓ ${updates.length} visits updated`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
