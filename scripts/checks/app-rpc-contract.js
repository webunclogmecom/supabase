#!/usr/bin/env node
/**
 * app-rpc-contract.js — assert every RPC a SHIPPED app calls actually resolves
 * in a schema that app's Supabase client is pinned to.
 *
 *   node scripts/checks/app-rpc-contract.js            # all apps
 *   node scripts/checks/app-rpc-contract.js calendar   # one app
 *
 * WHY THIS EXISTS (2026-07-30). The Visit Calendar's "Retry sync" button had NEVER worked.
 * The app called `client.rpc("retry_visit_push")` on a client pinned to db:{schema:'ops'}, but
 * `retry_visit_push` was only ever created in `public` — the sole calendar RPC without an `ops`
 * twin. Every press returned PGRST202 and toasted a raw PostgREST string at dispatch staff.
 *
 * It survived extensive verification because every backend test ran through the Management API
 * as `postgres` with `public` on the search_path, which is STRUCTURALLY INCAPABLE of seeing a
 * PostgREST schema-resolution failure. The function existed. The app could not reach it.
 *
 *   Existing rule:  test as the ROLE, not as the owner.
 *   This check is:  TEST THROUGH THE TRANSPORT, NOT THE CATALOGUE.
 *
 * WHAT IT DOES NOT DO. It does not resolve which minified client variable makes each call —
 * that mapping changes every build and is brittle. Instead it asks the weaker, robust question:
 * "is this RPC reachable from EVERY schema this app pins?" An RPC present in only some of them
 * is reported as AT-RISK, which is exactly the shape of the bug above.
 */

const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const PAT = process.env.SUPABASE_PAT;
const PROJECT = process.env.SUPABASE_PROJECT_ID || 'wbasvhvvismukaqdnouk';
if (!PAT) { console.error('FAIL: SUPABASE_PAT missing from Supabase/.env'); process.exit(2); }

const APPS = {
  calendar: { label: 'Visit Calendar', url: 'https://calendar.unclogme.app' },
  clients:  { label: 'Client App',     url: 'https://clients.unclogme.app'  },
  derm:     { label: 'DERM Tracker',   url: 'https://derm.unclogme.app'     },
  review:   { label: 'Admin Review',   url: 'https://review.unclogme.app'   },
  fp:       { label: 'Field Portal',   url: 'https://fp.unclogme.app'       },
};

async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { throw new Error(`non-JSON from Management API: ${t.slice(0, 200)}`); }
  if (!Array.isArray(j)) throw new Error(`query failed: ${JSON.stringify(j).slice(0, 300)}`);
  return j;
}

/**
 * Fetch the app's JS to CLOSURE.
 * ⚠ Chunks reference each other in TWO forms and missing either gives a false all-clear:
 *      "/assets/index-ABC.js"   (absolute)      "./index-ABC.js"   (relative, no assets/ prefix)
 * A scan that only follows the absolute form stopped at 2 of 3 chunks during the audit and
 * reported ZERO matches for a string that was present.
 */
