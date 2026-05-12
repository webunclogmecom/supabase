// Verify sandbox-side photo paths resolve when fetched from Production bucket.
// (Sandbox has metadata, Production has the actual binary files.)
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const SANDBOX_PROJECT_ID = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function head(host, p) {
  return new Promise(res => {
    https.request({ hostname: host, path: p, method: 'HEAD' }, r => res(r.statusCode))
      .on('error', () => res(0)).end();
  });
}

function pgQuery(projectId, sql) {
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
  const rows = await pgQuery(SANDBOX_PROJECT_ID, `
    SELECT pl.entity_type, p.storage_path
    FROM photo_links pl JOIN photos p ON p.id=pl.photo_id
    GROUP BY pl.entity_type, p.storage_path
    ORDER BY pl.entity_type LIMIT 6;
  `);

  console.log('\nSandbox-derived paths tested against BOTH Production and Sandbox storage buckets:\n');
  for (const row of rows) {
    const enc = row.storage_path.split('/').map(encodeURIComponent).join('/');
    const p = `/storage/v1/object/public/GT%20-%20Visits%20Images/${enc}`;
    const prodStatus = await head('wbasvhvvismukaqdnouk.supabase.co', p);
    const sbxStatus  = await head('ubtlwpcyntelgbykdatn.supabase.co', p);
    console.log(`[${row.entity_type}] ${row.storage_path.slice(0,55)}...`);
    console.log(`  Production bucket → HTTP ${prodStatus} ${prodStatus===200?'✓':'✗'}`);
    console.log(`  Sandbox bucket    → HTTP ${sbxStatus} ${sbxStatus===200?'✓':'✗'}`);
    console.log();
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
