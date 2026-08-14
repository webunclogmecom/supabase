// ============================================================================
// cleanup_inherited_visit_photo_links.js — one-off repair of the job-note over-attach
// ============================================================================
// Fred, 2026-08-14: "Clean it after fixing it, and i don't care if they're already
// classified or not, we need to have the correct data shown on each visit." and, on
// the boundary: "yes keep the ones inside the 2 day window".
//
// BACKGROUND: docs/audits/2026-08-14_photo_note_linking_audit.md
// Jobber's Visit.notes returns the parent JOB's notes, so sync_jobber_note_photos.js
// stapled a job's whole photo history onto every visit of that job. Fixed forward in
// a3561c3 by binding an add to the note's own createdAt being within +/-2 days of the
// visit. This script applies THE SAME RULE to the links already in the table.
//
// 🛑 IT ASKS JOBBER, IT DOES NOT GUESS. The note dates we hold are not trustworthy:
// the sync stored `now()` for 107 of the notes behind these links, so a cleanup keyed
// on our own notes.note_date would be deciding with a fabricated timestamp. For each
// visit this re-runs the fixed sync's exact question and keeps exactly what the sync
// would keep today, so the cleanup and the ongoing behaviour agree by construction.
//
// THE RULE, and it is deliberately conservative:
//   soft-delete a visit link ONLY IF the photo's Jobber attachment gid IS present in
//   that visit's current Jobber response AND its note is OUTSIDE the +/-2 day window.
//   - attachment NOT in Jobber's response at all -> LEAVE IT. Cannot judge. This
//     protects the legacy date-matched photos (the audit measured 82% of Jobber
//     visit-photos have no note anchor) and anything Jobber has since dropped.
//   - photo not Jobber-sourced (an app upload) -> LEAVE IT, always.
//   - note date missing/unparseable -> LEAVE IT. Fails CLOSED toward keeping data.
//
// SOFT delete via public.soft_delete_photo_link semantics (deleted_at/by/reason), so
// photo_classifications survive and the whole run is reversible with one UPDATE.
// Runs as postgres over the Management API, which is required: `authenticated` holds
// the DELETE grant on photo_links but has no DELETE policy, so a cleanup run as
// authenticated would delete nothing and report success.
//
//   node scripts/sync/cleanup_inherited_visit_photo_links.js                 # DRY-RUN
//   node scripts/sync/cleanup_inherited_visit_photo_links.js --execute       # writes
//   ... [--days=N] [--visit=ID] [--limit=N]
// ============================================================================
const https = require('https');
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const PAT = process.env.SUPABASE_PAT;
const PROJECT = (process.env.SUPABASE_URL || '').match(/https?:\/\/([^.]+)\./)?.[1];
let JOBBER_TOKEN = process.env.JT || process.env.JOBBER_ACCESS_TOKEN || null;
const GQL_VERSION = '2026-04-16';
const EXECUTE = process.argv.includes('--execute');
const NOTE_WINDOW_DAYS = Number((process.argv.find(a => a.startsWith('--note-window=')) || '').split('=')[1] || 2);
const ONLY_VISIT = (process.argv.find(a => a.startsWith('--visit=')) || '').split('=')[1] || null;
const LIMIT = Number((process.argv.find(a => a.startsWith('--limit=')) || '').split('=')[1] || 0);
const JOBBER_SOURCES = ['jobber_migration', 'jobber_late_recovery', 'jobber_note_sync'];
const REASON = 'job-note inheritance cleanup 2026-08-14 (note outside +/-2d of visit)';
const sleep = ms => new Promise(r => setTimeout(r, ms));

