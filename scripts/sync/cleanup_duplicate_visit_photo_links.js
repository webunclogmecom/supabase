#!/usr/bin/env node
// ============================================================================
// cleanup_duplicate_visit_photo_links.js
// ============================================================================
// Jobber scopes notes to the JOB, not the visit, so one note's photos land on
// EVERY visit of that job within the sync's +/-2 day window. This pass removes
// the surplus links AFTER the fact, keeping the one visit the evidence supports.
//
// 🛑 WHY THIS IS A CLEANUP AND NOT A CHANGE TO THE INGEST (settled 2026-08-18).
// The obvious fix is to make `sync_jobber_note_photos.js` pick ONE visit instead
// of accepting every candidate. It was proposed, measured, and REJECTED:
//   * 17 of 41 misplaced August photos sit ONLY on a wrong visit, so fan-out is
//     not reliably "the right link plus extras". A narrower rule that guesses
//     wrong leaves NO duplicate anywhere to reveal it: a missing photo, which
//     nothing surfaces, instead of clutter, which the Reopened chip does.
//   * a window rule is inapplicable to 13% of visits (936 of 1,072 usable;
//     38 backwards, 98 longer than 24h).
//   * the audit that had hindsight AND two signals still declined 4% as
//     undecidable. A live ingest has less information, not more.
// ⇒ Over-link at write time, adjudicate later with better evidence. Do not
//   "simplify" this by moving the logic into the sync.
//   Full reasoning: Building Apps/Admin Review/docs/14-jobber-photos-brainstorm.md
//
// EVIDENCE, strongest first, both compared against the visit's WINDOW:
//   1. camera EXIF DateTime from the image bytes  (~19% coverage, crew-dependent)
//   2. Jobber note createdAt                       (~100%, independent of crews)
// 🛑 The note time is read from the JOBBER API, never from `notes.note_date`:
//    ours is a now() ingest fallback on 287 of 310 note_sync rows (92.6%).
// 🛑 Compared against [start_at, completed_at], NEVER against visit_date. An
//    overnight visit starting 07-13 and finishing 00:40 on 07-14 legitimately
//    owns a photo stamped 07-14 00:07.
//
// THE FOUR GUARDS. Each exists because of a real near-miss:
//   G1 never remove a photo's LAST alive visit link  -> that is deleting a
//      client's photo, not moving it. Stopped link 42263 on 2026-08-18.
//   G2 never remove a CLASSIFIED link                -> classified means
//      PUBLISHED (customer.wo_photos INNER JOINs photo_classifications), so
//      removing one changes what a client sees. 49 such links exist today.
//   G3 DECLINE the group if ANY candidate's window is unusable -> 38 visits
//      have completed_at < start_at (all wrong in JOBBER, not ours) and 98 exceed
//      24h. 🛑 Do NOT "just skip the bad one and choose among the rest": that is how
//      a guard produces a confident WRONG answer. Proven on job 1544.
//   G4 decline when ambiguous                        -> two candidates within
//      AMBIGUOUS_MIN minutes, or the stamp inside more than one window.
//
// DRY RUN BY DEFAULT. Writes only with --apply.
//
// Usage:
//   node scripts/sync/cleanup_duplicate_visit_photo_links.js                 # dry run, all
//   node scripts/sync/cleanup_duplicate_visit_photo_links.js --since=2026-08-01
//   node scripts/sync/cleanup_duplicate_visit_photo_links.js --job=1544
//   node scripts/sync/cleanup_duplicate_visit_photo_links.js --apply --limit=50
// Requires JOBBER_TOKEN in env:  cd Slack && export JOBBER_TOKEN=$(./jobber-token.sh)
// ============================================================================

const https = require('https');
const fs = require('fs');
const path = require('path');

