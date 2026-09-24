// guard-shipped.mjs: is the analytics token guard LIVE, byte-identical, and ahead of ~flock.js on every
// page an auth redirect can land on?   node guard-shipped.mjs [--fixture=good|cooked|after]
//
// Reads the RAW served HTML (fetch, following the 307s that clients and hr issue; a fragment survives
// those). Never the browser DOM: on the TanStack apps React removes a head() inline script from the DOM
// right after hydration, so a DOM check reports "missing" for a guard that ran.
// PASS for a page = exactly one inline <script> whose text === the canonical one-liner (printed by
// analytics-token-guard.test.mjs --print), with no src/async/defer/type, located before the ~flock.js tag.
// --fixture splices a guard into the fetched HTML to prove this checker can pass (good) and can fail
// (cooked = pasted into a JS template literal, after = placed after the tracker tag).
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
const TEST = fileURLToPath(new URL('./analytics-token-guard.test.mjs', import.meta.url))
const GUARD = execFileSync(process.execPath, [TEST, '--print'], { encoding: 'utf8' }).replace(/\n$/, '')
const fixture = (process.argv.find((a) => a.startsWith('--fixture=')) || '').split('=')[1]
const PAGES = {
  hub: ['/', '/reset-password'], admin: ['/'], clients: ['/', '/reset-password'], stamp: ['/'],
  derm: ['/'], calendar: ['/'], hr: ['/employees'], planner: ['/', '/reset-password'],
}
const FLOCK = /<script\b[^>]*\bsrc="\/~flock\.js"[^>]*>/i
let bad = 0
for (const [app, paths] of Object.entries(PAGES)) {
  for (const path of [...paths, '/__guard-probe-404']) {
    const r = await fetch(`https://${app}.unclogme.app${path}`, { redirect: 'follow' })
    let html = await r.text()
    if (fixture) {
      const g = fixture === 'cooked' ? eval('`' + GUARD + '`') : GUARD
      html = fixture === 'after' ? html.replace(FLOCK, (m) => m + '</script><script>' + g) : html.replace(FLOCK, (m) => '<script>' + g + '</script>' + m)
    }
    const flockAt = html.search(FLOCK)
    const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)].map((m) => ({ at: m.index, attrs: m[1], body: m[2] }))
    const exact = scripts.filter((s) => !/\bsrc\s*=/i.test(s.attrs) && s.body === GUARD)
    const near = scripts.filter((s) => s.body.includes('__unclogmeAnalyticsGuard') && s.body !== GUARD)
    const why = []
    if (flockAt < 0) why.push('no ~flock.js tag (re-check the tracker detector)')
    if (exact.length !== 1) why.push(`${exact.length} byte-identical guard scripts`)
    for (const n of near) { let i = 0; while (n.body[i] === GUARD[i]) i++; why.push(`DRIFTED copy, first difference at char ${i}: served ${JSON.stringify(n.body.slice(i - 10, i + 10))} vs canonical ${JSON.stringify(GUARD.slice(i - 10, i + 10))}`) }
    if (exact[0] && /\b(async|defer|type)\b/i.test(exact[0].attrs)) why.push(`guard tag carries attributes: ${exact[0].attrs.trim()}`)
    if (exact[0] && flockAt >= 0 && exact[0].at > flockAt) why.push('guard comes AFTER the ~flock.js tag')
    if (why.length) bad++
    console.log(`${(app + path).padEnd(30)} ${r.status} ${why.length ? 'FAIL  ' + why.join('; ') : 'PASS'}`)
  }
}
console.log(`\ncanonical guard: ${GUARD.length} chars${fixture ? `, fixture=${fixture}` : ''}`)
process.exit(bad ? 1 : 0)
