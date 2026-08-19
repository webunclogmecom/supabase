// Behavioural test for supabase/functions/_shared/service-call-job.ts
//
// WHY IT LOOKS LIKE THIS. The helper is a Deno edge-function module and there is no Deno runtime on
// this machine (checked: not on PATH, not in scoop, not in ~/.deno). Rather than install one, this
// uses Node 22's built-in type stripping. Two mechanics are load-bearing:
//   1. Node treats a bare .ts as CommonJS and chokes on `export`, so the module is COPIED to .mts.
//      🛑 COPIED, byte for byte, never retyped. A retyped copy tests a file that is not the one we
//         ship, which is the whole failure this repo documents under CREATE OR REPLACE.
//   2. globalThis.Deno is stubbed, because the module reads Deno.env.get for the delegate URL.
//
// Run: node --experimental-strip-types scripts/probes/service_call_job_behaviour.mjs
import { copyFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(HERE, '..', '..', 'supabase', 'functions', '_shared', 'service-call-job.ts');
const dir = mkdtempSync(join(tmpdir(), 'scj-'));
const copy = join(dir, 'service-call-job.mts');
copyFileSync(SRC, copy);

globalThis.Deno = { env: { get: () => 'http://stub.local' } };
const { ensureServiceCallJob } = await import(pathToFileURL(copy).href);

// ---- stubs -------------------------------------------------------------------------------------
/** Minimal stand-in for the supabase-js query builder. `jobs` may be a QUEUE: one entry per await. */
function stubDb({ links, jobs, unplaced }) {
  // `jobs` may be a QUEUE: entry 1 answers the property_id read, entry 2 the post-create re-read.
  // `unplaced` answers the .is('property_id', null) sweep and defaults to empty.
  const jobQueue = Array.isArray(jobs) ? [...jobs] : [jobs];
  return {
    from(table) {
      let isUnplaced = false;
      const chain = {
        select: () => chain,
        eq: () => chain,
        not: () => chain,
        is: () => { isUnplaced = true; return chain; },
        then: (res, rej) => {
          const result = table === 'entity_source_links'
            ? (links ?? { data: [], error: null })
            : isUnplaced
              ? (unplaced ?? { data: [], error: null })
              : (jobQueue.length > 1 ? jobQueue.shift() : (jobQueue[0] ?? { data: [], error: null }));
          return Promise.resolve(result).then(res, rej);
        },
      };
      return chain;
    },
  };
}

function stubFetch({ status = 200, ctype = 'application/json', body = { ok: true } } = {}) {
  let calls = 0;
  const fn = async () => {
    calls++;
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: (h) => (h.toLowerCase() === 'content-type' ? ctype : null) },
      json: async () => body,
    };
  };
  fn.calls = () => calls;
  return fn;
}

const REAL_LINK = { data: [{ source_id: 'Z2lkOi8vSm9iYmVyL1Byb3BlcnR5LzE=' }], error: null };
const ARGS = { authHeader: 'Bearer test', clientId: 1, propertyId: 2 };

// ---- cases -------------------------------------------------------------------------------------
const results = [];
const t = async (name, fn) => {
  try { const r = await fn(); results.push({ name, pass: r === true || r === undefined, got: r === true ? 'ok' : String(r) }); }
  catch (e) { results.push({ name, pass: false, got: 'threw: ' + e.message }); }
};
const expect = (actual, wanted, label) => actual === wanted ? true : `${label}: expected ${wanted}, got ${actual}`;

await t('billing-twin-only property is refused, Jobber never called', async () => {
  const f = stubFetch(); globalThis.fetch = f;
  const r = await ensureServiceCallJob({ db: stubDb({ links: { data: [{ source_id: 'Z2lkOi8vSm9iYmVyL0NsaWVudC8x_billing' }], error: null } }), ...ARGS });
  if (r.ok !== false) return 'expected refusal';
  if (f.calls() !== 0) return 'it called the delegate anyway';
  return expect(r.reason, 'property_not_in_jobber', 'reason');
});

await t('property with no Jobber link at all is refused', async () => {
  globalThis.fetch = stubFetch();
  const r = await ensureServiceCallJob({ db: stubDb({ links: { data: [], error: null } }), ...ARGS });
  return r.ok === false ? expect(r.reason, 'property_not_in_jobber', 'reason') : 'expected refusal';
});

await t('FAILS CLOSED when the link lookup errors', async () => {
  globalThis.fetch = stubFetch();
  const r = await ensureServiceCallJob({ db: stubDb({ links: { data: null, error: { message: 'connection reset' } } }), ...ARGS });
  return r.ok === false ? expect(r.reason, 'link_lookup_failed', 'reason') : 'expected refusal';
});

