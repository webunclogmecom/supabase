// ============================================================================
// derive_visit_vehicle_id.js — populate visits.vehicle_id by GPS cross-reference
// ============================================================================
// Jobber owns visits but doesn't track which truck did each one.
// Samsara owns truck GPS but doesn't know about Jobber visits.
// We bridge them ourselves.
//
// Algorithm per visit (progressive tier fallback):
//   1. Skip if vehicle_id already set, no start_at, or property has no GPS.
//   2. For each tier (tight → medium → wide), pull GPS readings in
//      [start_at - pad, COALESCE(completed_at, start_at + 1h) + pad] within
//      a bounding box, then exact-Haversine filter to the tier radius.
//   3. Tight tier alone counts as high-confidence: if exactly one truck has
//      ≥1 reading there, write it and stop. Medium/wide tiers act as a
//      fallback when tight returns nothing (covers GPS dropout / slight
//      geocode drift).
//   4. Goliath is excluded for visits dated 2026-01-01 onward — truck was
//      decommissioned 2026-02-16 and any 2026 GPS pings at a property
//      represent stale telemetry, not an attribution signal. Without this
//      exclusion the autopilot saw Goliath+Moises overlap and skipped the
//      visit as ambiguous (~24 false-NULLs/run per 2026-05-12 audit).
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

// Matching tunables — progressive tier fallback. Tight = the canonical
// match; medium/wide kick in only when tight yields nothing, to recover
// visits with GPS dropout or slight property-geocode drift.
const TIERS = [
  { name: 'tight',  radius_m: 150, pad_ms: 5 * 60 * 1000 },
  { name: 'medium', radius_m: 300, pad_ms: 15 * 60 * 1000 },
  { name: 'wide',   radius_m: 500, pad_ms: 30 * 60 * 1000 },
];
const FALLBACK_DURATION_MS = 60 * 60 * 1000;      // when completed_at is null
// Cutoff after which Goliath is no longer a valid candidate. Per ops:
// Goliath was decommissioned 2026-02-16; any post-cutoff GPS pings at a
// property are stale telemetry, not attribution signal.
const GOLIATH_DECOMMISSION_DATE = '2026-01-01';

// Cloggy is the day-shift plumbing truck (Grecia). Commercial overnight
// service (GT/CL/LS/WD) is run by Moises (Kenworth T880); Cloggy only
// touches residential/emergency calls. Cloggy GPS pings near commercial
// clients are usually pass-by noise during the day route. Without this
// exclusion the autopilot saw Moises+Cloggy overlap on 8/15 recent
// commercial visits (audit 2026-05-22) and skipped them as ambiguous.
const COMMERCIAL_SERVICE_TYPES = new Set(['GT', 'CL', 'LS', 'WD']);

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

