// For each of the 10 overdue clients, pull the Airtable Clients-table record
// and inspect: GT/CL Frequency, Last Visit, Next Visit. Compare Airtable's
// "Next Visit" against (Last Visit + Frequency) and against today's date.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const AT_KEY  = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
if (!AT_KEY || !AT_BASE) { console.error('AIRTABLE_API_KEY / BASE_ID missing'); process.exit(1); }

function http(opts) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.end();
  });
}
async function pg(sql) {
  for (let i = 0; i < 3; i++) {
    const r = await new Promise((res, rej) => {
      const req = https.request({
        hostname: 'api.supabase.com',
        path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
        method: 'POST',
        headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
      }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({ status: x.statusCode, body: b })); });
      req.on('error', rej); req.write(JSON.stringify({ query: sql })); req.end();
    });
    if (r.status < 300) return JSON.parse(r.body);
    await new Promise(rs => setTimeout(rs, 4000));
  }
  throw new Error('5xx');
}

async function airtableGet(recordId) {
  const r = await http({
    hostname: 'api.airtable.com',
    path: `/v0/${AT_BASE}/Clients/${recordId}`,
    method: 'GET',
    headers: { Authorization: `Bearer ${AT_KEY}` }
  });
  if (r.status >= 300) return { error: `HTTP ${r.status}` };
  return JSON.parse(r.body);
}

const CLIENTS = [
  ['013-DIM',  'CL',  30],
  ['026-HAP',  'CL',  60],
  ['172-NU',   'GT',  60],
  ['174-VIN',  'GT',  30],
  ['029-JOS',  'GT',  30],
  ['069-TCE',  'GT',  30],
  ['070-TCE',  'CL', 120],
  ['089-COW',  'GT',  40],
  ['083-SHUL', 'CL',  60],
  ['112-YA',   'GT',  10],
];

(async () => {
  // Resolve client_code → Airtable record id via entity_source_links
  const codeList = CLIENTS.map(c => `'${c[0]}'`).join(',');
  const links = await pg(`
    SELECT c.client_code, esl.source_id AS at_record_id
    FROM clients c
    JOIN entity_source_links esl
      ON esl.entity_type='client' AND esl.entity_id=c.id AND esl.source_system='airtable'
    WHERE c.client_code IN (${codeList});
  `);
  const codeToAt = Object.fromEntries(links.map(r => [r.client_code, r.at_record_id]));

  const today = new Date().toISOString().slice(0, 10);
  console.log(`Comparing Airtable Next Visit vs (Last + Freq), today = ${today}\n`);
  console.log('client    | svc | freq | AT Last Visit | Expected      | AT Next Visit | Slip vs expected | Slip vs today | name');
  console.log('----------|-----|------|---------------|---------------|---------------|------------------|---------------|-----');

  for (const [code, svc, freq] of CLIENTS) {
    const recId = codeToAt[code];
    if (!recId) { console.log(`  ${code} — no Airtable ESL`); continue; }
    const at = await airtableGet(recId);
    if (at.error) { console.log(`  ${code} — Airtable ${at.error}`); continue; }
    const f = at.fields || {};
    const last = f[`${svc} Last Visit`] || '';
    const next = f[`${svc} Next Visit`] || '';
    const fld = f[`${svc} Frequency`] || '';

    const expected = last
      ? new Date(new Date(last).getTime() + freq * 86400000).toISOString().slice(0, 10)
      : '';
    const slipVsExpected = (next && expected)
      ? Math.round((new Date(next) - new Date(expected)) / 86400000)
      : null;
    const slipVsToday = next
      ? Math.round((new Date(next) - new Date(today)) / 86400000)
      : null;

    const flag = (slipVsExpected !== null && slipVsExpected > 14) ? '⚠️ '
              : (next === '' ? '⚠️ '
              : '   ');

    const slipExpStr = slipVsExpected === null ? '(no last)' : `${slipVsExpected > 0 ? '+' : ''}${slipVsExpected}d`;
    const slipNowStr = slipVsToday === null ? '(no next)' : `${slipVsToday > 0 ? '+' : ''}${slipVsToday}d`;

    console.log(`${flag}${code.padEnd(9)} | ${svc.padEnd(3)} | ${String(fld || freq).padStart(4)} | ${(last || '').padEnd(13)} | ${expected.padEnd(13)} | ${(next || '(empty)').padEnd(13)} | ${slipExpStr.padStart(16)} | ${slipNowStr.padStart(13)} | ${(f['Client Name'] || f['CLIENT XX'] || '').slice(0, 30)}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
