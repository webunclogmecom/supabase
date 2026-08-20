// TASK 12 STEP 6: create ONE real property on 112-YA through save-client-property.
//
// 🛑 THIS COMMITS TWICE OVER: a real Jobber PROPERTY (no propertyDelete in our surface) and a real,
//    PERMANENT Service Call job (no jobDelete, no jobArchive; only jobClose(DESTROY_ALL)). Run once.
//    Refuses without --commit, and refuses if the address already exists.
//
// AUTHORISATION: Fred, 2026-08-20 - "Anything on the client 112-YA can be done, as it is a testing
// account, so go ahead, specially if it's a smoke test", plus his OK to mint a staff session as
// fred@ayache.com. ⚠ The actor recorded in audit.logs is therefore HIM for a write he did not click.
//
// Run: node --experimental-strip-types scripts/probes/task12_save_client_property_112ya.mjs --commit
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';

const COMMIT = process.argv.includes('--commit');
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const env = Object.fromEntries(readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));
const U = `https://${env.SUPABASE_PROJECT_ID}.supabase.co`;
const SR = env.SUPABASE_SERVICE_ROLE_KEY;
const db = createClient(U, SR, { auth: { persistSession: false } });
const say = (...a) => console.log(...a);

const STREET = '9401 Collins Avenue Unit 2';
const CITY = 'Surfside';
const ZIP = '33154';

// ---- 1. AUDIT FIRST -----------------------------------------------------------------------------
const { data: client } = await db.from('clients').select('id').eq('client_code', '112-YA').maybeSingle();
if (!client?.id) { say('FATAL: 112-YA not found'); process.exit(1); }
const { data: before } = await db.from('properties').select('id,address').eq('client_id', client.id);
const dupe = (before ?? []).filter(p => String(p.address ?? '').startsWith(STREET));
say('AUDIT BEFORE');
say('  client 112-YA id      :', client.id);
say('  properties on file    :', before?.length, (before ?? []).map(p => p.id).join(', '));
say('  already at this addr  :', dupe.length, dupe.map(p => p.id).join(', ') || '(none)');
if (dupe.length) { say('\n🛑 ABORT: that address already exists. This script must run once.'); process.exit(1); }
if (!COMMIT) { say('\nDRY: pass --commit to create a REAL Jobber property + a PERMANENT job.'); process.exit(0); }

// ---- 2. staff session, memory only ---------------------------------------------------------------
const g = await (await fetch(`${U}/auth/v1/admin/generate_link`, { method: 'POST',
  headers: { apikey: SR, Authorization: `Bearer ${SR}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', email: 'fred@ayache.com' }) })).json();
const v = await (await fetch(`${U}/auth/v1/verify`, { method: 'POST',
  headers: { apikey: SR, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', token_hash: g.hashed_token }) })).json();
if (!v?.access_token) { say('FATAL: could not mint a staff session'); process.exit(1); }

// ---- 3. call it -----------------------------------------------------------------------------------
say('\nCALL save-client-property');
const r = await fetch(`${U}/functions/v1/save-client-property`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${v.access_token}`, 'Content-Type': 'application/json', apikey: SR },
  body: JSON.stringify({ client_id: Number(client.id), street: STREET, city: CITY, postal_code: ZIP }),
});
const j = await r.json();
say('  http', r.status, '|', JSON.stringify(j).slice(0, 340));

// ---- 4. ASSERT ON THE DB, not the response --------------------------------------------------------
await new Promise(res => setTimeout(res, 3000));
const { data: rows } = await db.from('properties')
  .select('id,address,is_billing,client_id').eq('client_id', client.id).like('address', STREET + '%');
const p = rows?.[0];
let link = null, scJobs = [];
if (p?.id) {
  const { data: l } = await db.from('entity_source_links').select('source_id')
    .eq('entity_type', 'property').eq('entity_id', p.id).eq('source_system', 'jobber').maybeSingle();
  link = l?.source_id ?? null;
  const { data: jb } = await db.from('jobs').select('id,title,job_status,job_number')
    .eq('property_id', p.id).not('job_status', 'in', '("archived","closed","destroyed")');
  scJobs = (jb ?? []).filter(x => String(x.title).trim().toLowerCase() === 'service call');
}
say('\nDB AFTER');
say('  property row   :', JSON.stringify(p ?? null));
say('  jobber link    :', link ?? '(MISSING)');
say('  SC jobs        :', scJobs.length, JSON.stringify(scJobs));

const checks = [
  ['response ok', j?.ok !== false],
  ['exactly one property row landed', (rows?.length ?? 0) === 1],
  ['it is a SERVICE property (is_billing = false)', p?.is_billing === false],
  ['a real Jobber GID is linked', !!link],
  ['🛑 the link is NOT a _billing twin', !!link && !String(link).endsWith('_billing')],
  ['exactly one Service Call job', scJobs.length === 1],
  ['response says schedulable', j?.schedulable === true],
];
say('');
for (const [n, ok] of checks) say((ok ? 'PASS' : 'FAIL').padEnd(5), n);
say(`\n${checks.filter(c => c[1]).length}/${checks.length} passed`);
say('\nFor the Jobber UI check -> property_id', p?.id, '| job #', scJobs[0]?.job_number ?? '(none)');
process.exit(checks.every(c => c[1]) ? 0 : 1);
