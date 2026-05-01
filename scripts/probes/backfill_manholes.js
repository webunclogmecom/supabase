// Backfill properties.grease_trap_manhole_count from Airtable Clients.manholes
//
// Per Yannick 2026-04-30: he added a `manholes` field on the Airtable Clients
// table. This one-shot pulls those values + UPDATEs each client's PRIMARY
// property in our DB.
//
// Usage:
//   node scripts/probes/backfill_manholes.js                  # default: production
//   node scripts/probes/backfill_manholes.js --target=main    # explicit production
//   node scripts/probes/backfill_manholes.js --target=sandbox # against the Sandbox
//
// Idempotent. Re-running just re-applies the same UPDATE — safe.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const target = (process.argv.find(a => a.startsWith('--target=')) || '--target=main').split('=')[1];
const projectId = target === 'sandbox'
  ? process.env.SANDBOX_SUPABASE_PROJECT_ID
  : process.env.SUPABASE_PROJECT_ID;
const pat = process.env.SUPABASE_PAT;
if (!projectId) { console.error(`No project ID for target=${target}`); process.exit(1); }
if (!pat) { console.error('SUPABASE_PAT missing'); process.exit(1); }

console.log(`[target=${target}] project_id=${projectId}\n`);

function httpRequest(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d }));
    });
    req.on('error', rej);
    req.setTimeout(30000, () => req.destroy(new Error('timeout')));
    if (body) req.write(body);
    req.end();
  });
}

async function sbQuery(sql) {
  const body = JSON.stringify({ query: sql });
  const r = await httpRequest({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${projectId}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${pat}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) throw new Error(`DB ${r.status}: ${r.body.slice(0, 400)}`);
  return JSON.parse(r.body);
}

async function airtableFetchAll(tableName) {
  const all = [];
  let offset = null, pages = 0;
  do {
    const q = new URLSearchParams();
    q.set('pageSize', '100');
    if (offset) q.set('offset', offset);
    const r = await httpRequest({
      hostname: 'api.airtable.com',
      path: `/v0/${process.env.AIRTABLE_BASE_ID}/${encodeURIComponent(tableName)}?${q}`,
      method: 'GET',
      headers: { Authorization: `Bearer ${process.env.AIRTABLE_API_KEY}` },
    });
    if (r.status >= 300) throw new Error(`AT ${r.status}: ${r.body.slice(0, 200)}`);
    const j = JSON.parse(r.body);
    all.push(...(j.records || []));
    offset = j.offset;
    pages++;
    if (pages > 50) break;
  } while (offset);
  return all;
}

(async () => {
  // 1. Verify the column exists on the target
  console.log('Checking that properties.grease_trap_manhole_count exists on target...');
  const cols = await sbQuery(`
    SELECT column_name FROM information_schema.columns
    WHERE table_schema='public' AND table_name='properties' AND column_name='grease_trap_manhole_count';
  `);
  if (!cols.length) {
    console.error(`❌ properties.grease_trap_manhole_count missing on target=${target}.`);
    console.error(`   Apply migration first: node scripts/probes/apply_manhole_migration.js (with --target=${target} support)`);
    process.exit(1);
  }
  console.log('  ✓ column present\n');

  // 2. Pull Airtable Clients records that have a manholes value
  console.log('Pulling Airtable Clients with manholes field...');
  const records = await airtableFetchAll('Clients');
  const withManholes = records.filter(r => {
    const v = r.fields?.manholes;
    return typeof v === 'number' && v >= 0;
  });
  console.log(`  ${records.length} total Airtable Clients · ${withManholes.length} have a manholes value set\n`);

  if (!withManholes.length) {
    console.log('Nothing to backfill yet — Yannick has not filled in the manholes field for any client.');
    process.exit(0);
  }

  // 3. For each AT record with manholes: find our client_id via ESL, then UPDATE primary property
  console.log('Updating primary properties...\n');
  let updated = 0, skipped_no_client = 0, skipped_no_primary = 0, errors = 0;

  for (const rec of withManholes) {
    const atId = rec.id;
    const manholes = Math.round(rec.fields.manholes);
    const name = rec.fields['Client Name'] || rec.fields['CLIENT XX'] || atId;

    try {
      // Find client_id via ESL
      const escAt = atId.replace(/'/g, "''");
      const clientLookup = await sbQuery(`
        SELECT entity_id AS client_id FROM entity_source_links
        WHERE entity_type='client' AND source_system='airtable' AND source_id='${escAt}' LIMIT 1;
      `);
      if (!clientLookup.length) {
        skipped_no_client++;
        continue;
      }
      const clientId = clientLookup[0].client_id;

      // Update primary property
      const result = await sbQuery(`
        UPDATE properties
        SET grease_trap_manhole_count = ${manholes}
        WHERE client_id = ${clientId} AND is_primary = TRUE
        RETURNING id, address;
      `);
      if (!result.length) {
        skipped_no_primary++;
        console.log(`  ⚠ no primary property for client_id=${clientId} ("${name}", manholes=${manholes})`);
        continue;
      }
      updated++;
      if (updated <= 10) {
        console.log(`  ✓ "${name}" → property #${result[0].id} (${result[0].address}) manholes=${manholes}`);
      }
    } catch (e) {
      errors++;
      console.log(`  ✗ "${name}": ${e.message.slice(0, 100)}`);
    }
  }

  console.log(`\nSummary:`);
  console.log(`  updated:               ${updated}`);
  console.log(`  skipped (no client):   ${skipped_no_client}`);
  console.log(`  skipped (no primary):  ${skipped_no_primary}`);
  console.log(`  errors:                ${errors}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
