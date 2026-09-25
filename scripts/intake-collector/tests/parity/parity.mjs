// Data parity probe: drive old.html and new.html through the same sequences, compare submit body + draft.
// Run: node parity.mjs            (all sequences)   node parity.mjs S2   (one)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const { chromium } = (await import('node:module')).createRequire(import.meta.url)(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core');

const DIR = path.dirname(fileURLToPath(import.meta.url));
const LOAD = fs.readFileSync(path.join(DIR, 'load.json'), 'utf8');
const EP = 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/intake-submit';
const URL0 = 'https://planner.unclogme.app/intake.html';
const KEY = 'intake-draft-TESTTOKEN123';
const DAYN = { mon: 'Mon', tue: 'Tue', wed: 'Wed', thu: 'Thu', fri: 'Fri', sat: 'Sat', sun: 'Sun' };
const DAYS = Object.keys(DAYN);
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'POST,PUT,OPTIONS' };
const JPG = Buffer.from('/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=', 'base64');

function sortDeep(v) {
  if (Array.isArray(v)) return v.map(sortDeep);
  if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortDeep(v[k])]));
  return v;
}
// blob: URLs differ per run by construction; keep only "is a blob URL of this origin".
function normBlobs(v) {
  if (Array.isArray(v)) return v.map(normBlobs);
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, (k === 'preview' && typeof x === 'string' && x.startsWith('blob:https://planner.unclogme.app/')) ? 'BLOB' : normBlobs(x)]));
  return v;
}
const canon = (v) => JSON.stringify(sortDeep(normBlobs(v)));

