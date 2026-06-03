// probe_112ya_service_agreement_v2.js
// (A) Introspect Jobber `VisitSchedule` + `Visit` types -> find frequency/recurrence fields.
// (B) Retry 112-YA jobs query with throttle backoff (v1 got THROTTLED).
const https = require('https');
const fs = require('fs');
const path = require('path');
const { getValidToken } = require('../sync/jobber_token');

const CLIENT_GID = 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ='; // 112-YA Yan's Restaurant

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
  for (let attempt = 1; attempt <= 5; attempt++) {
    const r = await gql(token, q);
    if (r.errors && r.errors[0] && r.errors[0].extensions && r.errors[0].extensions.code === 'THROTTLED') {
      const wait = 3 * attempt; console.log(`throttled ${label} attempt ${attempt}, sleep ${wait}s`); await sleep(wait * 1000); continue;
    }
    return r;
  }
  return { errors: [{ message: 'still throttled after retries' }] };
}
const introQ = name => `{ __type(name: "${name}") { name fields { name description type { name kind ofType { name kind ofType { name kind } } } } } }`;

(async () => {
  const token = await getValidToken();

  const vs = await gqlRetry(token, introQ('VisitSchedule'), 'VisitSchedule');
  await sleep(1500);
  const visit = await gqlRetry(token, introQ('Visit'), 'Visit');
  await sleep(3000);

  const qJobs = `{
    client(id: "${CLIENT_GID}") {
      id name companyName
      jobs(first: 25) {
        totalCount
        nodes {
          id jobNumber jobType jobStatus title total startAt endAt
          lineItems(first: 15) { nodes { name description quantity unitPrice totalPrice } }
        }
      }
    }
  }`;
  const jobs = await gqlRetry(token, qJobs, 'jobs');

  const out = { probed_at: new Date().toISOString(), visit_schedule_introspection: vs, visit_introspection: visit, jobs };
  const outPath = path.resolve(__dirname, '../../docs/audits/2026-06-03/112ya_jobber_probe_v2.json');
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2));
  console.log('WROTE ' + outPath);

  const vsFields = vs && vs.data && vs.data.__type && vs.data.__type.fields || [];
  console.log('VisitSchedule fields: ' + vsFields.map(f => f.name).join(', '));
  console.log('jobsErr ' + (jobs.errors ? JSON.stringify(jobs.errors).slice(0, 200) : 'none'));
  const c = jobs && jobs.data && jobs.data.client;
  if (c) {
    console.log('client ' + (c.name || c.companyName) + ' | jobs ' + (c.jobs && c.jobs.totalCount));
    (c.jobs && c.jobs.nodes || []).forEach(j => {
      const li = (j.lineItems && j.lineItems.nodes || []).map(x => x.name).join(' ; ');
      const sched = j.visitSchedule ? `${j.visitSchedule.startDate || '?'}..${j.visitSchedule.endDate || '?'}` : 'none';
      console.log(`  #${j.jobNumber} [${j.jobType}/${j.jobStatus}] sched=${sched} "${j.title}" -> ${li || '(no line items)'}`);
    });
  }
})().catch(e => { console.error('FATAL ' + e.message); process.exit(1); });
