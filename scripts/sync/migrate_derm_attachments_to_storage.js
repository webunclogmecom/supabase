// migrate_derm_attachments_to_storage.js
//
// One-shot: download every DERM Manifest + DERM Address attachment from
// Airtable-served URLs (which expire every ~2h) and upload to Supabase Storage
// on Prod. Replaces the AT URL in derm_manifests.{derm_manifest_url,
// derm_address_url} with the PERMANENT Supabase Storage URL.
//
// Bucket: 'GT - Visits Images' (existing public bucket, reused for DERM docs)
// Path:   derm/{manifest_id}/manifest.{ext}
//         derm/{manifest_id}/address.{ext}
//
// After this runs:
//   - derm_manifest_url / derm_address_url point at permanent Supabase URLs
//   - AT can re-rotate its signatures all day; doesn't affect customers
//   - Customer view (customer.work_orders) passes URLs through unchanged
//
// Usage:
//   node scripts/sync/migrate_derm_attachments_to_storage.js                   # full run
//   node scripts/sync/migrate_derm_attachments_to_storage.js --limit 3        # test with 3 rows first
//   node scripts/sync/migrate_derm_attachments_to_storage.js --resume         # skip rows already on Storage URLs

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const SBX1 = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const FP   = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;
const PAT  = process.env.SUPABASE_PAT;
const SUPABASE_URL = process.env.SUPABASE_URL;                          // https://wbasvhvvismukaqdnouk.supabase.co
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SUPABASE_HOST = new URL(SUPABASE_URL).hostname;

const BUCKET = 'GT - Visits Images';
const BUCKET_PATH = 'GT%20-%20Visits%20Images';                          // URL-encoded for Storage REST path
const PUBLIC_URL_BASE = `${SUPABASE_URL}/storage/v1/object/public/${BUCKET_PATH}`;

const CONCURRENCY = parseInt(process.env.MIGRATE_CONCURRENCY || '5');
const LIMIT = process.argv.includes('--limit') ? parseInt(process.argv[process.argv.indexOf('--limit')+1]) : null;
const RESUME = process.argv.includes('--resume');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({status: r.statusCode, body: Buffer.concat(c), headers: r.headers}));
    });
    req.on('error', rej);
    if (body) req.write(body);
    req.end();
  });
}
async function pg(sql, project) {
  const r = await http({
    hostname: 'api.supabase.com', path: `/v1/projects/${project}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${project} ${r.status}: ${r.body.toString().slice(0,400)}`);
  return JSON.parse(r.body.toString());
}

function downloadBytes(url) {
  return new Promise((res, rej) => {
    const u = new URL(url);
    https.get({ hostname: u.hostname, path: u.pathname + u.search }, r => {
      const chunks = [];
      r.on('data', c => chunks.push(c));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(chunks), contentType: r.headers['content-type'] }));
    }).on('error', rej);
  });
}

async function uploadToStorage(path, bytes, contentType) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: SUPABASE_HOST,
      path: `/storage/v1/object/${BUCKET_PATH}/${encodeURI(path)}`,
      method: 'POST',
      headers: {
        apikey: SERVICE_KEY,
        Authorization: `Bearer ${SERVICE_KEY}`,
        'Content-Type': contentType || 'image/jpeg',
        'Content-Length': bytes.length,
        'x-upsert': 'true',
      }
    }, r => { const c = []; r.on('data', x => c.push(x)); r.on('end', () => res({status: r.statusCode, body: Buffer.concat(c).toString()})); });
    req.on('error', rej);
    req.write(bytes);
    req.end();
  });
}

function extFromContentType(ct) {
  if (!ct) return 'jpg';
  if (ct.includes('png')) return 'png';
  if (ct.includes('pdf')) return 'pdf';
  if (ct.includes('webp')) return 'webp';
  if (ct.includes('jpeg') || ct.includes('jpg')) return 'jpg';
  return 'jpg';
}

async function migrateOne(row, col, fname) {
  const atUrl = row[col];
  if (!atUrl) return null;
  if (atUrl.startsWith(SUPABASE_URL)) return null; // already migrated
  const dl = await downloadBytes(atUrl);
  if (dl.status !== 200) throw new Error(`download ${dl.status}`);
  const ext = extFromContentType(dl.contentType);
  const path = `derm/${row.id}/${fname}.${ext}`;
  const up = await uploadToStorage(path, dl.body, dl.contentType);
  if (up.status >= 300) throw new Error(`upload ${up.status}: ${up.body.slice(0,100)}`);
  return `${PUBLIC_URL_BASE}/${encodeURI(path)}`;
}

