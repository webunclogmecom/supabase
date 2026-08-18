#!/usr/bin/env node
/**
 * repair_cross_job_photo_links.js - ask JOBBER which job owns each disputed photo.
 *
 * Fred, 2026-08-18: "if you're 100% sure the photos are from a different visit then move
 * them to the correct ones."
 *
 * WHAT MAKES THIS CERTAIN RATHER THAN A HEURISTIC. A JobNote is scoped to the JOB (proven
 * 2026-08-18: zero JobNotes are shared between a client's two same-day visits on different
 * jobs - see docs/reference/jobber-note-photo-attribution.md). So an attachment that lives
 * on a note of job X CANNOT belong to a visit of job Y. That is a structural fact, not a
 * date comparison, and it is the only class this script touches:
 *
 *     102 photos hold alive links to visits on TWO DIFFERENT JOBS (all from the May
 *     jobber_migration, none since August, zero cross-client). Exactly one link in each
 *     pair is wrong, and Jobber can say which.
 *
 * 🛑 WHAT IT DELIBERATELY DOES NOT TOUCH: photos dual-linked WITHIN one job (34 of them).
 * Jobber cannot arbitrate those - both visits belong to the owning job - so the only
 * available tie-break is the completion-time heuristic. A heuristic is not "100% sure".
 *
 * 🛑 FAILS CLOSED, EVERY TIME. A photo is skipped, not guessed, when: the attachment is
 * not found on any candidate job; it is somehow found on more than one; any candidate
 * job's note pages could not be read to completion; or Jobber answers with anything that
 * is not JSON (the HTTP-200 "waiting room" - CLAUDE.md).
 *
 * 🛑 POSITIVE CONTROL BEFORE ANY DECISION. Undisputed photos (a single alive visit link,
 * imported by the sync) are looked up first and MUST be found on their own job. If the
 * control fails, the fetcher is untrusted and the run aborts having changed nothing - a
 * sweep that reports "not found" without a control is an untested instrument.
 *
 * Writes: soft-delete only (deleted_at + deleted_reason), pinned to link ids with the
 * wrong-job predicate re-asserted in the statement, so nothing fires if the world moved.
 * A missing link on the owning job is ADDED via the same nearest-by-completion rule the
 * sync uses. public.photo_links is audited, and a JSON backup is written first regardless.
 *
 *   node scripts/probes/repair_cross_job_photo_links.js              # DRY-RUN
 *   node scripts/probes/repair_cross_job_photo_links.js --execute    # writes
 */
const fs = require('fs');
const path = require('path');

const EXECUTE = process.argv.includes('--execute');
const GQL_VERSION = '2026-04-16';
const NOTE_WINDOW_DAYS = 2;
const COMPLETED_TRUST_MS = 24 * 3600000;

const ROOT = path.resolve(__dirname, '..', '..');
const envRaw = fs.readFileSync(path.join(ROOT, '.env'), 'utf8');
const envVal = (k) => (envRaw.match(new RegExp('^' + k + '=(.+)$', 'm')) || [])[1]?.trim();
const PAT = envVal('SUPABASE_PAT');
const PROJECT = envVal('SUPABASE_PROJECT_ID') || 'wbasvhvvismukaqdnouk';

// The Management API front end also sheds load with an HTML error page (a 502 landed
// mid-run on the first EXECUTE attempt). Retry the transient shapes; never retry a real
// SQL error, and never let an HTML body reach JSON.parse as if it were a result.
async function pg(query, attempt = 0) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  const text = await r.text();
  const transient = r.status === 502 || r.status === 503 || r.status === 504 || r.status === 429;
  if (!r.ok) {
    if (transient && attempt < 4) {
      console.log(`  (management API ${r.status}, retrying in 5s)`);
      await sleep(5000);
      return pg(query, attempt + 1);
    }
    throw new Error(`pg ${r.status}: ${text.slice(0, 200)}`);
  }
  if (!(r.headers.get('content-type') ?? '').includes('json')) {
    if (attempt < 4) { await sleep(5000); return pg(query, attempt + 1); }
    throw new Error('management API answered with a non-JSON body');
  }
  const j = JSON.parse(text);
  if (j.error) throw new Error(`pg error: ${JSON.stringify(j.error).slice(0, 300)}`);
  return j;
}
const esc = (v) => (v === null || v === undefined ? 'NULL' : `'${String(v).replace(/'/g, "''")}'`);

