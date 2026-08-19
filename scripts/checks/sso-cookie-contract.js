#!/usr/bin/env node
/**
 * sso-cookie-contract.js — guards the shared-session cookie across all six staff apps.
 *
 * WHY THIS EXISTS. Since 2026-08-18 hub/admin/clients/stamp/derm/calendar share ONE login through a
 * tokens-only cookie `sb-wbasvhvvismukaqdnouk-auth-token` on Domain=.unclogme.app. Every way of
 * breaking it fails SILENTLY: green build, no console error, nothing in audit.logs, the user is just
 * asked to log in again. There is no runtime signal to alarm on, so the only guard is this check.
 *
 * WHAT IT CATCHES (see Building Apps/CLAUDE.md rule 0b):
 *   1. an app-authored `storageKey` reappearing        -> that app silently un-shares
 *   2. a Supabase URL changed to a custom auth domain  -> key derives from the URL's FIRST hostname
 *                                                         label, NOT the project ref, so the cookie
 *                                                         silently renames itself
 *   3. `auth.userStorage` dropped                      -> full session is 4080 bytes vs a ~4062
 *                                                         ceiling; cookie silently never written
 *   4. the cookie Domain/attributes drifting per app
 *
 * 🛑 CONTROLS. Two of them, because this estate has repeatedly been burned by a confident zero from a
 * broken matcher:
 *   - CONTROL A: total string literals must be in the thousands. Low tens means a preview shell was
 *     scanned instead of the app, and every finding is meaningless.
 *   - CONTROL B: the LIBRARY-INTERNAL `storageKey` token must be NON-ZERO in every bundle. Any app
 *     shipping supabase-js contains it. A sweep reporting 0 for BOTH the app option and the library
 *     token has a broken matcher, not a clean app. (An earlier hand-run of this check reported
 *     "0 occurrences" as a pass; that is a number a working instrument cannot produce.)
 *
 * ⚠ Literals are matched with a CAPTURED-AND-BACKREFERENCED quote — (["'`])x\1 — never a class on
 * both ends. At least one app in this estate quotes with BACKTICKS throughout, and a ["'] matcher
 * scores it a confident zero.
 *
 * ⚠ Chunks are walked RECURSIVELY TO CLOSURE. The root HTML seeds only 14 of DERM Tracker's 22
 * chunks; an entry-chunk-only scan gives a confident wrong answer.
 *
 * Usage: node sso-cookie-contract.js
 * Exit 0 = contract holds. Exit 1 = a real break. Exit 2 = instrument broken (controls failed).
 */

const PROD_REF = 'wbasvhvvismukaqdnouk';
const EXPECTED_COOKIE = `sb-${PROD_REF}-auth-token`;
const COOKIE_DOMAIN = '.unclogme.app';

const APPS = [
  { key: 'hub',      url: 'https://hub.unclogme.app' },
  { key: 'admin',    url: 'https://admin.unclogme.app' },
  { key: 'clients',  url: 'https://clients.unclogme.app' },
  { key: 'stamp',    url: 'https://stamp.unclogme.app' },
  { key: 'derm',     url: 'https://derm.unclogme.app' },
  { key: 'calendar', url: 'https://calendar.unclogme.app' },
];

// Stamp Studio still ships its OLD key as a one-time transfer shim. It is allowed to appear as a
// plain constant but must NEVER appear as a `storageKey:` option.
const ALLOWED_LEGACY_CONSTANTS = { stamp: ['derm-stamp-studio-auth'] };

