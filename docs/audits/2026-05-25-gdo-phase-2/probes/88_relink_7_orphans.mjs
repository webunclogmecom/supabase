// 88_relink_7_orphans.mjs
// The 7 AT DERM records that didn't link after replay because the webhook's
// dedup-on-insert path returns early without creating the entity_source_links
// row when it finds a matching (client_id, manifest_number) already in DB.
//
// For each of those 7 AT records, find the matching DB derm_manifest by
// (client_id from AT client_code, white_manifest_number). If that DB row has
// NO existing AT link, INSERT one pointing to the AT record id.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${(await r.text()).slice(0, 600)}`);
  return JSON.parse(await r.text());
}

async function fetchAll(table) {
  const all = [];
  let offset = null;
  do {
    const q = new URLSearchParams();
    q.set('pageSize', '100');
    if (offset) q.set('offset', offset);
    const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/${encodeURIComponent(table)}?${q}`, {
      headers: { Authorization: `Bearer ${AT_KEY}` },
    });
    const j = await r.json();
    all.push(...(j.records || []));
    offset = j.offset;
  } while (offset);
  return all;
}

const linked = await pg(`
  SELECT source_id FROM public.entity_source_links
  WHERE entity_type='derm_manifest' AND source_system='airtable';
`);
const linkedSet = new Set(linked.map(r => r.source_id));

const at = await fetchAll('DERM');
const targets = at.filter(r => {
  if (linkedSet.has(r.id)) return false;
  const f = r.fields || {};
  const m = f['White Manifest #'] || f['White Manifest Number'] || f['Manifest #'] || null;
  const d = f['GT Last Visit'] || f['Date'] || f['Service Date'] || null;
  const county = Array.isArray(f['County']) ? f['County'][0] : f['County'];
  return m && /^\d{3,}$/.test(String(m).trim())
    && d && /^\d{4}-\d{2}-\d{2}/.test(d)
    && !/broward/i.test(String(county || ''));
});
console.log(`AT records still unlinked: ${targets.length}`);

let added = 0, conflict = 0, noMatch = 0;
const details = [];

for (const r of targets) {
  const f = r.fields;
  const manifest = String(f['White Manifest #'] || f['White Manifest Number'] || f['Manifest #']).trim();
  const code = (f['Client Code #3 (from Client)'] || [''])[0];
  const atClientGid = (f['Client'] || [null])[0];

  // Resolve client_id via AT client GID → entity_source_links → clients.id
  let clientRow = null;
  if (atClientGid) {
    const got = await pg(`
      SELECT esl.entity_id AS client_id, c.client_code, c.name
      FROM public.entity_source_links esl
      JOIN public.clients c ON c.id = esl.entity_id
      WHERE esl.entity_type='client' AND esl.source_system='airtable' AND esl.source_id='${atClientGid}'
      LIMIT 1;
    `);
    if (got.length) clientRow = got[0];
  }
  // Fallback by client_code
  if (!clientRow && code) {
    const got = await pg(`
      SELECT id AS client_id, client_code, name FROM public.clients WHERE client_code='${code.replace(/'/g, "''")}'
      LIMIT 1;
    `);
    if (got.length) clientRow = got[0];
  }
  if (!clientRow) {
    noMatch++;
    details.push({ at_id: r.id, manifest, code, status: 'no_client_match' });
    continue;
  }

  // Find matching DB derm_manifest row by (client_id, manifest_number)
  const dbRow = await pg(`
    SELECT id FROM public.derm_manifests
    WHERE client_id=${clientRow.client_id} AND white_manifest_number='${manifest.replace(/'/g, "''")}'
    LIMIT 1;
  `);
  if (!dbRow.length) {
    noMatch++;
    details.push({ at_id: r.id, manifest, code, status: 'no_db_match' });
    continue;
  }
  const manifestId = dbRow[0].id;

  // Does this DB row already have an AT link to a DIFFERENT AT id?
  const existingLink = await pg(`
    SELECT source_id FROM public.entity_source_links
    WHERE entity_type='derm_manifest' AND entity_id=${manifestId} AND source_system='airtable'
    LIMIT 1;
  `);
  if (existingLink.length) {
    conflict++;
    details.push({ at_id: r.id, manifest, code, manifest_id: manifestId, conflict_with: existingLink[0].source_id });
    continue;
  }

  // Insert the link
  await pg(`
    INSERT INTO public.entity_source_links (entity_type, entity_id, source_system, source_id, synced_at)
    VALUES ('derm_manifest', ${manifestId}, 'airtable', '${r.id}', NOW());
  `);
  added++;
  details.push({ at_id: r.id, manifest, code, manifest_id: manifestId, status: 'linked' });
}

console.log(`\nadded=${added}  conflict=${conflict}  no_match=${noMatch}`);
console.log('\nDetails:');
details.forEach(d => console.log(' ', JSON.stringify(d)));

// Final state check
const final = await pg(`
  SELECT COUNT(*)::int AS at_links FROM public.entity_source_links
  WHERE entity_type='derm_manifest' AND source_system='airtable';
`);
console.log('\nFinal AT-linked derm_manifest count:', final);
