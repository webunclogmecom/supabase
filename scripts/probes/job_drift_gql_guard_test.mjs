// job_drift_gql_guard_test.mjs - prove sync-jobber-job-drift's gql() refuses a missing answer.
//
// WHY THIS EXISTS
// ---------------
// Measured 2026-09-06 on live Prod: `sync-jobber-job-drift` logged 30 non-success runs in 14 days,
// every one with the sample "run failed: Cannot read properties of undefined (reading 'jobs')" and
// every one still reporting checked=480 with updated=0. The mechanism:
//
//   const j = await r.json().catch(() => ({}));   // HTML waiting room -> {}
//   if (j.errors) throw ...                       // undefined, so no throw
//   return j.data;                                // -> undefined
//   ...
//   const byGid = new Map((data.jobs?.nodes ?? []).map(...))   // TypeError, OUTSIDE the batch catch
//
// Two defects in that last line. The undefined killed the WHOLE sweep instead of one batch, and a
// reply shaped `{}` would instead have coerced to an empty array, missed every lookup, and driven
// all 25 jobs in the slice into the "gone on Jobber's side" branch, which ARCHIVES them. The second
// has never fired (gone_archived has only ever been 1, twice) precisely BECAUSE the first one
// throws. Fixing the crash alone would have armed the mass archive.
//
// THE POINT OF THE CONTROL
// ------------------------
// A test suite that only exercises the fixed body is an untested instrument: it cannot tell a real
// guard from a no-op. So this extracts gql() from BOTH the working tree AND the pre-fix body at a
// given git ref, runs the identical assertions against each, and REQUIRES the old one to fail the
// two cases the fix is about. If the control stops failing, the harness is broken, not proven.
//
// Usage:  node scripts/probes/job_drift_gql_guard_test.mjs [pre-fix-git-ref]
// Read-only. Talks to nothing: fetch is stubbed. Never contacts Jobber.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const SRC = 'supabase/functions/sync-jobber-job-drift/index.ts';
const PRE_FIX_REF = process.argv[2] ?? 'HEAD';

// Extract the gql function body verbatim, never retyped. (CLAUDE.md: copy the body, do not retype
// it; a retyped body silently loses whatever you fail to reproduce.)
function extractGql(source, label) {
  const start = source.indexOf('async function gql(');
  if (start === -1) throw new Error(`${label}: no gql() found`);
  // Walk braces from the first { after the signature to find the true end of the function.
  const open = source.indexOf('{', start);
  let depth = 0, end = -1;
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') depth++;
    else if (source[i] === '}') { depth--; if (depth === 0) { end = i + 1; break } }
  }
  if (end === -1) throw new Error(`${label}: unbalanced braces in gql()`);
  const ts = source.slice(start, end);
  // Strip only the TypeScript annotations, so the executed logic is byte-identical otherwise.
  const js = ts
    .replace('async function gql(token: string, query: string, variables?: unknown, _retry = 0): Promise<any>',
             'async function gql(token, query, variables, _retry = 0)')
    .replace(/\(e: any\)/g, '(e)');
  if (js.includes(': string') || js.includes(': Promise<')) {
    throw new Error(`${label}: type annotations survived the strip, the signature must have changed`);
  }
  return js;
}

function buildGql(js) {
  const factory = new Function('fetch', 'GQL_VERSION', `${js}; return gql;`);
  return (stubFetch) => factory(stubFetch, '2026-04-16');
}

const res = (body, { status = 200, ctype = 'application/json' } = {}) => async () => ({
  status,
  headers: { get: (h) => (h.toLowerCase() === 'content-type' ? ctype : null) },
  json: async () => { if (typeof body === 'string') throw new Error('not json'); return body },
});

// Each case: does gql() THROW (refuse), or does it RETURN a value the caller will misread?
const CASES = [
  { name: 'html-waiting-room-at-200', mustThrow: true,
    fetch: res('<html><title>Jobber | Waiting Room</title></html>', { ctype: 'text/html' }) },
  { name: 'json-with-no-data-key', mustThrow: true,
    fetch: res({ extensions: { cost: {} } }) },
  { name: 'json-with-null-data', mustThrow: true, fetch: res({ data: null }) },
  { name: 'graphql-errors', mustThrow: true, fetch: res({ errors: [{ message: 'boom' }] }) },
  // The positive control for the instrument itself: a good answer must still come back intact,
  // or a test where everything throws would "pass" against a gql() that simply always throws.
  { name: 'CONTROL-valid-payload-passes-through', mustThrow: false,
    expect: (v) => v?.jobs?.nodes?.length === 1,
    fetch: res({ data: { jobs: { nodes: [{ id: 'gid://Jobber/Job/1' }] } } }) },
];

async function run(js, label) {
  const make = buildGql(js);
  const out = [];
  for (const c of CASES) {
    // _retry = 5 exhausts the retry ladder immediately, so a transient-retry path resolves to its
    // terminal behaviour without the test sleeping through 31s of exponential backoff.
    let threw = false, value, err;
    try { value = await make(c.fetch)('tok', 'query {}', {}, 5) } catch (e) { threw = true; err = e.message }
    const ok = c.mustThrow ? threw : (!threw && c.expect(value));
    out.push({ case: c.name, mustThrow: c.mustThrow, threw, ok,
               detail: threw ? err.slice(0, 60) : `returned ${JSON.stringify(value)?.slice(0, 40)}` });
  }
  return { label, results: out };
}

const fixed = await run(extractGql(readFileSync(SRC, 'utf8'), 'working tree'), 'FIXED (working tree)');

const oldSource = execFileSync('git', ['show', `${PRE_FIX_REF}:${SRC}`], { encoding: 'utf8' });
const control = await run(extractGql(oldSource, `pre-fix ${PRE_FIX_REF}`), `CONTROL (pre-fix @ ${PRE_FIX_REF})`);

for (const r of [fixed, control]) {
  console.log(`\n=== ${r.label} ===`);
  for (const x of r.results) {
    console.log(`  ${x.ok ? 'PASS' : 'FAIL'}  ${x.case.padEnd(38)} threw=${String(x.threw).padEnd(5)} ${x.detail}`);
  }
}

const fixedAllPass = fixed.results.every((x) => x.ok);
// The two cases the fix is ABOUT. The control must fail exactly these, and must still pass the
// valid-payload case, or it is not a like-for-like comparison.
const guardCases = ['html-waiting-room-at-200', 'json-with-no-data-key'];
const controlFailsGuards = guardCases.every((n) => control.results.find((x) => x.case === n)?.ok === false);
const controlPassesValid = control.results.find((x) => x.case === 'CONTROL-valid-payload-passes-through')?.ok === true;

console.log('\n=== VERDICT ===');
console.log(`  fixed body passes every case            : ${fixedAllPass}`);
console.log(`  control FAILS both guard cases          : ${controlFailsGuards}   <- proves the test can detect the bug`);
console.log(`  control still passes the valid payload  : ${controlPassesValid}   <- proves it is a like-for-like body`);

if (!(fixedAllPass && controlFailsGuards && controlPassesValid)) {
  console.log('\nRESULT: NOT PROVEN. A failing control means the instrument is untrusted, not that the target is broken.');
  process.exit(1);
}
console.log('\nRESULT: PROVEN. The guards refuse a missing answer, and the pre-fix body demonstrably does not.');
