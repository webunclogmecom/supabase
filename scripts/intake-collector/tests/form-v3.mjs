// form-v3.mjs : the collector form for question list version 3 (Fred, 2026-09-30): his short words on the lift station and
// water tank cards ("Access (optional)", "Control panel", "Lift station"; "Capacity", "Water tank"), the (i) on the
// capacity plate card, an explanation REQUIRED on every photo ("everytime you add a pic you need to put explaination":
// the panel with "Show me", the red boxes kept through a redraw, no "Done" beside an unexplained photo, "Submit anyway"
// cannot skip it) and Remove on every photo (asks first in the card, frees its place under max_photos), on a version 2
// form too. Local only: the parity harness serves the built form at its real URL and fakes intake-submit (load, upload,
// attach, remove, submit); nothing reaches the database or Google. It submits only to the fake.
//   node scripts/intake-collector/tests/form-v3.mjs [outdir]
//   INTAKE_HTML=<file>  serve another build (the control: the live bytes before the v3 page must FAIL every [new] check;
//                       each broken build of form_v3_patch.mjs --mutant <name> fails exactly its named checks)
// The version 3 load is built from the harness's load.json: taken as is when it is already version 3, else made from the
// version 2 tree with the SAME changes as the migration (mk_mig_tree.mjs); keep the two in step.
import fs from 'node:fs'
import { pathToFileURL } from 'node:url'
const { setup, open, LOAD, EP, PNG, sleep } = await import(process.env.PARITY_H || './parity/h.mjs')
const out = process.argv[2] || './form_v3_shots'; fs.mkdirSync(out, { recursive: true })
const FILE = pathToFileURL(process.env.INTAKE_HTML || new URL('../intake.html', import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1')).href
const clone = (x) => JSON.parse(JSON.stringify(x))
function toV3(l0) {
  const l = clone(l0); const t = l.form
  if (t.version === 3) return l
  const qs = () => t.sections.flatMap((s) => s.questions), q = (k) => qs().find((x) => x.key === k), sec = (id) => t.sections.find((s) => s.id === id)
  t.version = 3; t.photo_note_required = true
  Object.assign(q('grease_trap.capacity_photos'), { label: 'Photos of the capacity plate or gallons pumped, and measurements', info: "Take the grease trap's capacity plate. If there is none, the gallons pumped. Add the measurements too." })
  const ls = sec('lift_station'), lp = q('lift_station.photos'), cp = q('lift_station.control_panel_photos')
  ls.questions = ls.questions.filter((x) => x.key === 'lift_station.count')
  t.sections.splice(t.sections.indexOf(ls) + 1, 0, { id: 'lift_station_photos', title: 'Photos for the lift station', questions: [
    { key: 'lift_station.access_photos', type: 'photos', label: 'Lift station access', short: 'Access', show_if: 'lift_station.count>0', optional: true, max_photos: 3 },
    { ...cp, label: 'Lift station control panel', short: 'Control panel', max_photos: 3 }, { ...lp, label: 'Lift station' }] })
  const wt = sec('water_tank'), wp = q('water_tank.photos')
  wt.questions = wt.questions.filter((x) => x.key !== 'water_tank.photos')
  wt.questions.push({ key: 'water_tank.capacity_photos', type: 'photos', label: 'Water tank capacity', short: 'Capacity', show_if: 'water_tank.count>0', max_photos: 3 }, { ...wp, label: 'Water tank' })
  l.requested = qs().map((x) => x.key)
  return l
}
const V3 = toV3(LOAD)
const V2 = (() => { const l = clone(LOAD); delete l.form.photo_note_required; if (l.form.version === 3) l.form.version = 2; return l })()
const img = (n) => ({ name: n + '.png', mimeType: 'image/png', buffer: PNG })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${c || v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 400)}`) }
const PANEL2 = '2 photos need an explanation: Lift station (1), Water tank (1). Write what each photo shows in the box under it.'
const PANEL1 = '1 photo needs an explanation: Water tank (1). Write what each photo shows in the box under it.'
const PANEL4 = '4 photos need an explanation: Lift station access (3), Water tank (1). Write what each photo shows in the box under it.'
const INFO = "Take the grease trap's capacity plate. If there is none, the gallons pumped. Add the measurements too."

async function withRemove(context, S) {
  // the harness answers load/upload/attach/submit; this route answers remove (and lets every other call through)
  S.removes = []; S.rmFail = false; S.rmDelay = 0
  await context.route(EP, async (route) => {
    const r = route.request(); if (r.method() !== 'POST') return route.fallback()
    const b = JSON.parse(r.postData() || '{}'); if (b.op !== 'remove') return route.fallback()
    S.ops.push('remove'); S.removes.push(b.path)
    if (S.rmDelay) await sleep(S.rmDelay)
    if (S.rmFail) return route.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ ok: false, message: 'That photo does not belong to this form.' }) })
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, removed: true }) })
  })
}
const idle = (p) => p.waitForFunction(() => !document.querySelector('.ph .t.send') && busy === 0 && (typeof RMV === 'undefined' || RMV === 0), null, { timeout: 20000 }).catch(() => {})
// a tap that never throws (the control build has no such control: its check fails, the run goes on)
const tap = async (loc) => { if (await loc.count()) await loc.first().click({ timeout: 4000 }).catch(() => {}) }
const plus = async (p, key, n = 1) => { for (let i = 0; i < n; i++) { await p.locator(`[data-f="${key}:+"]`).first().click(); await sleep(150) } }
const addPhoto = async (p, key, name) => { await p.locator(`[data-q="${key}"] input[type=file]:not([capture])`).setInputFiles(img(name)); await sleep(250); await idle(p) }
const box = (p, key, i = 0) => p.locator(`[data-q="${key}"] textarea.pcm`).nth(i)
const card = (p, key) => p.evaluate((key) => {
  const q = document.querySelector(`[data-q="${key}"]`); if (!q) return null
  const t = (e) => (e ? e.textContent.replace(/\s+/g, ' ').trim() : null)
  const R = (e) => { const b = e.getBoundingClientRect(); return { w: Math.round(b.width), h: Math.round(b.height) } }
  const ib = q.querySelector('.ib'), qi = q.querySelector('.qi')
  return { label: t(q.querySelector(':scope > label')), ib: ib ? { aria: ib.getAttribute('aria-label'), exp: ib.getAttribute('aria-expanded'), ctl: ib.getAttribute('aria-controls'), size: R(ib), title: ib.getAttribute('title') } : null,
    hint: qi ? { text: t(qi), hidden: qi.hidden, id: qi.id, shown: qi.getClientRects().length > 0 } : null,
    boxes: [...q.querySelectorAll('textarea.pcm')].map((b) => ({ ph: b.placeholder, aria: b.getAttribute('aria-label'), req: b.getAttribute('aria-required'), bad: b.classList.contains('bad'), inv: b.getAttribute('aria-invalid'), v: b.value })),
    rms: [...q.querySelectorAll('.prm')].map((b) => ({ aria: b.getAttribute('aria-label'), size: R(b) })), rmq: q.querySelector('.rmq') ? [t(q.querySelector('.rmq > div')), ...[...q.querySelectorAll('.rmq button')].map(t)].join(' / ') : null,
    tiles: q.querySelectorAll('.ph .t').length, note: t(q.querySelector(':scope > .note')), errs: [...q.querySelectorAll('.err span')].map(t),
    choose: !!q.querySelector(`[data-f="${key}:ph"]`) }
}, key)
const secHead = (p, id) => p.evaluate((id) => { const s = document.querySelector(`[data-sc="${id}"]`); return s ? { h2: s.parentElement.querySelector('h2').textContent, sc: s.textContent, cls: s.className } : null }, id)
const panel = (p) => p.evaluate(() => { const n = document.querySelector('#fmsg .nt'); return n ? { text: n.firstChild.textContent, role: n.getAttribute('role'), btn: [...n.querySelectorAll('button')].map((b) => b.textContent) } : null })
const draftOf = (p, k) => p.evaluate((k) => { const d = JSON.parse(localStorage.getItem('intake-draft-TESTTOKEN123') || 'null'); return ((d && d[k]) || []).map((x) => x.path) }, k)

for (const [name, mobile] of [['phone390', true], ['desktop1280', false]]) {
  const { browser, context, page: p, S } = await setup({ mobile, file: FILE, load: V3, ctx: mobile ? {} : { deviceScaleFactor: 1 } })
  await withRemove(context, S)
  try {
    await open(p)
    await plus(p, 'grease_trap.systems_count'); await plus(p, 'lift_station.count'); await plus(p, 'water_tank.count')
    // his words on the form
    const L = {}; for (const k of ['lift_station.access_photos', 'lift_station.control_panel_photos', 'lift_station.photos', 'water_tank.capacity_photos', 'water_tank.photos']) L[k] = (await card(p, k) || {}).label
    ok(L['lift_station.access_photos'] === 'Access (optional)' && L['lift_station.control_panel_photos'] === 'Control panel' && L['lift_station.photos'] === 'Lift station', `${name}: [new] V3a the lift station cards read "Access (optional)", "Control panel", "Lift station"`, L)
    ok(L['water_tank.capacity_photos'] === 'Capacity' && L['water_tank.photos'] === 'Water tank', `${name}: [new] V3a the water tank cards read "Capacity" and "Water tank"`, L)
    const hs = await secHead(p, 'lift_station_photos')
    ok(!!hs && hs.h2 === 'Photos for the lift station', `${name}: [guard] V3a the section "Photos for the lift station" is drawn under "Lift station"`, hs)
    // the (i)
    let c = await card(p, 'grease_trap.capacity_photos')
    ok(!!c && c.label === 'Photos of the capacity plate or gallons pumped, and measurements' && !!c.ib && c.ib.aria === 'More about this question' && c.ib.exp === 'false' && c.ib.ctl === (c.hint && c.hint.id) && !c.ib.title && c.hint && c.hint.hidden && !c.hint.shown, `${name}: [new] V3b the capacity plate card: new label, an (i) "More about this question" (aria-expanded false, controls the hint), the hint hidden`, c && { label: c.label, ib: c.ib, hint: c.hint })
    ok(!!c && !!c.ib && (mobile ? c.ib.size.w >= 44 && c.ib.size.h >= 44 : c.ib.size.w >= 32 && c.ib.size.h >= 32), `${name}: [new] V3b the (i) tap area is ${mobile ? '44x44 on a phone' : '32x32 at the PC scale'}`, c && c.ib)
    await tap(p.locator('[data-q="grease_trap.capacity_photos"] .ib')); await sleep(150)
    c = await card(p, 'grease_trap.capacity_photos')
    ok(!!c && c.ib && c.ib.exp === 'true' && c.hint && !c.hint.hidden && c.hint.shown && c.hint.text === INFO, `${name}: [new] V3b a tap opens the hint under the label with the question's text`, c && { ib: c.ib, hint: c.hint })
    await addPhoto(p, 'grease_trap.capacity_photos', 'plate')
    c = await card(p, 'grease_trap.capacity_photos')
    ok(!!c && c.tiles === 1 && c.hint && c.hint.shown && c.ib.exp === 'true', `${name}: [new] V3b the hint stays open when a photo lands (every card is redrawn)`, c && { tiles: c.tiles, hint: c.hint, exp: c.ib && c.ib.exp })
    await tap(p.locator('[data-q="grease_trap.capacity_photos"] .ib')); await sleep(150)
    c = await card(p, 'grease_trap.capacity_photos')
    ok(!!c && c.hint && c.hint.hidden && c.ib.exp === 'false', `${name}: [new] V3b a second tap closes it`, c && c.hint)
    // the explanation box
    ok(!!c && c.boxes.length === 1 && c.boxes[0].ph === 'What does this photo show?' && c.boxes[0].aria === 'Explanation for photo 1' && c.boxes[0].req === 'true', `${name}: [new] V3c on a version 3 form the box asks "What does this photo show?" (aria "Explanation for photo 1", required)`, c && c.boxes)
    await box(p, 'grease_trap.capacity_photos').fill('The plate on the lid, 1000 gallons')
    // the water tank section, fully answered, with two photos
    await plus(p, 'water_tank.manhole_count')
    const cap = p.locator('[data-q="water_tank.capacity"] textarea, [data-q="water_tank.capacity"] input[type=text]').first(); await cap.fill('500 gallons'); await cap.press('Tab'); await sleep(200)
    await addPhoto(p, 'water_tank.capacity_photos', 'wcap'); await box(p, 'water_tank.capacity_photos').fill('The tank label, 500 gallons')
    await addPhoto(p, 'water_tank.photos', 'tank')
    await addPhoto(p, 'lift_station.photos', 'station')
    const wh = await secHead(p, 'water_tank')
    ok(!!wh && wh.sc === '' && wh.cls !== 'done', `${name}: [new] V3g every Water tank question answered but one photo unexplained: its counter is blank, never "Done"`, wh)
    // Submit: the name first, then the explanations (before the blank-questions step)
    await p.fill('#who', 'Test Collector'); await p.locator('#send').click(); await sleep(300)
    let pn = await panel(p)
    ok(!!pn && pn.text === PANEL2 && pn.role === 'alert' && pn.btn.join() === 'Show me' && S.submits.length === 0 && !(await p.locator('.cf .row button', { hasText: 'Submit anyway' }).count()), `${name}: [new] V3d Submit names the unexplained photos in the panel ("Show me"), sends nothing, and shows no "Submit anyway"`, { pn, submits: S.submits.length })
    const lb = await card(p, 'lift_station.photos'), wb = await card(p, 'water_tank.photos'), gb0 = await card(p, 'grease_trap.capacity_photos')
    ok(lb.boxes[0].bad && lb.boxes[0].inv === 'true' && wb.boxes[0].bad && !gb0.boxes[0].bad, `${name}: [new] V3d the two empty boxes are red (aria-invalid), the explained one is not`, { lift: lb.boxes, tank: wb.boxes, plate: gb0.boxes })
    // "Show me": the first empty box has the cursor, inside the tap
    await tap(p.locator('#fmsg .nt button')); await sleep(60)
    const act = await p.evaluate(() => document.activeElement && document.activeElement.getAttribute('data-f'))
    ok(act === 'lift_station.photos:note:0', `${name}: [new] V3f "Show me" puts the cursor in the first empty box within the tap`, act)
    await box(p, 'lift_station.photos').pressSequentially('The pump pit, lid open', { delay: 3 }); await sleep(150)
    pn = await panel(p)
    ok(!!pn && pn.text === PANEL1 && !(await card(p, 'lift_station.photos')).boxes[0].bad, `${name}: [new] V3e typing clears that box's red and the panel counts again (1 left)`, pn)
    await plus(p, 'water_tank.manhole_count'); await p.evaluate(() => render()); await sleep(200)
    const wb2 = await card(p, 'water_tank.photos'); pn = await panel(p)
    ok(wb2.boxes[0].bad && !!pn && pn.text === PANEL1, `${name}: [new] V3e after a redraw (another answer) the water tank box is still red and the panel still says 1`, { box: wb2.boxes[0], pn })
    // Remove, on the lift station photo: asks first; Keep keeps
    let lc = await card(p, 'lift_station.photos')
    ok(lc.rms.length === 1 && lc.rms[0].aria === 'Remove photo 1' && (mobile ? lc.rms[0].size.w >= 44 && lc.rms[0].size.h >= 44 : lc.rms[0].size.w >= 32), `${name}: [new] R1 each photo has "Remove photo N" (${mobile ? '44x44' : '32x32'})`, lc.rms)
    await tap(p.locator('[data-q="lift_station.photos"] .prm')); await sleep(150)
    lc = await card(p, 'lift_station.photos')
    const focusK = await p.evaluate(() => document.activeElement && document.activeElement.textContent)
    const sawConfirm = lc.rmq === 'Remove this photo? / Keep / Remove'
    ok(sawConfirm && S.removes.length === 0 && focusK === 'Keep', `${name}: [new] R1 Remove asks first in the card ("Remove this photo?" Keep / Remove, focus on Keep), nothing sent`, { rmq: lc.rmq, removes: S.removes, focusK })
    // the two buttons of the confirm: each word on ONE line and inside the photo's tile (a half-width tile on a phone broke
    // "Remove" into "Remov" / "e" when they sat side by side; review 2026-09-30)
    const rw = await p.evaluate(() => [...document.querySelectorAll('[data-q="lift_station.photos"] .rmq button')].map((b) => {
      const r = document.createRange(); r.selectNodeContents(b)
      const lines = new Set([...r.getClientRects()].filter((x) => x.width > 0).map((x) => Math.round(x.top))).size
      const t = b.closest('.pi').getBoundingClientRect(), bb = b.getBoundingClientRect()
      return { t: b.textContent, lines, inside: bb.left >= t.left - 0.5 && bb.right <= t.right + 0.5 } }))
    ok(rw.length === 2 && rw.every((x) => x.lines === 1 && x.inside), `${name}: [new] R1 Keep and Remove each sit on one line inside the photo's tile (never "Remov" / "e")`, rw)
    await tap(p.locator('[data-q="lift_station.photos"] .rmq .no')); await sleep(150)
    lc = await card(p, 'lift_station.photos')
    ok(sawConfirm && lc.tiles === 1 && !lc.rmq && lc.boxes[0].v === 'The pump pit, lid open', `${name}: [new] R1 Keep puts the card back as it was (the photo and its explanation)`, lc)
    // the capped access photo: 3 of 3, remove 1, the buttons come back
    await p.locator('[data-q="lift_station.access_photos"] input[type=file]:not([capture])').setInputFiles([img('a1'), img('a2'), img('a3')]); await sleep(300); await idle(p)
    let ac = await card(p, 'lift_station.access_photos')
    ok(ac.tiles === 3 && !ac.choose, `${name}: [guard] R3 Access at 3 of 3: no add button`, ac)
    // the panel counts the three new photos, and names their question by its full label, never the card's short word
    pn = await panel(p)
    ok(!!pn && pn.text === PANEL4, `${name}: [new] V3d the panel names a question by its full label ("Lift station access"), never the card's short word alone`, pn)
    const before = await draftOf(p, 'lift_station.access_photos')
    await tap(p.locator('[data-q="lift_station.access_photos"] .prm').nth(1)); await sleep(120)
    await tap(p.locator('[data-q="lift_station.access_photos"] .rmq .go')); await sleep(250); await idle(p)
    ac = await card(p, 'lift_station.access_photos'); const after = await draftOf(p, 'lift_station.access_photos')
    ok(S.removes.length === 1 && S.removes[0] === before[1], `${name}: [new] R2 Remove sends op remove with THAT photo's path`, { removes: S.removes, before })
    ok(ac.tiles === 2 && ac.choose && ac.note === '2 photos attached' && after.length === 2 && !after.includes(before[1]), `${name}: [new] R2/R3 the photo leaves the card and the draft, and its place is free again ("Choose more photos" is back)`, { tiles: ac.tiles, choose: ac.choose, note: ac.note, after })
    // a Remove the server refuses: the photo stays, the server's words on the card
    S.rmFail = true
    await tap(p.locator('[data-q="lift_station.access_photos"] .prm')); await sleep(120)
    await tap(p.locator('[data-q="lift_station.access_photos"] .rmq .go')); await sleep(250); await idle(p)
    ac = await card(p, 'lift_station.access_photos'); S.rmFail = false
    ok(ac.tiles === 2 && ac.errs.includes('That photo does not belong to this form.'), `${name}: [new] R4 a refused Remove keeps the photo and shows the server's sentence on the card`, ac)
    // a Remove on its way holds Submit
    S.rmDelay = 900
    await tap(p.locator('[data-q="lift_station.access_photos"] .prm')); await sleep(120)
    await tap(p.locator('[data-q="lift_station.access_photos"] .rmq .go')); await sleep(250)
    const sb = await p.evaluate(() => { const b = document.getElementById('send'); return { dis: b.disabled, txt: b.textContent } })
    await idle(p); S.rmDelay = 0
    ok(sb.dis && sb.txt === 'Removing...', `${name}: [new] R6 while a Remove is on its way Submit is disabled and reads "Removing..."`, sb)
    // the explanations for the access photo left (1 photo on the card now), then the last box: the panel goes
    await box(p, 'lift_station.access_photos').fill('The hatch behind the dumpster')
    pn = await panel(p); const hadPanel = !!pn && pn.text === PANEL1
    ok(hadPanel, `${name}: [new] V3e the panel counts what Submit would send (still the water tank photo)`, pn)
    await box(p, 'water_tank.photos').fill('The tank from the alley'); await sleep(150)
    pn = await panel(p); const badN = await p.locator('textarea.pcm.bad').count(); const wh2 = await secHead(p, 'water_tank')
    ok(hadPanel && pn === null && badN === 0 && (await p.locator('#fmsg').innerHTML()) === '', `${name}: [new] V3h at 0 the panel goes and no box is red`, { pn, badN })
    ok(!!wh2 && wh2.sc === 'Done' && wh2.cls === 'done', `${name}: [guard] V3g every Water tank photo explained: "Done"`, wh2)
    // "Submit anyway" once every photo is explained; the notes carry every photo
    await p.locator('#send').click(); await sleep(300)
    const go = p.locator('.cf .go', { hasText: 'Submit anyway' }); const cfShown = await go.count()
    if (cfShown) { await go.click(); await sleep(400) }
    const sub = S.submits[0] || {}
    const sent = Object.entries(sub.answers || {}).filter(([, v]) => Array.isArray(v)).flatMap(([, v]) => v)
    ok(cfShown === 1 && sent.length === 5 && sent.every((x) => typeof x === 'string') && sent.every((x) => typeof (sub.notes || {})[x] === 'string' && sub.notes[x].trim()), `${name}: [new] V3i the blank-questions step comes after, and the submit carries paths only plus an explanation for each of the 5 photos`, { cfShown, sent, notes: sub.notes })
    // the one refused Remove (R4) answers 400 on purpose, and Chrome logs that response; nothing else may log
    const errs = S.errors.filter((e) => !/status of 400/.test(e))
    ok(errs.length === 0, `${name}: no console error (besides the one deliberate 400 of R4)`, S.errors)
    const ov = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
    ok(ov === 0, `${name}: no sideways scroll`, ov)
  } catch (e) { ok(false, `${name}: run`, String(e)) }
  await p.screenshot({ path: `${out}/${name}_v3.png`, fullPage: true }).catch(() => {})
  await browser.close()
  // a version 2 form: the optional comment as before, no panel, and Remove too
  const r2 = await setup({ mobile, file: FILE, load: V2, ctx: mobile ? {} : { deviceScaleFactor: 1 } })
  await withRemove(r2.context, r2.S)
  try {
    const q = r2.page
    await open(q)
    await q.locator('[data-q="access_entry.access_photos"] input[type=file]:not([capture])').setInputFiles([img('b1'), img('b2')]); await sleep(300); await idle(q)
    let c2 = await card(q, 'access_entry.access_photos')
    ok(c2.boxes.length === 2 && c2.boxes.every((b, i) => b.ph === 'Comment (optional)' && b.aria === `Comment for photo ${i + 1}` && !b.req), `${name}: [guard] V2 a version 2 form keeps "Comment (optional)" (aria "Comment for photo N", not required)`, c2.boxes)
    ok(c2.rms.length === 2, `${name}: [new] R5 Remove is on a version 2 form too`, c2.rms)
    await tap(q.locator('[data-q="access_entry.access_photos"] .prm')); await sleep(120)
    await tap(q.locator('[data-q="access_entry.access_photos"] .rmq .go')); await sleep(250); await idle(q)
    c2 = await card(q, 'access_entry.access_photos')
    ok(c2.tiles === 1 && r2.S.removes.length === 1, `${name}: [new] R5 ... and removes`, { tiles: c2.tiles, removes: r2.S.removes })
    await q.fill('#who', 'Test Collector'); await q.locator('#send').click(); await sleep(300)
    const pn2 = await panel(q); const go2 = q.locator('.cf .go', { hasText: 'Submit anyway' }); const cf2 = await go2.count()
    if (cf2) { await go2.click(); await sleep(400) }
    ok(pn2 === null && cf2 === 1 && r2.S.submits.length === 1 && JSON.stringify(r2.S.submits[0].notes) === '{}', `${name}: [guard] V2 Submit asks no explanation and sends as before (notes {})`, { pn2, cf2, submits: r2.S.submits.length })
    ok(r2.S.errors.length === 0, `${name}: V2 no console error`, r2.S.errors)
  } catch (e) { ok(false, `${name}: V2 run`, String(e)) }
  await r2.browser.close()
}
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
