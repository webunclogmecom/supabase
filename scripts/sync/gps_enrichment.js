// ============================================================================
// gps_enrichment.js — Phase 6.2 — GPS crossmatch for visits.vehicle_id
// ============================================================================
// Pulls Samsara /fleet/trips for the last N days and matches trips to visits
// via (client.samsara_address_id → vehicle_id) + time window overlap.
//
// Updates matched visits with:
//   vehicle_id            ← from trip.vehicle.id → vehicles.samsara_vehicle_id
//   actual_arrival_at     ← trip.startTime
//   actual_departure_at   ← trip.endTime
//   gps_confirmed         ← TRUE
//
// Non-matching visits are left NULL. Goliath visits can never match (no GPS).
//
// Modes:
//   --dry-run    (default) pulls trips, computes matches, prints report, no writes
//   --execute    applies the UPDATEs
//   --days=N     override default lookback window (default 90)
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const { newQuery } = require('../populate/lib/db');

const args = process.argv.slice(2);
const DRY_RUN = !args.includes('--execute');
const DAYS = parseInt((args.find(a => a.startsWith('--days=')) || '').split('=')[1] || '90');
const TOL_H = parseInt((args.find(a => a.startsWith('--tolerance-h=')) || '').split('=')[1] || '4');
const TIME_TOLERANCE_MS = TOL_H * 60 * 60 * 1000;

const SAM_TOKEN = process.env.SAMSARA_API_TOKEN;
if (!SAM_TOKEN) throw new Error('SAMSARA_API_TOKEN missing');

console.log('='.repeat(70));
console.log('gps_enrichment.js');
console.log(`Mode:     ${DRY_RUN ? 'DRY-RUN (no writes)' : 'EXECUTE'}`);
console.log(`Lookback: ${DAYS} days`);
console.log(`Tolerance: ±${TIME_TOLERANCE_MS / 3600000}h`);
console.log('='.repeat(70));

// ----------------------------------------------------------------------------
function samsaraGet(path) {
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: 'api.samsara.com',
      path,
      method: 'GET',
      headers: { Authorization: `Bearer ${SAM_TOKEN}`, Accept: 'application/json' },
    }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        if (res.statusCode >= 300) return reject(new Error(`Samsara HTTP ${res.statusCode}: ${data.slice(0, 400)}`));
        try { resolve(JSON.parse(data)); } catch (e) { reject(new Error('Bad JSON: ' + data.slice(0, 200))); }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

// Samsara's /fleet/trips endpoint is deprecated. We reconstruct trips from
// /fleet/vehicles/stats/history?types=gps — each GPS sample carries an
// address.id when the vehicle is inside a client geofence. We group
// consecutive samples at the same address per vehicle into synthetic "trips".
const MIN_DWELL_MIN = parseInt((args.find(a => a.startsWith('--min-dwell-min=')) || '').split('=')[1] || '2');
const MIN_DWELL_MS = MIN_DWELL_MIN * 60 * 1000;
const GAP_MS       = 15 * 60 * 1000;  // >15min outside geofence closes the visit
const CHUNK_DAYS   = 7;

async function fetchGpsHistory(startTimeIso, endTimeIso, vehicleIds) {
  const all = [];
  const vehFilter = `&vehicleIds=${vehicleIds.join(',')}`;
  let after = null, pages = 0;
  do {
    const p = `/fleet/vehicles/stats/history?types=gps&startTime=${encodeURIComponent(startTimeIso)}&endTime=${encodeURIComponent(endTimeIso)}${vehFilter}${after ? `&after=${encodeURIComponent(after)}` : ''}`;
    const r = await samsaraGet(p);
    all.push(...(r.data || []));
    after = r.pagination?.hasNextPage ? r.pagination.endCursor : null;
    pages++;
    if (pages > 500) { console.warn('  [warn] gps pagination cap hit'); break; }
  } while (after);
  return { rows: all, pages };
}

