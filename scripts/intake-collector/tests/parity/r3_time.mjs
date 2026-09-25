// Desktop keyboard entry into an hours time box: does the rebuild after each segment change garble the time?
// node r3_time.mjs [file=new.html]  (r3_time_ctl.html = control where a time change does not rebuild)
import { setup, open, draft, sleep } from './h.mjs';
const file = process.argv[2] || 'new.html';
const { browser, page, S } = await setup({ file });
await open(page);
const SEED = { 'access_hours.schedule': { mon: { open: '08:00', close: '17:00' } } };
async function fresh() {
  await page.evaluate((s) => { localStorage.clear(); localStorage.setItem('intake-draft-TESTTOKEN123', JSON.stringify(s)); }, SEED);
  await page.reload(); await open(page); await sleep(100);
  await page.evaluate(() => { window.__r = 0; new MutationObserver(() => window.__r++).observe(document.getElementById('qs'), { childList: true }); });
}
const O = '[data-f="access_hours.schedule:mon:o"]';
async function seg(part) { // click the hour (left) or minute (middle) segment of the box
  const p = await page.locator(O).evaluate((e, part) => { e.scrollIntoView({ block: 'center' }); const r = e.getBoundingClientRect(); return { x: r.left + (part === 'h' ? 20 : 44), y: r.top + r.height / 2 }; }, part);
  await page.mouse.click(p.x, p.y);
}
for (const [name, part, keys, want] of [
  ['type 0930AM, 0ms/key', 'h', '0930AM', '09:30'],
  ['type 0930AM, 150ms/key', 'h', '0930AM', '09:30'],
  ['type 1045PM, 300ms/key', 'h', '1045PM', '22:45'],
  ['minutes ArrowUp x3', 'm', ['ArrowUp', 'ArrowUp', 'ArrowUp'], '08:03'],
  ['hour ArrowUp then Tab to minutes, type 15', 'h', ['ArrowUp', 'Tab', '1', '5'], '09:15'],
]) {
  await fresh(); await seg(part);
  const delay = /150ms/.test(name) ? 150 : /300ms/.test(name) ? 300 : 120;
  if (typeof keys === 'string') await page.keyboard.type(keys, { delay: /0ms\/key/.test(name) && !/150|300/.test(name) ? 0 : delay });
  else for (const k of keys) { await page.keyboard.press(k); await sleep(delay); }
  await sleep(400);
  const got = (await draft(page))['access_hours.schedule'].mon.open;
  const shown = await page.locator(O).inputValue();
  const r = await page.evaluate(() => window.__r);
  const act = await page.evaluate(() => document.activeElement.getAttribute('data-f') || document.activeElement.tagName);
  console.log(`${got === want ? 'PASS' : 'FAIL'} [${file}] ${name}: want ${want} stored ${got} shown ${shown} rebuilds=${r} focus=${act}`);
}
console.log('pageerrors', S.errors, 'aborted', S.aborted.length);
await browser.close();
