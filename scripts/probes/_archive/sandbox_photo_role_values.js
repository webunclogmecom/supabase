// Peek at photo_links.role values + entity_type breakdown to see if there's any
// before/after taxonomy hiding in there.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
function pg(sql, projectId) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${projectId}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({status: x.statusCode, body: b})); });
    req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
  });
}

(async () => {
  console.log('=== photo_links.role distribution (Sandbox) ===');
  const r1 = JSON.parse((await pg(`
    SELECT role, COUNT(*) AS n
    FROM photo_links GROUP BY role ORDER BY n DESC NULLS LAST;`, SBX)).body);
  console.log(JSON.stringify(r1, null, 2));

  console.log('\n=== photo_links.entity_type distribution ===');
  const r2 = JSON.parse((await pg(`
    SELECT entity_type, COUNT(*) AS n
    FROM photo_links GROUP BY entity_type ORDER BY n DESC;`, SBX)).body);
  console.log(JSON.stringify(r2, null, 2));

  console.log('\n=== photo_links.caption sample (looking for "before"/"after" mentions) ===');
  const r3 = JSON.parse((await pg(`
    SELECT entity_type, role, caption, COUNT(*) OVER() AS total_matches
    FROM photo_links
    WHERE caption ~* '\\m(before|after|pre|post)\\M'
    LIMIT 15;`, SBX)).body);
  console.log(`Captions containing before/after/pre/post: ${r3.length ? r3[0].total_matches : 0}`);
  console.log(JSON.stringify(r3, null, 2));

  console.log('\n=== app_visit_reviews sample (Sandbox has 2 rows) ===');
  const r4 = JSON.parse((await pg(`SELECT * FROM app_visit_reviews ORDER BY created_at DESC LIMIT 5;`, SBX)).body);
  console.log(JSON.stringify(r4, null, 2));

  console.log('\n=== Any indexes/constraints on photo_links suggesting classification logic? ===');
  const r5 = JSON.parse((await pg(`
    SELECT indexname, indexdef FROM pg_indexes
    WHERE schemaname='public' AND tablename='photo_links';`, SBX)).body);
  console.log(JSON.stringify(r5, null, 2));
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
