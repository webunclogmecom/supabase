// LIVE Page Builder + forms screens, property 1164, real data read in SQL as Fred's claims, edited per scenario.
// Sign-in faked, every RPC stubbed, nothing written. Checks batch M2 (2026-09-27):
//   the "Changed in the Client App's property data" notice (renamed twice on 2026-09-28; the Activity card checks moved to activity_modal.mjs)
//   (list, Submit blocked, Use the new values), the driver link copy, /forms cards (photo plural, city) and the
//   /forms/$id link to the Page Builder.
//   node scripts/page-builder/tests/activity_notice.mjs <outdir>
//   CHUNK_SUB='<from>|||<to>@@@<from2>|||<to2>' serves the live chunks with those edits (a control: named checks must FAIL)
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const r = await sql(`do $$ begin perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where lower(email)='fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true); end $$;
select client.get_page_builder(1164) as pb, client.get_page_builder_forms(1164) as forms, client.get_intake(686) as intake, (select jsonb_agg(to_jsonb(l)) from client.page_builder_list() l) as list,
       (select jsonb_agg(to_jsonb(s)) from client.v_intake_submissions s where s.property_id = 1164) as subs;`)
const row = r[r.length - 1]
const ACT = Array.from({ length: 10 }, (_, i) => ({ at: new Date(Date.UTC(2026, 8, 27, 10, 40 - i)).toISOString(), kind: i === 3 ? 'form_filled' : 'page_submitted', who: 'Someone ' + i, intake_id: i === 3 ? 686 : null, version: i === 3 ? null : 10 - i, text: i === 3 ? 'Site survey form #686 filled in by [TEST] Carlos' : `Version ${10 - i} of the driver page submitted for approval by Someone ${i}` }))
const N = JSON.parse(JSON.stringify({ pb: row.pb, forms: row.forms }))
N.pb.live.source = { ...(N.pb.property.source || {}), lock_box_key: 'OLD-LB-1' }
N.pb.property.source = { ...(N.pb.property.source || {}), lock_box_key: 'NEW-LB-2' }
N.pb.live.content.facts = { ...N.pb.live.content.facts, lock_box_code: 'OLD-LB-1' }
N.pb.pending = null
const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 400)}`) }
const out = process.argv[2] || './act_shots'; fs.mkdirSync(out, { recursive: true })
const calls = [], subHits = []
async function open(w, path, replies, fail500 = []) {
  const ctx = await browser.newContext({ viewport: { width: w, height: 900 } })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => { try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {} }, user)
  const p = await ctx.newPage()
  const state = { fail500: new Set(fail500) }
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/rest/v1/**', (x) => {
    const n = new URL(x.request().url()).pathname.split('/').pop(); calls.push(n)
    if (state.fail500.has(n)) return x.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"boom"}' })
    if (replies[n] !== undefined) return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(replies[n]) })
    return x.fulfill({ status: 404, body: '{}' })
  })
  await p.route(SB + '/storage/v1/**', (x) => x.fulfill({ status: 400, contentType: 'application/json', body: '{}' }))
  await p.route('https://maps.googleapis.com/**', (x) => x.abort())
  // CHUNK_SUB='<from>|||<to>@@@<from2>|||<to2>' serves the live chunks with those edits (a control: named checks must FAIL)
  if (process.env.CHUNK_SUB) { const pairs = process.env.CHUNK_SUB.split('@@@').map((x) => x.split('|||')); await p.route(H + '/assets/*.js', async (x) => { const f = await x.fetch(); let t = await f.text(); for (const [from, to] of pairs) if (t.includes(from)) { subHits.push(from.slice(0, 30)); t = t.split(from).join(to) } return x.fulfill({ response: f, body: t }) }) }
  await p.goto(H + path)
  await p.waitForTimeout(4500)
  return { ctx, p, state }
}
const builderReplies = (data, act) => ({ get_page_builder: data.pb, get_page_builder_forms: data.forms, get_property_activity: act })

{ // the driver link copy (the Activity card checks moved to activity_modal.mjs with the card, 2026-09-28)
  const { ctx, p } = await open(1440, '/property/1164', builderReplies({ pb: row.pb, forms: row.forms }, ACT))
  const copy = await p.evaluate(() => document.body.textContent)
  ok(/Paste it into the job's Instructions in Jobber for the drivers\. You can also send it to the client: they see the same site file, codes included\. Never put it in the job title or in a visit\./.test(copy), 'site file link card: the new copy')
  await ctx.close()
}
{ // Changed in the Client App's property data notice (was "Changed on the property record" until the 2026-09-28 rewording)
  const { ctx, p } = await open(1440, '/property/1164', builderReplies(N, []))
  const t = await p.evaluate(() => document.body.textContent)
  ok(/Changed in the Client App's property data since this version was made:/.test(t) && !/Changed on the property record since this/.test(t), 'notice: shown when the live version\'s source differs, new wording, old wording gone')
  ok(/Lock box code(: | \()OLD-LB-1 to NEW-LB-2/.test(t), 'notice: names the lock box code with old and new values', (t.match(/Lock box code.{0,40}/) || [])[0])
  const sub = p.locator('button', { hasText: /^Submit for approval$/ })
  ok(await sub.isDisabled().catch(() => false), 'notice: Submit for approval is disabled until answered')
  ok(/Check what changed in the Client App's property data first\./.test(t) && !/Check what changed on the property record first/.test(t), 'notice: the footer says why, new wording, old wording gone')
  await p.screenshot({ path: `${out}/notice_1440.png` })
  await p.locator('button', { hasText: /^Use the new values$/ }).click().catch(() => {}); await p.waitForTimeout(700)
  const vals = await p.evaluate(() => [...document.querySelectorAll('input')].map((i) => i.value))
  ok(vals.includes('NEW-LB-2') && !vals.includes('OLD-LB-1'), 'notice: Use the new values puts NEW-LB-2 in the draft', vals.filter((v) => /LB/.test(v)))
  const t2 = await p.evaluate(() => document.body.textContent)
  ok(!/Changed in the Client App's property data since this version was made:/.test(t2) && !/Changed on the property record since this/.test(t2) && /Took the new values from the Client App's property data\./.test(t2) && !/Took the new values from the property record/.test(t2), 'notice: hidden, with the Undo notice, new wording, old wording gone')
  ok(await sub.isEnabled().catch(() => false), 'notice: Submit for approval is enabled again')
  await ctx.close()
}
{ // /forms cards
  const subs = (row.subs || []).map((s) => ({ ...s, photo_count: s.intake_id === 686 ? 1 : s.photo_count, address: '650 Northwest 33rd Street, Miami', city: 'Miami' }))
  const { ctx, p } = await open(1280, '/forms', { v_intake_submissions: subs })
  const t = await p.evaluate(() => document.body.textContent)
  ok(/answered · 1 photo(?!s)/.test(t), '/forms: "1 photo" singular', (t.match(/answered · \d+ photos?/g) || []).slice(0, 3))
  ok(!/650 Northwest 33rd Street, Miami, Miami/.test(t), '/forms: the city is not repeated')
  await ctx.close()
}
{ // /forms/$id link
  const { ctx, p } = await open(1280, '/forms/686', { get_intake: row.intake })
  const l = await p.evaluate(() => [...document.querySelectorAll('a')].map((a) => [a.textContent.trim(), a.getAttribute('href')]).find(([t]) => /Open the Page Builder for this property/.test(t)) || null)
  ok(l && /\/property\/1164$/.test(l[1]), '/forms/686: link to /property/1164', l)
  await ctx.close()
}
{ // home page: no long dash; phone map buttons are 44px
  const { ctx, p } = await open(1280, '/', { page_builder_list: row.list })
  const t = await p.evaluate(() => document.body.textContent + ' ' + [...document.querySelectorAll('[placeholder],[aria-label],[title],meta[name=description]')].map((e) => [e.getAttribute('placeholder'), e.getAttribute('aria-label'), e.getAttribute('title'), e.getAttribute('content')].filter(Boolean).join(' ')).join(' ') + ' ' + document.title)
  ok(!/\u2014/.test(t), 'home: no long dash', (t.match(/.{20}\u2014.{20}/g) || []).slice(0, 2))
  await ctx.close()
  const q = await open(390, '/property/1164', builderReplies({ pb: row.pb, forms: row.forms }, []))
  const hs = await q.p.evaluate(() => [...document.querySelectorAll('button')].filter((b) => /^(Place|Move) (GT Location|Truck Parking)|^Draw arrow$/.test(b.textContent.trim())).map((b) => Math.round(b.getBoundingClientRect().height)))
  ok(hs.length >= 3 && hs.every((h) => h >= 44), 'phone 390: map buttons are at least 44px tall', hs)
  await q.ctx.close()
  const d = await open(1280, '/property/1164', builderReplies({ pb: row.pb, forms: row.forms }, []))
  const hd = await d.p.evaluate(() => [...document.querySelectorAll('button')].filter((b) => /^(Place|Move) (GT Location|Truck Parking)|^Draw arrow$/.test(b.textContent.trim())).map((b) => Math.round(b.getBoundingClientRect().height)))
  ok(hd.length >= 3 && hd.every((h) => h <= 34), 'laptop 1280: map buttons keep their size', hd)
  await d.ctx.close()
}
await browser.close()
if (process.env.CHUNK_SUB) console.log('CHUNK_SUB edits applied:', [...new Set(subHits)].length, 'of', process.env.CHUNK_SUB.split('@@@').length)
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