async function run(browser, which, seq) {
  const html = fs.readFileSync(path.join(DIR, (which === 'new' && process.env.NEWFILE) || which + '.html'), 'utf8');
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, permissions: ['geolocation'], geolocation: { latitude: 25.8, longitude: -80.2, accuracy: 5 } });
  const log = { api: [], aborted: [], submit: null, uploads: 0 };
  let n = 0;
  await ctx.route('**/*', (r) => { log.aborted.push(r.request().url()); return r.abort(); });
  await ctx.route('https://upload.invalid/**', (r) => r.fulfill({ status: 200, headers: CORS, body: '' }));
  await ctx.route(EP, async (r) => {
    const req = r.request();
    if (req.method() === 'OPTIONS') return r.fulfill({ status: 204, headers: CORS });
    const b = req.postDataJSON();
    const j = (o) => r.fulfill({ status: 200, headers: { ...CORS, 'content-type': 'application/json' }, body: typeof o === 'string' ? o : JSON.stringify(o) });
    log.api.push({ op: b.op, role: b.role, content_type: b.content_type, path: b.path, token: b.token });
    if (b.op === 'load') return j(LOAD);
    if (b.op === 'upload') { n++; return j({ ok: true, signed_url: 'https://upload.invalid/put', path: '999/p' + n + '.jpg' }); }
    if (b.op === 'attach') return j({ ok: true });
    if (b.op === 'submit') { log.submit = b; return j({ ok: true, status: 'Incomplete' }); }
    return j({ ok: false, message: 'unknown op' });
  });
  await ctx.route(URL0, (r) => r.fulfill({ status: 200, contentType: 'text/html', body: html }));
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', (e) => errs.push(String(e)));
  await page.goto(URL0 + '#code=TESTTOKEN123');
  await page.waitForFunction(() => window.F && document.querySelectorAll('.q').length > 0);

  const settle = async () => { await page.waitForTimeout(60); await page.waitForFunction(() => busy === 0); await page.waitForTimeout(30); };
  const qLoc = async (key) => {
    const r = await page.evaluate((k) => {
      const req = new Set(F.requested); const keys = [];
      F.form.sections.forEach((s) => s.questions.forEach((q) => { if (req.has(q.key) && visible(q)) keys.push(q.key); }));
      return { i: keys.indexOf(k), label: (findQ(k) || {}).label };
    }, key);
    if (r.i < 0) throw new Error(which + ': question not visible: ' + key);
    const loc = page.locator('.q').nth(r.i);
    const lab = (await loc.locator('label').first().textContent()) || '';
    if (!lab.startsWith(r.label)) throw new Error(which + ': locator mismatch for ' + key + ' got label ' + lab);
    if (which === 'new' && (await loc.getAttribute('data-q')) !== key) throw new Error('new: data-q mismatch ' + key);
    return loc;
  };
  const S = {
    click: async (k, t) => { await (await qLoc(k)).getByRole('button', { name: t, exact: true }).click(); },
    text: async (k, v) => { const l = (await qLoc(k)).locator('textarea, input[type=text]'); await l.fill(v); await l.press('Tab'); },
    num: async (k, v) => { const l = (await qLoc(k)).locator('input[type=number]'); await l.fill(String(v)); await l.press('Tab'); },
    day: async (k, d) => {
      const q = await qLoc(k);
      if (which === 'old') await q.locator('.hrs').nth(DAYS.indexOf(d)).locator('input[type=checkbox]').click();
      else await q.getByRole('button', { name: DAYN[d], exact: true }).click();
    },
    times: async (k, d, o, c) => {
      for (const [idx, val] of [[0, o], [1, c]]) {
        const q = await qLoc(k);
        const l = which === 'old' ? q.locator('.hrs').nth(DAYS.indexOf(d)).locator('input[type=time]').nth(idx) : q.getByLabel(DAYN[d] + (idx ? ' closes' : ' opens'), { exact: true });
        await l.fill(val); await settle();
      }
    },
    gps: async (k, lat, lng, acc) => {
      await ctx.setGeolocation({ latitude: lat, longitude: lng, accuracy: acc });
      await (await qLoc(k)).getByRole('button', { name: /Use my location/ }).click();
      await page.waitForFunction(([k, lat]) => A[k] && A[k].lat === lat, [k, lat], { timeout: 30000 });
    },
    photo: async (k) => {
      const before = await page.evaluate((k) => (Array.isArray(A[k]) ? A[k].length : 0), k);
      await (await qLoc(k)).locator('input[type=file]').setInputFiles({ name: 'p.jpg', mimeType: 'image/jpeg', buffer: JPG });
      await page.waitForFunction(([k, b]) => busy === 0 && Array.isArray(A[k]) && A[k].length === b + 1, [k, before], { timeout: 10000 });
    },
    reload: async () => { await page.reload(); await page.waitForFunction(() => window.F && document.querySelectorAll('.q').length > 0); },
  };
  for (const st of seq.steps) {
    const [op, ...args] = st;
    if (which === 'new' && seq.newOverride && seq.newOverride[JSON.stringify(st)]) { await seq.newOverride[JSON.stringify(st)](page, qLoc); }
    else await S[op](...args);
    await settle();
  }
  const draftRaw = await page.evaluate((K) => localStorage.getItem(K), KEY);
  const visibleKeys = await page.evaluate(() => { const req = new Set(F.requested); const o = []; F.form.sections.forEach((s) => s.questions.forEach((q) => { if (req.has(q.key) && visible(q)) o.push(q.key); })); return o; });
  // submit
  await page.fill('#who', seq.who || 'Jane Collector');
  await page.click('#send');
  let confirmShown = false;
  if (which === 'new') {
    const any = page.getByRole('button', { name: 'Submit anyway', exact: true });
    try { await any.waitFor({ state: 'visible', timeout: 1500 }); confirmShown = true; await any.click(); } catch {}
  }
  const t0 = Date.now();
  while (!log.submit && Date.now() - t0 < 5000) await page.waitForTimeout(50);
  await page.waitForTimeout(200);
  const draftAfter = await page.evaluate((K) => localStorage.getItem(K), KEY);
  const thanks = await page.locator('.big h2').first().textContent().catch(() => null);
  await ctx.close();
  return { draft: draftRaw ? JSON.parse(draftRaw) : null, draftAfter, submit: log.submit, api: log.api.map(({ op, role, content_type, path, token }) => ({ op, role, content_type, path, token })), aborted: log.aborted, errs, confirmShown, thanks, visibleKeys };
}

