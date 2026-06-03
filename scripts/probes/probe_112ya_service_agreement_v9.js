// probe_112ya_service_agreement_v9.js — re-check #11100534 CURRENT state after Fred's change:
// native recurrence? visits now? custom field still there?
const https = require('https');
const fs = require('fs');
const path = require('path');
const { getValidToken } = require('../sync/jobber_token');
const SA_GID = 'Z2lkOi8vSm9iYmVyL0pvYi8xNDY2NTAxNDI='; // #11100534

function gql(token, query) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query });
    const req = https.request({ hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
      headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Length': Buffer.byteLength(body) } },
      r => { let d = ''; r.on('data', c => d += c); r.on('end', () => { try { resolve(JSON.parse(d)); } catch (e) { reject(new Error('parse ' + r.statusCode + ': ' + d.slice(0, 300))); } }); });
    req.on('error', reject); req.setTimeout(30000, () => req.destroy(new Error('timeout'))); req.write(body); req.end();
  });
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function gqlRetry(token, q) { for (let a = 1; a <= 6; a++) { const r = await gql(token, q); if (r.errors && r.errors[0] && r.errors[0].extensions && r.errors[0].extensions.code === 'THROTTLED') { await sleep(3000 * a); continue; } return r; } return { errors: [{ message: 'throttled' }] }; }

(async () => {
  const token = await getValidToken();
  const r = await gqlRetry(token, `{ job(id:"${SA_GID}") {
      jobNumber jobType jobStatus
      visitSchedule { startDate endDate startTime endTime recurrenceSchedule { friendly calendarRule } }
      visits(first: 8) { totalCount nodes { startAt title } }
      customFields { __typename ... on CustomFieldNumeric { label valueNumeric unit } }
  } }`);
  fs.writeFileSync(path.resolve(__dirname, '../../docs/audits/2026-06-03/112ya_jobber_probe_v9.json'), JSON.stringify({ probed_at: new Date().toISOString(), r }, null, 2));
  console.log('err ' + (r.errors ? JSON.stringify(r.errors).slice(0, 250) : 'none'));
  const j = r.data && r.data.job;
  if (j) {
    const rs = j.visitSchedule && j.visitSchedule.recurrenceSchedule;
    console.log('jobType/status = ' + j.jobType + '/' + j.jobStatus);
    console.log('visitSchedule.start/end = ' + (j.visitSchedule && j.visitSchedule.startDate) + ' .. ' + (j.visitSchedule && j.visitSchedule.endDate));
    console.log('recurrence.friendly = ' + (rs && rs.friendly));
    console.log('recurrence.calendarRule = ' + (rs && rs.calendarRule));
    console.log('visits total = ' + (j.visits && j.visits.totalCount));
    (j.visits && j.visits.nodes || []).forEach(v => console.log('  visit ' + (v.startAt || '').slice(0, 10) + ' "' + (v.title || '') + '"'));
    (j.customFields || []).forEach(c => console.log('  customField label="' + c.label + '" value=' + c.valueNumeric + ' unit=' + c.unit));
  }
})().catch(e => { console.error('FATAL ' + e.message); process.exit(1); });
