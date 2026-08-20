// TASK 5: the one irreversible arm. Creates a REAL, PERMANENT Service Call job in Jobber on
// 112-YA property 1057, through the exact code path create-client uses.
//
// 🛑 JOBBER HAS NO jobDelete AND NO jobArchive. The only teardown is jobClose(DESTROY_ALL), which
//    also destroys the job's scheduled visits. RUN THIS ONCE. It refuses to run without --commit.
//
// AUTHORISATION: Fred, 2026-08-20 - "Anything on the client 112-YA can be done, as it is a testing
// account, so go ahead, specially if it's a smoke test" and "you can use my account fred@ayache.com
// for it". The staff gate on save-client-job needs a real user token, and no automation identity
// exists in auth.users, so a session is minted for fred@ayache.com via the Admin API.
// ⚠ THE ACTOR IN audit.logs WILL THEREFORE READ fred@ayache.com FOR A WRITE FRED DID NOT CLICK.
//   That is a deliberate, authorised synthetic actor, recorded here so the activity trail can be
//   read honestly later.
//
// 🛑 THE TOKEN IS HELD IN MEMORY ONLY. It is never written to disk and never printed. Both repos
//    are PUBLIC and .staff_token.tmp is NOT gitignored - an earlier draft nearly wrote it there.
//
// Run: node --experimental-strip-types scripts/probes/task5_live_sc_job_112ya.mjs --commit
import { copyFileSync, mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createClient } from '@supabase/supabase-js';

const COMMIT = process.argv.includes('--commit');
const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const PROPERTY_ID = 1057;   // 9401 Collins Avenue, is_billing=false, zero SC jobs
const env = Object.fromEntries(readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));

const SUPABASE_URL = `https://${env.SUPABASE_PROJECT_ID}.supabase.co`;
const SR = env.SUPABASE_SERVICE_ROLE_KEY;
globalThis.Deno = { env: { get: (k) => (k === 'SUPABASE_URL' ? SUPABASE_URL : env[k]) } };

const db = createClient(SUPABASE_URL, SR, { auth: { persistSession: false } });
const say = (...a) => console.log(...a);

// ---- 1. AUDIT FIRST -------------------------------------------------------------------------
const { data: client } = await db.from('clients').select('id').eq('client_code', '112-YA').maybeSingle();
const before = await db.from('jobs').select('id,title,job_status')
  .eq('property_id', PROPERTY_ID).not('job_status', 'in', '("archived","closed","destroyed")');
say('AUDIT BEFORE');
say('  client 112-YA id      :', client?.id);
say('  live jobs on 1057     :', before.data?.length, JSON.stringify(before.data ?? []));
if ((before.data?.length ?? 0) > 0) {
  say('\n🛑 ABORT: property 1057 already has a live job. This script exists to create the FIRST one.');
  process.exit(1);
}
if (!COMMIT) { say('\nDRY: pass --commit to actually create the job. Nothing done.'); process.exit(0); }

