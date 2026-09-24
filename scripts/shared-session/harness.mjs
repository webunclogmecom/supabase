// harness.mjs: a small fake browser for testing a shared-session module WITHOUT signing in anywhere.
//
// It models exactly the three things the module touches, per origin, with the lifetimes a real browser
// gives them:
//   document.cookie   a jar with Domain matching (RFC 6265 5.1.3), Max-Age / Expires, deletion by
//                     Max-Age=0, and SESSION cookies (no Max-Age, no Expires) that restart() drops;
//   localStorage      per origin, SURVIVES restart();
//   sessionStorage    per origin (one tab per origin), CLEARED by restart().
// restart() is the browser quitting and reopening WITHOUT session restore. That is the case a Max-Age
// inspection cannot see: it proves what the cookie does, not what the OTHER stores bring back.
//
// install() points globalThis.window / document / localStorage / sessionStorage / location at the
// current origin; visit(host) switches origin. Modules must read these at CALL time (the canonical one
// does), so a module imported once can be exercised on several hosts.

export function makeBrowser(startHost = 'hub.unclogme.app') {
  let host = startHost
  let now = Date.UTC(2026, 8, 24, 12, 0, 0)
  const jar = [] // { name, value, domain, hostOnly, path, expires: ms | null }
  const local = new Map(), session = new Map() // origin -> Map

  const domainMatch = (h, d) => h === d || h.endsWith('.' + d)
  const alive = (c) => c.expires === null || c.expires > now
  const store = (maps) => {
    const m = () => { if (!maps.has(host)) maps.set(host, new Map()); return maps.get(host) }
    return {
      getItem: (k) => (m().has(String(k)) ? m().get(String(k)) : null),
      setItem: (k, v) => { m().set(String(k), String(v)) },
      removeItem: (k) => { m().delete(String(k)) },
      clear: () => m().clear(),
      key: (i) => [...m().keys()][i] ?? null,
      get length() { return m().size },
    }
  }
  const localStorage = store(local), sessionStorage = store(session)

  const document = {
    get cookie() {
      return jar.filter((c) => alive(c) && (c.hostOnly ? c.domain === host : domainMatch(host, c.domain)))
        .map((c) => `${c.name}=${c.value}`).join('; ')
    },
    set cookie(str) {
      const [pair, ...attrs] = String(str).split(';').map((s) => s.trim())
      const eq = pair.indexOf('=')
      if (eq < 1) return
      const name = pair.slice(0, eq), value = pair.slice(eq + 1)
      let domain = host, hostOnly = true, path = '/', expires = null, maxAge = null
      for (const a of attrs) {
        const i = a.indexOf('='), k = (i < 0 ? a : a.slice(0, i)).toLowerCase(), v = i < 0 ? '' : a.slice(i + 1)
        if (k === 'domain') { const d = v.replace(/^\./, '').toLowerCase(); if (!domainMatch(host, d)) return; domain = d; hostOnly = false }
        else if (k === 'path') path = v || '/'
        else if (k === 'max-age') { if (/^-?[0-9]+$/.test(v)) maxAge = Number(v) } // Chrome ignores a non-integer Max-Age
        else if (k === 'expires') { const t = Date.parse(v); if (!Number.isNaN(t)) expires = t }
      }
      if (maxAge !== null) expires = maxAge <= 0 ? 0 : now + maxAge * 1000 // Max-Age wins over Expires
      if (Buffer.byteLength(name + value) > 4096) return // the real browser drops it silently
      const at = jar.findIndex((c) => c.name === name && c.domain === domain && c.hostOnly === hostOnly && c.path === path)
      if (at >= 0) jar.splice(at, 1)
      if (expires !== null && expires <= now) return // a deletion
      jar.push({ name, value, domain, hostOnly, path, expires })
    },
  }

  const b = {
    get host() { return host },
    visit(h) { host = h; return b },
    restart() { // quit + reopen, no session restore
      for (let i = jar.length - 1; i >= 0; i--) if (jar[i].expires === null) jar.splice(i, 1)
      session.clear()
      return b
    },
    advance(ms) { now += ms; return b },
    install() {
      const loc = { get hostname() { return host }, get host() { return host }, hash: '', search: '', pathname: '/', get origin() { return 'https://' + host } }
      const win = { get location() { return loc }, localStorage, sessionStorage, document }
      Object.assign(globalThis, { window: win, document, localStorage, sessionStorage })
      Object.defineProperty(globalThis, 'location', { value: loc, configurable: true, writable: true })
      return b
    },
    cookies: (name) => jar.filter((c) => !name || c.name === name).map((c) => ({ ...c, session: c.expires === null })),
    local: (h = host) => new Map(local.get(h) ?? []),
    sessionOf: (h = host) => new Map(session.get(h) ?? []),
  }
  return b
}

