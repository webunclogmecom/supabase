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
// EVIDENCE, strongest first, both scored against the visit's `completed_at`:
//   1. camera EXIF DateTime from the image bytes  (~19% coverage, crew-dependent)
//   2. Jobber note createdAt                       (~100%, independent of crews)
// 🛑 The note time is read from the JOBBER API, never from `notes.note_date`:
//    ours is a now() ingest fallback on 287 of 310 note_sync rows (92.6%).
//
// 🛑 THE ANCHOR IS `completed_at` ALONE (changed 2026-08-18). NEVER REINTRODUCE `start_at`.
// The old rule tested containment in [start_at, completed_at]. Wrong at the root: `start_at` is a
// SCHEDULED SLOT, not a measured start (:00 seconds on 1,072 of 1,072 completed visits vs 17 of
// 1,072 for completed_at), so the pair was never a work window and its ordering was never an
// invariant. That misreading stalled 71 of 80 groups on a "bad upstream data" theory that was false.
//
// CALIBRATION (ground truth, 2026-08-18). A correct note is created AT THE COMPLETION TAP:
//   median 2.2 SECONDS from completed_at over 900 known-correct links; 84.2% within 60s;
//   96.8% within 30 min; 99.29% inside [-2h, +6h]. An independent EXIF-labelled set (n=262)
//   agrees (median 4.0s) and shows ZERO of 488 photos captured AFTER completion.
//   Band = -GRACE_AFTER_H .. +LOOKBACK_H. The late tail has a HARD EDGE: of 143 correct links
//   whose note followed completion, 141 are within 60 min and the 1-2h/2-4h/4-6h/6-12h bins are
//   ALL EMPTY. So grace beyond ~1h buys nothing until 12h, and 2h is the honest stopping point.
//   Backtest: 89.4% correct / 0.08% WRONG / 10.5% declined; on the EXIF set 0 wrong in 5,240 trials.
//
// THE FIVE GUARDS. Each exists because of a real near-miss:
//   G1 never remove a photo's LAST alive visit link  -> that is deleting a
//      client's photo, not moving it. Stopped link 42263 on 2026-08-18.
//   G2 never remove a CLASSIFIED link                -> classified means
//      PUBLISHED (customer.wo_photos INNER JOINs photo_classifications), so
//      removing one changes what a client sees.
//   G3 DECLINE the group if ANY candidate lacks `completed_at` -> the true owner
//      could be the one we cannot score.
//      🛑 RANK ALL CANDIDATES FIRST, THEN GATE THE WINNER ON THE BAND. Do NOT filter
//      candidates to the band and choose among the survivors. Proven on job 1544: excluding a
//      candidate made the remaining choice look MORE certain while removing the visit that
//      probably owned the photo. A guard that narrows the field must WIDEN the doubt.
//   G4 decline when ambiguous                        -> two candidates within
//      AMBIGUOUS_MIN minutes of each other in distance.
//   G5 decline a ClientNote attachment               -> ClientNotes are CLIENT-scoped,
//      not job-scoped, so createdAt carries no visit signal: median 13.73h from completion
//      vs 2.2 SECONDS for a JobNote, and this rule run on them is 8.45% wrong vs 0.05%.
//      The kind is readable straight out of the base64 GID, so the guard is free.
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
// ── THE ANCHOR, calibrated on ground truth 2026-08-18. See docs/audits/2026-08-18_photo_anchor_audit.md.
// A correct note is created at the MOMENT OF THE COMPLETION TAP: median 2.2 SECONDS from
// completed_at across 900 known-correct links, 84.2% within 60s, 96.8% within 30 min.
// So the band is deliberately tight; it is not a guess.
const AMBIGUOUS_MIN = Number(arg('ambiguous-minutes', '90'));   // rival this close in distance -> decline
const LOOKBACK_H    = Number(arg('lookback-hours', '6'));       // stamp may precede completed_at by this much
const GRACE_AFTER_H = Number(arg('grace-after-hours', '2'));    // ...or follow it by this much

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
  console.log(`  anchor completed_at, band -${GRACE_AFTER_H}h..+${LOOKBACK_H}h | ambiguity ${AMBIGUOUS_MIN} min` +
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

  // 🛑 THE ANCHOR IS `completed_at` ALONE. `start_at` IS NOT USED AND MUST NOT BE REINTRODUCED.
  // The old rule tested containment in [start_at, completed_at]. That was wrong at the root:
  // `start_at` is a SCHEDULED SLOT, not a measured start (:00 seconds on 1,072 of 1,072 completed
  // visits, vs 17 of 1,072 for completed_at), so the pair was never a work window and its ordering
  // was never an invariant. 38 visits have completed_at < start_at; every one matches Jobber to the
  // second, so there was nothing upstream to repair. That misreading is what stalled 71 of 80 groups.
  const anchorOk = r => !!r.completed_at && Number.isFinite(Date.parse(r.completed_at));

  // Jobber attachment GIDs are base64 of `gid://Jobber/<Kind>/<id>`.
  // 🛑 A ClientNoteFile is CLIENT-scoped, not job-scoped, so its createdAt carries NO visit signal:
  // measured median 13.73h from completion (IQR 7.57-23.73h) against 2.2 SECONDS for a JobNote, and
  // running this rule on them produces an 8.45% wrong-removal rate versus 0.05%. A 160x difference,
  // and the guard costs nothing because the GID says which kind it is with no API call.
  const attKind = gid => {
    if (!gid) return null;
    try { return (Buffer.from(String(gid), 'base64').toString('utf8').match(/gid:\/\/Jobber\/([A-Za-z]+)\//) || [])[1] || null; }
    catch { return null; }
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

    // G5: a ClientNote attachment carries no visit signal at all. Decline before adjudicating.
    const kind = attKind(links[0].att_gid);
    if (kind && /^ClientNote/i.test(kind)) { decline('attachment is a ClientNote (client-scoped, no visit signal)'); continue; }

    // G3, restated for the anchor: every candidate must HAVE the anchor, or the true owner
    // could be the one we cannot score. Decline the whole group rather than score the rest.
    if (!links.every(anchorOk)) { decline('a candidate visit has no completed_at, so the true owner cannot be scored'); continue; }
    if (links.length < 2) { decline('fewer than 2 candidates'); continue; }

    // 🛑 ORDER IS LOAD-BEARING: rank ALL candidates FIRST, then gate the winner on the band.
    // Do NOT filter candidates to the band and pick among the survivors. That is precisely the
    // failure already recorded on job 1544, where excluding a candidate made the remaining choice
    // look MORE certain while removing the visit that probably owned the photo. Ranking first turns
    // "the true owner is nowhere near this note" into a DECLINE; pre-filtering turns it into a
    // confident WRONG removal. A guard that narrows the field must widen the doubt, not shrink it.
    const sorted = links
      .map(r => ({ r, delta: Date.parse(r.completed_at) - stamp, d: Math.abs(Date.parse(r.completed_at) - stamp) }))
      .sort((a, b) => a.d - b.d);

    if (sorted.length > 1 && (sorted[1].d - sorted[0].d) < AMBIGUOUS_MIN * 60e3) {
      decline(`nearest two candidates within ${AMBIGUOUS_MIN} min`); continue;   // G4
    }

    // Band gate, applied to the winner only. delta > 0 means the note preceded the completion tap.
    const best = sorted[0];
    if (best.delta > LOOKBACK_H * 3600e3) { decline(`winner outside band: note ${(best.delta / 3600e3).toFixed(1)}h before completion`); continue; }
    if (best.delta < -GRACE_AFTER_H * 3600e3) { decline(`winner outside band: note ${(-best.delta / 3600e3).toFixed(1)}h after completion`); continue; }
    const winner = best.r;

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