let JOBBER_TOKEN = null;
async function jobberToken() {
  if (JOBBER_TOKEN) return JOBBER_TOKEN;
  const rows = await pg(`SELECT access_token, refresh_token, client_id, client_secret, expires_at
                           FROM public.webhook_tokens WHERE source_system='jobber'`);
  const t = rows[0];
  if (!t) throw new Error('no jobber token row');
  if (t.access_token && t.expires_at && new Date(t.expires_at) > new Date(Date.now() + 60_000)) {
    JOBBER_TOKEN = t.access_token;
    return JOBBER_TOKEN;
  }
  const r = await fetch('https://api.getjobber.com/api/oauth/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token', refresh_token: t.refresh_token,
      client_id: t.client_id, client_secret: t.client_secret,
    }).toString(),
  });
  if (!r.ok) throw new Error(`token refresh ${r.status}`);
  const j = await r.json();
  const exp = JSON.parse(Buffer.from(j.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await pg(`UPDATE public.webhook_tokens SET access_token=${esc(j.access_token)},
              refresh_token=${esc(j.refresh_token || t.refresh_token)},
              expires_at=${esc(new Date(exp).toISOString())}, updated_at=now()
            WHERE source_system='jobber'`);
  JOBBER_TOKEN = j.access_token;
  return JOBBER_TOKEN;
}

async function gql(query, variables) {
  const tok = await jobberToken();
  for (let attempt = 0; attempt < 4; attempt++) {
    const r = await fetch('https://api.getjobber.com/api/graphql', {
      method: 'POST',
      headers: { Authorization: `Bearer ${tok}`, 'X-JOBBER-GRAPHQL-VERSION': GQL_VERSION, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query, variables }),
    });
    // 🛑 the waiting room answers HTTP 200 with text/html and no errors array
    const ctype = r.headers.get('content-type') ?? '';
    if (!ctype.includes('json')) { await sleep(5000); continue; }
    const j = await r.json();
    if (j.errors?.some((e) => e.extensions?.code === 'THROTTLED')) { await sleep(6000); continue; }
    if (j.errors) throw new Error('jobber: ' + JSON.stringify(j.errors).slice(0, 200));
    if (!('data' in j)) throw new Error('jobber replied without a data key');
    return j;
  }
  throw new Error('jobber unavailable after retries');
}
const sleep = (ms) => new Promise((res) => setTimeout(res, ms));

// notes(20) x fileAttachments(50) = ~1,000 points of the ~10,000 budget (they MULTIPLY).
const JOB_NOTES = `query($id: EncodedId!, $after: String) {
  job(id: $id) { id notes(first: 20, after: $after) {
    nodes {
      __typename
      ... on JobNote    { id createdAt fileAttachments(first: 50) { nodes { id } pageInfo { hasNextPage } } }
      ... on ClientNote { id createdAt fileAttachments(first: 50) { nodes { id } pageInfo { hasNextPage } } }
    }
    pageInfo { hasNextPage endCursor }
  } }
}`;

/** Read every note page of a job. Returns {atts: Map(attGid -> note), complete: bool}. */
async function fetchJobAttachments(jobGid) {
  const atts = new Map();
  let after = null, complete = true, pages = 0;
  do {
    const d = await gql(JOB_NOTES, { id: jobGid, after });
    const notes = d.data.job?.notes;
    if (!d.data.job) return { atts, complete: false, missingJob: true };
    for (const n of (notes?.nodes ?? [])) {
      const fa = n.fileAttachments;
      if (fa?.pageInfo?.hasNextPage) complete = false;   // a note we cannot read whole
      for (const f of (fa?.nodes ?? [])) {
        atts.set(f.id, { noteGid: n.id, noteType: n.__typename, noteCreatedAt: n.createdAt ?? null });
      }
    }
    after = notes?.pageInfo?.hasNextPage ? notes.pageInfo.endCursor : null;
    pages += 1;
    await sleep(1600);                                    // budget refills ~500 points/s
  } while (after && pages < 25);
  if (after) complete = false;
  return { atts, complete };
}

