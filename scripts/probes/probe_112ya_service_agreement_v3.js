// probe_112ya_service_agreement_v3.js
// Introspect Jobber `RecurrenceSchedule` + pull #11100534 (SA-Pumping) schedule window.
const https = require('https');
const fs = require('fs');
const path = require('path');
const { getValidToken } = require('../sync/jobber_token');

const SA_JOB_GID = 'Z2lkOi8vSm9iYmVyL0pvYi8xNDY2NTAxNDI='; // #11100534 gid://Jobber/Job/146650142

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
    if (r.errors && r.errors[0] && r.errors[0].extensions && r.errors[0].extensions.code === 'THROTTLED') { const w = 3 * attempt; console.log(`throttled ${label} ${attempt}, sleep ${w}s`); await sleep(w * 1000); continue; }
    return r;
  }
  return { errors: [{ message: 'still throttled' }] };
}

(async () => {
  const token = await getValidToken();
  const intro = await gqlRetry(token, `{ __type(name:"RecurrenceSchedule") { name fields { name description type { name kind ofType { name kind ofType { name kind } } } } } }`, 'RecurrenceSchedule');
  await sleep(2000);
  const job = await gqlRetry(token, `{
    job(id: "${SA_JOB_GID}") {
      id jobNumber title jobType jobStatus
      visitSchedule { startDate endDate startTime endTime }
    }
  }`, 'job');

  const out = { probed_at: new Date().toISOString(), recurrence_schedule_introspection: intro, sa_job: job };
  const outPath = path.resolve(__dirname, '../../docs/audits/2026-06-03/112ya_jobber_probe_v3.json');
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2));
  console.log('WROTE ' + outPath);

  const f = intro && intro.data && intro.data.__type && intro.data.__type.fields || [];
  console.log('RecurrenceSchedule fields:');
  f.forEach(x => console.log(`  - ${x.name} : ${(x.type && (x.type.name || (x.type.ofType && x.type.ofType.name))) || '?'}  // ${x.description || ''}`));
  console.log('jobErr ' + (job.errors ? JSON.stringify(job.errors).slice(0, 200) : 'none'));
  const j = job && job.data && job.data.job;
  if (j) console.log('SA job #' + j.jobNumber + ' visitSchedule = ' + JSON.stringify(j.visitSchedule));
})().catch(e => { console.error('FATAL ' + e.message); process.exit(1); });