await t('FAILS CLOSED when the job lookup errors, and never reaches Jobber', async () => {
  const f = stubFetch(); globalThis.fetch = f;
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: { data: null, error: { message: 'statement timeout' } } }), ...ARGS });
  if (r.ok !== false) return 'expected refusal';
  if (f.calls() !== 0) return 'it called the delegate on an unread table';
  return expect(r.reason, 'job_lookup_failed', 'reason');
});

await t('idempotent: an existing "  Service call  " short-circuits before Jobber', async () => {
  const f = stubFetch(); globalThis.fetch = f;
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: { data: [{ id: 77, title: '  Service call  ', job_status: 'active' }], error: null } }), ...ARGS });
  if (r.ok !== true) return 'expected success, got ' + JSON.stringify(r);
  if (f.calls() !== 0) return 'it created a duplicate';
  return r.created === false && r.job_id === 77 ? true : `created=${r.created} job_id=${r.job_id}`;
});

await t('an ARCHIVED Service Call does NOT satisfy the check', async () => {
  globalThis.fetch = stubFetch();
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: [
    { data: [{ id: 5, title: 'Service Call', job_status: 'archived' }], error: null },
    { data: [{ id: 5, title: 'Service Call', job_status: 'archived' }, { id: 9, title: 'Service Call', job_status: 'active' }], error: null }] }), ...ARGS });
  return r.ok === true && r.created === true ? true : 'a terminal job wrongly suppressed the create: ' + JSON.stringify(r);
});

await t('a NULL-status Service Call DOES satisfy it (fail safe, no duplicate)', async () => {
  const f = stubFetch(); globalThis.fetch = f;
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: { data: [{ id: 12, title: 'Service Call', job_status: null }], error: null } }), ...ARGS });
  if (f.calls() !== 0) return 'a NULL-status job did not block the create, so a duplicate is possible';
  return r.ok === true && r.created === false ? true : JSON.stringify(r);
});

await t('a Service AGREEMENT does not satisfy it', async () => {
  globalThis.fetch = stubFetch();
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: [
    { data: [{ id: 88, title: 'Service Agreement - Pumping', job_status: 'active' }], error: null },
    { data: [{ id: 88, title: 'Service Agreement - Pumping', job_status: 'active' }, { id: 90, title: 'Service Call', job_status: 'active' }], error: null }] }), ...ARGS });
  return r.ok === true && r.created === true ? true : 'an SA wrongly suppressed the create: ' + JSON.stringify(r);
});

await t('"Service Call - 341" does NOT satisfy it (equality, not prefix)', async () => {
  globalThis.fetch = stubFetch();
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: [
    { data: [{ id: 41, title: 'Service Call - 341', job_status: 'active' }], error: null },
    { data: [{ id: 41, title: 'Service Call - 341', job_status: 'active' }, { id: 42, title: 'Service Call', job_status: 'active' }], error: null }] }), ...ARGS });
  return r.ok === true && r.created === true ? true : 'a prefix match wrongly suppressed the create: ' + JSON.stringify(r);
});

await t('save-client-job refusing at HTTP 200 with ok:false is a FAILURE, not a success', async () => {
  globalThis.fetch = stubFetch({ status: 200, body: { ok: false, code: 'bad_request', message: 'nope' } });
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: { data: [], error: null } }), ...ARGS });
  return r.ok === false ? expect(r.reason, 'job_create_failed', 'reason') : 'it read a refusal as success';
});

await t('an HTML waiting room with NO job recorded fails SAFE (Jobber may hold one)', async () => {
  globalThis.fetch = stubFetch({ status: 200, ctype: 'text/html', body: {} });
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: { data: [], error: null } }), ...ARGS });
  return r.ok === false ? expect(r.reason, 'job_not_recorded', 'reason') : 'it read HTML as success';
});

await t('an unreadable reply where the job DID land reports success, not failure', async () => {
  globalThis.fetch = stubFetch({ status: 200, ctype: 'text/html', body: {} });
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: [
    { data: [], error: null },
    { data: [{ id: 501, title: 'Service Call', job_status: 'active' }], error: null }] }), ...ARGS });
  return r.ok === true && r.created === true && r.job_id === 501 ? true
    : 'a lost reply was reported as a failed create: ' + JSON.stringify(r);
});

await t('a thrown fetch where the job DID land reports success', async () => {
  globalThis.fetch = async () => { throw new Error('socket hang up'); };
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: [
    { data: [], error: null },
    { data: [{ id: 502, title: 'Service Call', job_status: 'active' }], error: null }] }), ...ARGS });
  return r.ok === true && r.created === true && r.job_id === 502 ? true : JSON.stringify(r);
});

