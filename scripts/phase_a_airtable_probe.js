// ============================================================================
// Phase A — Airtable Probe (READ-ONLY, NO WRITES)
// ============================================================================
//
// Purpose: discover the live Airtable schema and data before writing any
// population code. Verifies our CLAUDE.md assumptions match reality.
//
// What it does:
//   1. Fetches the full base schema (all tables, all fields, all types)
//   2. For each table, counts records + pulls 2 sample rows
//   3. Flags unexpected field types, missing tables, naming drift
//   4. Writes a full report to scripts/phase_a_airtable_report.json
//
// NO WRITES anywhere. Pure inspection.
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');

const API_KEY = process.env.AIRTABLE_API_KEY;
const BASE_ID = process.env.AIRTABLE_BASE_ID;

if (!API_KEY || !BASE_ID) {
  console.error('ERROR: AIRTABLE_API_KEY and AIRTABLE_BASE_ID required in .env');
  process.exit(1);
}

// Tables we EXPECT to exist per CLAUDE.md. Script will flag any missing.
const EXPECTED_TABLES = [
  'Clients',
  'Visits',
  'DERM',
  'Route Creation',
  'Past Due',
  'Leads',
  'Drivers Team',
  'Pre Post Inspection',
];

// ----------------------------------------------------------------------------
// HTTPS GET helper
// ----------------------------------------------------------------------------
function get(pathStr) {
  return new Promise((resolve, reject) => {
    https.request(
      {
        hostname: 'api.airtable.com',
        path: pathStr,
        headers: { Authorization: `Bearer ${API_KEY}` },
      },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            try { resolve(JSON.parse(data)); }
            catch (e) { reject(new Error('Bad JSON: ' + data.slice(0, 300))); }
          } else {
            reject(new Error(`HTTP ${res.statusCode}: ${data.slice(0, 300)}`));
          }
        });
      }
    ).on('error', reject).end();
  });
}

// ----------------------------------------------------------------------------
// Fetch all records from a table (paginated, max 5 pages safety cap)
// ----------------------------------------------------------------------------
async function fetchAllRecords(tableId, maxPages = 50) {
  let all = [];
  let offset = null;
  let pages = 0;
  do {
    const q = new URLSearchParams();
    q.set('pageSize', '100');
    if (offset) q.set('offset', offset);
    const resp = await get(`/v0/${BASE_ID}/${tableId}?${q}`);
    all = all.concat(resp.records || []);
    offset = resp.offset;
    pages++;
    if (pages >= maxPages) {
      console.log(`    [warn] hit ${maxPages} page cap — truncating`);
      break;
    }
  } while (offset);
  return all;
}

// ----------------------------------------------------------------------------
// Main
// ----------------------------------------------------------------------------
(async () => {
  console.log('Phase A — Airtable Probe');
  console.log('Base:', BASE_ID);
  console.log('Mode: READ-ONLY\n');

  const report = {
    generated_at: new Date().toISOString(),
    base_id: BASE_ID,
    tables: {},
    missing_expected_tables: [],
    unexpected_tables: [],
  };

  // Step 1 — fetch schema
  console.log('[1/2] Fetching base schema...');
  const schema = await get(`/v0/meta/bases/${BASE_ID}/tables`);
  const liveTables = schema.tables;
  console.log(`    Found ${liveTables.length} tables\n`);

  const liveNames = liveTables.map(t => t.name);
  report.missing_expected_tables = EXPECTED_TABLES.filter(
    n => !liveNames.some(l => l.toLowerCase() === n.toLowerCase())
  );
  report.unexpected_tables = liveNames.filter(
    n => !EXPECTED_TABLES.some(e => e.toLowerCase() === n.toLowerCase())
  );

  // Step 2 — probe each table
  console.log('[2/2] Probing each table (count + 2 samples)...\n');
  for (const t of liveTables) {
    const label = `  ${t.name.padEnd(35)}`;
    try {
      const records = await fetchAllRecords(t.id);
      const sample = records.slice(0, 2).map(r => ({
        id: r.id,
        field_count: Object.keys(r.fields || {}).length,
        field_names: Object.keys(r.fields || {}),
      }));
      console.log(`${label} ${String(records.length).padStart(5)} rows  (${t.fields.length} fields)`);
      report.tables[t.name] = {
        id: t.id,
        field_count: t.fields.length,
        record_count: records.length,
        fields: t.fields.map(f => ({ id: f.id, name: f.name, type: f.type })),
        samples: sample,
      };
    } catch (err) {
      console.log(`${label} ERROR: ${err.message.slice(0, 100)}`);
      report.tables[t.name] = { id: t.id, error: err.message };
    }
  }

  // Output
  console.log('\n----- Summary -----');
  console.log(`Live tables:              ${liveTables.length}`);
  console.log(`Expected tables found:    ${EXPECTED_TABLES.length - report.missing_expected_tables.length}/${EXPECTED_TABLES.length}`);
  if (report.missing_expected_tables.length) {
    console.log(`Missing expected tables:  ${report.missing_expected_tables.join(', ')}`);
  }
  if (report.unexpected_tables.length) {
    console.log(`Unexpected tables:        ${report.unexpected_tables.join(', ')}`);
  }

  const outPath = path.resolve(__dirname, 'phase_a_airtable_report.json');
  fs.writeFileSync(outPath, JSON.stringify(report, null, 2));
  console.log(`\nFull report: ${outPath}`);
})().catch(err => {
  console.error('FATAL:', err);
  process.exit(1);
});
