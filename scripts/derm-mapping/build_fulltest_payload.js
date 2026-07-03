// build_fulltest_payload.js : build the payload for the FULL-FLEET stamped-sheet verification.
// For every sheet in stamp_state_v3.json: the rendered PNG, the stamps that were rendered, the DB's
// expected codes (matched + high + client_code) and ALL extracted rows for context. Also computes the
// inline diff render-vs-DB (missing/extra codes) -- those are findings before any vision runs.
const fs = require('fs');
const path = require('path');
const { q } = require('./lib/db');

(async () => {
  const state = JSON.parse(fs.readFileSync(path.resolve(__dirname, 'data', 'stamp_state_v3.json'), 'utf8'));
  const wms = [...new Set(state.map(e => e.wm).filter(Boolean))];
  const dfs = [...new Set(state.map(e => { const m = e.key.match(/^w(\d+)-s(\d+)-p\d+$/); return m ? `window${m[1]}-sheet${m[2]}` : null; }).filter(Boolean))];

  const rows = await q(`
    select m.white_manifest_number wm, m.dump_folder df, m.page, m.row_index,
           m.facility_name_read, m.address_read, m.assignment_status, m.confidence,
           c.client_code
    from derm.address_row_map m
    left join public.clients c on c.id = m.matched_client_id
    where m.white_manifest_number in (${wms.map(w => `'${w}'`).join(',')})
       or m.dump_folder in (${dfs.map(d => `'${d}'`).join(',')})
    order by m.page, m.row_index`);

  const byKey = {};
  for (const r of rows) {
    if (r.wm) (byKey[`wm:${r.wm}_${r.page}`] ||= []).push(r);
    if (r.df) (byKey[`df:${r.df}_${r.page}`] ||= []).push(r);
  }

  const payload = []; let missTotal = 0, extraTotal = 0;
  for (const e of state) {
    const m = e.key.match(/^w(\d+)-s(\d+)-p(\d+)$/);
    const df = m ? `window${m[1]}-sheet${m[2]}` : null;
    const page = m ? parseInt(m[3], 10) : e.page;
    const dbRows = (e.wm && byKey[`wm:${e.wm}_${page}`]) || (df && byKey[`df:${df}_${page}`]) || [];
    const expected = dbRows.filter(r => r.assignment_status === 'matched' && r.confidence === 'high' && r.client_code)
      .map(r => ({ code: r.client_code, facility: r.facility_name_read || '', address: r.address_read || '' }));
    const rendered = e.stamps.map(s => s.code);
    const expCodes = expected.map(x => x.code);
    const missing = expCodes.filter(c => !rendered.includes(c));
    const extra = rendered.filter(c => !expCodes.includes(c));
    missTotal += missing.length; extraTotal += extra.length;
    payload.push({
      key: e.key, window: e.window, wm: e.wm || null, out_png: e.out_png,
      stamps: e.stamps.map(s => ({ code: s.code, y_pct: +s.y_pct.toFixed(2) })),
      expected,
      all_rows: dbRows.map(r => ({ i: r.row_index, fac: r.facility_name_read || '', addr: r.address_read || '', code: r.client_code || null, st: r.assignment_status, cf: r.confidence })),
      missing_in_render: missing, extra_in_render: extra,
    });
  }
  fs.writeFileSync(path.resolve(__dirname, 'data', '_fulltest_payload.json'), JSON.stringify(payload, null, 1));
  console.log(`payload: ${payload.length} sheets · ${payload.reduce((s, p) => s + p.stamps.length, 0)} rendered stamps · ${payload.reduce((s, p) => s + p.expected.length, 0)} expected codes`);
  console.log(`INLINE DIFF -> missing_in_render: ${missTotal}  extra_in_render: ${extraTotal}`);
  for (const p of payload) {
    if (p.missing_in_render.length || p.extra_in_render.length)
      console.log(`  ${p.key}: missing=[${p.missing_in_render}] extra=[${p.extra_in_render}]`);
  }
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
