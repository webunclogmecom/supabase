// Find every Jobber Task linked to 009-CN's Jobber client, and inspect the
// task schema. Also dump every Visit Jobber currently has for this client
// so we can compare to our DB.

const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}` };

async function getJobberToken() {
  const r = await fetch(`${URL}/rest/v1/webhook_tokens?source_system=eq.jobber&select=access_token`, { headers: H });
  return (await r.json())[0]?.access_token;
}

async function gql(token, query, variables = {}) {
  const r = await fetch('https://api.getjobber.com/api/graphql', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
    },
    body: JSON.stringify({ query, variables }),
  });
  const j = await r.json();
  return { status: r.status, data: j.data, errors: j.errors };
}

(async () => {
  const token = await getJobberToken();
  if (!token) throw new Error('no token');

  // First — what fields does Task type have?
  const introspect = await gql(token, `
    query {
      __type(name: "Task") {
        name
        fields { name type { name kind } }
      }
    }
  `);
  console.log('=== Jobber Task type schema =====================================');
  console.log(JSON.stringify(introspect.data?.__type?.fields?.map(f => `${f.name}: ${f.type.name || f.type.kind}`), null, 2));

  // 009-CN Jobber client GID: we know from earlier audit it's Z2lkOi8vSm9iYmVyL0NsaWVudC85NjE1NTY3Mw==
  const CLIENT_GID = 'Z2lkOi8vSm9iYmVyL0NsaWVudC85NjE1NTY3Mw==';
  console.log('\nUsing client GID:', CLIENT_GID, '(009-CN Casa Neos)');

  // Introspect TaskFilterAttributes
  const taskFilter = await gql(token, `
    query { __type(name: "TaskFilterAttributes") { name inputFields { name type { name kind ofType { name } } } } }
  `);
  console.log('\nTaskFilterAttributes:', JSON.stringify(taskFilter.data?.__type?.inputFields, null, 2));

  // Fetch all tasks with title + startAt + client filter applied in JS
  console.log('\n=== Pull every Jobber task (paged), then JS-filter for 009-CN ===');
  let cursor = null, all = [];
  for (let page = 0; page < 30; page++) {
    const tasksPage = await gql(token, `
      query($after: String) {
        tasks(first: 50, after: $after) {
          nodes { id title startAt endAt isComplete client { id name } }
          pageInfo { hasNextPage endCursor }
          totalCount
        }
      }
    `, { after: cursor });
    if (tasksPage.errors) { console.log('errs:', JSON.stringify(tasksPage.errors).slice(0,300)); break; }
    const nodes = tasksPage.data?.tasks?.nodes || [];
    all.push(...nodes);
    if (!tasksPage.data.tasks.pageInfo.hasNextPage) break;
    cursor = tasksPage.data.tasks.pageInfo.endCursor;
  }
  console.log(`Pulled ${all.length} tasks total.`);
  const matching = all.filter(t => t.client?.id === CLIENT_GID);
  console.log(`Tasks for 009-CN (${matching.length}):`);
  for (const t of matching) {
    console.log(`  ${t.id} | "${t.title}" | startAt=${t.startAt || 'NULL'} | endAt=${t.endAt || 'NULL'} | complete=${t.isComplete}`);
  }
  const july4 = matching.filter(t => (t.startAt || '').startsWith('2026-07-04'));
  console.log(`\n→ Tasks on 2026-07-04 for 009-CN: ${july4.length}`);
  for (const t of july4) console.log(`    ${t.id} | "${t.title}" | startAt=${t.startAt}`);

  // Also lookup Task/2192152063 specifically (same numeric ID as the Visit)
  console.log('\n=== Lookup Task/2192152063 (same number as the July 4 Visit) ===');
  const taskByNum = await gql(token, `
    query {
      task(id: "Z2lkOi8vSm9iYmVyL1Rhc2svMjE5MjE1MjA2Mw==") {
        id title startAt endAt isComplete instructions client { id }
      }
    }
  `);
  console.log(JSON.stringify(taskByNum.errors || taskByNum.data, null, 2));

  console.log('\n=== Try `client.tasks` -- ask client for its tasks ==============');
  const clientTasks = await gql(token, `
    query($id: EncodedId!) {
      client(id: $id) {
        id name
        ... on Client {
          jobs(first: 5) {
            nodes {
              id title
            }
          }
        }
      }
    }
  `, { id: CLIENT_GID });
  console.log(JSON.stringify(clientTasks.data || clientTasks.errors, null, 2));

  // Pull all visits Jobber has for 009-CN in 2026 to compare to our DB
  console.log('\n=== All Jobber visits for 009-CN, July 2026 window =============');
  const visits = await gql(token, `
    query($clientId: EncodedId!) {
      visits(
        filter: { clientId: $clientId, startAt: { after: "2026-06-15T00:00:00Z", before: "2026-08-01T00:00:00Z" } }
        first: 50
      ) {
        nodes {
          id title startAt endAt completedAt visitStatus
          job { id title }
        }
        totalCount
      }
    }
  `, { clientId: CLIENT_GID });
  console.log(JSON.stringify(visits.data || visits.errors, null, 2));
})().catch(e => { console.error(e); process.exit(1); });
