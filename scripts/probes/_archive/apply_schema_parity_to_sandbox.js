// Bring Sandbox schema in line with Production for the migrations that were
// deferred. Run before sandbox_refresh.sh can succeed.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');

const PROJECT = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${PROJECT}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,800)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log(`Sandbox: ${PROJECT}\n`);

  console.log('=== BEFORE: vehicle_telemetry_readings columns ===');
  console.table(await q(`SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='vehicle_telemetry_readings' ORDER BY ordinal_position;`));

  console.log('\n=== Applying add_gps_to_telemetry_2026_04_30.sql ===');
  const gps = fs.readFileSync(path.resolve(__dirname, '../migrations/add_gps_to_telemetry_2026_04_30.sql'), 'utf8');
  await q(gps);
  console.log('  ✓ done');

  console.log('\n=== Applying drop_dormant_tables_2026_04_30.sql ===');
  const drop = fs.readFileSync(path.resolve(__dirname, '../migrations/drop_dormant_tables_2026_04_30.sql'), 'utf8');
  await q(drop);
  console.log('  ✓ done');

  console.log('\n=== AFTER: vehicle_telemetry_readings columns ===');
  console.table(await q(`SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='vehicle_telemetry_readings' ORDER BY ordinal_position;`));

  console.log('\n=== AFTER: dormant tables remaining? ===');
  console.table(await q(`SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('routes','route_stops','receivables','leads','expenses');`));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
