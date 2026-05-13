// Clean up orphaned storage objects in the GT - Visits Images bucket.
// After delete_pre_2026_notes_photos.js deleted DB rows but failed to delete
// storage objects (bulk endpoint Cloudflare-rejected for missing
// Content-Length), 4,120 orphans remain. Strategy:
//   1. List all storage objects under notes/ recursively.
//   2. For each, check if its photo_id is still in `photos` table.
//   3. If NOT present → orphan → DELETE via single-file API (proven path).
// Re-runnable: idempotent. Per-file DELETE retains a 200 even if already gone.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PAT = process.env.SUPABASE_PAT;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;
const BUCKET = 'GT - Visits Images';
const DRY = !process.argv.includes('--execute');
const PARALLEL = 16;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.setTimeout(60000, () => req.destroy(new Error('timeout')));
    if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROJECT}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 300)}`);
  return JSON.parse(r.body);
}

const supabaseHost = SUPABASE_URL.replace('https://', '');

// List one folder level (paginate with offset). Retries on transient 5xx.
async function listFolder(prefix) {
  const objects = [];
  let offset = 0;
  while (true) {
    const body = JSON.stringify({ prefix, limit: 1000, offset, sortBy: { column: 'name', order: 'asc' } });
    let r;
    for (let attempt = 1; attempt <= 5; attempt++) {
      try {
        r = await http({
          hostname: supabaseHost,
          path: `/storage/v1/object/list/${encodeURIComponent(BUCKET)}`,
          method: 'POST',
          headers: {
            Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY,
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(body)
          }
        }, body);
        if (r.status < 300) break;
        if (r.status >= 500 && attempt < 5) {
          await new Promise(rs => setTimeout(rs, 2000 * attempt));
          continue;
        }
        throw new Error(`list ${r.status}: ${r.body.slice(0, 200)}`);
      } catch (e) {
        if (attempt < 5) { await new Promise(rs => setTimeout(rs, 2000 * attempt)); continue; }
        throw e;
      }
    }
    const page = JSON.parse(r.body);
    for (const o of page) objects.push(o);
    if (page.length < 1000) break;
    offset += page.length;
  }
  return objects;
}

// Recursively walk the entire bucket, return all leaf object paths
async function listAll(prefix = '') {
  const out = [];
  const stack = [prefix];
  while (stack.length) {
    const cur = stack.shift();
    const entries = await listFolder(cur);
    for (const e of entries) {
      // Folders have id=null in supabase storage list
      if (e.id === null) {
        const sub = cur ? `${cur}/${e.name}` : e.name;
        stack.push(sub);
      } else {
        const path = cur ? `${cur}/${e.name}` : e.name;
        out.push(path);
      }
    }
  }
  return out;
}

async function deleteOne(path) {
  const encoded = path.split('/').map(encodeURIComponent).join('/');
  const r = await http({
    hostname: supabaseHost,
    path: `/storage/v1/object/${encodeURIComponent(BUCKET)}/${encoded}`,
    method: 'DELETE',
    headers: { Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY }
  });
  return r.status;
}

(async () => {
  console.log(`=== ${DRY ? 'DRY-RUN' : 'EXECUTE'}: clean orphaned storage objects ===`);

  console.log('[1/3] Listing bucket recursively...');
  const allPaths = await listAll('notes');
  console.log(`  ${allPaths.length} objects under notes/`);

  console.log('[2/3] Cross-checking against photos table...');
  // Insert paths into a temp table for SQL diff; or do batched IN-list checks.
  // The DB has ~6K photos remaining; we have ~10K storage objects. Pull all
  // remaining storage_paths from DB once, then diff in JS.
  const dbRows = await pg(`SELECT storage_path FROM photos WHERE storage_path IS NOT NULL`);
  const dbSet = new Set(dbRows.map(r => r.storage_path));
  const orphans = allPaths.filter(p => !dbSet.has(p));
  console.log(`  ${dbSet.size} paths in photos table`);
  console.log(`  ${orphans.length} orphaned storage objects`);

  if (DRY) {
    console.log('\nSample orphans:');
    for (const p of orphans.slice(0, 10)) console.log(`  ${p}`);
    console.log(`  ...and ${Math.max(0, orphans.length - 10)} more`);
    console.log('\nRe-run with --execute to delete.');
    process.exit(0);
  }

  console.log(`[3/3] Deleting ${orphans.length} orphans (parallel=${PARALLEL})...`);
  let done = 0, failed = 0;
  for (let i = 0; i < orphans.length; i += PARALLEL) {
    const batch = orphans.slice(i, i + PARALLEL);
    const results = await Promise.allSettled(batch.map(deleteOne));
    for (const r of results) {
      if (r.status === 'fulfilled' && r.value < 300) done++;
      else failed++;
    }
    if (i % (PARALLEL * 25) === 0) {
      process.stdout.write(`  ${done}/${orphans.length} done (${failed} failed)\r`);
    }
  }
  console.log(`\n✅ Storage cleanup: ${done} deleted, ${failed} failed`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
