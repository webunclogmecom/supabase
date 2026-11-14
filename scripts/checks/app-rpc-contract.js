#!/usr/bin/env node
/**
 * app-rpc-contract.js — assert every RPC a SHIPPED app calls actually resolves
 * in the schema that call goes to.
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
 * HOW A CALL GETS ITS SCHEMA (rewritten 2026-11-04). The first version did not follow the client
 * and asked "is this RPC in EVERY schema this app pins?". It exited 1 with "27 unreachable, 20 at
 * risk", all false alarms: it read supabase-js's own {schema:"public"} default and the 'myschema'
 * example in a supabase-js warning as pins, and it could not see `.schema('hr').rpc(...)`. Now each
 * call site is judged on the schema it really goes to:
 *
 *   X.schema("hr").rpc("a")                    hr
 *   let s=X.schema("hr"); s.rpc("a")           hr (the nearest earlier assignment of that name)
 *   Wv=f(u,k,{db:{schema:"ops"}}); Wv.rpc("a") ops, also when another chunk has import{v as ye}
 *   function F(e){e.rpc("a")}; F(Wv)           ops, when every caller passes the same client
 *   anything else (a Proxy, say)               unresolved
 *
 * A resolved call whose function is not in that schema is a FAIL. That is the bug above, now caught
 * even in an app with two clients. An unresolved call is ok when the function is in every schema
 * the app's clients pin, AT-RISK when it is in only some of the schemas the app reaches, and a FAIL
 * when it is in none of them. A bundler change that breaks the following shows up as a loud FAIL or
 * a failed control, never as a quiet pass: see the per-app `control` below.
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
 *
 * `control` = schema.function, a call this app is known to make. The run fails if the instrument
 * cannot see that call on that schema, or if the verdict does not flip to FAIL when the function is
 * moved out of that schema. Calendar's is the function of the original bug; DERM's goes through the
 * client factory and an import alias. DUMP has no client, so it has no control.
 */
