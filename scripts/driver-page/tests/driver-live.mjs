// node driver-live.mjs <outdir> [property_id=162]
// Live check of the PUBLIC driver page (Picture Planner /driver#code=...), plan
// Building Apps/docs/2026-09-25_page-builder-and-driver-page-plan.md, build step 3.
// Reads the property's driver link from the DB (never prints it), then:
//   1. SSR HTML of /driver: no supabase chunk in its modulepreload list;
//   2. the static-import closure of the /driver route chunk: no supabase chunk, no createClient / GoTrue;
//   3. a real browser at 360 / 390 / 768 / 1280: the page shows the fixture's data, every photo decodes,
//      no request goes to /rest/v1 or /auth/v1, the page tracker never carries the code (code=redacted),
//      no sideways scroll, no tap target under 44px;
//   4. a malformed and an unknown code show "This link is not valid."
// Writes screenshots to <outdir>. Needs a [TEST] approved page on the property (see the migration notes).
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const [out = './driver-shots', propArg = '162'] = process.argv.slice(2)
fs.mkdirSync(out, { recursive: true })
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const [link] = await sql(`select public_id from public.property_page_links where property_id = ${Number(propArg)}`)
if (!link) throw new Error('no driver link for property ' + propArg)
const CODE = link.public_id
const HOST = 'https://planner.unclogme.app'
const results = []
const ok = (name, cond, extra = '') => results.push(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + String(extra).replaceAll(CODE, '<code>') : ''}`)

// 1 + 2. SSR HTML and the route chunk closure
const html = await (await fetch(HOST + '/driver')).text()
const preloads = [...html.matchAll(/<link[^>]+rel="modulepreload"[^>]+href="([^"]+)"/g)].map((m) => m[1])
ok('SSR /driver preloads no supabase chunk', preloads.length > 0 && !preloads.some((h) => /supabase/i.test(h)), preloads.join(' '))
const all = new Map()
const fetchChunk = async (name) => { if (!all.has(name)) all.set(name, await (await fetch(HOST + '/assets/' + name)).text()); return all.get(name) }
const entry = (html.match(/\/assets\/(index-[^"']+\.js)/) || [])[1]
const root = entry ? await fetchChunk(entry) : ''
const driverChunk = (root.match(/driver-[A-Za-z0-9_-]+\.js/) || [])[0]
ok('the root chunk names a /driver route chunk', !!driverChunk, driverChunk)
const seen = new Set()
const walk = async (name) => {
  if (seen.has(name)) return; seen.add(name)
  const src = await fetchChunk(name)
  for (const m of src.matchAll(/(?:from|import)\s*["']\.\/([A-Za-z0-9_.-]+\.js)["']/g)) await walk(m[1])
}
if (driverChunk) await walk(driverChunk)
const closure = [...seen]
ok('the /driver static-import closure has no supabase chunk', closure.length > 0 && !closure.some((n) => /supabase/i.test(n)), closure.join(' '))
ok('no createClient / GoTrue in the /driver closure', closure.every((n) => !/createClient\(|GoTrueClient/.test(all.get(n))))
ok('no HTML sink in the /driver closure', closure.every((n) => !/dangerouslySetInnerHTML|\.innerHTML\s*=|insertAdjacentHTML|InfoWindow/.test(all.get(n))))
// positive control for the closure walk: the root chunk must itself be reachable and non-empty
ok('control: the root chunk was fetched', root.length > 10000, root.length)

// 3. a real browser
const b = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true, args: ['--disable-blink-features=AutomationControlled'] })
for (const [name, w, h, dpr] of [['phone360', 360, 740, 2], ['phone390', 390, 844, 2], ['tablet768', 768, 1024, 1], ['desktop1280', 1280, 900, 1]]) {
  const ctx = await b.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: dpr, isMobile: w < 700, hasTouch: w < 700 })
  const p = await ctx.newPage()
  const reqs = []
  p.on('request', (r) => reqs.push({ url: r.url(), body: r.postData() || '' }))
  await p.goto(HOST + '/driver#code=' + CODE)
  await p.waitForFunction(() => /Checked by|not valid|Could not open/.test(document.body.innerText), null, { timeout: 20000 })
  await p.waitForTimeout(1500)
  const m = await p.evaluate(() => ({
    text: document.body.innerText,
    title: document.title,
    overflowX: document.documentElement.scrollWidth > innerWidth,
    imgs: [...document.images].filter((i) => i.getBoundingClientRect().width > 0).map((i) => ({ ok: i.complete && i.naturalWidth > 0, src: i.currentSrc.slice(0, 60) })),
    small: [...document.querySelectorAll('a,button')].filter((e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && r.height < 44 && !e.closest('#lovable-badge, [id*="lovable" i]') && !/^Edit with/.test((e.textContent || '').trim()) }).map((e) => (e.textContent || '').trim().slice(0, 24) + ':' + Math.round(e.getBoundingClientRect().height)).slice(0, 8),
    hash: location.hash.length,
  }))
  await p.screenshot({ path: `${out}/${name}_top.png` })
  await p.screenshot({ path: `${out}/${name}_full.png`, fullPage: true })
  if (name === 'phone390') {
    ok('shows the client and the checked chip', /112-YA/.test(m.text) && /Checked by/.test(m.text), m.text.slice(0, 120).replace(/\n/g, ' | '))
    ok('shows the gate code and lock box code', /\[TEST\] 4321/.test(m.text) && /\[TEST\] 1234/.test(m.text))
    ok('hours: overnight and any time and no access', /overnight/i.test(m.text) && /Any time/i.test(m.text) && /No access/i.test(m.text))
    ok('tab title names no client', m.title === 'Driver page · Picture Planner · UnclogMe', m.title)
    ok('fragment still present after load', m.hash > 10)
  }
  ok(`${name}: every visible photo decodes`, m.imgs.length > 0 && m.imgs.every((i) => i.ok), JSON.stringify(m.imgs))
  ok(`${name}: no sideways scroll`, !m.overflowX)
  ok(`${name}: no tap target under 44px`, m.small.length === 0, m.small.join(', '))
  ok(`${name}: no request to /rest/v1 or /auth/v1`, !reqs.some((r) => /\/rest\/v1|\/auth\/v1/.test(r.url)))
  await p.waitForTimeout(1500)
  const tracker = reqs.filter((r) => /\/~api\/analytics/.test(r.url))
  ok(`${name}: control: the page tracker did report the page view`, tracker.length > 0, `${tracker.length} tracker requests`)
  ok(`${name}: the tracker body carries code=redacted`, tracker.some((r) => r.body.includes('code=redacted')))
  ok(`${name}: the page tracker never carries the code`, reqs.every((r) => !r.url.includes(CODE) || /functions\/v1\/driver-page/.test(r.url)) && tracker.every((r) => !r.body.includes(CODE)), `${tracker.length} tracker requests`)
  await ctx.close()
}
// 4. bad and unknown codes
for (const [label, frag] of [['malformed', '#code=short'], ['unknown', '#code=AAAAAAAAAAAAAAAAAAAAAA'], ['no code', '']]) {
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 } })
  const p = await ctx.newPage()
  await p.goto(HOST + '/driver' + frag)
  await p.waitForFunction(() => /not valid|Could not open|Checked by/.test(document.body.innerText), null, { timeout: 20000 }).catch(() => {})
  ok(`${label} code shows "This link is not valid."`, /This link is not valid/.test(await p.evaluate(() => document.body.innerText)))
  await ctx.close()
}
await b.close()
console.log(results.join('\n'))
console.log(results.some((r) => r.startsWith('FAIL')) ? 'SOME FAILED' : 'ALL PASS')