async function pg(sql, _retry = 0) {
  if (!PAT || !PROJECT) throw new Error('SUPABASE_PAT and SUPABASE_PROJECT_ID required for queries');
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROJECT}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  // Mgmt API throttles around 60 req/min. Back off + retry on 429 / 5xx.
  if ((r.status === 429 || (r.status >= 500 && r.status < 600)) && _retry < 6) {
    const waitMs = Math.min(60_000, 2_000 * Math.pow(2, _retry));
    console.log(`  [pg] HTTP ${r.status} — backing off ${waitMs/1000}s (retry ${_retry+1}/6)`);
    await new Promise(rs => setTimeout(rs, waitMs));
    return pg(sql, _retry + 1);
  }
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
      v.service_type,
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
  const byTier = { tight: 0, medium: 0, wide: 0 };
  const updates = [];

  for (const v of candidates) {
    const startMs = new Date(v.start_at).getTime();
    const endMs = v.completed_at ? new Date(v.completed_at).getTime() : startMs + FALLBACK_DURATION_MS;
    const lat = v.lat, lng = v.lng;
    const excludeGoliath = v.visit_date >= GOLIATH_DECOMMISSION_DATE;
    // Exclude Cloggy for commercial visits (and for NULL service_type, which
    // for visits past 2026 is overwhelmingly recurring commercial work).
    const excludeCloggy = v.service_type == null || COMMERCIAL_SERVICE_TYPES.has(v.service_type);
    const exclusions = [];
    if (excludeGoliath) exclusions.push("'Goliath'");
    if (excludeCloggy) exclusions.push("'Cloggy'");
    const goliathClause = exclusions.length
      ? `AND veh.name NOT IN (${exclusions.join(',')})`
      : '';

    let resolved = null;
    let lastAmbiguous = null;

    for (const tier of TIERS) {
      const winStart = new Date(startMs - tier.pad_ms).toISOString();
      const winEnd   = new Date(endMs   + tier.pad_ms).toISOString();
      // Bounding box: convert tier.radius_m to degrees (~111km per degree lat).
      // Add 10% headroom so the exact-Haversine filter doesn't miss edge pings.
      const dLat = (tier.radius_m * 1.1) / 111000;
      const dLng = dLat / Math.cos(lat * Math.PI / 180);
      const tel = await pg(`
        SELECT vt.vehicle_id, veh.name AS truck,
          vt.recorded_at::text AS recorded_at,
          vt.latitude::float  AS tel_lat,
          vt.longitude::float AS tel_lng
        FROM vehicle_telemetry_readings vt
        JOIN vehicles veh ON veh.id = vt.vehicle_id
        WHERE vt.recorded_at >= '${winStart}'
          AND vt.recorded_at <= '${winEnd}'
          AND vt.latitude  BETWEEN ${lat - dLat} AND ${lat + dLat}
          AND vt.longitude BETWEEN ${lng - dLng} AND ${lng + dLng}
          ${goliathClause};
      `);
      const within = tel.filter(r => haversineM(lat, lng, r.tel_lat, r.tel_lng) <= tier.radius_m);
      const truckIds = [...new Set(within.map(r => r.vehicle_id))];

      if (truckIds.length === 1) {
        resolved = {
          visit_id: v.visit_id, vehicle_id: truckIds[0],
          truck: within[0].truck, tier: tier.name,
          pings: within.length,
          min_dist_m: Math.round(Math.min(...within.map(r => haversineM(lat, lng, r.tel_lat, r.tel_lng)))),
        };
        break;
      }
      if (truckIds.length > 1) {
        lastAmbiguous = { tier: tier.name, trucks: [...new Set(within.map(r => r.truck))].join(', ') };
        // Don't widen further — multiple trucks at this tier already means
        // we can't disambiguate; widening would only add noise.
        break;
      }
      // truckIds.length === 0 → fall through to next tier
    }

    if (resolved) {
      matched++;
      byTier[resolved.tier]++;
      updates.push({ visit_id: resolved.visit_id, vehicle_id: resolved.vehicle_id, truck: resolved.truck });
      const goliathNote = excludeGoliath ? '' : ' (Goliath eligible)';
      console.log(`  ✓ v${v.visit_id} ${(v.client_code || '?').padEnd(8)} ${v.visit_date} → ${resolved.truck} [${resolved.tier}, ${resolved.pings} pings, ${resolved.min_dist_m}m]${goliathNote}`);
    } else if (lastAmbiguous) {
      ambiguous++;
      console.log(`  ? v${v.visit_id} ${(v.client_code || '?').padEnd(8)} ${v.visit_date} AMBIGUOUS [${lastAmbiguous.tier}]: ${lastAmbiguous.trucks}`);
    } else {
      noMatch++;
    }
  }

  console.log(`\n[2/3] Match results:`);
  console.log(`  Matched (1 truck):          ${matched}`);
  console.log(`    by tier — tight: ${byTier.tight}  medium: ${byTier.medium}  wide: ${byTier.wide}`);
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