const SEQ = {
  S1_full: { who: '  Jane Doe  ', steps: [
    ['gps', 'site_map.truck_parking', 25.80123456, -80.20123456, 5],
    ['click', 'access_entry.gate', 'Yes'], ['text', 'access_entry.gate_code', 'Code 4321#'], ['photo', 'access_entry.gate_photos'],
    ['click', 'access_entry.equipment_where', 'Inside'], ['click', 'access_entry.where_inside', 'Other'], ['text', 'access_entry.where_inside_note', 'Behind the walk-in cooler'],
    ['click', 'access_entry.access_point', 'Other'], ['text', 'access_entry.access_point_note', 'Loading dock ramp'], ['photo', 'access_entry.access_photos'],
    ['click', 'access_entry.how_access', 'Lock box'], ['text', 'access_entry.lock_box_code', '  1234  '], ['photo', 'access_entry.lock_box_photos'],
    ['click', 'access_entry.alarm', 'Yes'], ['text', 'access_entry.alarm_instruction', 'Panel by door, code 9999'],
    ['text', 'access_entry.obstacles', 'Low ceiling\nWatch the step'],
    ['day', 'access_hours.schedule', 'mon'], ['times', 'access_hours.schedule', 'mon', '07:30', '22:15'],
    ['num', 'grease_trap.systems_count', 2], ['gps', 'site_map.gt_location', 25.7001, -80.3002, 8],
    ['num', 'grease_trap.cleanouts_count', 3], ['num', 'grease_trap.manhole_count', 1], ['photo', 'grease_trap.photos'],
    ['num', 'grease_trap.capacity_gallons', 20000], ['photo', 'grease_trap.capacity_photos'], ['num', 'grease_trap.sample_ports', 0],
    ['num', 'lift_station.count', 1], ['photo', 'lift_station.photos'], ['photo', 'lift_station.control_panel_photos'],
    ['num', 'water_tank.count', 1], ['num', 'water_tank.manhole_count', 2], ['text', 'water_tank.capacity', '500 gal'], ['photo', 'water_tank.photos'],
  ] },
  S2_hidden_followups: { steps: [
    ['click', 'access_entry.how_access', 'Lock box'], ['text', 'access_entry.lock_box_code', '5555'], ['photo', 'access_entry.lock_box_photos'],
    ['click', 'access_entry.how_access', 'Key'], ['text', 'access_entry.key_instruction', 'Under the mat'],
    ['click', 'access_entry.gate', 'Yes'], ['text', 'access_entry.gate_code', 'abc'], ['photo', 'access_entry.gate_photos'], ['click', 'access_entry.gate', 'No'],
    ['click', 'access_entry.equipment_where', 'Outside'], ['click', 'access_entry.where_outside', 'Other'], ['text', 'access_entry.where_outside_note', 'Alley'],
    ['click', 'access_entry.equipment_where', 'Inside'], ['click', 'access_entry.where_inside', 'Kitchen'],
    ['click', 'access_entry.access_point', 'Other'], ['text', 'access_entry.access_point_note', 'x'], ['click', 'access_entry.access_point', 'Front door'],
    ['num', 'grease_trap.systems_count', 1], ['text', 'grease_trap.capacity_measure', '4x3x2 ft'], ['num', 'grease_trap.capacity_gallons', 750],
    ['num', 'water_tank.count', 1], ['text', 'water_tank.capacity', '300'], ['num', 'water_tank.count', 0],
    ['click', 'access_entry.alarm', 'Yes'], ['text', 'access_entry.alarm_instruction', 'zzz'], ['click', 'access_entry.alarm', 'No'],
    ['num', 'lift_station.count', 2], ['photo', 'lift_station.photos'], ['num', 'lift_station.count', 0],
    ['day', 'access_hours.schedule', 'tue'],
  ] },
  S3_numbers_gps: { steps: [
    ['num', 'grease_trap.systems_count', 3], ['num', 'grease_trap.capacity_gallons', 20000],
    ['num', 'grease_trap.cleanouts_count', '2.5'], ['num', 'grease_trap.manhole_count', 50], ['num', 'grease_trap.sample_ports', 7],
    ['num', 'lift_station.count', 0],
    ['num', 'water_tank.count', 2], ['num', 'water_tank.manhole_count', 4], ['num', 'water_tank.count', ''],
    ['gps', 'site_map.truck_parking', 25.61, -80.41, 40],
    ['gps', 'site_map.gt_location', 25.62, -80.42, 3],
    ['day', 'access_hours.schedule', 'sat'], ['times', 'access_hours.schedule', 'sat', '22:00', '02:00'],
    ['day', 'access_hours.schedule', 'fri'], ['day', 'access_hours.schedule', 'fri'],
    ['click', 'access_entry.equipment_where', 'Outside'], ['click', 'access_entry.where_outside', 'Back'],
  ] },
  S4_text_edges: { who: 'Ana María Núñez', steps: [
    ['click', 'access_entry.gate', 'Yes'], ['text', 'access_entry.gate_code', 'first'], ['text', 'access_entry.gate_code', ''],
    ['text', 'access_entry.obstacles', '   Café, ñ, 🚚 "quotes" <b>x</b>   '],
    ['click', 'access_entry.how_access', 'Lock box'], ['text', 'access_entry.lock_box_code', 'A'.repeat(150)],
    ['click', 'access_entry.alarm', 'No'],
    ['click', 'access_entry.equipment_where', 'Outside'], ['click', 'access_entry.where_outside', 'Other'], ['text', 'access_entry.where_outside_note', '  '],
    ['click', 'access_entry.access_point', 'Side entrance'],
    ['photo', 'access_entry.access_photos'], ['photo', 'access_entry.access_photos'],
    ['num', 'grease_trap.systems_count', 0], ['num', 'grease_trap.cleanouts_count', 0],
    ['day', 'access_hours.schedule', 'sun'], ['times', 'access_hours.schedule', 'sun', '00:00', '00:00'],
  ] },
  S5_reload_midway: { steps: [
    ['click', 'access_entry.how_access', 'Lock box'], ['text', 'access_entry.lock_box_code', '777'], ['photo', 'access_entry.lock_box_photos'],
    ['num', 'grease_trap.systems_count', 1], ['gps', 'site_map.gt_location', 25.5, -80.5, 6],
    ['day', 'access_hours.schedule', 'wed'], ['times', 'access_hours.schedule', 'wed', '06:00', '11:45'],
    ['reload'],
    ['photo', 'access_entry.lock_box_photos'], ['click', 'access_entry.alarm', 'Yes'], ['text', 'access_entry.alarm_instruction', 'after reload'],
  ] },
};

