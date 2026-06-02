// audit_jobber_photos_full.js
//
// Comprehensive audit comparing Jobber note file-attachments to our DB.
//
// For each JobNote in Jobber that has fileAttachments:
//   - Is the note tracked in our entity_source_links (entity_type='note')?
//   - Is each attached file tracked in our entity_source_links (entity_type='photo')?
//   - Is the photo linked to the right visit in photo_links (entity_type='visit')?
//
// Output categories:
//   A. Jobber has, we have, linked correctly ✓
//   B. Jobber has, we have, NOT linked to visit (orphan in DB)
//   C. Jobber has, we DON'T have (missing — biggest concern)
//   D. We have, Jobber doesn't (stale — probably files Jobber deleted)
//
// Scope (configurable):
//   - Default: all completed jobs (could be N×M expensive)
//   - --since=YYYY-MM-DD : limit to jobs/visits since date
//   - --limit-jobs=N : cap number of jobs to scan
//
// Usage:
//   node scripts/probes/audit_jobber_photos_full.js --since=2026-04-01
//   node scripts/probes/audit_jobber_photos_full.js --since=2026-04-01 --limit-jobs=100

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const SINCE = (process.argv.find(a => a.startsWith('--since=')) || '').split('=')[1] || null;
const LIMIT_JOBS = parseInt((process.argv.find(a => a.startsWith('--limit-jobs=')) || '').split('=')[1] || '0', 10);

function pgQ(sql) {
  return new Promise((res, rej) => {
    const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + PROD + '/database/query', method: 'POST',
      headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json' } },
      x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(JSON.parse(b))); });
    req.on('error', rej); req.write(JSON.stringify({ query: sql })); req.end();
  });
}

async function getJobberToken() {
  const r = await pgQ(`SELECT access_token, expires_at FROM webhook_tokens WHERE source_system='jobber';`);
  return r[0].access_token;
}

async function jobber(query, variables, attempt = 1) {
  const token = await getJobberToken();
  const resp = await new Promise((res, rej) => {
    const opts = { hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
      headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' } };
    const req = https.request(opts, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(JSON.parse(b))); });
    req.on('error', rej);
    req.write(JSON.stringify({ query, variables: variables || {} })); req.end();
  });
  // Throttle handling: retry with exponential backoff
  const throttled = resp.errors?.some(e => e.extensions?.code === 'THROTTLED');
  if (throttled && attempt < 5) {
    const waitSec = Math.min(30, 3 * Math.pow(2, attempt - 1));
    console.log(`  [throttled, attempt ${attempt}] waiting ${waitSec}s...`);
    await new Promise(rs => setTimeout(rs, waitSec * 1000));
    return jobber(query, variables, attempt + 1);
  }
  return resp;
}

const NOTES_QUERY = `
  query JobsWithNotes($after: String, $first: Int!, $since: ISO8601DateTime) {
    jobs(first: $first, after: $after, filter: { startAt: { after: $since } }, sort: [{ key: VISIT_START_DATE, direction: ASCENDING }]) {
      pageInfo { endCursor hasNextPage }
      nodes {
        id
        startAt
        notes(first: 15) {
          nodes {
            ... on JobNote {
              id
              createdAt
              message
              fileAttachments(first: 10) {
                nodes {
                  id
                  fileName
                  contentType
                }
              }
            }
          }
        }
      }
    }
  }`;

