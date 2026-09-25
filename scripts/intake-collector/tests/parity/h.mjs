// Shared harness: serves new.html at the real URL, fakes intake-submit, aborts everything else.
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
const req = createRequire(import.meta.url);
const { chromium } = req(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core');
const DIR = new URL('.', import.meta.url);
export const PAGE = 'https://planner.unclogme.app/intake.html#code=TESTTOKEN123';
export const EP = 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/intake-submit';
export const KEY = 'intake-draft-TESTTOKEN123';
export const LOAD = JSON.parse(readFileSync(new URL('load.json', DIR), 'utf8'));
export const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function setup(o = {}) {
  const html = readFileSync(new URL(o.file || 'new.html', DIR), 'utf8');
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true });
  const mobile = o.mobile;
  const context = await browser.newContext(mobile
    ? { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 3, ...(o.ctx || {}) }
    : { viewport: { width: 1280, height: 900 }, ...(o.ctx || {}) });
  const S = { errors: [], submits: [], ops: [], aborted: [], n: 0,
    load: o.load || 'ok', upload: o.upload || 'ok', submit: o.submit || 'ok', uploadDelay: o.uploadDelay || 0, putDelay: o.putDelay || 0 };
  await context.route('**/*', async (route) => {
    const r = route.request(), u = r.url();
    if (u.startsWith('https://planner.unclogme.app/intake.html')) return route.fulfill({ status: 200, contentType: 'text/html', body: html });
    if (u === EP) {
      if (r.method() !== 'POST') return route.fulfill({ status: 204 });
      const b = JSON.parse(r.postData() || '{}'); S.ops.push(b.op);
      const J = (x, st = 200) => route.fulfill({ status: st, contentType: 'application/json', body: JSON.stringify(x) });
      if (b.op === 'load') {
        if (S.load === 'abort') return route.abort();
        if (typeof S.load === 'object') return J(S.load);
        return J(LOAD);
      }
      if (b.op === 'upload') {
        if (S.uploadDelay) await sleep(S.uploadDelay);
        if (S.upload === 'abort') return route.abort();
        if (S.upload === 'html') return route.fulfill({ status: 502, contentType: 'text/html', body: '<html>Bad gateway</html>' });
        if (typeof S.upload === 'object') return J(S.upload);
        S.n++; return J({ ok: true, signed_url: 'https://upload.invalid/put', path: '999/p' + S.n + '.jpg' });
      }
      if (b.op === 'attach') return J({ ok: true });
      if (b.op === 'submit') {
        S.submits.push(b);
        if (S.submit === 'abort') return route.abort();
        if (typeof S.submit === 'object') return J(S.submit);
        return J({ ok: true, status: 'Incomplete' });
      }
      return J({ ok: false, message: 'unknown op' });
    }
    if (u.startsWith('https://upload.invalid/')) { if (S.putDelay) await sleep(S.putDelay); return route.fulfill({ status: 200, body: '' }); }
    S.aborted.push(u); return route.abort();
  });
  const page = await context.newPage();
  page.on('console', (m) => { if (m.type() === 'error') S.errors.push(m.text()); });
  page.on('pageerror', (e) => S.errors.push('pageerror: ' + e.message));
  return { browser, context, page, S };
}
export async function open(page) {
  await page.goto(PAGE);
  await page.waitForSelector('[data-q="access_entry.gate"]');
}
export const act = (page) => page.evaluate(() => { const a = document.activeElement; return a ? (a.getAttribute('data-f') || a.id || a.tagName) : null; });
export const draft = (page, k = 'intake-draft-TESTTOKEN123') => page.evaluate((k) => JSON.parse(localStorage.getItem(k) || 'null'), k);
// A human mouse click: move, press, hold, release (the event loop runs between press and release).
export async function humanClick(page, loc, hold = 90) {
  await loc.evaluate((e) => e.scrollIntoView({ block: 'center' })); await sleep(50);
  const b = await loc.boundingBox();
  const x = b.x + b.width / 2, y = b.y + b.height / 2;
  await page.mouse.move(x, y); await page.mouse.down(); await sleep(hold); await page.mouse.up();
}
export async function tapAt(page, loc) {
  await loc.evaluate((e) => e.scrollIntoView({ block: 'center' })); await sleep(50);
  const b = await loc.boundingBox();
  await page.touchscreen.tap(b.x + b.width / 2, b.y + b.height / 2);
}
