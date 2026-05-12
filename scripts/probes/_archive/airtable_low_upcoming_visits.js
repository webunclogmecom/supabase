// Find Recuring Airtable clients with < 3 upcoming visits in the Airtable
// Visits table per service type (GT / CL).
//   - Pull all Recuring clients + their GT/CL frequency (defines which services they subscribe to)
//   - Pull all upcoming Airtable visits (Visit Date >= today, status != Completed)
//   - Group by (client_code, service_type), count
//   - Flag any subscribed (client, service) pair where upcoming count < 3
//
// CLI: --threshold N (default 3), --service GT|CL (default both)
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const AT_KEY  = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const ACTIVE_FIELD = 'ACTIVE/INACTIVE';

const thArg  = process.argv.indexOf('--threshold');
const THRESH = thArg >= 0 ? parseInt(process.argv[thArg + 1]) : 3;
const svcArg = process.argv.indexOf('--service');
const SVC    = svcArg >= 0 ? process.argv[svcArg + 1] : null;
if (SVC && !['GT', 'CL'].includes(SVC)) { console.error('--service must be GT or CL'); process.exit(1); }

function http(opts) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.end();
  });
}

async function listAll(tableName, fields, filterFormula) {
  const out = [];
  const enc = encodeURIComponent;
  let offset;
  do {
    const fparam  = (fields || []).map(f => `fields%5B%5D=${enc(f)}`).join('&');
    const fffilt  = filterFormula ? `&filterByFormula=${enc(filterFormula)}` : '';
    const path = `/v0/${AT_BASE}/${enc(tableName)}?${fparam}&pageSize=100${fffilt}${offset ? `&offset=${enc(offset)}` : ''}`;
    const r = await http({ hostname: 'api.airtable.com', path, method: 'GET',
      headers: { Authorization: `Bearer ${AT_KEY}` } });
    if (r.status >= 300) throw new Error(`Airtable ${tableName} ${r.status}: ${r.body.slice(0, 200)}`);
    const j = JSON.parse(r.body);
    for (const rec of (j.records || [])) out.push(rec);
    offset = j.offset;
  } while (offset);
  return out;
}

(async () => {
  const today = new Date().toISOString().slice(0, 10);
  console.log(`Threshold: < ${THRESH} upcoming visits  |  service: ${SVC || 'GT+CL'}  |  today: ${today}\n`);

  console.log('[1/2] Pulling Recuring clients...');
  const clients = await listAll('Clients', [ACTIVE_FIELD, 'Client Code #3', 'Client Name', 'CLIENT XX', 'GT Frequency', 'CL Frequency']);
  const recuring = clients.filter(c => String(c.fields[ACTIVE_FIELD] || '').toUpperCase() === 'RECURING');
  console.log(`  ${recuring.length} Recuring clients`);

  // Index recordId → {code, gtFreq, clFreq}
  const clientById = {};
  for (const c of recuring) {
    const code = c.fields['Client Code #3'] || c.fields['CLIENT XX'] || '';
    clientById[c.id] = {
      code: String(code).trim(),
      name: (c.fields['Client Name'] || '').toString(),
      gtFreq: Number(c.fields['GT Frequency']) || 0,
      clFreq: Number(c.fields['CL Frequency']) || 0,
    };
  }

  console.log('[2/2] Pulling upcoming Airtable visits (Visit Date >= today, status not "Completed")...');
  // Filter: Visit Date >= today, REAL STATUS (or Status) not = Completed
  const filter = `AND(IS_AFTER({Visit Date}, '${today}'), {REAL STATUS} != 'Completed')`;
  const visits = await listAll('Visits',
    ['Visit Date', 'Service Type', 'Status', 'REAL STATUS', 'Client'],
    filter);
  console.log(`  ${visits.length} upcoming visits in Airtable\n`);

  // Group: (client_id, service_type) → count
  const counts = {};
  for (const v of visits) {
    const clientLink = v.fields.Client || [];
    const cid = Array.isArray(clientLink) ? clientLink[0] : null;
    if (!cid || !clientById[cid]) continue; // skip non-Recuring or unmatched
    const svc = v.fields['Service Type'];
    const svcStr = Array.isArray(svc) ? svc[0] : svc;
    const svcCode = /grease/i.test(svcStr) ? 'GT' : /clog|service/i.test(svcStr) ? 'CL' : (svcStr || '?');
    const key = `${cid}|${svcCode}`;
    counts[key] = (counts[key] || 0) + 1;
  }

  // For each Recuring client + each service they subscribe to, count their upcoming
  const flagged = [];
  for (const [cid, info] of Object.entries(clientById)) {
    if ((!SVC || SVC === 'GT') && info.gtFreq > 0) {
      const n = counts[`${cid}|GT`] || 0;
      if (n < THRESH) flagged.push({ code: info.code, name: info.name, svc: 'GT', freq: info.gtFreq, upcoming: n });
    }
    if ((!SVC || SVC === 'CL') && info.clFreq > 0) {
      const n = counts[`${cid}|CL`] || 0;
      if (n < THRESH) flagged.push({ code: info.code, name: info.name, svc: 'CL', freq: info.clFreq, upcoming: n });
    }
  }

  flagged.sort((a, b) => a.upcoming - b.upcoming || a.code.localeCompare(b.code));

  const zero  = flagged.filter(f => f.upcoming === 0);
  const one   = flagged.filter(f => f.upcoming === 1);
  const two   = flagged.filter(f => f.upcoming === 2);

  console.log(`Recuring clients with < ${THRESH} upcoming visits:`);
  console.log(`  0 upcoming: ${zero.length}`);
  console.log(`  1 upcoming: ${one.length}`);
  console.log(`  2 upcoming: ${two.length}`);
  console.log(`  total flagged: ${flagged.length}\n`);

  console.log(`code      | svc | freq | upcoming | name`);
  console.log(`----------|-----|------|----------|------`);
  for (const f of flagged) {
    console.log(`${f.code.padEnd(10)}| ${f.svc.padEnd(3)} | ${String(f.freq).padStart(4)} | ${String(f.upcoming).padStart(8)} | ${f.name.slice(0, 50)}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
