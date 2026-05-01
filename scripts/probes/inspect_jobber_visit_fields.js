// Look at one Jobber visit's schema in detail. Find the field that
// distinguishes "assigned driver" from "person who clicked completed".
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

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

async function gql(query, variables) {
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
  if (r.status >= 300) throw new Error(`Jobber ${r.status}: ${r.body.slice(0,300)}`);
  const json = JSON.parse(r.body);
  return json;
}

(async () => {
  console.log('=== Step 1: Introspect Visit type — what fields exist? ===\n');
  const introspection = await gql(`
    query VisitType {
      __type(name: "Visit") {
        name
        fields {
          name
          type { name kind ofType { name kind } }
        }
      }
    }
  `);
  const fields = introspection.data?.__type?.fields || [];
  console.log(`Found ${fields.length} fields on Visit type:\n`);
  for (const f of fields) {
    const typeName = f.type.name || f.type.ofType?.name || `${f.type.kind}<${f.type.ofType?.name}>`;
    console.log(`  ${f.name.padEnd(28)} ${typeName}`);
  }

  console.log('\n=== Step 2: Pull a real recent visit and see actual field values ===\n');
  // Visit 1454 (009-CN, 2026-03-07) — completed visit with no driver per earlier audit
  const sampleGid = 'Z2lkOi8vSm9iYmVyL1Zpc2l0LzIwNzE1MTMyNjU=';
  const data = await gql(`
    query VisitDetail($id: EncodedId!) {
      visit(id: $id) {
        id title visitStatus startAt endAt completedAt
        assignedUsers { nodes { id name { full } } }
        instructions
        client { id name }
        job { id }
      }
    }
  `, { id: sampleGid });

  console.log('Visit 1454 detail:');
  console.log(JSON.stringify(data, null, 2).slice(0, 2000));

  // Try to query for completedBy specifically
  console.log('\n=== Step 3: Try common completion-tracker field names ===\n');
  const candidates = ['completedBy', 'completedByUser', 'lastUpdatedBy', 'updatedByUser', 'finalizedBy'];
  for (const fname of candidates) {
    try {
      const r = await gql(`
        query Try($id: EncodedId!) {
          visit(id: $id) { id ${fname} { id name { full } } }
        }
      `, { id: sampleGid });
      if (r.errors) {
        console.log(`  ${fname}: ✗ ${r.errors[0]?.message?.slice(0,80) || 'error'}`);
      } else {
        console.log(`  ${fname}: ✓ ${JSON.stringify(r.data?.visit?.[fname])}`);
      }
    } catch (e) {
      console.log(`  ${fname}: ✗ ${e.message.slice(0,60)}`);
    }
  }

  // Also try visit status events / activity timeline
  console.log('\n=== Step 4: Try activity / events timeline ===\n');
  for (const fname of ['events', 'activityFeed', 'history', 'auditLog']) {
    try {
      const r = await gql(`
        query Try($id: EncodedId!) {
          visit(id: $id) { id ${fname} { nodes { __typename } } }
        }
      `, { id: sampleGid });
      if (r.errors) {
        console.log(`  ${fname}: ✗ ${r.errors[0]?.message?.slice(0,80)}`);
      } else {
        console.log(`  ${fname}: ✓ ${JSON.stringify(r.data?.visit?.[fname]).slice(0,150)}`);
      }
    } catch (e) {
      console.log(`  ${fname}: ✗ ${e.message.slice(0,60)}`);
    }
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
