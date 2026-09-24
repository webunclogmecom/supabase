// node --experimental-strip-types --no-warnings mutants.mjs
// Mutation test of harness.mjs against session-storage.ts: each mutant is ONE plausible edit that breaks
// a rule. Every mutant must be killed (at least one scenario fails), or the scenarios have a hole that a
// future edit could ship through at 18/18. Exit 1 if any mutant survives or any mutation no longer applies.
import fs from 'node:fs'
import { scenarios } from './harness.mjs'
const src = fs.readFileSync(new URL('./session-storage.ts', import.meta.url), 'utf8')
const MUTANTS = [
  ['shared host: a missing cookie falls back to this origin\'s localStorage copy', 'if (c === null) dropCopies(key) // signed out: an older module\'s copy must not stand in\n      return c', 'if (c === null) return window.localStorage.getItem(key)\n      return c'],
  ['an unknown choice counts as remembered', "return readCookie(REMEMBER_KEY) === 'true'", "return readCookie(REMEMBER_KEY) !== 'false'"],
  ['ticked sessions get no Max-Age', 'writeCookie(key, value, remember ? REMEMBER_MAX_AGE : null)', 'writeCookie(key, value, null)'],
  ['unticked sessions get a Max-Age too', 'writeCookie(key, value, remember ? REMEMBER_MAX_AGE : null)', 'writeCookie(key, value, REMEMBER_MAX_AGE)'],
  ['session writes stop renewing the choice', 'if (!key.endsWith(VERIFIER_SUFFIX)) setRememberMe(remember)', 'if (false) setRememberMe(remember)'],
  ['an oversize write leaves the old cookie', '        deleteCookie(key)\n        console.error', '        console.error'],
  ['cookies are written without Domain (host-only)', "`Domain=${COOKIE_DOMAIN}`, 'Path=/'", "'Path=/'"],
  ['the choice is kept per origin only', 'writeCookie(REMEMBER_KEY, v, remember ? REMEMBER_MAX_AGE : null)', 'window.localStorage.setItem(REMEMBER_KEY, v)'],
  ['the load sweep keeps user records whose session is gone', "readCookie(k.slice(0, -USER_SUFFIX.length)) === null) store.removeItem(k)", 'false) store.removeItem(k)'],
  ['sign-out leaves the cookie', 'if (isSharedCookieHost()) deleteCookie(key)\n    dropCopies(key)', 'dropCopies(key)'],
  ['preview host: unticked reads localStorage', "      window.localStorage.removeItem(key)\n      return window.sessionStorage.getItem(key)", '      return window.localStorage.getItem(key) ?? window.sessionStorage.getItem(key)'],
]
const tmp = new URL('./.mutant.ts', import.meta.url)
let bad = 0
for (let i = 0; i < MUTANTS.length; i++) {
  const [name, from, to] = MUTANTS[i]
  if (src.split(from).length !== 2) { console.log(`  STALE   ${name}: the text to mutate is not in session-storage.ts exactly once`); bad++; continue }
  fs.writeFileSync(tmp, src.replace(from, to))
  const m = await import(tmp.href + '?m=' + i)
  const origErr = console.error; console.error = () => {}
  const rows = scenarios(() => ({ storage: m.sharedSessionStorage, user: m.sharedUserStorage, setRemember: m.setRememberMe, load: m.sweepStaleCopies }))
  console.error = origErr
  const killers = rows.filter((r) => !r.ok).map((r) => r.name)
  if (!killers.length) bad++
  console.log(`  ${killers.length ? 'KILLED ' : 'SURVIVED'} ${name}${killers.length ? `  (${killers.length} scenario${killers.length > 1 ? 's' : ''})` : ''}`)
}
fs.rmSync(tmp, { force: true })
console.log(bad ? `\n${bad} mutant(s) not killed` : '\nall mutants killed')
process.exit(bad ? 1 : 0)
