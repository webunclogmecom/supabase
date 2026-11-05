// hints-live.mjs [outdir] : the (i) hints on the gate code and the hours, question list version 7, on the LIVE collector form and the
// REAL server (2026-11-05, Serena: "specify for the gate code or the access hours that they needs to speak with the GENERAL MANAGER
// or THE PERSON IN CHARGE"; Fred: behind the (i) button). Makes its own [TEST] form on the test property 1164, opens it at phone size,
// taps each (i) open and closed, asserts the words, the closed start and that the page goes back to its height, then removes the form.
// Nothing is submitted. outdir, when given, gets one picture per open hint. Exit 1 on any failure.
//   node scripts/intake-collector/tests/hints-live.mjs [outdir]
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { execFileSync } from 'node:child_process'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()

const OUT = process.argv[2]
if (OUT) fs.mkdirSync(OUT, { recursive: true })
const GATE = 'Ask the general manager or the person in charge.'
const HOURS = 'The hours our truck can come, not when the business is open. Ask the general manager or the person in charge.'
const [made] = await sql(`INSERT INTO public.property_intakes (property_id, form_snapshot, requested, requested_by)
  SELECT 1164, s, to_jsonb(public.fn_intake_normalise_requested(s, (SELECT array_agg(question_key) FROM client.v_intake_questions))), '[TEST] collector page check (hints-live)'
    FROM (SELECT public.fn_intake_form_current() s) x RETURNING id, token, form_snapshot ->> 'version' AS v`)
if (!made || !made.token) throw new Error('could not make the test form')
const TOKEN = made.token
let pass = 0, fail = 0
const ok = (c, name, v) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}${c || v === undefined ? '' : ' :: ' + String(JSON.stringify(v)).replaceAll(TOKEN, '<token>').slice(0, 400)}`) }
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
try {
  ok(made.v === '7', 'a new form carries question list version 7', made.v)
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true })
  const page = await ctx.newPage()
  const errors = []; page.on('pageerror', (e) => errors.push(String(e)))
  await page.goto('https://planner.unclogme.app/intake.html#code=' + TOKEN)
  await page.waitForSelector('[data-q="access_hours.schedule"]', { timeout: 30000 })
  await page.waitForTimeout(800)
  const check = async (key, text, shot) => {
    const q = page.locator(`[data-q="${key}"]`), ib = q.locator('.ib'), hint = q.locator('.qi')
    await q.scrollIntoViewIfNeeded()
    const h0 = await q.evaluate((e) => e.getBoundingClientRect().height)
    ok(await ib.isVisible(), `${key}: the (i) shows`)
    ok(!(await hint.isVisible()), `${key}: the hint starts closed`)
    await ib.tap(); await page.waitForTimeout(200)
    ok(await hint.isVisible() && (await hint.textContent()).trim() === text, `${key}: a tap opens the hint, word for word`, await hint.textContent())
    ok((await ib.getAttribute('aria-expanded')) === 'true', `${key}: the (i) reads as open`)
    if (OUT) await q.screenshot({ path: path.join(OUT, shot) })
    const box = await hint.boundingBox()
    ok(box && box.x >= 0 && box.x + box.width <= 390, `${key}: the hint fits the phone`, box)
    await ib.tap(); await page.waitForTimeout(200)
    ok(!(await hint.isVisible()), `${key}: a second tap closes it`)
    const h1 = await q.evaluate((e) => e.getBoundingClientRect().height)
    ok(h1 === h0, `${key}: the question goes back to its height`, [h0, h1])
  }
  await check('access_hours.schedule', HOURS, 'hint_hours.png')
  // the gate code only shows after Yes
  const gate = page.locator('[data-q="access_entry.gate"]')
  ok(!(await page.locator('[data-q="access_entry.gate_code"]').isVisible().catch(() => false)), 'the gate code question is hidden until there is a gate')
  await gate.scrollIntoViewIfNeeded()
  await page.locator('[data-f="access_entry.gate=yes"]').first().tap(); await page.waitForTimeout(300)
  await check('access_entry.gate_code', GATE, 'hint_gate.png')
  ok((await page.locator('.ib').count()) >= 2, 'other hints still draw', await page.locator('.ib').count())
  ok(errors.length === 0, 'no page errors', errors)
} finally {
  await browser.close()
  const clean = new URL('cleanup.mjs', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')
  const left = execFileSync(process.execPath, [decodeURI(clean), String(made.id)], { encoding: 'utf8' })
  const [gone] = await sql(`select count(*)::int n from public.property_intakes where id = ${Number(made.id)}`)
  ok(gone.n === 0, 'the test form is removed', left.slice(-200))
}
console.log(`${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
