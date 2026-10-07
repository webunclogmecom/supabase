// apply.js — make the Railway services match services.json (the versioned source of truth).
//   node services/timed-jobs/apply.js            show differences only
//   node services/timed-jobs/apply.js --apply    write them
// Why not railway.json / .railway/railway.ts: Railway deprecated railway.json (unread after 2026-12-01, refused
// for new services) and its replacement cannot express cronSchedule, watchPatterns or restartPolicyType yet
// (2026-10-07). Uses the Railway CLI's own login (~/.railway/config.json); prints no secret. Creates no service
// and touches no variable: add a service with `railway add`, set its secrets in the dashboard.
const fs = require('fs'), os = require('os'), path = require('path');
const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, 'services.json'), 'utf8'));
const cli = JSON.parse(fs.readFileSync(path.join(os.homedir(), '.railway', 'config.json'), 'utf8'));
const token = cli.user?.accessToken || cli.user?.token;
if (!token) throw new Error('not logged in: run `railway login`');
const gql = async (query, variables) => {
  const r = await fetch('https://backboard.railway.com/graphql/v2', { method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token }, body: JSON.stringify({ query, variables }) });
  const j = await r.json(); if (j.errors) throw new Error(JSON.stringify(j.errors)); return j.data;
};
(async () => {
  const p = (await gql(`query($id:String!){project(id:$id){environments{edges{node{id name}}} services{edges{node{id name}}}}}`,
    { id: cfg.projectId })).project;
  const env = p.environments.edges.map(e => e.node).find(e => e.name === cfg.environment);
  const byName = Object.fromEntries(p.services.edges.map(e => [e.node.name, e.node.id]));
  let drift = 0;
  for (const [name, want] of Object.entries(cfg.services)) {
    if (!byName[name]) { console.log(`${name}: MISSING in Railway (create it with railway add)`); drift++; continue; }
    const have = (await gql(`query($s:String!,$e:String!){serviceInstance(serviceId:$s,environmentId:$e){${Object.keys(want).join(' ')}}}`,
      { s: byName[name], e: env.id })).serviceInstance;
    const diff = Object.keys(want).filter(k => JSON.stringify(have[k]) !== JSON.stringify(want[k]));
    if (!diff.length) { console.log(`${name}: in sync`); continue; }
    drift++;
    for (const k of diff) console.log(`${name}.${k}: ${JSON.stringify(have[k])} -> ${JSON.stringify(want[k])}`);
    if (process.argv.includes('--apply')) {
      await gql(`mutation($s:String!,$e:String!,$i:ServiceInstanceUpdateInput!){serviceInstanceUpdate(serviceId:$s,environmentId:$e,input:$i)}`,
        { s: byName[name], e: env.id, i: Object.fromEntries(diff.map(k => [k, want[k]])) });
      console.log(`${name}: applied`);
    }
  }
  for (const name of Object.keys(byName)) if (!cfg.services[name]) console.log(`${name}: in Railway but not in services.json`);
  process.exitCode = drift && !process.argv.includes('--apply') ? 1 : 0;
})().catch(e => { console.error(e.message); process.exit(2); });
