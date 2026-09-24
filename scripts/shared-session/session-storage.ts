// src/lib/session-storage.ts: THE shared staff session, canonical copy (Building Apps rule 0b).
//
// Every staff app on *.unclogme.app ships THIS FILE, byte-identical. Source of truth:
// `Supabase/scripts/shared-session/session-storage.ts` (public repo webunclogmecom/supabase, so a Lovable
// project can download the exact bytes). Change it there, prove it with run.mjs and mutants.mjs in the
// same folder, roll it to every app, then run live-restart.mjs. Never edit one app's copy.
//
// What it does
// - On *.unclogme.app the session (tokens only) lives in ONE cookie on Domain=.unclogme.app, so signing
//   in to one app signs you in to all of them, and signing out of one signs you out of all of them. The
//   cookie name is supabase-js's default key: never pass a storageKey.
// - THE COOKIE IS THE ONLY SOURCE OF TRUTH THERE. No per-origin copy of the session is kept or read: a
//   missing cookie means signed out (by another app, by the browser closing, by expiry). Copies older
//   modules left in localStorage/sessionStorage are deleted when found.
// - "Remember me" (Fred, 2026-08-18, WORKING-NOW decision 1): ticked = a persistent cookie; unticked =
//   a SESSION cookie that dies with the browser and is NEVER silently upgraded. The choice is a cookie on
//   .unclogme.app beside the session, rewritten with the same lifetime on every session write, so it
//   lives exactly as long as the session it controls. An UNKNOWN choice (no flag: a recovery or invite
//   link, an app without the checkbox, a flag an older module never wrote) counts as NOT remembered: a
//   downgrade costs one extra sign-in, an upgrade would break the rule.
// - The user object goes to per-origin localStorage through `sharedUserStorage` (auth.userStorage): the
//   full session does not fit in a cookie (4,080 bytes against a ~4,062 ceiling), tokens alone do
//   (~1.6 KB). It cannot restore a session by itself, and it is swept when its session cookie is gone.
// - On any other host (Lovable previews) there is no shared cookie: ticked keeps the session in this
//   origin's localStorage, unticked in this tab's sessionStorage.
//
// Known limit: a browser that restores the previous session (Chrome "Continue where you left off", Edge
// startup boost) restores session cookies too, so an unticked session survives what looks like a restart.
//
// Invariants that must not regress (rule 0b): no `storageKey` on createClient; the default Supabase URL
// (the cookie name derives from its first hostname label); keep auth.userStorage = sharedUserStorage;
// staff gates call `await supabase.auth.getUser()`, never `session.user`; login screens call
// setRememberMe(checkbox) BEFORE signInWithPassword / signInWithOAuth, and the checkbox starts ticked.

const REMEMBER_KEY = 'unclogme-remember-me'
const APEX = 'unclogme.app'
const COOKIE_DOMAIN = '.unclogme.app'
const REMEMBER_MAX_AGE = 400 * 24 * 60 * 60 // seconds; Chrome caps cookie lifetimes at 400 days
const COOKIE_LIMIT = 4000 // bytes of name + encoded value; the real ceiling is ~4,062 and overflow is silent
const VERIFIER_SUFFIX = '-code-verifier' // every PKCE key auth-js writes ends with this
const USER_SUFFIX = '-user' // auth-js stores the user object under `${storageKey}-user`

function hasDom(): boolean {
  return typeof window !== 'undefined' && typeof document !== 'undefined'
}

function isSharedCookieHost(): boolean {
  const h = window.location.hostname.toLowerCase()
  return h === APEX || h.endsWith(COOKIE_DOMAIN)
}

function readCookie(name: string): string | null {
  const encoded = encodeURIComponent(name)
  for (const part of document.cookie ? document.cookie.split('; ') : []) {
    const eq = part.indexOf('=')
    if (eq < 0) continue
    const n = part.slice(0, eq)
    if (n !== encoded && n !== name) continue
    const v = part.slice(eq + 1)
    try { return decodeURIComponent(v) } catch { return v }
  }
  return null
}

function writeCookie(name: string, value: string, maxAge: number | null): void {
  const parts = [`${encodeURIComponent(name)}=${encodeURIComponent(value)}`, `Domain=${COOKIE_DOMAIN}`, 'Path=/', 'Secure', 'SameSite=Lax']
  if (maxAge !== null) parts.push(`Max-Age=${maxAge}`) // no Max-Age = a session cookie
  document.cookie = parts.join('; ')
}

