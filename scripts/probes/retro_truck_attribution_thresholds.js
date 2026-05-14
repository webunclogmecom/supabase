// Empirically derive proximity + dwell-time thresholds for backfilling
// NULL vehicle_id visits via GPS.
//
// Method: sample N completed visits with KNOWN vehicle_id + property GPS.
// For each, query the assigned truck's GPS pings in the visit window
// (start_at - 30min ... end_at + 30min). Compute:
//   - min_dist_m  : closest the truck got to the property
//   - pings_<X>m  : count of pings within X meters (X ∈ 100/150/250/333/500/1000)
//   - dwell_<X>m  : minutes between first and last ping within X meters
//
// Then aggregate percentiles → pick a threshold pair that captures P90+
// of known-good visits while excluding random drive-bys.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const https = require('https');

const SAMPLE_SIZE = +(process.env.RETRO_SAMPLE_SIZE || 150);
const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT  = process.env.SUPABASE_PAT;

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) {
  const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROD+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query:sql}));
  if (r.status >= 300) throw new Error('PG '+r.status+': '+r.body.slice(0,400));
  return JSON.parse(r.body);
}
function haversineM(lat1, lng1, lat2, lng2) {
  const R = 6371000, toRad = d => d * Math.PI / 180;
  const dLat = toRad(lat2 - lat1), dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat/2)**2 + Math.cos(toRad(lat1))*Math.cos(toRad(lat2))*Math.sin(dLng/2)**2;
  return 2 * R * Math.asin(Math.sqrt(a));
}
function percentile(arr, p) {
  if (!arr.length) return null;
  const sorted = [...arr].sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.floor(p * sorted.length));
  return sorted[idx];
}

