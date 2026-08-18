// ============================================================================
// sync_jobber_note_photos.js — ongoing Jobber note-photo diff sync
// ============================================================================
// Keeps each completed Jobber-linked visit's photos IN SYNC with the current
// attachments on that visit's Jobber notes. Unlike the one-time migration (which
// was NOTE-level idempotent and skipped edited notes), this diffs at the
// ATTACHMENT level:
//   ADD    — a Jobber note attachment we don't have  -> download + upload + link.
//   REMOVE — NOTE-ANCHORED (safe): a photo whose OWN Jobber note is STILL on the
//            visit but no longer holds the attachment => Diego removed it from that
//            note. We UNLINK it (delete photo_links + classifications) so it stops
//            showing in the apps immediately, but KEEP the photos row + storage
//            (recoverable — a re-add re-links it; orphan storage is swept by the
//            existing cleanup later). We NEVER touch legacy note-less photos (no
//            note anchor — 82% of Jobber visit-photos are date-matched with no
//            note link and were proven false-removes under a naive diff), and never
//            a note that isn't currently surfaced (deleted/moved => can't confirm).
//
// Scope: completed, Jobber-linked visits with visit_date within --days (default
// 45). --visit=<id> targets one. Only touches Jobber-sourced photos
// (source in jobber_migration / jobber_late_recovery / jobber_note_sync);
// app-uploaded photos are never removed.
//
// Runs every 6h via .github/workflows/jobber-note-photo-sync.yml.
//   node scripts/sync/sync_jobber_note_photos.js [--days=45] [--visit=ID]        # DRY-RUN
//   node scripts/sync/sync_jobber_note_photos.js --execute [--days=45]           # writes
// ============================================================================
const https = require('https');
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const PAT = process.env.SUPABASE_PAT;
const PROJECT = (process.env.SUPABASE_URL || '').match(/https?:\/\/([^.]+)\./)?.[1];
const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
let JOBBER_TOKEN = process.env.JOBBER_ACCESS_TOKEN || null; // env override (local); else refreshed from webhook_tokens
const GQL_VERSION = '2026-04-16';
const STORAGE_BUCKET = 'GT - Visits Images';
const STORAGE_SIZE_LIMIT = 52428800;
const EXECUTE = process.argv.includes('--execute');
const DAYS = Number((process.argv.find(a => a.startsWith('--days=')) || '').split('=')[1] || 45);
// +/- days between a NOTE's createdAt and the visit's date for its attachments to
// belong to that visit. Matches jobber_notes_photos.js NOTE_CLASSIFIER_WINDOW_DAYS.
// NOT the same thing as --days, which only chooses which visits to refresh.
const NOTE_WINDOW_DAYS = Number((process.argv.find(a => a.startsWith('--note-window=')) || '').split('=')[1] || 2);
const ONLY_VISIT = (process.argv.find(a => a.startsWith('--visit=')) || '').split('=')[1] || null;
// Removals default OFF for local dry-runs; the cron passes --enable-remove. Now
// SAFE because removes are NOTE-ANCHORED (only a photo whose own note is still on
// the visit but dropped it) + UNLINK (recoverable), not a naive visit-level diff
// with hard-delete. Extra guards below: skip when Jobber returned ZERO attachments
// for the visit (query blip) and skip any note whose attachment page is truncated.
const ENABLE_REMOVE = process.argv.includes('--enable-remove');
const JOBBER_SOURCES = ['jobber_migration', 'jobber_late_recovery', 'jobber_note_sync'];
const sleep = ms => new Promise(r => setTimeout(r, ms));

