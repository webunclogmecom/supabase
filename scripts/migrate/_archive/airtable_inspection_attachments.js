// ============================================================================
// airtable_inspection_attachments.js — migrate Airtable PRE-POST inspection
// images into Production storage + photos/photo_links.
// ============================================================================
//
// Source-of-truth: Airtable PRE-POST insptection table (sic — typo is real).
// Each record corresponds to one inspection in our `inspections` table,
// linked via entity_source_links (entity_type='inspection', source_system=
// 'airtable').
//
// Attachment fields (all per-record evidence photos):
//   "Back Pic", "Front  Pic" (sic, double space), "Cabin Pic",
//   "Right Side Pic", "Left Side Pic", "Dashboard Pic",
//   "Cabin Side left", "Cabin Side right copy",
//   "Closed Valve", "Remote Pic",
//   "Level Sludge Pic", "Level Water PIC",
//   "Issue pictures",
//   "Expense Receipt",
//   "DERM manifest", "DERM Adress manifest"
//
// Storage path:  airtable/inspection/{our_inspection_id}/{role}_{att.id}.{ext}
//
// Idempotency:
//   - photos.storage_path UNIQUE (so re-upload is no-op)
//   - entity_source_links(entity_type='photo', source_system='airtable',
//     source_id=att.id) — lookup → if exists, just create/upsert the
//     photo_link without re-downloading
//   - photo_links(photo_id, entity_type, entity_id, role) UNIQUE
//
// CLI:
//   node scripts/migrate/airtable_inspection_attachments.js --dry-run
//   node scripts/migrate/airtable_inspection_attachments.js --execute
//   node scripts/migrate/airtable_inspection_attachments.js --execute --limit=5
//   node scripts/migrate/airtable_inspection_attachments.js --execute --resume
// ============================================================================

const https = require('https');
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
const STORAGE_BUCKET = 'GT - Visits Images';
const TABLE = 'PRE-POST insptection';

if (!AT_KEY || !AT_BASE) throw new Error('AIRTABLE_API_KEY/BASE_ID required');
if (!SUPABASE_URL || !SERVICE_KEY) throw new Error('SUPABASE creds required');
if (!SUPABASE_PAT || !SUPABASE_PROJECT_ID) throw new Error('SUPABASE_PAT/PROJECT_ID required');

// (airtable field name) → (role string for photo_links.role)
const FIELD_ROLE_MAP = [
  ['Back Pic',              'back'],
  ['Front  Pic',            'front'],   // sic — Airtable has double space
  ['Cabin Pic',             'cabin'],
  ['Right Side Pic',        'right_side'],
  ['Left Side Pic',         'left_side'],
  ['Dashboard Pic',         'dashboard'],
  ['Cabin Side left',       'cabin_left'],
  ['Cabin Side right copy', 'cabin_right'],
  ['Closed Valve',          'closed_valve'],
  ['Remote Pic',            'remote'],
  ['Level Sludge Pic',      'sludge_level'],
  ['Level Water PIC',       'water_level'],
  ['Issue pictures',        'issue'],
  ['Expense Receipt',       'expense_receipt'],
  ['DERM manifest',         'derm_manifest'],
  ['DERM Adress manifest',  'derm_address'],
];

console.log('='.repeat(60));
console.log('airtable_inspection_attachments.js');
console.log('  Mode:  ' + (DRY_RUN ? 'DRY-RUN' : 'EXECUTE'));
console.log('  Limit: ' + (LIMIT || 'none'));
console.log('  Bucket: ' + STORAGE_BUCKET);
console.log('  Fields: ' + FIELD_ROLE_MAP.length);
console.log('='.repeat(60));

// ---- HTTP -----------------------------------------------------------------
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
    if (r.status >= 300) throw new Error(`AT ${r.status}: ${r.body.toString().slice(0, 200)}`);
    const j = JSON.parse(r.body.toString());
    all.push(...(j.records || []));
    offset = j.offset;
    pages++;
    if (pages > 100) break;
  } while (offset);
  return all;
}

async function downloadFromUrl(url) {
  const u = new URL(url);
  const r = await httpRequest({ hostname: u.hostname, path: u.pathname + u.search, method: 'GET' }, null, 120000);
  if (r.status >= 300) throw new Error(`Download HTTP ${r.status}`);
  return { body: r.body, contentType: r.headers['content-type'] };
}

async function sbStorageUpload(bucketName, objectPath, bodyBuffer, contentType) {
  const supabaseHost = SUPABASE_URL.replace('https://', '');
  const encodedPath = encodeURIComponent(bucketName) + '/' +
    objectPath.split('/').map(encodeURIComponent).join('/');
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
  if (r.status >= 300) throw new Error(`Storage HTTP ${r.status}: ${r.body.toString().slice(0, 200)}`);
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
  const map = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/heic': 'heic',
                'image/webp': 'webp', 'application/pdf': 'pdf' };
  if (ct && map[ct.toLowerCase().split(';')[0]]) return map[ct.toLowerCase().split(';')[0]];
  if (fallbackName && fallbackName.includes('.')) {
    return fallbackName.split('.').pop().toLowerCase().slice(0, 5);
  }
  return 'bin';
}