export const KEY = 'sb-wbasvhvvismukaqdnouk-auth-token'
export const SESSION = JSON.stringify({ access_token: 'a.b.c', token_type: 'bearer', expires_in: 3600, expires_at: 1790000000, refresh_token: 'rt-1' })
export const SESSION2 = JSON.stringify({ access_token: 'd.e.f', token_type: 'bearer', expires_in: 3600, expires_at: 1790003600, refresh_token: 'rt-2' })
export const USER = JSON.stringify({ user: { id: 'u1', email: 'someone@unclogme.com' } })

// The scenarios. `mod(host)` returns { storage, user, setRemember, load? } for the app served on that
// host (for the canonical module every host returns the same object). `load` is what the module does
// when a page loads; it runs after every visit and restart, as a real page load would.
export function scenarios(mod, { hosts = ['hub.unclogme.app', 'admin.unclogme.app'], preview = 'x.lovable.app' } = {}) {
  const [A, B] = hosts
  const out = []
  const t = (name, fn) => { try { const r = fn(); out.push({ name, ok: r === true, got: r === true ? '' : String(r) }) } catch (e) { out.push({ name, ok: false, got: 'threw ' + e.message }) } }
  let b
  const at = (h) => { b.visit(h); const m = mod(h); m.load?.(); return m } // a page load on host h
  const fresh = (h = A) => { b = makeBrowser(h).install(); return at(h) }
  const restart = () => { b.restart() }
  const signIn = (m, remember) => { if (remember !== undefined) m.setRemember(remember); m.user.setItem(KEY + '-user', USER); m.storage.setItem(KEY, SESSION) }
  const writeRaw = (s) => { globalThis.document.cookie = s }

  // --- the rule: unticked dies with the browser ---
  t('OFF + restart: signed out (cookie, sessionStorage AND localStorage give nothing back)', () => {
    signIn(fresh(), false); restart(); const v = at(A).storage.getItem(KEY)
    return v === null || `still signed in after restart: ${v.slice(0, 40)}`
  })
  t('OFF: nothing that restores the session is left in localStorage', () => {
    signIn(fresh(), false)
    const left = [...b.local(A).keys()].filter((k) => k.startsWith('sb-') && !k.endsWith('-user'))
    return left.length === 0 || `localStorage holds ${left.join(', ')}`
  })
  t('OFF + restart: no user record (email) is left behind either', () => {
    signIn(fresh(), false); restart(); at(A); at(B)
    const left = [...b.local(A).keys(), ...b.local(B).keys()].filter((k) => k.endsWith('-user'))
    return left.length === 0 || `left: ${left.join(', ')}`
  })
  t('OFF: the session cookie is a SESSION cookie', () => {
    signIn(fresh(), false)
    const c = b.cookies(KEY); return (c.length === 1 && c[0].session) || JSON.stringify(c.map((x) => ({ d: x.domain, session: x.session })))
  })
  t('OFF, before restart: another app is signed in by the shared cookie (SSO still works)', () => {
    signIn(fresh(), false); return at(B).storage.getItem(KEY) === SESSION || 'the other app sees no session'
  })
  t('OFF: a token refresh in ANOTHER app keeps it a session cookie (no silent upgrade)', () => {
    signIn(fresh(), false); at(B).storage.setItem(KEY, SESSION2); restart()
    const a = at(A).storage.getItem(KEY), bb = at(B).storage.getItem(KEY)
    return (a === null && bb === null) || `after restart A=${a ? 'signed in' : 'out'} B=${bb ? 'signed in' : 'out'}`
  })
  t('UNKNOWN choice (no flag: a recovery link, an app without the checkbox) + restart: signed out', () => {
    signIn(fresh()); restart(); const v = at(A).storage.getItem(KEY)
    return v === null || 'an unknown choice was treated as Remember me'
  })
  t('flag missing while another app holds an unticked session cookie: the first save here keeps it a session cookie', () => {
    fresh(B); writeRaw(`${KEY}=${encodeURIComponent(SESSION)}; Domain=.unclogme.app; Path=/; Secure; SameSite=Lax`)
    at(A).storage.setItem(KEY, SESSION2); restart(); const v = at(A).storage.getItem(KEY)
    return v === null || 'the session was upgraded to a persistent cookie'
  })
  t('OFF: a copy an older module left in localStorage is ignored and deleted', () => {
    const m = fresh(); m.setRemember(false); restart()
    globalThis.localStorage.setItem(KEY, SESSION) // the residue of the old mirror
    const v = at(A).storage.getItem(KEY); const left = b.local(A).has(KEY)
    return (v === null && !left) || `returned ${v ? 'the stale session' : 'null'}, residue ${left ? 'kept' : 'removed'}`
  })

  t('a tab still running an OLDER version writes a copy after this page loaded: it never signs this page in', () => {
    const m = fresh(); m.setRemember(true); restart(); at(A) // this page has loaded; the cookie is gone
    globalThis.localStorage.setItem(KEY, SESSION) // an old-bundle tab of the same app writes its mirror now
    const v = mod(A).storage.getItem(KEY)
    return v === null || 'the late copy stood in for the missing cookie'
  })

  // --- the control: ticked survives, and nothing downgrades it ---
  t('ON + restart: still signed in (control: the restart does not simply wipe everything)', () => {
    signIn(fresh(), true); restart(); return at(A).storage.getItem(KEY) === SESSION || 'signed out'
  })
  t('ON: the session cookie is persistent', () => {
    signIn(fresh(), true)
    const c = b.cookies(KEY); return (c.length === 1 && !c[0].session) || JSON.stringify(c.map((x) => ({ d: x.domain, session: x.session })))
  })
  t('ON: a token refresh in ANOTHER app keeps it persistent (no silent downgrade)', () => {
    signIn(fresh(), true); at(B).storage.setItem(KEY, SESSION2); restart()
    return at(A).storage.getItem(KEY) === SESSION2 || 'signed out after a refresh elsewhere'
  })
  t('ON: saves keep the choice alive (a flag written with a 7-day cap survives 30 days of use)', () => {
    const m = fresh(); writeRaw('unclogme-remember-me=true; Domain=.unclogme.app; Path=/; Secure; SameSite=Lax; Max-Age=604800')
    m.user.setItem(KEY + '-user', USER); m.storage.setItem(KEY, SESSION)
    for (let d = 0; d < 30; d++) { b.advance(86400000); at(d % 2 ? A : B).storage.setItem(KEY, SESSION2) }
    restart(); return at(A).storage.getItem(KEY) === SESSION2 || 'the choice expired under a live session'
  })

  // --- one session for every app ---
  t('sign-out in one app signs every app out, including one that still has a page open', () => {
    signIn(fresh(), true); at(B).storage.getItem(KEY); mod(B).storage.removeItem(KEY)
    b.visit(A); const a = mod(A).storage.getItem(KEY) // A's open page reads again, no reload
    return (a === null && b.cookies(KEY).length === 0) || `A still reads ${a ? 'the session' : 'null'}, cookies left ${b.cookies(KEY).length}`
  })
  t('a session too big for the cookie: the old cookie goes, and no app reads a rotated-away token', () => {
    const big = JSON.stringify({ access_token: 'x'.repeat(4200), refresh_token: 'rt-big' })
    const m = fresh(); signIn(m, true); m.storage.setItem(KEY, big)
    const a = mod(A).storage.getItem(KEY), bb = at(B).storage.getItem(KEY)
    const stale = [a, bb].some((v) => v && v.includes('rt-1'))
    return !stale || `stale refresh token still readable: A=${a ? a.slice(0, 30) : null} B=${bb ? bb.slice(0, 30) : null}`
  })
  t('the Remember me choice survives a restart when ticked, and is shared', () => {
    fresh().setRemember(true); restart(); b.visit(B)
    const seen = globalThis.document.cookie.split('; ').includes('unclogme-remember-me=true') // what app B can actually read
    const c = b.cookies('unclogme-remember-me'); return (seen && c.length === 1 && !c[0].session) || JSON.stringify({ seenFromB: seen, jar: c })
  })

  // --- hosts without the shared cookie (Lovable previews) ---
  t('preview host (no shared cookie), OFF + restart: signed out', () => {
    signIn(fresh(preview), false); restart(); const v = at(preview).storage.getItem(KEY); return v === null || 'still signed in'
  })
  t('preview host, OFF: a copy an older module left in localStorage is ignored', () => {
    const m = fresh(preview); m.setRemember(false); restart(); at(preview)
    globalThis.localStorage.setItem(KEY, SESSION)
    const v = mod(preview).storage.getItem(KEY); return v === null || 'the old copy was used'
  })
  t('preview host, ON + restart: still signed in', () => {
    signIn(fresh(preview), true); restart(); return at(preview).storage.getItem(KEY) === SESSION || 'signed out'
  })
  return out
}
