// Quick diff of Jobber's current client list vs our DB.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

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
    hostname: 'api.supabase.com', path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) throw new Error(r.body.slice(0, 200));
  return JSON.parse(r.body);
}

async function gql(query, variables, retries = 5) {
  const body = JSON.stringify({ query, variables });
  const r = await http({
    hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: { Authorization: `Bearer ${process.env.JOBBER_ACCESS_TOKEN}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-13', 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) {
    if (retries > 0) { await new Promise(rs => setTimeout(rs, 4000)); return gql(query, variables, retries - 1); }
    throw new Error(r.body);
  }
  const j = JSON.parse(r.body);
  if (j.errors) {
    if (j.errors.some(e => e.extensions?.code === 'THROTTLED') && retries > 0) {
      await new Promise(rs => setTimeout(rs, 5000)); return gql(query, variables, retries - 1);
    }
    throw new Error(JSON.stringify(j.errors));
  }
  return j.data;
}

(async () => {
  const all = new Set();
  let cur = null;
  while (true) {
    const d = await gql(`query($a:String){clients(after:$a,first:100){pageInfo{hasNextPage endCursor} nodes{id}}}`, { a: cur });
    for (const c of d.clients.nodes) all.add(c.id);
    if (!d.clients.pageInfo.hasNextPage) break;
    cur = d.clients.pageInfo.endCursor;
  }
  console.log(`Jobber: ${all.size} clients`);

  const dbTotal = (await pg('SELECT COUNT(*)::int AS n FROM clients'))[0].n;
  console.log(`DB total: ${dbTotal}`);

  const ourLinks = await pg(`
    SELECT esl.source_id, c.id, c.client_code, c.name, c.status,
      (SELECT COUNT(*) FROM visits WHERE client_id=c.id) AS visits,
      (SELECT COUNT(*) FROM derm_manifests WHERE client_id=c.id) AS derm,
      (SELECT COUNT(*) FROM invoices WHERE client_id=c.id) AS invoices
    FROM entity_source_links esl JOIN clients c ON c.id=esl.entity_id
    WHERE esl.entity_type='client' AND esl.source_system='jobber';
  `);

  const inDbNotInJobber = ourLinks.filter(r => !all.has(r.source_id));
  console.log(`\nIn DB but NOT in current Jobber: ${inDbNotInJobber.length}`);
  console.table(inDbNotInJobber.map(r => ({
    id: r.id, code: r.client_code, name: (r.name || '').slice(0, 30),
    status: r.status, visits: r.visits, derm: r.derm, invoices: r.invoices,
  })));

  const ourLinked = new Set(ourLinks.map(r => r.source_id));
  const inJobberNotInDb = [...all].filter(g => !ourLinked.has(g));
  console.log(`\nIn Jobber but NOT in DB: ${inJobberNotInDb.length}`);
  for (const g of inJobberNotInDb) console.log(`  ${g}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
