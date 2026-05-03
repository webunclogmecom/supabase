// ============================================================================
// recover_visit_note_photos_window2d.js — late-note photo recovery
// ============================================================================
// For each completed Jobber-linked visit in our DB that has NO photos linked,
// look at Jobber's notes on that client posted within ±2 days of the visit's
// completed_at (fallback: visit_date) and migrate any attachments.
//
// Photos get linked to BOTH the note and the visit (so they show up no matter
// which entity the UI queries).
//
// Idempotent — safe to re-run.
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const JOBBER_TOKEN = process.env.JOBBER_ACCESS_TOKEN;
const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
const WINDOW_DAYS = 2;
const STORAGE_BUCKET = 'GT - Visits Images';
const STORAGE_SIZE_LIMIT = 52428800;

const DRY_RUN = !process.argv.includes('--execute');
// --no-window: drop the ±2d filter. Safe with visit.notes endpoint because
// Jobber already attributes each note to its visit; the window was a guard
// for the old client.notes approach where misattribution was possible.
const NO_WINDOW = process.argv.includes('--no-window');

function http(opts, body, timeoutMs = 120000) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const chunks = [];
      r.on('data', c => chunks.push(c));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(chunks), headers: r.headers }));
    });
    req.on('error', rej);
    req.setTimeout(timeoutMs, () => req.destroy(new Error('timeout')));
    if (body) req.write(body);
    req.end();
  });
}

