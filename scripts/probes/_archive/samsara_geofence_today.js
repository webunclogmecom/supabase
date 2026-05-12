require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
function pg(sql) { return new Promise((res, rej) => {
  const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res({status:x.statusCode,body:b}));});
  req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
});}
async function q(sql) { const r = await pg(sql); if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0,300)}`); return JSON.parse(r.body); }

// Cutoff: 04:00 UTC = midnight ET (since current_date is 2026-05-11)
const SINCE = `'2026-05-11 04:00:00+00'`;

(async () => {
  console.log('=== Updates since midnight ET (2026-05-11 04:00 UTC) ===\n');

  // Q1: Which clients got geofence/location updates today, by status?
  console.log('Q1. Status breakdown of updated clients today:');
  const byStatus = await q(`
    SELECT
      c.status,
      COUNT(DISTINCT c.id) AS n_clients,
      COUNT(DISTINCT p.id) AS n_properties
    FROM properties p JOIN clients c ON c.id = p.client_id
    WHERE p.updated_at >= ${SINCE}
    GROUP BY c.status ORDER BY n_clients DESC;`);
  console.log('  status          | clients | properties');
  console.log('  ' + '-'.repeat(40));
  for (const r of byStatus) console.log(`  ${(r.status||'NULL').padEnd(15)} | ${String(r.n_clients).padStart(7)} | ${String(r.n_properties).padStart(10)}`);

  // Q2: Were INACTIVE / PAUSED clients also updated?
  console.log('\nQ2. INACTIVE / PAUSED clients updated today (samples):');
  const nonActiveUpdated = await q(`
    SELECT c.client_code, c.name, c.status,
      p.id AS property_id, p.address, p.latitude, p.longitude, p.geofence_radius_meters,
      p.updated_at AT TIME ZONE 'America/New_York' AS updated_et
    FROM properties p JOIN clients c ON c.id = p.client_id
    WHERE p.updated_at >= ${SINCE}
      AND c.status IN ('INACTIVE','PAUSED')
    ORDER BY c.status, c.client_code;`);
  if (nonActiveUpdated.length === 0) {
    console.log('  ✓ None — only ACTIVE/Recuring clients touched today');
  } else {
    console.log(`  ⚠ ${nonActiveUpdated.length} non-active properties also got updates`);
    for (const r of nonActiveUpdated.slice(0,15)) console.log(`    ${r.status.padEnd(10)} ${(r.client_code||'-').padEnd(10)} ${(r.name||'').slice(0,40).padEnd(40)} ${r.updated_et}`);
  }

  // Q3: Active/Recurring clients whose properties were NOT updated today
  console.log('\nQ3. Active/Recurring commercial clients with properties NOT updated today:');
  const missing = await q(`
    SELECT c.client_code, c.name, c.status,
      COUNT(*) AS n_properties,
      MAX(p.updated_at AT TIME ZONE 'America/New_York') AS last_property_update_et,
      COUNT(*) FILTER (WHERE p.latitude IS NULL OR p.longitude IS NULL) AS n_no_gps,
      COUNT(*) FILTER (WHERE p.geofence_radius_meters IS NULL) AS n_no_geofence
    FROM clients c
    LEFT JOIN properties p ON p.client_id = c.id
    WHERE c.status IN ('ACTIVE','Recuring')
      AND c.client_code ~ '^[0-9]{3}-'
      AND NOT EXISTS (
        SELECT 1 FROM properties p2 WHERE p2.client_id = c.id AND p2.updated_at >= ${SINCE}
      )
    GROUP BY c.id, c.client_code, c.name, c.status
    ORDER BY c.client_code;`);
  console.log(`  ${missing.length} active/recurring commercial clients had NO property touched today`);
  if (missing.length > 0 && missing.length <= 30) {
    for (const r of missing) console.log(`    ${(r.client_code||'-').padEnd(10)} ${(r.name||'').slice(0,40).padEnd(40)}  status=${r.status}  props=${r.n_properties} (no_gps=${r.n_no_gps}, no_geofence=${r.n_no_geofence}, last_update=${r.last_property_update_et||'-'})`);
  } else if (missing.length > 30) {
    console.log('  (showing first 25 + summary)');
    for (const r of missing.slice(0,25)) console.log(`    ${(r.client_code||'-').padEnd(10)} ${(r.name||'').slice(0,40).padEnd(40)}  no_gps=${r.n_no_gps}, no_geofence=${r.n_no_geofence}`);
  }

  // Q4: Among those missing-today, which ones have NO GPS or NO geofence at all?
  console.log('\nQ4. Of clients NOT updated today: which have INCOMPLETE GPS or geofence data?');
  const incomplete = await q(`
    SELECT c.client_code, c.name, c.status,
      p.id AS property_id, p.address,
      p.latitude, p.longitude, p.geofence_radius_meters, p.geofence_type,
      p.updated_at AT TIME ZONE 'America/New_York' AS last_update_et
    FROM clients c JOIN properties p ON p.client_id = c.id
    WHERE c.status IN ('ACTIVE','Recuring')
      AND c.client_code ~ '^[0-9]{3}-'
      AND p.updated_at < ${SINCE}
      AND (p.latitude IS NULL OR p.longitude IS NULL OR p.geofence_radius_meters IS NULL)
    ORDER BY c.client_code;`);
  console.log(`  ${incomplete.length} active/recurring commercial properties missing GPS or geofence_radius`);
  for (const r of incomplete.slice(0,20)) {
    const gaps = [];
    if (!r.latitude || !r.longitude) gaps.push('NO GPS');
    if (!r.geofence_radius_meters) gaps.push('NO RADIUS');
    console.log(`    ${(r.client_code||'-').padEnd(10)} ${(r.name||'').slice(0,35).padEnd(35)}  ${gaps.join('+').padEnd(20)}  last_update=${r.last_update_et||'-'}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
