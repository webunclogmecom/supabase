// Audit Airtable activity in the last 24 hours (ET):
//   1. Visits CREATED today              (record.createdTime within window)
//   2. Visits with Visit Date UPDATED today (Last Modified (Visit Date) within window AND created earlier)
//   3. Clients MODIFIED today            (Last modified time within window — could include GT/CL freq changes)
//
// Airtable doesn't track field-level history, so we can't directly pinpoint
// which fields on a modified Client changed. We surface the client's current
// freq values + modification timestamp; the office can confirm.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const AT_KEY  = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

// Window: today 00:00 ET → now (UTC offset depends on DST; today is May → EDT → UTC-4)
const todayUtc = new Date();
const startEtMs = new Date(Date.UTC(todayUtc.getUTCFullYear(), todayUtc.getUTCMonth(), todayUtc.getUTCDate()) - (-4) * 3600 * 1000);
// startEt is 00:00 ET. Convert to ISO for Airtable filter.
const startIso = startEtMs.toISOString();

function http(opts) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.end();
  });
}
async function listAll(table, fields, filter, includeCreatedTime) {
  const out = []; let offset; const enc = encodeURIComponent;
  do {
    const fparam = (fields || []).map(f => `fields%5B%5D=${enc(f)}`).join('&');
    const ffilt  = filter ? `&filterByFormula=${enc(filter)}` : '';
    const path = `/v0/${AT_BASE}/${enc(table)}?${fparam}&pageSize=100${ffilt}${offset ? `&offset=${enc(offset)}` : ''}`;
    const r = await http({ hostname: 'api.airtable.com', path, method: 'GET',
      headers: { Authorization: `Bearer ${AT_KEY}` } });
    if (r.status >= 300) throw new Error(`Airtable ${table} ${r.status}: ${r.body.slice(0,200)}`);
    const j = JSON.parse(r.body);
    for (const rec of (j.records || [])) {
      const row = { ...rec.fields };
      if (includeCreatedTime) row._createdTime = rec.createdTime;
      row._id = rec.id;
      out.push(row);
    }
    offset = j.offset;
  } while (offset);
  return out;
}

(async () => {
  console.log(`Airtable activity since ${startIso} (= today 00:00 ET)\n`);

  // ===== VISITS =====
  console.log('[1] Pulling Visits with Last Modified (Visit Date) since today...');
  const visits = await listAll('Visits',
    ['Visit Date', 'Service Type', 'Status', 'REAL STATUS', 'Client Code', 'Client', 'Last Modified (Visit Date)'],
    `IS_AFTER({Last Modified (Visit Date)}, '${startIso}')`,
    /* includeCreatedTime */ true);

  const created = visits.filter(v => v._createdTime >= startIso);
  const dateUpdated = visits.filter(v => v._createdTime < startIso);

  console.log(`\n=== VISITS CREATED TODAY (${created.length}) ===`);
  if (!created.length) console.log('  (none)');
  console.log(`  visit_date  | svc | code      | client (linked record)              | created_at_et`);
  console.log(`  ------------|-----|-----------|-------------------------------------|---------------`);
  for (const v of created) {
    const code = (Array.isArray(v['Client Code']) ? v['Client Code'][0] : v['Client Code']) || '-';
    const link = Array.isArray(v.Client) ? v.Client[0] : '';
    const et = new Date(new Date(v._createdTime).getTime() - 4 * 3600 * 1000).toISOString().slice(0, 16);
    console.log(`  ${(v['Visit Date'] || '-').padEnd(11)} | ${(v['Service Type'] || '-').padEnd(3)} | ${String(code).padEnd(10)}| ${String(link).padEnd(36)} | ${et}`);
  }

  console.log(`\n=== VISITS WHERE VISIT_DATE UPDATED TODAY (${dateUpdated.length}) ===`);
  if (!dateUpdated.length) console.log('  (none)');
  console.log(`  current visit_date | svc | code      | last_mod_et   | created_at_et`);
  console.log(`  -------------------|-----|-----------|---------------|---------------`);
  for (const v of dateUpdated) {
    const code = (Array.isArray(v['Client Code']) ? v['Client Code'][0] : v['Client Code']) || '-';
    const lmEt = v['Last Modified (Visit Date)']
      ? new Date(new Date(v['Last Modified (Visit Date)']).getTime() - 4 * 3600 * 1000).toISOString().slice(0, 16)
      : '-';
    const cEt = new Date(new Date(v._createdTime).getTime() - 4 * 3600 * 1000).toISOString().slice(0, 10);
    console.log(`  ${(v['Visit Date'] || '-').padEnd(18)} | ${(v['Service Type'] || '-').padEnd(3)} | ${String(code).padEnd(10)}| ${lmEt.padEnd(13)} | ${cEt}`);
  }

  // ===== CLIENTS =====
  console.log(`\n[2] Pulling Clients modified today (Last modified time since ${startIso})...`);
  const clients = await listAll('Clients',
    ['Client Code #3', 'Client Name', 'CLIENT XX', 'GT Frequency', 'CL Frequency', 'ACTIVE/INACTIVE', 'Last modified time'],
    `IS_AFTER({Last modified time}, '${startIso}')`,
    /* includeCreatedTime */ false);

  console.log(`\n=== CLIENTS MODIFIED TODAY (${clients.length}) — could include freq changes (Airtable doesn't expose field-level history) ===`);
  if (!clients.length) console.log('  (none)');
  console.log(`  code      | active/inactive | GT freq | CL freq | last_mod_et   | name`);
  console.log(`  ----------|-----------------|---------|---------|---------------|------`);
  for (const c of clients) {
    const code = String(c['Client Code #3'] || c['CLIENT XX'] || '').trim();
    const active = String(c['ACTIVE/INACTIVE'] || '').slice(0, 15);
    const gt = c['GT Frequency'] ?? '-';
    const cl = c['CL Frequency'] ?? '-';
    const lm = c['Last modified time'];
    const et = lm ? new Date(new Date(lm).getTime() - 4 * 3600 * 1000).toISOString().slice(0, 16) : '-';
    console.log(`  ${code.padEnd(10)}| ${active.padEnd(15)} | ${String(gt).padStart(7)} | ${String(cl).padStart(7)} | ${et.padEnd(13)} | ${(c['Client Name'] || '').toString().slice(0, 35)}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
