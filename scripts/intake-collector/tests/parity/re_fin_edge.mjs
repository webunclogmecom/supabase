// Side probe for the focusin scroll added in the final build: press a control whose bottom sits just above
// the sticky bar (inside the 12 px band), near its top or bottom edge (negative yIn = from the bottom). focusin scrolls the page during the
// press; does the click still land on that control?  node re_fin_edge.mjs [file]
import { setup, open, draft, sleep } from './h.mjs';
const file = process.argv[2] || 'new.html';
const TG = [['access_entry.alarm=yes', (d) => d['access_entry.alarm'] === 'yes'], ['access_entry.gate=no', (d) => d['access_entry.gate'] === 'no'],
  ['access_hours.schedule:wed', (d) => !!(d['access_hours.schedule'] || {}).wed], ['grease_trap.systems_count:+', (d) => d['grease_trap.systems_count'] === 1]];
for (const [w, h, mobile] of [[1280, 900, false], [390, 844, true]]) {
  const { browser, page, context } = await setup({ file, mobile, ctx: { viewport: { width: w, height: h } } });
  const cdp = mobile ? await context.newCDPSession(page) : null; await open(page);
  for (const [gapFromBar, yIn] of [[4, 3], [4, -3], [4, -8], [8, -3], [11, -2], [20, -3]]) for (const [f, chk] of TG) {
    await page.evaluate(() => localStorage.clear()); await page.reload(); await page.waitForSelector('[data-q="access_entry.gate"]'); await sleep(150);
    if (await page.evaluate(() => Object.keys(A).length)) throw new Error('state not reset');
    const p = await page.evaluate(([f, gap, yIn]) => {
      const t = [...document.querySelectorAll('[data-f]')].find((e) => e.getAttribute('data-f') === f), ft = document.getElementById('foot');
      scrollTo(0, 0); scrollBy(0, t.getBoundingClientRect().bottom - (ft.getBoundingClientRect().top - gap));
      const r = t.getBoundingClientRect(); return { x: r.left + r.width / 2, y: yIn >= 0 ? r.top + yIn : r.bottom + yIn, sy: scrollY };
    }, [f, gapFromBar, yIn]);
    if (mobile) { await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: p.x, y: p.y }] }); await sleep(90); await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] }); }
    else { await page.mouse.move(p.x, p.y); await page.mouse.down(); await sleep(90); await page.mouse.up(); }
    await sleep(600);
    const d = await page.evaluate(() => JSON.parse(JSON.stringify(A)));
    const sy = await page.evaluate(() => Math.round(scrollY));
    console.log(`${chk(d) ? 'PASS' : 'FAIL'} [${file}] ${w}x${h} ${f} bottom ${gapFromBar}px above bar, pressed ${yIn >= 0 ? yIn + "px below its top" : -yIn + "px above its bottom"}; scrolled ${sy - p.sy}px; draft=${JSON.stringify(d)}`);
  }
  await browser.close();
}
