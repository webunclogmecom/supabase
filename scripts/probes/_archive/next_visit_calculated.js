// Calculate the canonical next-visit date per active client+service:
//   1. last_completed = MAX(visits.visit_date) for matching service_type (Jobber → our DB)
//   2. freq           = Airtable [SVC] Frequency
//   3. expected_next  = last_completed + freq  (calculated here — don't trust Airtable's stored "Next Visit")
//   4. days_until     = expected_next - today  (negative = overdue)
//
// Skips Airtable ACTIVE/INACTIVE = PAUSED or INACTIVE.
// CLI: --service GT|CL (default GT), --threshold-days N (default 0 → show all overdue)
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const AT_KEY  = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const ACTIVE_FIELD = 'ACTIVE/INACTIVE';

const svcArg = process.argv.indexOf('--service');
const SERVICE_FILTER = svcArg >= 0 ? process.argv[svcArg + 1] : 'GT';
if (!['GT', 'CL'].includes(SERVICE_FILTER)) { console.error('--service must be GT or CL'); process.exit(1); }

const thArg = process.argv.indexOf('--threshold-days');
const THRESHOLD = thArg >= 0 ? parseInt(process.argv[thArg + 1]) : 0;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  let lastBody = '';
  for (let i = 0; i < 5; i++) {
    const r = await http({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, JSON.stringify({ query: sql }));
    if (r.status < 300) return JSON.parse(r.body);
    lastBody = r.body;
    if (r.status === 429 || r.status >= 500) {
      await new Promise(rs => setTimeout(rs, 5000 * (i + 1)));
      continue;
    }
    throw new Error(`PG ${r.status}: ${r.body.slice(0, 300)}`);
  }
  throw new Error(`5xx exhausted: ${lastBody.slice(0, 200)}`);
}

async function pullAirtable() {
  const out = {};
  let offset;
  const enc = encodeURIComponent;
  const fields = [
    ACTIVE_FIELD, 'Client Name', 'CLIENT XX',
    'GT Frequency', 'CL Frequency',
  ];
  const fieldsParam = fields.map(f => `fields%5B%5D=${enc(f)}`).join('&');
  do {
    const path = `/v0/${AT_BASE}/Clients?${fieldsParam}&pageSize=100${offset ? `&offset=${enc(offset)}` : ''}`;
    const r = await http({ hostname: 'api.airtable.com', path, method: 'GET',
      headers: { Authorization: `Bearer ${AT_KEY}` } });
    if (r.status >= 300) throw new Error(`Airtable ${r.status}: ${r.body.slice(0, 200)}`);
    const j = JSON.parse(r.body);
    for (const rec of (j.records || [])) out[rec.id] = rec.fields;
    offset = j.offset;
  } while (offset);
  return out;
}

(async () => {
  const today = new Date().toISOString().slice(0, 10);
  console.log(`Service: ${SERVICE_FILTER}  |  threshold: ${THRESHOLD} days overdue or more  |  today: ${today}\n`);

  const at = await pullAirtable();

  // Per client, last completed visit of THIS service_type only.
  // service_type is already filtered in the JOIN, so we don't need it in the
  // SELECT/GROUP BY.
  const db = await pg(`
    SELECT
      c.client_code, c.name AS db_name,
      MAX(CASE WHEN esl.source_system='airtable' THEN esl.source_id END) AS at_id,
      MAX(v.visit_date)::text AS last_done
    FROM clients c
    LEFT JOIN entity_source_links esl ON esl.entity_type='client' AND esl.entity_id=c.id
    LEFT JOIN visits v ON v.client_id=c.id AND v.visit_status='completed' AND v.service_type='${SERVICE_FILTER}'
    WHERE c.client_code IS NOT NULL
    GROUP BY c.client_code, c.name
  `);

  const results = [];
  let skippedPaused = 0, skippedNoFreq = 0, skippedNoLast = 0, skippedNoLink = 0;

  for (const row of db) {
    if (!row.at_id) { skippedNoLink++; continue; }
    const fields = at[row.at_id];
    if (!fields) { skippedNoLink++; continue; }

    // Only "Recuring" clients (Airtable's intentional misspelling of Recurring).
    // ACTIVE = emergency-only, PAUSED = on hold, INACTIVE = ended — none of
    // those have a contracted cadence to compare against.
    const status = String(fields[ACTIVE_FIELD] || '').toUpperCase();
    if (status !== 'RECURING') { skippedPaused++; continue; }

    const freq = Number(fields[`${SERVICE_FILTER} Frequency`]);
    if (!freq) { skippedNoFreq++; continue; }
    if (!row.last_done) { skippedNoLast++; continue; }

    const expectedNext = new Date(new Date(row.last_done).getTime() + freq * 86400000)
      .toISOString().slice(0, 10);
    const daysUntil = Math.round((new Date(expectedNext) - new Date(today)) / 86400000);

    results.push({
      code: row.client_code,
      name: (fields['Client Name'] || row.db_name || '').toString().slice(0, 35),
      freq,
      last_done: row.last_done,
      expected_next: expectedNext,
      days_until: daysUntil,
      at_status: status,
    });
  }

  // Sort: most overdue first
  results.sort((a, b) => a.days_until - b.days_until);

  const overdue = results.filter(r => r.days_until <= -THRESHOLD);
  const dueSoon = results.filter(r => r.days_until > -THRESHOLD && r.days_until <= 7);
  const future  = results.filter(r => r.days_until > 7);

  console.log(`Recuring ${SERVICE_FILTER} clients evaluated: ${results.length}`);
  console.log(`  Skipped: ${skippedPaused} non-Recuring (ACTIVE/PAUSED/INACTIVE/empty), ${skippedNoFreq} no-freq, ${skippedNoLast} no-completed-visit, ${skippedNoLink} no-airtable-link\n`);

  console.log(`OVERDUE (expected next ≤ today - ${THRESHOLD}d)  —  ${overdue.length}`);
  console.log(`client    | freq | last completed | expected next | days overdue | name`);
  console.log(`----------|------|----------------|---------------|--------------|------`);
  for (const r of overdue) {
    console.log(`${r.code.padEnd(10)}| ${String(r.freq).padStart(4)} | ${r.last_done}     | ${r.expected_next}    | ${String(-r.days_until).padStart(12)} | ${r.name}`);
  }

  console.log(`\nDUE SOON (in the next 7 days)  —  ${dueSoon.length}`);
  console.log(`client    | freq | last completed | expected next | days until | name`);
  console.log(`----------|------|----------------|---------------|------------|------`);
  for (const r of dueSoon) {
    console.log(`${r.code.padEnd(10)}| ${String(r.freq).padStart(4)} | ${r.last_done}     | ${r.expected_next}    | ${String(r.days_until).padStart(10)} | ${r.name}`);
  }

  console.log(`\nFUTURE (> 7 days out): ${future.length} clients — not shown unless requested`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
