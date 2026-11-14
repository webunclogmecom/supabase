// guard-shipped.mjs: is the analytics token guard LIVE, byte-identical, and ahead of Lovable's tracker on every
// page an auth redirect can land on, and WHICH tracker is there?   node guard-shipped.mjs [--fixture=NAME]
//
// Reads the RAW served HTML (fetch, following the 307s that clients and hr issue; a fragment survives
// those). Never the browser DOM: on the TanStack apps React removes a head() inline script from the DOM
// right after hydration, so a DOM check reports "missing" for a guard that ran.
// Two trackers are known. /~flock.js (until 2026-11-12..14) posted location.href, fragment included, to
// /~api/analytics: that is what the guard scrubs. /__l5e/events[.<hash>].js (since) posts to /__l5e/ and
// redacts on its own (measured 2026-11-14 with fake tokens, mockups/2026-11-14-l5e/measure.mjs); the guard
// does nothing for it but stays, for any project still served ~flock.js.
// PASS for a page = a known tracker tag is there, exactly one inline <script> whose text === the canonical
// one-liner (printed by analytics-token-guard.test.mjs --print), with no src/async/defer/type, located before
// the tracker tag, and an __l5e tag carries no attribute beyond the eight seen on 2026-11-14: data-replay
// switches on its session recorder (rrweb, whose Meta event records location.href) and a data-*-url moves
// its endpoint, so either one needs a new measurement before it is trusted.
// CONTROLS, every run, on the first page's HTML: each fixture is applied and must give its verdict for the
// right reason, or the run FAILS. --fixture=NAME applies one of them to every page instead.
//   good       the served guard moved to just before the tracker tag             must PASS
//   flock      the __l5e tag swapped for a ~flock.js tag (a project still on it)  must PASS
//   cooked     the guard pasted into a JS template literal                        must FAIL (drifted)
//   after      the guard placed after the tracker tag                             must FAIL (after)
//   notracker  every tracker tag removed                                          must FAIL (no tracker)
//   replay     data-replay="rrweb" added to the __l5e tag                         must FAIL (attribute)
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
const TEST = fileURLToPath(new URL('./analytics-token-guard.test.mjs', import.meta.url))
const GUARD = execFileSync(process.execPath, [TEST, '--print'], { encoding: 'utf8' }).replace(/\n$/, '')
const fixture = (process.argv.find((a) => a.startsWith('--fixture=')) || '').split('=')[1]
const PAGES = {
  hub: ['/', '/reset-password', '/reset-password/invite'], admin: ['/'], clients: ['/', '/reset-password'], stamp: ['/'],
  derm: ['/'], calendar: ['/'], hr: ['/employees'], planner: ['/', '/reset-password'], ops: ['/'],
}
const TRACKERS = { flock: /<script\b[^>]*\bsrc="\/~flock\.js"[^>]*>/i, l5e: /<script\b[^>]*\bsrc="[^"]*\/__l5e\/events(?:\.[0-9a-f]+)?\.js"[^>]*>/i }
const L5E_ATTRS = ['defer', 'src', 'data-artifact-kind', 'data-artifact-id', 'data-commit-sha', 'data-context-token', 'data-autocapture', 'data-consent']
const SERVED_GUARD = /<script\b[^>]*>(?:(?!<\/script>)[\s\S])*?__unclogmeAnalyticsGuard[\s\S]*?<\/script>/i
const TRACKER_ELEMENT = /<script\b[^>]*\bsrc="[^"]*(?:\/~flock\.js|\/__l5e\/events[^"]*)"[^>]*>\s*<\/script>/gi

function mutate(html, f) {
  if (f === 'flock') return html.replace(TRACKERS.l5e, '<script defer src="/~flock.js">')
  if (f === 'notracker') return html.replace(TRACKER_ELEMENT, '')
  if (f === 'replay') return html.replace(TRACKERS.l5e, (m) => m.replace(/>$/, ' data-replay="rrweb" data-replay-sample-rate="1">'))
  const g = f === 'cooked' ? eval('`' + GUARD + '`') : GUARD
  const bare = html.replace(SERVED_GUARD, '')
  const t = Object.values(TRACKERS).map((re) => re.exec(bare)).filter(Boolean).sort((a, b) => a.index - b.index)[0]
  if (!t) return bare
  const end = t.index + t[0].length
  return f === 'after' ? bare.slice(0, end) + '</script><script>' + g + bare.slice(end) : bare.slice(0, t.index) + '<script>' + g + '</script>' + bare.slice(t.index)
}

function judge(html) {
  const found = Object.entries(TRACKERS).map(([name, re]) => [name, re.exec(html)]).filter(([, m]) => m)
  const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)].map((m) => ({ at: m.index, attrs: m[1], body: m[2] }))
  const exact = scripts.filter((s) => !/\bsrc\s*=/i.test(s.attrs) && s.body === GUARD)
  const near = scripts.filter((s) => s.body.includes('__unclogmeAnalyticsGuard') && s.body !== GUARD)
  const why = []
  if (!found.length) why.push('no known tracker tag, neither ~flock.js nor /__l5e/events (re-check the tracker detector)')
  if (exact.length !== 1) why.push(`${exact.length} byte-identical guard scripts`)
  for (const n of near) { let i = 0; while (n.body[i] === GUARD[i]) i++; why.push(`DRIFTED copy, first difference at char ${i}: served ${JSON.stringify(n.body.slice(i - 10, i + 10))} vs canonical ${JSON.stringify(GUARD.slice(i - 10, i + 10))}`) }
  if (exact[0] && /\b(async|defer|type)\b/i.test(exact[0].attrs)) why.push(`guard tag carries attributes: ${exact[0].attrs.trim()}`)
  for (const [name, m] of found) if (exact[0] && exact[0].at > m.index) why.push(`guard comes AFTER the ${name} tag`)
  const l5e = found.find(([name]) => name === 'l5e')?.[1]?.[0] || ''
  const extra = [...l5e.slice(7, -1).matchAll(/([a-z][\w:-]*)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?/gi)].map((a) => a[1].toLowerCase()).filter((a) => !L5E_ATTRS.includes(a))
  if (extra.length) why.push(`__l5e tag carries ${extra.join(', ')}: a recorder or endpoint switch, re-measure with flock-race.mjs`)
  const tracker = found.map(([name, m]) => name === 'flock' ? 'flock' : `l5e ${/src="([^"]*)"/.exec(m[0])[1].split('/').pop()}${/data-autocapture="1"/.test(m[0]) ? ' autocapture' : ''}${/data-consent="1"/.test(m[0]) ? ' consent' : ''}`).join(' + ')
  return { why, tracker: tracker || 'NONE' }
}

