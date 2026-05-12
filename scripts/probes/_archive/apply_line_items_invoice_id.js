require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');
const PROD = process.env.SUPABASE_PROJECT_ID;
const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;

function pg(sql, project) {
  return new Promise((res, rej) => {
    const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${project}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res({status:x.statusCode,body:b}));});
    req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
  });
}
(async () => {
  const sql = fs.readFileSync(require('path').resolve(__dirname, '../migrations/add_line_items_invoice_id_2026_05_12.sql'), 'utf8');

  // Pre-check: existing rows all have at least one scope set
  console.log('=== Pre-check Prod: any line_items with all-NULL scope columns? ===');
  const pre = await pg(`SELECT COUNT(*) AS n FROM line_items WHERE job_id IS NULL AND quote_id IS NULL;`, PROD);
  if (pre.status >= 300) { console.error('Pre-check failed:', pre.body); return; }
  const orphans = JSON.parse(pre.body)[0].n;
  console.log(`  ${orphans} all-NULL rows`);
  if (Number(orphans) > 0) {
    console.error('  ⚠ Would break the CHECK constraint. Stopping. Investigate before retry.');
    return;
  }

  console.log('\n=== Applying migration to PROD ===');
  const r1 = await pg(sql, PROD);
  if (r1.status >= 300) { console.error('PROD migration FAILED:', r1.status, r1.body.slice(0,500)); return; }
  console.log('  ✓ Prod migration applied');

  console.log('\n=== Applying migration to SANDBOX (same SQL) ===');
  const r2 = await pg(sql, SBX);
  if (r2.status >= 300) { console.error('SBX migration FAILED:', r2.status, r2.body.slice(0,500)); return; }
  console.log('  ✓ Sandbox migration applied');

  // Verify column exists in both
  console.log('\n=== Verify column exists ===');
  for (const [name, proj] of [['PROD', PROD], ['SBX', SBX]]) {
    const v = await pg(`SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='line_items' AND column_name='invoice_id';`, proj);
    const rows = JSON.parse(v.body);
    console.log(`  ${name}: ${rows.length ? JSON.stringify(rows[0]) : 'NOT FOUND'}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
