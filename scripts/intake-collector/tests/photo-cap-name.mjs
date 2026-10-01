// photo-cap-name.mjs : the collector form's per-question photo limit and its "Your name" prefill (Fred, 2026-09-29:
// "when yes it needs to be able (optional) to add up to 3 pictures for the Alarm"; "we can take even advantage of that to
// prefill the name field at the intake form"). Local only: the parity harness serves the built form at its real URL and
// fakes intake-submit (load, upload, attach, submit); nothing reaches the database or Google. It submits only to the fake.
//   node scripts/intake-collector/tests/photo-cap-name.mjs [outdir]
//   INTAKE_HTML=<file>  serve another build (the control: the build before this change must FAIL the cap and name checks;
//                       the live bytes after the publish must PASS)
import fs from 'node:fs'
import { pathToFileURL } from 'node:url'
const { setup, open, LOAD, EP, PNG, sleep } = await import(process.env.PARITY_H || './parity/h.mjs')
const out = process.argv[2] || './cap_name_shots'; fs.mkdirSync(out, { recursive: true })
const FILE = pathToFileURL(process.env.INTAKE_HTML || new URL('../intake.html', import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1')).href
const clone = (x) => JSON.parse(JSON.stringify(x))
// the version 2 question (tree_new.json), added to the recorded load reply when it is not there yet
const ALARM_PHOTOS = { key: 'access_entry.alarm_photos', label: 'Photos of the alarm', type: 'photos', show_if: 'access_entry.alarm=yes', optional: true, max_photos: 3 }
// the version 2 behaviour is what this file tests: drop version 3's flag if load.json carries it
const withTree = (extra = {}) => { const l = { ...clone(LOAD), ...extra }; delete l.form.photo_note_required; const s = l.form.sections.find((x) => x.id === 'access_entry'); if (!s.questions.some((q) => q.key === ALARM_PHOTOS.key)) s.questions.splice(s.questions.findIndex((q) => q.key === 'access_entry.alarm_instruction') + 1, 0, clone(ALARM_PHOTOS)); if (Array.isArray(l.requested) && !l.requested.includes(ALARM_PHOTOS.key)) l.requested.splice(l.requested.indexOf('access_entry.alarm_instruction') + 1, 0, ALARM_PHOTOS.key); return l }
const WHO = 'intake-draft-TESTTOKEN123-who'
const CAP_MSG = 'This question takes at most 3 photos.'
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 360)}`) }
const files = (n) => Array.from({ length: n }, (_, i) => ({ name: `p${i + 1}.png`, mimeType: 'image/png', buffer: PNG }))
const card = (p, key) => p.evaluate((key) => {
  const q = document.querySelector(`[data-q="${key}"]`); if (!q) return null
  const t = (e) => (e ? e.textContent.replace(/\s+/g, ' ').trim() : null)
  const b = q.querySelector(`[data-f="${key}:ph"]`), inp = q.querySelector('input[type=file]:not([capture])')
  return { label: t(q.querySelector('label')), note: t(q.querySelector('.note')), errs: [...q.querySelectorAll('.err span')].map(t), button: !!(b && b.getClientRects().length), multiple: inp ? inp.multiple : null, tiles: q.querySelectorAll('.ph .t').length }
}, key)
const idle = (p) => p.waitForFunction(() => !document.querySelector('.ph .t.send'), null, { timeout: 20000 }).catch(() => {})
const yes = async (p, key) => { await p.locator(`[data-f="${key}=yes"]`).first().click({ timeout: 4000 }).catch(() => {}); await sleep(300) }
const pick = async (p, key, n) => { await p.locator(`[data-q="${key}"] input[type=file]:not([capture])`).setInputFiles(files(n)); await sleep(300); await idle(p); await sleep(300) }
const attaches = (S) => S.ops.filter((o) => o === 'attach').length

for (const [name, mobile, w, h] of [['phone390', true, 390, 844], ['desktop1280', false, 1280, 900]]) {
  const ctx = { viewport: { width: w, height: h } }
  { // the alarm photos card: optional, four picked keep three and say one was not added, the button goes at 3
    const { browser, page: p, S } = await setup({ mobile, file: FILE, load: withTree(), ctx })
    await open(p)
    await yes(p, 'access_entry.alarm')
    let c = await card(p, 'access_entry.alarm_photos')
    ok(!!c && c.label === 'Photos of the alarm (optional)' && c.note === 'No photos yet.' && c.button, `${name}: Alarm yes shows "Photos of the alarm (optional)" with today's "No photos yet." and the add button`, c)
    await pick(p, 'access_entry.alarm_photos', 4)
    c = await card(p, 'access_entry.alarm_photos')
    ok(!!c && attaches(S) === 3 && c.tiles === 3 && c.note === '3 photos attached', `${name}: four picked, three sent and attached ("3 photos attached")`, { attach: attaches(S), c })
    ok(!!c && c.errs.includes('This question takes at most 3 photos, so 1 photo was not added.'), `${name}: a sentence says one photo was not added (it stays until dismissed)`, c && c.errs)
    ok(!!c && !c.button, `${name}: at 3 photos the add button is gone`, c)
    await p.screenshot({ path: `${out}/${name}_cap.png`, fullPage: false }).catch(() => {})
    ok(S.errors.length === 0, `${name}: no page errors`, S.errors)
    await browser.close()
  }
  { // two picked: room for one, so the picker takes one file at a time; the button stays
    const { browser, page: p } = await setup({ mobile, file: FILE, load: withTree(), ctx })
    await open(p); await yes(p, 'access_entry.alarm')
    await pick(p, 'access_entry.alarm_photos', 2)
    const c = await card(p, 'access_entry.alarm_photos')
    ok(!!c && c.note === '2 photos attached' && c.button && c.multiple === false && c.errs.length === 0, `${name}: two attached, the button stays and picks one file (multiple off)`, c)
    await browser.close()
  }
}
{ // the server's own refusal (a 4th photo from anywhere) is shown as sent
  const { browser, context, page: p } = await setup({ mobile: true, file: FILE, load: withTree() })
  await context.route(EP, async (route) => { const b = JSON.parse(route.request().postData() || '{}'); if (b.op === 'attach') return route.fulfill({ status: 429, contentType: 'application/json', body: JSON.stringify({ ok: false, message: CAP_MSG }) }); return route.fallback() })
  await open(p); await yes(p, 'access_entry.alarm')
  await pick(p, 'access_entry.alarm_photos', 1)
  const c = await card(p, 'access_entry.alarm_photos')
  ok(!!c && c.errs.includes(CAP_MSG) && c.note === 'No photos yet.', 'phone390: a 429 from the server shows its sentence and keeps nothing', c)
  await browser.close()
}
{ // guard: a photo question with no limit is today's (no "up to", several files at once, the button stays)
  const { browser, page: p, S } = await setup({ mobile: true, file: FILE, load: withTree() })
  await open(p)
  const sys = p.locator('[data-q="grease_trap.systems_count"] input'); await sys.fill('1'); await sys.dispatchEvent('change'); await sleep(400)
  await pick(p, 'grease_trap.photos', 4)
  const c = await card(p, 'grease_trap.photos')
  ok(!!c && attaches(S) === 4 && c.note === '4 photos attached' && c.button && c.multiple === true, 'phone390: guard, grease trap photos (no limit) take all four and keep the button', { attach: attaches(S), c })
  await browser.close()
}
// "Your name": the name the collector typed on this phone, else the task's one assignee, else empty
for (const [label, extra, saved, want] of [
  ['the assignee prefills an empty box', { assignee_name: 'Grecia [TEST]' }, null, 'Grecia [TEST]'],
  ['a name already typed on this phone wins', { assignee_name: 'Grecia [TEST]' }, 'Typed Name', 'Typed Name'],
  ['guard, no assignee: empty', {}, null, ''],
  ['guard, a non-text assignee is ignored', { assignee_name: 42 }, null, ''],
]) {
  const { browser, context, page: p } = await setup({ mobile: true, file: FILE, load: withTree(extra) })
  if (saved) await context.addInitScript(([k, v]) => { try { if (!sessionStorage.getItem('seeded')) { localStorage.setItem(k, v); sessionStorage.setItem('seeded', '1') } } catch {} }, [WHO, saved])
  await open(p)
  const v = await p.locator('#who').inputValue()
  ok(v === want, `phone390: ${label} ("${want}")`, v)
  await browser.close()
}
{ // the prefilled name is what the form sends
  const { browser, page: p, S } = await setup({ mobile: true, file: FILE, load: withTree({ assignee_name: 'Grecia [TEST]' }) })
  await open(p)
  await p.locator('#send').click(); await sleep(500)
  await p.locator('button', { hasText: /^Submit anyway$/ }).first().click({ timeout: 4000 }).catch(() => {}); await sleep(1200)
  ok(S.submits.length === 1 && S.submits[0].collector === 'Grecia [TEST]', 'phone390: Submit sends the prefilled name as the collector', S.submits.map((s) => s.collector))
  await browser.close()
}
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exitCode = 1
