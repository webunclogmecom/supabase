export const meta = {
  name: 'derm-locate-box',
  description: 'Coarse-locate the Section B (Origination of Waste) bounding box on each raw sheet image',
  phases: [{ title: 'Locate box', detail: '1 pass per image; easy coarse task on the full page' }],
}

// IMAGES embedded by build_locate_wf.js: [{key, local_file}]
const IMAGES = []

const SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    y0_pct: { type: 'number' }, y1_pct: { type: 'number' }, x1_pct: { type: 'number' },
  }, required: ['y0_pct', 'y1_pct', 'x1_pct'],
}

function prompt(im) {
  return `This is a scanned Miami-Dade FOG eManifest. Read the image: ${im.local_file} (use the Read tool).

Find the "B: Origination of Waste" section — it starts with a solid dark title bar with white text reading "B: Origination of Waste", and contains a table of up to 6 facility rows (each with a "GDO#" box, a "Facility Name" line, and a "Complete Facility Address" line). This section ends where "Attach Additional Sheets..." text appears, or where "E: Liquid Waste Transporter Certification" begins.

Return, as percentages (0-100) of the FULL image:
- y0_pct: the vertical position where the "B: Origination of Waste" title bar STARTS (its top edge)
- y1_pct: the vertical position where this section ENDS (just below the last facility row, before "Attach Additional Sheets" or the certification section)
- x1_pct: the horizontal position where the facility-address table ends and the "FOG Control Device" columns begin (i.e. where the wide grid of measurement columns starts, on the right side)

Be generous rather than exact — a little extra margin above/below/right is fine, but do not CUT OFF any part of the title bar or any facility row. Return ONLY the JSON.`
}

phase('Locate box')
const out = await parallel(IMAGES.map(im => () =>
  agent(prompt(im), { label: 'box:' + im.key, phase: 'Locate box', schema: SCHEMA, effort: 'high' })
    .then(r => ({ key: im.key, local_file: im.local_file, y0_pct: r.y0_pct, y1_pct: r.y1_pct, x1_pct: r.x1_pct }))
    .catch(() => null)
))
return { boxes: out.filter(Boolean) }
