// Final re-check, side probe: Tab / Shift+Tab out of a stepper's number box right after typing a value that
// flips the - or + button's disabled state (sync() runs on change, after focus has already moved).
import { setup, open, draft, sleep } from './h.mjs';
const file = process.argv[2] || 'new.html';
const where = (page) => page.evaluate(() => { const a = document.activeElement; return a ? (a.getAttribute('data-f') || a.id || a.tagName) + (a.disabled ? ' [disabled]' : '') : null; });
const R = {};
const { browser, page } = await setup({ file }); await open(page);
const box = page.locator('[data-f="grease_trap.manhole_count"]');
await box.click(); await page.keyboard.type('50'); await page.keyboard.press('Tab'); await sleep(200);
R['a) empty, type 50, Tab'] = { focus: await where(page), v: (await draft(page))['grease_trap.manhole_count'] };
await page.keyboard.press('Tab'); await sleep(100); R['a) ... next Tab'] = await where(page);
await box.click(); await page.keyboard.press('Control+A'); await page.keyboard.type('48'); await page.keyboard.press('Tab'); await sleep(200);
R['b) at 50 (+ disabled), type 48, Tab'] = { focus: await where(page), v: (await draft(page))['grease_trap.manhole_count'], plusDisabled: await page.locator('[data-f="grease_trap.manhole_count:+"]').isDisabled() };
const c = page.locator('[data-f="grease_trap.cleanouts_count"]');
await c.click(); await page.keyboard.type('0'); await page.keyboard.press('Shift+Tab'); await sleep(200);
R['c) empty, type 0, Shift+Tab'] = { focus: await where(page), v: (await draft(page))['grease_trap.cleanouts_count'] };
await page.keyboard.press('Shift+Tab'); await sleep(100); R['c) ... next Shift+Tab'] = await where(page);
console.log(file, JSON.stringify(R, null, 1));
await browser.close();
