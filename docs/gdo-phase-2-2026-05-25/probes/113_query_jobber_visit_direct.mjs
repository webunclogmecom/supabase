// 113_query_jobber_visit_direct.mjs
// Query Jobber GraphQL directly for the current state of the Kendall visit.
// Bypasses the cron + webhook (both are blind to un-completion in different
// ways). Uses the live access token from public.webhook_tokens.
import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${(await r.text()).slice(0, 600)}`);
  return JSON.parse(await r.text());
}

const VISIT_GID = 'Z2lkOi8vSm9iYmVyL1Zpc2l0LzIxODI3NTM0Mzk=';

// Pull the current Jobber access token from the DB
const tok = await pg(`
  SELECT access_token, expires_at
  FROM public.webhook_tokens WHERE source_system='jobber' LIMIT 1;
`);
console.log('Token loaded; expires at:', tok[0]?.expires_at);

const r = await fetch('https://api.getjobber.com/api/graphql', {
  method: 'POST',
  headers: {
    Authorization: `Bearer ${tok[0].access_token}`,
    'Content-Type': 'application/json',
    'X-JOBBER-GRAPHQL-VERSION': '2023-08-18',
  },
  body: JSON.stringify({
    query: `query VisitState($id: EncodedId!) {
      visit(id: $id) {
        id
        title
        startAt
        endAt
        completedAt
        completedBy
        visitStatus
        client { id name }
        job { id jobNumber }
      }
    }`,
    variables: { id: VISIT_GID },
  }),
});
const j = await r.json();
console.log('Jobber response status:', r.status);
console.log(JSON.stringify(j, null, 2));
