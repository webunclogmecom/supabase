// For each near-visit note in our DB, query Jobber's API and see if it has
// fileAttachments we missed during migration.
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
      const wait = (6 - retries) * 4000;
      await new Promise(rs => setTimeout(rs, wait));
      return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber ${r.status}: ${r.body.slice(0,200)}`);
  }
  const json = JSON.parse(r.body);
  if (json.errors) {
    const isThrottle = json.errors.some(e => e.extensions?.code === 'THROTTLED');
    if (isThrottle && retries > 0) {
      const wait = (6 - retries) * 5000;
      await new Promise(rs => setTimeout(rs, wait));
      return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber GQL: ${JSON.stringify(json.errors).slice(0,200)}`);
  }
  // Soft pause if remaining budget low
  const remaining = json.extensions?.cost?.throttleStatus?.currentlyAvailable;
  if (remaining != null && remaining < 2000) {
    await new Promise(rs => setTimeout(rs, Math.ceil((2000 - remaining) / 500) * 1000));
  }
  return json.data;
}

(async () => {
  // The notes Fred said have pictures
  const targetVisits = [1783, 1596, 1597, 1770, 1771, 1743, 1730, 1731, 1716, 1605];

  for (const visitId of targetVisits) {
    const [v] = await pg(`SELECT v.id, v.visit_date::text AS date, v.client_id, c.client_code,
        (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=v.client_id AND source_system='jobber' LIMIT 1) AS client_gid
      FROM visits v JOIN clients c ON c.id=v.client_id WHERE v.id=${visitId}`);
    if (!v) { console.log(`visit ${visitId}: NOT FOUND`); continue; }
    if (!v.client_gid) { console.log(`visit ${visitId} (${v.client_code}): client has no Jobber GID`); continue; }

    console.log(`\n=== visit ${visitId} (${v.client_code}, ${v.date}) — pulling ALL client notes from Jobber ===`);
    let allNotes = [];
    let cursor = null, page = 0;
    try {
      do {
        const data = await gql(`
          query ClientNotes($id: EncodedId!, $after: String) {
            client(id: $id) {
              notes(first: 25, after: $after) {
                nodes {
                  id createdAt message
                  createdBy { __typename ... on User { id name { full } } }
                  fileAttachments { nodes { id fileName contentType fileSize url } }
                }
                pageInfo { hasNextPage endCursor }
              }
            }
          }
        `, { id: v.client_gid, after: cursor });
        const cn = data.client?.notes;
        if (!cn) break;
        allNotes.push(...cn.nodes);
        cursor = cn.pageInfo.hasNextPage ? cn.pageInfo.endCursor : null;
        page++;
      } while (cursor && page < 20);
    } catch (e) {
      console.log(`  ERR pulling notes: ${e.message.slice(0,120)}`);
      continue;
    }

    // Filter to ±5 days of visit
    const visitDate = new Date(v.date + 'T00:00:00Z');
    const nearby = allNotes.filter(n => {
      const nd = new Date(n.createdAt);
      const delta = Math.abs((nd - visitDate) / (1000*60*60*24));
      return delta <= 5;
    });
    console.log(`  ${allNotes.length} total client notes, ${nearby.length} within ±5d`);
    for (const n of nearby) {
      const author = n.createdBy?.name?.full || '?';
      const atts = n.fileAttachments?.nodes || [];
      const photoFlag = atts.length > 0 ? `📸 ${atts.length} attachment(s)` : '(no attachments)';
      console.log(`  ${n.id.slice(-15)}  ${n.createdAt.slice(0,16)}  ${author.padEnd(20)}  ${photoFlag}  ${atts.map(a => a.fileName).join(', ').slice(0, 60)}`);
    }
    await new Promise(r => setTimeout(r, 300));
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
