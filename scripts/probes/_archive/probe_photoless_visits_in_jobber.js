// Probe each photo-less completed visit DIRECTLY via Jobber's visit(id).notes
// to find every recovery candidate. Segment results into:
//   A) unpinned + inside ±2d  → safe auto-recover (Lever 1 v2)
//   B) unpinned + outside ±2d → manual review (visit-specific but late/early)
//   C) pinned (any time)      → location-level photos (per Fred's rule, NOT
//                               linked to a specific visit, but valuable to
//                               surface for the client/property)
//   D) NO notes / NO attachments → genuinely no photos; manual list for Fred
//
// Output: prints a per-visit table. No DB writes (probe only).

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c) }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}

async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.toString().slice(0, 200)}`);
  return JSON.parse(r.body.toString());
}

async function gql(query, variables, retries = 5) {
  const body = JSON.stringify({ query, variables });
  const r = await http({
    hostname: 'api.getjobber.com',
    path: '/api/graphql',
    method: 'POST',
    headers: {
      Authorization: `Bearer ${process.env.JOBBER_ACCESS_TOKEN}`,
      'X-JOBBER-GRAPHQL-VERSION': '2026-04-13',
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    },
  }, body);
  if (r.status >= 300) {
    if (retries > 0 && (r.status === 429 || r.status >= 500)) {
      await new Promise(rs => setTimeout(rs, (6 - retries) * 4000));
      return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber ${r.status}: ${r.body.toString().slice(0, 200)}`);
  }
  const j = JSON.parse(r.body.toString());
  if (j.errors) {
    if (j.errors.some(e => e.extensions?.code === 'THROTTLED') && retries > 0) {
      await new Promise(rs => setTimeout(rs, (6 - retries) * 5000));
      return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber GQL: ${JSON.stringify(j.errors).slice(0, 300)}`);
  }
  // Pace by remaining budget. visit.notes(first:10) cost ≈ 5,056.
  const remaining = j.extensions?.cost?.throttleStatus?.currentlyAvailable;
  if (remaining != null && remaining < 6000) {
    await new Promise(rs => setTimeout(rs, Math.ceil((6000 - remaining) / 500) * 1000));
  }
  return j.data;
}

const WINDOW_DAYS = 2;
const WINDOW_MS = WINDOW_DAYS * 24 * 60 * 60 * 1000;

const Q = `
  query VisitNotes($id: EncodedId!) {
    visit(id: $id) {
      id startAt completedAt
      notes(first: 10) {
        nodes {
          ... on ClientNote { id pinned createdAt message fileAttachments { nodes { id fileName fileSize contentType } } }
          ... on JobNote    { id pinned createdAt message fileAttachments { nodes { id fileName fileSize contentType } } }
          ... on QuoteNote  { id pinned createdAt message fileAttachments { nodes { id fileName fileSize contentType } } }
          ... on RequestNote { id pinned createdAt message fileAttachments { nodes { id fileName fileSize contentType } } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
`;

(async () => {
  const visits = await pg(`
    SELECT v.id AS visit_id, v.completed_at, v.visit_date,
      esl_v.source_id AS visit_gid,
      c.client_code, c.name AS client_name
    FROM visits v
    JOIN entity_source_links esl_v ON esl_v.entity_type='visit' AND esl_v.entity_id=v.id AND esl_v.source_system='jobber'
    JOIN clients c ON c.id = v.client_id
    WHERE v.visit_status='completed'
      AND v.visit_date >= '2026-01-01'
      AND NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)
      AND NOT EXISTS (SELECT 1 FROM notes n WHERE n.visit_id=v.id AND EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='note' AND pl.entity_id=n.id))
    ORDER BY v.visit_date, c.client_code
  `);

  console.log(`==== Probing ${visits.length} photo-less completed visits via visit(id).notes ====\n`);

  const results = [];
  let i = 0;
  for (const v of visits) {
    i++;
    const anchorIso = (v.completed_at || `${v.visit_date}T00:00:00Z`);
    const anchorMs = new Date(anchorIso).getTime();

    let notes = [];
    try {
      const d = await gql(Q, { id: v.visit_gid });
      notes = d.visit?.notes?.nodes || [];
    } catch (e) {
      results.push({ visit_id: v.visit_id, client_code: v.client_code || '?', date: v.visit_date, status: 'ERR', detail: e.message.slice(0, 60) });
      continue;
    }

    let bucketA = 0, bucketB = 0, bucketC = 0;
    for (const n of notes) {
      const att = (n.fileAttachments?.nodes || []).length;
      if (!att) continue;
      const inWindow = Math.abs(new Date(n.createdAt).getTime() - anchorMs) <= WINDOW_MS;
      if (n.pinned) bucketC += att;
      else if (inWindow) bucketA += att;
      else bucketB += att;
    }

    let status, detail;
    if (bucketA + bucketB + bucketC === 0) {
      status = 'NONE';
      detail = `${notes.length} notes, no attachments`;
    } else {
      status = 'HAS';
      detail = `A:${bucketA} unpinned/in-window  B:${bucketB} unpinned/out-window  C:${bucketC} pinned/location`;
    }
    results.push({ visit_id: v.visit_id, client_code: v.client_code || '?', date: v.visit_date, status, detail, A: bucketA, B: bucketB, C: bucketC });
    console.log(`[${i}/${visits.length}] v${v.visit_id} ${v.client_code || '?'} ${v.visit_date}  ${status}  ${detail}`);
  }

  // Aggregate
  const totals = { HAS: 0, NONE: 0, ERR: 0, A: 0, B: 0, C: 0 };
  for (const r of results) {
    totals[r.status]++;
    totals.A += r.A || 0; totals.B += r.B || 0; totals.C += r.C || 0;
  }

  console.log(`\n==== Summary ====`);
  console.log(`  Visits probed:                              ${results.length}`);
  console.log(`  HAS attachments somewhere:                  ${totals.HAS}`);
  console.log(`  NONE — no attachments anywhere:             ${totals.NONE}`);
  console.log(`  ERR (Jobber error):                         ${totals.ERR}`);
  console.log(`  Total attachments by bucket:`);
  console.log(`    A) unpinned + inside ±2d (auto-recover):  ${totals.A}`);
  console.log(`    B) unpinned + outside ±2d (review):       ${totals.B}`);
  console.log(`    C) pinned/location-level (don't link):    ${totals.C}`);

  // Save manual list for Fred
  const manualList = results.filter(r => r.status === 'NONE');
  if (manualList.length) {
    console.log(`\n==== Manual review list (${manualList.length} visits with NO attachments anywhere in Jobber) ====`);
    console.log('client_code, visit_date, visit_id');
    for (const r of manualList) console.log(`${r.client_code}, ${r.date}, ${r.visit_id}`);
  }

  // Detail of bucket B (unpinned outside window — these are real visit-specific photos but timing is off)
  const reviewList = results.filter(r => r.B > 0);
  if (reviewList.length) {
    console.log(`\n==== Bucket B detail: visits with unpinned attachments outside ±2d (likely backfilled later) ====`);
    console.log('client_code, visit_date, visit_id, attachments');
    for (const r of reviewList) console.log(`${r.client_code}, ${r.date}, ${r.visit_id}, ${r.B}`);
  }
})();
