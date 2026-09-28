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
const flat = css.join('\n').replace(/\\/g, '')
const missing = classes.filter((c) => !flat.includes('.' + c))
console.log(JSON.stringify({ js: [...seen].filter((u) => u.endsWith('.js')).length, css: css.length, hits, missing }, null, 1))
if (needles.some((n) => !hits[n].length) || missing.length) process.exitCode = 1