// ---- 2. mint the staff session (memory only) --------------------------------------------------
const g = await fetch(`${SUPABASE_URL}/auth/v1/admin/generate_link`, {
  method: 'POST', headers: { apikey: SR, Authorization: `Bearer ${SR}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 'magiclink', email: 'fred@ayache.com' }) });
const gj = await g.json();
const v = await fetch(`${SUPABASE_URL}/auth/v1/verify`, {
  method: 'POST', headers: { apikey: SR, 'Content-Type': 'application/json' },
  // ⚠ token_hash, NOT token. `token` returns HTTP 200 with no access_token, so a naive
  //   `if (!vj.access_token)` reads a 200 as a failure and you debug the wrong layer.
  body: JSON.stringify({ type: 'magiclink', token_hash: gj.hashed_token }) });
const vj = await v.json();
if (!vj?.access_token) { say('FATAL: could not mint a staff session'); process.exit(1); }
const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SR, Authorization: `Bearer ${vj.access_token}` } });
const actor = (await u.json())?.email;
say('  acting as             :', actor);
if (!/@(ayache|unclogme)\.com$/.test(actor ?? '')) { say('FATAL: not a staff identity'); process.exit(1); }

// ---- 3. run the REAL helper -------------------------------------------------------------------
const dir = mkdtempSync(join(tmpdir(), 'scj-t5-'));
const copy = join(dir, 'service-call-job.mts');
copyFileSync(join(ROOT, 'supabase', 'functions', '_shared', 'service-call-job.ts'), copy);
const { ensureServiceCallJob } = await import(pathToFileURL(copy).href);

say('\nCREATE');
const res1 = await ensureServiceCallJob({
  db, authHeader: `Bearer ${vj.access_token}`, clientId: Number(client.id), propertyId: PROPERTY_ID });
say('  helper says           :', JSON.stringify(res1));

// ---- 4. ASSERT ON WHAT LANDED, not on the response --------------------------------------------
const landed = await db.from('jobs')
  .select('id,title,job_status,frequency_days,billing_type,invoice_frequency,start_at,property_id,job_number')
  .eq('property_id', PROPERTY_ID).eq('title', 'Service Call');
const j = landed.data?.[0];
say('\nDB AFTER');
say('  job row               :', JSON.stringify(j ?? null));
const { data: lines } = await db.from('line_items').select('id').eq('job_id', j?.id ?? -1);
const { data: link } = await db.from('entity_source_links')
  .select('source_id').eq('entity_type', 'job').eq('entity_id', j?.id ?? -1).eq('source_system', 'jobber').maybeSingle();
say('  job-scoped line items :', lines?.length, '(expected 0: SC jobs carry none)');
say('  jobber link           :', link?.source_id ? 'present' : 'MISSING');

const { data: opts } = await db.schema('ops').from('client_service_options')
  .select('job_kind').eq('client_id', client.id);
const kinds = {};
for (const o of opts ?? []) kinds[o.job_kind] = (kinds[o.job_kind] ?? 0) + 1;
say('  ops.client_service_options by kind :', JSON.stringify(kinds), '(an SC row must appear)');

// ---- 5. IDEMPOTENCY: run it again ------------------------------------------------------------
say('\nRE-RUN (idempotency)');
const res2 = await ensureServiceCallJob({
  db, authHeader: `Bearer ${vj.access_token}`, clientId: Number(client.id), propertyId: PROPERTY_ID });
say('  helper says           :', JSON.stringify(res2));
const after2 = await db.from('jobs').select('id').eq('property_id', PROPERTY_ID)
  .eq('title', 'Service Call').not('job_status', 'in', '("archived","closed","destroyed")');
say('  live SC jobs on 1057  :', after2.data?.length, '(MUST be exactly 1)');

// ---- verdict ---------------------------------------------------------------------------------
const checks = [
  ['helper created the job', res1.ok === true && res1.created === true],
  ['a Service Call row landed on 1057', !!j?.id],
  ['title is exactly "Service Call"', j?.title === 'Service Call'],
  ['frequency_days = 0', Number(j?.frequency_days) === 0],
  ['start_at is NULL', j?.start_at === null],
  ['billing_type = visit_based', j?.billing_type === 'visit_based'],
  ['invoice_frequency = per_visit', j?.invoice_frequency === 'per_visit'],
  ['no job-scoped line items', (lines?.length ?? -1) === 0],
  ['a real Jobber GID is linked', !!link?.source_id],
  ['ops.client_service_options exposes an SC row', (kinds.SC ?? 0) > 0],
  ['re-run was idempotent (created=false)', res2.ok === true && res2.created === false],
  ['exactly ONE live Service Call on 1057', (after2.data?.length ?? -1) === 1],
];
say('');
for (const [n, ok] of checks) say((ok ? 'PASS' : 'FAIL').padEnd(5), n);
say(`\n${checks.filter(c => c[1]).length}/${checks.length} passed`);
say(`\nJobber job number for the UI check: ${j?.job_number ?? '(none)'}`);
process.exit(checks.every(c => c[1]) ? 0 : 1);
