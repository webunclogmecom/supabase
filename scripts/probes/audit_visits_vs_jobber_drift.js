// scripts/probes/audit_visits_vs_jobber_drift.js
//
// Three-in-one probe (read-only — no DB writes):
//
// 1. Verify Calendar app fetches from Prod: count May 2026 visits and
//    compare to the "156 visits" the Calendar UI showed at 12:30 ET.
// 2. Audit 009-CN July 4 — find row in public.visits, look up its Jobber
//    GID via entity_source_links, query Jobber for the GID, report whether
//    Jobber currently treats it as a Visit, a Task, or unknown.
// 3. Date-drift sample — for a window of upcoming visits in DB, query
//    Jobber for each linked GID's current startAt and report mismatches.
//
// Run:
//   cd Supabase
//   node scripts/probes/audit_visits_vs_jobber_drift.js
//
// Or scope to client 009-CN only:
//   node scripts/probes/audit_visits_vs_jobber_drift.js --client 009-CN

const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
let JOBBER_TOKEN = process.env.JOBBER_ACCESS_TOKEN;

if (!URL || !KEY) throw new Error('Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY');

const argv = process.argv.slice(2);
const argClient = (() => { const i = argv.indexOf('--client'); return i >= 0 ? argv[i + 1] : null; })();
const argDateScan = argv.includes('--date-scan');

const REST_HEADERS = { apikey: KEY, Authorization: `Bearer ${KEY}` };

async function rest(qs) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, { headers: REST_HEADERS });
  if (!r.ok) throw new Error(`REST ${r.status} ${qs} ${await r.text()}`);
  return r.json();
}

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  if (!r.ok) throw new Error(`SQL ${r.status} ${await r.text()}`);
  return r.json();
}

