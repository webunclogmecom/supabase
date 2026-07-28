// cross_ref_at_derm_vs_db.js
//
// Cross-references Airtable DERM table against our Prod derm_manifests table.
// Reports AT records that aren't linked via entity_source_links (= missing from DB).
//
// Direction: AT → DB (are we missing any AT records in our DB?)
// Method: every AT DERM record has a unique `rec...` ID. We store these in
// public.entity_source_links where entity_type='derm_manifest' AND
// source_system='airtable'. So AT rec_ids NOT present in ESL = missing.

const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env') });

const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

function pg(s) {
  return new Promise((r, j) => {
    const b = JSON.stringify({ query: s });
    const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) } }, rs => { let d=''; rs.on('data',c=>d+=c); rs.on('end',()=>{ if(rs.statusCode>=300) return j(new Error(rs.statusCode+': '+d)); r(JSON.parse(d)); }); });
    req.on('error', j); req.write(b); req.end();
  });
}

function atFetch(p) {
  return new Promise((res, rej) => {
    https.get({ hostname: 'api.airtable.com', path: p, headers: { Authorization: 'Bearer ' + AT_KEY } }, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => {
        if (r.statusCode >= 300) return rej(new Error('AT ' + r.statusCode + ': ' + d.slice(0, 200)));
        res(JSON.parse(d));
      });
    }).on('error', rej);
  });
}

async function atFetchAll(table) {
  let all = [];
  let offset = null;
  do {
    const q = new URLSearchParams({ pageSize: '100' });
    if (offset) q.append('offset', offset);
    const j = await atFetch('/v0/' + AT_BASE + '/' + encodeURIComponent(table) + '?' + q);
    all = all.concat(j.records);
    offset = j.offset;
  } while (offset);
  return all;
}

(async () => {
  console.log('# AT DERM ↔ DB cross-reference — ' + new Date().toISOString() + '\n');

  // 1. Pull every AT DERM record
  console.log('[1] Pulling all AT DERM records...');
  const atRecords = await atFetchAll('DERM');
  console.log('  AT total records:', atRecords.length);

  // 2. Pull all entity_source_links for derm_manifest from Airtable
  console.log('\n[2] Pulling entity_source_links for derm_manifest/airtable...');
  const eslRows = await pg(`
    SELECT source_id, entity_id
    FROM public.entity_source_links
    WHERE entity_type = 'derm_manifest' AND source_system = 'airtable'`);
  console.log('  ESL rows (linked to AT):', eslRows.length);
  const linkedAtIds = new Set(eslRows.map(r => r.source_id));

  // 3. Diff
  const missingInDb = atRecords.filter(r => !linkedAtIds.has(r.id));
  const presentInDb = atRecords.length - missingInDb.length;

  console.log('\n=== Summary ===');
  console.log('AT total:                ', atRecords.length);
  console.log('Present in DB (linked):  ', presentInDb);
  console.log('MISSING from DB:         ', missingInDb.length);
  console.log('% present:               ', ((presentInDb / atRecords.length) * 100).toFixed(1) + '%');

  if (missingInDb.length > 0) {
    console.log('\n=== Missing records (first 20) ===');
    for (const rec of missingInDb.slice(0, 20)) {
      const f = rec.fields || {};
      // Try a few likely field names — adjust per actual AT schema
      const summary = {
        rec_id: rec.id,
        created: rec.createdTime,
        manifest_number: f['White Manifest Number'] || f['Manifest Number'] || f['White Manifest #'] || null,
        service_date: f['Service Date'] || f['Date'] || null,
        dump_date: f['Dump Date'] || f['Dump Ticket Date'] || null,
        client: f['Client Code'] || f['Client'] || f['Client Name'] || null,
      };
      console.log(JSON.stringify(summary));
    }
    if (missingInDb.length > 20) {
      console.log('  ...and ' + (missingInDb.length - 20) + ' more');
    }

    // Time distribution of missing records
    console.log('\n=== Time distribution of missing records (by createdTime month) ===');
    const byMonth = {};
    for (const rec of missingInDb) {
      const m = (rec.createdTime || '').slice(0, 7);
      byMonth[m] = (byMonth[m] || 0) + 1;
    }
    for (const m of Object.keys(byMonth).sort().reverse().slice(0, 12)) {
      console.log('  ' + m + ': ' + byMonth[m]);
    }
  }

  // 4. Inverse: any DB derm_manifests rows without an ESL? (AT-sourced manifests missing the link)
  console.log('\n[3] DB derm_manifests rows lacking AT ESL link...');
  const orphanInDb = await pg(`
    SELECT COUNT(*)::int AS n
    FROM public.derm_manifests dm
    WHERE NOT EXISTS (
      SELECT 1 FROM public.entity_source_links esl
      WHERE esl.entity_type = 'derm_manifest'
        AND esl.entity_id = dm.id
    )`);
  console.log('  DB rows without AT ESL link:', orphanInDb[0].n);
  console.log('  (some of these may be future DERM Tracker-only writes; today AT is still the only writer)');

  // Sample
  const orphanSample = await pg(`
    SELECT id, white_manifest_number, service_date::text, created_at::text
    FROM public.derm_manifests dm
    WHERE NOT EXISTS (SELECT 1 FROM public.entity_source_links esl WHERE esl.entity_type = 'derm_manifest' AND esl.entity_id = dm.id)
    ORDER BY id DESC LIMIT 5`);
  console.log('  Sample orphans (newest first):');
  for (const o of orphanSample) console.log('    ' + JSON.stringify(o));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