(async () => {
  console.log('Sampling ' + SAMPLE_SIZE + ' known-good completed visits with GPS...');
  const sample = await pg(`
    SELECT v.id, v.start_at::text AS start_at, v.completed_at::text AS completed_at,
      v.vehicle_id, veh.name AS truck,
      p.latitude::float AS lat, p.longitude::float AS lng,
      c.client_code
    FROM visits v
    JOIN vehicles veh ON veh.id = v.vehicle_id
    JOIN properties p ON p.id = v.property_id
    LEFT JOIN clients c ON c.id = v.client_id
    WHERE v.visit_status = 'completed'
      AND v.start_at IS NOT NULL
      AND v.visit_date >= '2026-02-16'  -- Moises operational + reliable telemetry window
      AND p.latitude IS NOT NULL
    ORDER BY random()
    LIMIT ${SAMPLE_SIZE};
  `);
  console.log('  got ' + sample.length + ' visits with assigned truck + property GPS\n');

  const DIST_BUCKETS = [100, 150, 250, 333, 500, 1000];
  const stats = {
    by_truck: {},
    no_gps_evidence: 0,
    samples: [],
  };

  for (let i = 0; i < sample.length; i++) {
    const v = sample[i];
    const startMs = new Date(v.start_at).getTime();
    const endMs = v.completed_at ? new Date(v.completed_at).getTime() : startMs + 90*60*1000;
    const winStart = new Date(startMs - 30*60*1000).toISOString();
    const winEnd = new Date(endMs + 30*60*1000).toISOString();
    const dLat = 0.03; // ~3km bounding box, generous
    const dLng = 0.03 / Math.cos(v.lat * Math.PI / 180);

    const pings = await pg(`
      SELECT recorded_at::text AS t, latitude::float AS plat, longitude::float AS plng,
        (speed_meters_per_sec * 2.237)::float AS speed_mph
      FROM vehicle_telemetry_readings
      WHERE vehicle_id = ${v.vehicle_id}
        AND recorded_at BETWEEN '${winStart}' AND '${winEnd}'
        AND latitude BETWEEN ${v.lat-dLat} AND ${v.lat+dLat}
        AND longitude BETWEEN ${v.lng-dLng} AND ${v.lng+dLng}
      ORDER BY recorded_at;
    `);

    if (!pings.length) { stats.no_gps_evidence++; continue; }

    const distsAll = pings.map(p => ({
      ts: new Date(p.t).getTime(),
      dist: haversineM(v.lat, v.lng, p.plat, p.plng),
      speed: p.speed,
    }));

    const minDist = Math.round(Math.min(...distsAll.map(d => d.dist)));
    const result = { visit_id: v.id, truck: v.truck, client_code: v.client_code, min_dist_m: minDist };

    for (const X of DIST_BUCKETS) {
      const within = distsAll.filter(d => d.dist <= X);
      const dwellMin = within.length >= 2
        ? Math.round((within[within.length-1].ts - within[0].ts) / 60000)
        : (within.length === 1 ? 0 : null);
      result['pings_' + X + 'm'] = within.length;
      result['dwell_' + X + 'm'] = dwellMin;
    }

    stats.samples.push(result);
    if (!stats.by_truck[v.truck]) stats.by_truck[v.truck] = 0;
    stats.by_truck[v.truck]++;

    if ((i+1) % 25 === 0) console.log('  processed ' + (i+1) + '/' + sample.length);
  }

  console.log('\n=== Sample composition ===');
  console.table(stats.by_truck);
  console.log('  visits with NO GPS evidence at all: ' + stats.no_gps_evidence);

  console.log('\n=== Percentiles across the ' + stats.samples.length + ' GPS-evidenced visits ===');
  const rows = [];
  for (const X of DIST_BUCKETS) {
    const pings = stats.samples.map(s => s['pings_' + X + 'm']).filter(n => n != null);
    const dwells = stats.samples.map(s => s['dwell_' + X + 'm']).filter(n => n != null);
    rows.push({
      threshold: X + 'm',
      p10_pings: percentile(pings, 0.10),
      p50_pings: percentile(pings, 0.50),
      p90_pings: percentile(pings, 0.90),
      p10_dwell_min: percentile(dwells, 0.10),
      p50_dwell_min: percentile(dwells, 0.50),
      p90_dwell_min: percentile(dwells, 0.90),
      coverage_pct: Math.round(100 * dwells.filter(d => d != null && d > 0).length / stats.samples.length),
    });
  }
  console.table(rows);

  console.log('\n=== min_dist_m percentiles ===');
  const minDists = stats.samples.map(s => s.min_dist_m);
  console.table([
    { metric: 'min_dist_m',
      p10: percentile(minDists, 0.10),
      p25: percentile(minDists, 0.25),
      p50: percentile(minDists, 0.50),
      p75: percentile(minDists, 0.75),
      p90: percentile(minDists, 0.90),
    }
  ]);

  // Find the (proximity, dwell) threshold combos that capture ≥X% of known-good
  console.log('\n=== Coverage of candidate (distance ≤ D AND dwell ≥ T min) rules ===');
  const candidates = [];
  for (const D of [100, 150, 250, 333, 500]) {
    for (const T of [0, 1, 2, 5, 10, 15, 20]) {
      const matches = stats.samples.filter(s => {
        const d = s['dwell_' + D + 'm'];
        return s.min_dist_m <= D && d != null && d >= T;
      }).length;
      candidates.push({
        rule: `≤${D}m for ≥${T}min`,
        captures: matches,
        coverage_pct: Math.round(100 * matches / stats.samples.length),
      });
    }
  }
  console.table(candidates.filter(c => c.coverage_pct >= 80 && c.coverage_pct <= 99).sort((a,b)=>b.coverage_pct-a.coverage_pct));

  // Persist full results
  const outPath = path.resolve(__dirname, '../../docs/field-portal-truck-attribution-retro.md');
  let md = '# Truck attribution thresholds — retro analysis\n\n';
  md += '_Generated ' + new Date().toISOString().slice(0,10) + '. Sample = ' + stats.samples.length + ' known-good visits with property GPS, run against canonical vehicle_telemetry_readings._\n\n';
  md += '## Composition by truck\n\n';
  md += '| Truck | Visits sampled |\n|---|---:|\n';
  for (const [t, n] of Object.entries(stats.by_truck)) md += '| ' + t + ' | ' + n + ' |\n';
  md += '| _(no GPS at all)_ | ' + stats.no_gps_evidence + ' |\n\n';
  md += '## Percentiles (pings + dwell within distance threshold)\n\n';
  md += '| Threshold | p10 pings | p50 pings | p90 pings | p10 dwell (min) | p50 dwell (min) | p90 dwell (min) | % with ≥1 ping |\n|---|---:|---:|---:|---:|---:|---:|---:|\n';
  for (const r of rows) md += '| ' + r.threshold + ' | ' + r.p10_pings + ' | ' + r.p50_pings + ' | ' + r.p90_pings + ' | ' + r.p10_dwell_min + ' | ' + r.p50_dwell_min + ' | ' + r.p90_dwell_min + ' | ' + r.coverage_pct + '% |\n';
  md += '\n## Candidate rules (distance ≤ D AND dwell ≥ T min) — coverage of known-good visits\n\n';
  md += '| Rule | Captures | Coverage |\n|---|---:|---:|\n';
  for (const c of candidates.filter(c => c.coverage_pct >= 75).sort((a,b)=>b.coverage_pct-a.coverage_pct).slice(0, 30)) {
    md += '| ' + c.rule + ' | ' + c.captures + ' | ' + c.coverage_pct + '% |\n';
  }
  fs.writeFileSync(outPath, md);
  console.log('\nFull retro saved to docs/field-portal-truck-attribution-retro.md');
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
