// ============================================================================
// airtable_derm_attachments.js — migrate Airtable DERM table images
// ============================================================================
//
// Per Fred 2026-04-30: pull `DERM Manifest` and `DERM Address` attachment
// fields from each Airtable DERM record, store in our unified photos +
// photo_links architecture (ADR 009).
//
// Source-of-truth: Airtable is the canonical source for DERM data
// (see ADR 011 — trust hierarchy). Each Airtable DERM row gets its own
// attachments — no dedup by White Manifest # (Diego enters them per row;
// we mirror as-is per Fred's "take it as it is" guidance).
//
// Idempotency:
//   - photos.storage_path is unique → ON CONFLICT DO UPDATE (no-op)
//   - entity_source_links (entity_type='photo', source_system='airtable',
//     source_id=att.id) → ON CONFLICT DO NOTHING. Skip-if-exists check
//     before download to save bandwidth.
//
// Storage layout:
//   airtable/derm/{derm_manifest_id}/manifest_{att.id}.{ext}
//   airtable/derm/{derm_manifest_id}/address_{att.id}.{ext}
//
// CLI:
//   node scripts/migrate/airtable_derm_attachments.js --dry-run
//   node scripts/migrate/airtable_derm_attachments.js --execute
//   node scripts/migrate/airtable_derm_attachments.js --execute --limit 10
// ============================================================================

const https = require('https');
const fs = require('fs');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') }); } catch (_) {}

const args = process.argv.slice(2);
const DRY_RUN = !args.includes('--execute');
const LIMIT_ARG = args.find(a => a.startsWith('--limit='));
const LIMIT = LIMIT_ARG ? parseInt(LIMIT_ARG.split('=')[1]) : null;

const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SUPABASE_PAT = process.env.SUPABASE_PAT;
const SUPABASE_PROJECT_ID = process.env.SUPABASE_PROJECT_ID;
const STORAGE_BUCKET = 'GT - Visits Images';  // same bucket Jobber migration uses

if (!AT_KEY || !AT_BASE) throw new Error('AIRTABLE_API_KEY and AIRTABLE_BASE_ID required');
if (!SUPABASE_URL || !SERVICE_KEY) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY required');
if (!SUPABASE_PAT || !SUPABASE_PROJECT_ID) throw new Error('SUPABASE_PAT and SUPABASE_PROJECT_ID required');

console.log('='.repeat(60));
console.log('airtable_derm_attachments.js');
console.log('  Mode:  ' + (DRY_RUN ? 'DRY-RUN' : 'EXECUTE'));
console.log('  Limit: ' + (LIMIT || 'none'));
console.log('  Bucket: ' + STORAGE_BUCKET);
console.log('='.repeat(60));

// ---- HTTP ----------------------------------------------------------------

