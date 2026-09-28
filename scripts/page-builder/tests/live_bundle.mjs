// Walk the LIVE Picture Planner bundle to closure (seeded from real routes) and report which chunks hold each needle;
// with --c, report which Tailwind classes have NO rule in the served stylesheet (a class glued to ${...} is never
// generated, PP rule 15). Read-only. Exit 1 when a needle is missing or a class has no rule.
//   node scripts/page-builder/tests/live_bundle.mjs --n accept_intake_answers --n "Add to the property record" --c "aria-selected:bg-[#fff4ef]"
const H = 'https://planner.unclogme.app'
const args = process.argv.slice(2), needles = [], classes = []
for (let i = 0; i < args.length; i += 2) (args[i] === '--c' ? classes : needles).push(args[i + 1])
const seen = new Set(), queue = [], css = []
for (const route of ['/', '/forms', '/forms/715', '/property/1164']) {
  const html = await (await fetch(H + route)).text()
  for (const m of html.matchAll(/\/assets\/[A-Za-z0-9._$-]+\.(?:js|css)/g)) queue.push(m[0])
}
const hits = Object.fromEntries(needles.map((n) => [n, []]))
while (queue.length) {
  const u = queue.shift(); if (seen.has(u)) continue; seen.add(u)
  const t = await (await fetch(H + u)).text()
  if (u.endsWith('.css')) { css.push(t); continue }
  for (const n of needles) if (t.includes(n)) hits[n].push(u.slice(8))
  for (const m of t.matchAll(/(?:\.\/|\/assets\/)([A-Za-z0-9._$-]+\.(?:js|css))/g)) queue.push('/assets/' + m[1])
}
// A class has a rule only when '.' + its CSS-escaped name is followed by a character that ends the name: a plain
// substring took `.top-3.5` for `top-3` and `.border-[#f14714]/30` for `border-[#f14714]`. The served CSS escapes every
// character outside [A-Za-z0-9_-] with one backslash (measured 2026-09-28: no hex escapes), so match on the raw text.
const raw = css.join('\n')
const hasRule = (text, c) => { const s = '.' + c.replace(/[^A-Za-z0-9_-]/g, (x) => '\\' + x); for (let i = text.indexOf(s); i >= 0; i = text.indexOf(s, i + 1)) if (!/[A-Za-z0-9_\\-]/.test(text[i + s.length] || '')) return true; return false }
// the matcher's own control: an exact rule and a variant followed by its attribute selector must count; two longer
// classes must not; and the live stylesheet must have `.flex` (so an empty or unfetched stylesheet cannot pass)
const FIX = '.flex{}.aria-selected\\:bg-\\[\\#fff4ef\\][aria-selected=true]{}.top-3\\.5{}.border-\\[\\#f14714\\]\\/30{}'
if (!hasRule(FIX, 'flex') || !hasRule(FIX, 'aria-selected:bg-[#fff4ef]') || hasRule(FIX, 'top-3') || hasRule(FIX, 'border-[#f14714]') || !hasRule(raw, 'flex')) throw new Error('class matcher control failed')
const missing = classes.filter((c) => !hasRule(raw, c))
console.log(JSON.stringify({ js: [...seen].filter((u) => u.endsWith('.js')).length, css: css.length, hits, missing }, null, 1))
if (needles.some((n) => !hits[n].length) || missing.length) process.exitCode = 1