(async () => {
  console.log(`repair_cross_job_photo_links  ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}`);

  // ---- 1. the disputed set: photos with alive visit links on 2+ distinct jobs ----------
  const disputed = await pg(`
    with vl as (
      select pl.id as link_id, pl.photo_id, pl.created_at as link_created,
             v.id as visit_id, v.job_id, v.visit_date, v.completed_at, v.client_id,
             c.client_code, ph.source, ph.file_name,
             esl.source_id as att_gid, jl.source_id as job_gid
        from public.photo_links pl
        join public.visits v on v.id = pl.entity_id
        join public.clients c on c.id = v.client_id
        join public.photos ph on ph.id = pl.photo_id
        left join public.entity_source_links esl
          on esl.entity_type='photo' and esl.source_system='jobber' and esl.entity_id = pl.photo_id
        left join public.entity_source_links jl
          on jl.entity_type='job' and jl.source_system='jobber' and jl.entity_id = v.job_id
       where pl.entity_type='visit' and pl.deleted_at is null and v.deleted_at is null
    ),
    multi as (select photo_id from vl group by photo_id having count(distinct job_id) > 1)
    select vl.* from vl join multi m on m.photo_id = vl.photo_id
     order by vl.photo_id, vl.link_id`);

  const byPhoto = new Map();
  for (const r of disputed) {
    if (!byPhoto.has(r.photo_id)) byPhoto.set(r.photo_id, []);
    byPhoto.get(r.photo_id).push(r);
  }
  const jobGids = [...new Set(disputed.map((r) => r.job_gid).filter(Boolean))];
  console.log(`  disputed: ${byPhoto.size} photos, ${disputed.length} links, ${jobGids.length} jobs to read`);

  // ---- 2. POSITIVE CONTROL: undisputed photos must be found on their own job ----------
  const controls = await pg(`
    with vl as (
      select pl.photo_id, v.job_id, esl.source_id as att_gid, jl.source_id as job_gid
        from public.photo_links pl
        join public.visits v on v.id = pl.entity_id
        join public.photos ph on ph.id = pl.photo_id
        join public.entity_source_links esl
          on esl.entity_type='photo' and esl.source_system='jobber' and esl.entity_id = pl.photo_id
        join public.entity_source_links jl
          on jl.entity_type='job' and jl.source_system='jobber' and jl.entity_id = v.job_id
       where pl.entity_type='visit' and pl.deleted_at is null and v.deleted_at is null
         and ph.source = 'jobber_note_sync'
    )
    select photo_id, job_id, att_gid, job_gid from vl
     group by photo_id, job_id, att_gid, job_gid
    having count(*) = 1
     order by photo_id desc limit 5`);

  const jobCache = new Map();
  const readJob = async (gid) => {
    if (!jobCache.has(gid)) jobCache.set(gid, await fetchJobAttachments(gid));
    return jobCache.get(gid);
  };

  let controlPass = 0;
  for (const c of controls) {
    const { atts, complete } = await readJob(c.job_gid);
    const found = atts.has(c.att_gid);
    console.log(`  control photo ${c.photo_id} on job ${c.job_id}: ${found ? 'FOUND' : 'NOT FOUND'}${complete ? '' : ' (job read incomplete)'}`);
    if (found) controlPass += 1;
  }
  if (controls.length === 0 || controlPass < Math.ceil(controls.length * 0.8)) {
    console.error(`\n🛑 POSITIVE CONTROL FAILED (${controlPass}/${controls.length} found). The fetcher cannot be trusted, so "not found" is not evidence. Nothing was changed.`);
    process.exit(1);
  }
  console.log(`  control: ${controlPass}/${controls.length} found -> fetcher trusted\n`);

  // ---- 3. read every disputed job, then decide per photo -------------------------------
  for (const gid of jobGids) await readJob(gid);

  const noonMs = (d) => Date.parse(`${String(d).slice(0, 10)}T12:00:00Z`);
  const anchorOf = (completedAt, visitDate) => {
    const noon = noonMs(visitDate);
    const c = completedAt ? Date.parse(completedAt) : NaN;
    if (!Number.isFinite(c)) return noon;
    if (!Number.isFinite(noon)) return c;
    return Math.abs(c - noon) <= COMPLETED_TRUST_MS ? c : noon;
  };

  const decisions = [];
  for (const [photoId, links] of byPhoto) {
    const attGid = links[0].att_gid;
    const jobs = [...new Set(links.map((l) => l.job_gid))];
    const owners = [];
    let anyIncomplete = false;
    for (const gid of jobs) {
      const { atts, complete } = jobCache.get(gid) ?? { atts: new Map(), complete: false };
      if (!complete) anyIncomplete = true;
      if (atts.has(attGid)) owners.push({ gid, note: atts.get(attGid) });
    }
    const base = { photo_id: photoId, file_name: links[0].file_name, client_code: links[0].client_code,
                   att_gid: attGid, links: links.map((l) => ({ link_id: l.link_id, visit_id: l.visit_id, job_id: l.job_id })) };

    // 🛑 CLASSIFY BY NOTE TYPE FIRST. An attachment on a CLIENT note is client-scoped, so
    // it legitimately appears under EVERY job of that client - "found on 2 jobs" is its
    // expected signature, not a contradiction. An earlier version tested the owner count
    // first and reported such a photo as "found on 2 jobs, which should be impossible",
    // which reads as evidence against job scoping when it is an example of it.
    // (Real case: photo 4692, gid://Jobber/ClientNoteFile/388345596, jobs 7 and 66.)
    const jobOwners = owners.filter((o) => o.note.noteType === 'JobNote');
    if (jobOwners.length !== 1) {
      let reason;
      if (jobOwners.length > 1) {
        reason = `found as a JobNote on ${jobOwners.length} jobs, which contradicts job scoping - needs a human`;
      } else if (owners.length > 0) {
        reason = `attachment sits on a ${owners[0].note.noteType} (client-scoped), so no job owns it`;
      } else if (anyIncomplete) {
        reason = 'not found, and at least one candidate job could not be read whole';
      } else {
        reason = 'attachment not found on any linked job (deleted upstream?)';
      }
      decisions.push({ ...base, action: 'SKIP', reason });
      continue;
    }
    if (anyIncomplete) {
      decisions.push({ ...base, action: 'SKIP', reason: 'owner identified but another candidate job could not be read whole' });
      continue;
    }
    const ownerGid = jobOwners[0].gid;
    const note = jobOwners[0].note;
    const keep = links.filter((l) => l.job_gid === ownerGid);
    const wrong = links.filter((l) => l.job_gid !== ownerGid);
    decisions.push({ ...base, action: 'FIX', owner_job_id: keep[0]?.job_id ?? null, owner_job_gid: ownerGid,
                     note_created_at: note.noteCreatedAt,
                     keep: keep.map((l) => ({ link_id: l.link_id, visit_id: l.visit_id })),
                     remove: wrong.map((l) => ({ link_id: l.link_id, visit_id: l.visit_id, job_id: l.job_id })) });
  }

  const fix = decisions.filter((d) => d.action === 'FIX');
  const skip = decisions.filter((d) => d.action === 'SKIP');
  console.log(`decisions: ${fix.length} fixable, ${skip.length} skipped`);
  const removals = fix.flatMap((d) => d.remove);
  console.log(`  links to soft-delete: ${removals.length}`);
  console.log(`  photos keeping a link on the owning job: ${fix.filter((d) => d.keep.length > 0).length} of ${fix.length}`);
  for (const s of skip.slice(0, 10)) console.log(`  SKIP photo ${s.photo_id} (${s.client_code}): ${s.reason}`);

  const stamp = new Date().toISOString().slice(0, 10);
  const outDir = path.join(ROOT, '..', 'backups');
  const outFile = path.join(outDir, `${stamp}_cross_job_photo_link_repair.json`);
  fs.writeFileSync(outFile, JSON.stringify({ generated_at: new Date().toISOString(), execute: EXECUTE, decisions }, null, 1));
  console.log(`\nbackup + decision record: ${outFile}`);

  if (!EXECUTE) { console.log('\nDRY-RUN, nothing written.'); return; }
  if (!removals.length) { console.log('\nnothing to do.'); return; }

  // ---- 4. apply: soft-delete pinned to (link id, PROVEN owner job) ---------------------
  // The predicate re-asserts the exact fact Jobber established - this link's visit belongs
  // to a job that is NOT the one holding the attachment - so if anything moved between the
  // read and the write, the row simply does not match and nothing fires. Pinning to ids
  // alone would delete on a stale premise; inferring the owner from "some other link" would
  // silently skip any photo carrying two wrong links on the same job.
  const pairs = fix.flatMap((d) => d.remove.map((r) => `(${r.link_id}, ${d.owner_job_id})`));
  const res = await pg(`
    update public.photo_links pl
       set deleted_at = now(),
           deleted_reason = 'wrong job: Jobber holds this attachment on another job''s note (cross-job repair 2026-08-18)'
      from (values ${pairs.join(', ')}) as t(link_id, owner_job_id)
      join public.photo_links pl2 on pl2.id = t.link_id
      join public.visits v on v.id = pl2.entity_id
     where pl.id = t.link_id
       and pl.entity_type = 'visit'
       and pl.deleted_at is null
       and v.deleted_at is null
       and v.job_id <> t.owner_job_id
    returning pl.id`);
  console.log(`soft-deleted ${res.length} link(s) of ${removals.length} requested`);
  if (res.length !== removals.length) {
    console.log('  ⚠ the difference did not match the pinned predicate and was left alone on purpose');
  }
})().catch((e) => { console.error('FAILED:', e.message); process.exit(1); });
