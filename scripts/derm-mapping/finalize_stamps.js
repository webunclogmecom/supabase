// finalize_stamps.js <fine-pos-result.json> : convert crop-relative positions back to full-image %,
// match confirmed DB rows to located rows, stamp ONCE onto the ORIGINAL sheet image, and write the
// authoritative data/stamp_state_v3.json. Outputs individual PNGs per window to
// C:/Users/FRED/Downloads/DERM_Stamped/Window_<nn>/.
const fs = require('fs');
const path = require('path');
const { q } = require('./lib/db');
const { render, buildStamps } = require('./lib/stamp_render');
const OUTROOT = 'C:/Users/FRED/Downloads/DERM_Stamped';
const STATE_FILE = path.resolve(__dirname, 'data', 'stamp_state_v3.json');
// Physical row height as a fraction of the FULL page height -- calibrated from a fully-verified
// sheet (828601: confirmed row centers 29.4/34.8/40.2/45.7% -> spacing 5.433%) and cross-checked
// against a second independent sheet (827989 p2, ~5.5%). The form is a fixed printed template, so
// this is a physical constant, not something to re-estimate per sheet -- table_top_pct (a single,
// high-contrast landmark: bottom of the black section-B title bar) is the only per-sheet unknown.
const ROW_HEIGHT_FULL_PCT = 5.433;

(async () => {
  const raw = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const positions = (raw.result && raw.result.positions) || raw.positions || [];
  const db = await q(`SELECT m.dump_folder, m.page, m.row_index, m.facility_name_read, m.address_read, c.client_code AS code
    FROM derm.address_row_map m JOIN clients c ON c.id=m.matched_client_id
    WHERE m.assignment_status='matched' AND m.confidence='high' AND c.client_code IS NOT NULL`);
  const dbByPage = {};
  for (const r of db) { const k = r.dump_folder + '|' + r.page; (dbByPage[k] = dbByPage[k] || []).push(r); }

  // We need dump_folder/wm/page per key -- read back from data/crops_all.json's sibling sheets_*.json
  // via the locate step's images, but simplest: re-derive from data/sheets_<nn>.json using the label.
  const D = path.resolve(__dirname, 'data');
  const labelInfo = {}; // "w1-s4" -> {dump_folder, wm, local_files, page_urls}
  for (let n = 1; n <= 13; n++) {
    const f = path.join(D, 'sheets_' + String(n).padStart(2, '0') + '.json');
    if (!fs.existsSync(f)) continue;
    const d = JSON.parse(fs.readFileSync(f, 'utf8'));
    for (const s of d.sheets) labelInfo[s.label] = s;
  }

  let existing = [];
  if (fs.existsSync(STATE_FILE)) existing = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  const byKey = new Map(existing.map(s => [s.key, s]));

  let imgs = 0, coded = 0, fails = 0;
  for (const pos of positions) {
    if (!pos || !pos.key) continue;
    const m = /^(w\d+-s\d+)-p(\d+)$/.exec(pos.key);
    if (!m) { console.error('unrecognized key', pos.key); fails++; continue; }
    const [, sheetLabel, pageStr] = m;
    const page = Number(pageStr);
    const sheet = labelInfo[sheetLabel];
    if (!sheet) { console.error('no sheet info for', sheetLabel); fails++; continue; }
    const box = pos.box; // {x0Pct,y0Pct,x1Pct,y1Pct} of the crop within the ORIGINAL image
    const cropW = box.x1Pct - box.x0Pct, cropH = box.y1Pct - box.y0Pct;
    if (typeof pos.table_top_pct !== 'number') { console.error('no table_top for', pos.key); fails++; continue; }
    const tableTopFull = box.y0Pct + (pos.table_top_pct / 100) * cropH;
    const rows = (pos.facility_names || []).map(r => ({ row_index: r.row_index, facility_name: r.facility_name,
      y_pct: tableTopFull + (r.row_index - 0.5) * ROW_HEIGHT_FULL_PCT }));
    const gdoXFull = (typeof pos.gdo_x_pct_in_crop === 'number') ? (box.x0Pct + (pos.gdo_x_pct_in_crop / 100) * cropW) : null;

    const winMatch = /^w(\d+)-/.exec(sheetLabel);
    const win = winMatch ? String(winMatch[1]).padStart(2, '0') : '00';
    const dbrows = dbByPage[sheet.dump_folder + '|' + page] || [];
    const stamps = buildStamps(dbrows, rows);
    if (!stamps.length) continue; // nothing confident to stamp on this page

    const dir = OUTROOT + '/Window_' + win;
    fs.mkdirSync(dir, { recursive: true });
    const localFile = (sheet.local_files || [])[page - 1];
    if (!localFile) { console.error('no local_file for', pos.key); fails++; continue; }
    const base = sheet.wm ? ('ticket_' + sheet.wm) : String(sheet.dump_folder || sheetLabel).replace(/[^a-z0-9]+/gi, '_');
    const out = dir + '/' + base + '_p' + page + '_' + stamps.length + 'codes.png';
    const gdoX = (gdoXFull != null && gdoXFull >= 0.5 && gdoXFull <= 20) ? gdoXFull : 6;
    try { render(localFile, gdoX, stamps, out); imgs++; coded += stamps.length; }
    catch (e) { console.error('render fail', pos.key, e.message); fails++; continue; }
    byKey.set(pos.key, { key: pos.key, window: win, dump_folder: sheet.dump_folder, wm: sheet.wm, page,
      local_file: localFile, out_png: out, gdo_x_pct: gdoX, box, stamps });
  }
  fs.writeFileSync(STATE_FILE, JSON.stringify([...byKey.values()], null, 2));
  console.log('finalized ' + imgs + ' images (' + coded + ' codes), ' + fails + ' fails -> ' + OUTROOT + ' | state: ' + STATE_FILE);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
