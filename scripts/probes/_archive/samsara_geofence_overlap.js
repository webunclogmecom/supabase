require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
function pg(sql) { return new Promise((res, rej) => {
  const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res(JSON.parse(b)));});
  req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
});}
function haversineM(lat1, lng1, lat2, lng2) {
  const R = 6371000, toRad = d => d * Math.PI / 180;
  const dLat = toRad(lat2 - lat1), dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat/2)**2 + Math.cos(toRad(lat1))*Math.cos(toRad(lat2))*Math.sin(dLng/2)**2;
  return 2 * R * Math.asin(Math.sqrt(a));
}
(async () => {
  // Pull all properties with both lat/lng AND geofence_radius_meters
  const props = await pg(`
    SELECT p.id, p.latitude::float AS lat, p.longitude::float AS lng,
      p.geofence_radius_meters::float AS r,
      p.address, c.client_code, c.name AS client_name, c.status
    FROM properties p LEFT JOIN clients c ON c.id = p.client_id
    WHERE p.latitude IS NOT NULL AND p.longitude IS NOT NULL
      AND p.geofence_radius_meters IS NOT NULL AND p.geofence_radius_meters > 0;`);
  console.log(`Comparing ${props.length} properties with full GPS+radius...\n`);

  const overlaps = [];
  for (let i = 0; i < props.length; i++) {
    for (let j = i + 1; j < props.length; j++) {
      const a = props[i], b = props[j];
      // Quick bounding box test to skip obvious-no
      if (Math.abs(a.lat - b.lat) > 0.01 || Math.abs(a.lng - b.lng) > 0.01) continue;
      const dist = haversineM(a.lat, a.lng, b.lat, b.lng);
      const sumR = a.r + b.r;
      if (dist < sumR && a.id !== b.id) {
        // Same-client overlaps are fine (multi-location of one client)
        const isSameClient = a.client_code && b.client_code && a.client_code === b.client_code;
        overlaps.push({a, b, dist_m: Math.round(dist), sum_r: sumR, overlap_m: Math.round(sumR - dist), is_same_client: isSameClient});
      }
    }
  }
  overlaps.sort((x,y) => y.overlap_m - x.overlap_m);
  console.log(`Found ${overlaps.length} pair(s) where geofences overlap (sum-of-radii > distance)\n`);

  const diffClient = overlaps.filter(o => !o.is_same_client);
  const sameClient = overlaps.filter(o => o.is_same_client);

  console.log(`=== DIFFERENT-CLIENT overlaps (${diffClient.length}) — these are the real problem ===`);
  for (const o of diffClient.slice(0, 30)) {
    console.log(`  ${o.overlap_m}m overlap (distance=${o.dist_m}m, sum_r=${o.sum_r}m)`);
    console.log(`    A: ${(o.a.client_code||'-').padEnd(10)} ${(o.a.client_name||'?').slice(0,40).padEnd(40)} [${o.a.status||'?'}] r=${o.a.r}m`);
    console.log(`       ${(o.a.address||'').slice(0,60)}`);
    console.log(`    B: ${(o.b.client_code||'-').padEnd(10)} ${(o.b.client_name||'?').slice(0,40).padEnd(40)} [${o.b.status||'?'}] r=${o.b.r}m`);
    console.log(`       ${(o.b.address||'').slice(0,60)}`);
    console.log('');
  }
  if (diffClient.length > 30) console.log(`  ...and ${diffClient.length - 30} more`);

  console.log(`\n=== SAME-CLIENT overlaps (${sameClient.length}) — usually fine (multi-property single client) ===`);
  if (sameClient.length <= 10) for (const o of sameClient) console.log(`  ${o.a.client_code}: ${o.overlap_m}m`);
  else console.log(`  (${sameClient.length} same-client overlaps — generally OK, multi-building campuses, drive-thrus etc.)`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