let bad = 0, first = null
for (const [app, paths] of Object.entries(PAGES)) {
  for (const path of [...paths, '/__guard-probe-404']) {
    const r = await fetch(`https://${app}.unclogme.app${path}`, { redirect: 'follow' })
    let html = await r.text()
    first ??= html
    if (fixture) html = mutate(html, fixture)
    const { why, tracker } = judge(html)
    if (why.length) bad++
    console.log(`${(app + path).padEnd(30)} ${r.status} ${why.length ? 'FAIL  ' + why.join('; ') : 'PASS'}  tracker=${tracker}`)
  }
}
const EXPECT = { good: null, flock: null, cooked: /DRIFTED/, after: /AFTER/, notracker: /no known tracker/, replay: /data-replay/ }
console.log('\ncontrols on the first page:')
for (const [f, want] of Object.entries(EXPECT)) {
  const { why, tracker } = judge(mutate(first, f))
  const ok = want ? why.some((w) => want.test(w)) : why.length === 0
  if (!ok) bad++
  console.log(`  ${f.padEnd(10)} must ${want ? 'FAIL' : 'PASS'}: ${ok ? 'ok   ' : 'WRONG'} ${why.length ? why.join('; ') : 'PASS'}  tracker=${tracker}`)
}
console.log(`\ncanonical guard: ${GUARD.length} chars${fixture ? `, fixture=${fixture}` : ''}`)
process.exit(bad ? 1 : 0)