async function fetchBundle(baseUrl) {
  const seen = new Map();
  const queue = [];
  const html = await (await fetch(baseUrl, { redirect: 'follow' })).text();
  for (const m of html.matchAll(/\/assets\/[A-Za-z0-9._-]+\.js/g)) queue.push(m[0]);
  if (!queue.length) throw new Error(`no /assets/*.js found at ${baseUrl} — app moved or is down`);

  while (queue.length) {
    const p = queue.shift();
    if (seen.has(p)) continue;
    const res = await fetch(new URL(p, baseUrl).href);
    if (!res.ok) { seen.set(p, ''); continue; }
    const body = await res.text();
    seen.set(p, body);
    for (const m of body.matchAll(/["'](?:\.\/|\/assets\/)([A-Za-z0-9._-]+\.js)["']/g)) {
      const next = `/assets/${m[1]}`;
      if (!seen.has(next)) queue.push(next);
    }
  }
  return { chunks: seen.size, bytes: [...seen.values()].reduce((a, b) => a + b.length, 0), code: [...seen.values()].join('\n') };
}

function extract(code) {
  const rpcs = new Set();
  for (const m of code.matchAll(/\.rpc\(\s*["']([a-zA-Z0-9_]+)["']/g)) rpcs.add(m[1]);

  // Which schemas does this app pin its clients to? Default is `public` when unspecified.
  const schemas = new Set();
  for (const m of code.matchAll(/schema\s*:\s*["']([a-zA-Z0-9_]+)["']/g)) schemas.add(m[1]);
  if (!schemas.size) schemas.add('public');

  // Explicit per-call overrides would defeat the whole-app assumption below.
  const overrides = (code.match(/\.schema\(\s*["'][a-zA-Z0-9_]+["']\s*\)/g) || []).length;
  return { rpcs: [...rpcs].sort(), schemas: [...schemas].sort(), overrides };
}

(async () => {
  const only = process.argv[2];
  const keys = only ? [only] : Object.keys(APPS);
  if (only && !APPS[only]) { console.error(`unknown app "${only}" — known: ${Object.keys(APPS).join(', ')}`); process.exit(2); }

  let failures = 0, risks = 0;

  for (const key of keys) {
    const app = APPS[key];
    process.stdout.write(`\n=== ${app.label}  (${app.url}) ===\n`);

    let bundle;
    try { bundle = await fetchBundle(app.url); }
    catch (e) { console.log(`  SKIP — ${e.message}`); continue; }

    const { rpcs, schemas, overrides } = extract(bundle.code);
    console.log(`  bundle: ${bundle.chunks} chunks, ${bundle.bytes.toLocaleString()} bytes`);
    console.log(`  client schemas pinned: ${schemas.join(', ')}`);
    if (overrides) console.log(`  ⚠ ${overrides} per-call .schema() override(s) — verdicts below may be conservative`);

    // POSITIVE CONTROL — and note what it tests. The FIRST version of this check treated "zero
    // RPCs" as a broken extractor and hard-failed. That was wrong: Admin Review legitimately makes
    // zero `.rpc()` calls (it uses only table reads/writes), so the check reported a FAIL on a
    // healthy app. The control has to prove the INSTRUMENT works, not assume the app must have
    // RPCs. So: assert the supabase client library is present in the bundle. If it is and there
    // are no call sites, zero is a real, correct answer.
    const libPresent = /createClient|supabase-js|\.rpc\(/.test(bundle.code);
    if (!libPresent) {
      console.log('  🛑 FAIL — no supabase client found in the bundle at all. BROKEN CHECK, not a clean app.');
      failures++; continue;
    }
    if (!rpcs.length) {
      console.log('  ok — no .rpc() call sites (control: supabase client IS present, so zero is real)');
      continue;
    }
    console.log(`  rpc calls found: ${rpcs.length}  (control passed: client present, extractor working)`);

    const rows = await sql(`
      select n.nspname as schema, p.proname as fn
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where p.proname in (${rpcs.map(r => `'${r.replace(/'/g, "''")}'`).join(',')})
        and n.nspname in (${schemas.map(s => `'${s.replace(/'/g, "''")}'`).join(',')})`);

    const found = new Map();
    for (const r of rows) {
      if (!found.has(r.fn)) found.set(r.fn, new Set());
      found.get(r.fn).add(r.schema);
    }

    // For the AT-RISK set, look for POSITIVE PROOF the app already reaches them: audit rows whose
    // request path is /rpc/<name>. Such a row can only exist if the call arrived and succeeded.
    //
    // ⚠ THE DIRECTION OF THIS INFERENCE MATTERS AND IS EASY TO GET BACKWARDS.
    //   rows present  -> PROVEN reachable. Downgrade to ok.
    //   rows absent   -> proves NOTHING. Stays AT-RISK.
    // audit.logs records only SUCCESSES, so silence is not evidence of breakage (and plenty of
    // RPCs touch no audited table at all). Positive evidence may downgrade; absence may never
    // upgrade. This is the same rule that let a broken zone rename look healthy for weeks.
    const atRisk = rpcs.filter(fn => {
      const has = found.get(fn) || new Set();
      return has.size && schemas.some(s => !has.has(s));
    });
    let proven = new Map();
    if (atRisk.length) {
      const rows = await sql(`
        select replace(request_context->>'path','/rpc/','') as fn,
               count(*)::text as n,
               to_char(max(changed_at) at time zone 'America/New_York','YYYY-MM-DD') as last_seen
        from audit.logs
        where request_context->>'path' in (${atRisk.map(f => `'/rpc/${f.replace(/'/g, "''")}'`).join(',')})
        group by 1`);
      for (const r of rows) proven.set(r.fn, r);
    }

    for (const fn of rpcs) {
      const has = found.get(fn) || new Set();
      const missing = schemas.filter(s => !has.has(s));
      if (!has.size) {
        console.log(`  🛑 FAIL      ${fn.padEnd(30)} exists in NONE of [${schemas.join(', ')}] — unreachable`);
        failures++;
      } else if (missing.length) {
        const ev = proven.get(fn);
        if (ev) {
          console.log(`  ok (proven) ${fn.padEnd(30)} only in [${[...has].join(', ')}], but ${ev.n} successful call(s) through /rpc/${fn}, last ${ev.last_seen}`);
        } else {
          console.log(`  ⚠ AT-RISK   ${fn.padEnd(30)} only in [${[...has].join(', ')}] — missing from [${missing.join(', ')}], and NO successful call on record`);
          risks++;
        }
      } else {
        console.log(`  ok          ${fn.padEnd(30)} [${[...has].join(', ')}]`);
      }
    }
  }

  console.log('');
  if (failures) {
    console.log(`🛑 ${failures} unreachable RPC(s). An app is calling something that does not exist.`);
  }
  if (risks) {
    console.log(`⚠ ${risks} at-risk RPC(s): present in some pinned schemas but not all.`);
    console.log('  This is the exact shape of the 2026-07-30 dead-button bug. For each one, confirm the');
    console.log('  client that calls it is pinned to a schema where it exists — or add the missing wrapper.');
    console.log('');
    console.log('  ⚠ BEFORE TREATING ONE AS A BUG: a READ-ONLY rpc writes no audit row, so "no successful');
    console.log('    call on record" is EXPECTED for functions that only SELECT (portal reads, search).');
    console.log('    Absence is not evidence either way — exercise the app surface that calls it instead.');
    console.log('    Only a WRITING rpc with zero calls on record is genuinely suspicious.');
  }
  if (!failures && !risks) console.log('✅ every RPC resolves in every schema its app pins.');

  process.exit(failures ? 1 : risks ? 1 : 0);
})().catch(e => { console.error('CHECK ERRORED:', e.message); process.exit(2); });
