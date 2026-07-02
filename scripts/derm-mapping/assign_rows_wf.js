export const meta = {
  name: 'derm-assign-physical-rows',
  description: 'Assign each DERM client code to its true physical row by reading the sheet',
  phases: [{ title: 'Assign' }],
}

// payload: [{key, wm, page, local_file, phys_rows, rowCenters:[{phys_row,y_pct}], codes:[{code,address,facility}]}]
const payload = typeof args === 'string' ? JSON.parse(args) : args

const SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    rows: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          phys_row: { type: 'integer' },
          facility_read: { type: 'string' },
          address_read: { type: 'string' },
          assigned_code: { type: ['string', 'null'] },
        },
        required: ['phys_row', 'facility_read', 'address_read', 'assigned_code'],
      },
    },
    unplaced_codes: { type: 'array', items: { type: 'string' } },
    rows_with_facility_but_no_code: { type: 'array', items: { type: 'integer' } },
    notes: { type: 'string' },
  },
  required: ['rows', 'unplaced_codes', 'rows_with_facility_but_no_code', 'notes'],
}

function prompt(p) {
  return `You are reading a Miami-Dade FOG eManifest (DERM) sheet to map known client codes to the correct PHYSICAL row.

Image: ${p.local_file} (use the Read tool to view it).

Section B "Origination of Waste" has ${p.phys_rows} physical row slots, numbered 1 (topmost) to ${p.phys_rows} (bottom). Each slot has a "Facility Name" line and a "Complete Facility Address" line beneath it. Some slots may be blank.

Here are the client codes we need to place, each with the address we have on file:
${p.codes.map(c => `  - ${c.code}: ${c.facility} | ${c.address}`).join('\n')}

Your job:
1. Read EACH physical row slot 1..${p.phys_rows} top to bottom. Report what facility name + address is actually written there (or empty strings if the slot is blank).
2. For each physical row, set assigned_code to the ONE code from the list above whose facility/address matches what is written in that row. If a row is blank or its facility is not in the list, set assigned_code to null.
3. Each code must be assigned to at most ONE physical row. If a code in the list does not match any physical row, put it in unplaced_codes.
4. If a physical row clearly has a facility written but none of the codes match it, include that row number in rows_with_facility_but_no_code.

Be careful: the handwriting is messy and addresses are the most reliable signal. The number of codes may be fewer than the number of filled rows (some facilities have no code yet). Return ONLY the JSON.`
}

phase('Assign')
const out = await parallel(payload.map(p => () =>
  agent(prompt(p), { label: 'assign:' + p.key, phase: 'Assign', schema: SCHEMA, effort: 'high' })
    .then(r => ({ key: p.key, ...r }))
    .catch(() => null)
))
return { results: out.filter(Boolean) }
