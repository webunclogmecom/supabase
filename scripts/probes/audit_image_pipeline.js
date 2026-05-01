// Audit image pipeline across Jobber / DERM / Inspections — and check that
// the Sandbox can read the same data.
//
// Usage:
//   node scripts/probes/audit_image_pipeline.js --target=main
//   node scripts/probes/audit_image_pipeline.js --target=sandbox
//   node scripts/probes/audit_image_pipeline.js --target=both
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const target = (process.argv.find(a => a.startsWith('--target=')) || '--target=both').split('=')[1];

const PROD = {
  label: 'PRODUCTION',
  projectId: process.env.SUPABASE_PROJECT_ID,
  url: process.env.SUPABASE_URL,
  serviceKey: process.env.SUPABASE_SERVICE_ROLE_KEY,
  anonKey: process.env.SUPABASE_ANON_KEY, // may be missing — fetched from mgmt API if needed
};
const SBX = {
  label: 'SANDBOX',
  projectId: process.env.SANDBOX_SUPABASE_PROJECT_ID,
  url: process.env.SANDBOX_SUPABASE_URL,
  serviceKey: process.env.SANDBOX_SUPABASE_SERVICE_ROLE_KEY,
  anonKey: process.env.SANDBOX_SUPABASE_ANON_KEY,
};

