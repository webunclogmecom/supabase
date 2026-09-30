// photo-comment-camera.mjs : the collector form's comment per photo (layout D1) and the phone camera (Fred, 2026-09-29:
// "When uploading a photo we need to also have a comment for the photo ... we need to be able to take a picture with the
// phone, not just upload a picture"; he picked D1: two photos per row on a phone, a two-line box under each). Local only:
// the parity harness serves the built form at its real URL and fakes intake-submit (load, upload, attach, submit); nothing
// reaches the database or Google. It submits only to the fake. What a real phone OPENS is not provable here: after the
// publish Fred taps "Take a photo" on his Android phone and his iPhone (T2 plan, last step).
//   node scripts/intake-collector/tests/photo-comment-camera.mjs [outdir]
//   INTAKE_HTML=<file>  serve another build (the control: the build without photo_patch.mjs must FAIL every check it
//                       reaches; the live bytes after the publish must PASS)
import fs from 'node:fs'
import { pathToFileURL } from 'node:url'
const { setup, open, LOAD, PNG, sleep } = await import(process.env.PARITY_H || './parity/h.mjs')
const out = process.argv[2] || './photo_comment_shots'; fs.mkdirSync(out, { recursive: true })
const FILE = pathToFileURL(process.env.INTAKE_HTML || new URL('../intake.html', import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1')).href
const clone = (x) => JSON.parse(JSON.stringify(x))
// the version 2 question, added to the recorded load reply when it is not there yet
const ALARM = { key: 'access_entry.alarm_photos', label: 'Photos of the alarm', type: 'photos', show_if: 'access_entry.alarm=yes', optional: true, max_photos: 3 }
const load = () => { const l = clone(LOAD); const s = l.form.sections.find((x) => x.id === 'access_entry'); if (!s.questions.some((q) => q.key === ALARM.key)) s.questions.splice(s.questions.findIndex((q) => q.key === 'access_entry.alarm_instruction') + 1, 0, clone(ALARM)); if (Array.isArray(l.requested) && !l.requested.includes(ALARM.key)) l.requested.splice(l.requested.indexOf('access_entry.alarm_instruction') + 1, 0, ALARM.key); return l }
const img = (n) => ({ name: n + '.png', mimeType: 'image/png', buffer: PNG })
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 360)}`) }
const AP = 'access_entry.access_photos'
const TEXT = 'Alley access, enter here'
const card = (p, key) => p.evaluate((key) => {
  const q = document.querySelector(`[data-q="${key}"]`); if (!q) return null
  const vis = (e) => !!(e && e.getClientRects().length && getComputedStyle(e).display !== 'none')
  const R = (e) => { const b = e.getBoundingClientRect(); return { x: Math.round(b.x), y: Math.round(b.y), r: Math.round(b.right), b: Math.round(b.bottom), h: Math.round(b.height) } }
  const cam = q.querySelector(`[data-f="${key}:cam"]`), ch = q.querySelector(`[data-f="${key}:ph"]`)
  const ins = [...q.querySelectorAll('input[type=file]')].map((i) => ({ accept: i.accept, capture: i.getAttribute('capture'), multiple: i.multiple }))
  const items = [...q.querySelectorAll('.ph .pi')].map((it) => { const t = it.querySelector('.t'), b = it.querySelector('.pcm'); return { tile: t ? R(t) : null, box: b ? R(b) : null } })
  const boxes = [...q.querySelectorAll('.pcm')].map((b) => { const c = getComputedStyle(b), r = b.getBoundingClientRect(); return { tag: b.tagName, rows: b.rows, v: b.value, aria: b.getAttribute('aria-label'), max: b.maxLength, ph: b.placeholder, h: Math.round(r.height), fs: c.fontSize } })
  return { cam: vis(cam) ? cam.textContent.trim() : null, camInDom: !!cam, choose: vis(ch) ? ch.textContent.trim() : null, ins, items, boxes, tiles: q.querySelectorAll('.ph .t').length, note: (q.querySelector('.note') || {}).textContent }
}, key)
const idle = (p) => p.waitForFunction(() => !document.querySelector('.ph .t.send') && busy === 0, null, { timeout: 20000 }).catch(() => {})
const note0 = (p) => p.evaluate((k) => { const d = JSON.parse(localStorage.getItem('intake-draft-TESTTOKEN123') || 'null'); return ((d && d[k]) || []).map((x) => x.note || '') }, AP)

for (const [name, mobile] of [['phone390', true], ['desktop1280', false]]) {
  const { browser, page: p, S } = await setup({ mobile, file: FILE, load: load(), ctx: mobile ? {} : { deviceScaleFactor: 2 } })
  const shot = async (key, tag) => { await p.evaluate(() => { document.getElementById('foot').style.visibility = 'hidden' }); const el = p.locator(`[data-q="${key}"]`); await el.scrollIntoViewIfNeeded(); await sleep(150); await el.screenshot({ path: `${out}/${name}_${tag}.png` }).catch(() => {}); await p.evaluate(() => { document.getElementById('foot').style.visibility = '' }) }
  try {
    await open(p)
    await p.locator('[data-q="access_entry.access_point"]').getByRole('button', { name: 'Back door', exact: true }).click().catch(() => {})
    let c = await card(p, AP)
    const capIn = c.ins.find((i) => i.capture), chIn = c.ins.find((i) => !i.capture)
    ok(c.ins.length === 2 && capIn && capIn.capture === 'environment' && capIn.accept === 'image/*' && !capIn.multiple && chIn && chIn.accept === 'image/*' && chIn.multiple, `${name}: two inputs, the camera one single with capture=environment, the other multiple`, c.ins)
    if (mobile) ok(c.cam === 'Take a photo' && c.choose === 'Choose photos', `${name}: "Take a photo" and "Choose photos" shown`, { cam: c.cam, choose: c.choose })
    else ok(c.cam === null && c.camInDom && c.choose === 'Choose photos', `${name}: the PC scale hides "Take a photo", "Choose photos" shown`, { cam: c.cam, inDom: c.camInDom, choose: c.choose })
    await shot(AP, 'empty')
    await p.locator(`[data-q="${AP}"] input[type=file][capture]`).setInputFiles(img('camera')); await sleep(300); await idle(p)
    await p.locator(`[data-q="${AP}"] input[type=file]:not([capture])`).setInputFiles(img('chosen')); await sleep(300); await idle(p)
    c = await card(p, AP)
    ok(c.tiles === 2 && S.ops.filter((o) => o === 'attach').length === 2, `${name}: one photo through the camera input, one through Choose photos, both attached`, { tiles: c.tiles, ops: S.ops })
    if (mobile) ok(c.cam === 'Take another photo' && c.choose === 'Choose more photos', `${name}: after a photo the buttons read "Take another photo" and "Choose more photos"`, { cam: c.cam, choose: c.choose })
    ok(c.boxes.length === 2 && c.boxes.every((b, i) => b.tag === 'TEXTAREA' && b.rows === 2 && b.aria === `Comment for photo ${i + 1}` && b.max === 300 && b.ph === 'Comment (optional)' && b.v === ''), `${name}: a two-line comment box per photo, aria-label "Comment for photo N", 300 at most, "Comment (optional)"`, c.boxes)
    // D1 as drawn: each box right under its own photo; on a phone the two photos side by side
    const under = c.items.length === 2 && c.items.every((it) => it.tile && it.box && it.box.y >= it.tile.b && it.box.y - it.tile.b <= 12 && Math.abs(it.box.x - it.tile.x) <= 1 && Math.abs(it.box.r - it.tile.r) <= 1)
    const side = c.items.length === 2 && c.items[0].tile.y === c.items[1].tile.y && c.items[1].tile.x > c.items[0].tile.r
    ok(under && side, `${name}: D1, the two photos side by side and each comment box right under its photo, as wide as it`, c.items)
    ok(mobile ? c.boxes[0].h >= 64 && c.boxes[0].fs === '16px' : c.boxes[0].h >= 52 && c.boxes[0].fs === '14px', `${name}: box size (${mobile ? '64px or more and 16px text on a phone, so an iPhone does not zoom' : '52px or more and 14px text under the PC scale'})`, c.boxes[0])
    const b0 = p.locator(`[data-q="${AP}"] .pcm`).first(), b1 = p.locator(`[data-q="${AP}"] .pcm`).nth(1)
    await b0.click(); await b0.pressSequentially(TEXT, { delay: 5 }); await b0.press('Enter')
    await p.evaluate(() => render()); await sleep(150)
    const focus = await p.evaluate(() => document.activeElement && document.activeElement.getAttribute('data-f'))
    ok(focus === `${AP}:note:0`, `${name}: a redraw gives the focus back to the box being typed in`, focus)
    await b1.fill('Line one\nline\ttwo'); await sleep(100)
    const pasted = await b1.inputValue(), pd = await note0(p)
    ok(pasted === 'Line one line two' && pd[1] === 'Line one line two', `${name}: a line break or a tab put in the box becomes a space (one line, as intake-submit wants it), in the box and in the draft`, { box: pasted, draft: pd[1] })
    await b1.fill(''); await sleep(100)
    await p.evaluate(() => document.activeElement && document.activeElement.blur())
    c = await card(p, AP)
    const dn = await note0(p)
    ok(c.boxes[0].v === TEXT && dn[0] === TEXT && dn[1] === '', `${name}: Enter adds no line; the comment survives a redraw and sits on its own photo in the draft`, { v: c.boxes[0].v, dn })
    await shot(AP, 'two')
    // the capped question: both buttons at 2 of 3 (Choose takes one file), none at 3
    await p.locator('[data-f="access_entry.alarm=yes"]').first().click().catch(() => {}); await sleep(250)
    await p.locator(`[data-q="${ALARM.key}"] input[type=file]:not([capture])`).setInputFiles([img('lid1'), img('lid2')]); await sleep(300); await idle(p)
    c = await card(p, ALARM.key)
    const ch2 = c.ins.find((i) => !i.capture)
    ok(c.ins.length === 2 && ch2 && ch2.multiple === false && c.choose === 'Choose more photos' && (mobile ? c.cam === 'Take another photo' : c.cam === null), `${name}: Alarm photos at 2 of 3: both inputs, Choose takes one file`, { ins: c.ins, cam: c.cam, choose: c.choose })
    await p.locator(`[data-q="${ALARM.key}"] input[type=file][capture]`).setInputFiles(img('plate')); await sleep(300); await idle(p)
    c = await card(p, ALARM.key)
    ok(c.tiles === 3 && c.ins.length === 0 && !c.camInDom && c.choose === null && c.boxes.length === 3 && c.note === '3 photos attached', `${name}: at 3 of 3 neither button nor input is drawn, each photo keeps its box, "3 photos attached"`, { tiles: c.tiles, ins: c.ins.length, cam: c.camInDom, choose: c.choose, boxes: c.boxes.length, note: c.note })
    await shot(ALARM.key, 'alarm_full')
    const ov = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
    ok(ov === 0, `${name}: no sideways scroll`, ov)
    // Submit: the answers are paths only; notes carries the one non-empty comment, on its photo's path
    await p.fill('#who', 'Test Collector')
    await p.locator('#send').click(); await sleep(300)
    const go = p.locator('.cf .go'); if (await go.count()) { await go.click(); await sleep(400) }
    const sub = S.submits[0] || {}
    const paths = (sub.answers || {})[AP] || []
    ok(Array.isArray(paths) && paths.length === 2 && paths.every((x) => typeof x === 'string') && sub.notes && Object.keys(sub.notes).length === 1 && sub.notes[paths[0]] === TEXT, `${name}: Submit sends the answers as paths and notes {path: comment} for the one comment`, { answers: paths, notes: sub.notes })
    ok(S.errors.length === 0, `${name}: no console error`, S.errors)
  } catch (e) { ok(false, `${name}: run`, String(e)) }
  await browser.close()
}
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
