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

/**
 * ⚠ THIS LIST WAS 5 APPS AND THE TWO MISSING ONES WERE NOT THE QUIET ONES (added 2026-07-31).
 * DERM Stamp Studio makes TEN RPC calls, eight of which write, and was covered by nothing. It was
 * missed because it is the app nobody logs into (public, obscure-URL gate), which is precisely
 * backwards as a reason to skip a contract check. Add an app here the day it gets a domain.
 */
const APPS = {
  calendar: { label: 'Visit Calendar', url: 'https://calendar.unclogme.app' },
  clients:  { label: 'Client App',     url: 'https://clients.unclogme.app'  },
  derm:     { label: 'DERM Tracker',   url: 'https://derm.unclogme.app'     },
  // Admin Review moved review.unclogme.app -> admin.unclogme.app on 2026-08-04, because Yannick's new
  // "Review Builder" app took reviews.unclogme.app (plural) and the two read alike. Verified that day:
  // admin.* serves 200 and review.* no longer serves at all, so this URL was BROKEN until it was changed.
  review:   { label: 'Admin Review',   url: 'https://admin.unclogme.app'    },
  fp:       { label: 'Field Portal',   url: 'https://fp.unclogme.app'       },
  studio:   { label: 'DERM Stamp Studio', url: 'https://studio.unclogme.app' },
  dump:     { label: 'DUMP Schedule QR',  url: 'https://dump.unclogme.app'   },
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
    for (const m of body.matchAll(/(["'`])(?:\.\/|\/assets\/)([A-Za-z0-9._-]+\.js)\1/g)) {
      const next = `/assets/${m[2]}`;
      if (!seen.has(next)) queue.push(next);
    }
  }
  return { chunks: seen.size, bytes: [...seen.values()].reduce((a, b) => a + b.length, 0), code: [...seen.values()].join('\n') };
}

/**
 * TWO extraction passes, because ONE OF THEM SILENTLY MISSES MOST APPS.
 *
 * ⚠ 2026-07-30. The original version had only pass A and reported "1 rpc call found" for the
 * Client App while the app in fact calls four. Not a regex typo — a wrong ASSUMPTION about the
 * shape of a minified call. Measured across all five live bundles:
 *
 *     calendar  8 literal   0 indirect      <- pass A is complete here
 *     clients   1 literal   indirect        <- pass A finds global_search and MISSES the 3 wave-1 writes
 *     derm      3 literal   0 indirect
 *     review    0 literal   indirect
 *     fp        2 literal   0 indirect
 *
 * The Calendar minifies to `.rpc("edit_calendar_visit",{...})` so the name survives as a literal
 * AT the call site. The Client App routes through a helper, so the call site is `.rpc(e,...)` and
 * the name only ever appears as a string somewhere else entirely. NO regex over call syntax can
 * recover it, so pass A is not fixable — it needs a different question.
 *
 * PASS B inverts it: harvest every identifier-shaped string literal in the bundle and INTERSECT
 * with the real function names in the schemas this app pins. Minification cannot hide a string
 * literal, so this is robust to whatever the bundler does to the call site.
 *
 * Cost of B: a false positive is possible when a literal coincidentally equals a function name
 * (a column called `global_search`, say). That is why the two passes are reported SEPARATELY and
 * B is labelled `candidate` — a noisy AT-RISK line is cheap; a silent miss is what this file
 * exists to prevent.
 *
 * 🛑 RESIDUAL LIMITATION, STATED SO NOBODY READS THIS CHECK AS COMPLETE. Pass B can only find a
 * name that EXISTS somewhere in the bundle as a string. Measured on the Client App the same day:
 * `client` holds three wave-1 write RPCs, and B recovers two.
 *
 *     update_property_operational   in the bundle as a literal   -> found
 *     upsert_gdo_permit             in the bundle as a literal   -> found
 *     update_client_fields          NOT in the bundle AT ALL     -> invisible to any static scan
 *
 * `update_client_fields` has 1 successful call in audit.logs, so something has called it, but the
 * CURRENTLY DEPLOYED bundle does not contain the string, so the live app cannot be calling it by
 * name. Flagged to the Client App's owner; it is not this file's job to resolve.
 *
 * ⇒ Read this check as: "of the RPCs I can SEE this app naming, do they all resolve?" It is a
 * lower bound on the RPC surface, and coverage is now stated in the output instead of implied.
 * The complement to it is audit.logs `/rpc/<name>` paths — names the DB has SEEN called. Neither
 * alone is the full picture, and neither can prove a call site is absent.
 */
/**
 * ⚠ EVERY LITERAL MATCHER BELOW ACCEPTS A BACKTICK, AND THAT IS NOT COSMETIC (2026-07-31).
 *
 * These regexes were `["']`-only. A bundler is free to emit `.from(`visits`)` / `.rpc(`name`)`,
 * and the DERM Stamp Studio's live bundle does exactly that — a `["']`-only sweep over it reports
 * **zero** `.from()` calls, which reads as "this app touches no tables" rather than as a broken
 * instrument. Measured on the Studio bundle the same day (817,566 bytes, 3 chunks, walked to
 * closure): `["']` -> 0 tables, backtick-aware -> the real set.
 *
 * The delimiter is captured and back-referenced (`(["'\`])...\1`) rather than put in a character
 * class on both ends, so `"name\`` cannot match as a pair.
 *
 * Same family as the pass-A/pass-B split below: a regex over call syntax is an instrument, and an
 * instrument that returns 0 has told you nothing until a positive control says it can return >0.
 */
function extract(code) {
  // PASS A — the name is a literal at the call site. High confidence: definitely an RPC call.
  const direct = new Set();
  for (const m of code.matchAll(/\.rpc\(\s*(["'`])([a-zA-Z0-9_]+)\1/g)) direct.add(m[2]);

  // Every identifier-shaped string literal. Intersected against the catalogue by the caller.
  const literals = new Set();
  for (const m of code.matchAll(/(["'`])([a-z][a-z0-9_]{3,60})\1/g)) literals.add(m[2]);

  // COVERAGE TELL. `.rpc(` whose first argument is NOT a literal means pass A is structurally
  // incomplete for this app. Counted so the check can say so out loud instead of implying zero.
  // The supabase-js library defines its own `rpc(` method, so a small count is expected noise —
  // what matters is that we STOP treating pass A's total as the app's RPC surface.
  //
  // ⚠ The identifier was capped at 4 chars (`[\w$]{0,3}`) on the assumption that every bundle is
  // aggressively minified. Caught by the extractor self-test 2026-07-31: a bundle that ships a
  // readable `.rpc(rpcName)` scored indirect = 0, i.e. "pass A is complete here" — the single most
  // load-bearing false all-clear this file can emit, since it is what licenses reading the literal
  // count as coverage. Widened. A longer identifier is no less indirect than a short one, and the
  // trailing `[,)]` still requires the argument to be exactly one bare identifier.
  const indirect = (code.match(/\.rpc\(\s*[A-Za-z_$][\w$]{0,40}\s*[,)]/g) || []).length;

  // Which schemas does this app pin its clients to? Default is `public` when unspecified.
  const schemas = new Set();
  for (const m of code.matchAll(/schema\s*:\s*(["'`])([a-zA-Z0-9_]+)\1/g)) schemas.add(m[2]);
  if (!schemas.size) schemas.add('public');

  // Explicit per-call overrides would defeat the whole-app assumption below.
  const overrides = (code.match(/\.schema\(\s*(["'`])[a-zA-Z0-9_]+\1\s*\)/g) || []).length;
  return { direct: [...direct].sort(), literals, indirect, schemas: [...schemas].sort(), overrides };
}

/**
 * POSITIVE CONTROL ON THE EXTRACTOR ITSELF, run before any app is fetched.
 *
 * The two controls further down prove the BUNDLE has a supabase client and the CATALOGUE query
 * returns rows. Neither says anything about whether these regexes can match. The 2026-07-31
 * backtick gap sat in three of them and every control still passed — a real app would simply have
 * come back "0 rpc names", indistinguishable from a clean app.
 *
 * So: a fixture that exercises every quoting style, asserted at startup. If a future edit narrows
 * a delimiter class again, this fails loudly instead of the check going quietly blind.
 */
function selfTest() {
  const fixture = [
    'a.rpc("dq_name",{});',
    "b.rpc('sq_name',{});",
    'c.rpc(`bt_name`,{});',
    'd.rpc(varName,{});',
    'createClient(u,k,{db:{schema:`bt_schema`}});',
    'e.schema(`bt_override`).from(`t`);',
  ].join('\n');
  const r = extract(fixture);
  const problems = [];
  for (const n of ['dq_name', 'sq_name', 'bt_name']) {
    if (!r.direct.includes(n)) problems.push(`.rpc() missed ${n}`);
    if (!r.literals.has(n)) problems.push(`literal pass missed ${n}`);
  }
  if (r.indirect !== 1) problems.push(`indirect count ${r.indirect}, expected 1`);
  if (!r.schemas.includes('bt_schema')) problems.push('schema pin missed a backtick literal');
  if (r.overrides !== 1) problems.push(`override count ${r.overrides}, expected 1`);
  return problems;
}

(async () => {
  const only = process.argv[2];
  const keys = only ? [only] : Object.keys(APPS);
  if (only && !APPS[only]) { console.error(`unknown app "${only}" — known: ${Object.keys(APPS).join(', ')}`); process.exit(2); }

  const selfTestProblems = selfTest();
  if (selfTestProblems.length) {
    console.error('🛑 EXTRACTOR SELF-TEST FAILED — every result below would be untrustworthy:');
    for (const p of selfTestProblems) console.error(`   - ${p}`);
    process.exit(2);
  }
  console.log('extractor self-test: ok (double-quote, single-quote and backtick forms all recovered)');

  let failures = 0, risks = 0;

  for (const key of keys) {
    const app = APPS[key];
    process.stdout.write(`\n=== ${app.label}  (${app.url}) ===\n`);

    let bundle;
    try { bundle = await fetchBundle(app.url); }
    catch (e) { console.log(`  SKIP — ${e.message}`); continue; }

    const { direct, literals, indirect, schemas, overrides } = extract(bundle.code);
    console.log(`  bundle: ${bundle.chunks} chunks, ${bundle.bytes.toLocaleString()} bytes`);
    console.log(`  client schemas pinned: ${schemas.join(', ')}`);
    if (overrides) console.log(`  ⚠ ${overrides} per-call .schema() override(s) — verdicts below may be conservative`);

    // PASS B — intersect the bundle's string literals with the REAL function names in the pinned
    // schemas. One catalogue query, intersected in JS: cheaper and safer than building a giant
    // IN-list out of every literal in a megabyte of minified code.
    const catalogue = await sql(`
      select distinct n.nspname as schema, p.proname as fn
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in (${schemas.map(s => `'${s.replace(/'/g, "''")}'`).join(',')})`);
    const bySchema = new Map();
    for (const r of catalogue) {
      if (!bySchema.has(r.fn)) bySchema.set(r.fn, new Set());
      bySchema.get(r.fn).add(r.schema);
    }
    const candidates = [...bySchema.keys()].filter(fn => literals.has(fn) && !direct.includes(fn)).sort();
    const rpcs = [...new Set([...direct, ...candidates])].sort();

    if (indirect) {
      console.log(`  ⚠ ${indirect} .rpc(<variable>) call site(s) — the name is NOT a literal at the call site,`);
      console.log(`    so the ${direct.length} literal match(es) are a FLOOR, not this app's RPC surface.`);
      console.log(`    This is why pass B exists. Do not read the literal count as coverage.`);
    }
    console.log(`  rpc names: ${direct.length} literal at call site + ${candidates.length} candidate via string-literal ∩ catalogue`);
    if (candidates.length) console.log(`    candidates: ${candidates.join(', ')}`);

    // POSITIVE CONTROL — and note what it tests. The FIRST version of this check treated "zero
    // RPCs" as a broken extractor and hard-failed. That was wrong: Admin Review legitimately makes
    // zero `.rpc()` calls (it uses only table reads/writes), so the check reported a FAIL on a
    // healthy app. The control has to prove the INSTRUMENT works, not assume the app must have
    // RPCs. So: assert the supabase client library is present in the bundle. If it is and there
    // are no call sites, zero is a real, correct answer.
    const libPresent = /createClient|supabase-js|\.rpc\(/.test(bundle.code);
    // ⚠ A THIRD TRANSPORT EXISTS, and treating its absence as a broken check is a FALSE FAIL
    // (found 2026-07-31 the moment DUMP Schedule was added). DUMP ships NO supabase-js: its entire
    // backend surface is one `fetch` to `.../functions/v1/dump-visit-create`. Measured: createClient
    // 0, rest/v1 0, .rpc( 0, and all six `.from(` hits are `Array.from`/`Buffer.from`. So zero RPCs
    // is the CORRECT answer, exactly like Admin Review's legitimate zero above — the control must
    // prove the instrument can see a backend, not demand one particular client library.
    const edgeOnly = !libPresent && /\/functions\/v1\//.test(bundle.code);
    if (edgeOnly) {
      const fns = [...new Set([...bundle.code.matchAll(/\/functions\/v1\/([a-zA-Z0-9_-]+)/g)].map(m => m[1]))];
      console.log(`  ok — no PostgREST client; this app calls edge function(s) directly: ${fns.join(', ')}`);
      console.log('    RPC contract does not apply. Its contract is the edge function\'s own signature.');
      continue;
    }
    if (!libPresent) {
      console.log('  🛑 FAIL — no supabase client and no edge-function URL in the bundle at all.');
      console.log('    BROKEN CHECK (bad URL / chunk walk stopped early), not a clean app.');
      failures++; continue;
    }
    // SECOND POSITIVE CONTROL, for pass B specifically. If the catalogue query came back empty the
    // intersection is guaranteed to be empty too, and "no candidates" would be a property of the
    // broken query rather than of the app. An untested instrument, not an all-clear.
    if (!catalogue.length) {
      console.log(`  🛑 FAIL — 0 functions found in [${schemas.join(', ')}]. The catalogue query is broken,`);
      console.log('    so pass B could only ever return zero. BROKEN CHECK, not a clean app.');
      failures++; continue;
    }
    console.log(`  control: ${catalogue.length} function(s) exist in the pinned schema(s), so the intersection is meaningful`);

    if (!rpcs.length) {
      console.log('  ok — no RPC names found by either pass (controls: supabase client present, catalogue non-empty)');
      continue;
    }

    // Resolution reuses the catalogue already fetched for pass B — no second round trip.
    const found = new Map();
    for (const fn of rpcs) if (bySchema.has(fn)) found.set(fn, bySchema.get(fn));

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
      // How we know about this name at all. A `candidate` came FROM the catalogue, so it can never
      // hit the FAIL branch — only a literal call site can name something that does not exist,
      // which is precisely the 2026-07-30 dead-button shape.
      const via = direct.includes(fn) ? 'literal  ' : 'candidate';
      if (!has.size) {
        console.log(`  🛑 FAIL      ${fn.padEnd(30)} [${via}] exists in NONE of [${schemas.join(', ')}] — unreachable`);
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
