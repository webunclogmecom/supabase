// Catch Sandbox up to Production for photo-related canonical tables. Runs
// once now until the daily-refresh GitHub Action takes over.
//
// Tables synced: photos, photo_links, entity_source_links (entity_type='photo')
//
// Strategy: pull rows from Production that don't exist in Sandbox (by id /
// natural key), bulk-INSERT into Sandbox. Idempotent — re-running is safe.
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
  if (v instanceof Date) return "'" + v.toISOString() + "'";
  return "'" + String(v).replace(/'/g, "''") + "'";
};

async function syncTable({ table, columns, whereProd = '', whereSandboxExclude, batchSize = 200 }) {
  console.log(`\n[${table}] starting sync...`);

  // 1. List Sandbox-side IDs (or natural keys) we already have
  const sandboxIds = new Set();
  if (whereSandboxExclude) {
    const have = await q(SBX_PROJECT, whereSandboxExclude);
    for (const r of have) sandboxIds.add(String(r.k));
    console.log(`  Sandbox already has ${sandboxIds.size} rows`);
  }

  // 2. Fetch all Production rows
  const colsCsv = columns.join(', ');
  const prodRows = await q(PROD_PROJECT, `
    SELECT ${colsCsv} FROM ${table} ${whereProd ? `WHERE ${whereProd}` : ''} ORDER BY id;
  `);
  console.log(`  Production has ${prodRows.length} rows`);

  // 3. Diff
  const idCol = columns[0]; // assume first col is id (or composite key column we use as discriminator)
  const missing = prodRows.filter(r => !sandboxIds.has(String(r[idCol])));
  console.log(`  Missing from Sandbox: ${missing.length}`);
  if (!missing.length) return { synced: 0 };

  // 4. Bulk insert in batches
  let inserted = 0;
  for (let i = 0; i < missing.length; i += batchSize) {
    const batch = missing.slice(i, i + batchSize);
    const values = batch.map(row =>
      '(' + columns.map(c => escSqlVal(row[c])).join(', ') + ')'
    ).join(',\n  ');
    const sql = `
      INSERT INTO ${table} (${colsCsv}) VALUES
        ${values}
      ON CONFLICT (id) DO NOTHING;
    `;
    await q(SBX_PROJECT, sql);
    inserted += batch.length;
    if (inserted % 1000 === 0 || i + batchSize >= missing.length) {
      console.log(`  ...${inserted}/${missing.length}`);
    }
  }

  return { synced: inserted };
}

(async () => {
  console.log('Production → Sandbox photo sync');
  console.log('  PROD: ' + PROD_PROJECT);
  console.log('  SBX:  ' + SBX_PROJECT);

  // Snapshot before
  const before = await q(SBX_PROJECT, `
    SELECT 'photos' AS t, COUNT(*)::text AS n FROM photos
    UNION ALL SELECT 'photo_links', COUNT(*)::text FROM photo_links
    UNION ALL SELECT 'esl_photo', COUNT(*)::text FROM entity_source_links WHERE entity_type='photo';
  `);
  console.log('\nSandbox BEFORE:');
  console.table(before);

  // 1. photos
  const r1 = await syncTable({
    table: 'photos',
    columns: ['id', 'storage_path', 'thumbnail_path', 'file_name', 'content_type',
              'size_bytes', 'width_px', 'height_px', 'exif_taken_at', 'exif_latitude',
              'exif_longitude', 'exif_device', 'uploaded_by_employee_id', 'uploaded_at',
              'source', 'created_at'],
    whereSandboxExclude: `SELECT id AS k FROM photos`,
  });

  // 2. photo_links
  const r2 = await syncTable({
    table: 'photo_links',
    columns: ['id', 'photo_id', 'entity_type', 'entity_id', 'role', 'caption', 'created_at'],
    whereSandboxExclude: `SELECT id AS k FROM photo_links`,
  });

  // 3. entity_source_links for photos
  const r3 = await syncTable({
    table: 'entity_source_links',
    columns: ['id', 'entity_type', 'entity_id', 'source_system', 'source_id', 'created_at'],
    whereProd: `entity_type='photo'`,
    whereSandboxExclude: `SELECT id AS k FROM entity_source_links WHERE entity_type='photo'`,
  });

  // 4. Advance sequences past max(id)
  console.log('\n[sequences] advancing sequences past restored max(id)...');
  for (const t of ['photos', 'photo_links', 'entity_source_links']) {
    await q(SBX_PROJECT, `
      SELECT setval(pg_get_serial_sequence('public.${t}', 'id'),
                    COALESCE((SELECT MAX(id) FROM public.${t}), 1),
                    (SELECT MAX(id) FROM public.${t}) IS NOT NULL);
    `);
    console.log(`  ✓ ${t} sequence advanced`);
  }

  // Snapshot after
  const after = await q(SBX_PROJECT, `
    SELECT 'photos' AS t, COUNT(*)::text AS n FROM photos
    UNION ALL SELECT 'photo_links', COUNT(*)::text FROM photo_links
    UNION ALL SELECT 'esl_photo', COUNT(*)::text FROM entity_source_links WHERE entity_type='photo';
  `);
  console.log('\nSandbox AFTER:');
  console.table(after);

  console.log('\n=== Summary ===');
  console.log(`  photos synced:               ${r1.synced}`);
  console.log(`  photo_links synced:          ${r2.synced}`);
  console.log(`  entity_source_links synced:  ${r3.synced}`);

  // Confirm parity with Production
  const prodCounts = await q(PROD_PROJECT, `
    SELECT 'photos' AS t, COUNT(*)::text AS n FROM photos
    UNION ALL SELECT 'photo_links', COUNT(*)::text FROM photo_links
    UNION ALL SELECT 'esl_photo', COUNT(*)::text FROM entity_source_links WHERE entity_type='photo';
  `);
  console.log('\nProduction (for parity check):');
  console.table(prodCounts);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
