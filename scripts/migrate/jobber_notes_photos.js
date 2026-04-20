// ============================================================================
// Jobber notes + photos migration
// ============================================================================
//
// Extracts notes and attached media (photos, videos, PDFs) from Jobber
// Clients and Jobs, routes them into our schema per ADR 009.
//
// Must complete before the May 2026 Jobber sunset — after that, Jobber-
// hosted attachment URLs die.
//
// ARCHITECTURE (Tech Lead summary)
//
//   Jobber model:
//     - Notes live on Client, Job, Quote, Request.
//     - Every note implements NoteInterface: id, createdAt, lastEditedAt,
//       message, pinned, createdBy (Union of User|Application), fileAttachments
//     - fileAttachments.nodes are NoteFileInterface objects with:
//         id, fileName, contentType, fileSize, url (signed S3, 3-day expiry),
//         thumbnailUrl, status, createdAt
//
//   Our model (ADR 009):
//     notes                — text content, linked to client (+ optional visit/property/job)
//     photos               — file + EXIF metadata (unified for images/videos/PDFs despite the name)
//     photo_links          — polymorphic bridge (entity_type + entity_id + role)
//     entity_source_links  — cross-system ID tracking (idempotency)
//
//   Classification:
//     For each Jobber note, find the closest visit (±1 day on same client).
//     - Match → VISIT-SCOPED. Note + photos attach to that visit.
//     - No match → NON-VISIT. Note on client; photos attach to the note itself
//       (entity_type='note', role='attachment') to preserve context. Future
//       manual review can reclassify.
//
//   Idempotency:
//     Every note and every photo gets an entity_source_links row keyed by
//     (entity_type, source_system='jobber', source_id=<jobber_gid>).
//     Before inserting, we check existence; if present, skip the note (and
//     all its attachments) entirely. Safe to Ctrl-C and re-run with --resume.
//
//   Rate limiting:
//     Jobber: 2500 req / 5 min + 10k-point GraphQL cost bucket.
//     - `respectBudget` sleeps when budget drops below 20% of max.
//     - Throttled responses auto-retry with exponential backoff (max 3).
//
//   Checkpointing:
//     sync_cursors row with entity='jobber_notes_migration':
//       rows_pulled        = last completed client.id (our local entity_id)
//       rows_populated     = cumulative notes migrated this run
//       last_run_status    = running | completed | failed
//       last_error         = error text if last run failed
//
// USAGE
//   node scripts/migrate/jobber_notes_photos.js --dry-run [--limit N]
//   node scripts/migrate/jobber_notes_photos.js --execute [--resume] [--limit N] [--skip-attachments]
//
//   --dry-run            print what would happen, no writes
//   --execute            real writes (Storage + DB)
//   --resume             continue from last sync_cursors checkpoint
//   --limit N            only process N clients (for testing)
//   --skip-attachments   write notes only, leave photos for a later pass
//   --include-quote-request  also pull Quote + Request notes (default: Client + Job only)
//
// ============================================================================

require('dotenv').config();
const https = require('https');
const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
const DRY_RUN = !args.includes('--execute');
const RESUME = args.includes('--resume');
const SKIP_ATTACHMENTS = args.includes('--skip-attachments');
const INCLUDE_QUOTE_REQUEST = args.includes('--include-quote-request');
const LIMIT = (() => {
  const i = args.indexOf('--limit');
  return i >= 0 ? parseInt(args[i + 1], 10) : null;
})();

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
const JOBBER_GRAPHQL = 'https://api.getjobber.com/api/graphql';
const JOBBER_API_VERSION = '2026-04-13';
const STORAGE_BUCKET = 'GT - Visits Images';
const NOTE_CLASSIFIER_WINDOW_DAYS = 1;

// Budget: pause new queries when Jobber budget < 20% of max
const BUDGET_FLOOR_FRACTION = 0.20;

// Supabase Pro caps bucket file_size_limit at 50 MB. Files larger than this
// are skipped and logged to jobber_oversized_attachments (tracked for
// possible later-pass with external storage or plan upgrade).
const STORAGE_SIZE_LIMIT_BYTES = 52428800;  // 50 MB

