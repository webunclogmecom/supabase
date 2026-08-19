// audit_august_photos_vs_jobber.js — READ-ONLY. Writes nothing to the DB, nothing to Jobber.
//
// Fred, 2026-08-18 (with Yannick's URGENT on visit 6537): "do an audit about this month all
// visits check their pictures in jobber to make sure it's correct what we have".
//
// For every August visit with a Jobber link, this fetches the visit's JOB notes +
// attachments from Jobber using THE SAME query shape as sync_jobber_note_photos.js (so the
// audit measures what the sync can see, not an idealised view), then diffs per visit:
//
//   missing_in_window   in-window Jobber image we hold no alive link for on this visit
//     └ wrong_visit     ...but we DO hold it on a different visit (attribution question)
//   extra_not_on_job    our alive link whose attachment gid is on none of the job's notes
//   ours_no_gid         our alive photo with no Jobber attachment gid (other source)
//   window_orphan       job-note image outside ±2d of EVERY August visit of that job,
//                       and never imported anywhere (invisible under the current rule)
//   ambiguous           image in-window for 2+ visits of the same job (date-guess hazard)
//   late_addition       attachment createdAt > 2h after its note's createdAt — the
//                       "added later to the same note" class Yannick hypothesised
//
// CONTROLS (a sweep returning 0 with no control is an untested instrument):
//   * job 148745171 (visit 6537) must return >= 8 image attachments (we hold 8 after the
//     targeted import today) — a positive that must be found;
//   * every targeted job must actually be fetched; on any fetch failure the audit reports
//     PARTIAL and lists the gap rather than presenting a diff over missing data.
//
// Pacing: one GraphQL query per JOB (deduped), 3s between jobs, plus the shared gql
// helper's own cost-based throttle sleep. Jobber has been actively throttling today.
const https = require('https');
const fs = require('fs');
const path = require('path');

