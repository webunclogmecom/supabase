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
// Runs hourly on Railway (service note-photo, services/timed-jobs/services.json) since Trello #247 (2026-11-24);
// the GitHub workflow .github/workflows/jobber-note-photo-sync.yml stays as a manual button.
//   node scripts/sync/sync_jobber_note_photos.js [--days=45|auto] [--visit=ID]   # DRY-RUN
//   node scripts/sync/sync_jobber_note_photos.js --execute [--days=45|auto]      # writes
// --days=auto: 14 when the run starts in the 05 UTC hour (the daily full sweep), else 3.
//
// 🛑 DATABASE ACCESS: the normal API with the server key (SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY), header
// x-app-source: note-photo-sync. Until 2026-11-24 it used the Supabase admin API with the account-wide token, whose
// rate limit (429) caused every failure the job ever had. The three joined reads are the service_role-only functions
// public.note_photo_sync_targets / _visit / _photo_id (docs/migrations/2026-11-24_1215_note_photo_sync_reads.sql);
// change their SQL there, not here. Locally, .env's SUPABASE_SERVICE_ROLE_KEY is the legacy key (switched off 2026-10-27):
// run with SUPABASE_SERVICE_ROLE_KEY set to a secret key (sb_secret_...).
// ============================================================================
const https = require('https');
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!SUPABASE_URL || !SVC) { console.error('FATAL SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required'); process.exit(1); }
let JOBBER_TOKEN = process.env.JOBBER_ACCESS_TOKEN || null; // env override (local); else refreshed from webhook_tokens
const GQL_VERSION = '2026-04-16';
const STORAGE_BUCKET = 'GT - Visits Images';
const STORAGE_SIZE_LIMIT = 52428800;
const EXECUTE = process.argv.includes('--execute');
const DAYS_ARG = (process.argv.find(a => a.startsWith('--days=')) || '').split('=')[1];
const DAYS = DAYS_ARG === 'auto' ? (new Date().getUTCHours() === 5 ? 14 : 3) : Number(DAYS_ARG || 45);
if (!Number.isInteger(DAYS) || DAYS < 0) { console.error(`FATAL bad --days=${DAYS_ARG}`); process.exit(1); }
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
// One call to the normal API (PostgREST). `path` is after /rest/v1/. Returns the parsed JSON, or null for an empty body.
async function api(method, path, body, prefer, retries = 4) {
  const data = body == null ? null : Buffer.from(JSON.stringify(body));
  const headers = { Authorization: 'Bearer ' + SVC, apikey: SVC, 'x-app-source': 'note-photo-sync', Accept: 'application/json' };
  if (data) { headers['Content-Type'] = 'application/json'; headers['Content-Length'] = data.length; }
  if (prefer) headers.Prefer = prefer;
  let r;
  try {
    r = await http({ hostname: SUPABASE_URL.replace('https://', ''), path: '/rest/v1/' + path, method, headers }, data);
  } catch (e) { // transient network/DNS blip (e.g. ENOTFOUND) — retry with backoff so one drop doesn't kill a long backfill
    if (retries > 0) { await sleep((5 - retries) * 2000); return api(method, path, body, prefer, retries - 1); }
    throw e;
  }
  const where = `${method} ${path.split('?')[0]}`;
  if (r.status >= 300) {
    if (retries > 0 && (r.status === 429 || r.status >= 500)) { await sleep((5 - retries) * 2000); return api(method, path, body, prefer, retries - 1); }
    throw new Error(`DB ${where} ${r.status}: ${r.body.toString().slice(0, 300)}`);
  }
  const txt = r.body.toString();
  if (!txt) return null;
  // a gateway page at HTTP 200 is not an answer (the Jobber "waiting room" lesson, Supabase CLAUDE.md)
  if (!String(r.headers['content-type'] || '').includes('json')) throw new Error(`DB ${where}: not JSON (${r.headers['content-type']})`);
  return JSON.parse(txt);
}
const rpc = (fn, args) => api('POST', 'rpc/' + fn, args);
const q = encodeURIComponent;
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
const extOf = (ct, name) => { const m = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/heic': 'heic', 'image/webp': 'webp', 'application/pdf': 'pdf' }; if (ct && m[ct.toLowerCase().split(';')[0]]) return m[ct.toLowerCase().split(';')[0]]; if (name && name.includes('.')) return name.split('.').pop().toLowerCase().slice(0, 5); return 'bin'; };

// Read Jobber READ token from webhook_tokens (source_system='jobber'), refreshing
// if near expiry — so the cron needs no static token secret. Env var wins if set.
async function getReadToken(force) {
  const rows = await api('GET', 'webhook_tokens?source_system=eq.jobber&select=access_token,refresh_token,client_id,client_secret,expires_at');
  const t = rows[0]; if (!t) throw new Error('no jobber read token in webhook_tokens');
  if (!force && new Date(t.expires_at).getTime() > Date.now() + 120000) return t.access_token;
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(t.refresh_token)}&client_id=${encodeURIComponent(t.client_id)}&client_secret=${encodeURIComponent(t.client_secret)}`;
  const r = await http({ hostname: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) } }, body);
  if (r.status >= 300) throw new Error(`read token refresh ${r.status}`);
  const j = JSON.parse(r.body.toString());
  const exp = JSON.parse(Buffer.from(j.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await api('PATCH', 'webhook_tokens?source_system=eq.jobber', { access_token: j.access_token, refresh_token: j.refresh_token || t.refresh_token, expires_at: new Date(exp).toISOString(), updated_at: new Date().toISOString() }, 'return=minimal');
  return j.access_token;
}

(async () => {
  console.log(`sync_jobber_note_photos  ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}${ENABLE_REMOVE ? ' +remove' : ' (add-only)'}  ${ONLY_VISIT ? `visit=${ONLY_VISIT}` : `last ${DAYS}d`}`);
  if (!JOBBER_TOKEN) JOBBER_TOKEN = await getReadToken();
  const target = await rpc('note_photo_sync_targets', { p_days: DAYS, p_visit: ONLY_VISIT ? Number(ONLY_VISIT) : null });
  console.log(`${target.length} visit(s) to check`);
  let added = 0, removed = 0, errors = 0, changedVisits = 0, windowSkipped = 0;
  // 2026-09-08. These two used to not exist, and that WAS the bug: an attachment we could
  // not ingest incremented neither `added` nor `errors` and reached no counter in
  // sync_log.details, so a permanent failure was byte-identical to a quiet day. Measured
  // before the fix: 6 field videos, 915 MB, 5 clients, silently dropped over 8 days.
  let oversizedSkipped = 0, noUrlSkipped = 0, oversizedBytes = 0;

  for (const t of target) {
    // our jobber-sourced photos for THIS visit: att_gid + the Jobber note it came
    // from (note_gid; NULL for legacy date-matched photos with no note anchor).
    // ours + the completed sibling visits of the same job, in one read (JOBBER_SOURCES is inside the function)
    const vis = await rpc('note_photo_sync_visit', { p_visit: t.visit_id });
    const ours = vis.ours;
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
    } catch (e) { errors++; console.log(`  v${t.visit_id} ERR: ${e.message.slice(0, 70)}`); continue; }

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
      const sibs = vis.sibs;
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
    console.log(`  v${t.visit_id}: +${toAdd.length} add${doRemove ? `, -${toRemove.length} remove` : (wouldRemoveGated ? `, (${wouldRemoveGated} would-remove — gated)` : '')}`);
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
        let noteRow = await api('GET', `entity_source_links?entity_type=eq.note&source_system=eq.jobber&source_id=eq.${q(att.noteGid)}&select=entity_id&limit=1`);
        let noteId = noteRow[0]?.entity_id;
        if (!noteId) {
          const ins = await api('POST', 'notes', { client_id: t.client_id, visit_id: t.visit_id, body: att.noteMsg, note_date: att.noteCreatedAt || new Date().toISOString(), source: 'jobber_note_sync' }, 'return=representation');
          noteId = ins[0].id;
          await api('POST', 'entity_source_links?on_conflict=entity_type,source_system,source_id', { entity_type: 'note', entity_id: noteId, source_system: 'jobber', source_id: att.noteGid }, 'resolution=ignore-duplicates,return=minimal');
        }
        // reuse an existing photo for this attachment gid ONLY if the photo row still
        // exists — there are ~4k stale photo esls (source_system='jobber') pointing at
        // photos a historical cleanup deleted (esl has no cascade). The JOIN filters
        // those out so we don't hand a dangling photo_id to the FK; the DO UPDATE below
        // then repoints the stale esl to the freshly downloaded photo.
        let photoId = await rpc('note_photo_sync_photo_id', { p_att_gid: g });
        if (!photoId) {
          // 2026-09-08. Was ONE branch with ONE conflated message and NO counter:
          //   if (!att.url || (att.fileSize && att.fileSize > STORAGE_SIZE_LIMIT)) {
          //     console.log(`    skip ${att.fileName} (no url / oversized)`); continue; }
          // Two unrelated causes, so the logs could never say which happened, and neither
          // was countable anywhere. Now split, counted, and recorded in the catch-basin.
          // Note `!= null` rather than the old truthy test: a fileSize of 0 or null used to
          // fall THROUGH this guard into a download attempt instead of being caught.
          const size   = att.fileSize == null ? null : Number(att.fileSize);
          const tooBig = size != null && size > STORAGE_SIZE_LIMIT;
          if (!att.url || tooBig) {
            const reason = tooBig ? 'OVERSIZED' : 'NO_URL';
            if (tooBig) { oversizedSkipped++; oversizedBytes += size; }
            else noUrlSkipped++;
            console.log(`    skip ${att.fileName} ${reason}` +
              (tooBig ? ` ${size} bytes > ${STORAGE_SIZE_LIMIT} limit` : ' (Jobber returned no download url)'));
            // Record it so the file is RECOVERABLE and the skip is COUNTABLE from the DB.
            // 🛑 DO UPDATE, not DO NOTHING. jobber_url_signed is a presigned S3 url and it
            // EXPIRES: the 58 rows written by the migrate script were never refreshed and
            // every one of their urls is long dead, which is why this basin has never
            // recovered a single file. We re-encounter the same attachment ~10x/day, so
            // refreshing on conflict is what makes the row actually usable. `logged_at` is
            // deliberately NOT refreshed so it keeps meaning FIRST SEEN.
            // PostgREST's merge updates exactly the keys sent, so a null file_name / content_type / size_bytes is LEFT
            // OUT (keeps the stored value, as the old COALESCE did) while jobber_url_signed is always sent.
            // logged_at is never sent, so it keeps meaning FIRST SEEN.
            const basin = { client_id: t.client_id, visit_id: t.visit_id, note_jobber_id: att.noteGid, attachment_jobber_id: g,
                            jobber_url_signed: att.url || null, skip_reason: reason };
            if (att.fileName) basin.file_name = att.fileName;
            if (att.contentType) basin.content_type = att.contentType;
            if (size != null) basin.size_bytes = size;
            await api('POST', 'jobber_oversized_attachments?on_conflict=attachment_jobber_id', basin, 'resolution=merge-duplicates,return=minimal')
              // Never let bookkeeping fail the import of the OTHER attachments on this note.
              .catch(e => { errors++; console.log(`    basin ${g} ERR: ${e.message.slice(0, 70)}`); });
            continue;
          }
          const dl = await downloadFromUrl(att.url); const ext = extOf(dl.contentType || att.contentType, att.fileName);
          const path = `notes/${t.client_id}/${att.noteGid}/${g}.${ext}`;
          await storageUpload(path, dl.body, dl.contentType);
          // A row already at this path is reused untouched (the old ON CONFLICT DO UPDATE changed nothing either).
          const p = await api('POST', 'photos?on_conflict=storage_path', { storage_path: path, file_name: att.fileName || g + '.' + ext, content_type: dl.contentType || null, size_bytes: dl.body.length, source: 'jobber_note_sync' }, 'resolution=ignore-duplicates,return=representation');
          photoId = p[0]?.id ?? (await api('GET', `photos?storage_path=eq.${q(path)}&select=id`))[0]?.id;
          if (!photoId) throw new Error(`no photo row for ${path}`);
          await api('POST', 'entity_source_links?on_conflict=entity_type,source_system,source_id', { entity_type: 'photo', entity_id: photoId, source_system: 'jobber', source_id: g }, 'resolution=merge-duplicates,return=minimal');
        }
        // both links in ONE statement, as before (one request = one transaction)
        await api('POST', 'photo_links?on_conflict=photo_id,entity_type,entity_id,role', [
          { photo_id: photoId, entity_type: 'note', entity_id: noteId, role: 'attachment' },
          { photo_id: photoId, entity_type: 'visit', entity_id: t.visit_id, role: 'other' },
        ], 'resolution=ignore-duplicates,return=minimal');
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
        const scope = `photo_id=eq.${Number(r.photo_id)}&entity_type=eq.visit&entity_id=eq.${Number(t.visit_id)}`;
        const linkIds = (await api('GET', `photo_links?${scope}&select=id`)).map(x => Number(x.id));
        if (linkIds.length) await api('DELETE', `photo_classifications?photo_link_id=in.(${linkIds.join(',')})`, null, 'return=minimal');
        await api('DELETE', `photo_links?${scope}`, null, 'return=minimal');
        removed++;
      } catch (e) { errors++; console.log(`    remove ${r.att_gid} ERR: ${e.message.slice(0, 70)}`); }
    }
    await sleep(80);
  }
  console.log(`\n=== ${EXECUTE ? 'DONE' : 'DRY-RUN'} === visits changed: ${changedVisits} | photos added: ${added} | removed: ${removed} | skipped by note-window: ${windowSkipped} | oversized: ${oversizedSkipped}${oversizedSkipped ? ` (${Math.round(oversizedBytes / 1048576)} MB)` : ''} | no url: ${noUrlSkipped} | errors: ${errors}`);
  if (EXECUTE) {
    const nowIso = new Date().toISOString();
    // a failed log write is said out loud now (it used to vanish in .catch(() => {})); it never fails the run
    await api('POST', 'sync_log', { sync_source: 'jobber_note_photo_sync', started_at: nowIso, finished_at: nowIso, rows_updated: added + removed, rows_errored: errors, status: errors ? 'partial' : 'success', details: { added, removed, changedVisits, days: DAYS, oversizedSkipped, noUrlSkipped, oversizedBytes } }, 'return=minimal')
      .catch(e => console.log(`sync_log write ERR: ${e.message.slice(0, 120)}`));
  }
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
