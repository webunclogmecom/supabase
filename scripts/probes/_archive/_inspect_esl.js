require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const r = (project, sql) => new Promise((res, rej) => {
  const req = https.request({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${project}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(JSON.parse(b))); });
  req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
});
(async () => {
  const PROD = process.env.SUPABASE_PROJECT_ID;
  const SB = process.env.SANDBOX_SUPABASE_PROJECT_ID;
  const cols = await r(PROD, `SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='entity_source_links' ORDER BY ordinal_position`);
  console.log('entity_source_links cols:'); for (const c of cols) console.log(`  ${c.column_name} ${c.data_type}`);
  const sample = await r(PROD, `SELECT entity_type, source_system, source_id, entity_id FROM entity_source_links WHERE entity_type='visit' AND source_system='jobber' LIMIT 3`);
  console.log('\nsample visit ESLs:'); for (const s of sample) console.log(`  ${s.entity_type}/${s.source_system}: source_id=${s.source_id} → entity_id=${s.entity_id}`);
  const employee = await r(PROD, `SELECT entity_type, source_system, source_id, entity_id FROM entity_source_links WHERE entity_type='employee' LIMIT 8`);
  console.log('\nsample employee ESLs:'); for (const s of employee) console.log(`  ${s.entity_type}/${s.source_system}: source_id=${s.source_id} → entity_id=${s.entity_id}`);
  // What's the test row 1610 in Sandbox map to externally?
  const tr = await r(SB, `SELECT v.id, v.review_status, v.bonus_status, v.reviewed_by, v.bonus_decided_by, esl.source_system, esl.source_id FROM visits v LEFT JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id = v.id WHERE v.id = 1610 OR v.review_status <> 'pending' OR v.bonus_status <> 'pending' LIMIT 5`);
  console.log('\nsandbox test rows:'); for (const t of tr) console.log(`  visit ${t.id}: review=${t.review_status} bonus=${t.bonus_status} reviewed_by=${t.reviewed_by} bonus_decided_by=${t.bonus_decided_by} esl=${t.source_system}:${t.source_id}`);
}) ().catch(e => { console.error(e.message); process.exit(2); });