async function fetchAllTrips(startTimeIso, endTimeIso, vehicleIds) {
  // Chunk the window to keep responses tractable
  const start = new Date(startTimeIso).getTime();
  const end   = new Date(endTimeIso).getTime();
  // samples[vehicleId] = [{t, addr}]
  const samples = new Map();
  let totalPages = 0;
  for (let ws = start; ws < end; ws += CHUNK_DAYS * 86400000) {
    const we = Math.min(ws + CHUNK_DAYS * 86400000, end);
    const { rows, pages } = await fetchGpsHistory(new Date(ws).toISOString(), new Date(we).toISOString(), vehicleIds);
    totalPages += pages;
    for (const veh of rows) {
      const vid = String(veh.id);
      if (!samples.has(vid)) samples.set(vid, []);
      const arr = samples.get(vid);
      for (const g of (veh.gps || [])) {
        const addrId = g.address?.id ? String(g.address.id) : null;
        if (!addrId) continue; // only care about in-geofence samples
        arr.push({ t: new Date(g.time).getTime(), addr: addrId });
      }
    }
  }
  // Build synthetic trips: contiguous run of samples at same addr per vehicle
  const trips = [];
  for (const [vid, arr] of samples.entries()) {
    arr.sort((a, b) => a.t - b.t);
    let run = null;
    const flush = () => {
      if (!run) return;
      const dur = run.endT - run.startT;
      if (dur >= MIN_DWELL_MS) {
        trips.push({
          id: `${vid}:${run.addr}:${run.startT}`,
          vehicle: { id: vid },
          startTime: new Date(run.startT).toISOString(),
          endTime:   new Date(run.endT).toISOString(),
          startLocation: { addressIds: [run.addr] },
          endLocation:   { addressIds: [run.addr] },
        });
      }
      run = null;
    };
    for (const s of arr) {
      if (!run) { run = { addr: s.addr, startT: s.t, endT: s.t }; continue; }
      if (s.addr === run.addr && (s.t - run.endT) <= GAP_MS) {
        run.endT = s.t;
      } else {
        flush();
        run = { addr: s.addr, startT: s.t, endT: s.t };
      }
    }
    flush();
  }
  console.log(`  fetched gps across ${totalPages} page(s) → ${trips.length} synthetic trips (dwell ≥${MIN_DWELL_MS/60000}min)`);
  return trips;
}

// ----------------------------------------------------------------------------
function sqlEscape(v) {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'number') return String(v);
  if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE';
  return "'" + String(v).replace(/'/g, "''") + "'";
}

