// LIVE Picture Planner, Trello AIwCYcmn (2026-10-27): a Forms-only person ("See submitted forms" Yes, Picture Planner at
// No access) and the Share control on a submitted form. Real replies of client.list_intake_forms / client.get_intake are
// read in SQL as a TEMPORARY Field person (rolled back, nothing kept) and as Fred, then played back to the live bundle.
// Sign-in faked; every call stubbed; nothing written. Never prints a reply (a form can hold a lock box code).
// Spec: Building Apps/Picture Planner/docs/specs/2026-10-27-share-forms-and-forms-only.md
//   node scripts/page-builder/tests/forms_only.mjs <outdir>
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const ENV = [new URL('../../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()

// the fixture: one rolled-back block, results carried out in the error message
const r = await sql(`do $$
declare v_uid uuid := gen_random_uuid(); v_tag text := substr(md5(random()::text), 1, 8); c_tmp text; c_fred text; v_sub bigint; v_wait bigint; v_can bigint; o jsonb;
begin
  select max(i.id) filter (where i.submitted_at is not null and i.cancelled_at is null),
         max(i.id) filter (where i.submitted_at is null and i.cancelled_at is null and i.expires_at > now()),
         max(i.id) filter (where i.cancelled_at is not null)
    into v_sub, v_wait, v_can
    from public.property_intakes i join public.properties p on p.id = i.property_id join public.clients c on c.id = p.client_id
   where c.client_code = '112-YA';
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', 'fo-' || v_tag || '@unclogme.com', '', now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, false);
  insert into public.employees (id, full_name, status, email, access_level, notes) overriding system value
  values (990003, 'ZZ FO ' || v_tag, 'ACTIVE', 'fo-' || v_tag || '@unclogme.com', 'field', 'Temporary row of a rolled-back test');
  c_tmp := json_build_object('sub', v_uid, 'email', 'fo-' || v_tag || '@unclogme.com', 'role', 'authenticated')::text;
  c_fred := json_build_object('sub', (select id from auth.users where lower(email) = 'fred@ayache.com'), 'email', 'fred@ayache.com', 'role', 'authenticated')::text;
  perform set_config('request.jwt.claims', c_tmp, true);
  o := jsonb_build_object('sub', v_sub, 'wait', v_wait, 'can', v_can,
         'fo_access', hr.get_my_access(), 'fo_list', client.list_intake_forms(),
         'fo_sub', client.get_intake(v_sub), 'fo_wait', client.get_intake(v_wait));
  begin perform client.get_intake(v_can); exception when others then o := o || jsonb_build_object('fo_can_msg', sqlerrm, 'fo_can_state', sqlstate); end;
  perform set_config('request.jwt.claims', c_fred, true);
  o := o || jsonb_build_object('st_access', hr.get_my_access(), 'st_list', client.list_intake_forms(), 'st_sub', client.get_intake(v_sub));
  raise exception 'FIXTURE%', o::text;
end $$;`)
const m = String((r && r.message) || '').match(/FIXTURE(\{.*\})/s)
if (!m) { console.log('FAIL fixture did not report :: ' + String((r && r.message) || '').slice(0, 300)); process.exit(1) }
const F = JSON.parse(m[1])
const SUB = Number(F.sub), WAIT = Number(F.wait), CAN = Number(F.can)

const H = 'https://planner.unclogme.app', SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const exp = Math.floor(Date.now() / 1000) + 3600
const user = { id: '00000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'visual.check@ayache.com', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }
const session = { access_token: `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp })}.fakesignature`, refresh_token: 'fake-refresh', token_type: 'bearer', expires_in: 3600, expires_at: exp }
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64')
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const out = process.argv[2] || './forms_only_shots'; fs.mkdirSync(out, { recursive: true })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 300)}`) }

async function open(w, who, path) {
  const phone = w < 768
  const ctx = await browser.newContext({ viewport: { width: w, height: phone ? 844 : 900 }, deviceScaleFactor: phone ? 2 : 1, isMobile: phone, hasTouch: phone })
  await ctx.addCookies([{ name: 'sb-wbasvhvvismukaqdnouk-auth-token', value: encodeURIComponent(JSON.stringify(session)), domain: '.unclogme.app', path: '/', secure: true, sameSite: 'Lax' }])
  await ctx.addInitScript((u) => {
    try { localStorage.setItem('sb-wbasvhvvismukaqdnouk-auth-token-user', JSON.stringify({ user: u })) } catch {}
    window.__clip = []; window.__shares = []
    Object.defineProperty(Navigator.prototype, 'clipboard', { configurable: true, get: () => ({ writeText: (t) => { window.__clip.push(String(t)); return Promise.resolve() } }) })
    Navigator.prototype.share = function (d) { window.__shares.push(d); return Promise.resolve() }
  }, user)
  const p = await ctx.newPage()
  const st = { calls: [], errors: [] }
  p.on('pageerror', (e) => st.errors.push(String(e)))
  await p.route(SB + '/auth/v1/**', (x) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(user) }))
  await p.route(SB + '/storage/v1/**', (x) => {
    const u = new URL(x.request().url())
    if (x.request().method() === 'POST') return x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ signedURL: '/object/sign/intake-photos/x.png?token=t' }) })
    return x.fulfill({ status: 200, contentType: 'image/png', body: PNG })
  })
  await p.route(SB + '/rest/v1/**', async (x) => {
    const n = new URL(x.request().url()).pathname.split('/').pop(); st.calls.push(n)
    let b = {}; try { b = JSON.parse(x.request().postData() || '{}') } catch {}
    const j = (s, body) => x.fulfill({ status: s, contentType: 'application/json', body: JSON.stringify(body) })
    const fo = who === 'fo'
    if (n === 'get_my_access') return j(200, fo ? F.fo_access : F.st_access)
    if (n === 'list_intake_forms') return j(200, fo ? F.fo_list : F.st_list)
    if (n === 'get_intake') {
      const id = Number(b.p_intake_id)
      if (fo && id === CAN) return j(400, { code: F.fo_can_state, message: F.fo_can_msg, details: 'blocker=not_available in client.get_intake', hint: null })
      if (fo && id === WAIT) return j(200, F.fo_wait)
      return j(200, fo ? F.fo_sub : F.st_sub)
    }
    return j(403, { code: '42501', message: 'You do not have access to any UnclogMe app. Ask Fred or Yannick to change it.', details: 'blocker=no_access app=any in public.fn_request_gate', hint: null })
  })
  await p.goto(H + path, { waitUntil: 'domcontentloaded' })
  await p.waitForTimeout(3500)
  return { p, ctx, st }
}
const navText = (p) => p.evaluate(() => [...document.querySelectorAll('nav[aria-label="Main"] a, nav[aria-label="Main"] button')].map((e) => e.textContent.trim()))

for (const w of [1440, 375]) {
  const tag = w + 'px'
  // 2026-10-28: a phone (touch + share sheet) shows Share; a computer (it copies) shows the chain Link icon and Copy link
  const phone = w < 768, CARD = phone ? 'Share link to this form' : 'Copy link to this form', HDR = phone ? 'Share' : 'Copy link'
  const ICON = phone ? 'M12 2v13' : 'M10 13a5 5 0 0 0 7.54.54'
  // Forms-only: the list
  let { p, ctx, st } = await open(w, 'fo', '/forms')
  ok(JSON.stringify(await navText(p)) === JSON.stringify(['Forms', 'Sign out']), `${tag} FO nav is Forms + Sign out`, await navText(p))
  const L = await p.evaluate(([CARD, ICON]) => ({
    share: document.querySelectorAll(`button[aria-label="${CARD}"]`).length,
    icon: [...document.querySelectorAll(`button[aria-label="${CARD}"] svg path`)].some((e) => (e.getAttribute('d') || '').startsWith(ICON)),
    menus: document.querySelectorAll('button[aria-label^="More actions for"]').length,
    requested: (document.body.textContent.match(/Requested by/g) || []).length,
    expires: (document.body.textContent.match(/Link expires/g) || []).length,
    sideways: document.documentElement.scrollWidth > window.innerWidth + 1,
  }), [CARD, ICON])
  const nSub = F.fo_list.filter((x) => x.state === 'submitted').length, nWait = F.fo_list.filter((x) => x.state === 'awaiting').length
  ok(L.share === nSub && nSub > 0, `${tag} FO one "${CARD}" button per submitted card (${nSub})`, L)
  ok(L.icon, `${tag} FO card button shows the ${phone ? 'Share' : 'Link'} icon`, L)
  ok(L.menus === 0, `${tag} FO no three-dot menu`, L)
  ok(L.requested === 0 && L.expires === nWait && nWait > 0, `${tag} FO waiting cards show expiry only (${nWait})`, L)
  ok(!L.sideways, `${tag} FO no sideways scroll`)
  await p.screenshot({ path: `${out}/fo_list_${w}.png`, fullPage: false })
  await p.click(`button[aria-label="${CARD}"]`)
  await p.waitForTimeout(800)
  const S = await p.evaluate(() => ({ clip: window.__clip, shares: window.__shares, toast: document.body.textContent.includes('Link copied') }))
  if (w < 768) ok(S.shares.length === 1 && /\/forms\/\d+$/.test(S.shares[0].url) && /^Intake form · /.test(S.shares[0].title) && S.clip.length === 0, `${tag} FO Share opens the phone share sheet`, S)
  else ok(S.clip.length === 1 && /^https:\/\/planner\.unclogme\.app\/forms\/\d+$/.test(S.clip[0]) && S.toast && S.shares.length === 0, `${tag} FO Share copies the link and says Link copied`, S)
  await p.screenshot({ path: `${out}/fo_list_shared_${w}.png`, fullPage: false })
  ok(st.calls.every((c) => ['get_my_access', 'list_intake_forms'].includes(c)), `${tag} FO list calls only get_my_access and list_intake_forms`, st.calls)
  ok(st.errors.length === 0, `${tag} FO list no page error`, st.errors)
  await ctx.close()

  // Forms-only: a submitted form, and ?tab=record
  ;({ p, ctx, st } = await open(w, 'fo', `/forms/${SUB}?tab=record`))
  const D = await p.evaluate((HDR) => ({
    pb: document.body.textContent.includes('Open the Page Builder'), tabs: document.querySelectorAll('[role="tablist"]').length,
    record: document.body.textContent.includes('Lock box code') && !!document.querySelector('[data-accept-row]'),
    share: [...document.querySelectorAll('main button')].some((b) => b.textContent.trim() === HDR),
    collector: !!document.querySelector('[data-collector-link]'), sideways: document.documentElement.scrollWidth > window.innerWidth + 1,
  }), HDR)
  ok(!D.pb && D.tabs === 0 && !D.record && !D.collector, `${tag} FO form: no Page Builder link, no tabs, no record tab, no collector link`, D)
  ok(D.share && !D.sideways, `${tag} FO form: "${HDR}" button, no sideways scroll`, D)
  await p.screenshot({ path: `${out}/fo_form_${w}.png`, fullPage: false })
  await p.locator(`main button:text-is("${HDR}")`).locator('visible=true').first().click()
  await p.waitForTimeout(600)
  const S2 = await p.evaluate(() => ({ clip: window.__clip, shares: window.__shares, copied: document.body.textContent.includes('Link copied') }))
  if (w < 768) ok(S2.shares.length === 1 && S2.shares[0].url.endsWith('/forms/' + SUB_ID()), `${tag} FO form Share opens the share sheet`, S2)
  else ok(S2.clip[0] === H + '/forms/' + SUB_ID() && S2.copied, `${tag} FO form Share copies and turns to Link copied`, S2)
  if (w >= 768) await p.screenshot({ path: `${out}/fo_form_copied_${w}.png`, fullPage: false })
  ok(st.calls.every((c) => ['get_my_access', 'get_intake'].includes(c)), `${tag} FO form calls only get_my_access and get_intake`, st.calls)
  await ctx.close()

  // Forms-only: a waiting form and a cancelled one
  ;({ p, ctx, st } = await open(w, 'fo', `/forms/${WAIT}`))
  const Wt = await p.evaluate(() => ({ t: document.body.textContent.includes('This form is not sent in yet'), e: document.body.textContent.includes('Link expires'), share: [...document.querySelectorAll('main button')].some((b) => /^(Share|Copy link)$/.test(b.textContent.trim())) }))
  ok(Wt.t && Wt.e && !Wt.share, `${tag} FO waiting form: not sent in yet + expiry, no Share`, Wt)
  await p.screenshot({ path: `${out}/fo_waiting_${w}.png`, fullPage: false })
  await ctx.close()
  ;({ p, ctx, st } = await open(w, 'fo', `/forms/${CAN}`))
  ok(await p.evaluate(() => document.body.textContent.includes('This form is no longer available.')), `${tag} FO cancelled form: no longer available`)
  await ctx.close()

  // Forms-only: the Page Builder routes go to /forms
  for (const path of ['/', '/property/162']) {
    ;({ p, ctx, st } = await open(w, 'fo', path))
    ok(new URL(p.url()).pathname === '/forms', `${tag} FO ${path} goes to /forms`, p.url())
    await ctx.close()
  }

  // Staff (Fred): the card menu and the form header
  ;({ p, ctx, st } = await open(w, 'st', '/forms'))
  ok((await navText(p)).includes('Page Builder'), `${tag} staff nav keeps Page Builder`)
  await p.click('button[aria-label^="More actions for"]')
  await p.waitForTimeout(500)
  const MI = await p.evaluate(() => [...document.querySelectorAll('[role="menuitem"]')].map((e) => e.textContent.trim().slice(0, 40)))
  ok(MI.length >= 3 && MI[0].startsWith(CARD) && MI.some((t) => /^Share form/.test(t)) && MI.some((t) => /^Cancel form/.test(t)), `${tag} staff menu: "${CARD}" first, Share form and Cancel form kept`, MI)
  await p.screenshot({ path: `${out}/st_menu_${w}.png`, fullPage: false })
  await ctx.close()
  ;({ p, ctx, st } = await open(w, 'st', `/forms/${SUB}`))
  const SD = await p.evaluate((HDR) => ({ pb: document.body.textContent.includes('Open the Page Builder'), tabs: document.querySelectorAll('[role="tablist"]').length, share: [...document.querySelectorAll('main button')].some((b) => b.textContent.trim() === HDR) }), HDR)
  ok(SD.pb && SD.tabs === 1 && SD.share, `${tag} staff form: Page Builder link, tabs and "${HDR}"`, SD)
  await p.screenshot({ path: `${out}/st_form_${w}.png`, fullPage: false })
  await ctx.close()
}
function SUB_ID() { return SUB }
await browser.close()
console.log(`${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
