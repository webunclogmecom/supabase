export const meta = {
  name: 'derm-verify-placement',
  description: 'Adversarially verify each red code on the rendered DERM sheet lands on its correct facility row',
  phases: [{ title: 'Verify' }],
}

// payload: [{key, wm, out_png, expected:[{code, facility, address, phys_row}]}]
const payload = typeof args === 'string' ? JSON.parse(args) : args

const SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    checks: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          code: { type: 'string' },
          lands_next_to_facility: { type: 'string' },
          lands_next_to_address: { type: 'string' },
          verdict: { type: 'string', enum: ['correct', 'misaligned', 'cannot_tell'] },
        },
        required: ['code', 'lands_next_to_facility', 'lands_next_to_address', 'verdict'],
      },
    },
    any_code_between_rows: { type: 'boolean' },
    overall: { type: 'string', enum: ['all_correct', 'has_problem'] },
    notes: { type: 'string' },
  },
  required: ['checks', 'any_code_between_rows', 'overall', 'notes'],
}

function prompt(p) {
  return `You are ADVERSARIALLY verifying the placement of red client-code labels stamped onto a Miami-Dade FOG eManifest (DERM) sheet. Your job is to CATCH placement errors, not to rubber-stamp. Assume there may be a mistake and prove otherwise.

Rendered image: ${p.out_png} (use the Read tool to view it).

The sheet's Section B "Origination of Waste" has 6 physical row slots, each with a handwritten/printed Facility Name line and a Complete Facility Address line. Red client codes (like "057-BAY") have been overlaid in the left GDO# column, one per facility we identified.

Here is where each red code is SUPPOSED to land:
${p.expected.map(e => `  - ${e.code}  should sit on the row for: "${e.facility}" / "${e.address}"`).join('\n')}

For EACH red code label visible on the image:
1. Locate the red label.
2. Read the facility NAME and ADDRESS printed on the SAME horizontal row as that red label (i.e., the row the label is vertically centered on).
3. Compare to what it's supposed to be. Set verdict:
   - "correct" = the red label is clearly centered on the row whose facility/address matches the expected one above.
   - "misaligned" = the label sits on a DIFFERENT facility's row, or floats between two rows (not clearly on the intended one).
   - "cannot_tell" = the row content is too illegible to judge (use sparingly).
Be strict: if a label is closer to the neighboring row's text than to its intended row, that is "misaligned", not "correct".

Also set any_code_between_rows = true if ANY red label is not clearly seated within one row's band (floating on a grid line between two facilities).

Set overall = "all_correct" only if every check is "correct". Otherwise "has_problem". Return ONLY the JSON.`
}

phase('Verify')
// two independent verifiers per sheet (dual vote) for precision
const jobs = []
for (const p of payload) {
  for (let v = 0; v < 2; v++) {
    jobs.push(() => agent(prompt(p), { label: `verify:${p.key}#${v + 1}`, phase: 'Verify', schema: SCHEMA, effort: 'high' })
      .then(r => ({ key: p.key, voter: v + 1, ...r }))
      .catch(() => ({ key: p.key, voter: v + 1, overall: 'ERROR', checks: [], any_code_between_rows: false, notes: 'agent failed' })))
  }
}
const out = await parallel(jobs)
return { results: out }
