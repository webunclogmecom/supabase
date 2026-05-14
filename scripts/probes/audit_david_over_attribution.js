// Phase 2 — Audit visits attributed to David (truck) on/after 2026-03-01.
//
// Per memory: after Moises went operational 2026-02-16, David's actual
// presence dropped sharply. If a 2026-03+ visit is attributed to David
// but GPS shows another truck was clearly the one at the property,
// correct the attribution.
//
// Logic per visit:
//   1. Pull GPS pings for ALL active trucks in the visit window.
//   2. Score each truck (min_dist_m, pings_within_150m).
//   3. Find the "best" qualifying truck (min_dist ≤ 150m + ≥2 pings within 150m).
//   4. If best != David AND David's own evidence is WEAK
//      (min_dist > 150m OR pings_within_150m < 2)
//      → correct visit.vehicle_id = best.
//   5. If David himself has best/qualifying evidence → leave it.
//   6. If no truck qualifies → flag for manual review (no change).
//
// Idempotent: only updates when GPS clearly indicates a different truck.
//
// Usage:
//   node scripts/probes/audit_david_over_attribution.js              # dry-run
//   node scripts/probes/audit_david_over_attribution.js --execute    # writes
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

  // Get David's vehicle_id + suspect visits
  const davidRow = await pg(`SELECT id FROM vehicles WHERE name = 'David' LIMIT 1;`);
  if (!davidRow.length) throw new Error('No vehicle named David');
  const DAVID_ID = davidRow[0].id;

  const suspects = await pg(`
    SELECT v.id AS visit_id, v.visit_date::text, v.start_at::text, v.completed_at::text,
      v.client_id, c.client_code,
      COALESCE(p.latitude,  pp.latitude)::float  AS lat,
      COALESCE(p.longitude, pp.longitude)::float AS lng
    FROM visits v
    LEFT JOIN clients c ON c.id = v.client_id
    LEFT JOIN properties p ON p.id = v.property_id AND p.latitude IS NOT NULL
    LEFT JOIN properties pp ON pp.client_id = v.client_id AND pp.is_primary = TRUE AND pp.latitude IS NOT NULL
    WHERE v.visit_status = 'completed'
      AND v.vehicle_id = ${DAVID_ID}
      AND v.visit_date >= '2026-03-01'
      AND (p.latitude IS NOT NULL OR pp.latitude IS NOT NULL)
      AND v.start_at IS NOT NULL
    ORDER BY v.visit_date DESC;
  `);
  console.log('David-attributed visits 2026-03+ (with GPS reference): ' + suspects.length + '\n');

  const keep = [];           // David's evidence holds
  const correct = [];        // Another truck clearly better
  const noEvidence = [];     // No truck qualifies; flag

  for (let i = 0; i < suspects.length; i++) {
    const v = suspects[i];
    const startMs = new Date(v.start_at).getTime();
    const endMs   = v.completed_at ? new Date(v.completed_at).getTime() : startMs + 4*60*60*1000;
    const winStart = new Date(startMs - 30*60*1000).toISOString();
    const winEnd   = new Date(endMs + 30*60*1000).toISOString();
    const dLat = 0.005, dLng = 0.005 / Math.cos(v.lat * Math.PI / 180);

    const pings = await pg(`
      SELECT vt.vehicle_id, vt.latitude::float AS plat, vt.longitude::float AS plng, veh.name AS truck
      FROM vehicle_telemetry_readings vt
      JOIN vehicles veh ON veh.id = vt.vehicle_id AND veh.status = 'ACTIVE'
      WHERE vt.recorded_at BETWEEN '${winStart}' AND '${winEnd}'
        AND vt.latitude  BETWEEN ${v.lat - dLat} AND ${v.lat + dLat}
        AND vt.longitude BETWEEN ${v.lng - dLng} AND ${v.lng + dLng};
    `);

    const byTruck = {};
    for (const p of pings) {
      const d = haversineM(v.lat, v.lng, p.plat, p.plng);
      if (!byTruck[p.truck]) byTruck[p.truck] = { vehicle_id: p.vehicle_id, pings: [] };
      byTruck[p.truck].pings.push(d);
    }
    const scores = Object.entries(byTruck).map(([truck, d]) => ({
      truck, vehicle_id: d.vehicle_id,
      min_dist_m: Math.round(Math.min(...d.pings)),
      pings_within_150m: d.pings.filter(x => x <= 150).length,
    })).sort((a, b) => a.min_dist_m - b.min_dist_m);

    const qualified = scores.filter(s => s.min_dist_m <= 150 && s.pings_within_150m >= 2);
    const davidScore = scores.find(s => s.truck === 'David');
    const bestQualified = qualified[0];

    if (!bestQualified) {
      noEvidence.push({ ...v, scores });
    } else if (bestQualified.truck === 'David') {
      keep.push({ ...v, david: davidScore });
    } else {
      // Another truck clearly qualifies; check David's evidence
      const davidWeak = !davidScore
        || davidScore.min_dist_m > 150
        || davidScore.pings_within_150m < 2;
      if (davidWeak) {
        correct.push({ ...v, winner: bestQualified, david: davidScore || null, all_scores: scores });
      } else {
        keep.push({ ...v, david: davidScore, also_qualified: bestQualified });
      }
    }

    if ((i+1) % 10 === 0) console.log('  scanned ' + (i+1) + '/' + suspects.length);
  }

  console.log('\n=== Results ===');
  console.log('Keep as David (David has GPS evidence):     ' + keep.length);
  console.log('CORRECT to another truck (David clearly wrong by GPS): ' + correct.length);
  console.log('No qualifying truck (flag for manual review):          ' + noEvidence.length);

  if (correct.length) {
    console.log('\nCorrections — David → other truck:');
    console.table(correct.map(c => ({
      visit_id: c.visit_id, date: c.visit_date, client: c.client_code,
      david_evidence: c.david ? c.david.min_dist_m + 'm, ' + c.david.pings_within_150m + ' pings' : 'NO David pings',
      proposed_truck: c.winner.truck + ' (' + c.winner.min_dist_m + 'm, ' + c.winner.pings_within_150m + ' pings)',
    })));
  }
  if (keep.length && keep.length <= 5) {
    console.log('\nKept-as-David (David has GPS evidence at the property):');
    console.table(keep.map(k => ({
      visit_id: k.visit_id, date: k.visit_date, client: k.client_code,
      david: k.david ? k.david.min_dist_m + 'm, ' + k.david.pings_within_150m + ' pings' : 'kept (no qualifier — anomaly)',
    })));
  } else if (keep.length) {
    console.log('\nKept-as-David: ' + keep.length + ' visits (David\'s GPS confirms presence)');
  }
  if (noEvidence.length) {
    console.log('\nNo-evidence (no truck had ≥2 pings within 150m) — first 5:');
    console.table(noEvidence.slice(0, 5).map(n => ({
      visit_id: n.visit_id, date: n.visit_date, client: n.client_code,
      closest_observed: n.scores[0] ? n.scores[0].truck + ' (' + n.scores[0].min_dist_m + 'm)' : '(no pings)',
    })));
  }

  if (!EXECUTE) {
    console.log('\n[DRY-RUN] Would UPDATE ' + correct.length + ' visits. Re-run with --execute.');
    return;
  }

  for (const c of correct) {
    await pg('UPDATE visits SET vehicle_id = ' + c.winner.vehicle_id + ' WHERE id = ' + c.visit_id + ' AND vehicle_id = ' + DAVID_ID + ';');
  }
  console.log('\nUpdated ' + correct.length + ' visits.');

  const verify = await pg(`
    SELECT COALESCE(veh.name, '(NULL)') AS truck, COUNT(*)::int AS completed_2026
    FROM visits v LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
    WHERE v.visit_status = 'completed' AND v.visit_date >= '2026-01-01'
    GROUP BY veh.name ORDER BY completed_2026 DESC;
  `);
  console.log('\nPost-state — completed 2026 visits per truck:');
  console.table(verify);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
