// Phase 1 — Backfill visits.vehicle_id where it's NULL, using Samsara
// telemetry to identify which truck was at the property during the
// visit window.
//
// Empirical thresholds (from retro_truck_attribution_thresholds.js, 2026-05-14):
//   - min_dist_m       ≤ 150    (96% coverage of known-good visits)
//   - pings_within_150m ≥ 2     (excludes random single-ping flybys)
//   - window           [start_at - 30min, completed_at + 30min]
//   - tie-break        lowest min_dist_m (parked closest)
//   - fallback GPS     client's primary property if visit has no property GPS
//
// Idempotent: only updates visits where vehicle_id IS NULL.
//
// Usage:
//   node scripts/probes/backfill_null_trucks.js              # dry-run
//   node scripts/probes/backfill_null_trucks.js --execute    # writes
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const EXECUTE = process.argv.includes('--execute');
const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT  = process.env.SUPABASE_PAT;

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) {
  const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROD+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query:sql}));
  if (r.status >= 300) throw new Error('PG '+r.status+': '+r.body.slice(0,400));
  return r.body ? JSON.parse(r.body) : [];
}
function haversineM(lat1, lng1, lat2, lng2) {
  const R = 6371000, toRad = d => d * Math.PI / 180;
  const dLat = toRad(lat2 - lat1), dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat/2)**2 + Math.cos(toRad(lat1))*Math.cos(toRad(lat2))*Math.sin(dLng/2)**2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