// Page sizes
// NOTES_PAGE_SIZE must stay ≤ 10 — Jobber's GraphQL cost calculator
// estimates notes-with-attachments queries at ~500 points per note. At
// first:50 the requested cost is ~25k (exceeds 10k budget ceiling, rejected
// without executing). At first:10, requested ~5k, actual ~50 — fits.
const NOTES_PAGE_SIZE = 10;
const JOBS_PAGE_SIZE = 50;       // jobs query just selects {id} — cheap
const CLIENTS_BATCH_SIZE = 100;  // how many of our client rows to fetch per batch

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------
function httpRequest(opts, body) {
  return new Promise((resolve, reject) => {
    const req = https.request(opts, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        resolve({
          status: res.statusCode,
          headers: res.headers,
          body: Buffer.concat(chunks),
        });
      });
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Jobber token refresh
// ---------------------------------------------------------------------------
async function refreshJobberToken() {
  const params = new URLSearchParams({
    grant_type: 'refresh_token',
    client_id: process.env.JOBBER_CLIENT_ID,
    client_secret: process.env.JOBBER_CLIENT_SECRET,
    refresh_token: process.env.JOBBER_REFRESH_TOKEN,
  }).toString();
  const r = await httpRequest({
    hostname: 'api.getjobber.com',
    path: '/api/oauth/token',
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Content-Length': Buffer.byteLength(params),
    },
  }, params);
  if (r.status >= 300) throw new Error(`Token refresh failed: ${r.status} ${r.body.toString().slice(0, 200)}`);
  const tokens = JSON.parse(r.body.toString());
  process.env.JOBBER_ACCESS_TOKEN = tokens.access_token;
  if (tokens.refresh_token) process.env.JOBBER_REFRESH_TOKEN = tokens.refresh_token;
  // Also persist to .env so the next invocation doesn't start with expired tokens
  let env = fs.readFileSync('.env', 'utf8');
  env = env.replace(/^JOBBER_ACCESS_TOKEN=.*$/m, 'JOBBER_ACCESS_TOKEN=' + tokens.access_token);
  if (tokens.refresh_token) env = env.replace(/^JOBBER_REFRESH_TOKEN=.*$/m, 'JOBBER_REFRESH_TOKEN=' + tokens.refresh_token);
  fs.writeFileSync('.env', env);
  console.log('  [auth] Jobber token refreshed');
}

// ---------------------------------------------------------------------------
// Jobber GraphQL client
// ---------------------------------------------------------------------------
let _budget = { available: null, max: null, rate: null };

async function jobberGraphQL(query, variables = {}, _retries = 0) {
  const body = JSON.stringify({ query, variables });
  const r = await httpRequest({
    hostname: 'api.getjobber.com',
    path: '/api/graphql',
    method: 'POST',
    headers: {
      'Authorization': 'Bearer ' + process.env.JOBBER_ACCESS_TOKEN,
      'X-JOBBER-GRAPHQL-VERSION': JOBBER_API_VERSION,
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    },
  }, body);

  const parsed = JSON.parse(r.body.toString());

  // Expired token → refresh and retry once
  if (parsed.message === 'Access token expired' && _retries === 0) {
    await refreshJobberToken();
    return jobberGraphQL(query, variables, _retries + 1);
  }

  if (parsed.errors) {
    const throttled = parsed.errors.some(e => e.extensions?.code === 'THROTTLED');
    if (throttled && _retries < 3) {
      const waitSec = 20 * (_retries + 1);
      // On first throttle, log the full error body to help diagnose
      if (_retries === 0) console.log('  [throttled-detail] first error: ' + JSON.stringify(parsed.errors).slice(0, 400));
      console.log(`  [throttled] waiting ${waitSec}s (retry ${_retries + 1}/3); budget ${_budget.available}/${_budget.max}`);
      await sleep(waitSec * 1000);
      return jobberGraphQL(query, variables, _retries + 1);
    }
    throw new Error('GraphQL: ' + JSON.stringify(parsed.errors).slice(0, 500));
  }

  if (parsed.extensions?.cost?.throttleStatus) {
    _budget.available = parsed.extensions.cost.throttleStatus.currentlyAvailable;
    _budget.max = parsed.extensions.cost.throttleStatus.maximumAvailable;
    _budget.rate = parsed.extensions.cost.throttleStatus.restoreRate;
  }

  return parsed.data;
}

async function respectBudget() {
  if (_budget.available === null || _budget.max === null) return;
  const floor = _budget.max * BUDGET_FLOOR_FRACTION;
  if (_budget.available < floor && _budget.rate > 0) {
    const needed = floor - _budget.available;
    const waitSec = Math.ceil(needed / _budget.rate) + 2;
    console.log(`  [rate-limit] budget ${_budget.available}/${_budget.max} < floor; sleeping ${waitSec}s`);
    await sleep(waitSec * 1000);
  }
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// Supabase helpers (SQL via Management API; Storage via REST)
// ---------------------------------------------------------------------------
async function sbQuery(sql) {
  const body = JSON.stringify({ query: sql });
  const r = await httpRequest({
    hostname: 'api.supabase.com',
    path: '/v1/projects/' + process.env.SUPABASE_PROJECT_ID + '/database/query',
    method: 'POST',
    headers: {
      'Authorization': 'Bearer ' + process.env.SUPABASE_PAT,
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    },
  }, body);
  if (r.status >= 300) throw new Error('DB: HTTP ' + r.status + ': ' + r.body.toString().slice(0, 400));
  return JSON.parse(r.body.toString());
}

function sqlEscape(v) {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'number') return String(v);
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (Array.isArray(v)) return "ARRAY[" + v.map(x => sqlEscape(x)).join(',') + "]::text[]";
  // TEXT: escape single quotes
  return "'" + String(v).replace(/'/g, "''") + "'";
}

async function sbStorageUpload(bucketName, objectPath, bodyBuffer, contentType) {
  const supabaseHost = process.env.SUPABASE_URL.replace('https://', '');
  const encodedPath = encodeURIComponent(bucketName) + '/' + objectPath
    .split('/').map(encodeURIComponent).join('/');
  const r = await httpRequest({
    hostname: supabaseHost,
    path: '/storage/v1/object/' + encodedPath,
    method: 'POST',
    headers: {
      'Authorization': 'Bearer ' + process.env.SUPABASE_SERVICE_ROLE_KEY,
      'apikey': process.env.SUPABASE_SERVICE_ROLE_KEY,
      'Content-Type': contentType || 'application/octet-stream',
      'Content-Length': bodyBuffer.length,
      'x-upsert': 'true',
    },
  }, bodyBuffer);
  if (r.status >= 300) throw new Error('Storage upload: HTTP ' + r.status + ': ' + r.body.toString().slice(0, 300));
  return r.body.toString();
}

async function downloadFromUrl(url) {
  const u = new URL(url);
  const r = await httpRequest({
    hostname: u.hostname,
    path: u.pathname + u.search,
    method: 'GET',
  });
  if (r.status >= 300) throw new Error('Download: HTTP ' + r.status);
  return r.body;
}

// ---------------------------------------------------------------------------
// Idempotency lookups (entity_source_links)
// ---------------------------------------------------------------------------
async function isNoteAlreadyMigrated(jobberNoteGid) {
  const r = await sbQuery(
    `SELECT 1 FROM entity_source_links WHERE entity_type='note' AND source_system='jobber' AND source_id=${sqlEscape(jobberNoteGid)} LIMIT 1`
  );
  return r.length > 0;
}

async function isPhotoAlreadyMigrated(jobberFileGid) {
  const r = await sbQuery(
    `SELECT 1 FROM entity_source_links WHERE entity_type='photo' AND source_system='jobber' AND source_id=${sqlEscape(jobberFileGid)} LIMIT 1`
  );
  return r.length > 0;
}

// ---------------------------------------------------------------------------
// Classifier: find the closest visit for a note_date
// ---------------------------------------------------------------------------
async function classifyNote(ourClientId, noteDate) {
  if (!noteDate) return { kind: 'non_visit', visit_id: null, property_id: null };
  const dateOnly = noteDate.slice(0, 10);
  const rows = await sbQuery(`
    SELECT id, property_id
    FROM visits
    WHERE client_id = ${ourClientId}
      AND visit_date BETWEEN DATE '${dateOnly}' - INTERVAL '${NOTE_CLASSIFIER_WINDOW_DAYS} days'
                         AND DATE '${dateOnly}' + INTERVAL '${NOTE_CLASSIFIER_WINDOW_DAYS} days'
    ORDER BY ABS(visit_date - DATE '${dateOnly}'), end_at DESC NULLS LAST
    LIMIT 1
  `);
  if (rows.length) {
    return { kind: 'visit', visit_id: rows[0].id, property_id: rows[0].property_id };
  }
  return { kind: 'non_visit', visit_id: null, property_id: null };
}

// ---------------------------------------------------------------------------
// Fetch all notes for one Jobber client (client-level + job-level)
// ---------------------------------------------------------------------------
async function fetchJobberClientNotes(clientGid) {
  // Notes can surface twice: via client.notes AND via job.notes (Jobber's
  // JobNoteUnion includes inherited ClientNotes). Dedupe by Jobber note id.
  const seen = new Set();
  const allNotes = [];
  const pushUnique = (n, parent, parentId) => {
    if (seen.has(n.id)) return;
    seen.add(n.id);
    allNotes.push({ ...n, _parent: parent, _parentId: parentId });
  };

  // 1. Client-level notes (paginate)
  let cursor = null;
  do {
    const data = await jobberGraphQL(`
      query ClientNotes($id: EncodedId!, $after: String) {
        client(id: $id) {
          notes(first: ${NOTES_PAGE_SIZE}, after: $after) {
            nodes {
              id createdAt lastEditedAt message pinned
              createdBy { __typename ... on User { id name { full } } }
              fileAttachments {
                nodes { id fileName contentType fileSize url createdAt }
              }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    `, { id: clientGid, after: cursor });
    const page = data.client?.notes;
    if (!page) break;
    for (const n of page.nodes) pushUnique(n, 'client', clientGid);
    cursor = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
    await respectBudget();
  } while (cursor);

  // 2. Job-level notes — first enumerate job IDs, then fetch each job's notes
  const jobIds = [];
  cursor = null;
  do {
    const data = await jobberGraphQL(`
      query ClientJobs($id: EncodedId!, $after: String) {
        client(id: $id) {
          jobs(first: ${JOBS_PAGE_SIZE}, after: $after) {
            nodes { id }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    `, { id: clientGid, after: cursor });
    const page = data.client?.jobs;
    if (!page) break;
    for (const j of page.nodes) jobIds.push(j.id);
    cursor = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
    await respectBudget();
  } while (cursor);

  // 3. For each job, pull its notes
  for (const jobId of jobIds) {
    let jc = null;
    do {
      // JobNoteUnion means each note can be ClientNote|JobNote|QuoteNote|RequestNote —
      // we fragment-spread the shared NoteInterface fields via inline fragments
      const data = await jobberGraphQL(`
        query JobNotes($id: EncodedId!, $after: String) {
          job(id: $id) {
            notes(first: ${NOTES_PAGE_SIZE}, after: $after) {
              nodes {
                ... on ClientNote { id createdAt lastEditedAt message pinned
                  createdBy { __typename ... on User { id name { full } } }
                  fileAttachments { nodes { id fileName contentType fileSize url createdAt } }
                }
                ... on JobNote { id createdAt lastEditedAt message pinned
                  createdBy { __typename ... on User { id name { full } } }
                  fileAttachments { nodes { id fileName contentType fileSize url createdAt } }
                }
                ... on QuoteNote { id createdAt lastEditedAt message pinned
                  createdBy { __typename ... on User { id name { full } } }
                  fileAttachments { nodes { id fileName contentType fileSize url createdAt } }
                }
                ... on RequestNote { id createdAt lastEditedAt message pinned
                  createdBy { __typename ... on User { id name { full } } }
                  fileAttachments { nodes { id fileName contentType fileSize url createdAt } }
                }
              }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      `, { id: jobId, after: jc });
      const page = data.job?.notes;
      if (!page) break;
      for (const n of page.nodes) pushUnique(n, 'job', jobId);
      jc = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
      await respectBudget();
    } while (jc);
  }

  return allNotes;
}

// ---------------------------------------------------------------------------
// Attachment filter
// ---------------------------------------------------------------------------
function shouldUploadAttachment(att) {
  // Respect bucket's allowed mime types: image/*, video/*, application/pdf
  if (!att.contentType) return { ok: false, reason: 'no_content_type' };
  const mimeOk = att.contentType.startsWith('image/')
    || att.contentType.startsWith('video/')
    || att.contentType === 'application/pdf';
  if (!mimeOk) return { ok: false, reason: 'mimetype_not_allowed' };
  // Size gate — Supabase Pro bucket cap is 50 MB
  if (att.fileSize && att.fileSize > STORAGE_SIZE_LIMIT_BYTES) {
    return { ok: false, reason: 'oversized' };
  }
  return { ok: true };
}

async function logOversizedAttachment(ctx, note, att, classification) {
  // Best-effort log. If the tracking table doesn't exist yet, skip silently
  // (the migration still succeeds for non-oversized attachments).
  if (DRY_RUN) return;
  const sql = `
    INSERT INTO jobber_oversized_attachments
      (client_id, note_jobber_id, attachment_jobber_id, file_name, content_type, size_bytes, jobber_url_signed, classification_kind, visit_id, logged_at)
    VALUES (
      ${sqlEscape(ctx.ourClientId)},
      ${sqlEscape(note.id)},
      ${sqlEscape(att.id)},
      ${sqlEscape(att.fileName)},
      ${sqlEscape(att.contentType)},
      ${sqlEscape(att.fileSize)},
      ${sqlEscape(att.url)},
      ${sqlEscape(classification.kind)},
      ${sqlEscape(classification.visit_id)},
      now()
    )
    ON CONFLICT (attachment_jobber_id) DO NOTHING
  `;
  try { await sbQuery(sql); } catch (e) { /* table may not exist yet */ }
}

function sanitizeFilename(name) {
  return (name || 'file').replace(/[^A-Za-z0-9_.-]/g, '_').slice(0, 150);
}

function storagePathFor(classification, ourClientId, noteGid, att) {
  const ts = (att.createdAt || new Date().toISOString()).slice(0, 10).replace(/-/g, '');
  const fileId = att.id.slice(-12).replace(/[^A-Za-z0-9]/g, '');
  const name = sanitizeFilename(att.fileName);
  if (classification.kind === 'visit') {
    return `visits/${classification.visit_id}/${ts}_${fileId}_${name}`;
  }
  return `notes/${ourClientId}/${noteGid.slice(-12).replace(/[^A-Za-z0-9]/g, '')}/${ts}_${fileId}_${name}`;
}

// ---------------------------------------------------------------------------
// Author resolver — Jobber user → our employees.id (via entity_source_links)
// Returns { author_employee_id, author_name }
// ---------------------------------------------------------------------------
const _employeeCache = new Map(); // jobber user gid → our employee_id
async function resolveAuthor(createdBy) {
  const authorName = createdBy?.name?.full || null;
  if (!createdBy || createdBy.__typename !== 'User' || !createdBy.id) {
    return { author_employee_id: null, author_name: authorName };
  }
  if (_employeeCache.has(createdBy.id)) {
    return { author_employee_id: _employeeCache.get(createdBy.id), author_name: authorName };
  }
  const r = await sbQuery(`
    SELECT entity_id FROM entity_source_links
    WHERE entity_type='employee' AND source_system='jobber' AND source_id=${sqlEscape(createdBy.id)}
    LIMIT 1
  `);
  const id = r.length ? r[0].entity_id : null;
  _employeeCache.set(createdBy.id, id);
  return { author_employee_id: id, author_name: authorName };
}

// ---------------------------------------------------------------------------
// persistNote — transaction that lands one note + all its attachments
// ---------------------------------------------------------------------------
async function persistNote(context, note, classification, uploadedAttachments) {
  // Build a single SQL batch that's transactional end-to-end
  const author = await resolveAuthor(note.createdBy);
  const linkEntityType = classification.kind === 'visit' ? 'visit' : 'note';

  // We need the inserted note id AND each inserted photo id to wire up links.
  // Approach: do it in discrete statements within a transaction.
  // sbQuery runs each call as its own HTTP POST; for atomicity across multiple
  // statements we wrap with BEGIN/COMMIT inside a SINGLE SQL batch.

  // Build the batch SQL:
  const parts = ['BEGIN;'];

  // 1. notes row
  parts.push(`
    WITH ins AS (
      INSERT INTO notes (client_id, visit_id, property_id, job_id, body, author_employee_id, author_name, note_date, source, tags)
      VALUES (
        ${sqlEscape(context.ourClientId)},
        ${sqlEscape(classification.visit_id)},
        ${sqlEscape(classification.property_id)},
        NULL,
        ${sqlEscape(note.message || '')},
        ${sqlEscape(author.author_employee_id)},
        ${sqlEscape(author.author_name)},
        ${sqlEscape(note.createdAt)},
        'jobber_migration',
        ${sqlEscape(classification.kind === 'visit' ? ['jobber_migration'] : ['jobber_migration','non_visit'])}
      )
      RETURNING id
    )
    INSERT INTO entity_source_links (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence, synced_at)
    SELECT 'note', ins.id, 'jobber', ${sqlEscape(note.id)}, NULL, 'api_pull', 1.00, now()
    FROM ins
    RETURNING entity_id AS note_id;
  `);

  // 2. each uploaded attachment → photos + photo_links + entity_source_links
  for (const u of uploadedAttachments) {
    parts.push(`
      WITH pins AS (
        INSERT INTO photos (storage_path, file_name, content_type, size_bytes, exif_taken_at, source, uploaded_at)
        VALUES (
          ${sqlEscape(u.storage_path)},
          ${sqlEscape(u.file_name)},
          ${sqlEscape(u.content_type)},
          ${sqlEscape(u.size_bytes)},
          ${sqlEscape(u.taken_at)},
          'jobber_migration',
          now()
        )
        ON CONFLICT (storage_path) DO UPDATE SET storage_path = EXCLUDED.storage_path
        RETURNING id
      ),
      links AS (
        INSERT INTO photo_links (photo_id, entity_type, entity_id, role, caption)
        SELECT pins.id, '${linkEntityType}',
               ${classification.kind === 'visit' ? sqlEscape(classification.visit_id) : `(SELECT entity_id FROM entity_source_links WHERE entity_type='note' AND source_system='jobber' AND source_id=${sqlEscape(note.id)} LIMIT 1)`},
               'other',
               ${sqlEscape((note.message || '').slice(0, 500) || null)}
        FROM pins
        ON CONFLICT (photo_id, entity_type, entity_id, role) DO NOTHING
      )
      INSERT INTO entity_source_links (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence, synced_at)
      SELECT 'photo', pins.id, 'jobber', ${sqlEscape(u.jobber_file_id)}, ${sqlEscape(u.file_name)}, 'api_pull', 1.00, now()
      FROM pins
      ON CONFLICT (entity_type, source_system, source_id) DO NOTHING;
    `);
  }

  parts.push('COMMIT;');
  const sql = parts.join('\n');

  if (DRY_RUN) {
    const target = classification.kind === 'visit'
      ? `visit #${classification.visit_id}`
      : `non_visit (client-scoped note)`;
    console.log(`    [dry-run] note ${note.id.slice(-16)} → ${target}, ${uploadedAttachments.length} attachments`);
    return;
  }
  await sbQuery(sql);
}

// ---------------------------------------------------------------------------
// Process one note end-to-end
// ---------------------------------------------------------------------------
async function processNote(context, note, stats) {
  // Idempotency: if note already migrated, skip
  if (await isNoteAlreadyMigrated(note.id)) {
    stats.skipped_already_migrated++;
    return;
  }
  const classification = await classifyNote(context.ourClientId, note.createdAt);
  stats[classification.kind]++;

  const uploads = [];
  if (!SKIP_ATTACHMENTS) {
    for (const att of (note.fileAttachments?.nodes || [])) {
      const check = shouldUploadAttachment(att);
      if (!check.ok) {
        if (check.reason === 'oversized') {
          stats.attachments_skipped_oversized++;
          await logOversizedAttachment(context, note, att, classification);
        } else {
          stats.attachments_skipped_mimetype++;
        }
        continue;
      }
      if (await isPhotoAlreadyMigrated(att.id)) {
        stats.attachments_skipped_already++;
        continue;
      }
      const storagePath = storagePathFor(classification, context.ourClientId, note.id, att);
      if (DRY_RUN) {
        uploads.push({
          storage_path: storagePath,
          file_name: att.fileName,
          content_type: att.contentType,
          size_bytes: att.fileSize,
          taken_at: att.createdAt,
          jobber_file_id: att.id,
        });
        stats.attachments_planned++;
        continue;
      }
      try {
        const buf = await downloadFromUrl(att.url);
        await sbStorageUpload(STORAGE_BUCKET, storagePath, buf, att.contentType);
        uploads.push({
          storage_path: storagePath,
          file_name: att.fileName,
          content_type: att.contentType,
          size_bytes: att.fileSize,
          taken_at: att.createdAt,
          jobber_file_id: att.id,
        });
        stats.attachments_uploaded++;
      } catch (e) {
        stats.attachments_failed++;
        console.log(`    [upload-fail] ${att.id} ${att.fileName}: ${e.message.slice(0, 150)}`);
      }
    }
  }
  await persistNote(context, note, classification, uploads);
  stats.notes_persisted++;
}

// ---------------------------------------------------------------------------
// Iterate our clients that have a Jobber source_id
// ---------------------------------------------------------------------------
async function* iterateClients(lastProcessedId = 0) {
  let offset = 0;
  let yielded = 0;
  while (true) {
    const rows = await sbQuery(`
      SELECT esl.entity_id AS client_id,
             esl.source_id AS jobber_gid,
             c.name AS client_name
      FROM entity_source_links esl
      JOIN clients c ON c.id = esl.entity_id
      WHERE esl.entity_type='client'
        AND esl.source_system='jobber'
        AND esl.entity_id > ${lastProcessedId}
      ORDER BY esl.entity_id
      LIMIT ${CLIENTS_BATCH_SIZE} OFFSET ${offset}
    `);
    if (!rows.length) break;
    for (const row of rows) {
      if (LIMIT && yielded >= LIMIT) return;
      yielded++;
      yield row;
    }
    offset += CLIENTS_BATCH_SIZE;
  }
}

// ---------------------------------------------------------------------------
// Checkpoint helpers
// ---------------------------------------------------------------------------
async function readCheckpoint() {
  const r = await sbQuery(`SELECT rows_pulled, rows_populated, last_run_status FROM sync_cursors WHERE entity='jobber_notes_migration' LIMIT 1`);
  if (r.length) return { last_client_id: r[0].rows_pulled || 0, total_notes: r[0].rows_populated || 0 };
  return { last_client_id: 0, total_notes: 0 };
}

async function writeCheckpoint(lastClientId, totalNotes, status, error = null) {
  const sql = `
    INSERT INTO sync_cursors (entity, rows_pulled, rows_populated, last_run_status, last_run_started, last_run_finished, last_error)
    VALUES ('jobber_notes_migration', ${lastClientId}, ${totalNotes}, ${sqlEscape(status)},
            COALESCE((SELECT last_run_started FROM sync_cursors WHERE entity='jobber_notes_migration'), now()),
            CASE WHEN ${sqlEscape(status)} IN ('completed','failed') THEN now() ELSE NULL END,
            ${sqlEscape(error)})
    ON CONFLICT (entity) DO UPDATE SET
      rows_pulled = EXCLUDED.rows_pulled,
      rows_populated = EXCLUDED.rows_populated,
      last_run_status = EXCLUDED.last_run_status,
      last_run_started = COALESCE(sync_cursors.last_run_started, now()),
      last_run_finished = EXCLUDED.last_run_finished,
      last_error = EXCLUDED.last_error,
      updated_at = now()
  `;
  if (!DRY_RUN) await sbQuery(sql);
}

// ---------------------------------------------------------------------------
// MAIN
// ---------------------------------------------------------------------------
(async () => {
  console.log('============================================================');
  console.log('Jobber notes + photos migration');
  console.log('  Mode            :', DRY_RUN ? 'DRY RUN' : 'EXECUTE');
  console.log('  Resume          :', RESUME);
  console.log('  Limit (clients) :', LIMIT || 'none');
  console.log('  Skip attachments:', SKIP_ATTACHMENTS);
  console.log('  Bucket          :', STORAGE_BUCKET);
  console.log('============================================================\n');

  const stats = {
    clients_processed: 0,
    notes_seen: 0,
    notes_persisted: 0,
    skipped_already_migrated: 0,
    visit: 0,
    non_visit: 0,
    attachments_planned: 0,
    attachments_uploaded: 0,
    attachments_skipped_mimetype: 0,
    attachments_skipped_already: 0,
    attachments_skipped_oversized: 0,
    attachments_failed: 0,
  };

  // Auth sanity
  try {
    const me = await jobberGraphQL(`{ account { name } }`);
    console.log('Jobber auth OK. Account:', me.account?.name || '(unknown)');
    console.log('  Budget:', _budget.available + '/' + _budget.max, '(restore', _budget.rate + '/s)');
  } catch (e) {
    console.error('Jobber auth failed:', e.message);
    process.exit(1);
  }

  // Resume point
  let lastProcessed = 0;
  if (RESUME) {
    const cp = await readCheckpoint();
    lastProcessed = cp.last_client_id;
    stats.notes_persisted = cp.total_notes;
    if (lastProcessed) console.log('Resuming after client #' + lastProcessed + ' (already migrated ' + cp.total_notes + ' notes)\n');
  }

  if (!DRY_RUN) await writeCheckpoint(lastProcessed, stats.notes_persisted, 'running');

  const errors = [];
  try {
    for await (const client of iterateClients(lastProcessed)) {
      stats.clients_processed++;
      console.log(`\n[${stats.clients_processed}] client #${client.client_id} (Jobber ${client.jobber_gid}) — ${client.client_name}`);

      try {
        const notes = await fetchJobberClientNotes(client.jobber_gid);
        console.log(`  ${notes.length} notes from Jobber`);
        for (const note of notes) {
          stats.notes_seen++;
          try {
            await processNote({ ourClientId: client.client_id, clientGid: client.jobber_gid }, note, stats);
          } catch (e) {
            errors.push({ client: client.client_id, note: note.id, error: e.message.slice(0, 300) });
            console.log(`    [note-fail] ${note.id}: ${e.message.slice(0, 150)}`);
          }
        }
      } catch (e) {
        errors.push({ client: client.client_id, error: e.message.slice(0, 300) });
        console.log(`  [client-fail]: ${e.message.slice(0, 200)}`);
      }

      lastProcessed = client.client_id;  // track for final checkpoint
      if (!DRY_RUN) await writeCheckpoint(client.client_id, stats.notes_persisted, 'running');
      console.log(`  running total: ${stats.notes_persisted} notes, ${stats.attachments_uploaded} uploaded | budget ${_budget.available}/${_budget.max}`);
    }
    if (!DRY_RUN) await writeCheckpoint(lastProcessed, stats.notes_persisted, 'success');
  } catch (e) {
    if (!DRY_RUN) await writeCheckpoint(lastProcessed, stats.notes_persisted, 'failed', e.message);
    throw e;
  }

  console.log('\n============================================================');
  console.log('SUMMARY');
  console.log('============================================================');
  Object.entries(stats).forEach(([k, v]) => console.log('  ' + k.padEnd(32) + ' ' + v));
  if (errors.length) {
    console.log('\nErrors (' + errors.length + '):');
    errors.slice(0, 20).forEach(e => console.log('  ' + JSON.stringify(e)));
    if (errors.length > 20) console.log('  ... ' + (errors.length - 20) + ' more');
  }
  process.exit(errors.length && !DRY_RUN ? 2 : 0);
})().catch(e => {
  console.error('\nFATAL:', e.message);
  console.error(e.stack);
  process.exit(1);
});