const APPS = {
  calendar: { label: 'Visit Calendar', url: 'https://calendar.unclogme.app', control: 'ops.retry_visit_push' },
  clients:  { label: 'Client App',     url: 'https://clients.unclogme.app',  control: 'hr.get_my_access' },
  derm:     { label: 'DERM Tracker',   url: 'https://derm.unclogme.app',     control: 'derm.get_visit_report' },
  // Admin Review moved review.unclogme.app -> admin.unclogme.app on 2026-08-04, because Yannick's new
  // "Review Builder" app took reviews.unclogme.app (plural) and the two read alike. Verified that day:
  // admin.* serves 200 and review.* no longer serves at all, so this URL was BROKEN until it was changed.
  review:   { label: 'Admin Review',   url: 'https://admin.unclogme.app',    control: 'hr.get_my_access' },
  fp:       { label: 'Field Portal',   url: 'https://fp.unclogme.app',       control: 'customer.get_client_portal' },
  // Stamp Studio moved studio.unclogme.app -> stamp.unclogme.app on 2026-07-30. The old host still
  // REDIRECTS, which is why this stale URL kept passing and nobody noticed it for three weeks: a
  // check pointed at a redirect measures the right app for the wrong reason, and stops working the
  // day the redirect is retired. Point checks at the canonical host, never at a redirect.
  studio:   { label: 'DERM Stamp Studio', url: 'https://stamp.unclogme.app',  control: 'hr.get_my_access' },
  dump:     { label: 'DUMP Schedule QR',  url: 'https://dump.unclogme.app'   },
  // Apps Hub, added 2026-08-18 on its Lovable default host. Measured 2026-11-04: that host now only
  // redirects to hub.unclogme.app, so this points at the canonical host (see the Stamp note above).
  // Its one RPC is hr.get_my_access.
  hub:      { label: 'Apps Hub',          url: 'https://hub.unclogme.app',     control: 'hr.get_my_access' },
  // Picture Planner, added 2026-10-20 for access phase 3 (it had a domain since 2026-09-24 and was missing).
  planner:  { label: 'Picture Planner',   url: 'https://planner.unclogme.app', control: 'hr.get_my_access' },
  ops:      { label: 'Ops Portal',        url: 'https://ops.unclogme.app',     control: 'hr.get_my_access' },
  // HR App, added 2026-11-04. It was missing since it went live on 2026-09-01. All its RPCs are in `hr`.
  hr:       { label: 'HR App',            url: 'https://hr.unclogme.app',      control: 'hr.get_my_access' },
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
// The walk is scripts/client-app/base.mjs: a production build as always, or a Vite dev server's modules (squeezed, keyed
// by their /src/ path), which is how the Client App's copy in the portal is checked: CLIENT_APP=http://localhost:8080/clients
// (or --base <url>) moves the `clients` entry there.
async function fetchBundle(baseUrl) {
  const { crawl } = await import('../client-app/base.mjs');
  const seen = await crawl(['/'], { base: baseUrl, html: /\/assets\/[A-Za-z0-9._-]+\.js/g, chunk: /(["'`])(?:\.\/|\/assets\/)([A-Za-z0-9._-]+\.js)\1/g });
  if (!seen.size) throw new Error(`no /assets/*.js found at ${baseUrl} — app moved or is down`);
  return { chunks: seen.size, bytes: [...seen.values()].reduce((a, b) => a + b.length, 0), files: seen };
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
function extract(files) {
  const code = [...files.values()].join('\n');

  // Every identifier-shaped string literal. Intersected against the catalogue by the caller.
  const literals = new Set();
  for (const m of code.matchAll(/(["'`])([a-z][a-z0-9_]{3,60})\1/g)) literals.add(m[2]);

  // A real pin, as a minifier writes it: `db:{schema:"ops"}`, no spaces. A strict `db:` is what skips
  // supabase-js's own `{schema:"public"}` default and Realtime's `{event:"*",schema:"public"}`, and
  // no spaces is what skips the example in its warning text, `{ db: { schema: 'myschema' } }`.
  // If a build ever keeps the spaces, pins go missing and calls FAIL loudly: the safe direction.
  const pins = new Set();
  for (const m of code.matchAll(/[{,]db:\{schema:(["'`])([a-zA-Z0-9_]+)\1\}/g)) pins.add(m[2]);

  // A client factory, the DERM Tracker's shape: function R4(t){...db:{schema:t}...}, wrapped by
  // function j1(t){...R4(t)...}, then ht=j1() (public) and k4=j1("derm").
  const factories = new Set();
  for (const m of code.matchAll(/function ([\w$]+)\(([\w$]+)\)\{[^}]{0,200}db:\{schema:\2\}/g)) factories.add(m[1]);
  for (const f of [...factories]) {
    const callee = f.replace(/\$/g, '\\$');
    // The span may not cross another `function`, or R4's own match swallows j1 right after it.
    for (const m of code.matchAll(new RegExp(`function ([\\w$]+)\\(([\\w$]+)\\)\\{(?:(?!function )[\\s\\S]){0,200}?[^\\w$]${callee}\\(\\2\\)`, 'g'))) factories.add(m[1]);
  }

  // Per chunk: which local names hold a client bound to a schema. Minified names only mean something
  // inside their own chunk, which is why this walks chunks and not the joined text.
  const bound = new Map();
  for (const [file, body] of files) {
    const vars = new Map();
    for (const m of body.matchAll(/([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\([^()]{0,400}?[{,]db:\{schema:(["'`])([a-zA-Z0-9_]+)\2\}/g)) vars.set(m[1], m[3]);
    // The Ops Portal's builder since 2026-11-09, moduleClient(label, { schema }): a minifier writes
    // dermDb=Xt("derm-tracker",{schema:"derm"}) and publicDb=Xt("derm-tracker"). The builder's own body reads
    // `db:{schema:t.schema}`, which no pattern above can tie to a schema, so the call site is matched on the
    // app's audit label. A new app moving into the portal adds its label here, or its calls go unresolved.
    for (const m of body.matchAll(/([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\((["'`])(visit-calendar|derm-tracker|hr-app|derm-stamp-studio|admin-review|client-app|picture-planner)\2(?:,\{schema:(["'`])([a-zA-Z0-9_]+)\4[^)]*)?\)/g)) {
      vars.set(m[1], m[5] || 'public');
      pins.add(m[5] || 'public');
    }
    for (const f of factories) {
      const callee = f.replace(/\$/g, '\\$');
      for (const m of body.matchAll(new RegExp(`([A-Za-z_$][\\w$]*)=${callee}\\((?:(["'\`])([a-zA-Z0-9_]+)\\2)?\\)`, 'g'))) {
        vars.set(m[1], m[3] || 'public');
        pins.add(m[3] || 'public');
      }
    }
    bound.set(file, vars);
  }
  // ...and those names across chunks: export{Wv as v} in one, import{v as ye}from"./x.js" in another.
  // Two passes, so a chunk that re-exports what it imported resolves too.
  const pairs = list => list.split(',').map(p => p.trim().split(/\s+as\s+/)).filter(p => p[0]);
  // A dev server's modules (keys under /src/) also export `export const x=` and re-export `export{a as b}from"/src/..."`
  // (the portal's prodDb), and import by their /src/ path: those three shapes are read there only.
  const dev = [...files.keys()].some(k => k.startsWith('/src/'));
  const exported = new Map();
  for (const [file, body] of files) {
    const names = new Map();
    for (const m of body.matchAll(/export\s*\{([^}]*)\}(\s*from)?/g)) for (const [local, name = local] of pairs(m[1])) names.set(name, dev && m[2] ? name : local);
    if (dev) for (const m of body.matchAll(/export\s+(?:const|let|var)\s+([\w$]+)/g)) names.set(m[1], m[1]);
    exported.set(file, names);
  }
  for (let pass = 0; pass < 2; pass++) {
    for (const [file, body] of files) {
      for (const m of body.matchAll(dev ? /(?:import|export)\s*\{([^}]*)\}\s*from\s*(["'`])([^"'`]+)\2/g : /import\s*\{([^}]*)\}\s*from\s*(["'`])([^"'`]+)\2/g)) {
        const from = dev && m[3].startsWith('/src/') ? m[3].split('?')[0] : `/assets/${m[3].split('/').pop()}`;
        for (const [name, local = name] of pairs(m[1])) {
          const schema = bound.get(from)?.get(exported.get(from)?.get(name));
          if (schema) bound.get(file).set(local, schema);
        }
      }
    }
  }

  // Every call site, with the schema it goes to (null = could not tell).
  const calls = [];
  const wrappers = [];
  for (const [file, body] of files) {
    const aliases = [...body.matchAll(/([A-Za-z_$][\w$]*)=[\w$.()]*?\.schema\(\s*(["'`])([a-zA-Z0-9_]+)\2\s*\)/g)];
    // A client handed in as the first argument: async function CM(e,t){...e.rpc("x")...} called as CM(ln,id).
    // Every caller must be in this chunk (not exported) and agree, or it stays unresolved.
    const viaArgument = (at, receiver) => {
      const holder = [...body.slice(Math.max(0, at - 400), at).matchAll(/function ([\w$]+)\(([\w$]+)[,)]/g)].pop();
      if (!holder || holder[2] !== receiver || [...exported.get(file).values()].includes(holder[1])) return null;
      const callee = holder[1].replace(/\$/g, '\\$');
      const callers = [...body.matchAll(new RegExp(`(function )?(?<![\\w$.])${callee}\\(\\s*([A-Za-z_$][\\w$]*)?`, 'g'))].filter(c => !c[1]);
      const schemas = new Set(callers.map(c => bound.get(file).get(c[2]) ?? null));
      return callers.length && schemas.size === 1 ? [...schemas][0] : null;
    };
    const schemaOf = (at, receiver) => {
      let near = null;
      for (const a of aliases) {
        if (a.index >= at) break;
        if (a[1] === receiver && at - a.index < 4000) near = a; // ponytail: a window, not scope analysis
      }
      return near ? near[3] : bound.get(file).get(receiver) ?? viaArgument(at, receiver);
    };
    const receiverAt = at => /([A-Za-z_$][\w$]*)(?:\(\))?$/.exec(body.slice(Math.max(0, at - 64), at))?.[1];

    // PASS A: the name is a literal at the call site. High confidence: definitely an RPC call.
    for (const m of body.matchAll(/(?:\.schema\(\s*(["'`])([a-zA-Z0-9_]+)\1\s*\)\s*)?\.rpc\(\s*(["'`])([a-zA-Z0-9_]+)\3/g)) {
      calls.push({ name: m[4], schema: m[2] ?? schemaOf(m.index, receiverAt(m.index)) });
    }
    // `.rpc(<variable>)`: a wrapper like the Client App's Ct("name",{...}). supabase-js's own
    // `this.rest.rpc(t,e,s)` is not the app's call and is left out.
    for (const m of body.matchAll(/(?:\.schema\(\s*(["'`])([a-zA-Z0-9_]+)\1\s*\)\s*)?\.rpc\(\s*[A-Za-z_$][\w$]{0,40}\s*[,)]/g)) {
      if (body.slice(Math.max(0, m.index - 9), m.index) === 'this.rest') continue;
      wrappers.push({ schema: m[2] ?? schemaOf(m.index, receiverAt(m.index)) });
    }
  }

  // COVERAGE TELL. `.rpc(` whose first argument is NOT a literal means pass A is structurally
  // incomplete for this app. Counted so the check can say so out loud instead of implying zero.
  //
  // ⚠ The identifier was capped at 4 chars (`[\w$]{0,3}`) on the assumption that every bundle is
  // aggressively minified. Caught by the extractor self-test 2026-07-31: a bundle that ships a
  // readable `.rpc(rpcName)` scored indirect = 0, i.e. "pass A is complete here" — the single most
  // load-bearing false all-clear this file can emit, since it is what licenses reading the literal
  // count as coverage. Widened. A longer identifier is no less indirect than a short one, and the
  // trailing `[,)]` still requires the argument to be exactly one bare identifier.
  const indirect = wrappers.length;

  // Schemas this app names per call, reached with `.schema("x")` on any client.
  const perCall = new Set();
  for (const m of code.matchAll(/\.schema\(\s*(["'`])([a-zA-Z0-9_]+)\1\s*\)/g)) perCall.add(m[2]);

  return { calls, wrappers, literals, indirect, pins: [...pins].sort(), perCall: [...perCall].sort() };
}

/**
 * THE VERDICTS, separate from the fetch and the catalogue query so the self-test can replay them.
 * `catalogue` is Map(function name -> Set(schemas holding it)).
 */
function judge(x, catalogue) {
  const clientSchemas = x.pins.length ? x.pins : ['public']; // no pin at all = supabase-js's default
  const reached = [...new Set([...clientSchemas, ...x.perCall])].sort();
  const rows = [];

  for (const fn of [...new Set(x.calls.map(c => c.name))].sort()) {
    const has = catalogue.get(fn) || new Set();
    const sites = x.calls.filter(c => c.name === fn);
    const on = [...new Set(sites.map(c => c.schema).filter(Boolean))].sort();
    const dead = on.filter(s => !has.has(s));
    const unresolved = sites.some(c => !c.schema);
    let verdict = 'ok', why = `on [${on.join(', ')}]`;
    if (dead.length) {
      verdict = 'fail';
      why = `called on [${dead.join(', ')}], exists in [${[...has].sort().join(', ') || 'no schema'}]`;
    } else if (unresolved) {
      const inClient = clientSchemas.filter(s => has.has(s));
      if (inClient.length === clientSchemas.length) why = `in every client schema [${clientSchemas.join(', ')}]`;
      else if (!reached.some(s => has.has(s))) {
        verdict = 'fail';
        why = `client not resolved, exists in [${[...has].sort().join(', ') || 'no schema'}], app reaches [${reached.join(', ')}]`;
      } else {
        verdict = 'risk';
        why = `client not resolved, exists in [${[...has].sort().join(', ')}], app's clients pin [${clientSchemas.join(', ')}]`;
      }
    }
    rows.push({ fn, via: 'literal  ', verdict, why });
  }

  // PASS B: the name is a string somewhere else. It only counts as a call if a wrapper exists to
  // make it, and then it must be in a schema a wrapper goes to.
  const wrapperSchemas = [...new Set(x.wrappers.flatMap(w => (w.schema ? [w.schema] : clientSchemas)))].sort();
  const candidates = [...catalogue.keys()]
    .filter(fn => x.literals.has(fn) && reached.some(s => catalogue.get(fn).has(s)) && !x.calls.some(c => c.name === fn))
    .sort();
  if (wrapperSchemas.length) {
    for (const fn of candidates) {
      const has = catalogue.get(fn);
      if (wrapperSchemas.some(s => has.has(s))) rows.push({ fn, via: 'candidate', verdict: 'ok', why: `wrapper reaches it in [${wrapperSchemas.filter(s => has.has(s)).join(', ')}]` });
      else rows.push({ fn, via: 'candidate', verdict: 'risk', why: `only in [${[...has].sort().join(', ')}], the wrapper goes to [${wrapperSchemas.join(', ')}]` });
    }
  }
  return { clientSchemas, reached, candidates, rows };
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
 *
 * The verdicts get the same treatment (2026-11-04): the fixtures below replay the 2026-07-30 dead
 * button, and each false alarm of the first version, with a verdict each must reach.
 */
function selfTest() {
  const problems = [];
  const one = (...lines) => new Map([['/assets/a.js', lines.join('\n')]]);
  const catalogueOf = o => new Map(Object.entries(o).map(([fn, s]) => [fn, new Set(s)]));
  const expectVerdicts = (label, files, catalogue, want) => {
    const rows = judge(extract(files), catalogue).rows;
    for (const [fn, verdict] of Object.entries(want)) {
      const got = rows.find(r => r.fn === fn)?.verdict ?? 'no row';
      if (got !== verdict) problems.push(`${label}: ${fn} judged ${got}, expected ${verdict}`);
    }
  };

  // Every quoting style.
  const r = extract(one(
    'a.rpc("dq_name",{});',
    "b.rpc('sq_name',{});",
    'c.rpc(`bt_name`,{});',
    'd.rpc(varName,{});',
    'createClient(u,k,{db:{schema:`bt_schema`}});',
    'e.schema(`bt_override`).from(`t`);',
  ));
  for (const n of ['dq_name', 'sq_name', 'bt_name']) {
    if (!r.calls.some(c => c.name === n)) problems.push(`.rpc() missed ${n}`);
    if (!r.literals.has(n)) problems.push(`literal pass missed ${n}`);
  }
  if (r.indirect !== 1) problems.push(`indirect count ${r.indirect}, expected 1`);
  if (!r.pins.includes('bt_schema')) problems.push('schema pin missed a backtick literal');
  if (!r.perCall.includes('bt_override')) problems.push('.schema() missed a backtick literal');

  // supabase-js's own text is not the app's: no pin, no wrapper.
  const lib = extract(one(
    'Lk={schema:"public"},Mk={schema:`public`};',
    'console.warn(`Use "db", e.g. createClient(url, key, { db: { schema: \'myschema\' } }).`);',
    'class S{rpc(t,e){return this.rest.rpc(t,e,s)}}',
    'ch.on("postgres_changes",{event:"*",schema:"public",table:"visits"});',
  ));
  if (lib.pins.length) problems.push(`library text read as pins: ${lib.pins.join(', ')}`);
  if (lib.wrappers.length) problems.push('supabase-js this.rest.rpc read as an app wrapper');

  // The 2026-07-30 dead button, in an app with two clients, across chunks.
  expectVerdicts('two clients', new Map([
    ['/assets/index-1.js', 'const Wv=pd(a,b,{db:{schema:"ops"},auth:{}}),Wx=pd(a,b,{db:{schema:"public"},auth:{}});export{Wv as v,Wx as G};'],
    ['/assets/page-2.js', 'import{v as ye,G as ln}from"./index-1.js";ye.rpc("retry_visit_push");ye.rpc("edit_calendar_visit");ln.rpc("create_dump_visit");p.rpc("one_pin_only");p.rpc("in_both");p.rpc("nowhere");async function CM(e,t){await e.rpc("arg_ok",{})}CM(ln,1);async function BM(e,t){await e.rpc("arg_dead",{})}BM(ye,1);'],
  ]), catalogueOf({ retry_visit_push: ['public'], edit_calendar_visit: ['ops'], create_dump_visit: ['public'], one_pin_only: ['public'], in_both: ['ops', 'public'], arg_ok: ['public'], arg_dead: ['public'] }), {
    retry_visit_push: 'fail', edit_calendar_visit: 'ok', create_dump_visit: 'ok', one_pin_only: 'risk', in_both: 'ok', nowhere: 'fail', arg_ok: 'ok', arg_dead: 'fail',
  });
  // The same button in an app with one client, which reaches nothing else.
  expectVerdicts('one client', one('createClient(u,k,{db:{schema:"ops"}});c.rpc("retry_visit_push");'),
    catalogueOf({ retry_visit_push: ['public'] }), { retry_visit_push: 'fail' });

  // `.schema()` on the call and on a local name, and the factory: each goes to its own schema.
  const shapes = one(
    'function R4(t){return c(a,b,{...t?{db:{schema:t}}:{},auth:A})}function j1(t){let e;return new Proxy({},{get(n,s,a){return e||(e=R4(t)),Reflect.get(e,s,a)}})}const ht=j1(),k4=j1("derm");',
    'k4.rpc("get_visit_report");ht.rpc("file_manifest");X.schema("hr").rpc("get_my_access");',
    'async function f(){let s=_().schema(`hr`),{data:l}=await s.rpc(`set_pay_rates`,{});}',
  );
  expectVerdicts('shapes', shapes, catalogueOf({ get_visit_report: ['derm'], file_manifest: ['public'], get_my_access: ['hr'], set_pay_rates: ['hr'] }), {
    get_visit_report: 'ok', file_manifest: 'ok', get_my_access: 'ok', set_pay_rates: 'ok',
  });
  expectVerdicts('shapes moved', shapes, catalogueOf({ get_visit_report: ['public'], file_manifest: ['derm'], get_my_access: ['public'], set_pay_rates: ['public'] }), {
    get_visit_report: 'fail', file_manifest: 'fail', get_my_access: 'fail', set_pay_rates: 'fail',
  });

  // A name that reaches a wrapper as a string: it must be where the wrapper goes.
  expectVerdicts('wrapper', one(
    'createClient(u,k,{db:{schema:"client"}});async function Ct(e,t){await ae.rpc(e,t)}Ct("wrapped_name",{});Ct("only_in_hr",{});X.schema("hr").from("t");',
  ), catalogueOf({ wrapped_name: ['client'], only_in_hr: ['hr'] }), { wrapped_name: 'ok', only_in_hr: 'risk' });

  return problems;
}

(async () => {
  const { BASE, ARGS } = await import('../client-app/base.mjs');
  APPS.clients.url = BASE;
  const only = ARGS[0];
  const keys = only ? [only] : Object.keys(APPS);
  if (only && !APPS[only]) { console.error(`unknown app "${only}" — known: ${Object.keys(APPS).join(', ')}`); process.exit(2); }

  const selfTestProblems = selfTest();
  if (selfTestProblems.length) {
    console.error('🛑 EXTRACTOR SELF-TEST FAILED — every result below would be untrustworthy:');
    for (const p of selfTestProblems) console.error(`   - ${p}`);
    process.exit(2);
  }
  console.log('self-test: ok (every quoting style; library text is no pin; the dead button still fails)');

  // One catalogue query, intersected in JS: cheaper and safer than building a giant IN-list out of
  // every literal in a megabyte of minified code.
  const catalogue = new Map();
  for (const r of await sql(`
      select distinct n.nspname as schema, p.proname as fn
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname not in ('pg_catalog', 'information_schema')`)) {
    if (!catalogue.has(r.fn)) catalogue.set(r.fn, new Set());
    catalogue.get(r.fn).add(r.schema);
  }

  let failures = 0, risks = 0;

  for (const key of keys) {
    const app = APPS[key];
    process.stdout.write(`\n=== ${app.label}  (${app.url}) ===\n`);

    // 🛑 AN UNREACHABLE HOST IS A FAILURE, NOT A SKIP (2026-08-04).
    // This used to `console.log('SKIP') ; continue`, which meant a dead domain produced NO failure, the
    // run printed "✅ every RPC resolves" and exited 0. That is exactly how review.unclogme.app sailed
    // through after Admin Review moved: the one check that should have caught a domain going dead was
    // defeated by the very condition it exists to detect. A check that cannot fail is not a check.
    let bundle;
    try { bundle = await fetchBundle(app.url); }
    catch (e) {
      console.log(`  🛑 FAIL — cannot reach ${app.url}: ${e.message}`);
      console.log('     Either the app moved domain (update APPS above, and the audit.log_change Origin');
      console.log('     CASE, and the Auth uri_allow_list) or it is genuinely down. Both are worth a stop.');
      failures++; continue;
    }

    const code = [...bundle.files.values()].join('\n');
    const x = extract(bundle.files);
    const { clientSchemas, reached, candidates, rows } = judge(x, catalogue);
    const direct = [...new Set(x.calls.map(c => c.name))];
    const resolved = x.calls.filter(c => c.schema).length;
    console.log(`  bundle: ${bundle.chunks} chunks, ${bundle.bytes.toLocaleString()} bytes`);
    console.log(`  client schemas pinned: ${x.pins.join(', ') || '(none, so public)'}; with .schema(): ${x.perCall.join(', ') || '(none)'}`);

    if (x.indirect) {
      console.log(`  ⚠ ${x.indirect} .rpc(<variable>) call site(s): the name is NOT a literal at the call site,`);
      console.log(`    so the ${direct.length} literal match(es) are a FLOOR, not this app's RPC surface.`);
      console.log(`    This is why pass B exists. Do not read the literal count as coverage.`);
    }
    console.log(`  rpc names: ${direct.length} literal at call site (${resolved} of ${x.calls.length} sites resolved to a schema) + ${candidates.length} string-literal ∩ catalogue`);
    if (candidates.length && !x.indirect) console.log(`    not calls, no wrapper in this app: ${candidates.join(', ')}`);

    // POSITIVE CONTROL — and note what it tests. The FIRST version of this check treated "zero
    // RPCs" as a broken extractor and hard-failed. That was wrong: Admin Review legitimately makes
    // zero `.rpc()` calls (it uses only table reads/writes), so the check reported a FAIL on a
    // healthy app. The control has to prove the INSTRUMENT works, not assume the app must have
    // RPCs. So: assert the supabase client library is present in the bundle. If it is and there
    // are no call sites, zero is a real, correct answer.
    const libPresent = /createClient|supabase-js|\.rpc\(/.test(code);
    // ⚠ A THIRD TRANSPORT EXISTS, and treating its absence as a broken check is a FALSE FAIL
    // (found 2026-07-31 the moment DUMP Schedule was added). DUMP ships NO supabase-js: its entire
    // backend surface is one `fetch` to `.../functions/v1/dump-visit-create`. Measured: createClient
    // 0, rest/v1 0, .rpc( 0, and all six `.from(` hits are `Array.from`/`Buffer.from`. So zero RPCs
    // is the CORRECT answer, exactly like Admin Review's legitimate zero above — the control must
    // prove the instrument can see a backend, not demand one particular client library.
    const edgeOnly = !libPresent && /\/functions\/v1\//.test(code);
    if (edgeOnly) {
      const fns = [...new Set([...code.matchAll(/\/functions\/v1\/([a-zA-Z0-9_-]+)/g)].map(m => m[1]))];
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
    const held = [...catalogue.values()].filter(s => reached.some(r => s.has(r))).length;
    if (!held) {
      console.log(`  🛑 FAIL: 0 functions found in [${reached.join(', ')}]. The catalogue query is broken,`);
      console.log('    so pass B could only ever return zero. BROKEN CHECK, not a clean app.');
      failures++; continue;
    }
    console.log(`  control: ${held} function(s) exist in [${reached.join(', ')}], so the intersection is meaningful`);

    // THIRD POSITIVE CONTROL, and the one that speaks for the verdicts on THIS bundle. A call the app
    // is known to make must be seen on its schema, and moving that function out of the schema must
    // flip the verdict to FAIL. That second half replays the 2026-07-30 bug on the live bytes.
    if (app.control) {
      const [schema, fn] = app.control.split('.');
      const seen = x.calls.some(c => c.name === fn && (c.schema ? c.schema === schema : clientSchemas.length === 1 && clientSchemas[0] === schema));
      const moved = new Map(catalogue).set(fn, new Set(['__moved__']));
      const flips = judge(x, moved).rows.some(r => r.fn === fn && r.verdict === 'fail');
      if (!seen || !flips || !catalogue.get(fn)?.has(schema)) {
        console.log(`  🛑 FAIL: control ${app.control}: seen on that schema ${seen}, flips to FAIL when moved ${flips}, in the catalogue ${!!catalogue.get(fn)?.has(schema)}.`);
        console.log('    BROKEN CHECK or a changed app. Until this holds, the verdicts below prove nothing.');
        failures++; continue;
      }
      console.log(`  control: ${app.control} seen on its schema, and judged FAIL when moved out of it`);
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
    const atRisk = rows.filter(r => r.verdict === 'risk').map(r => r.fn);
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

    for (const { fn, via, verdict, why } of rows) {
      // How we know about this name at all. A `candidate` came FROM the catalogue, so it can never
      // hit the FAIL branch — only a literal call site can name something that does not exist,
      // which is precisely the 2026-07-30 dead-button shape.
      if (verdict === 'fail') {
        console.log(`  🛑 FAIL      ${fn.padEnd(30)} [${via}] ${why}: unreachable`);
        failures++;
      } else if (verdict === 'risk') {
        const ev = proven.get(fn);
        if (ev) {
          console.log(`  ok (proven) ${fn.padEnd(30)} ${why}, but ${ev.n} successful call(s) through /rpc/${fn}, last ${ev.last_seen}`);
        } else {
          console.log(`  ⚠ AT-RISK   ${fn.padEnd(30)} [${via}] ${why}, and NO successful call on record`);
          risks++;
        }
      } else {
        console.log(`  ok          ${fn.padEnd(30)} [${via}] ${why}`);
      }
    }
  }

  console.log('');
  if (failures) {
    console.log(`🛑 ${failures} unreachable RPC(s), or a failed control. An app is calling something it cannot reach, or the instrument is blind.`);
  }
  if (risks) {
    console.log(`⚠ ${risks} at-risk RPC(s): the call's client could not be resolved, and the function is not in every schema the app's clients pin.`);
    console.log('  This is the exact shape of the 2026-07-30 dead-button bug. For each one, confirm the');
    console.log('  client that calls it is pinned to a schema where it exists — or add the missing wrapper.');
    console.log('');
    console.log('  ⚠ BEFORE TREATING ONE AS A BUG: a READ-ONLY rpc writes no audit row, so "no successful');
    console.log('    call on record" is EXPECTED for functions that only SELECT (portal reads, search).');
    console.log('    Absence is not evidence either way — exercise the app surface that calls it instead.');
    console.log('    Only a WRITING rpc with zero calls on record is genuinely suspicious.');
  }
  if (!failures && !risks) console.log('✅ every RPC an app calls resolves in the schema the call goes to.');

  process.exit(failures ? 1 : risks ? 1 : 0);
})().catch(e => { console.error('CHECK ERRORED:', e.message); process.exit(2); });