async function pg(sql) {
  const body = JSON.stringify({ query: sql });
  const r = await http({
    hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) throw new Error(`DB ${r.status}: ${r.body.toString().slice(0, 300)}`);
  return JSON.parse(r.body.toString());
}

async function gql(query, variables, retries = 5) {
  const body = JSON.stringify({ query, variables });
  const r = await http({
    hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: { Authorization: `Bearer ${JOBBER_TOKEN}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-13', 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) {
    if (retries > 0 && (r.status === 429 || r.status >= 500)) {
      await new Promise(rs => setTimeout(rs, (6 - retries) * 4000));
      return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber ${r.status}: ${r.body.toString().slice(0, 200)}`);
  }
  const j = JSON.parse(r.body.toString());
  if (j.errors) {
    if (j.errors.some(e => e.extensions?.code === 'THROTTLED') && retries > 0) {
      await new Promise(rs => setTimeout(rs, (6 - retries) * 5000));
      return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber GQL: ${JSON.stringify(j.errors).slice(0, 300)}`);
  }
  // ClientNotes(first:10) requestedQueryCost ≈ 5056 — bucket max 10000, refill 500/s.
  // Wait until we have 6000+ available before returning so the next call doesn't 429.
  const remaining = j.extensions?.cost?.throttleStatus?.currentlyAvailable;
  if (remaining != null && remaining < 6000) {
    await new Promise(rs => setTimeout(rs, Math.ceil((6000 - remaining) / 500) * 1000));
  }
  return j.data;
}

async function downloadFromUrl(url) {
  const u = new URL(url);
  const r = await http({ hostname: u.hostname, path: u.pathname + u.search, method: 'GET' });
  if (r.status >= 300) throw new Error(`Download ${r.status}`);
  return { body: r.body, contentType: r.headers['content-type'] };
}

async function storageUpload(path, bodyBuffer, contentType) {
  const host = SUPABASE_URL.replace('https://', '');
  const enc = encodeURIComponent(STORAGE_BUCKET) + '/' + path.split('/').map(encodeURIComponent).join('/');
  const r = await http({
    hostname: host, path: '/storage/v1/object/' + enc, method: 'POST',
    headers: {
      Authorization: 'Bearer ' + SVC, apikey: SVC,
      'Content-Type': contentType || 'application/octet-stream',
      'Content-Length': bodyBuffer.length, 'x-upsert': 'true',
    },
  }, bodyBuffer);
  if (r.status >= 300) throw new Error(`Storage ${r.status}: ${r.body.toString().slice(0, 200)}`);
}

const sqlEsc = v => v == null ? 'NULL' : (typeof v === 'number' ? String(v) : "'" + String(v).replace(/'/g, "''") + "'");
const extOf = (ct, name) => {
  const m = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/heic': 'heic', 'image/webp': 'webp', 'application/pdf': 'pdf' };
  if (ct && m[ct.toLowerCase().split(';')[0]]) return m[ct.toLowerCase().split(';')[0]];
  if (name && name.includes('.')) return name.split('.').pop().toLowerCase().slice(0, 5);
  return 'bin';
};

(async () => {
  console.log('='.repeat(60));
  console.log(`recover_visit_note_photos_window2d.js  Mode: ${DRY_RUN ? 'DRY-RUN' : 'EXECUTE'}  Window: ${NO_WINDOW ? 'OFF (all)' : `±${WINDOW_DAYS}d`}`);
  console.log('='.repeat(60));

  // 1. Find the photo-less completed Jobber visits in our DB
  console.log('\n[1/4] Finding photo-less completed Jobber visits...');
  const target = await pg(`
    SELECT v.id AS visit_id, v.visit_date::text AS visit_date,
      v.completed_at::text AS completed_at, v.client_id,
      esl_v.source_id AS visit_gid,
      esl_c.source_id AS client_gid,
      c.client_code, c.name AS client_name
    FROM visits v
    JOIN entity_source_links esl_v ON esl_v.entity_type='visit' AND esl_v.entity_id=v.id AND esl_v.source_system='jobber'
    JOIN clients c ON c.id = v.client_id
    JOIN entity_source_links esl_c ON esl_c.entity_type='client' AND esl_c.entity_id=v.client_id AND esl_c.source_system='jobber'
    WHERE v.visit_status='completed'
      AND v.visit_date >= '2026-01-01'
      AND NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)
      AND NOT EXISTS (SELECT 1 FROM notes n WHERE n.visit_id=v.id AND EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='note' AND pl.entity_id=n.id));
  `);
  console.log(`  ${target.length} candidates`);

  // Pre-fetch existing photo ESL → photo_id map for idempotency
  const existingPhotos = await pg(`SELECT source_id, entity_id FROM entity_source_links WHERE entity_type='photo' AND source_system='jobber'`);
  const photoIdByJobberAttId = new Map(existingPhotos.map(r => [r.source_id, r.entity_id]));

  // Pre-fetch note ESL map (note GID → note id)
  const existingNotes = await pg(`SELECT source_id, entity_id FROM entity_source_links WHERE entity_type='note' AND source_system='jobber'`);
  const noteIdByJobberId = new Map(existingNotes.map(r => [r.source_id, r.entity_id]));

  let visitsScanned = 0, visitsRecovered = 0, photosUploaded = 0, photoLinksCreated = 0, notesCreated = 0, errors = 0;

  for (const t of target) {
    visitsScanned++;
    const anchor = (t.completed_at || t.visit_date + 'T00:00:00Z').slice(0, 10);
    const anchorMs = new Date(anchor + 'T00:00:00Z').getTime();
    const windowMs = WINDOW_DAYS * 24 * 60 * 60 * 1000;

    // Pull notes attached to THIS specific visit from Jobber (paginate).
    // Notes can be any of: ClientNote, JobNote, QuoteNote, RequestNote (union).
    // Skip pinned notes — per Fred's rule, pinned = location-level info for the
    // client, not specific to this visit, so they shouldn't be linked to it.
    let allNotes = [];
    let cursor = null;
    try {
      do {
        const d = await gql(`
          query VisitNotes($id: EncodedId!, $after: String) {
            visit(id: $id) {
              notes(first: 10, after: $after) {
                nodes {
                  ... on ClientNote { id pinned createdAt message fileAttachments { nodes { id fileName contentType fileSize url } } }
                  ... on JobNote    { id pinned createdAt message fileAttachments { nodes { id fileName contentType fileSize url } } }
                  ... on QuoteNote  { id pinned createdAt message fileAttachments { nodes { id fileName contentType fileSize url } } }
                  ... on RequestNote { id pinned createdAt message fileAttachments { nodes { id fileName contentType fileSize url } } }
                }
                pageInfo { hasNextPage endCursor }
              }
            }
          }
        `, { id: t.visit_gid, after: cursor });
        const vn = d.visit?.notes;
        if (!vn) break;
        allNotes.push(...vn.nodes);
        cursor = vn.pageInfo.hasNextPage ? vn.pageInfo.endCursor : null;
      } while (cursor && allNotes.length < 200);  // safety cap
    } catch (e) {
      errors++;
      if (errors <= 3) console.log(`  [${visitsScanned}/${target.length}] ${t.client_code} v${t.visit_id} ERR: ${e.message.slice(0, 80)}`);
      continue;
    }

    // Filter: unpinned notes only, with attachments.
    // Window check unless --no-window flag (visit.notes already attributes
    // each note to this visit, so window is just a recency guard).
    const nearbyWithAtt = allNotes.filter(n => {
      if (n.pinned) return false;
      if (!NO_WINDOW) {
        const nMs = new Date(n.createdAt).getTime();
        if (Math.abs(nMs - anchorMs) > windowMs) return false;
      }
      return (n.fileAttachments?.nodes || []).length > 0;
    });

    if (!nearbyWithAtt.length) continue;

    if (DRY_RUN) {
      const totalAtts = nearbyWithAtt.reduce((s, n) => s + n.fileAttachments.nodes.length, 0);
      console.log(`  [${visitsScanned}/${target.length}] would recover: visit ${t.visit_id} ${t.client_code} ${anchor} → ${totalAtts} attachments across ${nearbyWithAtt.length} notes`);
      visitsRecovered++;
      continue;
    }

    // EXECUTE: ensure note exists in DB, then upload each attachment
    let recoveredThisVisit = 0;
    for (const note of nearbyWithAtt) {
      // 1. Ensure note exists in our DB
      let dbNoteId = noteIdByJobberId.get(note.id);
      if (!dbNoteId) {
        const result = await pg(`
          INSERT INTO notes (client_id, visit_id, body, note_date, source)
          VALUES (${t.client_id}, ${t.visit_id}, ${sqlEsc(note.message || '')}, ${sqlEsc(note.createdAt)}, 'jobber_late_recovery')
          RETURNING id;
        `);
        dbNoteId = result[0].id;
        await pg(`
          INSERT INTO entity_source_links (entity_type, entity_id, source_system, source_id)
          VALUES ('note', ${dbNoteId}, 'jobber', ${sqlEsc(note.id)})
          ON CONFLICT (entity_type, source_system, source_id) DO NOTHING;
        `);
        noteIdByJobberId.set(note.id, dbNoteId);
        notesCreated++;
      } else {
        // Note exists — make sure it's linked to THIS visit (visit_id may have been NULL when imported)
        await pg(`UPDATE notes SET visit_id=${t.visit_id} WHERE id=${dbNoteId} AND visit_id IS NULL;`);
      }

      // 2. For each attachment, upload + insert + link
      for (const att of note.fileAttachments.nodes) {
        if (!att.url || !att.id) continue;
        if (att.fileSize > STORAGE_SIZE_LIMIT) {
          console.log(`    ⚠ oversized ${att.id} (${att.fileName}) ${att.fileSize}b — skip`);
          continue;
        }

        let dbPhotoId = photoIdByJobberAttId.get(att.id);
        if (!dbPhotoId) {
          // Download + upload + insert
          try {
            const dl = await downloadFromUrl(att.url);
            const ext = extOf(dl.contentType || att.contentType, att.fileName);
            const storagePath = `notes/${t.client_id}/${note.id}/${att.id}.${ext}`;
            await storageUpload(storagePath, dl.body, dl.contentType);
            const result = await pg(`
              INSERT INTO photos (storage_path, file_name, content_type, size_bytes, source)
              VALUES (${sqlEsc(storagePath)}, ${sqlEsc(att.fileName || `${att.id}.${ext}`)}, ${sqlEsc(dl.contentType || null)}, ${dl.body.length}, 'jobber_late_recovery')
              ON CONFLICT (storage_path) DO UPDATE SET storage_path=EXCLUDED.storage_path
              RETURNING id;
            `);
            dbPhotoId = result[0].id;
            await pg(`
              INSERT INTO entity_source_links (entity_type, entity_id, source_system, source_id)
              VALUES ('photo', ${dbPhotoId}, 'jobber', ${sqlEsc(att.id)})
              ON CONFLICT (entity_type, source_system, source_id) DO NOTHING;
            `);
            photoIdByJobberAttId.set(att.id, dbPhotoId);
            photosUploaded++;
          } catch (e) {
            errors++;
            console.log(`    ✗ download/upload ${att.id}: ${e.message.slice(0, 80)}`);
            continue;
          }
        }

        // Link to BOTH note and visit (idempotent)
        await pg(`
          INSERT INTO photo_links (photo_id, entity_type, entity_id, role)
          VALUES (${dbPhotoId}, 'note', ${dbNoteId}, 'attachment')
          ON CONFLICT (photo_id, entity_type, entity_id, role) DO NOTHING;
          INSERT INTO photo_links (photo_id, entity_type, entity_id, role)
          VALUES (${dbPhotoId}, 'visit', ${t.visit_id}, 'attachment')
          ON CONFLICT (photo_id, entity_type, entity_id, role) DO NOTHING;
        `);
        photoLinksCreated += 2;
        recoveredThisVisit++;
      }
    }
    if (recoveredThisVisit > 0) {
      visitsRecovered++;
      console.log(`  [${visitsScanned}/${target.length}] ✓ ${t.client_code} v${t.visit_id} recovered ${recoveredThisVisit} photo(s)`);
    }

    // Outer pacing on top of the gql()-internal "wait until ≥6000 available"
    // logic. With requestedQueryCost ≈ 5056 per ClientNotes call and 500/s
    // refill, gql() already pauses ~10s when the bucket is below 6000; this
    // 1s extra buffers against burst variability. Runtime ~76 × 11s ≈ 14 min.
    await new Promise(rs => setTimeout(rs, 1000));
  }

  console.log('\n=== Summary ===');
  console.log(`  Visits scanned:      ${visitsScanned}`);
  console.log(`  Visits recovered:    ${visitsRecovered}`);
  console.log(`  Notes created:       ${notesCreated}`);
  console.log(`  Photos uploaded:     ${photosUploaded}`);
  console.log(`  Photo links created: ${photoLinksCreated}`);
  console.log(`  Errors:              ${errors}`);
})().catch(e => { console.error('FATAL:', e.message, e.stack); process.exit(1); });
