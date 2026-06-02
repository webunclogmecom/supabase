// Hit Jobber GraphQL directly for visit 2160911401 (092-TCE May 4) to see
// whether assignedUsers / completedBy are populated. If yes, our webhook is
// missing them; if no, Jobber API itself lacks the data.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
function pg(sql) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${PROD}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(b)); });
    req.on('error', rej);
    req.write(JSON.stringify({query: sql}));
    req.end();
  });
}

async function jobberGql(token, query, variables) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query, variables });
    const req = https.request({
      hostname: 'api.getjobber.com',
      path: '/api/graphql',
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
        'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
      }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({status: x.statusCode, body: b})); });
    req.on('error', rej);
    req.write(body);
    req.end();
  });
}

(async () => {
  console.log('Fetching Jobber access token from webhook_tokens...');
  const tokens = JSON.parse(await pg("SELECT access_token, expires_at FROM webhook_tokens WHERE source_system='jobber' LIMIT 1;"));
  if (!tokens.length) { console.error('No jobber token'); return; }
  const token = tokens[0].access_token;
  console.log('  token expires:', tokens[0].expires_at);

  // Query for visit 2160911401 with EVERY relevant field
  const query = `
    query($id: EncodedId!) {
      visit(id: $id) {
        id
        title
        startAt
        endAt
        completedAt
        visitStatus
        assignedUsers { nodes { id name { first last } } }
        completedBy
        job { id title }
        client { id }
      }
    }
  `;
  const visitGid = Buffer.from('gid://Jobber/Visit/2160911401').toString('base64');
  console.log('\nQuerying Jobber for visit 2160911401 (gid =', visitGid, ')...');
  const r = await jobberGql(token, query, { id: visitGid });
  console.log('Status:', r.status);
  console.log('Body:', r.body.slice(0, 2000));
})();