(async () => {
  let where = `(derm_manifest_url IS NOT NULL OR derm_address_url IS NOT NULL)`;
  if (RESUME) {
    where += ` AND ((derm_manifest_url IS NOT NULL AND derm_manifest_url NOT LIKE '${SUPABASE_URL}%') OR (derm_address_url IS NOT NULL AND derm_address_url NOT LIKE '${SUPABASE_URL}%'))`;
  }
  const limitClause = LIMIT ? `LIMIT ${LIMIT}` : '';

  console.log(`Reading rows to migrate from Prod...`);
  const rows = await pg(`SELECT id, derm_manifest_url, derm_address_url FROM derm_manifests WHERE ${where} ORDER BY id ${limitClause};`, PROD);
  console.log(`  ${rows.length} rows to process`);
  console.log(`  concurrency: ${CONCURRENCY}, limit: ${LIMIT || 'none'}, resume: ${RESUME}`);

  const updates = [];
  let processed = 0, succ_m = 0, succ_a = 0, fail = 0;

  // Process in chunks of CONCURRENCY
  for (let i = 0; i < rows.length; i += CONCURRENCY) {
    const batch = rows.slice(i, i + CONCURRENCY);
    const results = await Promise.allSettled(batch.map(async row => {
      const out = { id: row.id, derm_manifest_url: row.derm_manifest_url, derm_address_url: row.derm_address_url, changed: false };
      try {
        const m = await migrateOne(row, 'derm_manifest_url', 'manifest');
        if (m) { out.derm_manifest_url = m; succ_m++; out.changed = true; }
      } catch (e) { console.warn(`  row ${row.id} manifest: FAIL ${e.message}`); fail++; }
      try {
        const a = await migrateOne(row, 'derm_address_url', 'address');
        if (a) { out.derm_address_url = a; succ_a++; out.changed = true; }
      } catch (e) { console.warn(`  row ${row.id} address: FAIL ${e.message}`); fail++; }
      return out;
    }));
    for (const r of results) if (r.status === 'fulfilled' && r.value.changed) updates.push(r.value);
    processed += batch.length;
    if (processed % 50 === 0 || processed === rows.length) {
      console.log(`  progress: ${processed}/${rows.length} rows | ${succ_m} manifests + ${succ_a} addresses uploaded | ${fail} failed`);
    }
  }

  console.log(`\nMigration result: ${updates.length} rows changed, ${succ_m + succ_a} files uploaded, ${fail} failures`);

  if (updates.length === 0) { console.log('Nothing to write back to DB.'); return; }

  console.log('\nWriting permanent Storage URLs back to DB on all 3 projects...');
  const values = updates.map(u => {
    const m = u.derm_manifest_url ? `'${u.derm_manifest_url.replace(/'/g, "''")}'` : 'NULL';
    const a = u.derm_address_url ? `'${u.derm_address_url.replace(/'/g, "''")}'` : 'NULL';
    return `(${u.id}, ${m}, ${a})`;
  }).join(',');
  const sql = `
    UPDATE derm_manifests dm
    SET derm_manifest_url = src.dm_url,
        derm_address_url = src.da_url
    FROM (VALUES ${values}) AS src(id, dm_url, da_url)
    WHERE dm.id = src.id;
  `;
  // Tolerate missing Sandbox / Field Portal env vars — the GH Actions cron
  // only carries the Prod secret. Local runs (Fred's machine) write to all 3.
  const targets = [['Prod', PROD], ['Sandbox #1', SBX1], ['Field Portal', FP]]
    .filter(([, id]) => id && id.length > 0);
  for (const [name, id] of targets) {
    await pg(sql, id);
    console.log(`  ${name}: written`);
  }

  console.log('\n=== Verify: visit 1619 manifest (Prod) ===');
  console.log(await pg(`SELECT id, white_manifest_number, derm_manifest_url, derm_address_url FROM derm_manifests WHERE id IN (SELECT manifest_id FROM manifest_visits WHERE visit_id = 1619);`, PROD));

  console.log('\n=== Coverage check across reachable DBs ===');
  for (const [name, id] of targets) {
    const r = await pg(`
      SELECT
        COUNT(*)::int AS total,
        COUNT(derm_manifest_url) FILTER (WHERE derm_manifest_url LIKE '${SUPABASE_URL}%')::int AS storage_manifest,
        COUNT(derm_manifest_url) FILTER (WHERE derm_manifest_url LIKE 'https://v5.airtableusercontent.com%')::int AS at_manifest,
        COUNT(derm_address_url)  FILTER (WHERE derm_address_url  LIKE '${SUPABASE_URL}%')::int AS storage_address,
        COUNT(derm_address_url)  FILTER (WHERE derm_address_url  LIKE 'https://v5.airtableusercontent.com%')::int AS at_address
      FROM derm_manifests;
    `, id);
    console.log(`  ${name}:`, r[0]);
  }
})().catch(e => { console.error('FATAL:', e); process.exit(2); });
