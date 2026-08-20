// LIVE audit of the REAL ensureServiceCallJob against REAL Prod data, on test client 112-YA only.
//
// WHAT THIS PROVES, and what it deliberately does not.
//   ARM 1  property 162  already carries SC job 766, so the helper must SHORT-CIRCUIT on its
//          idempotency check and never reach the delegate. Nothing is written. This is the arm that
//          proves the guard works against real rows rather than against the stubs in the unit suite.
//   ARM 2  property 1057 carries no SC job, so the helper must pass every guard and REACH the
//          delegate. It is called with a service_role bearer, which save-client-job refuses with
//          `forbidden` (its staff gate). The helper must map that to a NOTHING-WAS-CREATED failure.
//          ⇒ the full path is exercised and NO Jobber job is minted.
//
// 🛑 SO ARM 2 IS NOT THE FINAL SMOKE TEST. Minting the real job needs a staff JWT and is a separate,
//    deliberate, irreversible act (Jobber has no jobDelete). This probe is what can be proven
//    without borrowing a person's identity.
//
// Same Node-type-stripping mechanics as service_call_job_behaviour.mjs: the module is COPIED to
// .mts byte for byte (never retyped) and globalThis.Deno is stubbed for the one env read.
//
// Run: node --experimental-strip-types scripts/probes/ensure_sc_job_live_112ya.mjs
import { copyFileSync, mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createClient } from '@supabase/supabase-js';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');

// --- env, without printing anything ---------------------------------------------------------
const env = Object.fromEntries(
  readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
    .filter(l => /^[A-Z_]+=/.test(l))
    .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));

const SUPABASE_URL = `https://${env.SUPABASE_PROJECT_ID}.supabase.co`;
globalThis.Deno = { env: { get: (k) => (k === 'SUPABASE_URL' ? SUPABASE_URL : env[k]) } };

const SRC = join(ROOT, 'supabase', 'functions', '_shared', 'service-call-job.ts');
const dir = mkdtempSync(join(tmpdir(), 'scj-live-'));
const copy = join(dir, 'service-call-job.mts');
copyFileSync(SRC, copy);
const { ensureServiceCallJob } = await import(pathToFileURL(copy).href);

const db = createClient(SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

// 112-YA. Resolved, not hardcoded, so a renumber cannot silently point this at another client.
const { data: client } = await db.from('clients').select('id').eq('client_code', '112-YA').maybeSingle();
if (!client?.id) { console.error('FATAL: 112-YA not found'); process.exit(1); }

const results = [];
const check = (name, pass, detail) => { results.push({ name, pass, detail }); };

// ---- ARM 1: the property that ALREADY has a Service Call ------------------------------------
const before162 = await db.from('jobs').select('id').eq('property_id', 162)
  .not('job_status', 'in', '("archived","closed","destroyed")');
const arm1 = await ensureServiceCallJob({
  db, authHeader: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
  clientId: Number(client.id), propertyId: 162,
});
check('ARM 1 property 162: helper reports ok', arm1.ok === true, JSON.stringify(arm1).slice(0, 150));
check('ARM 1 property 162: created=false (idempotent, did NOT duplicate)',
      arm1.ok === true && arm1.created === false, `created=${arm1.created} job_id=${arm1.job_id}`);
check('ARM 1 property 162: it found the EXISTING job 766',
      arm1.job_id === 766, `job_id=${arm1.job_id}`);

// ---- ARM 2: the property with none, stopped at the delegate ----------------------------------
const arm2 = await ensureServiceCallJob({
  db, authHeader: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
  clientId: Number(client.id), propertyId: 1057,
});
check('ARM 2 property 1057: passed every guard and REACHED the delegate',
      arm2.ok === false && arm2.reason !== 'billing_twin_only' && arm2.reason !== 'no_jobber_link',
      `reason=${arm2.reason}`);
// 🛑 THE ASSERTION THAT MATTERS IS THE CLASS, NOT THE STRING. An earlier version of this probe
//    expected reason==='forbidden' and FAILED. The probe was wrong, not the helper: `forbidden` is a
//    save-client-job FAILURE CODE, never an EnsureReason (see the EnsureReason union). The helper
//    folds every provably-pre-mutation code into `job_create_failed`, and reserves `job_not_recorded`
//    for the orphan class where Jobber may hold a job we never wrote down.
//    That distinction is the whole safety property: create-client maps job_not_recorded -> 'orphaned'
//    (a human looks at it) and everything else -> 'failed' (safe to retry). Calling a forbidden
//    refusal an orphan would park a clean failure in front of a human forever; calling an orphan a
//    failure would let a retry mint a SECOND undeletable Jobber job.
check('ARM 2 property 1057: refusal is the NOTHING-WAS-CREATED class, not the orphan class',
      arm2.ok === false && arm2.reason === 'job_create_failed',
      `reason=${arm2.reason} detail=${String(arm2.detail).slice(0, 90)}`);
check('ARM 2 property 1057: create-client would therefore record job_step=failed, not orphaned',
      arm2.ok === false && arm2.reason !== 'job_not_recorded',
      `maps to ${arm2.reason === 'job_not_recorded' ? 'orphaned' : 'failed'}`);

// ---- THE CONTROL THAT MATTERS: nothing was written ------------------------------------------
const after162 = await db.from('jobs').select('id').eq('property_id', 162)
  .not('job_status', 'in', '("archived","closed","destroyed")');
const after1057 = await db.from('jobs').select('id').eq('property_id', 1057)
  .not('job_status', 'in', '("archived","closed","destroyed")');
check('CONTROL: property 162 job count unchanged',
      (before162.data?.length ?? -1) === (after162.data?.length ?? -2),
      `${before162.data?.length} -> ${after162.data?.length}`);
check('CONTROL: property 1057 still has ZERO jobs (no Jobber write happened)',
      (after1057.data?.length ?? -1) === 0, `jobs on 1057 = ${after1057.data?.length}`);

for (const r of results) console.log((r.pass ? 'PASS' : 'FAIL').padEnd(5), r.name, '|', r.detail);
console.log(`\n${results.filter(r => r.pass).length}/${results.length} passed`);
process.exit(results.every(r => r.pass) ? 0 : 1);
