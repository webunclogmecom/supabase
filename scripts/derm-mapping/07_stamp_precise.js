// 07_stamp_precise.js <positions.json> : stamp confident codes onto each image and record the full
// stamp state (data/stamp_state.json) for the vision verify-and-correct pass. Outputs individual PNGs
// per 2-week window to C:/Users/FRED/Downloads/DERM_Stamped/Window_<nn>/.
const fs = require('fs');
const path = require('path');
const { q } = require('./lib/db');
const { render, buildStamps } = require('./lib/stamp_render');
const OUTROOT = 'C:/Users/FRED/Downloads/DERM_Stamped';
(async () => {
  const raw = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const positions = (raw.result && raw.result.positions) || raw.positions || [];
  const db = await q(`SELECT m.dump_folder, m.page, m.row_index, m.facility_name_read, m.address_read, c.client_code AS code
    FROM derm.address_row_map m JOIN clients c ON c.id=m.matched_client_id
    WHERE m.assignment_status='matched' AND m.confidence='high' AND c.client_code IS NOT NULL`);
  const dbByPage = {};
  for (const r of db) { const k = r.dump_folder + '|' + r.page; (dbByPage[k] = dbByPage[k] || []).push(r); }
  const state = [];
  let imgs = 0, coded = 0, fails = 0;
  for (const pos of positions) {
    if (!pos || !pos.local_file || String(pos.local_file).startsWith('DL_FAIL')) continue;
    const m = /^w(\d+)-/.exec(pos.label || '');
    const win = m ? String(m[1]).padStart(2, '0') : '00';
    const dir = OUTROOT + '/Window_' + win;
    fs.mkdirSync(dir, { recursive: true });
    const dbrows = dbByPage[pos.dump_folder + '|' + pos.page] || [];
    const stamps = buildStamps(dbrows, pos.rows || []);
    const gdoX = (typeof pos.gdo_x_pct === 'number' && pos.gdo_x_pct >= 0.5 && pos.gdo_x_pct <= 14) ? pos.gdo_x_pct : 6;
    const base = pos.wm ? ('ticket_' + pos.wm) : String(pos.dump_folder || 'sheet').replace(/[^a-z0-9]+/gi, '_');
    const out = dir + '/' + base + '_p' + pos.page + (stamps.length ? ('_' + stamps.length + 'codes') : '_blank') + '.png';
    try { render(pos.local_file, gdoX, stamps, out); imgs++; coded += stamps.length; }
    catch (e) { console.error('render fail', pos.label, 'p' + pos.page, '-', e.message); fails++; continue; }
    state.push({ window: win, label: pos.label, dump_folder: pos.dump_folder, wm: pos.wm, page: pos.page,
      local_file: pos.local_file, out_png: out, gdo_x_pct: gdoX, stamps });
  }
  fs.writeFileSync(path.resolve(__dirname, 'data', 'stamp_state.json'), JSON.stringify(state, null, 2));
  console.log('stamped ' + imgs + ' images (' + coded + ' codes), ' + fails + ' fails -> ' + OUTROOT + '  | wrote stamp_state.json');
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
