// Backfill derm_manifests.{derm_manifest_url, derm_address_url} from AT.
// One-shot. For each derm_manifest in canonical, look up its AT record via
// entity_source_links and copy the attachment URLs.
//
// STOP-GAP: stores AT-signed URLs which expire in hours. Follow-up to migrate
// to Supabase Storage.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const SBX1 = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const FP   = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;
const PAT  = process.env.SUPABASE_PAT;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const DERM_TABLE = 'tblz0CnWim7ViFjcw';

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({status: r.statusCode, body: Buffer.concat(c).toString()}));
    });
    req.on('error', rej);
    if (body) req.write(body);
    req.end();
  });
}
async function pg(sql, project = PROD) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${project}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${project} ${r.status}: ${r.body.slice(0, 300)}`);
  return JSON.parse(r.body);
}

// Page through Airtable DERM table, return Map<recordId, {derm_manifest_url, derm_address_url}>
async function fetchAllDermFromAT() {
  const out = new Map();
  let offset;
  do {
    const url = `/v0/${AT_BASE}/${DERM_TABLE}?pageSize=100&fields%5B%5D=${encodeURIComponent('DERM Manifest')}&fields%5B%5D=${encodeURIComponent('DERM Address')}` + (offset ? `&offset=${encodeURIComponent(offset)}` : '');
    const r = await http({
      hostname: 'api.airtable.com', path: url, method: 'GET',
      headers: { Authorization: `Bearer ${AT_KEY}` }
    });
    if (r.status >= 300) throw new Error(`AT ${r.status}: ${r.body.slice(0, 300)}`);
    const j = JSON.parse(r.body);
    for (const rec of (j.records || [])) {
      const dermManifestUrl = rec.fields?.['DERM Manifest']?.[0]?.url || null;
      const dermAddressUrl  = rec.fields?.['DERM Address']?.[0]?.url  || null;
      out.set(rec.id, { dermManifestUrl, dermAddressUrl });
    }
    offset = j.offset;
  } while (offset);
  return out;
}

(async () => {
  console.log('Pulling all DERM records from Airtable...');
  const atMap = await fetchAllDermFromAT();
  console.log(`  ${atMap.size} DERM records from AT`);
  console.log(`  with DERM Manifest attachment: ${[...atMap.values()].filter(v => v.dermManifestUrl).length}`);
  console.log(`  with DERM Address attachment:  ${[...atMap.values()].filter(v => v.dermAddressUrl).length}`);

  console.log('\nReading our derm_manifests + AT mapping from entity_source_links (Prod)...');
  const links = await pg(`
    SELECT esl.entity_id, esl.source_id AS at_record_id
    FROM entity_source_links esl
    WHERE esl.entity_type = 'derm_manifest' AND esl.source_system = 'airtable';
  `);
  console.log(`  ${links.length} canonical derm_manifests linked to AT`);

  console.log('\nBuilding update batch...');
  const updates = [];
  for (const { entity_id, at_record_id } of links) {
    const at = atMap.get(at_record_id);
    if (!at) continue;
    if (!at.dermManifestUrl && !at.dermAddressUrl) continue;
    updates.push({ id: entity_id, dermManifestUrl: at.dermManifestUrl, dermAddressUrl: at.dermAddressUrl });
  }
  console.log(`  ${updates.length} canonical rows have at least one attachment URL`);

  if (!updates.length) { console.log('Nothing to write.'); return; }

  // Build a single UPDATE ... FROM VALUES statement on Prod
  const values = updates.map(u => {
    const m = u.dermManifestUrl ? "'" + u.dermManifestUrl.replace(/'/g, "''") + "'" : 'NULL';
    const a = u.dermAddressUrl  ? "'" + u.dermAddressUrl.replace(/'/g, "''")  + "'" : 'NULL';
    return `(${u.id}, ${m}, ${a})`;
  }).join(',');
  const sql = `
    UPDATE derm_manifests dm
    SET derm_manifest_url = src.derm_manifest_url,
        derm_address_url  = src.derm_address_url
    FROM (VALUES ${values}) AS src(id, derm_manifest_url, derm_address_url)
    WHERE dm.id = src.id;
  `;

  console.log('\nWriting to Prod...');
  await pg(sql, PROD);
  console.log('  Prod: done');
  console.log('\nWriting to Sandbox #1...');
  await pg(sql, SBX1);
  console.log('  Sandbox #1: done');
  console.log('\nWriting to Field Portal (only rows whose id exists there)...');
  // Field Portal has a subset — apply same UPDATE; rows whose id doesn't exist are no-ops
  await pg(sql, FP);
  console.log('  Field Portal: done');

  console.log('\n=== Verify visit 1619 manifest (Prod) ===');
  console.log(await pg(`
    SELECT id, white_manifest_number, derm_manifest_url IS NOT NULL AS has_manifest_doc, derm_address_url IS NOT NULL AS has_address_doc
    FROM derm_manifests
    WHERE id IN (SELECT manifest_id FROM manifest_visits WHERE visit_id = 1619);
  `, PROD));

  console.log('\n=== Coverage check across all 3 DBs ===');
  for (const [name, id] of [['Prod', PROD], ['Sandbox #1', SBX1], ['Field Portal', FP]]) {
    const r = await pg(`
      SELECT
        COUNT(*)::int AS total,
        COUNT(derm_manifest_url)::int AS with_manifest_url,
        COUNT(derm_address_url)::int AS with_address_url
      FROM derm_manifests;
    `, id);
    console.log(`  ${name}:`, r[0]);
  }
})().catch(e => { console.error('FATAL:', e); process.exit(2); });