function http(opts, body) {
  return new Promise((res, rej) => {
    const r = https.request(opts, x => { const ch = []; x.on('data', c => ch.push(c)); x.on('end', () => res({ status: x.statusCode, body: Buffer.concat(ch) })); });
    r.on('error', rej); if (body) r.write(body); r.end();
  });
}
async function pg(sql, retries = 4) {
  const body = JSON.stringify({ query: sql });
  let r;
  try {
    r = await http({ hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, body);
  } catch (e) { if (retries > 0) { await sleep((5 - retries) * 2000); return pg(sql, retries - 1); } throw e; }
  if (r.status >= 300) {
    if (retries > 0 && (r.status === 429 || r.status >= 500)) { await sleep((5 - retries) * 2000); return pg(sql, retries - 1); }
    throw new Error(`DB ${r.status}: ${r.body.toString().slice(0, 300)}`);
  }
  return JSON.parse(r.body.toString());
}
async function gql(query, variables, retries = 5) {
  const body = JSON.stringify({ query, variables });
  const r = await http({ hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST', headers: { Authorization: `Bearer ${JOBBER_TOKEN}`, 'X-JOBBER-GRAPHQL-VERSION': GQL_VERSION, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, body);
  // 🛑 Jobber sheds load with an HTML "waiting room" at HTTP 200 (CLAUDE.md). A missing
  // answer must never be read as "this attachment is not on the visit", because here that
  // would soft-delete every link on the visit. Check the content type, not the status.
  const ctype = String(r.headers?.['content-type'] || '');
  if (r.status < 300 && ctype && !ctype.includes('json')) throw new Error(`Jobber busy (${ctype})`);
  if (r.status >= 300) {
    if (retries > 0 && (r.status === 429 || r.status >= 500)) { await sleep((6 - retries) * 4000); return gql(query, variables, retries - 1); }
    throw new Error(`Jobber ${r.status}`);
  }
  const j = JSON.parse(r.body.toString());
  if (j.errors) {
    if (j.errors.some(e => e.extensions?.code === 'THROTTLED') && retries > 0) { await sleep((6 - retries) * 5000); return gql(query, variables, retries - 1); }
    throw new Error(`Jobber GQL: ${JSON.stringify(j.errors).slice(0, 200)}`);
  }
  const rem = j.extensions?.cost?.throttleStatus?.currentlyAvailable;
  if (rem != null && rem < 6000) await sleep(Math.ceil((6000 - rem) / 500) * 1000);
  return j.data;
}
const sqlEsc = v => v == null ? 'NULL' : (typeof v === 'number' ? String(v) : "'" + String(v).replace(/'/g, "''") + "'");

const Q = `query($id:EncodedId!,$after:String){ visit(id:$id){ notes(first:10,after:$after){ nodes{ __typename
  ... on ClientNote { id createdAt fileAttachments(first:100){ nodes{ id } pageInfo{ hasNextPage } } }
  ... on JobNote    { id createdAt fileAttachments(first:100){ nodes{ id } pageInfo{ hasNextPage } } }
} pageInfo{ hasNextPage endCursor } } } }`;

(async () => {
  if (!JOBBER_TOKEN) { console.error('No Jobber token. Run: cd Slack && JT=$(./jobber-token.sh) and export JT.'); process.exit(1); }
  console.log(`cleanup_inherited_visit_photo_links  ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}  window=+/-${NOTE_WINDOW_DAYS}d${ONLY_VISIT ? `  visit=${ONLY_VISIT}` : ''}`);

  // Visits that hold at least one Jobber-sourced, still-alive visit link.
  const targets = await pg(`
    SELECT v.id AS visit_id, v.visit_date::text AS visit_date, esl.source_id AS visit_gid, c.client_code
    FROM visits v
    JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
    JOIN clients c ON c.id=v.client_id
    WHERE v.deleted_at IS NULL
      ${ONLY_VISIT ? `AND v.id=${Number(ONLY_VISIT)}` : ''}
      AND EXISTS (SELECT 1 FROM photo_links pl JOIN photos ph ON ph.id=pl.photo_id
                   WHERE pl.entity_type='visit' AND pl.entity_id=v.id AND pl.deleted_at IS NULL
                     AND ph.source IN (${JOBBER_SOURCES.map(sqlEsc).join(',')}))
    ORDER BY v.visit_date DESC${LIMIT ? ` LIMIT ${LIMIT}` : ''}`);
  console.log(`${targets.length} visit(s) with Jobber-sourced photos\n`);

  let scanned = 0, wouldDelete = 0, deleted = 0, kept = 0, unjudgeable = 0, errors = 0, visitsChanged = 0;

  for (const t of targets) {
    scanned++;
    // our alive, Jobber-sourced links for this visit, with the attachment gid
    const ours = await pg(`
      SELECT pl.id AS link_id, ph.source, esl.source_id AS att_gid
      FROM photo_links pl
      JOIN photos ph ON ph.id = pl.photo_id
      LEFT JOIN entity_source_links esl ON esl.entity_type='photo' AND esl.source_system='jobber' AND esl.entity_id=ph.id
      WHERE pl.entity_type='visit' AND pl.entity_id=${t.visit_id} AND pl.deleted_at IS NULL
        AND ph.source IN (${JOBBER_SOURCES.map(sqlEsc).join(',')})`);
    if (!ours.length) continue;

    let notes = [], cursor = null;
    try {
      do {
        const d = await gql(Q, { id: t.visit_gid, after: cursor });
        const vn = d.visit?.notes; if (!vn) break;
        notes.push(...vn.nodes); cursor = vn.pageInfo.hasNextPage ? vn.pageInfo.endCursor : null;
      } while (cursor && notes.length < 200);
    } catch (e) { errors++; console.log(`  v${t.visit_id} ${t.client_code} ERR ${e.message.slice(0, 60)}`); continue; }

    // 🛑 GUARD: an empty Jobber response must never be read as "nothing belongs here".
    if (!notes.length) { unjudgeable += ours.length; continue; }

    const visitMs = Date.parse(`${t.visit_date.slice(0, 10)}T12:00:00Z`);
    const inWindow = new Set(), seenAnywhere = new Set();
    for (const n of notes) {
      const atts = (n.fileAttachments?.nodes || []).map(f => f.id);
      atts.forEach(g => seenAnywhere.add(g));
      const nd = Date.parse(n.createdAt || '');
      if (!Number.isFinite(nd) || !Number.isFinite(visitMs)) continue;       // fail closed -> keep
      if (Math.abs(nd - visitMs) <= NOTE_WINDOW_DAYS * 86400000) atts.forEach(g => inWindow.add(g));
    }

    const doomed = [];
    for (const r of ours) {
      if (!r.att_gid) { unjudgeable++; continue; }            // no Jobber anchor -> leave
      if (inWindow.has(r.att_gid)) { kept++; continue; }       // inside the window -> Fred: keep
      if (!seenAnywhere.has(r.att_gid)) { unjudgeable++; continue; } // Jobber does not offer it -> leave
      doomed.push(r.link_id);
    }
    if (!doomed.length) continue;
    visitsChanged++;
    wouldDelete += doomed.length;
    console.log(`  v${t.visit_id} ${t.client_code} (${t.visit_date})  keep ${ours.length - doomed.length}  soft-delete ${doomed.length}`);
    if (EXECUTE) {
      await pg(`UPDATE public.photo_links SET deleted_at=now(), deleted_reason=${sqlEsc(REASON)}
                 WHERE id IN (${doomed.join(',')}) AND deleted_at IS NULL`);
      deleted += doomed.length;
    }
    await sleep(60);
  }

  console.log(`\n=== ${EXECUTE ? 'DONE' : 'DRY-RUN'} ===`);
  console.log(`visits scanned      : ${scanned}`);
  console.log(`visits changed      : ${visitsChanged}`);
  console.log(`links kept (in +/-${NOTE_WINDOW_DAYS}d) : ${kept}`);
  console.log(`links left alone (no Jobber anchor / not offered) : ${unjudgeable}`);
  console.log(`links ${EXECUTE ? 'soft-deleted' : 'that WOULD be soft-deleted'} : ${EXECUTE ? deleted : wouldDelete}`);
  console.log(`errors              : ${errors}`);
  if (EXECUTE) {
    await pg(`INSERT INTO public.sync_log (sync_source, started_at, finished_at, rows_updated, rows_errored, status, details)
              VALUES ('photo_link_inheritance_cleanup', now(), now(), ${deleted}, ${errors}, ${errors ? "'partial'" : "'success'"},
                      ${sqlEsc(JSON.stringify({ scanned, visitsChanged, kept, unjudgeable, deleted }))})`).catch(() => {});
  }
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
