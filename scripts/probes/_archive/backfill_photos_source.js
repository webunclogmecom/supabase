// Backfill photos.source from storage_path for both Production and Sandbox.
//   visits/% or notes/%   → 'jobber'
//   airtable/%            → 'airtable'
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PAT = process.env.SUPABASE_PAT;
const TARGETS = [
  { label: 'PRODUCTION', projectId: process.env.SUPABASE_PROJECT_ID },
  { label: 'SANDBOX',    projectId: process.env.SANDBOX_SUPABASE_PROJECT_ID },
];

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

(async () => {
  for (const t of TARGETS) {
    if (!t.projectId) { console.log(`Skipping ${t.label} (no project ID)`); continue; }
    console.log(`\n=== ${t.label} (${t.projectId}) ===`);

    console.log('Before:');
    console.table(await q(t.projectId, `
      SELECT COALESCE(source,'(NULL)') AS source, COUNT(*)::text AS n
      FROM photos GROUP BY source ORDER BY source NULLS FIRST;
    `));

    await q(t.projectId, `
      UPDATE photos
      SET source = CASE
        WHEN storage_path LIKE 'visits/%'  THEN 'jobber'
        WHEN storage_path LIKE 'notes/%'   THEN 'jobber'
        WHEN storage_path LIKE 'airtable/%' THEN 'airtable'
        ELSE source
      END
      WHERE source IS NULL;
    `);

    console.log('After:');
    console.table(await q(t.projectId, `
      SELECT COALESCE(source,'(NULL)') AS source, COUNT(*)::text AS n
      FROM photos GROUP BY source ORDER BY source NULLS FIRST;
    `));

    // Spot-check: any storage_path patterns we missed?
    const stragglers = await q(t.projectId, `
      SELECT LEFT(storage_path, 30) AS prefix, COUNT(*)::text AS n
      FROM photos WHERE source IS NULL
      GROUP BY LEFT(storage_path, 30) ORDER BY n DESC LIMIT 5;
    `);
    if (stragglers.length) {
      console.log('  ⚠ remaining NULL-source photos by storage_path prefix:');
      console.table(stragglers);
    } else {
      console.log('  ✓ all photos now have source set');
    }
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
