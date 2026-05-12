// Classify each gidless client: does a Jobber-linked sibling with the same
// client_code exist? If yes → mergeable. If not → orphan (just delete).
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log('=== Gidless clients — does each have a Jobber-linked sibling by client_code? ===');
  const rows = await q(`
    SELECT
      gl.id AS gidless_id,
      gl.client_code AS code,
      gl.name AS gidless_name,
      gl.status AS gidless_status,
      jl.id AS jobber_keeper_id,
      jl.name AS keeper_name,
      jl.status AS keeper_status,
      (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=gl.id AND source_system='airtable' LIMIT 1) AS gidless_at_id,
      (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=jl.id AND source_system='airtable' LIMIT 1) AS keeper_at_id
    FROM clients gl
    LEFT JOIN LATERAL (
      SELECT c.id, c.name, c.status FROM clients c
      WHERE c.client_code = gl.client_code
        AND c.id <> gl.id
        AND EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='jobber')
      ORDER BY c.id LIMIT 1
    ) jl ON true
    WHERE NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='client' AND entity_id=gl.id AND source_system='jobber')
    ORDER BY gl.id;
  `);
  console.table(rows.map(r => ({
    gidless: r.gidless_id,
    code: r.code,
    keeper: r.jobber_keeper_id,
    gidless_at: r.gidless_at_id ? r.gidless_at_id.slice(0,18) : null,
    keeper_has_at: !!r.keeper_at_id,
    name: (r.gidless_name || '').slice(0, 32),
  })));

  const mergeable = rows.filter(r => r.jobber_keeper_id);
  const orphans = rows.filter(r => !r.jobber_keeper_id);
  console.log(`\n  Mergeable (gidless has Jobber-linked sibling): ${mergeable.length}`);
  console.log(`  Orphans (gidless with no sibling, just delete): ${orphans.length}`);

  console.log('\n=== Mergeable conflicts: gidless has AT ESL, keeper ALSO has AT ESL? ===');
  const conflicts = mergeable.filter(r => r.gidless_at_id && r.keeper_at_id);
  console.log(`  ${conflicts.length} conflicts (both rows have an Airtable ESL — different ones)`);
  if (conflicts.length) console.table(conflicts.map(r => ({ code: r.code, gidless: r.gidless_id, keeper: r.jobber_keeper_id, gidless_at: r.gidless_at_id, keeper_at: r.keeper_at_id })));

  console.log('\n=== FK row counts on gidless clients (data we\'d carry over on merge) ===');
  console.table(await q(`
    WITH gidless AS (
      SELECT id FROM clients c
      WHERE NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='jobber')
    )
    SELECT 'visits' AS tbl, COUNT(*) FROM visits WHERE client_id IN (SELECT id FROM gidless)
    UNION ALL SELECT 'properties', COUNT(*) FROM properties WHERE client_id IN (SELECT id FROM gidless)
    UNION ALL SELECT 'jobs', COUNT(*) FROM jobs WHERE client_id IN (SELECT id FROM gidless)
    UNION ALL SELECT 'invoices', COUNT(*) FROM invoices WHERE client_id IN (SELECT id FROM gidless)
    UNION ALL SELECT 'service_configs', COUNT(*) FROM service_configs WHERE client_id IN (SELECT id FROM gidless)
    UNION ALL SELECT 'client_contacts', COUNT(*) FROM client_contacts WHERE client_id IN (SELECT id FROM gidless)
    UNION ALL SELECT 'derm_manifests', COUNT(*) FROM derm_manifests WHERE client_id IN (SELECT id FROM gidless)
    UNION ALL SELECT 'notes', COUNT(*) FROM notes WHERE client_id IN (SELECT id FROM gidless)
    UNION ALL SELECT 'quotes', COUNT(*) FROM quotes WHERE client_id IN (SELECT id FROM gidless)
    UNION ALL SELECT 'jobber_oversized_attachments', COUNT(*) FROM jobber_oversized_attachments WHERE client_id IN (SELECT id FROM gidless);
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
