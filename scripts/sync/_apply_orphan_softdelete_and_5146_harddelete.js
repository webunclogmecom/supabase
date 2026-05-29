// Apply the Phase B fixes from the 2026-05-29 audit:
//   1. Soft-delete 4 orphan visits (Jobber returned "Visit not found")
//   2. Hard-delete visit 5146 (009-CN Casa Neos July 4 — inverted timeline,
//      per Fred's explicit "Hard delete, it's not a visit" decision)
//
// All writes use X-App-Source: sql so the audit log attributes them to
// this repair script, not to a Lovable user.
//
// Dry-run by default. Pass --apply to mutate.

const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const APPLY = process.argv.includes('--apply');

const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json', 'X-App-Source': 'sql', Prefer: 'return=representation' };

const ORPHANS = [
  { id: 3917, code: '168-AVA',  reason: 'Jobber: Visit not found' },
  { id: 3912, code: 'Tower 41', reason: 'Jobber: Visit not found' },
  { id: 1624, code: '112-YA',   reason: 'Jobber: Visit not found' },
  { id: 1806, code: '148-MOR',  reason: 'Jobber: Visit not found' },
];

const HARD_DELETE_ID = 5146;

async function softDelete(id, code, reason) {
  console.log(`${APPLY ? 'APPLY' : 'DRY'} soft-delete id=${id} (${code}) — ${reason}`);
  if (!APPLY) return;
  const r = await fetch(`${URL}/rest/v1/visits?id=eq.${id}`, {
    method: 'PATCH',
    headers: H,
    body: JSON.stringify({ deleted_at: new Date().toISOString() }),
  });
  const j = await r.json();
  if (!r.ok) { console.error(`  FAIL ${r.status}:`, JSON.stringify(j)); return; }
  console.log(`  OK → id=${j[0]?.id} deleted_at=${j[0]?.deleted_at}`);
}

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  return { ok: r.ok, status: r.status, body: await r.text() };
}

async function hardDelete(id) {
  console.log(`\n${APPLY ? 'APPLY' : 'DRY'} HARD-DELETE id=${id}`);
  if (!APPLY) return;
  // Step 1: clear entity_source_links (no FK so no cascade)
  const r1 = await sql(`DELETE FROM public.entity_source_links WHERE entity_type='visit' AND entity_id=${id} RETURNING id, source_system, source_id;`);
  console.log(`  ESL delete: ${r1.status} ${r1.body.slice(0, 200)}`);
  // Step 2: delete the visit (CASCADE removes visit_assignments + visit_recommendations + manifest_visits)
  const r2 = await sql(`DELETE FROM public.visits WHERE id=${id} RETURNING id, visit_date, title, completed_at;`);
  console.log(`  visit DELETE: ${r2.status} ${r2.body.slice(0, 300)}`);
}

(async () => {
  console.log('=== Phase B fixes (2026-05-29 audit) ===');
  console.log(`Mode: ${APPLY ? 'APPLY' : 'DRY-RUN (pass --apply to mutate)'}\n`);

  console.log('--- 4 orphan soft-deletes ---');
  for (const o of ORPHANS) await softDelete(o.id, o.code, o.reason);

  console.log('--- 1 hard-delete (visit 5146 009-CN July 4 inverted timeline) ---');
  await hardDelete(HARD_DELETE_ID);

  console.log('\nDone.');
})().catch(e => { console.error(e); process.exit(1); });