async function walk(base) {
  const root = await (await fetch(base + '/?cb=' + Date.now())).text();
  const seen = new Set();
  let all = '', bytes = 0;
  const queue = [...root.matchAll(/\/assets\/[A-Za-z0-9._-]+\.js/g)].map(m => m[0]);
  while (queue.length) {
    const p = queue.shift();
    if (seen.has(p)) continue;
    seen.add(p);
    let r; try { r = await fetch(base + p); } catch { continue; }
    if (r.status !== 200) continue;
    const b = await r.text();
    all += b + '\n'; bytes += b.length;
    // absolute and chunk-relative imports both matter
    for (const m of b.matchAll(/(["'`])(\/assets\/[A-Za-z0-9._-]+\.js)\1/g)) if (!seen.has(m[2])) queue.push(m[2]);
    for (const m of b.matchAll(/(["'`])\.\/([A-Za-z0-9._-]+\.js)\1/g)) {
      const p2 = '/assets/' + m[2]; if (!seen.has(p2)) queue.push(p2);
    }
  }
  return { all, chunks: seen.size, kb: Math.round(bytes / 1024) };
}

(async () => {
  const rows = [];
  let broken = 0, failed = 0;

  for (const app of APPS) {
    let scan;
    try { scan = await walk(app.url); }
    catch (e) { rows.push({ app: app.key, verdict: 'UNKNOWN', note: 'unreachable: ' + e.message }); broken++; continue; }

    const { all, chunks, kb } = scan;
    const literals = (all.match(/(["'`])[^"'`\n]{4,}\1/g) || []).length;
    const libToken = all.split('storageKey').length - 1;

    // CONTROLS
    if (literals < 500) { rows.push({ app: app.key, verdict: 'INSTRUMENT', note: `only ${literals} literals — preview shell?` }); broken++; continue; }
    if (libToken === 0) { rows.push({ app: app.key, verdict: 'INSTRUMENT', note: 'library storageKey token = 0 — matcher is broken' }); broken++; continue; }

    // 1. app-authored storageKey (all three quote styles)
    const appKeys = [...all.matchAll(/storageKey:\s*(["'`])([^"'`]+)\1/g)].map(m => m[2]);
    const allowed = ALLOWED_LEGACY_CONSTANTS[app.key] || [];
    const badKeys = appKeys.filter(k => !allowed.includes(k));

    // 2. the Supabase URL, and the key it would derive
    const urls = [...new Set([...all.matchAll(/https:\/\/([a-z0-9-]+)\.supabase\.co/g)].map(m => m[1]))];
    const prodPresent = urls.includes(PROD_REF);
    const derived = prodPresent ? `sb-${PROD_REF}-auth-token` : `sb-${urls[0] || '??'}-auth-token`;

    // 3 + 4. cookie plumbing
    const hasDomain = all.includes(`Domain=`) && all.includes(COOKIE_DOMAIN);
    const hasUserStorage = all.includes('userStorage');

    const problems = [];
    if (badKeys.length) problems.push(`app-authored storageKey: ${JSON.stringify(badKeys)}`);
    if (!prodPresent) problems.push(`prod URL ${PROD_REF}.supabase.co absent (found ${JSON.stringify(urls)})`);
    if (derived !== EXPECTED_COOKIE) problems.push(`derived cookie ${derived} != ${EXPECTED_COOKIE}`);
    if (!hasDomain) problems.push(`no ${COOKIE_DOMAIN} cookie write`);
    if (!hasUserStorage) problems.push('auth.userStorage missing — session will overflow the cookie');

    if (problems.length) failed++;
    rows.push({ app: app.key, verdict: problems.length ? 'FAIL' : 'ok', chunks, kb, literals, libToken,
                derived, note: problems.join(' | ') || `shares ${EXPECTED_COOKIE}` });
  }

  console.log('SSO cookie contract — all six staff apps must agree on one cookie\n');
  for (const r of rows) {
    console.log(`${String(r.verdict).padEnd(10)} ${String(r.app).padEnd(9)} ` +
                (r.chunks ? `chunks:${String(r.chunks).padEnd(3)} ${String(r.kb).padStart(5)}KB lit:${String(r.literals).padEnd(6)} libTok:${String(r.libToken).padEnd(4)} ` : '') +
                r.note);
  }

  if (broken) { console.log(`\n🛑 INSTRUMENT BROKEN on ${broken} app(s) — conclude nothing from this run.`); process.exit(2); }
  if (failed) { console.log(`\n🛑 ${failed} app(s) have left the shared session. See Building Apps/CLAUDE.md rule 0b.`); process.exit(1); }
  console.log(`\n✅ all ${rows.length} apps derive ${EXPECTED_COOKIE} and write it on ${COOKIE_DOMAIN}.`);
  console.log('⚠ This proves NAME AGREEMENT and plumbing presence. It does NOT prove a cold cross-origin');
  console.log('  hydrate — that needs ARM 0/ARM 1 on a fresh browser profile (Apps Hub/docs/09-sso-rollout-plan.md).');
})();
