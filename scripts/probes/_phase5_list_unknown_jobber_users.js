// Find every distinct Jobber user GID that appears on a completed visit's
// assignedUsers list but ISN'T in our public.entity_source_links employees
// table. Fetch their names so we can decide whether to seed them.

const path = require('path');
const https = require('https');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const SB_URL = process.env.SUPABASE_URL, KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = process.env.SUPABASE_PROJECT_ID, PAT = process.env.SUPABASE_PAT;

function req({ host, path, method = 'GET', headers = {}, body = null }) {
  return new Promise((resolve, reject) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const r = https.request({ hostname: host, path, method, headers: { ...headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) } }, (res) => {
      let d = ''; res.on('data', c => (d += c));
      res.on('end', () => resolve({ status: res.statusCode, body: d }));
    });
    r.on('error', reject);
    r.setTimeout(60_000, () => r.destroy(new Error('timeout')));
    if (payload) r.write(payload);
    r.end();
  });
}
async function rest(p) {
  const u = new URL(SB_URL + '/rest/v1' + p);
  const r = await req({ host: u.hostname, path: u.pathname + u.search, headers: { apikey: KEY, Authorization: 'Bearer ' + KEY } });
  return JSON.parse(r.body);
}
async function pg(q) {
  const r = await req({ host: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json' }, body: JSON.stringify({ query: q }) });
  return JSON.parse(r.body);
}
let TOKEN = null;
async function getTk() {
  TOKEN = (await rest('/webhook_tokens?source_system=eq.jobber&select=access_token'))[0].access_token;
}

async function gqlVisit(gid) {
  const r = await req({ host: 'api.getjobber.com', path: '/api/graphql', method: 'POST', headers: { Authorization: 'Bearer ' + TOKEN, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' }, body: JSON.stringify({ query: 'query($id: EncodedId!) { visit(id: $id) { assignedUsers { nodes { id name { full } } } } }', variables: { id: gid } }) });
  return JSON.parse(r.body);
}

(async () => {
  await getTk();

  // 1. Get DB employee GIDs (known)
  const known = await pg(`SELECT source_id FROM public.entity_source_links WHERE entity_type='employee' AND source_system='jobber';`);
  const knownSet = new Set(known.map(r => r.source_id));
  console.log(`Known employee GIDs in DB: ${knownSet.size}`);

  // 2. Get all completed Jobber-linked visits
  const visits = await pg(`
    SELECT v.id, esl.source_id AS gid
    FROM public.visits v
    JOIN public.entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
    WHERE v.visit_status='completed'
    ORDER BY v.visit_date DESC;
  `);
  console.log(`Scanning ${visits.length} completed Jobber-linked visits…\n`);

  const unknownGids = new Map(); // gid → {name, occurrences}
  for (let i = 0; i < visits.length; i++) {
    if (i % 100 === 0) console.log(`  ${i}/${visits.length} — distinct unknown so far: ${unknownGids.size}`);
    const j = await gqlVisit(visits[i].gid);
    const nodes = j.data?.visit?.assignedUsers?.nodes || [];
    for (const n of nodes) {
      if (!knownSet.has(n.id)) {
        const cur = unknownGids.get(n.id) || { name: n.name?.full || '?', occurrences: 0 };
        cur.occurrences++;
        unknownGids.set(n.id, cur);
      }
    }
    await new Promise(r => setTimeout(r, 80));
  }

  console.log(`\n=== Distinct unknown Jobber users: ${unknownGids.size} ===`);
  const sorted = [...unknownGids.entries()].sort((a, b) => b[1].occurrences - a[1].occurrences);
  for (const [gid, info] of sorted) {
    console.log(`  ${info.name.padEnd(30)}  ${info.occurrences} visits  gid=${gid}`);
  }
})().catch(e => { console.error(e); process.exit(1); });
