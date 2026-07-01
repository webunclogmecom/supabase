export const meta = {
  name: 'derm-fine-pos',
  description: 'Locate the Section-B 6-row table boundary on a zoomed crop; rows are computed by EVEN DIVISION (not per-row guessing)',
  phases: [{ title: 'Fine locate', detail: '3 votes per crop, median table_top/table_bottom -> 6 equal rows' }],
}

// CROPS embedded by build_fine_pos_wf.js: [{key, cropped_file, box:{x0Pct,y0Pct,x1Pct,y1Pct}}]
const CROPS = []

const SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    gdo_x_pct: { type: 'number' },
    table_top_pct: { type: 'number' },
    facility_names: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: { row_index: { type: 'integer' }, facility_name: { type: 'string' } },
      required: ['row_index', 'facility_name'] } },
  }, required: ['gdo_x_pct', 'table_top_pct', 'facility_names'],
}

function prompt(c) {
  return `This image is a ZOOMED CROP of Section B ("Origination of Waste") from a Miami-Dade FOG eManifest, cropped tightly so you can see it at high detail. Read the image: ${c.cropped_file} (use the Read tool).

This section is a PRINTED TABLE with exactly 6 EQUAL-HEIGHT rows (whether filled with a facility or left blank). Each row is a single cell containing TWO lines of small printed captions with handwriting next to them: "GDO #:" / "Facility Name:" on the first line, then "Complete Facility / Address (if no GDO#):" on the second line. IMPORTANT: there is NO separate header row below the black title bar — the solid black "B: Origination of Waste" title bar is IMMEDIATELY followed by Row 1's cell, with no gap or extra row in between.

Find ONE precise landmark:
- table_top_pct: the vertical position (0-100, % of this crop's height) of the BOTTOM edge of the solid black "B: Origination of Waste" title bar. This bottom edge of the black bar IS the top of Row 1's cell — do not look for any other line, and do not confuse it with the top edge of the black bar.

Also return:
- gdo_x_pct: the horizontal center (0-100, % of crop width) of the GDO# column.
- facility_names: for each FILLED row only, its row_index (1-based, top to bottom, out of the 6 slots) and the facility_name text you read on that row. Do NOT estimate a y-position for these — row placement will be computed from table_top_pct and the form's known fixed row height, not from your own row-by-row guess.

Return ONLY the JSON.`
}

phase('Fine locate')
const med = arr => { const a = arr.filter(x => typeof x === 'number').sort((x, y) => x - y); return a.length ? a[Math.floor(a.length / 2)] : null }
const tasks = CROPS.map(c => () =>
  parallel([0, 1, 2].map(k => () => agent(prompt(c), { label: `fine:${c.key}#${k + 1}`, phase: 'Fine locate', schema: SCHEMA, effort: 'high' }).catch(() => null)))
    .then(passes => {
      // sanity-filter each vote's table_top before aggregating (a garbage read, e.g. way off-canvas,
      // would otherwise corrupt the median)
      const sane = passes.filter(Boolean).filter(o => typeof o.table_top_pct === 'number' && o.table_top_pct >= -2 && o.table_top_pct <= 60)
      const ok = sane.length ? sane : passes.filter(Boolean)
      if (!ok.length) return { key: c.key, box: c.box, table_top_pct: null, facility_names: [] }
      const tableTop = med(ok.map(o => o.table_top_pct))
      const gdoX = med(ok.map(o => o.gdo_x_pct))
      const byIdx = {}
      for (const o of ok) for (const r of (o.facility_names || [])) { (byIdx[r.row_index] = byIdx[r.row_index] || []).push(r.facility_name) }
      const facility_names = Object.keys(byIdx).map(Number).sort((a, b) => a - b).map(ri => ({ row_index: ri, facility_name: byIdx[ri].find(Boolean) || '' }))
      return { key: c.key, box: c.box, gdo_x_pct_in_crop: gdoX, table_top_pct: tableTop, facility_names }
    })
)
const results = await parallel(tasks)
return { positions: results }
