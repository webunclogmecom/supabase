// 120_backfill_multipage.mjs
// Replay AT DERM records that have 2+ pages of attachments through the
// patched webhook so the new derm_*_extra_urls columns get populated +
// pages 2+ are mirrored to Storage.
import 'dotenv/config';
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const SB_URL = process.env.SUPABASE_URL;
const TOKEN = process.env.AIRTABLE_WEBHOOK_TOKEN;
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${(await r.text()).slice(0, 500)}`);
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
  SELECT
    COUNT(*) FILTER (WHERE array_length(derm_manifest_extra_urls, 1) > 0)::int AS m_extra_pop,
    COUNT(*) FILTER (WHERE array_length(derm_address_extra_urls, 1) > 0)::int AS a_extra_pop
  FROM public.derm_manifests;
`);
console.log('Before:', before);

const at = await fetchAll('DERM');
const targets = at.filter(r => {
  const f = r.fields || {};
  const m = Array.isArray(f['DERM Manifest']) ? f['DERM Manifest'].length : 0;
  const a = Array.isArray(f['DERM Address']) ? f['DERM Address'].length : 0;
  return m >= 2 || a >= 2;
});
console.log(`Targets: ${targets.length} of ${at.length}`);

let ok = 0, fail = 0;
const t0 = Date.now();
for (let i = 0; i < targets.length; i++) {
  const r = targets[i];
  const res = await replay(r);
  if (res.status >= 200 && res.status < 300) ok++;
  else {
    fail++;
    console.log(`  [${i+1}] FAIL ${res.status} ${r.id}: ${res.body}`);
  }
  if ((i + 1) % 20 === 0) {
    const eta = ((Date.now() - t0) / (i + 1)) * (targets.length - i - 1) / 1000;
    console.log(`  [${i+1}/${targets.length}] ok=${ok} fail=${fail} ETA ${eta.toFixed(0)}s`);
  }
  // small throttle so the webhook isn't slammed
  await new Promise(s => setTimeout(s, 100));
}
console.log(`\nReplay totals: ok=${ok} fail=${fail} in ${((Date.now() - t0) / 1000).toFixed(0)}s`);

const after = await pg(`
  SELECT
    COUNT(*) FILTER (WHERE array_length(derm_manifest_extra_urls, 1) > 0)::int AS m_extra_pop,
    COUNT(*) FILTER (WHERE array_length(derm_address_extra_urls, 1) > 0)::int AS a_extra_pop
  FROM public.derm_manifests;
`);
console.log('After:', after);
