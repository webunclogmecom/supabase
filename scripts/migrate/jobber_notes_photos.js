// ============================================================================
// Jobber notes + photos migration — Scaffold (dry-run capable)
// ============================================================================
//
// Extracts Jobber notes (text + photo attachments) from clients, jobs, and
// visits, routes each into our schema per ADR 009 (unified photos) and the
// classifier documented in docs/migration-plan.md.
//
// Must complete before the May 2026 Jobber sunset, after which Jobber-hosted
// photo URLs die.
//
// USAGE:
//   node scripts/migrate/jobber_notes_photos.js --dry-run [--limit 5]
//   node scripts/migrate/jobber_notes_photos.js --execute [--resume]
//
// RATE LIMITING:
//   Jobber: 2,500 req / 5 min (DDoS) + 10k-point query cost bucket.
//   We pace to stay well under both. Budget logged every batch.
//
// IDEMPOTENCY:
//   Every note/photo gets an entity_source_links row. Re-running skips
//   anything already imported via ON CONFLICT on (entity_type, source_system,
//   source_id). Safe to interrupt and resume via --resume.
//
// CHECKPOINT:
//   Progress written to sync_cursors with entity = 'jobber_notes_migration'.
//   --resume reads the cursor and continues from the last client_id.
//
// STATUS: SCAFFOLD. The GraphQL query shape, classifier, and upload pipeline
// are wired in but returns are stubbed with TODO markers. See README in
// this folder for the implementation roadmap.
// ============================================================================

require('dotenv').config();
const fs = require('fs');
const path = require('path');
const https = require('https');

// ---- CLI args ----
const args = process.argv.slice(2);
const DRY_RUN = args.includes('--dry-run') || !args.includes('--execute');
const RESUME = args.includes('--resume');
const LIMIT = (() => {
  const i = args.indexOf('--limit');
  return i >= 0 ? parseInt(args[i + 1], 10) : null;
})();

const JOBBER_GRAPHQL = 'https://api.getjobber.com/api/graphql';
const JOBBER_API_VERSION = '2025-01-20'; // keep in sync with webhook-jobber