function httpRequest(opts, body, timeoutMs = 60000) {
  return new Promise((resolve, reject) => {
    const req = https.request(opts, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
    });
    req.setTimeout(timeoutMs, () => req.destroy(new Error(`timeout after ${timeoutMs}ms`)));
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function airtableFetchAll(tableName) {
  const all = [];
  let offset = null, pages = 0;
  do {
    const q = new URLSearchParams();
    q.set('pageSize', '100');
    if (offset) q.set('offset', offset);
    const r = await httpRequest({
      hostname: 'api.airtable.com',
      path: `/v0/${AT_BASE}/${encodeURIComponent(tableName)}?${q}`,
      headers: { Authorization: `Bearer ${AT_KEY}` },
    });
    if (r.status >= 300) throw new Error(`Airtable ${tableName} HTTP ${r.status}: ${r.body.toString().slice(0, 200)}`);
    const j = JSON.parse(r.body.toString());
    all.push(...(j.records || []));
    offset = j.offset;
    pages++;
    if (pages > 50) break;
  } while (offset);
  return all;
}

async function downloadFromUrl(url) {
  const u = new URL(url);
  const r = await httpRequest({ hostname: u.hostname, path: u.pathname + u.search, method: 'GET' }, null, 120000);
  if (r.status >= 300) throw new Error(`Download HTTP ${r.status}`);
  return r.body;
}

async function sbStorageUpload(bucketName, objectPath, bodyBuffer, contentType) {
  const supabaseHost = SUPABASE_URL.replace('https://', '');
  const encodedPath = encodeURIComponent(bucketName) + '/' + objectPath
    .split('/').map(encodeURIComponent).join('/');
  const r = await httpRequest({
    hostname: supabaseHost,
    path: '/storage/v1/object/' + encodedPath,
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + SERVICE_KEY,
      apikey: SERVICE_KEY,
      'Content-Type': contentType || 'application/octet-stream',
      'Content-Length': bodyBuffer.length,
      'x-upsert': 'true',
    },
  }, bodyBuffer);
  if (r.status >= 300) throw new Error(`Storage upload HTTP ${r.status}: ${r.body.toString().slice(0, 200)}`);
  return r.body.toString();
}

async function sbQuery(sql) {
  const body = JSON.stringify({ query: sql });
  const r = await httpRequest({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: {
      Authorization: `Bearer ${SUPABASE_PAT}`,
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    },
  }, body);
  if (r.status >= 300) throw new Error(`DB HTTP ${r.status}: ${r.body.toString().slice(0, 300)}`);
  return JSON.parse(r.body.toString());
}

function sqlEscape(v) {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'number') return String(v);
  if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE';
  return "'" + String(v).replace(/'/g, "''") + "'";
}

function extFromContentType(ct, fallbackName) {
  const map = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/heic': 'heic', 'image/webp': 'webp', 'application/pdf': 'pdf' };
  if (ct && map[ct.toLowerCase()]) return map[ct.toLowerCase()];
  if (fallbackName && fallbackName.includes('.')) return fallbackName.split('.').pop().toLowerCase().slice(0, 5);
  return 'bin';
}

// ---- Main ---------------------------------------------------------------

(async () => {
  const stats = {
    derm_records_total: 0,
    derm_records_resolved: 0,
    derm_records_unresolved: 0,
    attachments_seen: 0,
    attachments_skipped_already: 0,
    attachments_uploaded: 0,
    attachments_failed: 0,
    photos_inserted: 0,
    photo_links_inserted: 0,
  };
  const errors = [];

  console.log('\n[1/3] Loading Airtable→our derm_manifest ID map...');
  // Pre-fetch all Airtable DERM ESL rows in one query
  const eslRows = await sbQuery(`
    SELECT entity_id, source_id
    FROM entity_source_links
    WHERE entity_type='derm_manifest' AND source_system='airtable';
  `);
  const dermIdMap = new Map();
  for (const row of eslRows) dermIdMap.set(row.source_id, row.entity_id);
  console.log(`  ${dermIdMap.size} derm_manifest ESL rows loaded`);

  console.log('\n[2/3] Pulling Airtable DERM records...');
  let dermRecords = await airtableFetchAll('DERM');
  console.log(`  ${dermRecords.length} DERM records pulled from Airtable`);
  if (LIMIT) {
    dermRecords = dermRecords.slice(0, LIMIT);
    console.log(`  --limit applied: processing first ${dermRecords.length}`);
  }
  stats.derm_records_total = dermRecords.length;

  console.log('\n[3/3] Processing attachments...');

  // Pre-fetch existing photo ESL source_ids to skip already-migrated attachments
  const existingPhotoIds = new Set();
  const existingRows = await sbQuery(`
    SELECT source_id FROM entity_source_links
    WHERE entity_type='photo' AND source_system='airtable';
  `);
  for (const r of existingRows) existingPhotoIds.add(r.source_id);
  console.log(`  ${existingPhotoIds.size} Airtable-source photos already migrated (will skip)`);

  for (let i = 0; i < dermRecords.length; i++) {
    const rec = dermRecords[i];
    const f = rec.fields || {};

    const ourDermId = dermIdMap.get(rec.id);
    if (!ourDermId) {
      stats.derm_records_unresolved++;
      if (stats.derm_records_unresolved <= 5) {
        console.log(`  [${i + 1}] ${rec.id} — no derm_manifest in our DB, skipping`);
      }
      continue;
    }
    stats.derm_records_resolved++;

    // Process two attachment fields
    const attachmentFields = [
      { field: 'DERM Manifest', role: 'manifest' },
      { field: 'DERM Address',  role: 'address' },
    ];

    for (const { field, role } of attachmentFields) {
      const atts = f[field];
      if (!Array.isArray(atts) || atts.length === 0) continue;

      for (const att of atts) {
        if (!att.url || !att.id) continue;
        stats.attachments_seen++;

        if (existingPhotoIds.has(att.id)) {
          stats.attachments_skipped_already++;
          continue;
        }

        const ext = extFromContentType(att.type, att.filename);
        const storagePath = `airtable/derm/${ourDermId}/${role}_${att.id}.${ext}`;

        if (DRY_RUN) {
          console.log(`  [${i + 1}/${dermRecords.length}] would upload ${role} for derm_manifest=${ourDermId}: ${att.filename} (${att.size} bytes) → ${storagePath}`);
          continue;
        }

        try {
          const buf = await downloadFromUrl(att.url);
          await sbStorageUpload(STORAGE_BUCKET, storagePath, buf, att.type);
          stats.attachments_uploaded++;

          // Insert photo + photo_link + ESL atomically
          const sql = `
            BEGIN;
            WITH p AS (
              INSERT INTO photos (storage_path, file_name, content_type, size_bytes, source, uploaded_at)
              VALUES (
                ${sqlEscape(storagePath)},
                ${sqlEscape(att.filename)},
                ${sqlEscape(att.type)},
                ${sqlEscape(att.size)},
                'airtable_migration',
                now()
              )
              ON CONFLICT (storage_path) DO UPDATE SET storage_path = EXCLUDED.storage_path
              RETURNING id
            ),
            link_ins AS (
              INSERT INTO photo_links (photo_id, entity_type, entity_id, role, caption)
              SELECT p.id, 'derm_manifest', ${ourDermId}, ${sqlEscape(role)}, NULL
              FROM p
              ON CONFLICT (photo_id, entity_type, entity_id, role) DO NOTHING
            )
            INSERT INTO entity_source_links (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence, synced_at)
            SELECT 'photo', p.id, 'airtable', ${sqlEscape(att.id)}, ${sqlEscape(att.filename)}, 'api_pull', 1.00, now()
            FROM p
            ON CONFLICT (entity_type, source_system, source_id) DO NOTHING;
            COMMIT;
          `;
          await sbQuery(sql);
          existingPhotoIds.add(att.id); // mark as done for this run
          stats.photos_inserted++;
          stats.photo_links_inserted++;
        } catch (e) {
          stats.attachments_failed++;
          errors.push({ derm_record: rec.id, role, att: att.id, error: e.message.slice(0, 200) });
          console.log(`    [fail] ${role} ${att.id}: ${e.message.slice(0, 120)}`);
        }
      }
    }

    if ((i + 1) % 50 === 0) {
      console.log(`  [${i + 1}/${dermRecords.length}] running totals: ${stats.attachments_uploaded} uploaded, ${stats.attachments_skipped_already} skipped, ${stats.attachments_failed} failed`);
    }
  }

  console.log('\n' + '='.repeat(60));
  console.log('SUMMARY');
  console.log('='.repeat(60));
  for (const [k, v] of Object.entries(stats)) console.log('  ' + k.padEnd(28) + ': ' + v);
  if (errors.length) {
    console.log(`\nErrors (${errors.length}):`);
    for (const e of errors.slice(0, 10)) console.log('  ' + JSON.stringify(e));
    if (errors.length > 10) console.log(`  ... ${errors.length - 10} more`);
  }
  process.exit(errors.length ? 2 : 0);
})().catch(e => {
  console.error('\nFATAL:', e.message);
  console.error(e.stack);
  process.exit(1);
});
