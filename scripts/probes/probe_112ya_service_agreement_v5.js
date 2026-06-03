// probe_112ya_service_agreement_v5.js
// Compare recurrence exposure across 112-YA jobs: the new SA shell vs two older
// established recurring jobs. Answers: does Jobber expose frequency for configured jobs?
const https = require('https');
const fs = require('fs');
const path = require('path');
const { getValidToken } = require('../sync/jobber_token');

const JOBS = {
  '11100534_SA_Pumping_new': 'Z2lkOi8vSm9iYmVyL0pvYi8xNDY2NTAxNDI=', // 146650142
  '10000152_GT_CLeaning_old': 'Z2lkOi8vSm9iYmVyL0pvYi8xMjc2MzU1MDc=', // 127635507
  '10000178_GT_ServiceAgreement_old': 'Z2lkOi8vSm9iYmVyL0pvYi8xMjkzNTMwNjE=', // 129353061
};

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
  const results = {};
  for (const [label, gid] of Object.entries(JOBS)) {
    const r = await gqlRetry(token, `{
      job(id: "${gid}") {
        id jobNumber title jobType jobStatus startAt endAt
        visitSchedule { startDate endDate startTime endTime recurrenceSchedule { friendly calendarRule } }
        visits(first: 8) { totalCount nodes { startAt } }
      }
    }`, label);
    results[label] = r;
    const j = r && r.data && r.data.job;
    if (j) {
      const rs = j.visitSchedule && j.visitSchedule.recurrenceSchedule;
      const dates = (j.visits && j.visits.nodes || []).map(v => (v.startAt || '').slice(0, 10));
      console.log(`\n${label} #${j.jobNumber} [${j.jobType}/${j.jobStatus}]`);
      console.log('  vs.start/end = ' + (j.visitSchedule && j.visitSchedule.startDate) + ' .. ' + (j.visitSchedule && j.visitSchedule.endDate));
      console.log('  recurrence.friendly = ' + (rs && rs.friendly));
      console.log('  recurrence.calendarRule = ' + (rs && rs.calendarRule));
      console.log('  visits total = ' + (j.visits && j.visits.totalCount) + ' | recent: ' + dates.join(', '));
    } else {
      console.log(`\n${label}: err ` + (r.errors ? JSON.stringify(r.errors).slice(0, 200) : '?'));
    }
    await sleep(2500);
  }
  const outPath = path.resolve(__dirname, '../../docs/audits/2026-06-03/112ya_jobber_probe_v5.json');
  fs.writeFileSync(outPath, JSON.stringify({ probed_at: new Date().toISOString(), results }, null, 2));
  console.log('\nWROTE ' + outPath);
})().catch(e => { console.error('FATAL ' + e.message); process.exit(1); });