async function fetchAnonKey(projectId) {
  const r = await httpReq({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${projectId}/api-keys`,
    method: 'GET',
    headers: { Authorization: `Bearer ${PAT}` },
  });
  if (r.status >= 300) throw new Error(`api-keys fetch failed ${r.status}`);
  const keys = JSON.parse(r.body);
  const anon = keys.find(k => k.name === 'anon' || (k.type === 'legacy' && k.id === 'anon'));
  return anon?.api_key;
}
const PAT = process.env.SUPABASE_PAT;

function httpReq(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d }));
    });
    req.on('error', rej);
    req.setTimeout(30000, () => req.destroy(new Error('timeout')));
    if (body) req.write(body);
    req.end();
  });
}

async function pgQuery(env, sql) {
  const body = JSON.stringify({ query: sql });
  const r = await httpReq({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${env.projectId}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) throw new Error(`DB ${env.label} ${r.status}: ${r.body.slice(0, 400)}`);
  return JSON.parse(r.body);
}

// REST query via anon key — what a Lovable frontend would see
async function anonRestRead(env, table, query='select=*&limit=1') {
  const url = new URL(`${env.url}/rest/v1/${table}?${query}`);
  const r = await httpReq({
    hostname: url.hostname,
    path: url.pathname + url.search,
    method: 'GET',
    headers: {
      apikey: env.anonKey,
      Authorization: `Bearer ${env.anonKey}`,
    },
  });
  return { status: r.status, body: r.body.slice(0, 200) };
}

// HEAD a public-bucket storage URL — does the file exist?
async function checkStorageHead(env, bucket, path) {
  const url = new URL(`${env.url}/storage/v1/object/public/${encodeURIComponent(bucket)}/${path}`);
  const r = await httpReq({
    hostname: url.hostname,
    path: url.pathname,
    method: 'HEAD',
  });
  return { status: r.status, exists: r.status === 200 };
}

async function listStorageBuckets(env) {
  const url = new URL(`${env.url}/storage/v1/bucket`);
  const r = await httpReq({
    hostname: url.hostname,
    path: url.pathname,
    method: 'GET',
    headers: {
      apikey: env.serviceKey,
      Authorization: `Bearer ${env.serviceKey}`,
    },
  });
  if (r.status >= 300) return null;
  return JSON.parse(r.body);
}

async function auditOne(env) {
  console.log('\n' + '='.repeat(70));
  console.log(`AUDIT: ${env.label} (${env.projectId})`);
  console.log('='.repeat(70));

  // ---- 1. photo_links breakdown ----
  console.log('\n[1] photo_links by entity_type + role');
  console.table(await pgQuery(env, `
    SELECT entity_type, role, COUNT(*) AS n
    FROM photo_links GROUP BY entity_type, role ORDER BY entity_type, role;
  `));

  // ---- 2. photos by source / orphans ----
  console.log('\n[2] photos: total + by source + orphan check');
  console.table(await pgQuery(env, `
    SELECT
      'total photos' AS metric, COUNT(*)::text AS n FROM photos
    UNION ALL SELECT 'total photo_links', COUNT(*)::text FROM photo_links
    UNION ALL SELECT 'photos with no link (orphan)', COUNT(*)::text
      FROM photos p WHERE NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.photo_id=p.id)
    UNION ALL SELECT 'photos by source: jobber',  COUNT(*)::text FROM photos WHERE source='jobber'
    UNION ALL SELECT 'photos by source: airtable', COUNT(*)::text FROM photos WHERE source='airtable'
    UNION ALL SELECT 'photos by source: NULL',  COUNT(*)::text FROM photos WHERE source IS NULL
    UNION ALL SELECT 'photos with NULL storage_path', COUNT(*)::text FROM photos WHERE storage_path IS NULL OR storage_path='';
  `));

  // ---- 3. Sample storage paths per entity_type ----
  console.log('\n[3] Sample storage paths per entity_type');
  for (const et of ['visit', 'note', 'derm_manifest', 'inspection']) {
    const rows = await pgQuery(env, `
      SELECT pl.entity_type, pl.role, p.storage_path, p.file_name
      FROM photo_links pl JOIN photos p ON p.id=pl.photo_id
      WHERE pl.entity_type='${et}'
      ORDER BY p.id LIMIT 2;
    `);
    if (rows.length) {
      console.log(`  ${et}:`);
      rows.forEach(r => console.log(`    role=${r.role || '(null)'} → ${r.storage_path}`));
    } else {
      console.log(`  ${et}: NONE`);
    }
  }

  // ---- 4. Storage buckets ----
  console.log('\n[4] Storage buckets');
  const buckets = await listStorageBuckets(env);
  if (buckets) {
    console.table(buckets.map(b => ({ name: b.name, public: b.public, created_at: b.created_at })));
  } else {
    console.log('  (could not list buckets via service-role — Storage API may be restricted)');
  }

  // ---- 5. Spot-check: does a sample file actually exist in storage? ----
  console.log('\n[5] HEAD checks against storage URLs (does the binary exist?)');
  const samples = await pgQuery(env, `
    SELECT pl.entity_type, p.storage_path
    FROM photo_links pl JOIN photos p ON p.id=pl.photo_id
    WHERE p.storage_path IS NOT NULL
    GROUP BY pl.entity_type, p.storage_path
    ORDER BY pl.entity_type
    LIMIT 8;
  `);
  for (const s of samples) {
    const r = await checkStorageHead(env, 'GT - Visits Images', s.storage_path);
    console.log(`  [${s.entity_type}] ${s.storage_path.slice(0,80)} → HTTP ${r.status} ${r.exists ? '✓' : '✗ NOT FOUND'}`);
  }

  // ---- 6. Anon-key REST reads — what Lovable actually sees ----
  console.log('\n[6] Anon-key REST reads (what Lovable frontend can read without login)');
  for (const t of ['clients', 'visits', 'photos', 'photo_links', 'notes', 'derm_manifests', 'inspections', 'employees', 'vehicle_telemetry_readings']) {
    const r = await anonRestRead(env, t);
    let preview = r.body.slice(0, 60).replace(/\s+/g, ' ');
    const ok = r.status === 200;
    const empty = r.body === '[]';
    console.log(`  ${t.padEnd(28)} HTTP ${r.status}  ${ok ? (empty ? '⚠ empty' : '✓ ' + preview) : '✗ ' + preview}`);
  }
}

(async () => {
  if (target === 'main' || target === 'both') {
    if (!PROD.anonKey) PROD.anonKey = await fetchAnonKey(PROD.projectId);
    await auditOne(PROD);
  }
  if (target === 'sandbox' || target === 'both') {
    if (!SBX.anonKey) SBX.anonKey = await fetchAnonKey(SBX.projectId);
    await auditOne(SBX);
  }

  console.log('\n' + '='.repeat(70));
  console.log('Audit complete');
  console.log('='.repeat(70));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
