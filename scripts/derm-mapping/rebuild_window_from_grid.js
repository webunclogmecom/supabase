// rebuild_window_from_grid.js <windowNumber> [--apply] : rebuild the stamped images for one window
// by measuring each sheet's real printed grid and placing every MATCHED, high-confidence client code
// at the vertical center of its DB row_index's "Facility Name" line. This fixes both failure modes of
// the old vision-anchored pipeline: (1) wrong table anchor -> whole column shifted, and (2) codes
// dropped because facility-name token matching failed (placement is now purely by row_index, so no
// row can be silently lost).
//
// Grid geometry, per sheet:
//  - Row boundaries come from scanning the Section C columns (x 46-60%), which carry ONLY the 6
//    full-width row rules (no internal name/address split) -> 7 clean, evenly-spaced lines.
//  - Within each row, the name/address divider is found in the left region and the code is centered
//    between the row's top boundary and that divider (= the Facility Name line). Falls back to a
//    fixed 0.25*rowHeight offset if no divider is confidently found.
const fs = require('fs');
const path = require('path');
const { decode } = require('./lib/crop');
const { detectLines } = require('./detect_grid');
const { render } = require('./lib/stamp_render');
const { q } = require('./lib/db');

const NAME_FRAC = 0.25; // fallback: name line sits ~1/4 of the way down the row block

// Extract the 6-row boundary grid (7 lines) from Section C. Take the longest run of lines whose
// consecutive gaps are a consistent row height (4.5-6.5%).
function rowBoundaries(img) {
  const lines = detectLines(img, 16, 72, [46, 60], 0.55).map(l => l.y_pct);
  let best = [];
  for (let i = 0; i < lines.length; i++) {
    const run = [lines[i]];
    for (let j = i + 1; j < lines.length; j++) {
      const gap = lines[j] - run[run.length - 1];
      if (gap >= 4.5 && gap <= 6.5) run.push(lines[j]);
      else if (gap < 4.5) continue; // skip a spurious close line, keep looking from current tail
      else break;
    }
    if (run.length > best.length) best = run;
  }
  return best;
}

function dividerFor(img, top, bot) {
  const rh = bot - top;
  const cand = detectLines(img, top + rh * 0.2, top + rh * 0.78, [3, 40], 0.5);
  if (!cand.length) return null;
  const mid = top + rh * 0.5;
  cand.sort((a, b) => Math.abs(a.y_pct - mid) - Math.abs(b.y_pct - mid));
  return cand[0].y_pct;
}

(async () => {
  const n = parseInt(process.argv[2], 10);
  const apply = process.argv.includes('--apply');
  if (!n) { console.error('usage: node rebuild_window_from_grid.js <windowNumber> [--apply]'); process.exit(1); }

  const STATE_FILE = path.resolve(__dirname, 'data', 'stamp_state_v3.json');
  const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  const entries = state.filter(e => String(e.window) === String(n).padStart(2, '0'))
    .sort((a, b) => a.wm.localeCompare(b.wm) || a.page - b.page);
  if (!entries.length) { console.error('no state entries for window', n); process.exit(1); }

  const wms = [...new Set(entries.map(e => e.wm))];
  const dbrows = await q(`
    select m.white_manifest_number as wm, m.page, m.row_index, m.address_read,
           m.assignment_status, m.confidence, c.client_code
    from derm.address_row_map m
    left join public.clients c on c.id = m.matched_client_id
    where m.white_manifest_number in (${wms.map(w => `'${w}'`).join(',')})
    order by m.white_manifest_number, m.page, m.row_index`);
  const dbBy = {};
  for (const r of dbrows) { (dbBy[`${r.wm}_${r.page}`] ||= []).push(r); }

  let changed = 0;
  for (const e of entries) {
    const img = decode(e.local_file);
    const bounds = rowBoundaries(img);
    const drows = (dbBy[`${e.wm}_${e.page}`] || []).filter(r => r.assignment_status === 'matched' && r.confidence === 'high' && r.client_code);
    const rh = bounds.length > 1 ? (bounds[bounds.length - 1] - bounds[0]) / (bounds.length - 1) : 5.5;
    console.log(`\n${e.key} (wm ${e.wm} p${e.page}): ${bounds.length} boundaries (rowH ${rh.toFixed(2)}), ${drows.length} matched codes`);
    if (bounds.length < 2) { console.log('  !! grid detection failed, SKIP'); continue; }

    const newStamps = [];
    for (const r of drows) {
      const k = r.row_index; // 1-indexed
      if (k > bounds.length - 1) { console.log(`  !! row_index ${k} > available rows ${bounds.length - 1} for ${r.client_code}, SKIP row`); continue; }
      const top = bounds[k - 1], bot = bounds[k];
      const div = dividerFor(img, top, bot);
      const y = div != null ? (top + div) / 2 : top + NAME_FRAC * rh;
      newStamps.push({ code: r.client_code, y_pct: y, address: r.address_read || '' });
      console.log(`  row ${k} ${r.client_code.padEnd(10)} top=${top.toFixed(2)} div=${div != null ? div.toFixed(2) : 'n/a'} -> y=${y.toFixed(2)}`);
    }
    // report deltas vs current
    for (const ns of newStamps) {
      const old = e.stamps.find(s => s.code === ns.code);
      console.log(`     ${ns.code.padEnd(10)} old=${old ? old.y_pct.toFixed(2) : 'MISSING'} new=${ns.y_pct.toFixed(2)}`);
    }
    if (apply) {
      e.stamps = newStamps;
      // regenerate out_png name to reflect new code count
      const base = e.out_png.replace(/_\d+codes\.png$/, '');
      e.out_png = `${base}_${newStamps.length}codes.png`;
      render(e.local_file, e.gdo_x_pct, e.stamps, e.out_png);
      changed++;
    }
  }
  if (apply) { fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2)); console.log(`\nAPPLIED: ${changed} sheets re-rendered + state saved`); }
  else console.log('\n(dry run -- pass --apply to write)');
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
