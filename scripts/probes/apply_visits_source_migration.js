// Apply scripts/migrations/add_visits_source_and_inactive_wipe_2026_05_12.sql
// to both Prod and Sandbox. Pre-checks first.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;

function pg(sql, project) {
  return new Promise((res, rej) => {
    const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${project}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res({status:x.statusCode,body:b}));});
    req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
  });
}

(async () => {
  const sql = fs.readFileSync(path.resolve(__dirname, '../migrations/add_visits_source_and_inactive_wipe_2026_05_12.sql'), 'utf8');

  for (const [name, proj] of [['PROD', PROD], ['SBX', SBX]]) {
    console.log(`\n=== Pre-check ${name}: any service_configs.service_type or visits.service_type outside the allowed set? ===`);
    const pre = await pg(`
      SELECT 'service_configs' AS t, service_type, COUNT(*) AS n FROM service_configs WHERE service_type NOT IN ('GT','CL','WD','LS') OR service_type IS NULL
      GROUP BY service_type
      UNION ALL
      SELECT 'visits', service_type, COUNT(*) FROM visits WHERE service_type IS NOT NULL AND service_type NOT IN ('GT','CL','WD','LS')
      GROUP BY service_type;`, proj);
    if (pre.status >= 300) { console.error('  Pre-check failed:', pre.body.slice(0,300)); return; }
    const rows = JSON.parse(pre.body);
    if (rows.length > 0) {
      console.log('  ⚠ Found out-of-set rows — would block the new CHECK constraint:');
      console.log(JSON.stringify(rows, null, 2));
      console.log(`  Aborting ${name}; investigate first.`);
      continue;
    }
    console.log('  ✓ All values are within allowed set');

    console.log(`\n=== Applying migration to ${name} ===`);
    const r = await pg(sql, proj);
    if (r.status >= 300) { console.error(`  ✗ FAILED:`, r.status, r.body.slice(0,500)); continue; }
    console.log(`  ✓ ${name} migration applied`);

    console.log(`\n=== Verify ${name} ===`);
    const v1 = await pg(`SELECT source, COUNT(*) AS n FROM visits GROUP BY source ORDER BY n DESC;`, proj);
    console.log('  visits by source:');
    for (const row of JSON.parse(v1.body)) console.log(`    ${row.source}: ${row.n}`);

    const v2 = await pg(`SELECT tgname FROM pg_trigger WHERE tgrelid='public.clients'::regclass AND tgname='trg_clients_wipe_upcoming_on_inactive';`, proj);
    console.log(`  INACTIVE wipe trigger: ${JSON.parse(v2.body).length ? '✓ installed' : '✗ MISSING'}`);

    const v3 = await pg(`SELECT conname FROM pg_constraint WHERE conrelid='public.service_configs'::regclass AND conname='service_configs_service_type_chk';`, proj);
    console.log(`  service_configs CHECK: ${JSON.parse(v3.body).length ? '✓ installed' : '✗ MISSING'}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
