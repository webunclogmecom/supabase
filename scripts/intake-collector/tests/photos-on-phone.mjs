// photos-on-phone.mjs : the collector form keeps photos on the phone until Submit (Trello #220, Fred 2026-11-17: "The store
// photo locally first on the device and for that to be saved like with cookies or stuff in the phone, and if they try to
// submit the form it shows an error like with the internet issue and the form stays with the data because there was an
// error"). Local only: the parity harness serves the built form at its real URL and fakes intake-submit; nothing reaches
// the database. It submits only to the fake.
//   node scripts/intake-collector/tests/photos-on-phone.mjs
//   INTAKE_HTML=<file>  serve another build. Control: the build before #220 (git show <commit>^:scripts/intake-collector/intake.html)
//                       must FAIL the [new] checks; the live bytes after the publish must PASS.
import fs from 'node:fs'
import { pathToFileURL } from 'node:url'
const { setup, open, LOAD, PNG, sleep } = await import(process.env.PARITY_H || './parity/h.mjs')
const FILE = pathToFileURL(process.env.INTAKE_HTML || new URL('../intake.html', import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1')).href
const AP = 'access_entry.access_photos'
const NOCONN = 'No connection. Try again later.'
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${v === undefined ? '' : ' :: ' + JSON.stringify(v).slice(0, 300)}`) }
const load = () => { const l = JSON.parse(JSON.stringify(LOAD)); delete l.form.photo_note_required; return l }
const img = (n) => ({ name: n + '.png', mimeType: 'image/png', buffer: PNG })
const count = (S, op) => S.ops.filter((o) => o === op).length
const card = (p) => p.evaluate((key) => {
  const q = document.querySelector(`[data-q="${key}"]`); if (!q) return null
  return { tiles: q.querySelectorAll('.ph .pi .t:not(.send)').length, imgs: [...q.querySelectorAll('.ph .t img')].filter((i) => i.complete && i.naturalWidth > 0).length,
    states: [...q.querySelectorAll('.pi .st')].map((e) => e.textContent), notes: [...q.querySelectorAll('.note')].map((e) => e.textContent) }
}, AP)
const idbCount = (p) => p.evaluate(() => new Promise((res) => { try { const rq = indexedDB.open('unclogme-intake', 1); rq.onupgradeneeded = () => rq.result.createObjectStore('photos'); rq.onsuccess = () => { try { const t = rq.result.transaction('photos', 'readonly').objectStore('photos').count(); t.onsuccess = () => { res(t.result); rq.result.close() }; t.onerror = () => res(-1) } catch (e) { res(-2) } }; rq.onerror = () => res(-3) } catch (e) { res(-4) } }))
const idle = (p) => p.waitForFunction(() => typeof busy !== 'undefined' && busy === 0 && !document.querySelector('.ph .t.send'), null, { timeout: 15000 }).catch(() => {})
async function prep(p) {
  await open(p)
  await p.locator('[data-q="access_entry.access_point"]').getByRole('button', { name: 'Back door', exact: true }).click().catch(() => {})
  await p.fill('#who', '[TEST] photos on phone').catch(() => {})
}
async function pick(p, names) { await p.locator(`[data-q="${AP}"] input[type=file]:not([capture])`).setInputFiles(names.map(img)); await sleep(300); await idle(p) }
async function submit(p) {
  await p.click('#send'); await sleep(300)
  const anyway = p.getByRole('button', { name: 'Submit anyway' }); if (await anyway.count()) await anyway.click()
  await p.waitForFunction(() => !SENDING, null, { timeout: 20000 }).catch(() => {}); await sleep(300)
}
const msg = (p) => p.evaluate(() => [...document.querySelectorAll('.err span')].map((e) => e.textContent))

// 1-4: pick, reload, a submit with no signal, a submit with signal
{
  const { browser, page: p, S } = await setup({ mobile: true, file: FILE, load: load() })
  try {
    await prep(p)
    await pick(p, ['a', 'b'])
    let c = await card(p)
    ok(c.tiles === 2 && count(S, 'upload') === 0 && count(S, 'attach') === 0, '[new] two photos picked: shown, and nothing sent', { c, ops: S.ops })
    ok(c.states.length === 2 && c.states.every((t) => t === 'Saved on this phone'), '[new] each card says "Saved on this phone"', c.states)
    ok(c.notes.includes('2 photos attached'), 'the count under the question is unchanged ("2 photos attached")', c.notes)
    ok(await idbCount(p) === 2, '[new] both photos are stored on the phone (IndexedDB)', await idbCount(p))
    await p.reload(); await p.waitForSelector(`[data-q="${AP}"]`); await sleep(1200)
    c = await card(p)
    ok(c.tiles === 2 && c.imgs === 2 && c.states.every((t) => t === 'Saved on this phone'), '[new] after a reload both photos are still there, with their pictures', c)
    S.upload = 'abort'
    await submit(p)
    c = await card(p)
    const m1 = await msg(p)
    ok(m1.includes(NOCONN), '[new] no signal: the error says nothing is lost', m1)
    ok(c.tiles === 2 && S.submits.length === 0 && await idbCount(p) === 2, '[new] no signal: the form keeps both photos and nothing was submitted', { c, submits: S.submits.length })
    ok((await p.evaluate(() => document.getElementById('send').disabled)) === false && (await p.textContent('#send')) === 'Submit', 'no signal: Submit is ready again', await p.textContent('#send'))
    S.upload = 'ok'; S.ops.length = 0
    await submit(p)
    const done = await p.evaluate(() => !!document.querySelector('.big h2') && document.querySelector('.big h2').textContent)
    ok(done === 'Thank you' && count(S, 'upload') === 2 && count(S, 'attach') === 2 && S.submits.length === 1, '[new] with signal: two photos sent, then the form', { done, ops: S.ops, submits: S.submits.length })
    const sent = S.submits[0] ? S.submits[0].answers[AP] : null
    ok(Array.isArray(sent) && sent.length === 2 && sent.every((x) => typeof x === 'string' && /^999\/p\d+\.jpg$/.test(x)), 'the answer carries only the paths the server handed out', sent)
    ok(await idbCount(p) === 0 && (await p.evaluate(() => localStorage.getItem('intake-draft-TESTTOKEN123'))) === null, '[new] after the submit the phone holds no photo and no draft', await idbCount(p))
  } catch (e) { ok(false, 'run 1 threw', String(e)) } finally { await browser.close() }
}

// 5: a submit that stops after the first photo, then resumes: nothing is sent twice
{
  const { browser, context, page: p, S } = await setup({ mobile: true, file: FILE, load: load() })
  try {
    await prep(p)
    await pick(p, ['a', 'b'])
    let attaches = 0
    await context.route('https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/intake-submit', async (route) => {
      const b = JSON.parse(route.request().postData() || '{}')
      if (b.op === 'attach' && ++attaches === 2) return route.abort()
      return route.fallback()
    })
    await submit(p)
    const c = await card(p)
    ok(c.states.join('|') === 'Sent|Saved on this phone' && S.submits.length === 0, '[new] stopped after one photo: the first says "Sent", the second waits on the phone', { states: c.states, ops: S.ops })
    S.ops.length = 0
    await submit(p)
    ok(count(S, 'upload') === 0 && count(S, 'attach') === 1 && S.submits.length === 1, '[new] the retry reuses the second photo\'s slot: no new upload, one attach, then the form', { ops: S.ops, submits: S.submits.length })
  } catch (e) { ok(false, 'run 2 threw', String(e)) } finally { await browser.close() }
}

// 6: remove a photo still on the phone: no call, gone from the phone
{
  const { browser, page: p, S } = await setup({ mobile: true, file: FILE, load: load() })
  try {
    await prep(p)
    await pick(p, ['a', 'b'])
    await p.locator(`[data-f="${AP}:rm:0"]`).click(); await sleep(150)
    await p.locator(`[data-f="${AP}:rmyes:0"]`).click(); await sleep(400)
    const c = await card(p)
    ok(c.tiles === 1 && count(S, 'remove') === 0 && await idbCount(p) === 1, '[new] Remove on a photo still on the phone: one left, no call, one stored', { c, ops: S.ops, idb: await idbCount(p) })
  } catch (e) { ok(false, 'run 3 threw', String(e)) } finally { await browser.close() }
}

// 7: a phone that cannot keep photos sends each at once, as before, and says so
{
  const { browser, context, page: p, S } = await setup({ mobile: true, file: FILE, load: load() })
  try {
    await context.addInitScript(() => { try { Object.defineProperty(window, 'indexedDB', { value: undefined, configurable: true }) } catch (e) {} })
    await prep(p)
    await pick(p, ['a'])
    await sleep(600); await idle(p)
    const c = await card(p)
    ok(c.tiles === 1 && count(S, 'upload') === 1 && count(S, 'attach') === 1, 'no storage on the phone: the photo is sent at once', { c, ops: S.ops })
    ok(c.notes.includes('This phone cannot keep photos, so each one is sent right away.'), '[new] and the form says so', c.notes)
  } catch (e) { ok(false, 'run 4 threw', String(e)) } finally { await browser.close() }
}

// 8: photos a stopped Submit already sent: Remove goes to the server with THAT path (moved here from form-v3.mjs R2, R4, R6)
{
  const { browser, context, page: p, S } = await setup({ mobile: true, file: FILE, load: load() })
  try {
    const R = { paths: [], fail: false, delay: 0 }
    await context.route('https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/intake-submit', async (route) => {
      const b = JSON.parse(route.request().postData() || '{}'); if (b.op !== 'remove') return route.fallback()
      S.ops.push('remove'); R.paths.push(b.path); if (R.delay) await sleep(R.delay)
      if (R.fail) return route.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ ok: false, message: 'That photo does not belong to this form.' }) })
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, removed: true }) })
    })
    await prep(p)
    await pick(p, ['a', 'b', 'c'])
    S.submit = 'abort'
    await submit(p)
    let c = await card(p)
    ok(c.states.every((t) => t === 'Sent') && c.tiles === 3 && S.submits.length === 1, 'a Submit that stops after the photos: all three say "Sent", the form keeps them', { states: c.states })
    const paths = await p.evaluate((k) => (JSON.parse(localStorage.getItem('intake-draft-TESTTOKEN123') || '{}')[k] || []).map((x) => x.path), AP)
    await p.locator(`[data-f="${AP}:rm:1"]`).click(); await sleep(120); await p.locator(`[data-f="${AP}:rmyes:1"]`).click(); await sleep(400); await idle(p)
    c = await card(p)
    ok(R.paths.length === 1 && R.paths[0] === paths[1] && c.tiles === 2, 'R2 Remove on a sent photo sends op remove with THAT photo\'s path', { removed: R.paths, paths, tiles: c.tiles })
    R.fail = true
    await p.locator(`[data-f="${AP}:rm:0"]`).click(); await sleep(120); await p.locator(`[data-f="${AP}:rmyes:0"]`).click(); await sleep(400); await idle(p)
    c = await card(p); const errs = await p.evaluate((k) => [...document.querySelectorAll(`[data-q="${k}"] .err span`)].map((e) => e.textContent), AP)
    ok(c.tiles === 2 && errs.includes('That photo does not belong to this form.'), 'R4 a refused Remove keeps the sent photo and shows the server\'s sentence', { tiles: c.tiles, errs })
    R.fail = false; R.delay = 900
    await p.locator(`[data-f="${AP}:rm:0"]`).click(); await sleep(120); await p.locator(`[data-f="${AP}:rmyes:0"]`).click(); await sleep(250)
    const sb = await p.evaluate(() => { const b = document.getElementById('send'); return { dis: b.disabled, txt: b.textContent } })
    await idle(p); await sleep(900)
    ok(sb.dis && sb.txt === 'Removing...', 'R6 while a Remove of a sent photo is on its way, Submit is disabled and reads "Removing..."', sb)
  } catch (e) { ok(false, 'run 5 threw', String(e)) } finally { await browser.close() }
}

console.log(`\nphotos-on-phone: ${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