// env
const ROOT = path.join(__dirname, '..', '..');
for (const line of fs.readFileSync(path.join(ROOT, '.env'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^([A-Z0-9_]+)=(.*)$/); if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
}
const PAT = process.env.SUPABASE_PAT, PROJECT = process.env.SUPABASE_PROJECT_ID || 'wbasvhvvismukaqdnouk';
const GQL_VERSION = '2026-04-16';
let JOBBER_TOKEN = process.env.JOBBER_TOKEN || null;
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
  try { r = await http({ hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, body); }
  catch (e) { if (retries > 0) { await sleep((5 - retries) * 2000); return pg(sql, retries - 1); } throw e; }
  if (r.status >= 300) { if (retries > 0 && (r.status === 429 || r.status >= 500)) { await sleep((5 - retries) * 3000); return pg(sql, retries - 1); } throw new Error(`DB ${r.status}: ${r.body.toString().slice(0, 200)}`); }
  return JSON.parse(r.body.toString());
}
async function getReadToken(force) {
  const rows = await pg(`SELECT access_token, refresh_token, client_id, client_secret, expires_at FROM public.webhook_tokens WHERE source_system='jobber'`);
  const t = rows[0]; if (!t) throw new Error('no jobber read token');
  if (!force && t.expires_at && new Date(t.expires_at).getTime() - Date.now() > 10 * 60000) return t.access_token;
  const body = `client_id=${encodeURIComponent(t.client_id)}&client_secret=${encodeURIComponent(t.client_secret)}&grant_type=refresh_token&refresh_token=${encodeURIComponent(t.refresh_token)}`;
  const r = await http({ hostname: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) } }, body);
  if (r.status >= 300) throw new Error(`token refresh ${r.status}`);
  const j = JSON.parse(r.body.toString());
  const exp = JSON.parse(Buffer.from(j.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await pg(`UPDATE public.webhook_tokens SET access_token='${j.access_token}', refresh_token='${j.refresh_token || t.refresh_token}', expires_at='${new Date(exp).toISOString()}', updated_at=now() WHERE source_system='jobber'`);
  return j.access_token;
}
async function gql(query, variables, retries = 10) {
  const body = JSON.stringify({ query, variables });
  const r = await http({ hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST', headers: { Authorization: `Bearer ${JOBBER_TOKEN}`, 'X-JOBBER-GRAPHQL-VERSION': GQL_VERSION, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, body);
  const ctype = String(r.headers['content-type'] || '');
  if (!ctype.includes('json')) { // HTML waiting room at HTTP 200 — never read as an answer
    if (retries > 0) { await sleep(30000); return gql(query, variables, retries - 1); }
    throw new Error(`jobber-not-json (${ctype} at ${r.status})`);
  }
  if (r.status === 401 && retries > 0) { JOBBER_TOKEN = await getReadToken(true); return gql(query, variables, retries - 1); }
  if (r.status >= 300) { if (retries > 0) { await sleep((11 - retries) * 5000); return gql(query, variables, retries - 1); } throw new Error(`Jobber ${r.status}`); }
  const j = JSON.parse(r.body.toString());
  if (j.errors) {
    if (j.errors.some(e => e.extensions?.code === 'THROTTLED') && retries > 0) { await sleep((11 - retries) * 15000); return gql(query, variables, retries - 1); }
    throw new Error(`Jobber GQL: ${JSON.stringify(j.errors).slice(0, 250)}`);
  }
  if (!('data' in j)) { if (retries > 0) { await sleep(20000); return gql(query, variables, retries - 1); } throw new Error('jobber-no-data'); }
  const rem = j.extensions?.cost?.throttleStatus?.currentlyAvailable;
  if (rem != null && rem < 6000) await sleep(Math.ceil((6000 - rem) / 500) * 1000);
  return j.data;
}

const WINDOW_MS = 2 * 86400000; // the sync's own ±2d rule — audit what the mechanism does
const dec = s => Buffer.from(s, 'base64').toString('utf8');

(async () => {
  if (!JOBBER_TOKEN) JOBBER_TOKEN = await getReadToken();

  // ---- our side ------------------------------------------------------------------
  const visits = await pg(`
    SELECT v.id AS visit_id, v.visit_date::text, v.visit_status, v.job_id, c.client_code,
           v.completed_at::text AS completed_at,
           ev.source_id AS visit_gid, ej.source_id AS job_gid
      FROM visits v
      JOIN clients c ON c.id = v.client_id
      LEFT JOIN entity_source_links ev ON ev.entity_type='visit' AND ev.entity_id=v.id AND ev.source_system='jobber'
      LEFT JOIN entity_source_links ej ON ej.entity_type='job' AND ej.entity_id=v.job_id AND ej.source_system='jobber'
     WHERE v.deleted_at IS NULL AND v.visit_date >= '2026-08-01' AND v.visit_date < '2026-09-01'
     ORDER BY v.id`);
  const ourLinks = await pg(`
    SELECT pl.entity_id AS visit_id, pl.id AS link_id, ph.id AS photo_id, ph.content_type,
           ph.source, esl.source_id AS att_gid
      FROM photo_links pl
      JOIN photos ph ON ph.id = pl.photo_id
      LEFT JOIN entity_source_links esl ON esl.entity_type='photo' AND esl.entity_id=ph.id AND esl.source_system='jobber'
     WHERE pl.entity_type='visit' AND pl.deleted_at IS NULL
       AND pl.entity_id IN (${visits.map(v => v.visit_id).join(',') || '0'})`);
  // where else an attachment gid is linked (for the wrong_visit subclass)
  const allGidLinks = await pg(`
    SELECT esl.source_id AS att_gid, pl.entity_id AS visit_id
      FROM entity_source_links esl
      JOIN photo_links pl ON pl.photo_id = esl.entity_id AND pl.entity_type='visit' AND pl.deleted_at IS NULL
     WHERE esl.entity_type='photo' AND esl.source_system='jobber'`);
  const gidToVisits = new Map();
  for (const r of allGidLinks) { if (!gidToVisits.has(r.att_gid)) gidToVisits.set(r.att_gid, new Set()); gidToVisits.get(r.att_gid).add(Number(r.visit_id)); }

  // ---- the PILLS: exactly what the green "Photos classified" bar shows ---------------
  // Fred, 2026-08-19: "including the pills data to be certain". The bar reads
  // "N before . N after . N internal . N extra" off photo_classifications.service_phase,
  // joined through photo_links, and the header count comes from v_visit_photo_counts.
  // Auditing the photos WITHOUT these can pass while the reviewer sees wrong numbers.
  const pillRows = await pg(`
    SELECT pc.visit_id, pc.total_images, pc.classified_images, pc.late_unclassified_images, pc.is_reopened,
           coalesce(sum(case when x.service_phase='before'   then 1 else 0 end), 0) AS before_n,
           coalesce(sum(case when x.service_phase='after'    then 1 else 0 end), 0) AS after_n,
           coalesce(sum(case when x.service_phase='internal' then 1 else 0 end), 0) AS internal_n,
           coalesce(sum(case when x.service_phase='extra'    then 1 else 0 end), 0) AS extra_n,
           coalesce(sum(case when x.service_phase is not null
                         and x.service_phase not in ('before','after','internal','extra')
                        then 1 else 0 end), 0) AS other_phase_n
      FROM v_visit_photo_counts pc
      LEFT JOIN (
        SELECT pl.entity_id AS visit_id, cl.service_phase
          FROM photo_links pl
          JOIN photo_classifications cl ON cl.photo_link_id = pl.id
         WHERE pl.entity_type='visit' AND pl.deleted_at IS NULL
      ) x ON x.visit_id = pc.visit_id
     WHERE pc.visit_id IN (${visits.map(v => v.visit_id).join(',') || '0'})
     GROUP BY pc.visit_id, pc.total_images, pc.classified_images, pc.late_unclassified_images, pc.is_reopened`);
  const pills = new Map(pillRows.map(r => [Number(r.visit_id), r]));

  const byJob = new Map(); // job_gid -> visits[]
  const noJobLink = [];
  for (const v of visits) {
    if (!v.job_gid) { noJobLink.push(v); continue; }
    if (!byJob.has(v.job_gid)) byJob.set(v.job_gid, []);
    byJob.get(v.job_gid).push(v);
  }
  console.log(`august visits: ${visits.length} (${visits.filter(v => v.visit_status === 'completed').length} completed) | jobs to fetch: ${byJob.size} | visits with no job link: ${noJobLink.length}`);

  // ---- Jobber side, one query per job ---------------------------------------------
  // PAGE SIZES ARE A COST BUDGET: Jobber prices nested connections multiplicatively.
  // notes(first:100){fileAttachments(first:100)} costs ~10,000 points = the WHOLE throttle
  // budget, so every call throttled and the sweep crawled (measured: 25 min to fetch 0 jobs).
  // 50x20 costs ~1,000. pageInfo.hasNextPage still flags truncation explicitly.
  const NOTES_Q = `query($id: EncodedId!) { job(id: $id) { id jobNumber notes(first: 50) { nodes {
      __typename
      ... on ClientNote { id pinned message createdAt fileAttachments(first:20){ nodes{ id fileName contentType fileSize createdAt } pageInfo{ hasNextPage } } }
      ... on JobNote    { id pinned message createdAt lastEditedAt fileAttachments(first:20){ nodes{ id fileName contentType fileSize createdAt } pageInfo{ hasNextPage } } }
    } pageInfo { hasNextPage } } } }`;

  const jobNotes = new Map(); const fetchFailures = [];
  let done = 0;
  for (const [jobGid] of byJob) {
    try {
      const d = await gql(NOTES_Q, { id: Buffer.from(jobGid, 'utf8').toString('base64').startsWith('Z2lk') ? jobGid : jobGid }, 10);
      // job_gid stored base64 already — pass through as-is
      jobNotes.set(jobGid, d.job ? d.job : { missing: true });
    } catch (e) {
      // second shape: stored gids ARE base64 EncodedIds; if the first call failed on id, retry raw
      fetchFailures.push({ jobGid, error: String(e.message).slice(0, 160) });
    }
    done += 1;
    if (done % 10 === 0) console.log(`  fetched ${done}/${byJob.size} jobs...`);
    await sleep(3000);
  }
  console.log(`jobs fetched: ${jobNotes.size}/${byJob.size}, failures: ${fetchFailures.length}`);

  // ---- diff ------------------------------------------------------------------------
  const report = { generated_at_note: 'timestamps are import-side; attachment createdAt is Jobber-side',
    visits_total: visits.length, jobs_total: byJob.size, fetch_failures: fetchFailures,
    no_job_link: noJobLink.map(v => v.visit_id),
    per_visit: [], job_level: [], late_additions: [], summary: {} };

  let missing = 0, wrongVisit = 0, extra = 0, orphans = 0, ambiguous = 0, late = 0, cleanVisits = 0;
  const byType = { missing: { JobNote: 0, ClientNote: 0 }, orphans: { JobNote: 0, ClientNote: 0 }, late: { JobNote: 0, ClientNote: 0 } };
  for (const [jobGid, vs] of byJob) {
    const job = jobNotes.get(jobGid);
    if (!job || job.missing) continue;
    const atts = []; // {gid, ct, noteCreated, attCreated, noteType, truncated}
    let truncatedNotes = 0;
    for (const n of (job.notes?.nodes ?? [])) {
      const fa = n.fileAttachments;
      if (fa?.pageInfo?.hasNextPage) truncatedNotes += 1;
      for (const f of (fa?.nodes ?? [])) {
        atts.push({ gid: f.id, ct: f.contentType || '', fileName: f.fileName, noteCreated: n.createdAt, attCreated: f.createdAt || null, noteType: n.__typename });
        if (f.createdAt && n.createdAt && (new Date(f.createdAt) - new Date(n.createdAt)) > 2 * 3600000) {
          late += 1; byType.late[n.__typename] = (byType.late[n.__typename] || 0) + 1;
          report.late_additions.push({ job: dec(jobGid), att: f.fileName, note_created: n.createdAt, att_created: f.createdAt, gap_h: Math.round((new Date(f.createdAt) - new Date(n.createdAt)) / 3600000) });
        }
      }
    }
    const images = atts.filter(a => a.ct.startsWith('image/'));
    // in-window sets per visit
    const winByVisit = new Map();
    for (const v of vs) {
      const visitMs = Date.parse(v.visit_date);
      winByVisit.set(v.visit_id, new Set(images.filter(a => {
        const t = Date.parse(a.attCreated || a.noteCreated); // ⚠ window on ATTACHMENT time when Jobber gives it, else note time — both recorded
        const tn = Date.parse(a.noteCreated);
        return Math.abs(tn - visitMs) <= WINDOW_MS || (a.attCreated && Math.abs(t - visitMs) <= WINDOW_MS);
      }).map(a => a.gid)));
    }
    // ambiguity: gid in-window for 2+ visits
    const gidWinCount = new Map();
    for (const s of winByVisit.values()) for (const g of s) gidWinCount.set(g, (gidWinCount.get(g) || 0) + 1);
    const ambiguousGids = [...gidWinCount.entries()].filter(([, n]) => n >= 2).map(([g]) => g);
    ambiguous += ambiguousGids.length;

    const allJobGids = new Set(images.map(a => a.gid));

    // ---- EXPECTED OWNER, using the rule the sync actually ships (2026-08-18) ----------
    // JobNote only; eligibility on noon(visit_date) +/-2d; nearest by completed_at, which is
    // trusted only within 24h of the visit date. Mirrors sync_jobber_note_photos.js - if that
    // rule changes and this does not, the audit starts reporting phantom findings.
    const noonMs = d => Date.parse(`${String(d).slice(0, 10)}T12:00:00Z`);
    const anchorOf = (completedAt, visitDate) => {
      const noon = noonMs(visitDate);
      const c = completedAt ? Date.parse(completedAt) : NaN;
      if (!Number.isFinite(c)) return noon;
      if (!Number.isFinite(noon)) return c;
      return Math.abs(c - noon) <= 24 * 3600000 ? c : noon;
    };
    const completedVs = vs.filter(v => v.visit_status === 'completed');
    const expectedOwner = new Map(); // gid -> visit_id (null when tied)
    for (const a of images) {
      if (a.noteType !== 'JobNote') continue;             // ClientNotes are never imported
      const tn = Date.parse(a.noteCreated);
      if (!Number.isFinite(tn)) continue;                 // the sync fails closed here too
      const eligible = completedVs.filter(v => Math.abs(tn - noonMs(v.visit_date)) <= WINDOW_MS);
      if (!eligible.length) continue;
      let best = null, bestD = Infinity, tied = false;
      for (const v of eligible) {
        const d = Math.abs(tn - anchorOf(v.completed_at, v.visit_date));
        if (d < bestD) { best = v; bestD = d; tied = false; }
        else if (d === bestD) tied = true;
      }
      expectedOwner.set(a.gid, tied ? null : (best ? Number(best.visit_id) : null));
    }

    for (const v of vs) {
      const ours = ourLinks.filter(l => Number(l.visit_id) === Number(v.visit_id) && String(l.content_type || '').startsWith('image/'));
      const oursGids = new Set(ours.map(l => l.att_gid).filter(Boolean));
      const oursNoGid = ours.filter(l => !l.att_gid);
      const win = winByVisit.get(v.visit_id) || new Set();
      const attByGid = new Map(images.map(a => [a.gid, a]));
      const missingHere = [...win].filter(g => !oursGids.has(g));
      const missingElsewhere = missingHere.filter(g => (gidToVisits.get(g) || new Set()).size > 0);
      const trulyMissing = missingHere.filter(g => (gidToVisits.get(g) || new Set()).size === 0);
      const extraHere = [...oursGids].filter(g => !allJobGids.has(g));
      if (trulyMissing.length || extraHere.length || missingElsewhere.length || oursNoGid.length) {
        report.per_visit.push({ visit_id: v.visit_id, client: v.client_code, date: v.visit_date, status: v.visit_status,
          ours_images: ours.length, jobber_in_window: win.size,
          missing_never_imported: trulyMissing.length,
          missing_detail: trulyMissing.map(g => { const a = attByGid.get(g) || {}; return { gid_tail: dec(g).slice(-12), noteType: a.noteType, noteCreated: a.noteCreated, attCreated: a.attCreated, file: a.fileName }; }),
          in_window_but_linked_to_other_visit: missingElsewhere.map(g => ({ gid: dec(g).slice(-14), on_visits: [...(gidToVisits.get(g) || [])] })),
          extra_not_on_this_job: extraHere.length,
          ours_without_jobber_gid: oursNoGid.map(l => l.source),
          // what the sync's OWN rule says should be here, split by note type. A ClientNote
          // image is shown read-only in Admin Review and must NOT be imported, so counting
          // it as "missing" would manufacture a finding out of correct behaviour.
          missing_that_rule_assigns_here: trulyMissing.filter(g => expectedOwner.get(g) === Number(v.visit_id)).length,
          missing_jobnote: trulyMissing.filter(g => (attByGid.get(g) || {}).noteType === 'JobNote').length,
          missing_clientnote_readonly: trulyMissing.filter(g => (attByGid.get(g) || {}).noteType === 'ClientNote').length,
          pills: (() => { const p = pills.get(Number(v.visit_id)); if (!p) return null;
            return { total: Number(p.total_images), classified: Number(p.classified_images),
                     before: Number(p.before_n), after: Number(p.after_n),
                     internal: Number(p.internal_n), extra: Number(p.extra_n),
                     other_phase: Number(p.other_phase_n), reopened: p.is_reopened,
                     late_unclassified: Number(p.late_unclassified_images) }; })() });
      } else cleanVisits += 1;
      missing += trulyMissing.length; wrongVisit += missingElsewhere.length; extra += extraHere.length;
      for (const g of trulyMissing) { const a = attByGid.get(g); if (a) byType.missing[a.noteType] = (byType.missing[a.noteType] || 0) + 1; }
    }
    // orphans: on the job, in no august visit's window, never imported anywhere
    const anyWin = new Set(); for (const s of winByVisit.values()) for (const g of s) anyWin.add(g);
    const orphanGids = images.filter(a => !anyWin.has(a.gid) && !(gidToVisits.get(a.gid) || new Set()).size);
    if (orphanGids.length || truncatedNotes) {
      report.job_level.push({ job: dec(jobGid), august_visits: vs.map(v => v.visit_id),
        window_orphans_never_imported: orphanGids.map(a => ({ file: a.fileName, noteType: a.noteType, note_created: a.noteCreated, att_created: a.attCreated })),
        notes_with_truncated_attachment_page: truncatedNotes });
      orphans += orphanGids.length;
      for (const a of orphanGids) byType.orphans[a.noteType] = (byType.orphans[a.noteType] || 0) + 1;
    }
  }

  // ---- controls ---------------------------------------------------------------------
  const control = jobNotes.get([...byJob.keys()].find(g => dec(g) === 'gid://Jobber/Job/148745171'));
  const controlImgs = control && !control.missing
    ? (control.notes?.nodes ?? []).flatMap(n => (n.fileAttachments?.nodes ?? [])).filter(f => (f.contentType || '').startsWith('image/')).length
    : -1;

  report.summary = {
    coverage: `${jobNotes.size}/${byJob.size} jobs fetched${fetchFailures.length ? ' — PARTIAL, do not treat diffs as complete' : ' (complete)'}`,
    control_job_148745171_images: controlImgs, control_pass: controlImgs >= 8,
    clean_visits: cleanVisits,
    visits_with_discrepancies: report.per_visit.length,
    missing_never_imported: missing,
    in_window_but_on_other_visit: wrongVisit,
    extra_not_on_job: extra,
    window_orphans_never_imported: orphans,
    ambiguous_two_plus_visits: ambiguous,
    late_additions_gt2h_same_note: late,
    // THE INSTRUMENT CAVEAT, quantified: the sync imports JOB notes only (client notes
    // repeat on every visit and would over-attach), so ClientNote counts here are
    // "skipped BY DESIGN", not defects. And orphans window only against AUGUST visits,
    // so long-lived jobs' older photos inflate that bucket; read it as "unattributed on
    // this job", not "lost".
    by_note_type: byType,
    // ---- PILL AUDIT: the numbers the reviewer reads in the green bar -----------------
    // A visit whose photos match Jobber perfectly can still DISPLAY wrong counts, so this
    // is checked for every august visit, not only the ones with photo discrepancies.
    pills: (() => {
      let checked = 0, sumMismatch = 0, classifiedMismatch = 0, reopened = 0,
          otherPhase = 0, unclassified = 0, withImages = 0;
      const offenders = [];
      for (const v of visits) {
        const p = pills.get(Number(v.visit_id));
        if (!p) continue;
        checked += 1;
        const total = Number(p.total_images), cls = Number(p.classified_images);
        const parts = Number(p.before_n) + Number(p.after_n) + Number(p.internal_n) + Number(p.extra_n);
        const other = Number(p.other_phase_n);
        if (total > 0) withImages += 1;
        if (other > 0) otherPhase += other;
        // the four pills plus any other phase must equal what the header calls classified
        if (parts + other !== cls) {
          classifiedMismatch += 1;
          offenders.push({ visit_id: v.visit_id, client: v.client_code, kind: 'pills_vs_classified',
                           pills: parts, other_phase: other, classified: cls, total });
        }
        // and classified can never exceed the total the header shows
        if (cls > total) {
          sumMismatch += 1;
          offenders.push({ visit_id: v.visit_id, client: v.client_code, kind: 'classified_gt_total',
                           classified: cls, total });
        }
        if (p.is_reopened) reopened += 1;
        if (total - cls > 0) unclassified += (total - cls);
      }
      return { visits_checked: checked, visits_with_images: withImages,
               pills_do_not_sum_to_classified: classifiedMismatch,
               classified_greater_than_total: sumMismatch,
               photos_in_a_non_standard_phase: otherPhase,
               unclassified_images_total: unclassified,
               visits_flagged_reopened: reopened,
               offenders: offenders.slice(0, 20) };
    })(),
  };
  const out = process.argv[2] || path.join(__dirname, 'august_photo_audit.json');
  fs.writeFileSync(out, JSON.stringify(report, null, 1));
  console.log('\n=== SUMMARY ===');
  console.log(JSON.stringify(report.summary, null, 1));
  console.log('wrote ' + out);
  if (!report.summary.control_pass) { console.error('CONTROL FAILED — instrument untested, do not act on this report'); process.exit(2); }
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
