export const meta = {
  name: 'derm-pos',
  description: 'Locate each facility row\'s GDO#-cell position on every DERM sheet image (for code stamping)',
  phases: [{ title: 'Locate', detail: '1 vision pass per page image → per-row GDO y%, column x%' }],
}

// SHEETS is embedded by build_pos_wf.js (replaces the next line).
const SHEETS = []

const SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    gdo_x_pct: { type: 'number' },
    rows: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: { row_index: { type: 'integer' }, facility_name: { type: 'string' }, y_pct: { type: 'number' } },
      required: ['row_index', 'facility_name', 'y_pct'] } },
  }, required: ['gdo_x_pct', 'rows'],
}

function prompt(path) {
  return `This is a scanned Miami-Dade County "Fats, Oils and Grease (FOG)" eManifest. Read the image at: ${path} (use the Read tool).

In Section B ("Origination of Waste") there are up to 6 facility rows stacked vertically. Each row has a small "GDO#" box on the FAR LEFT (to the left of the handwritten/typed facility name). A client code will be written INTO that GDO# box for each row.

For EVERY filled facility row (top to bottom), return:
- row_index (1-based, top to bottom),
- facility_name (what you read for that row — used to line the code up with the right row),
- y_pct = the VERTICAL center of that row's GDO# box, as a percentage (0-100) of the FULL image height.
Also return gdo_x_pct = the horizontal center of the GDO# column (0-100 of image WIDTH) — the same column for every row.

Be precise: the GDO# cells are evenly stacked, so y_pct should increase in roughly even steps down the rows, and each y_pct must sit ON its own row (never overlapping the row above or below). Return ONLY the JSON.`
}

phase('Locate')
const tasks = []
for (const s of SHEETS) (s.local_files || []).forEach((p, i) => {
  if (!p || String(p).startsWith('DL_FAIL')) return
  tasks.push(() => agent(prompt(p), { label: `pos:${s.label}-p${i + 1}`, phase: 'Locate', schema: SCHEMA, effort: 'high' })
    .then(r => ({ label: s.label, dump_folder: s.dump_folder, wm: s.wm, page: i + 1, local_file: p, ...r }))
    .catch(() => null))
})
const positions = (await parallel(tasks)).filter(Boolean)
return { positions }
