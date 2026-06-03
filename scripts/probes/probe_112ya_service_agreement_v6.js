// probe_112ya_service_agreement_v6.js
// Confirm Jobber deep-link URLs: job.jobberWebUri (SA job) + visit.jobberWebUri.
const https = require('https');
const fs = require('fs');
const path = require('path');
const { getValidToken } = require('../sync/jobber_token');

const SA_GID = 'Z2lkOi8vSm9iYmVyL0pvYi8xNDY2NTAxNDI=';        // #11100534 SA-Pumping
const VISIT_JOB_GID = 'Z2lkOi8vSm9iYmVyL0pvYi8xMjkzNTMwNjE='; // #10000178 (has 2 visits)
const CLIENT_GID = 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ='; // 112-YA

function gql(token, query) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query });
    const req = https.request({
      hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
      headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d = ''; r.on('data', c => d += c); r.on('end', () => { try { resolve(JSON.parse(d)); } catch (e) { reject(new Error('parse ' + r.statusCode + ': ' + d.slice(0, 300))); } }); });
    req.on('error', reject); req.setTimeout(30000, () => req.destroy(new Error('timeout')));
    req.write(body); req.end();
  });
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function gqlRetry(token, q, label) {
  for (let attempt = 1; attempt <= 6; attempt++) {
    const r = await gql(token, q);
    if (r.errors && r.errors[0] && r.errors[0].extensions && r.errors[0].extensions.code === 'THROTTLED') { const w = 3 * attempt; console.log(`throttled ${label} ${attempt}, sleep ${w}s`); await sleep(w * 1000); continue; }
    return r;
  }
  return { errors: [{ message: 'still throttled' }] };
}

(async () => {
  const token = await getValidToken();
  const a = await gqlRetry(token, `{ job(id:"${SA_GID}") { jobNumber jobberWebUri } client(id:"${CLIENT_GID}") { jobberWebUri } }`, 'jobUri');
  await sleep(2500);
  const b = await gqlRetry(token, `{ job(id:"${VISIT_JOB_GID}") { jobNumber jobberWebUri visits(first:2) { nodes { id startAt jobberWebUri } } } }`, 'visitUri');

  fs.writeFileSync(path.resolve(__dirname, '../../docs/audits/2026-06-03/112ya_jobber_probe_v6.json'), JSON.stringify({ probed_at: new Date().toISOString(), a, b }, null, 2));
  console.log('clientErr ' + (a.errors ? JSON.stringify(a.errors).slice(0, 200) : 'none'));
  if (a.data) {
    console.log('client.jobberWebUri = ' + (a.data.client && a.data.client.jobberWebUri));
    console.log('SA job.jobberWebUri = ' + (a.data.job && a.data.job.jobberWebUri));
  }
  console.log('visitErr ' + (b.errors ? JSON.stringify(b.errors).slice(0, 200) : 'none'));
  if (b.data && b.data.job) {
    console.log('job.jobberWebUri = ' + b.data.job.jobberWebUri);
    (b.data.job.visits && b.data.job.visits.nodes || []).forEach(v => console.log('  visit ' + (v.startAt || '').slice(0, 10) + ' -> ' + v.jobberWebUri + '  (gid ' + v.id + ')'));
  }
})().catch(e => { console.error('FATAL ' + e.message); process.exit(1); });