function http(opts, body) {
  return new Promise((res, rej) => {
    const r = https.request(opts, x => { const ch = []; x.on('data', c => ch.push(c)); x.on('end', () => res({ status: x.statusCode, headers: x.headers, body: Buffer.concat(ch) })); });
    r.on('error', rej); if (body) r.write(body); r.end();
  });
}
async function pg(sql, retries = 4) {
  const body = JSON.stringify({ query: sql });
  let r;
  try {
    r = await http({ hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, body);
  } catch (e) { // transient network/DNS blip (e.g. ENOTFOUND) — retry with backoff so one drop doesn't kill a long backfill
    if (retries > 0) { await sleep((5 - retries) * 2000); return pg(sql, retries - 1); }
    throw e;
  }
  if (r.status >= 300) {
    if (retries > 0 && (r.status === 429 || r.status >= 500)) { await sleep((5 - retries) * 2000); return pg(sql, retries - 1); }
    throw new Error(`DB ${r.status}: ${r.body.toString().slice(0, 300)}`);
  }
  return JSON.parse(r.body.toString());
}
async function gql(query, variables, retries = 5) {
  const body = JSON.stringify({ query, variables });
  const r = await http({ hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST', headers: { Authorization: `Bearer ${JOBBER_TOKEN}`, 'X-JOBBER-GRAPHQL-VERSION': GQL_VERSION, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, body);
  if (r.status >= 300) { if (r.status === 401 && retries > 0) { JOBBER_TOKEN = await getReadToken(true); return gql(query, variables, retries - 1); } if (retries > 0 && (r.status === 429 || r.status >= 500)) { await sleep((6 - retries) * 4000); return gql(query, variables, retries - 1); } throw new Error(`Jobber ${r.status}: ${r.body.toString().slice(0, 200)}`); }
  const j = JSON.parse(r.body.toString());
  if (j.errors) { if (j.errors.some(e => e.extensions?.code === 'THROTTLED') && retries > 0) { await sleep((6 - retries) * 5000); return gql(query, variables, retries - 1); } throw new Error(`Jobber GQL: ${JSON.stringify(j.errors).slice(0, 300)}`); }
  const rem = j.extensions?.cost?.throttleStatus?.currentlyAvailable;
  if (rem != null && rem < 6000) await sleep(Math.ceil((6000 - rem) / 500) * 1000);
  return j.data;
}
async function downloadFromUrl(url) { const u = new URL(url); const r = await http({ hostname: u.hostname, path: u.pathname + u.search, method: 'GET' }); if (r.status >= 300) throw new Error(`Download ${r.status}`); return { body: r.body, contentType: r.headers['content-type'] }; }
async function storageUpload(path, buf, ct) { const host = SUPABASE_URL.replace('https://', ''); const enc = encodeURIComponent(STORAGE_BUCKET) + '/' + path.split('/').map(encodeURIComponent).join('/'); const r = await http({ hostname: host, path: '/storage/v1/object/' + enc, method: 'POST', headers: { Authorization: 'Bearer ' + SVC, apikey: SVC, 'Content-Type': ct || 'application/octet-stream', 'Content-Length': buf.length, 'x-upsert': 'true' } }, buf); if (r.status >= 300) throw new Error(`Storage up ${r.status}: ${r.body.toString().slice(0, 150)}`); }
async function storageDelete(path) { const host = SUPABASE_URL.replace('https://', ''); const enc = encodeURIComponent(STORAGE_BUCKET) + '/' + path.split('/').map(encodeURIComponent).join('/'); const r = await http({ hostname: host, path: '/storage/v1/object/' + enc, method: 'DELETE', headers: { Authorization: 'Bearer ' + SVC, apikey: SVC } }, null); if (r.status >= 300 && r.status !== 404) throw new Error(`Storage del ${r.status}`); }
const sqlEsc = v => v == null ? 'NULL' : (typeof v === 'number' ? String(v) : "'" + String(v).replace(/'/g, "''") + "'");
const extOf = (ct, name) => { const m = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/heic': 'heic', 'image/webp': 'webp', 'application/pdf': 'pdf' }; if (ct && m[ct.toLowerCase().split(';')[0]]) return m[ct.toLowerCase().split(';')[0]]; if (name && name.includes('.')) return name.split('.').pop().toLowerCase().slice(0, 5); return 'bin'; };

// Read Jobber READ token from webhook_tokens (source_system='jobber'), refreshing
// if near expiry — so the cron needs no static token secret. Env var wins if set.
async function getReadToken(force) {
  const rows = await pg(`SELECT access_token, refresh_token, client_id, client_secret, expires_at FROM public.webhook_tokens WHERE source_system='jobber'`);
  const t = rows[0]; if (!t) throw new Error('no jobber read token in webhook_tokens');
  if (!force && new Date(t.expires_at).getTime() > Date.now() + 120000) return t.access_token;
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(t.refresh_token)}&client_id=${encodeURIComponent(t.client_id)}&client_secret=${encodeURIComponent(t.client_secret)}`;
  const r = await http({ hostname: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) } }, body);
  if (r.status >= 300) throw new Error(`read token refresh ${r.status}`);
  const j = JSON.parse(r.body.toString());
  const exp = JSON.parse(Buffer.from(j.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await pg(`UPDATE public.webhook_tokens SET access_token=${sqlEsc(j.access_token)}, refresh_token=${sqlEsc(j.refresh_token || t.refresh_token)}, expires_at=${sqlEsc(new Date(exp).toISOString())}, updated_at=now() WHERE source_system='jobber'`);
  return j.access_token;
}

(async () => {
  console.log(`sync_jobber_note_photos  ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}${ENABLE_REMOVE ? ' +remove' : ' (add-only)'}  ${ONLY_VISIT ? `visit=${ONLY_VISIT}` : `last ${DAYS}d`}`);
  if (!JOBBER_TOKEN) JOBBER_TOKEN = await getReadToken();
  const target = await pg(`
    SELECT v.id AS visit_id, v.client_id, v.visit_date, v.completed_at, esl.source_id AS visit_gid, c.client_code
    FROM visits v
    JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
    JOIN clients c ON c.id=v.client_id
    WHERE v.visit_status='completed' AND v.deleted_at IS NULL
      ${ONLY_VISIT ? `AND v.id=${Number(ONLY_VISIT)}` : `AND v.visit_date >= (current_date - ${DAYS})`}
    ORDER BY v.id`);
  console.log(`${target.length} visit(s) to check`);
  let added = 0, removed = 0, errors = 0, changedVisits = 0, windowSkipped = 0;

  for (const t of target) {
    // our jobber-sourced photos for THIS visit: att_gid + the Jobber note it came
    // from (note_gid; NULL for legacy date-matched photos with no note anchor).
    const ours = await pg(`
      SELECT ph.id AS photo_id, ph.storage_path, esl.source_id AS att_gid,
        (SELECT nesl.source_id FROM photo_links pn
           JOIN entity_source_links nesl ON nesl.entity_type='note' AND nesl.entity_id=pn.entity_id AND nesl.source_system='jobber'
         WHERE pn.photo_id=ph.id AND pn.entity_type='note' LIMIT 1) AS note_gid
      FROM photo_links pl JOIN photos ph ON ph.id=pl.photo_id
      JOIN entity_source_links esl ON esl.entity_type='photo' AND esl.entity_id=ph.id AND esl.source_system='jobber'
      WHERE pl.entity_type='visit' AND pl.entity_id=${t.visit_id} AND ph.source IN (${JOBBER_SOURCES.map(sqlEsc).join(',')})`);
    const ourByGid = new Map(ours.map(r => [r.att_gid, r]));

    // current Jobber attachments on this visit's notes: gid -> att
    let notes = [], cursor = null;
    try {
      do {
        const d = await gql(`query($id:EncodedId!,$after:String){ visit(id:$id){ notes(first:10,after:$after){ nodes{ __typename
          ... on ClientNote { id pinned message createdAt fileAttachments(first:100){ nodes{ id fileName contentType fileSize url } pageInfo{ hasNextPage } } }
          ... on JobNote    { id pinned message createdAt fileAttachments(first:100){ nodes{ id fileName contentType fileSize url } pageInfo{ hasNextPage } } }
        } pageInfo{ hasNextPage endCursor } } } }`, { id: t.visit_gid, after: cursor });
        const vn = d.visit?.notes; if (!vn) break; notes.push(...vn.nodes); cursor = vn.pageInfo.hasNextPage ? vn.pageInfo.endCursor : null;
      } while (cursor && notes.length < 200);
    } catch (e) { errors++; console.log(`  v${t.visit_id} ${t.client_code} ERR: ${e.message.slice(0, 70)}`); continue; }

    // curAtt: every current attachment (for the empty-guard + remove context).
    // noteAtts: per-note attachment set (for note-anchored REMOVE). incompleteNotes:
    // notes whose attachment page is truncated (>100) — excluded from removes.
    // 🛑 CORRECTED 2026-08-14. The comment that used to sit here said "JobNotes are
    // visit/job-specific, while ClientNotes are CLIENT-level ... attaching them
    // per-visit over-attaches". The first half is FALSE and it was the whole bug.
    // Jobber's `Visit.notes` is documented by Jobber as "The notes attached to the
    // associated JOB" (JobNoteUnionConnection), so EVERY visit of a recurring job
    // returns that job's ENTIRE note history, identically. Confirmed live: visits
    // 6826 (2026-06-27) and 7743 (2026-08-10), both on job 1720, returned the same
    // 16 notes and the same 42 attachments.
    // The ClientNote filter below is correct and stays, but it never was the
    // protection it looked like: it closed the client-level leak while the
    // job-level one produced 2,600 surplus links between 2026-07-01 and 2026-08-14.
    // Full audit: docs/audits/2026-08-14_photo_note_linking_audit.md
    // ⇒ The JobNote check is NOT sufficient on its own. The note-date window added
    //   below is what actually binds an attachment to THIS visit.
    const curAtt = new Map(); const noteAtts = new Map(); const incompleteNotes = new Set(); const jobNoteGids = new Set();
    for (const n of notes) {
      // 🛑 PINNED JOB NOTES ARE NOT SKIPPED ANY MORE (2026-08-18). `if (n.pinned) continue`
      // sat here from this file's first commit with no written rationale, and it was measured
      // to lose a real visit photo: visit 6840 (031-KRU), a driver's "3 manholes, located at
      // front of the restaurant" JobNote with a photo, pinned, within the window — skipped by
      // 13 consecutive sweeps while the audit kept flagging it missing. The pin is a Jobber UI
      // prominence flag, not a statement about content; the NOTE-DATE WINDOW below is the
      // attribution guard, and it applies to pinned notes identically (a months-old pinned
      // note fails the window and stays out). Pinned CLIENT notes remain excluded: they are
      // standing instructions/albums, client-level, and the ClientNote filter excludes them
      // from ADD anyway — keeping them out of the maps also keeps the REMOVE arm off them.
      // ⚠ The audit probe must fetch `pinned` too, or this class is invisible to it
      // (scripts/probes/audit_august_photos_vs_jobber.js).
      if (n.pinned && n.__typename === 'ClientNote') continue;
      const fa = n.fileAttachments;
      if (fa?.pageInfo?.hasNextPage) incompleteNotes.add(n.id);
      if (n.__typename === 'JobNote') jobNoteGids.add(n.id);
      noteAtts.set(n.id, new Set((fa?.nodes || []).map(f => f.id)));
      for (const f of (fa?.nodes || [])) curAtt.set(f.id, { ...f, noteGid: n.id, noteMsg: n.message || '', noteType: n.__typename, noteCreatedAt: n.createdAt || null });
    }

    // ±NOTE_WINDOW_DAYS between the NOTE's own createdAt and this visit's date.
    // This is the same rule scripts/migrate/jobber_notes_photos.js has always used
    // (NOTE_CLASSIFIER_WINDOW_DAYS = 2) and the one Fred expects the system to obey.
    // 🛑 FAILS CLOSED: no parseable note date => the attachment is NOT linked.
    // recover_visit_note_photos_window2d.js does `Math.abs(a-b) > window`, which is
    // false for NaN and therefore fails OPEN. Do not copy that shape.
    const visitMs = Date.parse(`${String(t.visit_date).slice(0, 10)}T12:00:00Z`);
    const withinWindow = (iso) => {
      if (!iso) return false;
      const n = Date.parse(iso);
      if (!Number.isFinite(n) || !Number.isFinite(visitMs)) return false;
      return Math.abs(n - visitMs) <= NOTE_WINDOW_DAYS * 86400000;
    };

    const jobNoteCandidates = [...curAtt.keys()].filter(g => curAtt.get(g).noteType === 'JobNote' && !ourByGid.has(g));
    const inWindow = jobNoteCandidates.filter(g => withinWindow(curAtt.get(g).noteCreatedAt));
    const skippedByWindow = jobNoteCandidates.length - inWindow.length;

    // 🛑 NEAREST-VISIT TIE-BREAK (2026-08-18). Two completed visits of one job within 4 days
    // of each other both satisfy the ±2d window for the same note, and this loop processes
    // visits independently — so the same attachment was linked to BOTH (measured live: the
    // 18:21Z sweep attached 3 photos to both 155-PV visits 7770 and 7802 minutes after the
    // audit predicted it; 56 such ambiguous pairs existed in August). A photo on two visits
    // ends up in two city emails.
    // Rule: the note's photos belong to the visit whose date is NEAREST the note date. Skip
    // the add when a STRICTLY closer sibling visit exists (completed, alive, same job) —
    // whether or not it has been processed yet; the sweep will link it there on its turn.
    // Exact ties keep today's dual-link behaviour (rare, and a human classifies anyway).
    // ⚠ This changes only future ADDs. Existing in-window links are untouched, per Fred's
    // 2026-08-14 ruling ("keep the ones inside the 2 day window").
    // 🛑 THE TIE-BREAK COMPARES COMPLETION TIMESTAMPS, THE WINDOW STILL COMPARES DATES.
    // Two anchors on purpose (2026-08-18, Fred: "we have a better and certain linking"):
    //   * ELIGIBILITY (who is allowed to take the photo) stays on noon(visit_date), because
    //     that is exactly how each sibling will judge its own window when its turn comes.
    //     If eligibility were judged on completed_at here, this visit could hand the photo
    //     to a sibling that then REFUSES it on its own pass, and the photo would land
    //     NOWHERE. Losing a photo is worse than dual-linking one.
    //   * DISTANCE (who is nearest) uses completed_at, which is strictly more precise.
    // Why it matters, measured over 180 days: 11 same-job pairs share a visit_date, so a
    // date-only distance is an exact tie and both visits keep the photo. Their crews are
    // identical in 11 of 11 cases (so the note's author cannot break the tie) but their
    // completed_at differs in 11 of 11 (249-LOU 2026-08-14: 18:10 vs 07:07, eleven hours).
    // A visit with no completed_at falls back to noon(visit_date); mixing anchors is fine,
    // the comparison only needs a total order, and each side uses its best available time.
    let toAdd = inWindow;
    if (inWindow.length) {
      const sibs = await pg(`SELECT v2.id, v2.visit_date, v2.completed_at FROM visits v2
        WHERE v2.job_id = (SELECT job_id FROM visits WHERE id=${t.visit_id})
          AND v2.id <> ${t.visit_id} AND v2.deleted_at IS NULL AND v2.visit_status='completed'`);
      if (sibs.length) {
        const noonMs = (d) => Date.parse(`${String(d).slice(0, 10)}T12:00:00Z`);
        // 🛑 completed_at IS ONLY TRUSTED WHEN IT IS NEAR THE VISIT DATE. It records when
        // someone MARKED the visit complete, not when the work happened: measured over the
        // last 365 days, 109 of 1,072 completed visits (10%) sit more than 24h from their
        // own visit_date, 11 of them beyond 7 days, worst case 819h (34 days). Feeding a
        // late admin marking into the distance would pull a photo onto the wrong sibling
        // with more confidence than the date rule it replaced. 963 of 1,072 (90%) are
        // within 24h, which also covers the overnight routes, so that is the cutoff.
        const COMPLETED_TRUST_MS = 24 * 3600000;
        const anchorOf = (completedAt, visitDate) => {
          const noon = noonMs(visitDate);
          const c = completedAt ? Date.parse(completedAt) : NaN;
          if (!Number.isFinite(c)) return noon;
          if (!Number.isFinite(noon)) return c;
          return Math.abs(c - noon) <= COMPLETED_TRUST_MS ? c : noon;
        };
        const myAnchor = anchorOf(t.completed_at, t.visit_date);
        toAdd = inWindow.filter(g => {
          const noteTs = Date.parse(curAtt.get(g).noteCreatedAt);
          const myDist = Math.abs(noteTs - myAnchor);
          const closer = sibs.some(sv => {
            const eligible = Math.abs(noteTs - noonMs(sv.visit_date)) <= NOTE_WINDOW_DAYS * 86400000;
            return eligible && Math.abs(noteTs - anchorOf(sv.completed_at, sv.visit_date)) < myDist;
          });
          if (closer) console.log(`    tie-break: ${curAtt.get(g).fileName} goes to a closer sibling visit, skipping here`);
          return !closer;
        });
      }
    }
    if (skippedByWindow > 0) windowSkipped += skippedByWindow;
    // NOTE-ANCHORED remove: only a JOB-note photo whose own note is STILL on the visit
    // (positive confirmation it exists) but no longer holds this attachment. Legacy
    // note-less photos, client-note photos, and photos on a truncated/absent note are
    // never removed (symmetric with add: the sync only manages job-note→visit links).
    const removable = r => r.note_gid && jobNoteGids.has(r.note_gid) && noteAtts.has(r.note_gid) && !incompleteNotes.has(r.note_gid) && !noteAtts.get(r.note_gid).has(r.att_gid);
    const toRemove = ENABLE_REMOVE ? ours.filter(removable) : [];
    const doRemove = ENABLE_REMOVE && curAtt.size > 0 && toRemove.length > 0; // guard: never remove on an empty Jobber response
    const wouldRemoveGated = !ENABLE_REMOVE ? ours.filter(removable).length : 0;
    if (!toAdd.length && !doRemove) continue;
    changedVisits++;
    console.log(`  v${t.visit_id} ${t.client_code}: +${toAdd.length} add${doRemove ? `, -${toRemove.length} remove` : (wouldRemoveGated ? `, (${wouldRemoveGated} would-remove — gated)` : '')}`);
    if (!EXECUTE) { added += toAdd.length; if (doRemove) removed += toRemove.length; continue; }

    // ADD (dedup-safe): if this attachment gid already exists as a photo anywhere,
    // just LINK that existing photo to the visit + note; only download when it's
    // genuinely new. Keying existence on the GLOBAL att_gid esl (not the visit-scoped
    // set) is what prevents duplicate rows when the same file is on multiple visits
    // or was captured earlier under a different storage path.
    for (const g of toAdd) {
      const att = curAtt.get(g);
      try {
        // ensure note row (job note -> visit-scoped)
        let noteRow = await pg(`SELECT entity_id FROM entity_source_links WHERE entity_type='note' AND source_system='jobber' AND source_id=${sqlEsc(att.noteGid)} LIMIT 1`);
        let noteId = noteRow[0]?.entity_id;
        if (!noteId) { const ins = await pg(`INSERT INTO notes (client_id, visit_id, body, note_date, source) VALUES (${t.client_id}, ${t.visit_id}, ${sqlEsc(att.noteMsg)}, ${att.noteCreatedAt ? sqlEsc(att.noteCreatedAt) : 'now()'}, 'jobber_note_sync') RETURNING id`); noteId = ins[0].id; await pg(`INSERT INTO entity_source_links (entity_type,entity_id,source_system,source_id) VALUES ('note',${noteId},'jobber',${sqlEsc(att.noteGid)}) ON CONFLICT (entity_type,source_system,source_id) DO NOTHING`); }
        // reuse an existing photo for this attachment gid ONLY if the photo row still
        // exists — there are ~4k stale photo esls (source_system='jobber') pointing at
        // photos a historical cleanup deleted (esl has no cascade). The JOIN filters
        // those out so we don't hand a dangling photo_id to the FK; the DO UPDATE below
        // then repoints the stale esl to the freshly downloaded photo.
        let photoId = (await pg(`SELECT esl.entity_id AS id FROM entity_source_links esl JOIN photos ph ON ph.id=esl.entity_id WHERE esl.entity_type='photo' AND esl.source_system='jobber' AND esl.source_id=${sqlEsc(g)} LIMIT 1`))[0]?.id;
        if (!photoId) {
          if (!att.url || (att.fileSize && att.fileSize > STORAGE_SIZE_LIMIT)) { console.log(`    skip ${att.fileName} (no url / oversized)`); continue; }
          const dl = await downloadFromUrl(att.url); const ext = extOf(dl.contentType || att.contentType, att.fileName);
          const path = `notes/${t.client_id}/${att.noteGid}/${g}.${ext}`;
          await storageUpload(path, dl.body, dl.contentType);
          const p = await pg(`INSERT INTO photos (storage_path,file_name,content_type,size_bytes,source) VALUES (${sqlEsc(path)},${sqlEsc(att.fileName || g + '.' + ext)},${sqlEsc(dl.contentType || null)},${dl.body.length},'jobber_note_sync') ON CONFLICT (storage_path) DO UPDATE SET storage_path=EXCLUDED.storage_path RETURNING id`);
          photoId = p[0].id;
          await pg(`INSERT INTO entity_source_links (entity_type,entity_id,source_system,source_id) VALUES ('photo',${photoId},'jobber',${sqlEsc(g)}) ON CONFLICT (entity_type,source_system,source_id) DO UPDATE SET entity_id=EXCLUDED.entity_id`);
        }
        await pg(`INSERT INTO photo_links (photo_id,entity_type,entity_id,role) VALUES (${photoId},'note',${noteId},'attachment') ON CONFLICT (photo_id,entity_type,entity_id,role) DO NOTHING;
                  INSERT INTO photo_links (photo_id,entity_type,entity_id,role) VALUES (${photoId},'visit',${t.visit_id},'other') ON CONFLICT (photo_id,entity_type,entity_id,role) DO NOTHING`);
        added++;
      } catch (e) { errors++; console.log(`    add ${g} ERR: ${e.message.slice(0, 70)}`); }
    }
    // REMOVE (note-anchored UNLINK): drop the photo's links + classifications so it
    // stops showing in the apps; keep the photos row + entity_source_link + storage
    // (recoverable; a re-add re-links, orphan storage swept by cleanup later).
    if (doRemove) for (const r of toRemove) {
      try {
        // SCOPED 2026-08-14. These used to be `WHERE photo_id=${r.photo_id}` with no
        // entity predicate, so one visit deciding a photo was removable would have
        // deleted that photo's link on EVERY other visit and its note anchor too, and
        // cascaded to all of its classifications. It never fired (0 removals in 151
        // runs) only because the trigger condition was unreachable, not because
        // anything prevented it. Only ever unlink the visit being processed.
        await pg(`DELETE FROM photo_classifications WHERE photo_link_id IN (
                    SELECT id FROM photo_links WHERE photo_id=${r.photo_id}
                     AND entity_type='visit' AND entity_id=${t.visit_id})`);
        await pg(`DELETE FROM photo_links WHERE photo_id=${r.photo_id}
                   AND entity_type='visit' AND entity_id=${t.visit_id}`);
        removed++;
      } catch (e) { errors++; console.log(`    remove ${r.att_gid} ERR: ${e.message.slice(0, 70)}`); }
    }
    await sleep(80);
  }
  console.log(`\n=== ${EXECUTE ? 'DONE' : 'DRY-RUN'} === visits changed: ${changedVisits} | photos added: ${added} | removed: ${removed} | skipped by note-window: ${windowSkipped} | errors: ${errors}`);
  if (EXECUTE) await pg(`INSERT INTO public.sync_log (sync_source, started_at, finished_at, rows_updated, rows_errored, status, details) VALUES ('jobber_note_photo_sync', now(), now(), ${added + removed}, ${errors}, ${errors ? "'partial'" : "'success'"}, ${sqlEsc(JSON.stringify({ added, removed, changedVisits, days: DAYS }))})`).catch(() => {});
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
