// probe_112ya_service_agreement_v8.js
// Read #11100534's numeric custom fields (label + value + unit) -> find the frequency.
const https = require('https');
const fs = require('fs');
const path = require('path');
const { getValidToken } = require('../sync/jobber_token');

const SA_GID = 'Z2lkOi8vSm9iYmVyL0pvYi8xNDY2NTAxNDI='; // #11100534
const SC_GID = 'Z2lkOi8vSm9iYmVyL0pvYi8xNDY2NTAxNDQ='; // #99900535 Service Call (compare)

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
const cfFrag = `customFields {
  __typename
  ... on CustomFieldNumeric { id label unit valueNumeric }
  ... on CustomFieldText { id label valueText }
  ... on CustomFieldDropdown { id label valueDropdown }
  ... on CustomFieldTrueFalse { id label valueTrueFalse }
}`;

(async () => {
  const token = await getValidToken();
  const r = await gqlRetry(token, `{
    sa: job(id:"${SA_GID}") { jobNumber title ${cfFrag} }
    sc: job(id:"${SC_GID}") { jobNumber title ${cfFrag} }
  }`, 'customFields values');

  fs.writeFileSync(path.resolve(__dirname, '../../docs/audits/2026-06-03/112ya_jobber_probe_v8.json'), JSON.stringify({ probed_at: new Date().toISOString(), r }, null, 2));
  console.log('err ' + (r.errors ? JSON.stringify(r.errors).slice(0, 300) : 'none'));
  for (const k of ['sa', 'sc']) {
    const j = r.data && r.data[k];
    if (!j) { console.log(k + ': (none)'); continue; }
    console.log(`\n${k} #${j.jobNumber} "${j.title}"`);
    (j.customFields || []).forEach(c => {
      const val = c.valueNumeric != null ? c.valueNumeric : (c.valueText != null ? c.valueText : (c.valueDropdown != null ? c.valueDropdown : c.valueTrueFalse));
      console.log(`  [${c.__typename}] label="${c.label}" value=${JSON.stringify(val)}${c.unit ? ' unit=' + c.unit : ''}`);
    });
  }
})().catch(e => { console.error('FATAL ' + e.message); process.exit(1); });