// ---- Supabase Management API wrapper for SQL + Storage ----
function supabaseQuery(sql) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: '/v1/projects/' + process.env.SUPABASE_PROJECT_ID + '/database/query',
      method: 'POST',
      headers: {
        'Authorization': 'Bearer ' + process.env.SUPABASE_PAT,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    }, res => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => {
        if (res.statusCode >= 300) reject(new Error('HTTP ' + res.statusCode + ': ' + d.slice(0, 400)));
        else resolve(JSON.parse(d));
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// ---- Jobber GraphQL client with token refresh + cost logging ----
let _jobberBudget = { available: null, max: null, rate: null };

async function jobberGraphQL(query, variables = {}, _retries = 0) {
  const body = JSON.stringify({ query, variables });
  return new Promise((resolve, reject) => {
    const req = https.request(JOBBER_GRAPHQL, {
      method: 'POST',
      headers: {
        'Authorization': 'Bearer ' + process.env.JOBBER_ACCESS_TOKEN,
        'X-JOBBER-GRAPHQL-VERSION': JOBBER_API_VERSION,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    }, res => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', async () => {
        try {
          const parsed = JSON.parse(d);
          if (parsed.errors) {
            const throttled = parsed.errors.some(e => e.extensions?.code === 'THROTTLED');
            if (throttled && _retries < 3) {
              const waitSec = 30 * (_retries + 1);
              console.log(`    [throttled] waiting ${waitSec}s (retry ${_retries + 1}/3)`);
              await new Promise(r => setTimeout(r, waitSec * 1000));
              resolve(await jobberGraphQL(query, variables, _retries + 1));
              return;
            }
            return reject(new Error('GraphQL: ' + JSON.stringify(parsed.errors).slice(0, 400)));
          }
          if (parsed.extensions?.cost?.throttleStatus) {
            _jobberBudget = {
              available: parsed.extensions.cost.throttleStatus.currentlyAvailable,
              max: parsed.extensions.cost.throttleStatus.maximumAvailable,
              rate: parsed.extensions.cost.throttleStatus.restoreRate,
            };
          }
          resolve(parsed.data);
        } catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function logBudget(prefix = '') {
  if (_jobberBudget.available !== null) {
    console.log(`  ${prefix}Jobber budget: ${_jobberBudget.available}/${_jobberBudget.max} (restore ${_jobberBudget.rate}/s)`);
  }
}

// Rate-limit floor: if budget drops below this fraction of max, sleep until recovered.
async function respectBudget(floorFraction = 0.2) {
  if (_jobberBudget.available === null || _jobberBudget.max === null) return;
  const floor = _jobberBudget.max * floorFraction;
  if (_jobberBudget.available < floor && _jobberBudget.rate > 0) {
    const needed = floor - _jobberBudget.available;
    const waitSec = Math.ceil(needed / _jobberBudget.rate) + 2;
    console.log(`  [rate-limit] budget ${_jobberBudget.available} below floor ${floor}, sleeping ${waitSec}s`);
    await new Promise(r => setTimeout(r, waitSec * 1000));
  }
}

// ============================================================================
// STEP 1 — Enumerate clients with Jobber IDs we need to examine
// ============================================================================
async function* iterateClients(resumeFromId = null) {
  const q = `SELECT entity_id, source_id, source_name
             FROM entity_source_links
             WHERE entity_type='client' AND source_system='jobber'
             ${resumeFromId ? `AND entity_id > ${resumeFromId}` : ''}
             ORDER BY entity_id`;
  const rows = await supabaseQuery(q);
  for (const r of rows) {
    if (LIMIT && --LIMIT < 0) break;   // local limit for dry runs
    yield r;
  }
}

// ============================================================================
// STEP 2 — Pull notes for one Jobber client
// ============================================================================
// TODO: Jobber's GraphQL schema for notes + attachments. Based on Jobber docs
// (as of 2025), the query looks roughly like:
//
// query ClientNotes($id: EncodedId!, $after: String) {
//   client(id: $id) {
//     notes(first: 50, after: $after) {
//       nodes {
//         id
//         message
//         createdAt
//         createdBy { id name }
//         attachments { url fileName contentType sizeBytes }
//       }
//       pageInfo { hasNextPage endCursor }
//     }
//   }
// }
//
// Notes also exist on Job and Visit nodes with similar shape. Full migration
// should iterate all three. For now this stub pulls from Client only.
async function fetchJobberClientNotes(jobberClientGid, cursor = null) {
  // TODO: implement the real GraphQL query. Returns [] for now so dry-run
  // can exercise the rest of the pipeline.
  return { notes: [], hasNextPage: false, endCursor: null };
}

// ============================================================================
// STEP 3 — Classify each note (visit-scoped vs. non-visit)
// ============================================================================
async function classifyNote(ourClientId, jobberNote) {
  // note_date comes from jobberNote.createdAt
  const noteDate = jobberNote.createdAt;
  const dateOnly = noteDate ? noteDate.slice(0, 10) : null;
  if (!dateOnly) return { kind: 'non_visit', visit_id: null, property_id: null };

  // Visit triangulation: visits within ±1 day of the note, for this client
  const rows = await supabaseQuery(`
    SELECT id, visit_date, property_id, end_at
    FROM visits
    WHERE client_id = ${ourClientId}
      AND visit_date BETWEEN DATE '${dateOnly}' - 1 AND DATE '${dateOnly}' + 1
    ORDER BY ABS(visit_date - DATE '${dateOnly}'), end_at DESC
    LIMIT 1
  `);

  if (rows.length) {
    return { kind: 'visit', visit_id: rows[0].id, property_id: rows[0].property_id };
  }
  return { kind: 'non_visit', visit_id: null, property_id: null };
}

// ============================================================================
// STEP 4 — Download attachment + upload to Supabase Storage
// ============================================================================
// TODO: Implement. Uses fetch() to pull from Jobber's CDN, then Supabase
// Storage REST API (POST /storage/v1/object/<bucket>/<path>) with service-role
// key to upload. Returns { storage_path, size_bytes, content_type, width_px,
// height_px, exif_* }.
//
// Bucket: 'jobber-notes-photos' (pre-created by Fred)
// Path pattern:
//   - visit-scoped: visits/<visit_id>/<sanitized_filename>
//   - non-visit:    unassigned/<client_id>/<jobber_note_id>/<sanitized_filename>
async function fetchAndStoreAttachment(jobberAttachment, targetPath) {
  // TODO
  return { storage_path: 'jobber-notes-photos/' + targetPath, size_bytes: null, content_type: null };
}

// ============================================================================
// STEP 5 — Insert into DB (atomic per note)
// ============================================================================
// TODO: For each classified note:
//   - INSERT into notes (client_id, visit_id, property_id, body, note_date,
//                        source='jobber_migration', author_name)
//   - For each attachment:
//       - INSERT into photos (storage_path, file_name, content_type, size_bytes,
//                             source='jobber_migration')
//       - INSERT into photo_links (photo_id, entity_type, entity_id, role, caption)
//         where entity_type = visit | property | note depending on classification
//   - INSERT into entity_source_links for the note and each photo
//   All inside one transaction to preserve consistency if the run is killed.
async function persistNote(note, classification, uploadedAttachments) {
  if (DRY_RUN) {
    console.log(`  [dry-run] would persist note ${note.jobberNoteId} (${classification.kind}), ${uploadedAttachments.length} attachments`);
    return;
  }
  // TODO: real implementation
  throw new Error('persistNote not yet implemented');
}

// ============================================================================
// MAIN
// ============================================================================
(async () => {
  console.log('============================================================');
  console.log('Jobber notes + photos migration');
  console.log('  Mode:', DRY_RUN ? 'DRY RUN (no writes)' : 'EXECUTE');
  if (RESUME) console.log('  Resume: yes (read from sync_cursors)');
  if (LIMIT) console.log('  Limit: ' + LIMIT + ' clients');
  console.log('============================================================\n');

  // Quick Jobber auth check
  try {
    const me = await jobberGraphQL(`{ account { name } }`);
    console.log('Jobber auth OK. Account:', me?.account?.name || '(unknown)');
    logBudget();
  } catch (e) {
    console.error('Jobber auth FAILED:', e.message);
    console.error('Run `node scripts/jobber_auth.js` to refresh tokens.');
    process.exit(1);
  }

  // Resume point
  let resumeFromId = null;
  if (RESUME) {
    const cur = await supabaseQuery(
      "SELECT last_synced_at FROM sync_cursors WHERE entity = 'jobber_notes_migration'"
    );
    if (cur.length && cur[0].last_synced_at) {
      resumeFromId = cur[0].last_synced_at; // reusing the field to store last client id as text
      console.log('Resuming after client_id:', resumeFromId);
    }
  }

  let clientCount = 0, noteCount = 0, attachmentCount = 0;

  for await (const client of iterateClients(resumeFromId)) {
    clientCount++;
    console.log(`\n[${clientCount}] Client ${client.entity_id} (Jobber ${client.source_id}) — ${client.source_name || '?'}`);

    let cursor = null;
    do {
      const page = await fetchJobberClientNotes(client.source_id, cursor);
      for (const note of page.notes) {
        const cls = await classifyNote(client.entity_id, note);
        const uploads = [];
        for (const att of note.attachments || []) {
          // TODO: fetchAndStoreAttachment(att, ...)
          uploads.push({ ...att, storage_path: 'TODO' });
        }
        await persistNote(note, cls, uploads);
        noteCount++;
        attachmentCount += uploads.length;
      }
      cursor = page.hasNextPage ? page.endCursor : null;
      await respectBudget();
    } while (cursor);

    // Checkpoint after each client (so --resume works)
    if (!DRY_RUN) {
      await supabaseQuery(`
        INSERT INTO sync_cursors (entity, last_synced_at, last_run_status, rows_pulled)
        VALUES ('jobber_notes_migration', '${client.entity_id}', 'running', ${noteCount})
        ON CONFLICT (entity) DO UPDATE SET
          last_synced_at = EXCLUDED.last_synced_at,
          last_run_status = EXCLUDED.last_run_status,
          rows_pulled = EXCLUDED.rows_pulled,
          updated_at = now()
      `);
    }
  }

  console.log('\n============================================================');
  console.log(`Complete. Clients: ${clientCount}, notes: ${noteCount}, attachments: ${attachmentCount}`);
  console.log('============================================================');
})().catch(e => {
  console.error('FATAL:', e.message);
  process.exit(1);
});
