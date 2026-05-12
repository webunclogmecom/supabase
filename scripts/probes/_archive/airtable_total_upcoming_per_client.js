// All Airtable Recuring clients + their TOTAL upcoming visit count (any
// service type combined). Flag clients with ≤ 3 upcoming visits.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const AT_KEY  = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const ACTIVE_FIELD = 'ACTIVE/INACTIVE';
const THRESHOLD = 3; // flag if upcoming <= 3

function http(opts) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.end();
  });
}
async function listAll(table, fields, filter) {
  const out = []; let offset; const enc = encodeURIComponent;
  do {
    const fparam = (fields || []).map(f => `fields%5B%5D=${enc(f)}`).join('&');
    const ffilt  = filter ? `&filterByFormula=${enc(filter)}` : '';
    const path = `/v0/${AT_BASE}/${enc(table)}?${fparam}&pageSize=100${ffilt}${offset ? `&offset=${enc(offset)}` : ''}`;
    const r = await http({ hostname: 'api.airtable.com', path, method: 'GET',
      headers: { Authorization: `Bearer ${AT_KEY}` } });
    if (r.status >= 300) throw new Error(`Airtable ${table} ${r.status}: ${r.body.slice(0,200)}`);
    const j = JSON.parse(r.body);
    for (const rec of (j.records || [])) out.push(rec);
    offset = j.offset;
  } while (offset);
  return out;
}

(async () => {
  const today = new Date().toISOString().slice(0, 10);
  console.log(`Recuring clients with ≤ ${THRESHOLD} TOTAL upcoming visits  |  today: ${today}\n`);

  console.log('[1/2] Pulling Recuring clients...');
  const clients = await listAll('Clients', [ACTIVE_FIELD, 'Client Code #3', 'Client Name', 'CLIENT XX', 'GT Frequency', 'CL Frequency', 'Service Type']);
  const recuring = clients.filter(c => String(c.fields[ACTIVE_FIELD] || '').toUpperCase() === 'RECURING');
  console.log(`  ${recuring.length} Recuring clients\n`);

  // Service Type is a multiselect on Clients. The Frequency fields are unreliable
  // (some clients have stale 360/364/etc. junk freq values for services they don't
  // actually subscribe to — Yan's Airtable fix list). Source-of-truth for "does this
  // client subscribe to GT?" is Service Type containing 'Grease Trap'; for CL it's
  // 'MAIN CL'.
  const subscribesToGT = (c) => {
    const s = c.fields['Service Type'];
    const arr = Array.isArray(s) ? s : (s ? [s] : []);
    return arr.some(v => /^grease trap$/i.test(v));
  };
  const subscribesToCL = (c) => {
    const s = c.fields['Service Type'];
    const arr = Array.isArray(s) ? s : (s ? [s] : []);
    return arr.some(v => /^main cl$/i.test(v));
  };

  console.log('[2/2] Pulling upcoming Airtable visits (Visit Date >= today, status != Completed)...');
  const visits = await listAll('Visits', ['Visit Date', 'Service Type', 'Client', 'REAL STATUS'],
    `AND(IS_AFTER({Visit Date}, '${today}'), {REAL STATUS} != 'Completed')`);
  console.log(`  ${visits.length} upcoming visits\n`);

  // Build (clientRecordId → count, breakdown)
  const upcomingByClient = {};
  for (const v of visits) {
    const link = v.fields.Client || [];
    const cid = Array.isArray(link) ? link[0] : null;
    if (!cid) continue;
    if (!upcomingByClient[cid]) upcomingByClient[cid] = { total: 0, GT: 0, CL: 0, other: 0 };
    upcomingByClient[cid].total++;
    const svc = v.fields['Service Type'];
    const svcStr = (Array.isArray(svc) ? svc[0] : svc) || '';
    // Airtable's Service Type singleSelect uses 'GT' / 'CL' directly.
    if (svcStr === 'GT') upcomingByClient[cid].GT++;
    else if (svcStr === 'CL') upcomingByClient[cid].CL++;
    else upcomingByClient[cid].other++;
  }

  // Build per-(client, service) flagged rows. A client subscribed to BOTH GT
  // and CL appears once per service. A client subscribed to only one service
  // appears only for that service (we don't flag a 0-CL on a GT-only client).
  const gtFlags = [];
  const clFlags = [];
  for (const c of recuring) {
    const counts = upcomingByClient[c.id] || { total: 0, GT: 0, CL: 0, other: 0 };
    const code = String(c.fields['Client Code #3'] || c.fields['CLIENT XX'] || '').trim();
    const name = (c.fields['Client Name'] || '').toString();
    const gtFreq = Number(c.fields['GT Frequency']) || 0;
    const clFreq = Number(c.fields['CL Frequency']) || 0;

    // Subscribe-check now drives flagging, not freq value. A client with Grease
    // Trap in Service Type is GT-subscribed regardless of whether GT Frequency
    // is set or junk; conversely a non-Grease-Trap client never gets flagged
    // for GT even if their GT Frequency is 360 (junk).
    if (subscribesToGT(c) && counts.GT <= THRESHOLD) {
      gtFlags.push({ code, name, freq: gtFreq || '?', upcoming: counts.GT });
    }
    if (subscribesToCL(c) && counts.CL <= THRESHOLD) {
      clFlags.push({ code, name, freq: clFreq || '?', upcoming: counts.CL });
    }
  }
  gtFlags.sort((a, b) => a.upcoming - b.upcoming || a.code.localeCompare(b.code));
  clFlags.sort((a, b) => a.upcoming - b.upcoming || a.code.localeCompare(b.code));

  console.log(`============================================================`);
  console.log(`GT (Grease Trap) — ${gtFlags.length} Recuring clients with ≤ ${THRESHOLD} upcoming GT visits`);
  console.log(`============================================================`);
  console.log(`code      | freq | upcoming | name`);
  console.log(`----------|------|----------|------`);
  for (const f of gtFlags) {
    console.log(`${f.code.padEnd(10)}| ${String(f.freq).padStart(4)} | ${String(f.upcoming).padStart(8)} | ${f.name.slice(0, 50)}`);
  }

  console.log(`\n============================================================`);
  console.log(`CL (Clog/Service Call) — ${clFlags.length} Recuring clients with ≤ ${THRESHOLD} upcoming CL visits`);
  console.log(`============================================================`);
  console.log(`code      | freq | upcoming | name`);
  console.log(`----------|------|----------|------`);
  for (const f of clFlags) {
    console.log(`${f.code.padEnd(10)}| ${String(f.freq).padStart(4)} | ${String(f.upcoming).padStart(8)} | ${f.name.slice(0, 50)}`);
  }
  console.log(`\nNote: CL service is mostly call-when-needed (emergency clog calls), so 0 upcoming CL visits is expected for many clients. The GT list above is the operationally meaningful one.`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
