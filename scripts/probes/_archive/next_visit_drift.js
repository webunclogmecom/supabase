// Cross-source next-visit drift audit. Per client_code + service_type:
//   1. last_completed = MAX(visits.visit_date) WHERE service_type matches  (Jobber → our DB)
//   2. freq           = Airtable [SVC] Frequency
//   3. next_visit     = Airtable [SVC] Next Visit
//   4. expected       = last_completed + freq
//   5. drift          = abs(next_visit - expected) ; flag if > 2 days OR missing
// Skips Airtable ACTIVE/INACTIVE = PAUSED or INACTIVE clients.
//
// CLI: --service GT|CL (default both), --max-drift N (default 2)
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const AT_KEY  = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const ACTIVE_FIELD = 'ACTIVE/INACTIVE';

const svcArg = process.argv.indexOf('--service');
const SERVICE_FILTER = svcArg >= 0 ? process.argv[svcArg + 1] : null;
if (SERVICE_FILTER && !['GT', 'CL'].includes(SERVICE_FILTER)) {
  console.error('--service must be GT or CL'); process.exit(1);
}
const driftArg = process.argv.indexOf('--max-drift');
const MAX_DRIFT = driftArg >= 0 ? parseInt(process.argv[driftArg + 1]) : 2;

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
  for (let i = 0; i < 3; i++) {
    const r = await http({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, JSON.stringify({ query: sql }));
    if (r.status < 300) return JSON.parse(r.body);
    await new Promise(rs => setTimeout(rs, 4000));
  }
  throw new Error('5xx');
}

// Pull all Airtable Clients records with the fields we need
async function pullAirtable() {
  const out = {};
  let offset;
  const enc = encodeURIComponent;
  // Field-name matrix (Airtable Clients schema as of 2026-05-06):
  //   GT: actual scheduled next visit lives in 'GT NEXT Visit (visits table)'
  //       (formula linking to the Visits table). The 'GT Next Visit Calculated'
  //       field is just last + freq, so comparing against it would always be
  //       zero drift — useless for this audit.
  //   CL: no equivalent visits-table field. Only 'CL Next Visit Calculated'
  //       exists (a formula), so CL drift can't be detected the same way.
  const fieldList = [
    ACTIVE_FIELD,
    'Client Name', 'CLIENT XX', 'Client Code #3',
    'GT Frequency', 'GT NEXT Visit (visits table)',
    'CL Frequency', 'CL Next Visit Calculated',
  ];
  const fieldsParam = fieldList.map(f => `fields%5B%5D=${enc(f)}`).join('&');
  do {
    const path = `/v0/${AT_BASE}/Clients?${fieldsParam}&pageSize=100${offset ? `&offset=${enc(offset)}` : ''}`;
    const r = await http({ hostname: 'api.airtable.com', path, method: 'GET',
      headers: { Authorization: `Bearer ${AT_KEY}` } });
    if (r.status >= 300) throw new Error(`Airtable ${r.status}: ${r.body.slice(0, 200)}`);
    const j = JSON.parse(r.body);
    for (const rec of (j.records || [])) {
      out[rec.id] = rec.fields;
    }
    offset = j.offset;
  } while (offset);
  return out;
}

