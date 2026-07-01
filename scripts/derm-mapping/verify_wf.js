export const meta = {
  name: 'derm-stamp-verify',
  description: 'Look at each stamped sheet and return the corrected GDO y for every red code (precision pass)',
  phases: [{ title: 'Verify', detail: '1 vision pass per stamped image; corrects mis-aligned codes' }],
}

// SHEETS embedded by build_verify_wf.js: [{key, stamped, gdo_x_pct, codes:[{code,address}]}]
const SHEETS = []

const SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    corrections: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: { code: { type: 'string' }, y_pct: { type: 'number' } }, required: ['code', 'y_pct'] } },
  }, required: ['corrections'],
}

function prompt(s) {
  return `This is a scanned Miami-Dade FOG eManifest with client codes ALREADY STAMPED in red in the GDO# column (far left of Section B). Read the image: ${s.stamped} (use the Read tool).

Each red code must be **vertically centered in the small GDO# box** at the far left of the facility row whose ADDRESS matches that client. Some codes are currently mis-aligned (too high or too low — sitting on the wrong row or between rows).

For EACH code below, find the facility row whose address matches it, and return the CORRECT **y_pct** = the vertical center of THAT row's GDO# box, as a percentage (0-100) of the full image height. Be precise: the code must line up with its own row, not the row above or below. If a code already looks correctly centered, return its current y_pct.

Codes on this sheet (code → the client's address, to locate the right row):
${s.codes.map(c => `  ${c.code}  ->  ${c.address}`).join('\n')}

Return ONLY {corrections:[{code,y_pct}, ...]} with one entry per code above.`
}

phase('Verify')
const out = await parallel(SHEETS.map(s => () =>
  agent(prompt(s), { label: 'verify:' + s.key, phase: 'Verify', schema: SCHEMA, effort: 'high' })
    .then(r => ({ key: s.key, corrections: (r && r.corrections) || [] })).catch(() => ({ key: s.key, corrections: [] }))
))
return { verifications: out }