(async () => {
  console.log('Mode: ' + (EXECUTE ? 'EXECUTE' : 'DRY-RUN') + '\n');

  const visits = await pg(`
    SELECT v.id AS visit_id, v.visit_date::text, v.start_at::text, v.completed_at::text,
      v.client_id, c.client_code,
      COALESCE(p.latitude,  pp.latitude)::float  AS lat,
      COALESCE(p.longitude, pp.longitude)::float AS lng,
      CASE WHEN p.latitude IS NOT NULL THEN 'visit-property'
           WHEN pp.latitude IS NOT NULL THEN 'client-primary-fallback' END AS gps_source
    FROM visits v
    LEFT JOIN clients c ON c.id = v.client_id
    LEFT JOIN properties p ON p.id = v.property_id AND p.latitude IS NOT NULL
    LEFT JOIN properties pp ON pp.client_id = v.client_id AND pp.is_primary = TRUE AND pp.latitude IS NOT NULL
    WHERE v.visit_status = 'completed'
      AND v.vehicle_id IS NULL
    ORDER BY v.visit_date DESC;
  `);
  const withGPS = visits.filter(v => v.lat != null);
  const noGPS   = visits.filter(v => v.lat == null);
  console.log('NULL-vehicle completed visits: ' + visits.length);
  console.log('  with GPS reference:    ' + withGPS.length);
  console.log('  no GPS available:      ' + noGPS.length + '  (can\'t backfill these without a property GPS)');

  const attributable = [];
  const ambiguous = [];
  const noEvidence = [];

  for (let i = 0; i < withGPS.length; i++) {
    const v = withGPS[i];
    const startMs = v.start_at ? new Date(v.start_at).getTime()
                    : new Date(v.visit_date + 'T00:00:00Z').getTime();
    const endMs   = v.completed_at ? new Date(v.completed_at).getTime() : startMs + 4*60*60*1000;
    const winStart = new Date(startMs - 30*60*1000).toISOString();
    const winEnd   = new Date(endMs + 30*60*1000).toISOString();
    const dLat = 0.005;                              // ~500m bounding box
    const dLng = 0.005 / Math.cos(v.lat * Math.PI / 180);

    const pings = await pg(`
      SELECT vt.vehicle_id, vt.recorded_at::text AS t,
        vt.latitude::float AS plat, vt.longitude::float AS plng,
        veh.name AS truck
      FROM vehicle_telemetry_readings vt
      JOIN vehicles veh ON veh.id = vt.vehicle_id AND veh.status = 'ACTIVE'
      WHERE vt.recorded_at BETWEEN '${winStart}' AND '${winEnd}'
        AND vt.latitude  BETWEEN ${v.lat - dLat} AND ${v.lat + dLat}
        AND vt.longitude BETWEEN ${v.lng - dLng} AND ${v.lng + dLng}
      ORDER BY vt.recorded_at;
    `);

    const byTruck = {};
    for (const p of pings) {
      const d = haversineM(v.lat, v.lng, p.plat, p.plng);
      if (!byTruck[p.truck]) byTruck[p.truck] = { vehicle_id: p.vehicle_id, pings: [] };
      byTruck[p.truck].pings.push(d);
    }
    const scores = Object.entries(byTruck).map(([truck, d]) => {
      const minDist = Math.round(Math.min(...d.pings));
      const within150 = d.pings.filter(x => x <= 150).length;
      return { truck, vehicle_id: d.vehicle_id, min_dist_m: minDist, pings_within_150m: within150 };
    });
    const qualified = scores.filter(s => s.min_dist_m <= 150 && s.pings_within_150m >= 2);

    if (qualified.length === 0) {
      noEvidence.push({ ...v, scores });
    } else if (qualified.length === 1) {
      attributable.push({ ...v, winner: qualified[0] });
    } else {
      qualified.sort((a, b) => a.min_dist_m - b.min_dist_m);
      ambiguous.push({ ...v, winner: qualified[0], runners_up: qualified.slice(1) });
    }

    if ((i + 1) % 20 === 0) console.log('  scanned ' + (i+1) + '/' + withGPS.length);
  }

  console.log('\n=== Results ===');
  console.log('Attributable (single qualifying truck):     ' + attributable.length);
  console.log('Tie-break needed (multiple trucks):         ' + ambiguous.length + ' (winner = closest min_dist)');
  console.log('No qualifying GPS evidence:                 ' + noEvidence.length);
  console.log('Total to UPDATE:                            ' + (attributable.length + ambiguous.length));

  if (attributable.length) {
    console.log('\nSample attributable visits (first 8):');
    console.table(attributable.slice(0, 8).map(a => ({
      visit_id: a.visit_id, date: a.visit_date, client: a.client_code,
      truck: a.winner.truck, min_dist_m: a.winner.min_dist_m, pings: a.winner.pings_within_150m,
      gps_src: a.gps_source,
    })));
  }
  if (ambiguous.length) {
    console.log('\nSample ambiguous visits (first 5) — taking winner by closest min_dist:');
    console.table(ambiguous.slice(0, 5).map(a => ({
      visit_id: a.visit_id, date: a.visit_date, client: a.client_code,
      winner: a.winner.truck + ' (' + a.winner.min_dist_m + 'm)',
      runners_up: a.runners_up.map(r => r.truck + ' (' + r.min_dist_m + 'm)').join('; '),
    })));
  }
  if (noEvidence.length) {
    console.log('\nNo-GPS-evidence visits (manual review needed) — first 5:');
    console.table(noEvidence.slice(0, 5).map(n => ({
      visit_id: n.visit_id, date: n.visit_date, client: n.client_code,
      best_candidate: n.scores.length ? n.scores[0].truck + ' (' + n.scores[0].min_dist_m + 'm, ' + n.scores[0].pings_within_150m + ' pings)' : '(no pings near property)',
    })));
  }

  if (!EXECUTE) {
    console.log('\n[DRY-RUN] Would UPDATE ' + (attributable.length + ambiguous.length) + ' rows. Re-run with --execute.');
    return;
  }

  console.log('\nApplying updates...');
  const winners = [...attributable, ...ambiguous];
  for (const w of winners) {
    await pg('UPDATE visits SET vehicle_id = ' + w.winner.vehicle_id + ' WHERE id = ' + w.visit_id + ' AND vehicle_id IS NULL;');
  }
  console.log('Updated ' + winners.length + ' visits.');

  const verify = await pg(`
    SELECT
      COALESCE(veh.name, '(NULL)') AS truck,
      COUNT(*) FILTER (WHERE v.visit_date >= '2026-01-01')::int AS completed_2026
    FROM visits v LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
    WHERE v.visit_status = 'completed' GROUP BY veh.name ORDER BY completed_2026 DESC;
  `);
  console.log('\nPost-state — completed visits per truck (2026):');
  console.table(verify);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
