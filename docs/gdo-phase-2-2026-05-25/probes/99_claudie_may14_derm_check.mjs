// 99_claudie_may14_derm_check.mjs
// DERM Tracker shows 110-CLA Claudie 2026-05-14 as "Missing manifest" but
// Fred says AT has the DERM. Investigate:
//   1. Find the visit in DB
//   2. Check manifest_visits links + any candidate manifests for Claudie
//   3. Search AT DERM table for any record referencing Claudie or that date

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
const banner = (s) => console.log(`\n${'='.repeat(70)}\n${s}\n${'='.repeat(70)}`);

banner('1. Claudie visit 2026-05-14 in DB');
console.log(await pg(`
  SELECT v.id, v.visit_date, v.visit_status, v.service_type, v.title,
         v.completed_at, v.derm_required, c.client_code, c.name
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  WHERE c.client_code = '110-CLA'
    AND v.visit_date BETWEEN '2026-05-12' AND '2026-05-16'
  ORDER BY v.visit_date;
`));

banner('2. Existing manifest_visits links for those visits');
console.log(await pg(`
  SELECT mv.visit_id, mv.manifest_id, dm.white_manifest_number,
         dm.service_date, dm.derm_manifest_url IS NOT NULL AS has_pdf
  FROM public.manifest_visits mv
  JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
  JOIN public.visits v ON v.id = mv.visit_id
  JOIN public.clients c ON c.id = v.client_id
  WHERE c.client_code = '110-CLA'
    AND v.visit_date BETWEEN '2026-05-12' AND '2026-05-16';
`));

banner('3. All derm_manifests for Claudie (client 110-CLA)');
console.log(await pg(`
  SELECT dm.id, dm.service_date, dm.white_manifest_number,
         dm.derm_manifest_url IS NOT NULL AS has_pdf,
         dm.created_at
  FROM public.derm_manifests dm
  JOIN public.clients c ON c.id = dm.client_id
  WHERE c.client_code = '110-CLA'
  ORDER BY dm.service_date DESC NULLS LAST
  LIMIT 10;
`));

banner('4. Find Claudie client_id + AT GID');
console.log(await pg(`
  SELECT c.id, c.client_code, c.name,
         (SELECT source_id FROM public.entity_source_links
          WHERE entity_type='client' AND entity_id=c.id AND source_system='airtable') AS at_gid,
         (SELECT source_id FROM public.entity_source_links
          WHERE entity_type='client' AND entity_id=c.id AND source_system='jobber') AS jb_gid
  FROM public.clients c WHERE c.client_code='110-CLA';
`));

banner('5. Search AT DERM table for Claudie-related records');
const at = await fetchAll('DERM');
const claudieRecs = at.filter(r => {
  const f = r.fields || {};
  const code = (f['Client Code #3 (from Client)'] || [''])[0];
  const name = (f['Client Name (from Client)'] || [''])[0];
  return code === '110-CLA' || /claudie/i.test(name);
});
console.log(`  ${claudieRecs.length} AT DERM records for Claudie`);
claudieRecs.forEach(r => {
  const f = r.fields || {};
  const m = f['White Manifest #'] || f['White Manifest Number'] || f['Manifest #'] || '—';
  const dump = f['Date Dump Ticket'] || '—';
  const gtLast = f['GT Last Visit'] || '—';
  const visits = (f['Visits'] || []).slice(0, 3);
  const date = f['Date'] || f['Service Date'] || '—';
  console.log(`  ${r.id}  WM#${String(m).padEnd(8)}  GT Last Visit=${gtLast}  Dump=${dump}  Date=${date}  Visits=${JSON.stringify(visits)}`);
});

banner('6. For each AT DERM record, look at the AT Visits referenced');
for (const r of claudieRecs.slice(0, 5)) {
  const f = r.fields || {};
  const visitGids = (f['Visits'] || []);
  if (visitGids.length === 0) continue;
  console.log(`\n  AT DERM ${r.id} → Visits: ${JSON.stringify(visitGids)}`);
  for (const vg of visitGids.slice(0, 3)) {
    // Look up the AT visit record
    const url = `https://api.airtable.com/v0/${AT_BASE}/Visits/${vg}`;
    try {
      const resp = await fetch(url, { headers: { Authorization: `Bearer ${AT_KEY}` } });
      if (resp.ok) {
        const v = await resp.json();
        const vf = v.fields || {};
        console.log(`    Visit ${vg}: Date=${vf['Date'] || vf['Service Date'] || '?'} Client=${(vf['Client Name (from Client)'] || ['?'])[0]}`);
      } else {
        console.log(`    Visit ${vg}: HTTP ${resp.status}`);
      }
    } catch (e) {
      console.log(`    Visit ${vg}: ERR ${e.message}`);
    }
  }
}

banner('7. Whatever AT DERM is for May 14, did our DB derm_manifests get it?');
const may14 = claudieRecs.find(r => {
  const f = r.fields || {};
  return (f['GT Last Visit'] || '').startsWith('2026-05-14') ||
         (f['Date Dump Ticket'] || '').startsWith('2026-05-14') ||
         (f['Date'] || '').startsWith('2026-05-14');
});
if (may14) {
  console.log(`AT DERM for May 14: ${may14.id}`);
  console.log(`  fields:`, JSON.stringify(may14.fields, null, 2).slice(0, 800));
  console.log('\n  Is this AT id in our entity_source_links?');
  console.log(await pg(`
    SELECT esl.entity_id, esl.synced_at
    FROM public.entity_source_links esl
    WHERE esl.entity_type='derm_manifest' AND esl.source_system='airtable' AND esl.source_id='${may14.id}';
  `));
} else {
  console.log('No AT DERM record matched May 14 directly via date fields');
}
