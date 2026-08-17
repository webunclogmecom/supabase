// Sweep Jobber for every visit assigned to Michael Escobar, with backoff.
//
// Why a script rather than ad-hoc curl: nested assignedUsers over a wide date range is
// an expensive Jobber query and repeated attempts got THROTTLED. This pages in small
// chunks, honours the throttle by backing off and retrying rather than failing the run,
// and prints solo-vs-paired because that distinction decides whether Michael should be
// the visit's PRIMARY driver (Fred, 2026-08-17: "there's no need for him to be the
// primary driver of a visit, unless in jobber of those visits it shows only him").
//
// Read-only. Writes nothing. Emits the visit GIDs for a separate backfill step.
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const AFTER = process.argv[2] || '2026-06-01T00:00:00Z';
const BEFORE = process.argv[3] || '2026-08-13T00:00:00Z';
const PAGE = 20;                 // small on purpose; larger pages are what got throttled
const OUT = process.argv[4] || path.join(__dirname, 'michael_sweep.json');

function token() {
  // ⚠ execSync uses cmd.exe on Windows, where "./jobber-token.sh" is not a command
  // ('.' is not recognized...). It must be handed to bash explicitly.
  return execSync('bash ./jobber-token.sh', {
    cwd: 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Slack', encoding: 'utf8',
  }).trim().split(/\r?\n/).filter(Boolean).pop();
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function gql(tok, query, variables) {
  // Retry on THROTTLED with growing backoff. A throttle is not a failure, it is a
  // "come back later", and treating it as fatal is what made the manual attempts useless.
  for (let attempt = 0; attempt < 8; attempt++) {
    const r = await fetch('https://api.getjobber.com/api/graphql', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${tok}`,
        'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ query, variables }),
    });
    const ctype = r.headers.get('content-type') ?? '';
    if (!ctype.includes('json')) {
      // Jobber sheds load with an HTML waiting room at HTTP 200 (see CLAUDE.md).
      console.log(`  non-JSON (${ctype}) at HTTP ${r.status}; backing off`);
      await sleep(30000); continue;
    }
    const j = await r.json();
    const throttled = (j.errors || []).some((e) => e?.extensions?.code === 'THROTTLED');
    if (throttled) {
      const wait = 20000 * (attempt + 1);
      console.log(`  throttled, waiting ${wait / 1000}s`);
      await sleep(wait); continue;
    }
    if (j.errors) throw new Error(JSON.stringify(j.errors).slice(0, 300));
    return j.data;
  }
  throw new Error('still throttled after 8 attempts');
}

const Q = `query($first:Int!,$after:String,$a:ISO8601DateTime!,$b:ISO8601DateTime!){
  visits(first:$first, after:$after, filter:{ startAt:{ after:$a, before:$b } },
         sort:{ key:START_AT, direction:DESCENDING }) {
    pageInfo { hasNextPage endCursor }
    nodes { id startAt visitStatus assignedUsers { nodes { name { full } } } }
  } }`;

(async () => {
  const tok = token();
  let after = null, page = 0, scanned = 0;
  const hits = [];
  console.log(`sweeping ${AFTER.slice(0, 10)} -> ${BEFORE.slice(0, 10)}, ${PAGE}/page`);
  while (page < 40) {
    const d = await gql(tok, Q, { first: PAGE, after, a: AFTER, b: BEFORE });
    const nodes = d.visits.nodes;
    scanned += nodes.length;
    for (const v of nodes) {
      const crew = (v.assignedUsers?.nodes || []).map((u) => u?.name?.full).filter(Boolean);
      if (crew.some((c) => /michael/i.test(c))) {
        hits.push({ gid: v.id, date: (v.startAt || '').slice(0, 10), status: v.visitStatus, crew, solo: crew.length === 1 });
      }
    }
    if (nodes.length) {
      console.log(`  page ${++page}: ${nodes.length} visits (${(nodes[nodes.length - 1].startAt || '').slice(0, 10)}), ${hits.length} hits so far`);
    }
    if (!d.visits.pageInfo.hasNextPage) break;
    after = d.visits.pageInfo.endCursor;
    await sleep(3000);   // stay under the restore rate rather than racing it
  }
  const solo = hits.filter((h) => h.solo);
  console.log(`\nscanned ${scanned} visits`);
  console.log(`with Michael: ${hits.length}`);
  console.log(`SOLO (would need him as PRIMARY): ${solo.length}`);
  hits.forEach((h) => console.log(`   ${h.date} ${h.solo ? 'SOLO ' : '     '} ${h.crew.join(' + ')}  ${h.gid}`));
  fs.writeFileSync(OUT, JSON.stringify({ scanned, hits, solo }, null, 1));
  console.log(`\nwrote ${OUT}`);
})().catch((e) => { console.error('FAILED:', e.message); process.exit(1); });