// ---- Main -----------------------------------------------------------------
(async () => {
  const stats = {
    inspections_total: 0, inspections_resolved: 0, inspections_unresolved: 0,
    attachments_seen: 0, attachments_skipped_already: 0,
    attachments_uploaded: 0, attachments_failed: 0,
    photo_links_inserted: 0,
  };
  const errors = [];

  console.log('\n[1/3] Loading Airtable→our inspection ID map...');
  const eslRows = await sbQuery(`
    SELECT entity_id, source_id
    FROM entity_source_links
    WHERE entity_type='inspection' AND source_system='airtable';
  `);
  const inspIdMap = new Map();
  for (const row of eslRows) inspIdMap.set(row.source_id, row.entity_id);
  console.log(`  ${inspIdMap.size} inspection ESL rows`);

  console.log('\n[2/3] Pulling Airtable PRE-POST records...');
  let recs = await airtableFetchAll(TABLE);
  console.log(`  ${recs.length} records`);
  if (LIMIT) {
    recs = recs.slice(0, LIMIT);
    console.log(`  --limit applied → processing first ${recs.length}`);
  }
  stats.inspections_total = recs.length;

  console.log('\n[3/3] Pre-loading existing photo ESL map (idempotency)...');
  const photoIdByAttId = new Map();
  const existingPhotos = await sbQuery(`
    SELECT source_id, entity_id FROM entity_source_links
    WHERE entity_type='photo' AND source_system='airtable';
  `);
  for (const r of existingPhotos) photoIdByAttId.set(r.source_id, r.entity_id);
  console.log(`  ${photoIdByAttId.size} airtable-source photos already in DB`);

  console.log('\n--- Processing inspections ---');
  const startMs = Date.now();

  for (let i = 0; i < recs.length; i++) {
    const rec = recs[i];
    const f = rec.fields || {};

    const ourInspId = inspIdMap.get(rec.id);
    if (!ourInspId) {
      stats.inspections_unresolved++;
      if (stats.inspections_unresolved <= 5) {
        console.log(`  [${i + 1}] ${rec.id} — no inspection in our DB, skipping`);
      }
      continue;
    }
    stats.inspections_resolved++;

    let attsThisRec = 0;
    for (const [field, role] of FIELD_ROLE_MAP) {
      const atts = f[field];
      if (!Array.isArray(atts) || atts.length === 0) continue;
      for (const att of atts) {
        if (!att.url || !att.id) continue;
        stats.attachments_seen++;
        attsThisRec++;

        // Idempotency: if photo already migrated, just ensure photo_link
        const existingPhotoId = photoIdByAttId.get(att.id);
        if (existingPhotoId) {
          stats.attachments_skipped_already++;
          if (DRY_RUN) continue;
          try {
            await sbQuery(`
              INSERT INTO photo_links (photo_id, entity_type, entity_id, role, caption)
              VALUES (${existingPhotoId}, 'inspection', ${ourInspId}, ${sqlEscape(role)}, NULL)
              ON CONFLICT (photo_id, entity_type, entity_id, role) DO NOTHING;
            `);
            stats.photo_links_inserted++;
          } catch (e) {
            stats.attachments_failed++;
            errors.push(`link-existing att=${att.id} insp=${ourInspId}: ${e.message.slice(0,100)}`);
          }
          continue;
        }

        if (DRY_RUN) {
          console.log(`  [${i+1}/${recs.length}] would migrate ${role} att=${att.id} (${att.filename || 'n/a'}) → insp=${ourInspId}`);
          continue;
        }

        try {
          const dl = await downloadFromUrl(att.url);
          const ext = extFromContentType(dl.contentType, att.filename);
          const storagePath = `airtable/inspection/${ourInspId}/${role}_${att.id}.${ext}`;
          await sbStorageUpload(STORAGE_BUCKET, storagePath, dl.body, dl.contentType);

          // Atomic photos+photo_links+ESL via single CTE
          const result = await sbQuery(`
            WITH ins_photo AS (
              INSERT INTO photos (storage_path, file_name, content_type, size_bytes, source)
              VALUES (
                ${sqlEscape(storagePath)},
                ${sqlEscape(att.filename || `${role}_${att.id}.${ext}`)},
                ${sqlEscape(dl.contentType || null)},
                ${dl.body.length},
                'airtable_migration'
              )
              ON CONFLICT (storage_path) DO UPDATE SET storage_path=EXCLUDED.storage_path
              RETURNING id
            ), ins_link AS (
              INSERT INTO photo_links (photo_id, entity_type, entity_id, role, caption)
              SELECT id, 'inspection', ${ourInspId}, ${sqlEscape(role)}, NULL FROM ins_photo
              ON CONFLICT (photo_id, entity_type, entity_id, role) DO NOTHING
              RETURNING id
            ), ins_esl AS (
              INSERT INTO entity_source_links (entity_type, entity_id, source_system, source_id)
              SELECT 'photo', id, 'airtable', ${sqlEscape(att.id)} FROM ins_photo
              ON CONFLICT (entity_type, source_system, source_id) DO NOTHING
              RETURNING id
            )
            SELECT (SELECT id FROM ins_photo) AS photo_id;
          `);
          const newPhotoId = result[0]?.photo_id;
          if (newPhotoId) photoIdByAttId.set(att.id, newPhotoId);
          stats.attachments_uploaded++;
          stats.photo_links_inserted++;

          if (stats.attachments_uploaded % 25 === 0) {
            const sec = Math.round((Date.now() - startMs) / 1000);
            console.log(`  ${stats.attachments_uploaded} uploaded · ${sec}s · ~${Math.round(stats.attachments_uploaded / Math.max(sec,1) * 60)}/min`);
          }
        } catch (e) {
          stats.attachments_failed++;
          errors.push(`upload att=${att.id} insp=${ourInspId} role=${role}: ${e.message.slice(0,100)}`);
          if (errors.length <= 5) console.log(`  ✗ ${role} att=${att.id}: ${e.message.slice(0,80)}`);
        }
      }
    }
  }

  console.log('\n=== Summary ===');
  console.table([stats]);
  if (errors.length) {
    console.log(`\nFirst 10 errors (${errors.length} total):`);
    errors.slice(0, 10).forEach(e => console.log('  ' + e));
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
