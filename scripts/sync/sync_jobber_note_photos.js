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
async function pg(sql) {
  const body = JSON.stringify({ query: sql });
  const r = await http({ hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, body);
  if (r.status >= 300) throw new Error(`DB ${r.status}: ${r.body.toString().slice(0, 300)}`);
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
    SELECT v.id AS visit_id, v.client_id, esl.source_id AS visit_gid, c.client_code
    FROM visits v
    JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
    JOIN clients c ON c.id=v.client_id
    WHERE v.visit_status='completed' AND v.deleted_at IS NULL
      ${ONLY_VISIT ? `AND v.id=${Number(ONLY_VISIT)}` : `AND v.visit_date >= (current_date - ${DAYS})`}
    ORDER BY v.id`);
  console.log(`${target.length} visit(s) to check`);
  let added = 0, removed = 0, errors = 0, changedVisits = 0;

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
          ... on ClientNote { id pinned message fileAttachments(first:100){ nodes{ id fileName contentType fileSize url } pageInfo{ hasNextPage } } }
          ... on JobNote    { id pinned message fileAttachments(first:100){ nodes{ id fileName contentType fileSize url } pageInfo{ hasNextPage } } }
        } pageInfo{ hasNextPage endCursor } } } }`, { id: t.visit_gid, after: cursor });
        const vn = d.visit?.notes; if (!vn) break; notes.push(...vn.nodes); cursor = vn.pageInfo.hasNextPage ? vn.pageInfo.endCursor : null;
      } while (cursor && notes.length < 200);
    } catch (e) { errors++; console.log(`  v${t.visit_id} ${t.client_code} ERR: ${e.message.slice(0, 70)}`); continue; }

    // curAtt: every current attachment (for the empty-guard + remove context).
    // noteAtts: per-note attachment set (for note-anchored REMOVE). incompleteNotes:
    // notes whose attachment page is truncated (>100) — excluded from removes.
    // We only ADD JobNote attachments to a visit: JobNotes are visit/job-specific,
    // while ClientNotes are CLIENT-level and Jobber returns the SAME ClientNotes on
    // EVERY visit of the client — attaching them per-visit over-attaches (the same
    // photo on all visits). Client-note photos are handled at the client level.
    const curAtt = new Map(); const noteAtts = new Map(); const incompleteNotes = new Set(); const jobNoteGids = new Set();
    for (const n of notes) {
      if (n.pinned) continue;
      const fa = n.fileAttachments;
      if (fa?.pageInfo?.hasNextPage) incompleteNotes.add(n.id);
      if (n.__typename === 'JobNote') jobNoteGids.add(n.id);
      noteAtts.set(n.id, new Set((fa?.nodes || []).map(f => f.id)));
      for (const f of (fa?.nodes || [])) curAtt.set(f.id, { ...f, noteGid: n.id, noteMsg: n.message || '', noteType: n.__typename });
    }

    const toAdd = [...curAtt.keys()].filter(g => curAtt.get(g).noteType === 'JobNote' && !ourByGid.has(g));
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
        if (!noteId) { const ins = await pg(`INSERT INTO notes (client_id, visit_id, body, note_date, source) VALUES (${t.client_id}, ${t.visit_id}, ${sqlEsc(att.noteMsg)}, now(), 'jobber_note_sync') RETURNING id`); noteId = ins[0].id; await pg(`INSERT INTO entity_source_links (entity_type,entity_id,source_system,source_id) VALUES ('note',${noteId},'jobber',${sqlEsc(att.noteGid)}) ON CONFLICT (entity_type,source_system,source_id) DO NOTHING`); }
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
        await pg(`DELETE FROM photo_classifications WHERE photo_link_id IN (SELECT id FROM photo_links WHERE photo_id=${r.photo_id})`);
        await pg(`DELETE FROM photo_links WHERE photo_id=${r.photo_id}`);
        removed++;
      } catch (e) { errors++; console.log(`    remove ${r.att_gid} ERR: ${e.message.slice(0, 70)}`); }
    }
    await sleep(80);
  }
  console.log(`\n=== ${EXECUTE ? 'DONE' : 'DRY-RUN'} === visits changed: ${changedVisits} | photos added: ${added} | removed: ${removed} | errors: ${errors}`);
  if (EXECUTE) await pg(`INSERT INTO public.sync_log (sync_source, started_at, finished_at, rows_updated, rows_errored, status, details) VALUES ('jobber_note_photo_sync', now(), now(), ${added + removed}, ${errors}, ${errors ? "'partial'" : "'success'"}, ${sqlEsc(JSON.stringify({ added, removed, changedVisits, days: DAYS }))})`).catch(() => {});
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
