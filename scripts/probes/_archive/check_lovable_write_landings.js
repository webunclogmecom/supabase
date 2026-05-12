require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
function pg(sql) { return new Promise((res, rej) => {
  const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${SBX}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res(JSON.parse(b)));});
  req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
});}
(async () => {
  console.log('=== app_visit_reviews — current state of visit 1799 (the one Fred just touched) ===');
  const visit = await pg(`SELECT external_visit_id, review_status, bonus_status, bonus_denial_note,
    bonus_decided_at AT TIME ZONE 'America/New_York' AS bonus_decided_et,
    updated_at AT TIME ZONE 'America/New_York' AS updated_et
    FROM app_visit_reviews WHERE external_visit_id=1799;`);
  console.log(JSON.stringify(visit, null, 2));

  console.log('\n=== All app_visit_reviews rows ===');
  const all = await pg(`SELECT external_visit_id, review_status, bonus_status,
    updated_at AT TIME ZONE 'America/New_York' AS updated_et
    FROM app_visit_reviews ORDER BY updated_at DESC;`);
  console.log(`  ${all.length} rows`);
  for (const r of all) console.log(`    visit=${r.external_visit_id}  review=${r.review_status}  bonus=${r.bonus_status}  updated=${r.updated_et}`);

  console.log('\n=== app_photo_classifications — any rows yet? ===');
  const pc = await pg(`SELECT COUNT(*) AS n,
    MIN(created_at AT TIME ZONE 'America/New_York') AS earliest_et,
    MAX(created_at AT TIME ZONE 'America/New_York') AS latest_et
    FROM app_photo_classifications;`);
  console.log(JSON.stringify(pc, null, 2));
  if (Number(pc[0].n) > 0) {
    const sample = await pg(`SELECT external_photo_link_id, service_phase,
      created_at AT TIME ZONE 'America/New_York' AS created_et
      FROM app_photo_classifications ORDER BY created_at DESC LIMIT 10;`);
    console.log('Sample rows:');
    for (const r of sample) console.log(`    link=${r.external_photo_link_id}  phase=${r.service_phase}  created=${r.created_et}`);
  } else {
    console.log('  (no rows yet — photo classification hook not yet exercised)');
  }

  console.log('\n=== app_property_overrides — any rows yet? ===');
  const po = await pg(`SELECT COUNT(*) AS n FROM app_property_overrides;`);
  console.log(`  ${po[0].n} rows`);
  if (Number(po[0].n) > 0) {
    const sample = await pg(`SELECT external_property_id, grease_trap_manhole_count, override_reason,
      created_at AT TIME ZONE 'America/New_York' AS created_et
      FROM app_property_overrides ORDER BY created_at DESC LIMIT 10;`);
    for (const r of sample) console.log(`    property=${r.external_property_id}  manholes=${r.grease_trap_manhole_count}  reason="${r.override_reason}"  created=${r.created_et}`);
  } else {
    console.log('  (no rows yet — manhole override hook not yet exercised)');
  }

  console.log('\n=== photo_links — confirm role column NOT mutated since Pattern B deployed ===');
  const recent = await pg(`SELECT role, COUNT(*) AS n FROM photo_links GROUP BY role ORDER BY n DESC LIMIT 20;`);
  console.log('role distribution (unchanged = clean):');
  for (const r of recent) console.log(`    ${r.role.padEnd(20)} ${r.n}`);
  const bad = recent.find(r => /^(before|after|completion|during|unknown)$/.test(r.role));
  console.log(bad ? `  ⚠ Found ${bad.role} in role column — Pattern A leak!` : '  ✓ No before/after/completion values in role column — Pattern A path closed');

  console.log('\n=== pg_stat: any recent UPDATEs on canonical writable tables? ===');
  const stat = await pg(`SELECT relname, n_tup_ins, n_tup_upd, n_tup_del
    FROM pg_stat_user_tables WHERE schemaname='public' AND relname IN ('photo_links','photos','properties','notes')
    ORDER BY relname;`);
  for (const r of stat) console.log(`    ${r.relname.padEnd(20)} ins=${r.n_tup_ins}  upd=${r.n_tup_upd}  del=${r.n_tup_del}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
