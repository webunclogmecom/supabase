// Pull Jobber's full state for the 2 drift cases (1794, 1795)
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}` };

async function r(p) {
  const x = await fetch(`${URL}/rest/v1${p}`, { headers: H });
  return x.json();
}

(async () => {
  const tk = (await r('/webhook_tokens?source_system=eq.jobber&select=access_token'))[0].access_token;
  const gids = [
    { id: 1794, gid: 'Z2lkOi8vSm9iYmVyL1Zpc2l0LzIxNDk1MTMzOTU=' },
    { id: 1795, gid: 'Z2lkOi8vSm9iYmVyL1Zpc2l0LzIxNTAyMjA2MTM=' },
  ];
  for (const { id, gid } of gids) {
    const res = await fetch('https://api.getjobber.com/api/graphql', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${tk}`,
        'Content-Type': 'application/json',
        'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
      },
      body: JSON.stringify({
        query: `query($id: EncodedId!) {
          visit(id: $id) {
            id title startAt endAt completedAt completedBy visitStatus
            client { id name }
            job { id title }
          }
        }`,
        variables: { id: gid },
      }),
    });
    const j = await res.json();
    console.log(`\nDB id=${id} gid=${gid}:`);
    console.log(JSON.stringify(j.data?.visit || j.errors, null, 2));
  }
})();
