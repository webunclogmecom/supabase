// SMOKE: save-client-property action:'preview' (READ-ONLY) across the shapes that matter.
//
// Preview writes NOTHING. It is the dialog's data source, so this exercises the blast-radius
// computation and every refusal that must happen BEFORE a delete is possible.
//
// AUTHORISATION: the staff session is minted as fred@ayache.com per the standing task12 pattern.
// Run: node scripts/probes/property_removal_preview_smoke.mjs
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const env = Object.fromEntries(readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));
const U = `https://${env.SUPABASE_PROJECT_ID}.supabase.co`;
const SR = env.SUPABASE_SERVICE_ROLE_KEY;
const db = createClient(U, SR, { auth: { persistSession: false } });
const say = (...a) => console.log(...a);

// ---- pick real subjects from live data -------------------------------------------------------
const { data: svc } = await db.from('properties')
  .select('id, client_id, address, is_billing')
  .eq('client_id', 381).not('is_billing', 'is', true).is('deleted_at', null).limit(1);
const { data: bill } = await db.from('properties')
  .select('id, client_id, address').eq('is_billing', true).is('deleted_at', null).limit(1);
const { data: gone } = await db.from('properties')
  .select('id').not('deleted_at', 'is', null).limit(1);

const subjects = [
  { label: 'service property on the TEST client (112-YA)', property_id: svc?.[0]?.id },
  { label: 'BILLING property (must refuse: client gid + _billing)', property_id: bill?.[0]?.id },
  { label: 'already-removed property (must refuse)', property_id: gone?.[0]?.id },
  { label: 'nonexistent property (must refuse)', property_id: 99999999 },
];

// ---- staff session, memory only ---------------------------------------------------------------
const g = await (await fetch(`${U}/auth/v1/admin/generate_link`, { method: 'POST',
  headers: { apikey: SR, Authorization: `Bearer ${SR}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', email: 'fred@ayache.com' }) })).json();
const v = await (await fetch(`${U}/auth/v1/verify`, { method: 'POST',
  headers: { apikey: SR, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', token_hash: g.hashed_token }) })).json();
if (!v?.access_token) { say('FATAL: could not mint a staff session'); process.exit(1); }

for (const s of subjects) {
  if (!s.property_id) { say(`\n### ${s.label}\n  (no subject found)`); continue; }
  const r = await fetch(`${U}/functions/v1/save-client-property`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${v.access_token}`, 'Content-Type': 'application/json', apikey: SR },
    body: JSON.stringify({ action: 'preview', property_id: Number(s.property_id) }),
  });
  const j = await r.json();
  say(`\n### ${s.label}  (property ${s.property_id})`);
  if (!j.ok) { say('  REFUSED:', j.code, '-', String(j.message).slice(0, 150)); continue; }
  const p = j.preview;
  say('  client   :', p.client.code, p.client.name);
  say('  property :', p.property.address);
  say('  jobber   :', p.jobber, '| gid', p.jobber_property_gid ? 'present' : 'none',
      '| client gid match:', p.jobber_client_gid ? 'read' : 'n/a');
  say('  destroys :', JSON.stringify(p.destroyed_in_jobber));
  say('  keeps    :', JSON.stringify(p.kept_here));
  say('  only addr:', p.is_only_property);
  say('  ACKS     :');
  for (const a of p.required_acknowledgements) say('     -', a.key, '|', a.label);
}

// ---- prove preview is read-only ----------------------------------------------------------------
const { count } = await db.from('properties').select('id', { count: 'exact', head: true })
  .not('deleted_at', 'is', null);
say('\nsoft-deleted properties after the run:', count, '(was 7 before this work)');
