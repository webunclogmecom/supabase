// 97_targeted_derm_replay.mjs
// Targeted re-replay: only AT DERM records created in the last 14 days.
// Captures recent additions + anything updated since the bulk historical
// backfill in probe 87. Skips the 800+ historical records that already mirror
// fine and don't need re-mirroring.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const SB_URL = process.env.SUPABASE_URL;
const TOKEN = process.env.AIRTABLE_WEBHOOK_TOKEN;

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

async function replay(rec) {
  const r = await fetch(`${SB_URL}/functions/v1/webhook-airtable`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ entity: 'derm_manifest', recordId: rec.id, fields: rec.fields, changeType: 'updated' }),
  });
  return { status: r.status, body: (await r.text()).slice(0, 200) };
}

const before = await pg(`
  SELECT (SELECT COUNT(*)::int FROM public.derm_manifests) AS m,
         (SELECT COUNT(*)::int FROM public.entity_source_links
          WHERE entity_type='derm_manifest' AND source_system='airtable') AS l;
`);
console.log('Before:', before);

const cutoff = new Date(Date.now() - 14 * 24 * 60 * 60 * 1000).toISOString();
console.log(`Targeting AT DERM records with createdTime >= ${cutoff}`);

const at = await fetchAll('DERM');
const targets = at.filter(r => r.createdTime && r.createdTime >= cutoff);
console.log(`Targets: ${targets.length} of ${at.length}`);

let ok = 0, fail = 0;
const failures = [];
const t0 = Date.now();
for (let i = 0; i < targets.length; i++) {
  const r = targets[i];
  const f = r.fields || {};
  const tag = `${(f['Client Code #3 (from Client)'] || ['?'])[0]} ${(f['Client Name (from Client)'] || ['?'])[0]}  #${f['White Manifest #'] || f['White Manifest Number'] || '—'}  ${f['GT Last Visit'] || f['Date'] || '—'}`;
  try {
    const res = await replay(r);
    if (res.status >= 200 && res.status < 300) {
      ok++;
      if (i % 10 === 0 || i === targets.length - 1) {
        const eta = ((Date.now() - t0) / (i + 1)) * (targets.length - i - 1) / 1000;
        console.log(`  [${i+1}/${targets.length}] ${res.status}  ${tag}  (ETA ${eta.toFixed(0)}s)`);
      }
    } else {
      fail++;
      failures.push({ id: r.id, status: res.status, body: res.body });
      console.log(`  [${i+1}/${targets.length}] FAIL ${res.status}  ${r.id}  ${tag}  ${res.body}`);
    }
  } catch (e) {
    fail++;
    failures.push({ id: r.id, error: String(e.message || e) });
  }
}

console.log(`\nReplay finished in ${((Date.now() - t0) / 1000).toFixed(0)}s. ok=${ok} fail=${fail}`);

const after = await pg(`
  SELECT (SELECT COUNT(*)::int FROM public.derm_manifests) AS m,
         (SELECT COUNT(*)::int FROM public.entity_source_links
          WHERE entity_type='derm_manifest' AND source_system='airtable') AS l;
`);
console.log('After:', after);
console.log(`Δ manifests = ${after[0].m - before[0].m}`);
console.log(`Δ AT links  = ${after[0].l - before[0].l}`);
if (failures.length) {
  console.log('\nFailures:'); failures.forEach(f => console.log('  ', f));
}
