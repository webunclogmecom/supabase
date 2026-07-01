// refine_positions.js : for every stamped sheet in stamp_state_v3.json, snap each code's row-boundary
// predictions to the nearest REAL printed horizontal line (pixel search, full resolution), recompute
// the row center from the (possibly snapped) boundaries, and re-render. Vision + the calibrated row
// height get us within ~1-3% of the true position; this step removes that residual error deterministically
// using the sheet's own printed pixels, not another guess.
const fs = require('fs');
const path = require('path');
const { render } = require('./lib/stamp_render');
const { decode } = require('./lib/crop');
const { findNearestLine } = require('./lib/snap_grid');
const ROW_HEIGHT_FULL_PCT = 5.433;
const SEARCH_RADIUS_PCT = 2.6; // < half a row height, so we can't accidentally snap to the adjacent row's line

const STATE_FILE = path.resolve(__dirname, 'data', 'stamp_state_v3.json');
const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));

// A snap is only trusted if BOTH boundaries were found AND the resulting row span is close to the
// known physical row height -- this rejects snaps onto the internal name/address divider line (too
// narrow a span) or onto an unrelated dark feature (too wide), which pure sharpness alone can't tell
// apart from a genuine row-to-row boundary.
const SPAN_MIN = ROW_HEIGHT_FULL_PCT * 0.8, SPAN_MAX = ROW_HEIGHT_FULL_PCT * 1.2;

let sheetsChanged = 0, codesMoved = 0, codesRejected = 0, totalMove = 0, maxMove = 0;
for (const entry of state) {
  let img;
  try { img = decode(entry.local_file); } catch (e) { console.error('decode fail', entry.key, e.message); continue; }
  const xRange = [Math.max(2, entry.box.x0Pct), Math.min(98, entry.box.x1Pct)];
  let any = false;
  for (const st of entry.stamps) {
    const predTop = st.y_pct - ROW_HEIGHT_FULL_PCT / 2;
    const predBottom = st.y_pct + ROW_HEIGHT_FULL_PCT / 2;
    const top = findNearestLine(img, predTop, SEARCH_RADIUS_PCT, xRange);
    const bottom = findNearestLine(img, predBottom, SEARCH_RADIUS_PCT, xRange);
    const span = bottom.y_pct - top.y_pct;
    if (top.snapped && bottom.snapped && span >= SPAN_MIN && span <= SPAN_MAX) {
      const newY = (top.y_pct + bottom.y_pct) / 2;
      const moved = Math.abs(newY - st.y_pct);
      if (moved > 0.05) {
        totalMove += moved; maxMove = Math.max(maxMove, moved); codesMoved++;
        st.y_pct = newY; any = true;
      }
    } else if (top.snapped || bottom.snapped) {
      codesRejected++; // a line was found but the span didn't look like a real row -- keep current position
    }
  }
  if (any) {
    try { render(entry.local_file, entry.gdo_x_pct, entry.stamps, entry.out_png); sheetsChanged++; }
    catch (e) { console.error('re-render fail', entry.key, e.message); }
  }
}
fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
console.log(`refined ${state.length} sheets: ${sheetsChanged} re-rendered, ${codesMoved} codes moved (avg ${(totalMove / Math.max(1, codesMoved)).toFixed(2)}%, max ${maxMove.toFixed(2)}%), ${codesRejected} snaps rejected (implausible span)`);
