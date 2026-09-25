// FINAL: controls in #main WITHOUT data-f (the OK button of an in-question error box: upload error, GPS error)
// get no scroll-margin-bottom. Tab onto one sitting under the bar: does it scroll clear?
// Positive control in the same run: a data-f button placed the same way.
import { setup, open, sleep } from './h.mjs';
const file = process.argv[2] || 'new.html';
for (const [vn, vo] of [['390 phone', { mobile: true }], ['1280x900', {}]]) {
  const { browser, page, S } = await setup({ file, ...vo });
  await open(page); await sleep(150);
  await page.evaluate(() => { ERR['access_entry.access_photos'] = 'The photo did not upload. Check your signal and try again.'; GEO['site_map.truck_parking'] = { err: 'Could not find this spot. Step outside if you can, then tap again.' }; render(); });
  const targets = await page.evaluate(() => [...document.querySelectorAll('#main .q .err button')].map((b) => b.closest('[data-q]').getAttribute('data-q')));
  for (const q of [...targets, 'CONTROL:access_entry.alarm=yes']) {
    const r0 = await page.evaluate((q) => {
      document.activeElement && document.activeElement.blur();
      const t = q.startsWith('CONTROL:') ? document.querySelector('[data-f="' + q.slice(8) + '"]') : document.querySelector('[data-q="' + q + '"] .err button');
      const f = document.getElementById('foot');
      const all = [...document.querySelectorAll('#main button,#main input:not(.hide),#main textarea')].filter((e) => e.offsetParent && e.tabIndex >= 0);
      const prev = all[all.indexOf(t) - 1];
      if (!prev) return { noPrev: true };
      window.__t = t;
      scrollBy(0, t.getBoundingClientRect().top - (f.getBoundingClientRect().top + 10));
      prev.focus({ preventScroll: true });
      return { prev: prev.getAttribute('data-f') || prev.id || prev.textContent, smb: getComputedStyle(t).scrollMarginBottom, top0: Math.round(t.getBoundingClientRect().top) };
    }, q);
    if (r0.noPrev) { console.log(vn, q, 'no previous control (first on page), skipped'); continue; }
    await page.keyboard.press('Tab'); await sleep(600);
    const r1 = await page.evaluate(() => {
      const t = window.__t, f = document.getElementById('foot'), r = t.getBoundingClientRect(), fr = f.getBoundingClientRect();
      const h = document.elementFromPoint(r.left + r.width / 2, Math.min(innerHeight - 1, r.top + r.height / 2));
      return { focused: document.activeElement === t, top: Math.round(r.top), bot: Math.round(r.bottom), ft: Math.round(fr.top), centre: h === t ? 'self' : h && h.closest('#foot') ? 'FOOTER' : h && h.tagName, clear: r.bottom <= fr.top };
    });
    console.log(`${r1.clear ? 'CLEAR ' : 'HIDDEN'} ${vn} | ${q.startsWith('CONTROL') ? q : 'OK button of error box in ' + q} | prev=${r0.prev} smb=${r0.smb} top ${r0.top0}->${r1.top} bottom ${r1.bot} barTop ${r1.ft} centre=${r1.centre} focused=${r1.focused}`);
    if (!r1.clear) await page.screenshot({ path: `fin/ok_hidden_${vn.replace(/\W+/g, '')}_${q.replace(/\W+/g, '_')}.png` });
  }
  if (S.errors.length || S.aborted.length) console.log('  errors', S.errors, 'aborted', S.aborted);
  await browser.close();
}
