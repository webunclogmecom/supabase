// Fix re-check: focus fallback at a stepper limit / after "Every day", and what it does on a touch phone.
import { setup, open, sleep, act } from './h.mjs';
const log = (k, v) => console.log(k + ':', JSON.stringify(v));
const q = (k) => `[data-q="${k}"]`;
const info = (page) => page.evaluate(() => { const a = document.activeElement; const c = a && a.closest && a.closest('[data-q]');
  return { f: a && (a.getAttribute('data-f') || a.id || a.tagName), inQ: c && c.getAttribute('data-q'), tag: a && a.tagName + (a.type ? '/' + a.type : ''),
    footer: getComputedStyle(document.getElementById('foot')).position, fv: a && a.matches(':focus-visible') }; });
for (const mobile of [false, true]) {
  const tag = mobile ? '390 touch' : '1280 mouse';
  const { browser, page, S } = await setup({ mobile }); await open(page);
  const press = async (sel) => { const l = page.locator(sel); await l.scrollIntoViewIfNeeded(); if (mobile) await l.tap(); else await l.click(); await sleep(120); };
  // 1. "-" on an empty count answers 0 and disables "-"
  await press(q('grease_trap.cleanouts_count') + ' [aria-label="One less"]');
  log(tag + ' "-" on empty cleanouts_count', { v: await page.evaluate(() => A['grease_trap.cleanouts_count']), ...(await info(page)) });
  await page.evaluate(() => document.activeElement && document.activeElement.blur());
  // 2. "+" up to the maximum (manhole_count max 50)
  const mh = page.locator(q('grease_trap.manhole_count') + ' input'); await mh.fill('49'); await mh.press('Tab'); await sleep(100);
  await press(q('grease_trap.manhole_count') + ' [aria-label="One more"]');
  log(tag + ' "+" to max on manhole_count', { v: await page.evaluate(() => A['grease_trap.manhole_count']), ...(await info(page)) });
  // 3. "-" from 1 to 0 on a PARENT count (systems_count) -> follow-ups disappear
  await press(q('grease_trap.systems_count') + ' [aria-label="One more"]');
  await press(q('grease_trap.systems_count') + ' [aria-label="One less"]');
  log(tag + ' systems_count 1 -> 0 with "-"', { v: await page.evaluate(() => A['grease_trap.systems_count']), ...(await info(page)) });
  // 4. Every day
  await press(q('access_hours.schedule') + ' [data-f="access_hours.schedule:wed"]');
  await press(q('access_hours.schedule') + ' [data-f="access_hours.schedule:all"]');
  log(tag + ' Every day', { ...(await info(page)), days: await page.evaluate(() => Object.keys(A['access_hours.schedule'] || {}).length) });
  // 5. keyboard: Enter on "+" repeatedly past the max stays inside the question
  if (!mobile) {
    await mh.fill('48'); await mh.press('Tab'); await sleep(100); // focus now on "+"
    const f0 = await info(page);
    await page.keyboard.press('Enter'); await sleep(50); await page.keyboard.press('Enter'); await sleep(50); await page.keyboard.press('Enter'); await sleep(50);
    log(tag + ' keyboard Enter x3 on "+" from 48', { start: f0.f, v: await page.evaluate(() => A['grease_trap.manhole_count']), ...(await info(page)) });
    // 6. a choice option whose value contains a double quote: does focus stay on the pressed option?
  }
  log(tag + ' errors', S.errors); await browser.close();
}
{ // 6. option value with a double quote (authored options are free text)
  const L = JSON.parse((await import('node:fs')).readFileSync(new URL('load.json', import.meta.url), 'utf8'));
  L.form.sections.forEach((s) => s.questions.forEach((x) => { if (x.key === 'access_entry.where_outside') x.options = ['Front', '6" pipe by the curb', 'Other']; }));
  const { browser, page, S } = await setup({ load: L }); await open(page);
  await page.locator('[data-f="access_entry.equipment_where=Outside"]').click(); await sleep(100);
  await page.locator(q('access_entry.where_outside')).getByRole('button', { name: '6" pipe by the curb' }).click(); await sleep(100);
  log('1280 option with a quote', { v: await page.evaluate(() => A['access_entry.where_outside']), ...(await info(page)) });
  await page.keyboard.press('Tab'); await sleep(50);
  log('1280 ... then Tab', await info(page));
  await browser.close();
}
