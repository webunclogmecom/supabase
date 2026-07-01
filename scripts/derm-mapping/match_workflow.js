export const meta = {
  name: 'derm-row-match',
  description: 'Blind vision agents match FOG-manifest facility rows to candidate clients; reconcile + confidence',
  phases: [{ title: 'Match', detail: '3 blind agents per sheet, digit-anchored constrained match' }],
}

// args = { sheets: [{label, dump_folder, wm, dump_date, candidates:[{code,name,address}], local_files:[paths]}], gazetteer: {byAddr,byName} }
// NOTE: the runtime delivers `args` as a JSON STRING — parse it.
const A = typeof args === 'string' ? JSON.parse(args) : (args || {})
const SHEETS = (A && A.sheets) || []
const GAZ = (A && A.gazetteer) || { byAddr: {}, byName: {} }

const SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    rows: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: {
        page: { type: 'integer' }, row_index: { type: 'integer' },
        facility_name_read: { type: 'string' }, address_read: { type: 'string' },
        assigned_code: { type: 'string' }, confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
        evidence: { type: 'string' },
      }, required: ['page', 'row_index', 'facility_name_read', 'address_read', 'assigned_code', 'confidence'] } },
    unplaced_candidates: { type: 'array', items: { type: 'string' } },
  }, required: ['rows', 'unplaced_candidates'],
}

function buildPrompt(s) {
  const gzHints = s.candidates
    .map(c => c.code).filter(Boolean)
    .concat(Object.values(GAZ.byAddr || {}), Object.values(GAZ.byName || {}))
  return `You are reading a scanned Miami-Dade County "Fats, Oils and Grease (FOG)" eManifest — a grease-disposal form filled out mostly BY HAND. Section B ("Origination of Waste") lists up to 6 serviced facilities per page; each filled facility has a handwritten Facility Name and a Complete Facility Address (street, city, FL, zip). A dump ticket can span multiple pages.

Image page(s) to read (${s.local_files.length}) — call the Read tool on EACH absolute path:
${s.local_files.map((p, i) => `  Page ${i + 1}: ${p}`).join('\n')}

For EVERY filled facility row (top-to-bottom, page by page), transcribe the facility name and address, then assign that row to the SINGLE best-matching candidate below (by code). The STREET NUMBER and ZIP are your most reliable signal — handwritten digits survive messy writing far better than cursive names — so match on those FIRST, then corroborate with the name. If a row plausibly matches NO candidate, set assigned_code to "UNMATCHED" (never force a match).

Candidate clients (order is NOT the row order):
${s.candidates.map(c => `${c.code || '(no code)'} | ${c.name} | ${c.address || ''}`).join('\n')}

Rules:
- Each candidate maps to at most ONE row; each row to at most one candidate.
- Prefer street-number + zip agreement; a clear NAME match can win even if the address differs.
- If illegible/unsure, give your best assignment but mark confidence "low"; use "UNMATCHED" only when nothing fits.
- List every candidate code you could NOT place in unplaced_candidates.
Return ONLY the structured JSON.`
}

const num = a => { const m = String(a || '').match(/\b(\d{2,6})\b/); return m ? m[1] : null }
const zip = a => { const m = String(a || '').match(/\b(3\d{4})\b/); return m ? m[1] : null }

phase('Match')
const perSheet = await parallel(SHEETS.map(s => () =>
  parallel([0, 1, 2].map(k => () =>
    agent(buildPrompt(s), { label: `match:${s.label}#${k + 1}`, phase: 'Match', schema: SCHEMA, effort: 'high' }).catch(() => null)
  )).then(passes => ({ sheet: s, passes: passes.filter(Boolean) }))
))

// ---- reconcile: majority vote per physical row across passes; confidence from agreement + digit consistency ----
function reconcile(sheet, passes) {
  // align rows by (page,row_index); collect each pass's assignment for that cell
  const cells = {}
  for (const p of passes) for (const r of (p.rows || [])) {
    const key = `${r.page}:${r.row_index}`
    ;(cells[key] = cells[key] || []).push(r)
  }
  const out = []
  for (const key of Object.keys(cells).sort()) {
    const rs = cells[key]
    const votes = {}
    for (const r of rs) votes[r.assigned_code] = (votes[r.assigned_code] || 0) + 1
    const [topCode, topN] = Object.entries(votes).sort((a, b) => b[1] - a[1])[0]
    const rep = rs.find(r => r.assigned_code === topCode) || rs[0]
    const agreement = `${topN}/${passes.length}`
    const cand = sheet.candidates.find(c => c.code === topCode)
    const digitOK = cand ? (num(rep.address_read) === num(cand.address) || zip(rep.address_read) === zip(cand.address)) : false
    let status, confidence
    if (topCode === 'UNMATCHED') { status = 'unmatched'; confidence = topN === passes.length ? 'high' : 'low' }
    else if (topN === passes.length && (digitOK || (rep.confidence === 'high'))) { status = 'matched'; confidence = 'high' }
    else { status = 'low_confidence'; confidence = 'low' }
    out.push({ page: rep.page, row_index: rep.row_index, facility_name_read: rep.facility_name_read,
      address_read: rep.address_read, matched_client_code: topCode === 'UNMATCHED' ? null : topCode,
      assignment_status: status, confidence, agent_agreement: agreement })
  }
  return out
}

const results = perSheet.filter(Boolean).map(({ sheet, passes }) => {
  const rows = passes.length ? reconcile(sheet, passes) : []
  const gazetteer_add = rows.filter(r => r.assignment_status === 'matched' && r.confidence === 'high')
    .map(r => ({ facility_name_read: r.facility_name_read, address_read: r.address_read, matched_client_code: r.matched_client_code }))
  return { label: sheet.label, dump_folder: sheet.dump_folder, wm: sheet.wm, dump_date: sheet.dump_date,
    page_urls: sheet.page_urls, local_files: sheet.local_files, candidates: sheet.candidates, rows, gazetteer_add }
})
return { window: (A && A.window) || null, sheets: results }