const only = process.argv[2];
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true });
const out = {};
let fail = 0;
for (const [name, seq] of Object.entries(SEQ)) {
  if (only && !name.startsWith(only)) continue;
  const o = await run(browser, 'old', seq), nw = await run(browser, 'new', seq);
  const r = {
    submitEqual: canon(o.submit) === canon(nw.submit),
    draftEqual: canon(o.draft) === canon(nw.draft),
    apiEqual: canon(o.api) === canon(nw.api),
    visibleEqual: canon(o.visibleKeys) === canon(nw.visibleKeys),
    draftClearedOld: o.draftAfter === null, draftClearedNew: nw.draftAfter === null,
    confirmShownNew: nw.confirmShown, thanks: [o.thanks, nw.thanks],
    pageErrors: [o.errs, nw.errs], abortedNonFavicon: [...o.aborted, ...nw.aborted],
  };
  // hidden follow-ups: in the draft but not visible -> must not be in the submit body
  for (const [w, x] of [['old', o], ['new', nw]]) {
    const hidden = Object.keys(x.draft || {}).filter((k) => !x.visibleKeys.includes(k));
    r['hiddenInDraft_' + w] = hidden;
    r['hiddenLeakedToSubmit_' + w] = hidden.filter((k) => x.submit && k in x.submit.answers);
    r['nonPathPhotos_' + w] = Object.entries(x.submit ? x.submit.answers : {}).filter(([, v]) => Array.isArray(v) && v.some((p) => typeof p !== 'string')).map(([k]) => k);
  }
  if (!r.submitEqual || !r.draftEqual) { fail++; r.oldSubmit = sortDeep(o.submit); r.newSubmit = sortDeep(nw.submit); r.oldDraft = sortDeep(normBlobs(o.draft)); r.newDraft = sortDeep(normBlobs(nw.draft)); }
  r.submitBody = sortDeep(nw.submit);
  r.draft = sortDeep(normBlobs(nw.draft));
  out[name] = r;
  console.log(name, JSON.stringify({ submitEqual: r.submitEqual, draftEqual: r.draftEqual, apiEqual: r.apiEqual, visibleEqual: r.visibleEqual, confirm: r.confirmShownNew, cleared: [r.draftClearedOld, r.draftClearedNew], hiddenOld: r.hiddenInDraft_old, leak: [r.hiddenLeakedToSubmit_old, r.hiddenLeakedToSubmit_new], nonPath: [r.nonPathPhotos_old, r.nonPathPhotos_new], errs: r.pageErrors, aborted: r.abortedNonFavicon }));
}
fs.writeFileSync(path.join(DIR, 'parity_out.json'), JSON.stringify(out, null, 1));
await browser.close();
console.log(fail ? 'MISMATCHES: ' + fail : 'ALL EQUAL');
