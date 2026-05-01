// Audit + reset all manhole counts: default=0, override with Airtable's
// manholes value where present.
//
// Per Fred 2026-05-01: previous DEFAULT 1 was wrong. Reset to 0 and
// only set higher when Airtable has it explicitly.
//
// Usage:
//   node scripts/probes/audit_and_fix_manholes.js                # dry-run
//   node scripts/probes/audit_and_fix_manholes.js --execute      # apply
//   node scripts/probes/audit_and_fix_manholes.js --execute --target=sandbox
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const target = (process.argv.find(a => a.startsWith('--target=')) || '--target=main').split('=')[1];
const EXECUTE = process.argv.includes('--execute');
const PROJECT = target === 'sandbox' ? process.env.SANDBOX_SUPABASE_PROJECT_ID : process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d }));
    });
    req.on('error', rej);
    if (body) req.write(body);
    req.end();
  });
}

async function pg(sql) {
  const body = JSON.stringify({ query: sql });
  const r = await http({
    hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) throw new Error(`DB ${r.status}: ${r.body.slice(0,400)}`);
  return JSON.parse(r.body);
}

async function airtableFetchAll(tableName) {
  const all = [];
  let offset = null;
  do {
    const q = new URLSearchParams();
    q.set('pageSize', '100');
    if (offset) q.set('offset', offset);
    const r = await http({
      hostname: 'api.airtable.com',
      path: `/v0/${AT_BASE}/${encodeURIComponent(tableName)}?${q}`,
      method: 'GET',
      headers: { Authorization: `Bearer ${AT_KEY}` },
    });
    if (r.status >= 300) throw new Error(`AT ${r.status}: ${r.body.slice(0,200)}`);
    const j = JSON.parse(r.body);
    all.push(...(j.records || []));
    offset = j.offset;
  } while (offset);
  return all;
}

(async () => {
  console.log(`Target: ${target} (${PROJECT})  Mode: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}\n`);

  console.log('=== BEFORE: manhole count distribution ===');
  console.table(await pg(`
    SELECT grease_trap_manhole_count AS count, COUNT(*) AS n_properties
    FROM properties GROUP BY grease_trap_manhole_count ORDER BY count;
  `));

  console.log('\n=== Pulling Airtable Clients with manholes value ===');
  const records = await airtableFetchAll('Clients');
  const withManholes = records.filter(r => {
    const v = r.fields?.manholes;
    return typeof v === 'number' && v >= 0;
  });
  console.log(`  ${records.length} total Airtable Clients · ${withManholes.length} have a manholes value\n`);

  // Map: airtable_record_id → manhole count
  const manholeByAt = new Map();
  for (const r of withManholes) {
    manholeByAt.set(r.id, Math.round(r.fields.manholes));
  }

  // Pull our DB primary properties + their client's Airtable ID
  console.log('=== Pulling our DB primary properties + Airtable links ===');
  const props = await pg(`
    SELECT p.id AS property_id, p.client_id, p.is_primary, p.grease_trap_manhole_count AS current_count,
      c.client_code, c.name,
      (SELECT esl.source_id FROM entity_source_links esl
        WHERE esl.entity_type='client' AND esl.entity_id=p.client_id AND esl.source_system='airtable' LIMIT 1) AS at_id
    FROM properties p JOIN clients c ON c.id = p.client_id;
  `);
  console.log(`  ${props.length} properties total`);

  // Decide target value for each
  const stats = { will_set_from_at: 0, will_zero_no_at: 0, will_zero_at_has_no_value: 0, no_change: 0 };
  const updates = []; // {property_id, target_count, reason}
  for (const p of props) {
    let target_count;
    let reason;
    if (p.at_id && manholeByAt.has(p.at_id)) {
      target_count = manholeByAt.get(p.at_id);
      reason = 'airtable_has_value';
    } else if (p.at_id) {
      target_count = 0;
      reason = 'airtable_linked_but_no_value';
    } else {
      target_count = 0;
      reason = 'no_airtable_link';
    }
    if (target_count !== p.current_count) {
      updates.push({ property_id: p.property_id, target_count, reason, current: p.current_count, code: p.client_code });
    }
    if (reason === 'airtable_has_value') stats.will_set_from_at++;
    else if (reason === 'airtable_linked_but_no_value') stats.will_zero_at_has_no_value++;
    else stats.will_zero_no_at++;
  }

  console.log('\n=== Plan ===');
  console.table([{
    will_change: updates.length,
    no_change: props.length - updates.length,
    set_from_at: stats.will_set_from_at,
    zero_at_no_value: stats.will_zero_at_has_no_value,
    zero_no_at: stats.will_zero_no_at,
  }]);

  // Show samples
  console.log('\n=== Sample changes (first 10) ===');
  console.table(updates.slice(0, 10));

  // Distribution of new target values
  console.log('\n=== Target distribution (after run) ===');
  const dist = {};
  for (const p of props) {
    let t;
    if (p.at_id && manholeByAt.has(p.at_id)) t = manholeByAt.get(p.at_id);
    else t = 0;
    dist[t] = (dist[t] || 0) + 1;
  }
  console.table(Object.entries(dist).sort((a,b) => Number(a[0])-Number(b[0])).map(([v, n]) => ({ count: v, n_properties: n })));

  if (!EXECUTE) {
    console.log('\nDRY-RUN — pass --execute to apply');
    return;
  }

  console.log('\n=== Executing migration ===');

  // Build the SQL: one CASE statement per row would be enormous; use CTE join
  // Apply in batches
  const batchSize = 200;
  let applied = 0;
  for (let i = 0; i < updates.length; i += batchSize) {
    const batch = updates.slice(i, i + batchSize);
    const values = batch.map(u => `(${u.property_id}, ${u.target_count})`).join(',');
    await pg(`
      WITH new_vals(id, c) AS (VALUES ${values})
      UPDATE properties p
      SET grease_trap_manhole_count = new_vals.c
      FROM new_vals
      WHERE p.id = new_vals.id;
    `);
    applied += batch.length;
    if (applied % 1000 === 0) console.log(`  ${applied}/${updates.length}`);
  }
  console.log(`  ✓ ${applied} rows updated`);

  // Change column default from 1 to 0
  console.log('\n=== Changing column default 1 → 0 ===');
  await pg(`ALTER TABLE properties ALTER COLUMN grease_trap_manhole_count SET DEFAULT 0;`);
  console.log('  ✓ default changed');

  console.log('\n=== AFTER: manhole count distribution ===');
  console.table(await pg(`
    SELECT grease_trap_manhole_count AS count, COUNT(*) AS n_properties
    FROM properties GROUP BY grease_trap_manhole_count ORDER BY count;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
