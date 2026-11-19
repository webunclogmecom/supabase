// Standing check (Trello #227, 2026-11-19): every live GDO permit's stored PDF prints OUR number.
//
// Why: the PDF check of 2026-11-19 found 8 ACTIVE permits whose PDF is another business's permit (one Fairfield Inn
// PDF sat on two clients) and 3 files that are TIFF pictures saved as .pdf. A wrong PDF reaches the client (Field
// Portal "Permits & Frequency") and the DERM sheets; nothing noticed it for months. Fred: "New card + standing check".
//
// Reads (SELECT only) every GDO permit that is not INACTIVE and has permit_document_path, downloads the PDF from the
// public gdo-permits bucket into a TEMP folder (never this repo: client documents), reads its text with pdftotext
// (poppler) and compares the printed "GDO-0nnnnn" with gdos.gdo_number BY DIGITS (5 or 6 digits are one number).
//   FAIL  wrong_number  the PDF prints GDO numbers and none of them is ours
//   FAIL  not_a_pdf     the file does not start with %PDF (e.g. a TIFF named .pdf)
//   WARN  no_text       a scanned PDF with no text layer: cannot be checked this way
//   WARN  no_number     text but no GDO number in it
// Exit 1 on any FAIL. Positive control: at least one permit must match, or the reader itself is broken.
// CONTROL=1 swaps the first matching permit's number for another, and the check must then FAIL.
// Usage: node scripts/checks/gdo_permit_pdf_numbers.mjs   (needs SUPABASE_PAT in Supabase/.env and pdftotext on PATH)
// Prints client codes and permit numbers only, never document text.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const env = Object.fromEntries(fs.readFileSync(path.join(root, '.env'), 'utf8').split(/\r?\n/)
  .filter((l) => l.includes('=') && !l.startsWith('#'))
  .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim().replace(/^"|"$/g, '')]))
const r = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', {
  method: 'POST', headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: `select g.id, c.client_code, g.gdo_number, g.status, g.permit_document_path as p
    from public.gdos g join public.clients c on c.id = g.client_id
    where g.permit_type = 'GDO' and g.status <> 'INACTIVE' and g.permit_document_path is not null order by g.id` }) })
const rows = await r.json()
if (!Array.isArray(rows)) { console.log('query failed:', JSON.stringify(rows).slice(0, 200)); process.exit(2) }

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'gdo-pdf-check-'))
const digits = (s) => { const m = String(s || '').match(/^GDO-?0*([0-9]+)$/i); return m ? m[1] : null }
let control = process.env.CONTROL === '1'
const out = { match: 0, fail: [], warn: [] }
try {
  for (const row of rows) {
    const file = path.join(tmp, `${row.id}.pdf`)
    const res = await fetch(`https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/gdo-permits/${row.p.split('/').map(encodeURIComponent).join('/')}`)
    if (!res.ok) { out.fail.push([row, 'download_' + res.status, '']); continue }
    const buf = Buffer.from(await res.arrayBuffer())
    fs.writeFileSync(file, buf)
    if (buf.subarray(0, 4).toString('latin1') !== '%PDF') { out.fail.push([row, 'not_a_pdf', '']); continue }
    let text = ''
    try { text = execFileSync('pdftotext', ['-layout', file, '-'], { encoding: 'utf8', maxBuffer: 20e6, stdio: ['ignore', 'pipe', 'ignore'] }) } catch { /* unreadable */ }
    if (!text.trim()) { out.warn.push([row, 'no_text', '']); continue }
    const printed = [...new Set([...text.matchAll(/GDO\s*[-–]?\s*(\d{3,7})/gi)].map((m) => m[1].replace(/^0+(?=\d)/, '')))]
    if (!printed.length) { out.warn.push([row, 'no_number', '']); continue }
    let ours = digits(row.gdo_number)
    if (control && printed.includes(ours)) { ours = String(Number(ours) + 1); control = false; row.gdo_number += ' (CONTROL: checked as ' + ours + ')' }
    if (printed.includes(ours)) out.match++
    else out.fail.push([row, 'wrong_number', printed.map((d) => 'GDO-' + d.padStart(6, '0')).join(', ')])
  }
} finally {
  fs.rmSync(tmp, { recursive: true, force: true })
}
console.log(`live GDO permits with a PDF: ${rows.length} | PDF prints our number: ${out.match} | FAIL ${out.fail.length} | WARN ${out.warn.length}`)
for (const [row, why, printed] of out.fail) console.log('FAIL', why.padEnd(12), row.client_code.padEnd(9), row.gdo_number, printed ? 'PDF prints ' + printed : '')
for (const [row, why] of out.warn) console.log('WARN', why.padEnd(12), row.client_code.padEnd(9), row.gdo_number)
if (out.match === 0) { console.log('CONTROL: no permit matched at all: the reader is broken, the result means nothing'); process.exit(2) }
process.exit(out.fail.length ? 1 : 0)
