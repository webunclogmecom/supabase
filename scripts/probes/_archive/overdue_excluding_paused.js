// Re-run the overdue-next-visit sweep, but exclude any client with
// Airtable ACTIVE/INACTIVE = PAUSED or INACTIVE. Also distinguish:
//   ACTIVE   → expects regular service
//   PAUSED   → on hold, not expected to receive visits
//   INACTIVE → contract ended
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const AT_KEY  = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const ACTIVE_FIELD = 'ACTIVE/INACTIVE';

// CLI: --service GT|CL  (default = both)
const svcArg = process.argv.find(a => a.startsWith('--service'));
const SERVICE_FILTER = svcArg ? svcArg.split('=')[1] || process.argv[process.argv.indexOf(svcArg) + 1] : null;
if (SERVICE_FILTER && !['GT', 'CL'].includes(SERVICE_FILTER)) {
  console.error(`--service must be GT or CL`); process.exit(1);
}

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

// Pull all Airtable Clients with ACTIVE/INACTIVE state, paginated.
// `fields[]=X&fields[]=Y` is the Airtable repeated-param form — the literal
// `[]` MUST be URL-encoded as %5B%5D, otherwise Airtable returns 0 records
// (the param is silently parsed as an unknown query string).
async function pullActiveStates() {
  const out = {};
  let offset;
  const enc = encodeURIComponent;
  do {
    const fieldsParam = `fields%5B%5D=${enc(ACTIVE_FIELD)}`;
    const path = `/v0/${AT_BASE}/Clients?${fieldsParam}&pageSize=100${offset ? `&offset=${enc(offset)}` : ''}`;
    const r = await http({ hostname: 'api.airtable.com', path, method: 'GET',
      headers: { Authorization: `Bearer ${AT_KEY}` } });
    if (r.status >= 300) throw new Error(`Airtable list ${r.status}: ${r.body.slice(0, 200)}`);
    const j = JSON.parse(r.body);
    for (const rec of (j.records || [])) {
      out[rec.id] = { active: rec.fields[ACTIVE_FIELD] || null };
    }
    offset = j.offset;
  } while (offset);
  return out;
}

(async () => {
  // Pull Airtable state for all clients
  console.log('Pulling Airtable ACTIVE/INACTIVE for all Clients...');
  const atStates = await pullActiveStates();
  const total = Object.keys(atStates).length;
  const byState = {};
  for (const v of Object.values(atStates)) byState[v.active || '(empty)'] = (byState[v.active || '(empty)'] || 0) + 1;
  console.log(`  ${total} Airtable Client records. State distribution:`, byState);

  // Run the overdue analysis as before, but JOIN to Airtable state
  const rows = await pg(`
    WITH active AS (
      SELECT sc.client_id, c.client_code, c.name, sc.service_type, sc.frequency_days,
        (SELECT esl.source_id FROM entity_source_links esl
          WHERE esl.entity_type='client' AND esl.entity_id=c.id AND esl.source_system='airtable'
          LIMIT 1) AS at_id
      FROM service_configs sc
      JOIN clients c ON c.id = sc.client_id
      WHERE c.status IN ('ACTIVE','Recuring','recuring')
        AND sc.frequency_days > 0
        AND sc.service_type IN (${SERVICE_FILTER ? `'${SERVICE_FILTER}'` : `'GT','CL'`})
    ),
    last_visit AS (
      SELECT v.client_id, v.service_type, MAX(v.visit_date) AS last_done
      FROM visits v WHERE v.visit_status = 'completed'
      GROUP BY v.client_id, v.service_type
    ),
    next_visit AS (
      SELECT v.client_id, v.service_type, MIN(v.visit_date) AS next_scheduled
      FROM visits v
      WHERE v.visit_status IN ('scheduled','today','late')
        AND v.visit_date >= CURRENT_DATE - INTERVAL '60 days'
      GROUP BY v.client_id, v.service_type
    )
    SELECT
      a.client_code, a.name, a.service_type, a.frequency_days AS freq,
      a.at_id,
      lv.last_done::text AS last_done,
      (lv.last_done + a.frequency_days * INTERVAL '1 day')::date::text AS expected_next,
      nv.next_scheduled::text AS actual_next,
      CASE
        WHEN nv.next_scheduled IS NULL THEN
          (CURRENT_DATE - (lv.last_done + a.frequency_days * INTERVAL '1 day')::date)::int
        ELSE
          (nv.next_scheduled - (lv.last_done + a.frequency_days * INTERVAL '1 day')::date)::int
      END AS slip_days
    FROM active a
    LEFT JOIN last_visit lv ON lv.client_id = a.client_id AND lv.service_type = a.service_type
    LEFT JOIN next_visit nv ON nv.client_id = a.client_id AND nv.service_type = a.service_type
    WHERE lv.last_done IS NOT NULL
    ORDER BY slip_days DESC NULLS FIRST;
  `);

  // Annotate with AT active state and split
  for (const r of rows) {
    r.active_state = (atStates[r.at_id]?.active || 'UNKNOWN').toUpperCase();
  }

  const skipped = rows.filter(r => r.active_state === 'PAUSED' || r.active_state === 'INACTIVE');
  const real    = rows.filter(r => r.active_state !== 'PAUSED' && r.active_state !== 'INACTIVE');

  const noNext = real.filter(r => r.actual_next === null && r.slip_days > 0);
  const wayLate = real.filter(r => r.actual_next !== null && r.slip_days > 14);

  console.log(`\nTotal active GT/CL configs evaluated: ${rows.length}`);
  console.log(`  Skipped (PAUSED/INACTIVE in Airtable): ${skipped.length}`);
  console.log(`  Real-active and overdue/no-next: ${noNext.length}`);
  console.log(`  Real-active with scheduled-but-way-late: ${wayLate.length}`);

  console.log(`\n=== A. NO upcoming visit + ACTIVE in Airtable — REAL action items (${noNext.length}) ===`);
  console.log(`client    | svc | freq | AT active | last done   | should-have-been-by | days overdue | name`);
  console.log(`----------|-----|------|-----------|-------------|---------------------|--------------|------`);
  for (const r of noNext) {
    console.log(`${r.client_code.padEnd(10)}| ${r.service_type.padEnd(3)} | ${String(r.freq).padStart(4)} | ${r.active_state.padEnd(9)} | ${r.last_done}  | ${r.expected_next}          | ${String(r.slip_days).padStart(12)} | ${r.name.slice(0, 35)}`);
  }

  console.log(`\n=== B. Has upcoming but scheduled WAY late + ACTIVE — REAL action items (${wayLate.length}) ===`);
  console.log(`client    | svc | freq | AT active | last done   | expected next  | actual next    | slip | name`);
  console.log(`----------|-----|------|-----------|-------------|----------------|----------------|------|------`);
  for (const r of wayLate) {
    console.log(`${r.client_code.padEnd(10)}| ${r.service_type.padEnd(3)} | ${String(r.freq).padStart(4)} | ${r.active_state.padEnd(9)} | ${r.last_done}  | ${r.expected_next}     | ${r.actual_next}     | ${String(r.slip_days).padStart(4)} | ${r.name.slice(0, 30)}`);
  }

  console.log(`\n=== Skipped (Airtable PAUSED or INACTIVE — informational only) ===`);
  for (const r of skipped) {
    console.log(`  [${r.active_state}] ${r.client_code} ${r.service_type}  last=${r.last_done}  ${r.name.slice(0, 40)}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