function deleteCookie(name: string): void {
  // both spellings of the name, host-only and domain cookies: a same-name survivor would shadow the delete
  for (const n of [encodeURIComponent(name), name]) {
    const dead = `${n}=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; SameSite=Lax`
    document.cookie = dead
    document.cookie = `${dead}; Domain=${COOKIE_DOMAIN}`
  }
}

function dropCopies(key: string): void {
  try { window.localStorage.removeItem(key); window.sessionStorage.removeItem(key) } catch { /* storage blocked */ }
}

/** Unknown = NOT remembered. */
function rememberMe(): boolean {
  if (isSharedCookieHost()) return readCookie(REMEMBER_KEY) === 'true'
  try { return window.localStorage.getItem(REMEMBER_KEY) === 'true' } catch { return false }
}

/** Login screens: call with the checkbox value BEFORE signInWithPassword / signInWithOAuth. */
export function setRememberMe(remember: boolean): void {
  if (!hasDom()) return
  const v = remember ? 'true' : 'false'
  if (isSharedCookieHost()) {
    writeCookie(REMEMBER_KEY, v, remember ? REMEMBER_MAX_AGE : null)
    try { window.localStorage.removeItem(REMEMBER_KEY) } catch { /* an older module's per-origin copy */ }
    return
  }
  try { window.localStorage.setItem(REMEMBER_KEY, v) } catch { /* storage blocked */ }
}

/**
 * Runs once when this module loads (and harness.mjs calls it to simulate a page load). On the shared
 * hosts: per-origin session copies are never valid, and a user object whose session cookie is gone is
 * residue. Neither can sign anyone in; both are removed.
 */
export function sweepStaleCopies(): void {
  if (!hasDom() || !isSharedCookieHost()) return
  try {
    for (const store of [window.localStorage, window.sessionStorage]) {
      const keys: string[] = []
      for (let i = 0; i < store.length; i++) { const k = store.key(i); if (k && /^sb-.+-auth-token/.test(k)) keys.push(k) }
      for (const k of keys) {
        const isUser = k.endsWith(USER_SUFFIX)
        if (!isUser || store === window.sessionStorage || readCookie(k.slice(0, -USER_SUFFIX.length)) === null) store.removeItem(k)
      }
    }
  } catch { /* storage blocked */ }
}
sweepStaleCopies()

/** auth.storage: the session (tokens) and the PKCE code verifiers. */
export const sharedSessionStorage = {
  getItem(key: string): string | null {
    if (!hasDom()) return null
    if (isSharedCookieHost()) {
      const c = readCookie(key)
      if (c === null) dropCopies(key) // signed out: an older module's copy must not stand in
      return c
    }
    try {
      if (rememberMe()) return window.localStorage.getItem(key)
      window.localStorage.removeItem(key)
      return window.sessionStorage.getItem(key)
    } catch { return null }
  },
  setItem(key: string, value: string): void {
    if (!hasDom()) return
    const remember = rememberMe()
    if (isSharedCookieHost()) {
      dropCopies(key)
      const size = key.length + encodeURIComponent(value).length
      if (size > COOKIE_LIMIT) {
        // Leaving the previous cookie would hand every app a refresh token that was just rotated away.
        deleteCookie(key)
        console.error(`[SSO session] ${key} is ${size} bytes, over the ${COOKIE_LIMIT}-byte cookie limit: it cannot be stored, so this browser is signed out. Shrink the JWT claims.`)
        return
      }
      writeCookie(key, value, remember ? REMEMBER_MAX_AGE : null)
      if (!key.endsWith(VERIFIER_SUFFIX)) setRememberMe(remember) // the choice lives exactly as long as the session
      return
    }
    try {
      ;(remember ? window.sessionStorage : window.localStorage).removeItem(key)
      ;(remember ? window.localStorage : window.sessionStorage).setItem(key, value)
    } catch { /* storage blocked */ }
  },
  removeItem(key: string): void {
    if (!hasDom()) return
    if (isSharedCookieHost()) deleteCookie(key)
    dropCopies(key)
  },
}

/** auth.userStorage: the user object, per origin. */
export const sharedUserStorage = {
  getItem(key: string): string | null {
    if (!hasDom()) return null
    try { return window.localStorage.getItem(key) } catch { return null }
  },
  setItem(key: string, value: string): void {
    if (!hasDom()) return
    try { window.sessionStorage.removeItem(key); window.localStorage.setItem(key, value) } catch { /* storage blocked */ }
  },
  removeItem(key: string): void {
    if (!hasDom()) return
    dropCopies(key)
  },
}
