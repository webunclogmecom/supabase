// probe_112ya_service_agreement.js
// One-off investigation for the Service Agreement / Service Call rebuild.
// 1. Pull ALL of 112-YA (Yan's Restaurant) Jobber jobs: type, status, title,
//    total, dates, line items.
// 2. Introspect the Jobber `Job` GraphQL type to find any recurrence /
//    frequency / schedule field (the open question for the generator).
// Writes a JSON artifact (reliable) + prints a tiny summary.

const https = require('https');
const fs = require('fs');
const path = require('path');
const { getValidToken } = require('../sync/jobber_token');

// 112-YA Yan's Restaurant client GID (gid://Jobber/Client/106567404)
const CLIENT_GID = 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ=';

function gql(token, query) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query });
    const req = https.request({
      hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
      headers: {
        Authorization: 'Bearer ' + token,
        'Content-Type': 'application/json',
        'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
        'Content-Length': Buffer.byteLength(body),
      },
    }, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => { try { resolve(JSON.parse(d)); } catch (e) { reject(new Error('parse ' + r.statusCode + ': ' + d.slice(0, 300))); } });
    });
    req.on('error', reject); req.setTimeout(30000, () => req.destroy(new Error('timeout')));
    req.write(body); req.end();
  });
}

(async () => {
  const token = await getValidToken();

  // (A) All of 112-YA's jobs + line items
  const qJobs = `{
    client(id: "${CLIENT_GID}") {
      id name companyName
      jobs(first: 50) {
        totalCount
        nodes {
          id jobNumber jobType jobStatus title total startAt endAt
          lineItems(first: 40) { nodes { name description quantity unitPrice totalPrice } }
        }
      }
    }
  }`;
  const jobsRaw = await gql(token, qJobs);

  // (B) Introspect the Job type — looking for recurrence / frequency / schedule fields
  const qIntro = `{ __type(name: "Job") { name fields { name description type { name kind ofType { name kind } } } } }`;
  const introRaw = await gql(token, qIntro);

  const out = {
    probed_at: new Date().toISOString(),
    client_gid: CLIENT_GID,
    jobs: jobsRaw,
    job_type_introspection: introRaw,
  };
  const outPath = path.resolve(__dirname, '../../docs/audits/2026-06-03/112ya_jobber_probe.json');
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2));

  // tiny summary (keep stdout small per Windows corruption mitigation)
  const c = jobsRaw && jobsRaw.data && jobsRaw.data.client;
  console.log('WROTE ' + outPath);
  console.log('jobsErr ' + (jobsRaw.errors ? JSON.stringify(jobsRaw.errors).slice(0, 250) : 'none'));
  console.log('introErr ' + (introRaw.errors ? JSON.stringify(introRaw.errors).slice(0, 250) : 'none'));
  if (c) {
    console.log('client ' + (c.name || c.companyName) + ' | jobs ' + (c.jobs && c.jobs.totalCount));
    (c.jobs && c.jobs.nodes || []).forEach(j => {
      const li = (j.lineItems && j.lineItems.nodes || []).map(x => x.name).join(' ; ');
      console.log(`  #${j.jobNumber} [${j.jobType}/${j.jobStatus}] "${j.title}" -> ${li || '(no line items)'}`);
    });
  }
  // List any Job field whose name hints at recurrence/frequency/schedule
  const fields = introRaw && introRaw.data && introRaw.data.__type && introRaw.data.__type.fields || [];
  const hits = fields.filter(f => /recur|freq|schedul|interval|repeat|visit/i.test(f.name)).map(f => f.name);
  console.log('Job recurrence-ish fields: ' + (hits.join(', ') || '(none found)'));
})().catch(e => { console.error('FATAL ' + e.message); process.exit(1); });
