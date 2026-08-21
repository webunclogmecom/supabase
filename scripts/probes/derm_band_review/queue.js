// Rebuild the visual-review queue from the live DB.
//
// 🛑 WHY THIS EXISTS: the first queue carried only the rows that have a SERVED redacted
// document. That is the wrong row set to look at. The redaction geometry is a per-page
// TILING: whether a boundary is in the right place is only visible when every band on
// the page is drawn. derm/1194 page 3 rendered with 4 of its 5 bands, and the missing
// one (242-WYN, unserved) is the row whose boundary with 226-JER is in question.
//
// So: every banded row on the page, with `served` marked, ordered by how far the tallest
// band on the page exceeds the fleet median band height.
const fs = require('fs');
const rows = JSON.parse(fs.readFileSync(__dirname + '/allrows.out.json', 'utf8'));

const heights = rows.map(r => Number(r.by1) - Number(r.by0)).sort((a, b) => a - b);
const median = heights[Math.floor(heights.length / 2)];

const pages = {};
for (const r of rows) {
  const k = r.dump_folder + '#' + r.pg;
  (pages[k] = pages[k] || {
    dump_folder: r.dump_folder, pg: r.pg, src: r.src, rows: [],
  }).rows.push({
    id: r.id,
    code: r.client_code || ('row' + r.id),
    y0: Number(r.by0), y1: Number(r.by1),
    s: r.s == null ? null : Number(r.s),
    served: !!r.served,
    src: r.band_source,
  });
}

const queue = Object.values(pages).map(p => {
  p.rows.sort((a, b) => a.y0 - b.y0);
  const maxH = Math.max(...p.rows.map(r => r.y1 - r.y0));
  return {
    ...p,
    bands: p.rows.length,
    served: p.rows.filter(r => r.served).length,
    max_h: maxH.toFixed(2),
    vs_fleet: (maxH / median).toFixed(2),
  };
}).sort((a, b) => Number(b.vs_fleet) - Number(a.vs_fleet));

fs.writeFileSync(__dirname + '/sweep-queue.json', JSON.stringify(queue));
console.log('fleet median band height ' + median.toFixed(2) + 'pp');
console.log(queue.length + ' pages, ' + queue.reduce((n, p) => n + p.bands, 0) + ' bands, '
  + queue.reduce((n, p) => n + p.served, 0) + ' served documents');

// which pages I already reviewed would render differently now?
const old = process.argv[2];
if (old) {
  const prev = JSON.parse(fs.readFileSync(old, 'utf8'));
  const n = Number(process.argv[3] || 0);
  const seen = prev.slice(0, n);
  const nowBy = Object.fromEntries(queue.map(p => [p.dump_folder + '#' + p.pg, p]));
  console.log('\nalready-reviewed pages whose row set was INCOMPLETE:');
  let bad = 0;
  for (const p of seen) {
    const k = p.dump_folder + '#' + p.pg;
    const cur = nowBy[k];
    if (!cur) { console.log('  ' + k + '  MISSING from new queue'); bad++; continue; }
    if (cur.bands !== p.rows.length) {
      console.log('  ' + k + '  reviewed with ' + p.rows.length + ' bands, page really has ' + cur.bands);
      bad++;
    }
  }
  if (!bad) console.log('  none - all ' + seen.length + ' were complete');
  console.log('\nnew queue positions of the ' + seen.length + ' already-reviewed pages:');
  console.log('  ' + seen.map(p => queue.findIndex(q => q.dump_folder === p.dump_folder && q.pg === p.pg)).join(', '));
}