(async () => {
  console.log(`Service filter: ${SERVICE_FILTER || 'GT+CL'}  |  max drift before flag: ${MAX_DRIFT} days\n`);

  // 1. Pull all Airtable clients
  const at = await pullAirtable();

  // 2. Pull our DB: per (client_code, service_type), last completed visit_date + ESL airtable id
  const db = await pg(`
    SELECT
      c.client_code,
      MAX(CASE WHEN esl.source_system='airtable' THEN esl.source_id END) AS at_id,
      v.service_type,
      MAX(v.visit_date)::text AS last_done
    FROM clients c
    LEFT JOIN entity_source_links esl ON esl.entity_type='client' AND esl.entity_id=c.id
    LEFT JOIN visits v ON v.client_id=c.id AND v.visit_status='completed' AND v.service_type IN ('GT','CL')
    WHERE c.client_code IS NOT NULL
    GROUP BY c.client_code, v.service_type
  `);

  // Index: client_code → { GT: last_done, CL: last_done, at_id }
  const byCode = {};
  for (const row of db) {
    if (!byCode[row.client_code]) byCode[row.client_code] = { at_id: row.at_id, GT: null, CL: null };
    byCode[row.client_code].at_id = row.at_id || byCode[row.client_code].at_id;
    if (row.service_type) byCode[row.client_code][row.service_type] = row.last_done;
  }

  const services = SERVICE_FILTER ? [SERVICE_FILTER] : ['GT', 'CL'];
  const results = [];
  let skipped = 0;

  for (const [code, info] of Object.entries(byCode)) {
    if (!info.at_id) { skipped++; continue; }
    const fields = at[info.at_id];
    if (!fields) { skipped++; continue; }
    // Only Recuring clients (Airtable's intentional misspelling). Skip
    // ACTIVE/PAUSED/INACTIVE/empty — they don't have a contracted recurring
    // cadence so a frequency mismatch isn't meaningful.
    const status = String(fields[ACTIVE_FIELD] || '').toUpperCase();
    if (status !== 'RECURING') continue;

    for (const svc of services) {
      const lastDone = info[svc];
      const freq    = Number(fields[`${svc} Frequency`]);
      // Field name differs by service — see fieldList comment above.
      const nextField = svc === 'GT' ? 'GT NEXT Visit (visits table)' : 'CL Next Visit Calculated';
      const nextRaw = fields[nextField];
      const next    = nextRaw ? String(nextRaw).slice(0, 10) : null;

      // Need freq to do anything
      if (!freq) continue;
      // Need at least last_done OR next to compute
      if (!lastDone && !next) continue;

      const expected = lastDone
        ? new Date(new Date(lastDone).getTime() + freq * 86400000).toISOString().slice(0, 10)
        : null;

      let drift = null;
      if (expected && next) {
        drift = Math.round((new Date(next) - new Date(expected)) / 86400000);
      }

      const status_label =
        !next      ? 'NO_NEXT_SET' :
        !expected  ? 'NO_LAST_DONE' :
        Math.abs(drift) <= MAX_DRIFT ? 'OK' :
        drift > 0  ? `LATE_BY_${drift}d` :
        `EARLY_BY_${-drift}d`;

      results.push({
        code, svc, status: status_label,
        freq, last_done: lastDone || '(none)', expected: expected || '(n/a)',
        next: next || '(empty)', drift,
        name: (fields['Client Name'] || fields['CLIENT XX'] || '').toString().slice(0, 30),
      });
    }
  }

  // Sort: missing-next first, then largest absolute drift
  const sortKey = (r) => {
    if (r.status === 'OK') return 0;
    if (r.status === 'NO_NEXT_SET') return 1_000_000;
    if (r.status === 'NO_LAST_DONE') return -1;
    return Math.abs(r.drift);
  };
  results.sort((a, b) => sortKey(b) - sortKey(a));

  // Buckets
  const noNext   = results.filter(r => r.status === 'NO_NEXT_SET');
  const drifted  = results.filter(r => r.status.startsWith('LATE_BY_') || r.status.startsWith('EARLY_BY_'));
  const ok       = results.filter(r => r.status === 'OK');
  const noLast   = results.filter(r => r.status === 'NO_LAST_DONE');

  console.log(`Evaluated: ${results.length} client+service pairs (skipped ${skipped} no-Airtable-link, ignored PAUSED/INACTIVE)\n`);

  console.log(`A. Airtable Next Visit is empty (need to set it) — ${noNext.length}`);
  console.log(`   client    | svc | freq | last done   | expected next  | name`);
  console.log(`   ----------|-----|------|-------------|----------------|--------------`);
  for (const r of noNext) {
    console.log(`   ${r.code.padEnd(10)}| ${r.svc.padEnd(3)} | ${String(r.freq).padStart(4)} | ${r.last_done}  | ${r.expected.padEnd(14)} | ${r.name}`);
  }

  console.log(`\nB. Airtable Next Visit drifts > ${MAX_DRIFT} days from (last_jobber + freq_airtable) — ${drifted.length}`);
  console.log(`   client    | svc | freq | last done   | expected next  | AT next visit  | drift     | name`);
  console.log(`   ----------|-----|------|-------------|----------------|----------------|-----------|--------------`);
  for (const r of drifted) {
    const dStr = r.drift > 0 ? `+${r.drift}d late` : `${r.drift}d early`;
    console.log(`   ${r.code.padEnd(10)}| ${r.svc.padEnd(3)} | ${String(r.freq).padStart(4)} | ${r.last_done}  | ${r.expected.padEnd(14)} | ${r.next.padEnd(14)} | ${dStr.padStart(9)} | ${r.name}`);
  }

  console.log(`\nC. No completed-visit data in our DB (informational) — ${noLast.length}`);
  for (const r of noLast.slice(0, 10)) console.log(`   ${r.code} ${r.svc}  AT next=${r.next}  freq=${r.freq}  ${r.name}`);
  if (noLast.length > 10) console.log(`   ...and ${noLast.length - 10} more`);

  console.log(`\nD. OK (within ${MAX_DRIFT}d tolerance) — ${ok.length}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
