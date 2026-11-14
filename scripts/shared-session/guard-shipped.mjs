// guard-shipped.mjs: is the analytics token guard LIVE, byte-identical, and ahead of any Lovable tracker on every
// page an auth redirect can land on, and WHICH tracker is there, if any?   node guard-shipped.mjs
//
// Reads the RAW served HTML (fetch, following the 307s that clients and hr issue; a fragment survives
// those). Never the browser DOM: on the TanStack apps React removes a head() inline script from the DOM
// right after hydration, so a DOM check reports "missing" for a guard that ran.
// Trackers. /~flock.js (until 2026-11-12..14) posted location.href, fragment included, to /~api/analytics:
// that is what the guard scrubs. /__l5e/events[.<hash>].js replaced it and redacts on its own (measured
// 2026-11-14 with fake tokens, mockups/2026-11-14-l5e/measure.mjs). Since 2026-11-14 about 05:20 ET
// "Visitor analytics" is OFF in the Project settings of all nine apps (Fred), so the expected state is NO
// tracker tag. The guard stays, for any project where Lovable turns a tracker back on.
// PASS for a page = exactly one inline <script> whose text === the canonical one-liner (printed by
// analytics-token-guard.test.mjs --print), with no src/async/defer/type, AND every external script is the
// app's own /assets/ bundle or a known tracker (anything else may be a renamed tracker), AND, when a tracker
// tag is there, the guard comes before it and an __l5e tag carries no attribute beyond the eight seen on
// 2026-11-14 (data-replay switches on its rrweb recorder, whose Meta event records location.href; a
// data-*-url moves its endpoint). A page with no tracker reports "tracker=NONE (Visitor analytics off)".
// CONTROLS, every run, on SAMPLE (a page as served with the tracker on), so they prove the detector whatever
// the live state is. Each must give its verdict for the right reason, or the run FAILS:
//   good       the guard moved to just before the tracker tag                    must PASS
//   flock      the __l5e tag swapped for a ~flock.js tag (a project still on it)  must PASS
//   notracker  every tracker tag removed (Visitor analytics off)                 must PASS
//   cooked     the guard pasted into a JS template literal                       must FAIL (drifted)
//   after      the guard placed after the tracker tag                            must FAIL (after)
//   replay     data-replay="rrweb" added to the __l5e tag                        must FAIL (attribute)
//   unknown    the tracker tag renamed to a script this check does not know      must FAIL (unknown script)
//   bare       no tracker AND no guard                                           must FAIL (no guard)
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
const TEST = fileURLToPath(new URL('./analytics-token-guard.test.mjs', import.meta.url))
const GUARD = execFileSync(process.execPath, [TEST, '--print'], { encoding: 'utf8' }).replace(/\n$/, '')
const PAGES = {
  hub: ['/', '/reset-password', '/reset-password/invite'], admin: ['/'], clients: ['/', '/reset-password'], stamp: ['/'],
  derm: ['/'], calendar: ['/'], hr: ['/employees'], planner: ['/', '/reset-password'], ops: ['/'],
}
const TRACKERS = { flock: /<script\b[^>]*\bsrc="\/~flock\.js"[^>]*>/i, l5e: /<script\b[^>]*\bsrc="[^"]*\/__l5e\/events(?:\.[0-9a-f]+)?\.js"[^>]*>/i }
const L5E_ATTRS = ['defer', 'src', 'data-artifact-kind', 'data-artifact-id', 'data-commit-sha', 'data-context-token', 'data-autocapture', 'data-consent']
const SERVED_GUARD = /<script\b[^>]*>(?:(?!<\/script>)[\s\S])*?__unclogmeAnalyticsGuard[\s\S]*?<\/script>/i
const TRACKER_ELEMENT = /<script\b[^>]*\bsrc="[^"]*(?:\/~flock\.js|\/__l5e\/events[^"]*)"[^>]*>\s*<\/script>/gi
// hub.unclogme.app/ as served on 2026-11-14 before Visitor analytics went off, cut to the tags the rules read.
// The __l5e tag is the served one with its values blanked (data-context-token is Lovable's signed deploy token).
const SAMPLE = '<!DOCTYPE html><html lang="en"><head><meta charSet="utf-8"/><script>' + GUARD + '</script><title>sample</title>'
  + '<script defer src="/__l5e/events.270c78a44fc53e7b.js" data-artifact-kind="dwl_content_hash" data-artifact-id="x" data-commit-sha="x" data-context-token="x" data-autocapture="1" data-consent="1"></script>'
  + '</head><body><div id="root"></div><script type="module" async="" src="/assets/index-sample.js"></script></body></html>'

function mutate(html, f) {
  if (f === 'flock') return html.replace(TRACKERS.l5e, '<script defer src="/~flock.js">')
  if (f === 'notracker') return html.replace(TRACKER_ELEMENT, '')
  if (f === 'bare') return html.replace(TRACKER_ELEMENT, '').replace(SERVED_GUARD, '')
  if (f === 'replay') return html.replace(TRACKERS.l5e, (m) => m.replace(/>$/, ' data-replay="rrweb" data-replay-sample-rate="1">'))
  if (f === 'unknown') return html.replace(TRACKERS.l5e, (m) => m.replace(/\/__l5e\/events[^"]*/, '/__lv/analytics.js'))
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
  if (exact.length !== 1) why.push(`${exact.length} byte-identical guard scripts`)
  for (const n of near) { let i = 0; while (n.body[i] === GUARD[i]) i++; why.push(`DRIFTED copy, first difference at char ${i}: served ${JSON.stringify(n.body.slice(i - 10, i + 10))} vs canonical ${JSON.stringify(GUARD.slice(i - 10, i + 10))}`) }
  if (exact[0] && /\b(async|defer|type)\b/i.test(exact[0].attrs)) why.push(`guard tag carries attributes: ${exact[0].attrs.trim()}`)
  for (const [name, m] of found) if (exact[0] && exact[0].at > m.index) why.push(`guard comes AFTER the ${name} tag`)
  const unknown = scripts.map((s) => /\bsrc\s*=\s*"([^"]*)"/i.exec(s.attrs)?.[1]).filter((src) => src && !src.startsWith('/assets/') && !Object.values(TRACKERS).some((re) => re.test(`<script src="${src}">`)))
  if (unknown.length) why.push(`unknown script ${unknown.join(', ')}: a renamed tracker? re-measure with flock-race.mjs and teach this check`)
  const l5e = found.find(([name]) => name === 'l5e')?.[1]?.[0] || ''
  const extra = [...l5e.slice(7, -1).matchAll(/([a-z][\w:-]*)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?/gi)].map((a) => a[1].toLowerCase()).filter((a) => !L5E_ATTRS.includes(a))
  if (extra.length) why.push(`__l5e tag carries ${extra.join(', ')}: a recorder or endpoint switch, re-measure with flock-race.mjs`)
  const tracker = found.map(([name, m]) => name === 'flock' ? 'flock' : `l5e ${/src="([^"]*)"/.exec(m[0])[1].split('/').pop()}${/data-autocapture="1"/.test(m[0]) ? ' autocapture' : ''}${/data-consent="1"/.test(m[0]) ? ' consent' : ''}`).join(' + ')
  return { why, tracker: tracker || 'NONE (Visitor analytics off)' }
}

let bad = 0
for (const [app, paths] of Object.entries(PAGES)) {
  for (const path of [...paths, '/__guard-probe-404']) {
    const r = await fetch(`https://${app}.unclogme.app${path}`, { redirect: 'follow' })
    const { why, tracker } = judge(await r.text())
    if (why.length) bad++
    console.log(`${(app + path).padEnd(30)} ${r.status} ${why.length ? 'FAIL  ' + why.join('; ') : 'PASS'}  tracker=${tracker}`)
  }
}
const EXPECT = { good: null, flock: null, notracker: null, cooked: /DRIFTED/, after: /AFTER/, replay: /data-replay/, unknown: /unknown script/, bare: /^0 byte-identical/ }
console.log('\ncontrols on the stored sample (tracker on):')
for (const [f, want] of Object.entries(EXPECT)) {
  const { why, tracker } = judge(mutate(SAMPLE, f))
  const ok = want ? why.some((w) => want.test(w)) : why.length === 0
  if (!ok) bad++
  console.log(`  ${f.padEnd(10)} must ${want ? 'FAIL' : 'PASS'}: ${ok ? 'ok   ' : 'WRONG'} ${why.length ? why.join('; ') : 'PASS'}  tracker=${tracker}`)
}
console.log(`\ncanonical guard: ${GUARD.length} chars`)
process.exit(bad ? 1 : 0)
