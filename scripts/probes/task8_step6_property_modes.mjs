// TASK 8 STEP 6 + 7: exercise the `separate` and `none` property_mode branches live, once each.
//
// 🛑 THIS CREATES TWO REAL JOBBER CLIENTS. clientArchive exists so the CLIENTS are recoverable, but
//    the Service Call job the `separate` run mints is NOT (no jobDelete, no jobArchive). Run once.
//    Refuses without --commit, and refuses if either client already exists.
//
// AUTHORISATION: Fred, 2026-08-20 - "you can go ahead with tasks 8 step 6". Staff gate satisfied
// with a minted session for fred@ayache.com, same synthetic-actor caveat as task5 (see that file).
//
// WHAT EACH ARM MUST PROVE
//   separate : the property lands at the SECOND address (2 Service St), NOT the client's own
//              billing address (1 Billing St). That inversion is the entire point of the mode, and
//              it is the one thing a dry run cannot prove, because only Jobber decides what
//              properties[] actually creates.
//   none     : NO non-billing property and NO job, and the ledger must say job_step='skipped',
//              never 'failed'. 'failed' would mean the mode branch fell through to the helper.
//
// Run: node --experimental-strip-types scripts/probes/task8_step6_property_modes.mjs --commit
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

// ---- 1. AUDIT FIRST ---------------------------------------------------------------------------
const { data: pre } = await db.from('clients').select('id,name,client_code')
  .in('name', ['ZZ Mode Separate', 'ZZ Mode None']);
say('AUDIT BEFORE');
say('  existing ZZ clients :', pre?.length ?? 0, JSON.stringify(pre ?? []));
if ((pre?.length ?? 0) > 0) { say('\n🛑 ABORT: a ZZ Mode client already exists. This must run once.'); process.exit(1); }
if (!COMMIT) { say('\nDRY: pass --commit to create two real Jobber clients. Nothing done.'); process.exit(0); }

// ---- 2. staff session, memory only -------------------------------------------------------------
const g = await (await fetch(`${U}/auth/v1/admin/generate_link`, { method: 'POST',
  headers: { apikey: SR, Authorization: `Bearer ${SR}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', email: 'fred@ayache.com' }) })).json();
const v = await (await fetch(`${U}/auth/v1/verify`, { method: 'POST',
  headers: { apikey: SR, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', token_hash: g.hashed_token }) })).json();
if (!v?.access_token) { say('FATAL: could not mint a staff session'); process.exit(1); }
const TOK = v.access_token;

async function createClientCall(body) {
  const r = await fetch(`${U}/functions/v1/create-client`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${TOK}`, 'Content-Type': 'application/json', apikey: SR },
    body: JSON.stringify(body),
  });
  return { status: r.status, json: await r.json() };
}

// ---- 3. ARM: separate ---------------------------------------------------------------------------
say('\nARM separate');
const sep = await createClientCall({
  idempotency_key: '22222222-2222-2222-2222-222222222221', name: 'ZZ Mode Separate',
  street: '1 Billing St', city: 'Miami', postal_code: '33139',
  property_mode: 'separate',
  property_street: '2 Service St', property_city: 'Miami Beach', property_postal_code: '33141',
});
say('  http', sep.status, '|', JSON.stringify(sep.json).slice(0, 320));

// ---- 4. ARM: none -------------------------------------------------------------------------------
say('\nARM none');
const none = await createClientCall({
  idempotency_key: '22222222-2222-2222-2222-222222222222', name: 'ZZ Mode None',
  street: '3 Billing Only Ave', city: 'Miami', postal_code: '33139',
  property_mode: 'none',
});
say('  http', none.status, '|', JSON.stringify(none.json).slice(0, 320));

// ---- 5. ASSERT ON THE DB, not the responses -----------------------------------------------------
await new Promise(r => setTimeout(r, 4000)); // let the synthetic webhook replay settle
const { data: clients } = await db.from('clients').select('id,name,client_code')
  .in('name', ['ZZ Mode Separate', 'ZZ Mode None']);
const summary = {};
for (const c of clients ?? []) {
  const { data: props } = await db.from('properties').select('id,address,is_billing').eq('client_id', c.id);
  const { data: jobs } = await db.from('jobs').select('id,title,property_id,job_status')
    .eq('client_id', c.id).not('job_status', 'in', '("archived","closed","destroyed")');
  summary[c.name] = {
    client_code: c.client_code,
    real_properties: (props ?? []).filter(p => p.is_billing === false).length,
    billing_properties: (props ?? []).filter(p => p.is_billing === true).length,
    service_address: (props ?? []).filter(p => p.is_billing === false).map(p => p.address)[0] ?? null,
    sc_jobs: (jobs ?? []).filter(j => String(j.title).trim().toLowerCase() === 'service call').length,
  };
}
say('\nDB AFTER');
for (const [k, s] of Object.entries(summary)) say(' ', k.padEnd(18), JSON.stringify(s));

// ---- 6. the LEDGER (step 7) ---------------------------------------------------------------------
const { data: ledger } = await db.from('client_create_attempts')
  .select('idempotency_key,status,job_step,job_id,client_code')
  .in('idempotency_key', ['22222222-2222-2222-2222-222222222221', '22222222-2222-2222-2222-222222222222']);
say('\nLEDGER');
for (const l of ledger ?? []) say('  ', l.idempotency_key.slice(-4), JSON.stringify(l));

const sepS = summary['ZZ Mode Separate'] ?? {}, noneS = summary['ZZ Mode None'] ?? {};
const lSep = (ledger ?? []).find(l => l.idempotency_key.endsWith('221')) ?? {};
const lNone = (ledger ?? []).find(l => l.idempotency_key.endsWith('222')) ?? {};

const checks = [
  ['separate: client exists', !!summary['ZZ Mode Separate']],
  ['separate: exactly 1 real property', sepS.real_properties === 1],
  ['separate: property is at 2 Service St, NOT the billing address',
    String(sepS.service_address ?? '').startsWith('2 Service St')],
  ['separate: exactly 1 Service Call job', sepS.sc_jobs === 1],
  ['separate: ledger job_step is created/existing', ['created', 'existing'].includes(lSep.job_step)],
  ['separate: ledger job_id is set', lSep.job_id != null],
  ['none: client exists', !!summary['ZZ Mode None']],
  ['none: ZERO real properties', noneS.real_properties === 0],
  ['none: ZERO Service Call jobs', noneS.sc_jobs === 0],
  ['none: ledger job_step is exactly "skipped" (NOT failed)', lNone.job_step === 'skipped'],
  ['none: ledger job_id is NULL', lNone.job_id == null],
  ['none: response reported schedulable=false', none.json?.schedulable === false],
];
say('');
for (const [n, ok] of checks) say((ok ? 'PASS' : 'FAIL').padEnd(5), n);
say(`\n${checks.filter(c => c[1]).length}/${checks.length} passed`);
say('\nJobber GIDs for the UI check:');
say('  separate:', sep.json?.jobber_client_gid ?? '(none)');
say('  none    :', none.json?.jobber_client_gid ?? '(none)');
process.exit(checks.every(c => c[1]) ? 0 : 1);
