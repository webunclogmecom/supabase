// probe_112ya_service_agreement_v7.js
// Fred stores frequency as a Job CUSTOM FIELD. Introspect the custom-field union
// + read #11100534's customFields typenames so we can pull the value.
const https = require('https');
const fs = require('fs');
const path = require('path');
const { getValidToken } = require('../sync/jobber_token');

const SA_GID = 'Z2lkOi8vSm9iYmVyL0pvYi8xNDY2NTAxNDI='; // #11100534

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
  // try common union names
  let union = null, unionName = null;
  for (const nm of ['CustomFieldUnion', 'CustomField', 'CustomFieldValueUnion']) {
    const r = await gqlRetry(token, `{ __type(name:"${nm}") { name kind possibleTypes { name fields { name type { name kind ofType { name kind } } } } } }`, 'introspect ' + nm);
    if (r.data && r.data.__type) { union = r; unionName = nm; break; }
    await sleep(1200);
  }
  await sleep(1500);
  const job = await gqlRetry(token, `{ job(id:"${SA_GID}") { jobNumber customFields { __typename } } }`, 'job customFields typenames');

  fs.writeFileSync(path.resolve(__dirname, '../../docs/audits/2026-06-03/112ya_jobber_probe_v7.json'), JSON.stringify({ probed_at: new Date().toISOString(), unionName, union, job }, null, 2));

  console.log('union resolved as: ' + unionName);
  const pts = union && union.data && union.data.__type && union.data.__type.possibleTypes || [];
  pts.forEach(t => console.log('  type ' + t.name + ' fields: ' + (t.fields || []).map(f => f.name).join(', ')));
  console.log('jobErr ' + (job.errors ? JSON.stringify(job.errors).slice(0, 250) : 'none'));
  const cf = job && job.data && job.data.job && job.data.job.customFields || [];
  console.log('#11100534 customFields typenames: ' + JSON.stringify(cf));
})().catch(e => { console.error('FATAL ' + e.message); process.exit(1); });
