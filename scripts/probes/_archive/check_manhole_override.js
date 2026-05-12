require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
function pg(sql) { return new Promise((res, rej) => {
  const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${SBX}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res(JSON.parse(b)));});
  req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
});}
(async () => {
  console.log('=== app_property_overrides — landings ===');
  const rows = await pg(`
    SELECT o.id, o.external_property_id, o.grease_trap_manhole_count AS override_count,
      o.override_reason,
      p.grease_trap_manhole_count AS canonical_count,
      c.client_code, c.name AS client_name, p.address,
      o.created_at AT TIME ZONE 'America/New_York' AS created_et,
      o.updated_at AT TIME ZONE 'America/New_York' AS updated_et
    FROM app_property_overrides o
    LEFT JOIN properties p ON p.id = o.external_property_id
    LEFT JOIN clients c ON c.id = p.client_id
    ORDER BY o.updated_at DESC;`);
  console.log(`  ${rows.length} row(s)`);
  for (const r of rows) {
    console.log(`    property_id=${r.external_property_id} (${r.client_code || '-'} ${r.client_name || '?'})`);
    console.log(`      address: ${r.address || '-'}`);
    console.log(`      override count: ${r.override_count}   canonical: ${r.canonical_count}`);
    console.log(`      reason: "${r.override_reason || '(null)'}"`);
    console.log(`      created: ${r.created_et}   updated: ${r.updated_et}`);
  }

  console.log('\n=== Confirm properties.grease_trap_manhole_count for this property was NOT touched ===');
  if (rows.length) {
    const propId = rows[0].external_property_id;
    const stat = await pg(`SELECT n_tup_upd FROM pg_stat_user_tables WHERE relname='properties';`);
    console.log(`  properties total UPDATEs (cumulative): ${stat[0].n_tup_upd}`);
    console.log(`  (Should equal the same number as before — no growth since hook rewired)`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
