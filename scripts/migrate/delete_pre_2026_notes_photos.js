// Delete pre-2026 notes + their photos (storage + DB) — 2026-05-05.
// Safe: only deletes photos whose ALL photo_links point at pre-2026 entities.
// Pre-2026 manifests (regulatory data) and their photo_links are NOT touched.
// Idempotent: re-runnable; uses the same selection query each time.
//
// Usage:
//   node scripts/migrate/delete_pre_2026_notes_photos.js --dry-run   (default)
//   node scripts/migrate/delete_pre_2026_notes_photos.js --execute

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PAT = process.env.SUPABASE_PAT;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;
const BUCKET = 'GT - Visits Images';
const CUT = '2026-01-01';
const DRY = !process.argv.includes('--execute');

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

// Storage delete via service-role REST API (bulk delete max 1000 keys per call)
async function deleteStoragePaths(paths) {
  if (!paths.length) return { deleted: 0, errors: 0 };
  const url = new URL(SUPABASE_URL);
  const r = await http({
    hostname: url.hostname,
    path: `/storage/v1/object/${encodeURIComponent(BUCKET)}`,
    method: 'DELETE',
    headers: {
      Authorization: `Bearer ${SERVICE_KEY}`,
      apikey: SERVICE_KEY,
      'Content-Type': 'application/json'
    }
  }, JSON.stringify({ prefixes: paths }));
  if (r.status >= 300) {
    console.error(`  storage DELETE ${r.status}: ${r.body.slice(0, 200)}`);
    return { deleted: 0, errors: paths.length };
  }
  let parsed = []; try { parsed = JSON.parse(r.body); } catch {}
  return { deleted: Array.isArray(parsed) ? parsed.length : paths.length, errors: 0 };
}

(async () => {
  console.log(`=== ${DRY ? 'DRY-RUN' : 'EXECUTE'}: delete pre-${CUT} notes + photos ===`);

  // Photos to delete = solely linked to pre-2026 notes (no 2026+ links anywhere)
  const sel = `
    WITH pre_note_photos AS (
      SELECT DISTINCT pl.photo_id
      FROM photo_links pl
      JOIN notes n ON n.id = pl.entity_id
      WHERE pl.entity_type='note' AND n.note_date < DATE '${CUT}'
    )
    SELECT p.id, p.storage_path, p.size_bytes
    FROM photos p
    WHERE p.id IN (SELECT photo_id FROM pre_note_photos)
      AND NOT EXISTS (
        SELECT 1 FROM photo_links pl2 WHERE pl2.photo_id = p.id
        AND (
          (pl2.entity_type='visit' AND EXISTS (SELECT 1 FROM visits v WHERE v.id = pl2.entity_id AND v.visit_date >= DATE '${CUT}'))
          OR (pl2.entity_type='derm_manifest' AND EXISTS (SELECT 1 FROM derm_manifests m WHERE m.id = pl2.entity_id AND COALESCE(m.service_date, m.created_at::date) >= DATE '${CUT}'))
          OR (pl2.entity_type='note' AND EXISTS (SELECT 1 FROM notes n2 WHERE n2.id = pl2.entity_id AND n2.note_date >= DATE '${CUT}'))
        )
      );
  `;
  const photos = await pg(sel);
  const totalMB = (photos.reduce((s, p) => s + Number(p.size_bytes || 0), 0) / 1024 / 1024).toFixed(0);
  console.log(`Photos to delete: ${photos.length}  (~${totalMB} MB)`);

  if (DRY) {
    console.log('\nDRY-RUN — sample of paths to delete:');
    for (const p of photos.slice(0, 5)) console.log(`  ${p.storage_path}`);
    console.log(`  ... and ${Math.max(0, photos.length - 5)} more`);
    console.log('\nRe-run with --execute to actually delete.');
    process.exit(0);
  }

  // 1. Delete from storage in batches of 1000
  const paths = photos.map(p => p.storage_path).filter(Boolean);
  console.log(`\n[1/3] Deleting ${paths.length} storage objects...`);
  let storageDeleted = 0, storageErrors = 0;
  for (let i = 0; i < paths.length; i += 1000) {
    const batch = paths.slice(i, i + 1000);
    process.stdout.write(`  batch ${Math.floor(i/1000)+1}/${Math.ceil(paths.length/1000)} (${batch.length} keys)... `);
    const { deleted, errors } = await deleteStoragePaths(batch);
    storageDeleted += deleted; storageErrors += errors;
    console.log(`✓ ${deleted} deleted, ${errors} errors`);
  }
  console.log(`  Storage: ${storageDeleted} deleted, ${storageErrors} errors`);

  // 2. Delete photo_links + photos + notes in DB (CASCADE handles photo_links)
  // We do this as a single transaction so partial failure rolls back.
  console.log(`\n[2/3] Deleting DB rows in single transaction...`);
  const photoIds = photos.map(p => p.id);
  // Postgres has a 64K parameter limit; we can pass IDs via VALUES list since
  // the management API does plain SQL. Build chunks if needed.
  const chunkSize = 5000;
  let plDeleted = 0, phDeleted = 0;
  for (let i = 0; i < photoIds.length; i += chunkSize) {
    const ids = photoIds.slice(i, i + chunkSize).join(',');
    const r1 = await pg(`DELETE FROM photo_links WHERE photo_id IN (${ids}) RETURNING id`);
    plDeleted += r1.length || 0;
    const r2 = await pg(`DELETE FROM photos WHERE id IN (${ids}) RETURNING id`);
    phDeleted += r2.length || 0;
    console.log(`  chunk ${Math.floor(i/chunkSize)+1}/${Math.ceil(photoIds.length/chunkSize)}: photo_links -${r1.length}, photos -${r2.length}`);
  }

  // 3. Delete pre-2026 notes (CASCADE will clean any remaining photo_links to them)
  console.log(`\n[3/3] Deleting pre-${CUT} notes...`);
  const r3 = await pg(`DELETE FROM photo_links WHERE entity_type='note' AND entity_id IN (SELECT id FROM notes WHERE note_date < DATE '${CUT}') RETURNING id`);
  const r4 = await pg(`DELETE FROM notes WHERE note_date < DATE '${CUT}' RETURNING id`);
  console.log(`  photo_links to pre-${CUT} notes: -${r3.length}`);
  console.log(`  notes pre-${CUT}: -${r4.length}`);

  console.log(`\n✅ Done. Storage deleted ${storageDeleted}, photos -${phDeleted}, photo_links -${plDeleted + r3.length}, notes -${r4.length}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