await t('db_write_failed means Jobber HAS the job: orphaned, never "failed"', async () => {
  // save-client-job:1143 returns this AFTER jobCreate succeeded. Calling it job_create_failed would
  // make the caller record job_step='failed' (= nothing was left behind) and the attention view
  // would never fire for a real orphan.
  globalThis.fetch = stubFetch({ status: 200, body: { ok: false, code: 'db_write_failed',
    message: 'The job WAS created in Jobber (#12345) but saving it locally failed' } });
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: { data: [], error: null } }), ...ARGS });
  return r.ok === false ? expect(r.reason, 'job_not_recorded', 'reason') : 'it reported an orphan as success';
});

await t('jobber_no_answer is orphan-class too', async () => {
  globalThis.fetch = stubFetch({ status: 200, body: { ok: false, code: 'jobber_no_answer',
    message: "Jobber didn't answer. It may or may not have created the job" } });
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: { data: [], error: null } }), ...ARGS });
  return r.ok === false ? expect(r.reason, 'job_not_recorded', 'reason') : JSON.stringify(r);
});

await t('an UNRECOGNISED code fails safe as orphan-class, not as failed', async () => {
  globalThis.fetch = stubFetch({ status: 200, body: { ok: false, code: 'some_new_code_we_never_saw', message: 'x' } });
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: { data: [], error: null } }), ...ARGS });
  return r.ok === false ? expect(r.reason, 'job_not_recorded', 'reason') : JSON.stringify(r);
});

await t('AMBIGUOUS: a live SC job on this client with NULL property_id blocks the create', async () => {
  // The real Prod shape: job #99901056 is a live Service Call on our property 1069, but its
  // jobs.property_id is NULL, so the property_id read cannot see it. Delegating here would mint a
  // second, permanently undeletable job.
  const f = stubFetch(); globalThis.fetch = f;
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK,
    jobs: { data: [], error: null },
    unplaced: { data: [{ id: 1838, title: 'Service call', job_status: 'action_required', property_id: null }], error: null } }), ...ARGS });
  if (f.calls() !== 0) return 'it delegated despite an unplaceable Service Call: a duplicate is possible';
  return r.ok === false ? expect(r.reason, 'job_lookup_ambiguous', 'reason') : JSON.stringify(r);
});

await t('an unplaced SERVICE AGREEMENT does not block the create', async () => {
  globalThis.fetch = stubFetch({ body: { ok: true } });
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK,
    jobs: [{ data: [], error: null }, { data: [{ id: 600, title: 'Service Call', job_status: 'active' }], error: null }],
    unplaced: { data: [{ id: 99, title: 'Service Agreement - Pumping', job_status: 'active', property_id: null }], error: null } }), ...ARGS });
  return r.ok === true && r.created === true ? true : 'an unrelated SA wrongly blocked the create: ' + JSON.stringify(r);
});

await t('FAILS CLOSED when the unplaced-jobs sweep errors', async () => {
  const f = stubFetch(); globalThis.fetch = f;
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK,
    jobs: { data: [], error: null },
    unplaced: { data: null, error: { message: 'timeout' } } }), ...ARGS });
  if (f.calls() !== 0) return 'it delegated on an unread table';
  return r.ok === false ? expect(r.reason, 'job_lookup_failed', 'reason') : JSON.stringify(r);
});

await t('delegate says ok but nothing landed -> job_not_recorded', async () => {
  globalThis.fetch = stubFetch({ body: { ok: true } });
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: { data: [], error: null } }), ...ARGS });
  return r.ok === false ? expect(r.reason, 'job_not_recorded', 'reason') : 'it claimed a job that is not there';
});

await t('happy path: created:true with the landed job id', async () => {
  globalThis.fetch = stubFetch({ body: { ok: true } });
  const r = await ensureServiceCallJob({ db: stubDb({ links: REAL_LINK, jobs: [
    { data: [], error: null },
    { data: [{ id: 4242, title: 'Service Call', job_status: 'action_required' }], error: null }] }), ...ARGS });
  return r.ok === true && r.created === true && r.job_id === 4242 ? true : JSON.stringify(r);
});

// ---- report ------------------------------------------------------------------------------------
for (const r of results) console.log((r.pass ? 'PASS' : 'FAIL').padEnd(5), r.name, r.pass ? '' : '| ' + r.got);
const failed = results.filter(r => !r.pass).length;
console.log(`\n${results.length - failed}/${results.length} passed`);
console.log('\nMUTATION CONTROL: remove .trim() from findServiceCall in the real file and re-run.');
console.log('The "  Service call  " idempotency case MUST fail. A suite that cannot fail proves nothing.');
process.exit(failed ? 1 : 0);
