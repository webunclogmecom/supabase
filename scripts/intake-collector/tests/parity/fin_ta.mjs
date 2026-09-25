// FINAL: Tab onto a TEXTAREA sitting under the sticky bar. Does it scroll clear (scroll-margin-bottom from --fh)?
// Compare a single-line input and a button placed the same way. Wait 800ms (no smooth-scroll excuse).
// node fin_ta.mjs [file=new.html]
import { setup, open, sleep } from './h.mjs';
const file = process.argv[2] || 'new.html';
const CASES = [
  ['textarea obstacles', 'textarea[data-f="access_entry.obstacles"]'],
  ['single-line lock_box_code', 'input[data-f="access_entry.lock_box_code"]'],
  ['number cleanouts', 'input[data-f="grease_trap.cleanouts_count"]'],
  ['button alarm=yes', '[data-f="access_entry.alarm=yes"]'],
];
for (const [vn, vo] of [['390 phone', { mobile: true }], ['1280x900', {}]]) for (const cfOpen of [false, true]) {
  const { browser, page, S } = await setup({ file, ...vo });
  await open(page);
  await page.evaluate(() => localStorage.setItem('intake-draft-TESTTOKEN123', JSON.stringify({ 'access_entry.how_access': 'Lock box' })));
  await page.reload(); await open(page); await sleep(150);
  if (cfOpen) { await page.fill('#who', 'Test Collector'); await page.click('#send'); await sleep(200); }
  for (const [name, sel] of CASES) {
    // put the target 20px below the bar top, focus the control BEFORE it without scrolling, then press Tab
    const r0 = await page.evaluate((sel) => {
      document.activeElement && document.activeElement.blur();
      const t = document.querySelector(sel), f = document.getElementById('foot');
      const all = [...document.querySelectorAll('#main button:not([tabindex="-1"]),#main input:not([tabindex="-1"]):not(.hide),#main textarea')].filter((e) => e.offsetParent);
      const prev = all[all.indexOf(t) - 1];
      scrollBy(0, t.getBoundingClientRect().top - (f.getBoundingClientRect().top + 20));
      prev.focus({ preventScroll: true });
      return { prev: prev.getAttribute('data-f') || prev.id, fh: getComputedStyle(document.documentElement).getPropertyValue('--fh'), smb: getComputedStyle(t).scrollMarginBottom, top0: Math.round(t.getBoundingClientRect().top), ft: Math.round(f.getBoundingClientRect().top) };
    }, sel);
    await page.keyboard.press('Tab'); await sleep(800);
    const r1 = await page.evaluate((sel) => {
      const t = document.querySelector(sel), a = document.activeElement, f = document.getElementById('foot');
      const r = t.getBoundingClientRect(), fr = f.getBoundingClientRect();
      const h = document.elementFromPoint(r.left + r.width / 2, Math.min(innerHeight - 1, r.top + r.height / 2));
      return { focused: a === t, top: Math.round(r.top), bot: Math.round(r.bottom), ft: Math.round(fr.top), vh: innerHeight, centreHit: h === t ? 'self' : h && h.closest('#foot') ? 'FOOTER' : h && h.tagName, clear: r.bottom <= fr.top };
    }, sel);
    console.log(`${r1.clear ? 'CLEAR ' : 'HIDDEN'} [${file}] ${vn}${cfOpen ? ' +confirm' : ''} | ${name} | prev=${r0.prev} --fh=${r0.fh} smb=${r0.smb} top ${r0.top0}->${r1.top} bottom ${r1.bot} barTop ${r1.ft} vh ${r1.vh} centre=${r1.centreHit} focused=${r1.focused}`);
    if (!r1.clear && name.startsWith('textarea')) await page.screenshot({ path: `fin/ta_hidden_${vn.replace(/\W+/g, '')}${cfOpen ? '_cf' : ''}.png` });
  }
  if (S.errors.length || S.aborted.length) console.log('  errors', S.errors, 'aborted', S.aborted);
  await browser.close();
}
