// RECHECK (1): first click after typing into a show_if parent, real mouse presses at 1280 and touch at 390.
// node r3_click.mjs [file=new.html]   (file=r3_mut.html is the positive control: afterPress made synchronous)
// Uses h.mjs: page URL served from the local file, intake-submit mocked, everything else aborted.
import { setup, open, draft, sleep } from './h.mjs';
const file = process.argv[2] || 'new.html';
const out = { pass: 0, fail: 0, rows: [] };

async function center(page, sel, where = 'center') {
  const loc = page.locator(sel).first();
  await loc.evaluate((e, w) => e.scrollIntoView({ block: w }), where); await sleep(60);
  const b = await loc.boundingBox(); return { x: b.x + b.width / 2, y: b.y + b.height / 2 };
}
async function mpress(page, sel, hold) { const p = await center(page, sel); await page.mouse.move(p.x, p.y); await page.mouse.down(); await sleep(hold); await page.mouse.up(); }
async function ttap(page, cdp, sel, hold) {
  const p = await center(page, sel);
  if (!hold) return page.touchscreen.tap(p.x, p.y);
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: p.x, y: p.y }] });
  await sleep(hold);
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
}
async function fresh(page, seed) {
  await page.evaluate(([s]) => { localStorage.clear(); if (s) localStorage.setItem('intake-draft-TESTTOKEN123', JSON.stringify(s)); }, [seed || null]);
  await page.reload(); await open(page); await sleep(100);
}
// parent: [inputSel, text, seed]; targets: [name, sel, check(draft)]
const PARENTS = [
  ['grease_trap.systems_count', '2', null],
  ['lift_station.count', '1', null],
  ['water_tank.count', '3', { 'water_tank.count': 1 }],
  ['grease_trap.capacity_gallons', '500', { 'grease_trap.systems_count': 1 }],
];
const TARGETS = (pk) => [
  ['gate Yes (above)', '[data-f="access_entry.gate=yes"]', (d) => d['access_entry.gate'] === 'yes'],
  ['alarm Yes (above)', '[data-f="access_entry.alarm=yes"]', (d) => d['access_entry.alarm'] === 'yes'],
  ['choice Inside (above)', '[data-f="access_entry.equipment_where=Inside"]', (d) => d['access_entry.equipment_where'] === 'Inside'],
  ['day chip Tue (above)', '[data-f="access_hours.schedule:tue"]', (d) => d['access_hours.schedule'] && !!d['access_hours.schedule'].tue],
  ...(pk === 'grease_trap.capacity_gallons' ? [] : [['own +', `[data-f="${pk}:+"]`, null]]),
  pk === 'water_tank.count'
    ? ['+ below (water manholes)', '[data-f="water_tank.manhole_count:+"]', (d) => d['water_tank.manhole_count'] === 1]
    : pk === 'lift_station.count'
      ? ['+ below (water tanks)', '[data-f="water_tank.count:+"]', (d) => d['water_tank.count'] === 1]
      : ['+ below (sample ports)', '[data-f="grease_trap.sample_ports:+"]', (d) => d['grease_trap.sample_ports'] === 1],
];

async function run(mode, holds) {
  const mobile = mode !== 'mouse';
  const { browser, page, S, context } = await setup({ file, mobile });
  const cdp = mobile ? await context.newCDPSession(page) : null;
  await open(page);
  for (const hold of holds) for (const [pk, text, seed] of PARENTS) for (const [tn, tsel, chk0] of TARGETS(pk)) {
    await fresh(page, seed);
    const inSel = `input[data-f="${pk}"]`;
    if (mobile) await ttap(page, cdp, inSel, 0); else await mpress(page, inSel, 60);
    await page.keyboard.press('Control+A'); await page.keyboard.type(text);
    const expectOwn = Number(text) + 1;
    const chk = chk0 || ((d) => d[pk] === expectOwn);
    const before = await page.evaluate(() => document.querySelectorAll('#qs [data-f]').length);
    if (mobile) await ttap(page, cdp, tsel, hold); else await mpress(page, tsel, hold);
    await sleep(350);
    const d = await draft(page);
    const typedKept = tn === 'own +' ? true : d[pk] === Number(text);
    const after = await page.evaluate(() => document.querySelectorAll('#qs [data-f]').length);
    const ok = chk(d) && typedKept;
    out[ok ? 'pass' : 'fail']++;
    if (!ok || hold === holds[0]) out.rows.push(`${ok ? 'PASS' : 'FAIL'} ${mode} hold=${hold} ${pk}="${text}" -> ${tn}  rerendered:${before}->${after} draft=${JSON.stringify(d)}`);
  }
  // time box edit followed by a click
  for (const hold of holds) for (const [tn, tsel, chk] of [
    ['alarm No', '[data-f="access_entry.alarm=no"]', (d) => d['access_entry.alarm'] === 'no'],
    ['day chip Wed', '[data-f="access_hours.schedule:wed"]', (d) => !!d['access_hours.schedule'].wed],
    ['systems +', '[data-f="grease_trap.systems_count:+"]', (d) => d['grease_trap.systems_count'] === 1],
    ['Mon closes box', '[data-f="access_hours.schedule:mon:c"]', (d) => true],
  ]) {
    await fresh(page, { 'access_hours.schedule': { mon: { open: '08:00', close: '17:00' } } });
    const o = '[data-f="access_hours.schedule:mon:o"]';
    // put the caret in the hour segment (left third of the box), then type a full time
    const bx = await page.locator(o).evaluate((e) => { e.scrollIntoView({ block: 'center' }); const r = e.getBoundingClientRect(); return { x: r.left + Math.min(22, r.width / 4), y: r.top + r.height / 2 }; });
    if (mobile) await page.locator(o).focus(); else { await page.mouse.click(bx.x, bx.y); }
    await page.keyboard.type('0930AM'); await sleep(50);
    if (mobile) await ttap(page, cdp, tsel, hold); else await mpress(page, tsel, hold);
    await sleep(350);
    const d = await draft(page);
    const monOpen = d['access_hours.schedule'] && d['access_hours.schedule'].mon && d['access_hours.schedule'].mon.open;
    const act = await page.evaluate(() => document.activeElement && (document.activeElement.getAttribute('data-f') || document.activeElement.tagName));
    const ok = chk(d) && monOpen === '09:30' && (tn !== 'Mon closes box' || act === 'access_hours.schedule:mon:c');
    out[ok ? 'pass' : 'fail']++;
    out.rows.push(`${ok ? 'PASS' : 'FAIL'} ${mode} hold=${hold} time box typed 0930AM -> ${tn}  mon.open=${monOpen} focus=${act} draft.alarm=${d['access_entry.alarm'] || '-'} days=${Object.keys(d['access_hours.schedule'] || {}).join(',')} sys=${d['grease_trap.systems_count'] ?? '-'}`);
  }
  out.rows.push(`${mode}: pageerrors=${JSON.stringify(S.errors)} aborted=${S.aborted.length} ops=${[...new Set(S.ops)].join(',')}`);
  await browser.close();
}
await run('mouse', [80, 150, 200]);
await run('touch-tap', [0]);
await run('touch-held', [120]);
console.log(`[${file}] PASS ${out.pass}  FAIL ${out.fail}`);
console.log(out.rows.join('\n'));