for (const line of fs.readFileSync(path.resolve(__dirname, '../../.env'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
  if (!m) continue;
  let v = m[2].trim();
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
  if (!(m[1] in process.env)) process.env[m[1]] = v;
}

const REF = process.env.SUPABASE_PROJECT_ID || 'wbasvhvvismukaqdnouk';
const JT = (process.env.JOBBER_TOKEN || '').trim();

const arg = (k, d) => {
  const a = process.argv.find(x => x.startsWith(`--${k}=`));
  return a ? a.split('=').slice(1).join('=') : d;
};
const APPLY = process.argv.includes('--apply');
const SINCE = arg('since', null);
const ONLY_JOB = arg('job', null);
const LIMIT = Number(arg('limit', '0')) || 0;
const AMBIGUOUS_MIN = Number(arg('ambiguous-minutes', '30'));
const MAX_WINDOW_H = Number(arg('max-window-hours', '24'));

function sql(q) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: q });
    const r = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${REF}/database/query`,
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + process.env.SUPABASE_PAT,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    }, x => {
      let d = '';
      x.setEncoding('utf8');
      x.on('data', c => (d += c));
      x.on('end', () => {
        let j;
        try { j = JSON.parse(d); } catch { return rej(new Error('bad json from Supabase: ' + d.slice(0, 200))); }
        if (j && j.message && !Array.isArray(j)) return rej(new Error(String(j.message).slice(0, 300)));
        res(Array.isArray(j) ? j : (j.result || []));
      });
    });
    r.on('error', rej);
    r.write(body);
    r.end();
  });
}

// 🛑 Jobber sheds load with an HTML "waiting room" at HTTP 200. Content-type is the
// only tell, and a missing `data` key is a throttle, not an empty result. Both must
// THROW so a non-answer can never be read as "this note does not exist".
function gql(query, variables) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query, variables });
    const r = https.request({
      hostname: 'api.getjobber.com',
      path: '/api/graphql',
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + JT,
        'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    }, x => {
      const ctype = x.headers['content-type'] || '';
      let d = '';
      x.setEncoding('utf8');
      x.on('data', c => (d += c));
      x.on('end', () => {
        if (!ctype.includes('json')) return rej(new Error(`NON_JSON (${ctype}) at HTTP ${x.statusCode}`));
        let j;
        try { j = JSON.parse(d); } catch { return rej(new Error('bad json from Jobber')); }
        if (!('data' in j)) return rej(new Error('no data key: ' + JSON.stringify(j.errors || j).slice(0, 160)));
        res(j.data);
      });
    });
    r.on('error', rej);
    r.write(body);
    r.end();
  });
}

// 🛑 50/50, NOT 100/100. notes(100) x fileAttachments(100) is 10,000 nodes and exceeds Jobber's
// query-cost ceiling. Jobber then returns an error, which this script correctly DECLINES on, so
// raising these silently turns the whole pass into a no-op that reads as "nothing to fix".
// Measured 2026-08-18: at 100/100 every group declined with "jobber did not answer".
const JOB_Q = `query($id: EncodedId!) {
  job(id: $id) {
    id
    notes(first: 50) {
      nodes {
        __typename
        ... on JobNote    { id createdAt fileAttachments(first: 50) { nodes { id } } }
        ... on ClientNote { id createdAt fileAttachments(first: 50) { nodes { id } } }
      }
    }
  }
}`;

const sqlEsc = s => "'" + String(s).replace(/'/g, "''") + "'";

(async () => {
  if (!JT) {
    console.error('FATAL: JOBBER_TOKEN not set. cd Slack && export JOBBER_TOKEN=$(./jobber-token.sh)');
    process.exit(1);
  }

  console.log(`cleanup_duplicate_visit_photo_links  ${APPLY ? '*** APPLY ***' : '(dry run)'}`);
  console.log(`  ambiguity threshold ${AMBIGUOUS_MIN} min | max usable window ${MAX_WINDOW_H}h` +
    `${SINCE ? ` | since ${SINCE}` : ''}${ONLY_JOB ? ` | job ${ONLY_JOB}` : ''}${LIMIT ? ` | limit ${LIMIT}` : ''}\n`);

  // Candidates: photos linked to more than one LIVE visit of the SAME job.
  // Cross-job duplicates are deliberately out of scope: they are a different defect
  // (102 exist, all same-client, all historical jobber_migration residue).
  const rows = await sql(`
    with multi as (
      select l.photo_id, v.job_id
      from public.photo_links l
        join public.visits v on v.id = l.entity_id and v.deleted_at is null
      where l.entity_type = 'visit' and l.deleted_at is null
        ${SINCE ? `and v.visit_date >= date ${sqlEsc(SINCE)}` : ''}
        ${ONLY_JOB ? `and v.job_id = ${Number(ONLY_JOB)}` : ''}
      group by l.photo_id, v.job_id
      having count(distinct l.entity_id) > 1
    )
    select l.id            as link_id,
           l.photo_id,
           l.entity_id     as visit_id,
           v.job_id,
           v.visit_date,
           v.start_at,
           v.completed_at,
           c.client_code,
           p.file_name,
           esl.source_id   as att_gid,
           jesl.source_id  as job_gid,
           (select count(*) from public.photo_classifications pc where pc.photo_link_id = l.id) as classified
    from multi m
      join public.photo_links l on l.photo_id = m.photo_id and l.entity_type = 'visit' and l.deleted_at is null
      join public.visits v on v.id = l.entity_id and v.deleted_at is null and v.job_id = m.job_id
      join public.clients c on c.id = v.client_id
      join public.photos p on p.id = l.photo_id
      left join public.entity_source_links esl
        on esl.entity_type = 'photo' and esl.source_system = 'jobber' and esl.entity_id = p.id
      left join public.entity_source_links jesl
        on jesl.entity_type = 'job' and jesl.source_system = 'jobber' and jesl.entity_id = v.job_id
    order by v.job_id, l.photo_id, l.entity_id
  `);

  // group into (job, photo) -> its links
  const groups = new Map();
  for (const r of rows) {
    const k = `${r.job_id}|${r.photo_id}`;
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(r);
  }
  console.log(`candidate groups (one photo on several visits of one job): ${groups.size}`);
  console.log(`candidate links: ${rows.length}\n`);

  // note createdAt per job, fetched once
  const jobNotes = new Map();
  const jobGids = [...new Set(rows.map(r => r.job_gid).filter(Boolean))];
  let consecutiveFail = 0;
  for (const gid of jobGids) {
    try {
      const d = await gql(JOB_Q, { id: gid });
      const map = new Map();
      for (const n of (d.job?.notes?.nodes || [])) {
        for (const a of (n.fileAttachments?.nodes || [])) map.set(a.id, n.createdAt);
      }
      jobNotes.set(gid, map);
      consecutiveFail = 0;
    } catch (e) {
      jobNotes.set(gid, null); // null = unknown, never treated as "no note"
      consecutiveFail++;
      // 🛑 A real outage must stop the run, not walk the fleet declining everything.
      if (consecutiveFail >= 8) {
        console.error(`\nABORT: 8 consecutive Jobber failures (${e.message}). Stopping so a non-answer is not read as evidence.`);
        process.exit(2);
      }
    }
    await new Promise(r => setTimeout(r, 120));
  }

  const usableWindow = r => {
    if (!r.start_at || !r.completed_at) return false;
    const s = Date.parse(r.start_at), e = Date.parse(r.completed_at);
    if (!(e > s)) return false;                                   // G3: backwards
    if ((e - s) > MAX_WINDOW_H * 3600e3) return false;            // G3: implausibly long
    return true;
  };

  const removals = [];
  const stats = { groups: 0, decided: 0, declined: 0, byReason: {} };
  const decline = why => { stats.declined++; stats.byReason[why] = (stats.byReason[why] || 0) + 1; };

  for (const [, links] of groups) {
    stats.groups++;
    const notes = jobNotes.get(links[0].job_gid);
    if (notes === null) { decline('jobber did not answer for this job'); continue; }
    if (!notes) { decline('no jobber link for this job'); continue; }

    const iso = links[0].att_gid ? notes.get(links[0].att_gid) : null;
    if (!iso) { decline('no note timestamp for this attachment'); continue; }
    const stamp = Date.parse(iso);
    if (!Number.isFinite(stamp)) { decline('unparseable note timestamp'); continue; }

    // 🛑 G3, AND THE SUBTLE HALF OF IT. If ANY candidate has an unusable window we must DECLINE
    // the whole group, not adjudicate among the survivors. Excluding a candidate makes the
    // remaining choice look MORE confident while removing the very visit that might own the photo.
    // Measured 2026-08-18 on job 1544: visit 6955's window is -12.2h (backwards, one of the 38),
    // so it was dropped, and the note timed 7 SECONDS before 6955's completion was then confidently
    // assigned to 6835 instead. A silent wrong answer produced BY a safety guard.
    const usable = links.filter(usableWindow);
    if (usable.length !== links.length) {
      decline('a candidate visit has an unusable window, so the true owner may have been excluded');
      continue;
    }
    if (usable.length < 2) { decline('fewer than 2 candidates have a usable window'); continue; }

    const inside = usable.filter(r => stamp >= Date.parse(r.start_at) && stamp <= Date.parse(r.completed_at));
    let winner = null;
    if (inside.length === 1) {
      winner = inside[0];
    } else if (inside.length > 1) {
      decline('stamp falls inside more than one visit window'); continue;   // G4
    } else {
      const sorted = usable
        .map(r => ({ r, d: Math.abs(stamp - Date.parse(r.completed_at)) }))
        .sort((a, b) => a.d - b.d);
      if (sorted.length > 1 && (sorted[1].d - sorted[0].d) < AMBIGUOUS_MIN * 60e3) {
        decline(`nearest two candidates within ${AMBIGUOUS_MIN} min`); continue;   // G4
      }
      winner = sorted[0].r;
    }

    // everything on this photo that is NOT the winner is surplus, subject to G1 and G2
    const losers = links.filter(r => r.link_id !== winner.link_id);
    const keptAlive = 1; // the winner
    for (const l of losers) {
      if (Number(l.classified) > 0) { decline('a surplus link is classified, i.e. published'); continue; } // G2
      removals.push({ ...l, winner_visit: winner.visit_id, stamp: iso });
    }
    if (keptAlive < 1) { decline('would orphan the photo'); continue; } // G1, belt and braces
    stats.decided++;
  }

  // 🛑 G1, enforced against the DATABASE rather than against this run's bookkeeping.
  // A photo could have links outside the candidate set; only the DB knows the true count.
  let orphanBlocked = 0;
  if (removals.length) {
    const ids = removals.map(r => r.link_id).join(',');
    const survivors = await sql(`
      select l.id as link_id,
             (select count(*) from public.photo_links l2
               join public.visits v2 on v2.id = l2.entity_id and v2.deleted_at is null
              where l2.photo_id = l.photo_id and l2.entity_type = 'visit'
                and l2.deleted_at is null and l2.id <> l.id) as other_alive
      from public.photo_links l where l.id in (${ids})
    `);
    const other = new Map(survivors.map(s => [Number(s.link_id), Number(s.other_alive)]));
    for (let i = removals.length - 1; i >= 0; i--) {
      if ((other.get(removals[i].link_id) || 0) < 1) { removals.splice(i, 1); orphanBlocked++; }
    }
  }

  const capped = LIMIT ? removals.slice(0, LIMIT) : removals;

  console.log('DECISION SUMMARY');
  console.log(`  groups examined ............ ${stats.groups}`);
  console.log(`  groups decided ............. ${stats.decided}`);
  console.log(`  groups declined ............ ${stats.declined}`);
  for (const [k, v] of Object.entries(stats.byReason)) console.log(`      ${k}: ${v}`);
  console.log(`  surplus links to remove .... ${removals.length}${LIMIT && removals.length > LIMIT ? ` (capped to ${LIMIT} this run)` : ''}`);
  console.log(`  blocked by never-orphan .... ${orphanBlocked}`);

  if (!capped.length) { console.log('\nnothing to do.'); return; }

  console.log('\nPLANNED REMOVALS');
  for (const r of capped.slice(0, 40)) {
    console.log(`  link ${r.link_id}  ${r.client_code}  ${r.file_name}  on visit ${r.visit_id} (${r.visit_date})` +
      `  -> keep ${r.winner_visit}   [note ${r.stamp}]`);
  }
  if (capped.length > 40) console.log(`  ... and ${capped.length - 40} more`);

  if (!APPLY) {
    console.log('\nDRY RUN. Re-run with --apply to write. Nothing was changed.');
    return;
  }

  const ids = capped.map(r => r.link_id).join(',');
  await sql(`
    do $cleanup$
    declare n_before int; n_after int; n_classified int; n_orphan int;
    begin
      select count(*) into n_before from public.photo_links where id in (${ids}) and deleted_at is null;
      if n_before <> ${capped.length} then
        raise exception 'ABORT: expected % alive links, found %. State changed under the run.', ${capped.length}, n_before;
      end if;

      -- G2 re-asserted at write time, not just at plan time
      select count(*) into n_classified from public.photo_links l
        join public.photo_classifications pc on pc.photo_link_id = l.id where l.id in (${ids});
      if n_classified <> 0 then
        raise exception 'ABORT: % links are classified (published). Refusing.', n_classified;
      end if;

      -- G1 re-asserted at write time
      select count(*) into n_orphan from public.photo_links l
       where l.id in (${ids})
         and (select count(*) from public.photo_links l2
               join public.visits v2 on v2.id = l2.entity_id and v2.deleted_at is null
              where l2.photo_id = l.photo_id and l2.entity_type='visit'
                and l2.deleted_at is null and l2.id <> l.id) = 0;
      if n_orphan <> 0 then
        raise exception 'ABORT: % photos would be left with no alive visit link.', n_orphan;
      end if;

      perform public.soft_delete_photo_link(
                id,
                'duplicate visit link: Jobber note createdAt matches another visit of the same job (cleanup_duplicate_visit_photo_links)')
        from unnest(array[${ids}]::bigint[]) as id;

      select count(*) into n_after from public.photo_links where id in (${ids}) and deleted_at is null;
      if n_after <> 0 then raise exception 'ABORT: % links still alive after soft delete', n_after; end if;
    end $cleanup$;
  `);
  console.log(`\nAPPLIED: ${capped.length} surplus links soft-deleted, reversible via audit.logs.`);
})().catch(e => { console.error('FATAL: ' + e.message); process.exit(1); });