async function gql(query, variables = {}) {
  const r = await fetch('https://api.getjobber.com/api/graphql', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${JOBBER_TOKEN}`,
      'Content-Type': 'application/json',
      'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
    },
    body: JSON.stringify({ query, variables }),
  });
  const j = await r.json();
  // Return both data and errors for inspection (don't throw on errors — we
  // may legitimately get "NOT_FOUND" for stale GIDs).
  return { status: r.status, data: j.data, errors: j.errors };
}

function decodeGid(b64) {
  try { return Buffer.from(b64, 'base64').toString('utf8'); } catch { return null; }
}

function inferTypeFromGid(b64) {
  const dec = decodeGid(b64);
  if (!dec) return null;
  // gid://Jobber/Visit/12345 → "Visit"
  const m = dec.match(/^gid:\/\/Jobber\/([A-Za-z_]+)\//);
  return m ? m[1] : null;
}

async function refreshJobberTokenFromDb() {
  const r = await fetch(`${URL}/rest/v1/webhook_tokens?source_system=eq.jobber&select=access_token,expires_at`, {
    headers: REST_HEADERS,
  });
  const rows = await r.json();
  if (rows[0]?.access_token) {
    JOBBER_TOKEN = rows[0].access_token;
    console.log(`(Using DB-stored Jobber token, expires ${rows[0].expires_at})`);
  }
}

async function main() {
  await refreshJobberTokenFromDb();
  const today = new Date().toISOString().slice(0, 10);

  // === STEP 1: Calendar/Prod consistency — May 2026 visit count =============
  console.log('=== STEP 1: Calendar visit count vs Prod DB =================');
  const mayCount = await sql(`
    SELECT COUNT(*)::int AS n
    FROM public.visits
    WHERE visit_date BETWEEN '2026-04-26' AND '2026-06-06'
      AND visit_status IS DISTINCT FROM 'cancelled';
  `);
  console.log(`Prod public.visits in May-window (Apr-26..Jun-06, !cancelled): ${mayCount[0].n}`);
  console.log('Calendar UI showed: 156 visits — match if number above is in the 150-165 range.');

  // === STEP 2: 009-CN July 4 ===============================================
  console.log('\n=== STEP 2: 009-CN July 4 case ==============================');
  const clients009 = await sql(`
    SELECT id, client_code, name
    FROM public.clients
    WHERE client_code = '009-CN';
  `);
  console.log(`Clients with code 009-CN:`, clients009);

  if (clients009.length === 0) {
    console.log('  → 009-CN client not found. Aborting 009-CN section.');
  } else {
    const c = clients009[0];
    // pull all visits for this client in 2026 to see what's there
    const v009 = await sql(`
      SELECT v.id, v.visit_date, v.visit_status, v.title, v.start_at, v.completed_at,
             esl.source_id AS jobber_gid, esl.match_method
      FROM public.visits v
      LEFT JOIN public.entity_source_links esl
        ON esl.entity_type = 'visit'
       AND esl.entity_id = v.id
       AND esl.source_system = 'jobber'
      WHERE v.client_id = ${c.id}
        AND v.visit_date >= '2026-01-01'
      ORDER BY v.visit_date;
    `);
    console.log(`009-CN visits since 2026-01-01 (${v009.length} rows):`);
    for (const r of v009) {
      const t = r.jobber_gid ? inferTypeFromGid(r.jobber_gid) : null;
      console.log(`  visit_date=${r.visit_date} id=${r.id} status=${r.visit_status} title="${r.title || ''}" gid=${r.jobber_gid || 'NULL'} (decoded type: ${t})`);
    }

    // Focus on July 4
    const july4 = v009.filter(v => v.visit_date === '2026-07-04');
    if (july4.length) {
      console.log(`\n  >>> Focusing on ${july4.length} July 4 row(s) <<<`);
      for (const row of july4) {
        if (!row.jobber_gid) {
          console.log(`  July 4 visit id=${row.id} has NO Jobber GID — orphan?`);
          continue;
        }
        // Try Visit lookup first
        const vRes = await gql(`
          query($id: EncodedId!) {
            visit(id: $id) {
              id title startAt endAt completedAt visitStatus
              client { id }
              job { id title }
            }
          }
        `, { id: row.jobber_gid });

        // Then try Task lookup (Jobber type: Task)
        const tRes = await gql(`
          query($id: EncodedId!) {
            task(id: $id) {
              id name dueDate completed
              client { id }
              job { id title }
            }
          }
        `, { id: row.jobber_gid });

        console.log(`  GID: ${row.jobber_gid}`);
        console.log(`    decoded: ${decodeGid(row.jobber_gid)}`);
        console.log(`    visit(): status=${vRes.status} data=${JSON.stringify(vRes.data)} errors=${JSON.stringify(vRes.errors || null).slice(0, 200)}`);
        console.log(`    task() : status=${tRes.status} data=${JSON.stringify(tRes.data)} errors=${JSON.stringify(tRes.errors || null).slice(0, 200)}`);
      }
    } else {
      console.log('\n  No July 4 row in DB for 009-CN. Maybe it was already cleaned up — or it lives on a different date.');
    }
  }

  if (argClient) {
    // Stop here if user asked to scope to single client
    console.log('\n--client scope set — stopping after 009-CN audit.');
    return;
  }

  // === STEP 3: Sample date-drift on last 60 + next 60 days =================
  console.log('\n=== STEP 3: Date-drift sweep (Jobber-linked visits, ±60 days) ===');
  const sample = await sql(`
    SELECT v.id, v.visit_date, v.visit_status, v.title,
           v.start_at, v.completed_at,
           c.client_code, c.name AS client_name,
           esl.source_id AS jobber_gid
    FROM public.visits v
    JOIN public.clients c ON c.id = v.client_id
    JOIN public.entity_source_links esl
      ON esl.entity_type = 'visit' AND esl.entity_id = v.id AND esl.source_system = 'jobber'
    WHERE v.visit_date BETWEEN ('${today}'::date - INTERVAL '60 days')::date
                           AND ('${today}'::date + INTERVAL '60 days')::date
      AND v.visit_status IS DISTINCT FROM 'cancelled'
    ORDER BY v.visit_date DESC
    LIMIT 250;
  `);
  console.log(`Sampled ${sample.length} upcoming visits with Jobber GIDs.`);

  const drift = [];
  const notVisit = [];
  const inverted = [];
  let scanned = 0;
  for (const r of sample) {
    scanned++;
    const vRes = await gql(`
      query($id: EncodedId!) { visit(id: $id) { id startAt completedAt visitStatus } }
    `, { id: r.jobber_gid });
    if (vRes.errors?.some(e => /NOT_FOUND|does not exist|null/i.test(e.message || ''))) {
      notVisit.push({ ...r, jobber_status: 'NOT_FOUND_AS_VISIT' });
      continue;
    }
    if (!vRes.data?.visit) {
      notVisit.push({ ...r, jobber_status: 'NULL_VISIT' });
      continue;
    }
    const j = vRes.data.visit;
    const jDate = j.startAt ? j.startAt.slice(0, 10) : null;
    if (jDate && jDate !== r.visit_date) {
      drift.push({ ...r, jobber_startAt: j.startAt, jobber_completedAt: j.completedAt, jobber_date: jDate });
    }
    if (j.completedAt && j.startAt && j.completedAt.slice(0, 10) < j.startAt.slice(0, 10)) {
      inverted.push({ ...r, jobber_startAt: j.startAt, jobber_completedAt: j.completedAt });
    }
  }
  console.log(`Scanned ${scanned} visits.\n`);
  console.log(`  Date drift (DB.visit_date != Jobber.startAt::date): ${drift.length}`);
  for (const d of drift) {
    console.log(`    ${d.client_code} ${d.client_name}: DB=${d.visit_date} JOBBER=${d.jobber_date} (id=${d.id} gid=${d.jobber_gid})`);
  }
  console.log(`\n  Not-a-Visit-in-Jobber-anymore: ${notVisit.length}`);
  for (const n of notVisit) {
    console.log(`    ${n.client_code} ${n.client_name}: DB=${n.visit_date} status=${n.jobber_status} (id=${n.id} gid=${n.jobber_gid})`);
  }
  console.log(`\n  Inverted timeline in Jobber (completedAt < startAt): ${inverted.length}`);
  for (const i of inverted) {
    console.log(`    ${i.client_code} ${i.client_name}: scheduled=${i.jobber_startAt} completed=${i.jobber_completedAt} (id=${i.id})`);
  }

  console.log('\n=== Done — read-only probe, no writes ===');
}

main().catch(e => { console.error(e); process.exit(1); });
