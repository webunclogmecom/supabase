// Finish the photo ESL sync (entity_source_links has id GENERATED ALWAYS, so
// we have to insert WITHOUT id and rely on the natural-key conflict resolver).
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD_PROJECT = process.env.SUPABASE_PROJECT_ID;
const SBX_PROJECT  = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT          = process.env.SUPABASE_PAT;

function q(projectId, sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${projectId}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

const escSqlVal = v => {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : 'NULL';
  if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE';
  return "'" + String(v).replace(/'/g, "''") + "'";
};

(async () => {
  // Sandbox photo ESL keys we already have (natural key)
  const have = await q(SBX_PROJECT, `
    SELECT entity_type || '|' || source_system || '|' || source_id AS k
    FROM entity_source_links WHERE entity_type='photo';
  `);
  const haveSet = new Set(have.map(r => r.k));
  console.log(`Sandbox already has ${haveSet.size} photo ESL rows`);

  // Production photo ESLs
  const prodRows = await q(PROD_PROJECT, `
    SELECT entity_type, entity_id, source_system, source_id, created_at
    FROM entity_source_links WHERE entity_type='photo' ORDER BY id;
  `);
  console.log(`Production has ${prodRows.length} photo ESLs`);

  const missing = prodRows.filter(r =>
    !haveSet.has(`${r.entity_type}|${r.source_system}|${r.source_id}`)
  );
  console.log(`Missing: ${missing.length}`);

  const batchSize = 200;
  let inserted = 0;
  for (let i = 0; i < missing.length; i += batchSize) {
    const batch = missing.slice(i, i + batchSize);
    const values = batch.map(r =>
      `(${escSqlVal(r.entity_type)}, ${escSqlVal(r.entity_id)}, ${escSqlVal(r.source_system)}, ${escSqlVal(r.source_id)}, ${escSqlVal(r.created_at)})`
    ).join(',\n  ');
    await q(SBX_PROJECT, `
      INSERT INTO entity_source_links (entity_type, entity_id, source_system, source_id, created_at)
      VALUES ${values}
      ON CONFLICT (entity_type, source_system, source_id) DO NOTHING;
    `);
    inserted += batch.length;
    if (inserted % 1000 === 0 || i + batchSize >= missing.length) {
      console.log(`  ...${inserted}/${missing.length}`);
    }
  }

  // Final counts
  console.log('\nFinal Sandbox state:');
  console.table(await q(SBX_PROJECT, `
    SELECT 'photos' AS t, COUNT(*)::text AS n FROM photos
    UNION ALL SELECT 'photo_links', COUNT(*)::text FROM photo_links
    UNION ALL SELECT 'esl_photo', COUNT(*)::text FROM entity_source_links WHERE entity_type='photo';
  `));

  console.log('Production for parity:');
  console.table(await q(PROD_PROJECT, `
    SELECT 'photos' AS t, COUNT(*)::text AS n FROM photos
    UNION ALL SELECT 'photo_links', COUNT(*)::text FROM photo_links
    UNION ALL SELECT 'esl_photo', COUNT(*)::text FROM entity_source_links WHERE entity_type='photo';
  `));

  // Check inspection coverage on Sandbox
  console.log('\nSandbox inspection photo_links:');
  console.table(await q(SBX_PROJECT, `
    SELECT entity_type, role, COUNT(*) AS n
    FROM photo_links WHERE entity_type='inspection'
    GROUP BY entity_type, role ORDER BY role;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
