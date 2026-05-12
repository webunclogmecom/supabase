// For the remaining gidless orphans (have DERM data, no Jobber sibling by code),
// search Jobber's full client list (live re-pull) by name to find their GIDs.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const JOBBER_TOKEN = process.env.JOBBER_ACCESS_TOKEN;
const JOBBER_API_VERSION = '2026-04-13';

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d }));
    });
    req.on('error', rej);
    if (body) req.write(body);
    req.end();
  });
}

async function pg(sql) {
  const body = JSON.stringify({ query: sql });
  const r = await http({
    hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) throw new Error(`DB ${r.status}: ${r.body.slice(0,200)}`);
  return JSON.parse(r.body);
}

async function gql(query, variables, retries = 5) {
  const body = JSON.stringify({ query, variables });
  const r = await http({
    hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: { Authorization: `Bearer ${JOBBER_TOKEN}`, 'X-JOBBER-GRAPHQL-VERSION': JOBBER_API_VERSION, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) {
    if (retries > 0) { await new Promise(rs => setTimeout(rs, 4000)); return gql(query, variables, retries - 1); }
    throw new Error(`Jobber ${r.status}: ${r.body.slice(0,200)}`);
  }
  const json = JSON.parse(r.body);
  if (json.errors) {
    if (json.errors.some(e => e.extensions?.code === 'THROTTLED') && retries > 0) {
      await new Promise(rs => setTimeout(rs, 5000)); return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber GQL: ${JSON.stringify(json.errors).slice(0,300)}`);
  }
  return json.data;
}

const norm = s => (s || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

(async () => {
  console.log('=== Pull all Jobber clients fresh ===');
  const jc = [];
  let cursor = null;
  while (true) {
    const d = await gql(`
      query AllClients($after: String) {
        clients(after: $after, first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes { id companyName firstName lastName isCompany isArchived }
        }
      }
    `, { after: cursor });
    jc.push(...d.clients.nodes);
    if (!d.clients.pageInfo.hasNextPage) break;
    cursor = d.clients.pageInfo.endCursor;
  }
  console.log(`  ${jc.length} Jobber clients\n`);

  // Index by normalized name
  const jcByNorm = new Map();
  for (const c of jc) {
    const name = c.isCompany ? c.companyName : `${c.firstName || ''} ${c.lastName || ''}`.trim();
    const key = norm(name);
    if (!jcByNorm.has(key)) jcByNorm.set(key, []);
    jcByNorm.get(key).push({ ...c, _name: name });
  }

  // Fuzzy: also check substring
  const orphans = await pg(`
    SELECT c.id, c.client_code, c.name FROM clients c
    WHERE NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='jobber');
  `);
  console.log(`Remaining gidless DB clients: ${orphans.length}\n`);

  for (const o of orphans) {
    const ourNorm = norm(o.name);
    const ourTokens = ourNorm.split(' ').filter(t => t.length > 2);

    console.log(`\n[${o.id}] code=${o.client_code} name="${o.name}"`);
    console.log(`  Searching Jobber for any client containing any of: ${ourTokens.join(', ')}`);

    const matches = [];
    for (const c of jc) {
      const fullName = `${c.companyName || ''} ${c.firstName || ''} ${c.lastName || ''}`.trim();
      const candidateNorm = norm(fullName);
      if (!candidateNorm) continue;
      const candidateTokens = candidateNorm.split(' ').filter(t => t.length > 2);
      const hits = ourTokens.filter(t => candidateTokens.includes(t));
      if (hits.length === 0) continue;
      matches.push({ score: hits.length, fullName, id: c.id, archived: c.isArchived, hits: hits.join(',') });
    }
    matches.sort((a, b) => b.score - a.score);
    if (matches.length) {
      console.log(`  Top matches (${matches.length} total):`);
      for (const m of matches.slice(0, 5)) {
        console.log(`    score=${m.score} archived=${m.archived ? 'Y' : 'N'} "${m.fullName}" (${m.id})`);
      }
    } else {
      console.log(`  ✗ NO Jobber client contains any of those tokens`);
    }
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
