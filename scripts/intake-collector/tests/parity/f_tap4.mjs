// Repro hunt: the queued rebuild flushes between a touch's pointerup and its tap-click. If that rebuild
// moves the layout (an error box appears above), which control does the tap answer?
// node f_tap2.mjs [new.html|old.html]
import { setup, sleep, PNG, PAGE } from './h.mjs';
const open = async (p) => { await p.goto(PAGE); await p.waitForFunction(() => document.querySelectorAll('.q').length > 3); };
const file = process.argv[2] || 'new.html';
const log = (k, v) => console.log(file + ' ' + k + ':', JSON.stringify(v));
for (const mode of ['touch', 'mouse']) {
  const { browser, page, S, context } = await setup({ mobile: mode === 'touch', file, upload: 'abort', uploadDelay: 400 }); await open(page);
  await page.evaluate(() => {
    window.__ev = [];
    ['pointerdown', 'pointerup', 'click'].forEach((t) => document.addEventListener(t, (e) => {
      const f = e.target.closest && e.target.closest('[data-f]'); window.__ev.push(t + ':' + (f ? f.getAttribute('data-f') : (e.target.textContent || '').trim().slice(0, 30) || e.target.tagName)); }, true));
    new MutationObserver(() => window.__ev.push('DOM')).observe(document.body, { childList: true, subtree: false });
  });
  const inp = file === 'new.html' ? page.locator('[data-q="access_entry.access_photos"] input[type=file]') : page.locator('input[type=file]').nth(0);
  await inp.setInputFiles({ name: 'a.png', mimeType: 'image/png', buffer: PNG });
  await sleep(0);
  const tgt = file === 'new.html' ? page.locator('[data-f="access_entry.how_access=Key"]') : page.locator('.q', { hasText: 'Is there an alarm?' }).first().getByRole('button', { name: 'No', exact: true });
  await tgt.evaluate((e) => e.scrollIntoView({ block: 'center' })); await sleep(100);
  const b = await tgt.boundingBox(); const x = b.x + b.width / 2, y = b.y + b.height / 2;
  await page.evaluate(() => { window.__ev = []; }); await page.waitForFunction(() => busy === 1); await sleep(Number(process.env.PRE||0));
  if (mode === 'touch') {
    const cdp = await context.newCDPSession(page);
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] });
    await sleep(Number(process.env.HOLD||700));
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  } else { await page.mouse.move(x, y); await page.mouse.down(); await sleep(Number(process.env.HOLD||700)); await page.mouse.up(); }
  await sleep(500);
  log(mode + ' held how_access=Key while a photo upload failed', await page.evaluate(() => ({ ev: window.__ev.join(' | '), A: JSON.stringify(A),
    err: [...document.querySelectorAll('.err span, .err')].map((e) => e.textContent).slice(0, 1) })));
  await browser.close();
}