(async () => {
  console.log('='.repeat(72));
  console.log('AUDIT: Jobber note file-attachments vs our DB');
  console.log('Scope:', SINCE ? `since ${SINCE}` : 'all jobs', LIMIT_JOBS ? `(limit ${LIMIT_JOBS} jobs)` : '');
  console.log('='.repeat(72));

  // Step 1: Inventory all Jobber file attachments via jobs → notes → fileAttachments
  const sinceISO = SINCE ? new Date(SINCE).toISOString() : '2020-01-01T00:00:00Z';
  const jobberFiles = new Map(); // file_id → { note_id, job_id, fileName, contentType, jobStartAt }
  const jobberNotes = new Map(); // note_id → { job_id, hasAttachments }
  let cursor = null;
  let scanned = 0;

  console.log('\n[1] Fetching Jobber jobs + notes + attachments...');
  while (true) {
    // Pace: wait 2s between pages to let throttle bucket refill
    if (cursor) await new Promise(rs => setTimeout(rs, 2000));
    const resp = await jobber(NOTES_QUERY, { after: cursor, first: 5, since: sinceISO });
    if (resp.errors) {
      console.error('Jobber error:', JSON.stringify(resp.errors).slice(0, 300));
      break;
    }
    const data = resp.data?.jobs;
    if (!data) break;
    for (const job of data.nodes) {
      const noteNodes = job.notes?.nodes || [];
      for (const note of noteNodes) {
        if (!note?.id) continue;
        const files = note.fileAttachments?.nodes || [];
        jobberNotes.set(note.id, { job_id: job.id, hasAttachments: files.length > 0, fileCount: files.length });
        for (const f of files) {
          jobberFiles.set(f.id, { note_id: note.id, job_id: job.id, fileName: f.fileName, contentType: f.contentType, jobStartAt: job.startAt });
        }
      }
    }
    scanned += data.nodes.length;
    if (LIMIT_JOBS && scanned >= LIMIT_JOBS) break;
    if (!data.pageInfo?.hasNextPage) break;
    cursor = data.pageInfo.endCursor;
    process.stdout.write(`\r  jobs scanned: ${scanned}, notes: ${jobberNotes.size}, files: ${jobberFiles.size}`);
  }
  console.log(`\n  TOTAL: ${scanned} jobs, ${jobberNotes.size} notes, ${jobberFiles.size} file attachments in Jobber`);

  // Step 2: Pull our DB's view of these
  console.log('\n[2] Querying our DB for Jobber photo + note source links...');
  const dbPhotos = await pgQ(`
    SELECT esl.source_id AS jobber_file_id, esl.entity_id AS photo_id,
           p.storage_path,
           (SELECT COUNT(*) FROM photo_links pl WHERE pl.photo_id = p.id AND pl.entity_type='visit') AS link_count
    FROM entity_source_links esl
    JOIN photos p ON p.id = esl.entity_id
    WHERE esl.source_system='jobber' AND esl.entity_type='photo';
  `);
  const dbPhotoMap = new Map(dbPhotos.map(r => [r.jobber_file_id, r]));
  console.log(`  ${dbPhotos.length} Jobber-sourced photos in our DB`);

  const dbNotes = await pgQ(`
    SELECT esl.source_id AS jobber_note_id, esl.entity_id AS note_id,
           n.visit_id
    FROM entity_source_links esl
    JOIN notes n ON n.id = esl.entity_id
    WHERE esl.source_system='jobber' AND esl.entity_type='note';
  `);
  const dbNoteMap = new Map(dbNotes.map(r => [r.jobber_note_id, r]));
  console.log(`  ${dbNotes.length} Jobber-sourced notes in our DB`);

  // Step 3: Cross-reference
  console.log('\n[3] Cross-referencing...');
  const buckets = {
    A_matched_linked: [],          // file in Jobber + our DB + linked to visit
    B_matched_unlinked: [],         // file in Jobber + our DB, but NOT linked to any visit
    C_missing_in_db: [],            // file in Jobber, NOT in our DB
    D_orphan_in_db: [],             // file in our DB, NOT in Jobber (within scope)
    E_note_missing: [],             // Jobber note not in our DB
  };

  for (const [fileId, info] of jobberFiles) {
    const dbPhoto = dbPhotoMap.get(fileId);
    if (!dbPhoto) {
      buckets.C_missing_in_db.push({ fileId, ...info });
    } else if (dbPhoto.link_count === 0) {
      buckets.B_matched_unlinked.push({ fileId, photoId: dbPhoto.photo_id, ...info });
    } else {
      buckets.A_matched_linked.push({ fileId, photoId: dbPhoto.photo_id, ...info });
    }
  }
  for (const [noteId, info] of jobberNotes) {
    if (!dbNoteMap.has(noteId) && info.hasAttachments) {
      buckets.E_note_missing.push({ noteId, ...info });
    }
  }
  // Find orphans (in DB, attachments only)
  for (const [jobberFileId, photo] of dbPhotoMap) {
    if (!jobberFiles.has(jobberFileId)) {
      buckets.D_orphan_in_db.push({ jobberFileId, photoId: photo.photo_id, storage_path: photo.storage_path });
    }
  }

  // Step 4: Report
  console.log('\n' + '='.repeat(72));
  console.log('SUMMARY');
  console.log('='.repeat(72));
  console.log(`A. Jobber + DB + linked-to-visit  : ${buckets.A_matched_linked.length}`);
  console.log(`B. Jobber + DB, NOT linked        : ${buckets.B_matched_unlinked.length}`);
  console.log(`C. Jobber HAS, DB DOES NOT        : ${buckets.C_missing_in_db.length}   (← biggest concern)`);
  console.log(`D. DB has, Jobber doesn't (orphan): ${buckets.D_orphan_in_db.length}   (only meaningful for unscoped runs)`);
  console.log(`E. Notes-with-attachments missing : ${buckets.E_note_missing.length}`);

  // Show samples
  console.log('\nSample C (missing in DB) — first 5:');
  buckets.C_missing_in_db.slice(0, 5).forEach(x => console.log(`  ${x.fileName || '(no name)'} (${x.contentType}) — job ${x.job_id.slice(-12)} started ${x.jobStartAt}`));

  console.log('\nSample B (matched but unlinked) — first 5:');
  buckets.B_matched_unlinked.slice(0, 5).forEach(x => console.log(`  photo_id=${x.photoId} jobber_file=${x.fileId.slice(-20)}`));

  console.log('\nSample E (notes-with-files we never received) — first 5:');
  buckets.E_note_missing.slice(0, 5).forEach(x => console.log(`  jobber_note=${x.noteId.slice(-20)} job=${x.job_id.slice(-12)} files=${x.fileCount}`));

  // Save full results for offline analysis
  const fs = require('fs');
  const out = {
    scope: { since: SINCE, limit_jobs: LIMIT_JOBS },
    counts: {
      A_matched_linked: buckets.A_matched_linked.length,
      B_matched_unlinked: buckets.B_matched_unlinked.length,
      C_missing_in_db: buckets.C_missing_in_db.length,
      D_orphan_in_db: buckets.D_orphan_in_db.length,
      E_note_missing: buckets.E_note_missing.length,
    },
    jobber_total: { jobs: scanned, notes: jobberNotes.size, files: jobberFiles.size },
    db_total: { photos: dbPhotos.length, notes: dbNotes.length },
    samples: {
      C_missing_in_db: buckets.C_missing_in_db.slice(0, 50),
      B_matched_unlinked: buckets.B_matched_unlinked.slice(0, 50),
      E_note_missing: buckets.E_note_missing.slice(0, 50),
    }
  };
  fs.writeFileSync('audit_jobber_photos_results.json', JSON.stringify(out, null, 2));
  console.log('\nFull results: audit_jobber_photos_results.json');
})().catch(e => { console.error('FATAL:', e); process.exit(2); });
