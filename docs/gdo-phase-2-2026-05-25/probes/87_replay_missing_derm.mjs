// 87_replay_missing_derm.mjs
// Replay the 49 missing AT DERM records through webhook-airtable.
// Idempotent: webhook handles INSERT-or-UPDATE + entity_source_links creation.
// Tracks per-record outcome.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const SB_URL = process.env.SUPABASE_URL;
const TOKEN = process.env.AIRTABLE_WEBHOOK_TOKEN;
if (!TOKEN || !SB_URL) throw new Error('AIRTABLE_WEBHOOK_TOKEN / SUPABASE_URL missing');

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
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${TOKEN}`,
    },
    body: JSON.stringify({
      entity: 'derm_manifest',
      recordId: rec.id,
      fields: rec.fields,
      changeType: 'updated',
    }),
  });
  return { status: r.status, body: (await r.text()).slice(0, 300) };
}

// ------- preflight: snapshot state before -------
const before = await pg(`
  SELECT
    (SELECT COUNT(*)::int FROM public.derm_manifests) AS manifests,
    (SELECT COUNT(*)::int FROM public.entity_source_links
     WHERE entity_type='derm_manifest' AND source_system='airtable') AS at_links;
`);
console.log('=== Before ===');
console.log(before);

// ------- compute the 49 target records -------
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
console.log(`\n=== Replaying ${targets.length} AT DERM records ===`);

let ok = 0, fail = 0;
const failures = [];
for (let i = 0; i < targets.length; i++) {
  const r = targets[i];
  const f = r.fields;
  const label = `${(f['Client Code #3 (from Client)'] || ['?'])[0]} ${(f['Client Name (from Client)'] || ['?'])[0]}  #${f['White Manifest #'] || f['White Manifest Number'] || f['Manifest #']}  ${f['GT Last Visit'] || f['Date']}`;
  try {
    const res = await replay(r);
    if (res.status >= 200 && res.status < 300) {
      ok++;
      console.log(`  [${i+1}/${targets.length}] ${res.status}  ${r.id}  ${label}`);
    } else {
      fail++;
      failures.push({ id: r.id, label, status: res.status, body: res.body });
      console.log(`  [${i+1}/${targets.length}] FAIL ${res.status}  ${r.id}  ${label}\n    body: ${res.body}`);
    }
  } catch (e) {
    fail++;
    failures.push({ id: r.id, label, error: String(e.message || e) });
    console.log(`  [${i+1}/${targets.length}] ERR  ${r.id}  ${label}  — ${e.message}`);
  }
  // small pacing — avoid overwhelming the webhook (it does cascaded inserts/links)
  await new Promise(s => setTimeout(s, 120));
}

console.log(`\n=== Replay totals: ok=${ok}  fail=${fail} ===`);

// ------- postflight: state after -------
const after = await pg(`
  SELECT
    (SELECT COUNT(*)::int FROM public.derm_manifests) AS manifests,
    (SELECT COUNT(*)::int FROM public.entity_source_links
     WHERE entity_type='derm_manifest' AND source_system='airtable') AS at_links;
`);
console.log('\n=== After ===');
console.log(after);
console.log(`\nΔ derm_manifests = ${after[0].manifests - before[0].manifests}`);
console.log(`Δ AT links       = ${after[0].at_links - before[0].at_links}`);

// ------- re-audit: how many AT DERMs still unlinked? -------
const stillMissing = await pg(`
  SELECT COUNT(*)::int AS still_unlinked
  FROM public.entity_source_links
  WHERE entity_type='derm_manifest' AND source_system='airtable';
`);
console.log('\nFinal AT-linked DERM count:', stillMissing);

if (failures.length > 0) {
  console.log(`\n=== ${failures.length} failures ===`);
  failures.forEach(f => console.log('  ', f));
}
