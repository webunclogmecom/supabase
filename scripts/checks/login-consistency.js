// login-consistency.js
// Audits every auth-gated PRODUCTION app for a consistent login: the canonical Command Deck,
// a working "Forgot password?" reset, Google account choice, and a redirect back to the RIGHT app.
//
// Why a dedicated scanner: a login defect looks identical to "the app is broken" from the outside
// (Admin Review, 2026-08-06), so the only reliable check is the shipped bytes.
//
// 🛑 INSTRUMENT RULES, learned the hard way in this workspace:
//  - SEED FROM REAL ROUTES. A '/'-only walk misses lazily-loaded route chunks entirely.
//  - EVERY APP CARRIES ITS OWN POSITIVE CONTROL. A zero on an app whose control did not fire is an
//    untested instrument, not a finding, and is reported as UNKNOWN rather than as a gap.
//  - Quote-delimiter agnostic where a literal is matched: capture the quote and back-reference it,
//    or a backtick-quoted bundle silently scores zero.
//
// Usage: node scripts/checks/login-consistency.js

const APPS = [
  { name: 'Visit Calendar',  origin: 'https://calendar.unclogme.app', routes: ['/'],                          expectSub: 'Sign in to the Visit Calendar' },
  { name: 'DERM Tracker',    origin: 'https://derm.unclogme.app',     routes: ['/', '/visits/1360', '/manifests'], expectSub: 'Sign in to the DERM Tracker' },
  { name: 'Admin Review',    origin: 'https://admin.unclogme.app',    routes: ['/'],                          expectSub: 'Sign in to Admin Review' },
  { name: 'Client App',      origin: 'https://clients.unclogme.app',  routes: ['/', '/clients/76'],           expectSub: 'Sign in to' },
  { name: 'Stamp Studio',    origin: 'https://stamp.unclogme.app',    routes: ['/'],                          expectSub: 'Sign in to Stamp Studio' },
  // Field Portal (fp) and DUMP Schedule are deliberately auth-free: QR access. Not audited here.
];

const get = async (u) => { try { const r = await fetch(u); return r.ok ? await r.text() : null; } catch { return null; } };

async function walk(origin, routes) {
  const seen = new Set(), q = [], bodies = [];
  for (const route of routes) {
    const h = await get(origin + route);
    if (!h) continue;
    bodies.push(h);
    for (const m of h.matchAll(/["'(]([^"'()\s]*\/assets\/[^"'()\s]+\.js)["')]/g)) q.push(new URL(m[1], origin).href);
  }
  while (q.length) {
    const u = q.shift(); if (seen.has(u)) continue; seen.add(u);
    const b = await get(u); if (!b) continue; bodies.push(b);
    for (const m of b.matchAll(/["'(]([^"'()\s]*\/assets\/[^"'()\s]+\.js)["')]/g)) {
      const n = new URL(m[1], origin).href; if (!seen.has(n)) q.push(n);
    }
  }
  return { chunks: seen.size, all: bodies.join('\n') };
}

(async () => {
  const rows = [];
  for (const app of APPS) {
    const { chunks, all } = await walk(app.origin, app.routes);
    const has = (s) => all.includes(s);
    const rx = (re) => re.test(all);

    // ---- POSITIVE CONTROLS: must fire or every result below is meaningless ----
    const control = {
      reachable: all.length > 0,
      bytes: all.length,
      chunks,
      supabase_client: has('supabase'),
      prod_backend: has('wbasvhvvismukaqdnouk'),
      any_auth_call: has('signInWith'),
    };
    const controlOk = control.reachable && control.bytes > 50000 && control.supabase_client && control.any_auth_call;

    rows.push({
      app: app.name,
      controlOk,
      control,
      // --- canonical Command Deck login ---
      deck_welcome_back:   has('Welcome back'),
      deck_google_btn:     has('Continue with Google'),
      deck_or_continue:    has('or continue with email'),
      deck_remember_me:    has('Remember me'),
      deck_footer:         has('Internal operations'),
      deck_subtext:        has(app.expectSub),
      remember_flag_key:   has('unclogme-remember-me'),
      // --- password reset ---
      forgot_link:         has('Forgot password?'),
      reset_fn:            has('resetPasswordForEmail'),
      recovery_mode:       has('PASSWORD_RECOVERY'),
      set_new_password:    has('updateUser'),
      // --- Google: choice + returns to the RIGHT app ---
      oauth_present:       has('signInWithOAuth'),
      redirect_to_origin:  rx(/redirectTo:\s*window\.location\.origin/) || has('redirectTo:window.location.origin'),
      select_account:      has('select_account'),
      // --- staff gate ---
      staff_gate:          has('staff only') || rx(/\["ayache\.com","unclogme\.com"\]/) || has('unclogme.com'),
    });
  }

  const F = (b) => (b ? 'yes' : 'NO ');
  const pad = (s, n) => String(s).padEnd(n);
  console.log('\n=== CONTROLS (a row that fails here is UNKNOWN, not a finding) ===');
  console.log(pad('app', 16) + pad('chunks', 8) + pad('bytes', 10) + pad('prod', 6) + 'control');
  for (const r of rows) console.log(pad(r.app, 16) + pad(r.control.chunks, 8) + pad(r.control.bytes, 10) + pad(F(r.control.prod_backend), 6) + (r.controlOk ? 'OK' : '*** FAILED ***'));

  const groups = [
    ['CANONICAL LOGIN (Command Deck)', ['deck_welcome_back', 'deck_google_btn', 'deck_or_continue', 'deck_remember_me', 'deck_footer', 'deck_subtext', 'remember_flag_key']],
    ['PASSWORD RESET',                 ['forgot_link', 'reset_fn', 'recovery_mode', 'set_new_password']],
    ['GOOGLE: choice + right app',     ['oauth_present', 'redirect_to_origin', 'select_account']],
    ['STAFF GATE',                     ['staff_gate']],
  ];
  for (const [title, keys] of groups) {
    console.log('\n=== ' + title + ' ===');
    console.log(pad('check', 22) + rows.map((r) => pad(r.app.slice(0, 14), 16)).join(''));
    for (const k of keys) {
      console.log(pad(k, 22) + rows.map((r) => pad(r.controlOk ? F(r[k]) : '?', 16)).join(''));
    }
  }

  const gaps = [];
  for (const r of rows) {
    if (!r.controlOk) { gaps.push(`${r.app}: CONTROL FAILED - cannot assess, do not treat as a gap`); continue; }
    if (!r.forgot_link || !r.reset_fn) gaps.push(`${r.app}: password reset missing (link=${r.forgot_link} reset=${r.reset_fn})`);
    if (!r.recovery_mode || !r.set_new_password) gaps.push(`${r.app}: cannot COMPLETE a reset (recovery=${r.recovery_mode} setPw=${r.set_new_password})`);
    if (!r.redirect_to_origin) gaps.push(`${r.app}: NO redirectTo origin - Google will bounce to the Supabase site_url (the Calendar), not this app`);
    if (!r.select_account) gaps.push(`${r.app}: no account chooser`);
    if (!r.deck_welcome_back || !r.deck_google_btn || !r.deck_footer) gaps.push(`${r.app}: not the canonical Command Deck login`);
  }
  console.log('\n=== GAPS ===');
  if (!gaps.length) console.log('  none');
  gaps.forEach((g) => console.log('  - ' + g));
  console.log('\n--- audit complete --- ' + JSON.stringify({ probe: 'login_consistency', apps: rows.length, gaps: gaps.length }));
})();