// ----------------------------------------------------------------------------
(async () => {
  const endTime = new Date();
  const startTime = new Date(Date.now() - DAYS * 24 * 3600 * 1000);

  // 1. Load trackable vehicles (samsara_vehicle_id present)
  const vehicles = await newQuery(`
    SELECT id, name, samsara_vehicle_id
    FROM public.vehicles
    WHERE samsara_vehicle_id IS NOT NULL AND samsara_vehicle_id <> ''
    ORDER BY id;
  `);
  console.log(`\n[1] Tracked vehicles: ${vehicles.length}`);
  vehicles.forEach(v => console.log(`    ${v.name.padEnd(10)} ${v.samsara_vehicle_id}`));
  const samsaraIdToVehicleId = new Map(vehicles.map(v => [String(v.samsara_vehicle_id), v.id]));

  // 2. Load candidate visits (have start_at + client geofence, within window)
  const visits = await newQuery(`
    SELECT v.id, v.start_at, v.end_at, v.visit_date, v.client_id,
           c.samsara_address_id, c.name AS client_name
    FROM public.visits v
    JOIN public.clients c ON c.id = v.client_id
    WHERE c.samsara_address_id IS NOT NULL
      AND v.start_at IS NOT NULL
      AND v.visit_date >= '${startTime.toISOString().slice(0, 10)}'
      AND v.visit_date <= '${endTime.toISOString().slice(0, 10)}'
    ORDER BY v.start_at;
  `);
  console.log(`\n[2] Candidate visits in window: ${visits.length}`);
  const addrToVisits = new Map();
  for (const v of visits) {
    const key = String(v.samsara_address_id);
    if (!addrToVisits.has(key)) addrToVisits.set(key, []);
    addrToVisits.get(key).push(v);
  }

  // 3. Pull trips from Samsara
  console.log(`\n[3] Fetching Samsara trips ${startTime.toISOString()} → ${endTime.toISOString()}`);
  const vehicleIds = vehicles.map(v => v.samsara_vehicle_id);
  let trips = [];
  try {
    trips = await fetchAllTrips(startTime.toISOString(), endTime.toISOString(), vehicleIds);
  } catch (e) {
    console.error(`  Samsara trips fetch FAILED: ${e.message}`);
    // Non-fatal in dry-run; fatal in execute
    if (!DRY_RUN) process.exit(1);
  }

  // Samsara trip shape (observed):
  //   { id, vehicle:{id,name}, startTime, endTime, startLocation, endLocation, ... }
  // Address match uses startLocation.addressIds[] and endLocation.addressIds[]
  function tripAddrIds(trip) {
    const ids = new Set();
    (trip.startLocation?.addressIds || []).forEach(i => ids.add(String(i)));
    (trip.endLocation?.addressIds || []).forEach(i => ids.add(String(i)));
    return [...ids];
  }

  // 4. Match each visit to trips
  const matches = []; // {visit_id, vehicle_id, actual_arrival_at, actual_departure_at, trip_id, ambiguous?}
  let stats = { matched: 0, ambiguous: 0, no_trip: 0, no_vehicle: 0, total: visits.length };

  for (const v of visits) {
    const addr = String(v.samsara_address_id);
    const vStart = new Date(v.start_at).getTime();
    const vEnd = v.end_at ? new Date(v.end_at).getTime() : vStart + 60 * 60 * 1000; // fallback 1h

    // Candidate trips: same geofence + time overlap with tolerance
    const cands = trips.filter(t => {
      const addrs = tripAddrIds(t);
      if (!addrs.includes(addr)) return false;
      const tStart = new Date(t.startTime).getTime();
      const tEnd = new Date(t.endTime).getTime();
      // overlap with tolerance
      return (tStart - TIME_TOLERANCE_MS) <= vEnd && (tEnd + TIME_TOLERANCE_MS) >= vStart;
    });

    if (cands.length === 0) { stats.no_trip++; continue; }

    // Pick best: longest dwell at this geofence (approximated by trip duration at endAddress)
    // Tiebreak: closest time match to visit.start_at
    cands.sort((a, b) => {
      const durA = new Date(a.endTime).getTime() - new Date(a.startTime).getTime();
      const durB = new Date(b.endTime).getTime() - new Date(b.startTime).getTime();
      if (durB !== durA) return durB - durA;
      const distA = Math.abs(new Date(a.startTime).getTime() - vStart);
      const distB = Math.abs(new Date(b.startTime).getTime() - vStart);
      return distA - distB;
    });
    const chosen = cands[0];

    const vehId = samsaraIdToVehicleId.get(String(chosen.vehicle?.id));
    if (!vehId) { stats.no_vehicle++; continue; }

    matches.push({
      visit_id: v.id,
      vehicle_id: vehId,
      actual_arrival_at: chosen.startTime,
      actual_departure_at: chosen.endTime,
      trip_id: chosen.id,
      ambiguous: cands.length > 1,
    });
    stats.matched++;
    if (cands.length > 1) stats.ambiguous++;
  }

  // 5. Report
  console.log('\n[4] Match report');
  console.table(stats);

  // Per-vehicle breakdown
  const perVeh = {};
  for (const m of matches) {
    const name = vehicles.find(v => v.id === m.vehicle_id)?.name || '?';
    perVeh[name] = (perVeh[name] || 0) + 1;
  }
  console.log('\nMatches per vehicle:');
  console.table(perVeh);

  if (DRY_RUN) {
    console.log('\nDRY-RUN: sample first 5 matches:');
    console.table(matches.slice(0, 5));
    console.log('\nRe-run with --execute to apply.');
    return;
  }

  // 6. Execute updates — batched VALUES clause
  console.log('\n[5] Applying updates...');
  const BATCH = 100;
  let applied = 0;
  for (let i = 0; i < matches.length; i += BATCH) {
    const slice = matches.slice(i, i + BATCH);
    const values = slice.map(m =>
      `(${m.visit_id}::bigint, ${m.vehicle_id}::bigint, ${sqlEscape(m.actual_arrival_at)}::timestamptz, ${sqlEscape(m.actual_departure_at)}::timestamptz)`
    ).join(',\n  ');
    const sql = `
      UPDATE public.visits v SET
        vehicle_id = t.vid,
        actual_arrival_at = t.arr,
        actual_departure_at = t.dep,
        gps_confirmed = TRUE
      FROM (VALUES
        ${values}
      ) AS t(visit_id, vid, arr, dep)
      WHERE v.id = t.visit_id;
    `;
    await newQuery(sql);
    applied += slice.length;
    process.stdout.write(`\r  applied ${applied}/${matches.length}`);
  }
  console.log('\n  done.');

  // 7. Post-run verification
  const post = await newQuery(`
    SELECT
      COUNT(*) FILTER (WHERE vehicle_id IS NOT NULL)::int AS with_vehicle,
      COUNT(*) FILTER (WHERE gps_confirmed)::int AS gps_confirmed,
      COUNT(*)::int AS total
    FROM public.visits;
  `);
  console.log('\nVisits post-update:');
  console.table(post);
})();
