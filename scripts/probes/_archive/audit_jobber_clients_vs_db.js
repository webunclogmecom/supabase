// Audit: which Jobber clients are missing from our DB? Which DB clients are
// not in Jobber (orphans / Airtable-only)?
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
    req.setTimeout(30000, () => req.destroy(new Error('timeout')));
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
    headers: {
      Authorization: `Bearer ${JOBBER_TOKEN}`,
      'X-JOBBER-GRAPHQL-VERSION': JOBBER_API_VERSION,
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    },
  }, body);
  if (r.status >= 300) {
    if (retries > 0 && (r.status === 429 || r.status >= 500)) {
      await new Promise(rs => setTimeout(rs, (6 - retries) * 4000));
      return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber ${r.status}: ${r.body.slice(0,200)}`);
  }
  const json = JSON.parse(r.body);
  if (json.errors) {
    if (json.errors.some(e => e.extensions?.code === 'THROTTLED') && retries > 0) {
      await new Promise(rs => setTimeout(rs, (6 - retries) * 5000));
      return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber GQL: ${JSON.stringify(json.errors).slice(0,300)}`);
  }
  const remaining = json.extensions?.cost?.throttleStatus?.currentlyAvailable;
  if (remaining != null && remaining < 2000) {
    await new Promise(rs => setTimeout(rs, Math.ceil((2000 - remaining) / 500) * 1000));
  }
  return json.data;
}

(async () => {
  console.log('=== Phase 1: pulling all Jobber clients ===');
  const all = [];
  let cursor = null, page = 0;
  while (true) {
    page++;
    const d = await gql(`
      query AllClients($after: String) {
        clients(after: $after, first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id companyName firstName lastName isCompany isArchived
            createdAt updatedAt
          }
        }
      }
    `, { after: cursor });
    const conn = d.clients;
    if (!conn) break;
    all.push(...conn.nodes);
    if (page % 5 === 0) console.log(`  page ${page}: ${all.length} clients`);
    if (!conn.pageInfo.hasNextPage) break;
    cursor = conn.pageInfo.endCursor;
  }
  console.log(`  ✓ ${all.length} total Jobber clients`);

  console.log('\n=== Phase 2: pulling our DB clients with Jobber ESL ===');
  const ourDb = await pg(`
    SELECT c.id, c.client_code, c.name, c.status,
      (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='jobber' LIMIT 1) AS jobber_gid,
      (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='airtable' LIMIT 1) AS airtable_id
    FROM clients c
    ORDER BY c.id;
  `);
  console.log(`  ${ourDb.length} clients in our DB`);

  // Index our DB by Jobber GID
  const ourByGid = new Map();
  const ourGidless = [];
  for (const c of ourDb) {
    if (c.jobber_gid) ourByGid.set(c.jobber_gid, c);
    else ourGidless.push(c);
  }

  console.log('\n=== Phase 3: diff ===');

  // Jobber clients missing from our DB
  const missingFromDb = all.filter(jc => !ourByGid.has(jc.id));
  console.log(`\nJobber clients NOT in our DB: ${missingFromDb.length}`);
  if (missingFromDb.length) {
    console.table(missingFromDb.slice(0, 30).map(jc => ({
      jobber_gid: jc.id.slice(0, 24) + '…',
      company_name: jc.companyName?.slice(0, 50) || '',
      first_last: `${jc.firstName || ''} ${jc.lastName || ''}`.trim().slice(0, 40),
      isArchived: jc.isArchived,
      createdAt: jc.createdAt?.slice(0, 10),
      updatedAt: jc.updatedAt?.slice(0, 10),
    })));
    if (missingFromDb.length > 30) console.log(`  ... and ${missingFromDb.length - 30} more`);
  }

  // Our DB clients without Jobber link
  console.log(`\nOur DB clients with NO Jobber GID: ${ourGidless.length}`);
  if (ourGidless.length) {
    console.table(ourGidless.slice(0, 20).map(c => ({
      id: c.id, code: c.client_code, name: c.name?.slice(0, 50), status: c.status,
      airtable_id: c.airtable_id ? c.airtable_id.slice(0, 18) : null,
    })));
    if (ourGidless.length > 20) console.log(`  ... and ${ourGidless.length - 20} more`);
  }

  // Duplicate Jobber GIDs in our DB (shouldn't happen with UNIQUE constraint, but check)
  console.log('\n=== Phase 4: duplicate clients (multiple rows per Jobber GID or per client_code) ===');
  console.table(await pg(`
    SELECT esl.source_id AS jobber_gid, COUNT(*) AS dupes,
      STRING_AGG(c.id::text || '/' || COALESCE(c.client_code,'?'), ', ') AS rows
    FROM entity_source_links esl JOIN clients c ON c.id=esl.entity_id
    WHERE esl.entity_type='client' AND esl.source_system='jobber'
    GROUP BY esl.source_id HAVING COUNT(*) > 1
    LIMIT 10;
  `));

  console.log('\nClients with duplicate client_code:');
  console.table(await pg(`
    SELECT client_code, COUNT(*) AS n,
      STRING_AGG(id::text || ' (' || status || ')', ', ' ORDER BY id) AS ids
    FROM clients WHERE client_code IS NOT NULL
    GROUP BY client_code HAVING COUNT(*) > 1
    ORDER BY client_code;
  `));

  console.log('\n=== Summary ===');
  console.log(`  Jobber total:                    ${all.length}`);
  console.log(`  In our DB with Jobber link:      ${ourByGid.size}`);
  console.log(`  In our DB WITHOUT Jobber link:   ${ourGidless.length}`);
  console.log(`  Missing from our DB (in Jobber): ${missingFromDb.length}`);
  console.log(`  Total in our DB:                 ${ourDb.length}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
