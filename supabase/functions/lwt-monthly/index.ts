// ============================================================================
// lwt-monthly/index.ts - Edge Function
// ============================================================================
// The server side of the DERM Tracker's Monthly Report page (Trello EOnFKqSK, 2026-11-05). Fred: "adding the monthly
// report to the apps ... instead of using the dashboard made by Jon".
//
// The GDO report bot stays the engine: it reads the county's invoice, runs the checks and builds the county's Excel
// file. This function is the one door between the page and the bot, the same shape as gdo-bot-file-visit:
//   - the browser never holds a run key; the bot answers no CORS anyway;
//   - who may do what is decided here, per action, by DERM Tracker access (hr.check_app_action, as the caller);
//   - the name on a county record comes from the session, never from the request. Real filings on record today say a
//     shared mailbox or a contractor because that field used to be typed.
//
// 🛑 A FIXED LIST OF ACTIONS, NEVER A PATH FROM THE CALLER. A proxy that takes a path would hand every staff browser
// every bot route, the filing routes included. Adding an action means adding it to botRequest below on purpose.
// 🛑 A PERSON CANNOT SEND dry_run OR filed_by_email. record always sends dry_run false and the session's email. The page
// has no test control, like Auto file. Rehearse against the bot directly, with a person's key, from a script.
// 🛑 BODIES HOLD CLIENT NAMES AND ADDRESSES: never log one. Statuses and action names only.
// The invoice travels as raw bytes, never base64 (Supabase CLAUDE.md, the out-of-memory trap at about 5 MB).
//
// Input: POST JSON { action, ... }, except read_invoice: POST ?action=read_invoice with the file as the raw body.
//   overview                                 { current, rows, me: { name, email, can_edit } }
//   tickets                                  what /monthly/fetch?unreported=1 answers
//   archive_state                            what /monthly/archive answers
//   read_invoice (raw body, 10 MB at most)   what /monthly/invoice-parse answers
//   check { payload }                        { html, findings } + x-preview-token and the x-preview-* summary headers
//   generate { payload }                     the .xlsx + X-Filing-Id, X-Filing-Tickets, X-Filing-List
//   download { id }                          the saved .xlsx, byte for byte
//   download_pdf { id }                      that same .xlsx printed to PDF by the pdf-service (Trello #238, 2026-11-20)
//   send_email { id, format, expect_tickets }  emails that report to the county as PDF or Excel, then records it as
//                                            filed (Trello #238, 2026-11-21); { id, format, test_to } sends a test copy to
//                                            an internal address only and records nothing. { sent, to, recorded, record }
//   record { id, expect_tickets }            the bot's sentence; it refuses a row that moved since it was read
//   discard { id, reason, reason_text? }     restore { id }
//   archive { ticket, reason, reason_text?, duplicate_of?, invoice_tickets?, known_tickets?, ticked? }   unarchive { ticket }
//   board { tickets, from?, to? }            derm.lwt_board, as the caller
//   suggest { dump_date, vehicle_id? }       derm.lwt_stop_suggestions, as the caller
//   save_size { property_id, gallons }       derm.lwt_save_trap_size, as the caller
//   load_work { period }                     { work, saved_by, saved_at } or { work: null }
//   save_work { period, work }               { saved_at }; last save wins (ponytail: 2 or 3 people, once a month)
//
// Auth: verify_jwt = true, a signed-in staff account, then View or Edit in DERM Tracker per action.
// Spec: Building Apps/DERM Tracker/docs/specs/2026-11-05-monthly-report-in-the-app.md
// Check: node scripts/checks/lwt_monthly_edge.mjs
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { isStaffEmail } from '../_shared/staff.ts'
import { checkAppAction } from '../_shared/access-check.ts'
import { countyLetterHtml, countyLetterText, countySubject } from './letter.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
const BOT_KEY = (Deno.env.get('GDO_BOT_FILE_KEY') ?? '').trim()
const BOT_ORIGIN = (() => { try { return new URL((Deno.env.get('GDO_BOT_FILE_URL') ?? '').trim()).origin } catch { return '' } })()
const BOT_READY = BOT_ORIGIN !== '' && BOT_KEY !== ''

const WORK_BUCKET = 'lwt-monthly-work'
const MAX_INVOICE_BYTES = 10 * 1024 * 1024   // the bot's own cap
const MAX_WORK_BYTES = 4_500_000             // the bucket allows 5 MB
const BOT_TIMEOUT_MS = 120_000               // a scanned invoice takes seconds on OCR; the platform stops at 150 s
const PDF_SERVICE_URL = (Deno.env.get('PDF_SERVICE_URL') ?? '').trim().replace(/\/$/, '')
const PDF_SERVICE_API_KEY = (Deno.env.get('PDF_SERVICE_API_KEY') ?? '').trim()
const PDF_TIMEOUT_MS = 100_000               // the pdf-service gives LibreOffice 90 s
// The county email (Trello #238). Fred, 2026-11-20: sent from contact@unclogme.com, so the county's replies (its payment link
// and invoice) reach the office inbox. The recipient is public.app_config 'lwt_county_email', never the caller's.
const RESEND_API_KEY = (Deno.env.get('RESEND_API_KEY') ?? '').trim()
const COUNTY_FROM = 'UnclogMe <contact@unclogme.com>'
const COUNTY_REPLY_TO = 'contact@unclogme.com'
const TEST_TO_RE = /^[^@\s]+@(ayache\.com|unclogme\.com)$/i   // a test copy goes to one of ours, never anywhere else
const MAX_ATTACH_BYTES = 8 * 1024 * 1024
const EMAIL_TIMEOUT_MS = 30_000

const ALLOWED_ORIGINS = new Set(['https://derm.unclogme.app', 'https://ops.unclogme.app'])
function corsHeadersFor(origin: string | null): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': origin && ALLOWED_ORIGINS.has(origin) ? origin : 'https://derm.unclogme.app',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, content-type, x-client-info, apikey, x-app-source',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  }
}
function json(body: Record<string, unknown>, status: number, cors: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
}

// The level each action needs. An action missing here does not exist.
const LEVEL: Record<string, 'view' | 'edit'> = {
  overview: 'view', tickets: 'view', archive_state: 'view', download: 'view', download_pdf: 'view', board: 'view', suggest: 'view', load_work: 'view',
  read_invoice: 'edit', check: 'edit', generate: 'edit', record: 'edit', discard: 'edit', restore: 'edit', send_email: 'edit',
  archive: 'edit', unarchive: 'edit', save_size: 'edit', save_work: 'edit',
}

class BadRequest extends Error {}
const rowId = (v: unknown): string => {
  const s = String(v ?? '')
  if (!/^[0-9]{1,12}$/.test(s)) throw new BadRequest('A filing id is required.')
  return s
}
const objectPayload = (v: unknown): Record<string, unknown> => {
  if (v === null || typeof v !== 'object' || Array.isArray(v)) throw new BadRequest('The report data is missing.')
  return v as Record<string, unknown>
}

// THE LIST, once: what each action may ask of the bot. Nothing from the caller reaches a path except a checked number.
export function botRequest(action: string, b: Record<string, unknown>, sessionEmail: string): { method: string, path: string, json?: unknown } | null {
  switch (action) {
    case 'overview': return { method: 'GET', path: '/dashboard/monthly/data' }
    case 'tickets': return { method: 'GET', path: '/monthly/fetch?unreported=1' }
    case 'archive_state': return { method: 'GET', path: '/monthly/archive' }
    case 'check': return { method: 'POST', path: '/monthly/preview', json: objectPayload(b.payload) }
    case 'generate': return { method: 'POST', path: '/monthly/generate', json: objectPayload(b.payload) }
    case 'download': return { method: 'GET', path: `/monthly/filings/${rowId(b.id)}/report` }
    case 'download_pdf': return { method: 'GET', path: `/monthly/filings/${rowId(b.id)}/report` }
    case 'record': {
      if ('filed_by_email' in b || 'dry_run' in b) throw new BadRequest('The name on a filing comes from the sign-in, and this page does not rehearse.')
      if (!Array.isArray(b.expect_tickets) || b.expect_tickets.length === 0) throw new BadRequest('Send the list of tickets you were shown.')
      return { method: 'POST', path: '/monthly/mark-filed-saved', json: { id: Number(rowId(b.id)), filed_by_email: sessionEmail, dry_run: false, expect_tickets: b.expect_tickets } }
    }
    case 'discard': return { method: 'POST', path: `/monthly/filings/${rowId(b.id)}/discard`, json: { reason: b.reason, reason_text: b.reason_text } }
    case 'restore': return { method: 'POST', path: `/monthly/filings/${rowId(b.id)}/restore` }
    case 'archive': return { method: 'POST', path: '/monthly/archive', json: {
      ticket: b.ticket, reason: b.reason, reason_text: b.reason_text, duplicate_of: b.duplicate_of,
      invoice_tickets: b.invoice_tickets, known_tickets: b.known_tickets, ticked: b.ticked } }
    case 'unarchive': return { method: 'POST', path: '/monthly/restore', json: { ticket: b.ticket } }
    default: return null
  }
}

// What travels back from the bot. Everything else (its server, its cookies) stays there.
export function forwardedHeaders(h: Headers): Record<string, string> {
  const out: Record<string, string> = {}
  const exposed: string[] = []
  h.forEach((value, name) => {
    const n = name.toLowerCase()
    if (n === 'content-type') out[name] = value
    else if (n === 'content-disposition' || n.startsWith('x-preview') || n.startsWith('x-filing')) { out[name] = value; exposed.push(name) }
  })
  if (exposed.length) out['Access-Control-Expose-Headers'] = exposed.join(', ')
  return out
}

// A bot answer becomes our answer. A 401 from the bot means OUR key is wrong: passing it on would read as "you are signed
// out", so it is said in words. Never retried: the bot locks an address out after 10 bad keys in 15 minutes.
async function relay(r: Response, action: string, cors: Record<string, string>): Promise<Response> {
  if (r.status === 401) {
    console.error(`lwt-monthly ${action}: the bot refused our key`)
    return json({ error: 'bot_key', message: 'The report service refused our key, so nothing was done. Tell Fred.' }, 502, cors)
  }
  if (r.status >= 500) {
    const text = await r.text().catch(() => '')
    console.error(`lwt-monthly ${action}: bot HTTP ${r.status}`)
    let detail: unknown = null; let refusedBy: unknown = null; let noAnswer = false
    try { const j = JSON.parse(text); detail = j?.detail ?? null; refusedBy = j?.refused_by ?? null; noAnswer = j?.no_answer === true } catch { /* not JSON */ }
    // no_answer (bot, 2026-11-20): a record whose answer was lost MAY have landed, so a page can say so instead of "refused".
    return json({ error: noAnswer ? 'bot_no_answer' : 'bot_error', no_answer: noAnswer, detail: typeof detail === 'string' ? detail : null, refused_by: refusedBy,
      message: typeof detail === 'string' ? detail : 'The report service had a problem, so nothing was done. Try again.' }, 502, cors)
  }
  const bytes = await r.arrayBuffer()
  return new Response(bytes, { status: r.status, headers: { ...cors, ...forwardedHeaders(r.headers) } })
}

// download_pdf: the bot's saved .xlsx, printed to PDF by the pdf-service's LibreOffice (POST /convert/xlsx-to-pdf).
// One source of truth: the PDF is the same file printed, never a redraw of the county's form. The bytes travel raw.
type PdfOut = { ok: true, bytes: ArrayBuffer, name: string } | { ok: false, status: number, error: string, message: string }
async function makePdf(xlsx: ArrayBuffer, name: string): Promise<PdfOut> {
  if (!PDF_SERVICE_URL || !PDF_SERVICE_API_KEY) {
    return { ok: false, status: 503, error: 'pdf_not_enabled', message: 'The PDF maker is not set up. Download the Excel file instead.' }
  }
  let up: Response
  try {
    up = await fetch(`${PDF_SERVICE_URL}/convert/xlsx-to-pdf?filename=${encodeURIComponent(name)}`, {
      method: 'POST', body: xlsx, signal: AbortSignal.timeout(PDF_TIMEOUT_MS),
      headers: { Authorization: `Bearer ${PDF_SERVICE_API_KEY}`, 'Content-Type': 'application/octet-stream' },
    })
  } catch (e) {
    console.error(`lwt-monthly pdf: no answer from the pdf-service: ${(e as Error).name}`)
    return { ok: false, status: 504, error: 'pdf_no_answer', message: 'The PDF took too long to make. Try again, or download the Excel file.' }
  }
  if (!up.ok) {
    let code = ''
    try { code = String((await up.json())?.error ?? '') } catch { /* not JSON */ }
    console.error(`lwt-monthly pdf: pdf-service HTTP ${up.status} ${code}`)
    if (code === 'converter_busy') return { ok: false, status: 503, error: 'pdf_busy', message: 'Another PDF is being made right now. Try again in a moment.' }
    return { ok: false, status: 502, error: 'pdf_failed', message: 'The PDF could not be made. Download the Excel file instead, and tell Fred.' }
  }
  const outName = /filename="([^"]+)"/.exec(up.headers.get('content-disposition') ?? '')?.[1] ?? 'report.pdf'
  return { ok: true, bytes: await up.arrayBuffer(), name: outName }
}
async function toPdf(answer: Response, cors: Record<string, string>): Promise<Response> {
  if (!answer.ok) return relay(answer, 'download_pdf', cors)
  const xlsx = await answer.arrayBuffer()
  const name = /filename="?([^";]+)"?/i.exec(answer.headers.get('content-disposition') ?? '')?.[1] ?? 'report.xlsx'
  const p = await makePdf(xlsx, name)
  if (!p.ok) return json({ error: p.error, message: p.message }, p.status, cors)
  return new Response(p.bytes, { status: 200, headers: {
    ...cors, 'Content-Type': 'application/pdf', 'Content-Disposition': `attachment; filename="${p.name}"`,
    'Access-Control-Expose-Headers': 'Content-Disposition' } })
}

// ---- send_email (Trello #238, 2026-11-21) ----------------------------------------------------------------------------------
// Fred: "when sending the email depending on the selected file format that's how's gonna be attached to the email (pdf or
// excel)", and "once we have that we don't need the button "Record as filed"". So: the report's saved file (printed to PDF
// when PDF is picked) goes to the county from contact@unclogme.com, then the report is recorded as filed with the session's
// email, through the same bot call as the record action.
// 🛑 Facts in the letter come from the filing history (the bot's own row), never from the page. The recipient comes from
//    public.app_config, never from the request: a caller can only ask for a TEST copy, and only to @ayache.com or
//    @unclogme.com (refused otherwise, never ignored, or a typo would reach the county). A test records nothing.
// 🛑 Send first, record second: a report recorded but not sent is worse than one sent and not recorded (that one keeps
//    Record as filed on its history row). The answer says which happened.
const monthName = (ym: string) => new Intl.DateTimeFormat('en-US', { month: 'long', year: 'numeric', timeZone: 'UTC' })
  .format(new Date(Date.UTC(+ym.slice(0, 4), +ym.slice(5, 7) - 1, 15)))
function base64(buf: ArrayBuffer): string {
  const u = new Uint8Array(buf)
  let bin = ''
  for (let i = 0; i < u.length; i += 8192) bin += String.fromCharCode(...u.subarray(i, i + 8192))
  return btoa(bin)
}

async function sendEmail(b: Record<string, unknown>, email: string, botHeaders: Record<string, string>,
  // deno-lint-ignore no-explicit-any
  sb: any, cors: Record<string, string>): Promise<Response> {
  const bad = (message: string, error = 'bad_request', status = 400) => json({ error, message }, status, cors)
  let id: string
  try { id = rowId(b.id) } catch (e) { return bad((e as Error).message) }
  const format = b.format === 'pdf' || b.format === 'xlsx' ? b.format : null
  if (!format) return bad('Pick PDF or Excel.')
  if ('to' in b || 'filed_by_email' in b || 'dry_run' in b) return bad('The recipient and the name on the filing are not set from this page.')
  let testTo: string | null = null
  if ('test_to' in b) {
    testTo = typeof b.test_to === 'string' ? b.test_to.trim().toLowerCase() : ''
    if (!TEST_TO_RE.test(testTo)) return bad('A test email may only go to an @ayache.com or @unclogme.com address. Nothing was sent.', 'bad_test_to')
  }
  if (!testTo && (!Array.isArray(b.expect_tickets) || b.expect_tickets.length === 0)) return bad('Send the list of tickets you were shown.')
  if (!RESEND_API_KEY) return bad('Email is not set up, so nothing was sent. Download the file and email it yourself.', 'email_not_configured', 503)

  let to = testTo
  if (!to) {
    const { data, error } = await sb.from('app_config').select('value').eq('key', 'lwt_county_email').maybeSingle()
    if (error) return bad('The county\'s email address could not be read, so nothing was sent. Try again.', 'server_error', 500)
    to = String(data?.value ?? '').trim()
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) return bad('We do not have the county\'s email address yet, so nothing was sent.', 'no_county_email', 409)
  }

  const call = (path: string, init: RequestInit = {}) =>
    fetch(BOT_ORIGIN + path, { ...init, headers: { ...botHeaders, ...(init.headers ?? {}) }, signal: AbortSignal.timeout(BOT_TIMEOUT_MS) })
  let row: Record<string, unknown> | undefined
  let file: Response
  try {
    const ov = await call('/dashboard/monthly/data')
    if (!ov.ok) return relay(ov, 'send_email', cors)
    const rows = (await ov.json())?.rows
    row = Array.isArray(rows) ? rows.find((x: Record<string, unknown>) => String(x?.id) === id) : undefined
    if (!row) return bad('That report is not in the filing history, so nothing was sent.', 'not_found', 404)
    if (!testTo && (row.filed || row.discarded)) return bad('That report is already recorded as filed or discarded, so nothing was sent.', 'already_filed', 409)
    file = await call(`/monthly/filings/${id}/report`)
  } catch (e) {
    console.error(`lwt-monthly send_email: no answer from the bot: ${(e as Error).name}`)
    return bad('The report service did not answer, so nothing was sent. Try again.', 'bot_no_answer', 502)
  }
  if (!file.ok) return relay(file, 'send_email', cors)
  const ym = String(row.ym ?? '')
  if (!PERIOD_RE.test(ym)) return bad('The report service gave a month that could not be read, so nothing was sent.', 'bot_error', 502)
  let bytes = await file.arrayBuffer()
  if (format === 'pdf') {
    const p = await makePdf(bytes, `LWT_report_${ym}.xlsx`)
    if (!p.ok) return bad(`Nothing was sent: the PDF could not be made. ${p.error === 'pdf_busy' ? 'Try again in a moment, or' : 'Try again, or'} pick Excel to send the spreadsheet.`, p.error, p.status)
    bytes = p.bytes
  }
  if (bytes.byteLength === 0 || bytes.byteLength > MAX_ATTACH_BYTES) return bad('The file is empty or too big to email, so nothing was sent. Tell Fred.', 'bad_file', 502)
  const fileName = `LWT_report_${ym}.${format}`
  const letter = { month: monthName(ym), tickets: Number(row.ticket_count) || 0, gallons: String(row.gallons ?? ''),
    invoice: typeof row.invoice_id === 'string' && row.invoice_id ? row.invoice_id : null, fileName, format, testTo } as const

  let resendId: string | null = null
  try {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST', signal: AbortSignal.timeout(EMAIL_TIMEOUT_MS),
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json',
        // One county email per report and file type for 24 hours, so a second press cannot send it twice.
        'Idempotency-Key': testTo ? `lwt-test:${id}:${format}:${crypto.randomUUID()}` : `lwt-county:${id}:${format}` },
      body: JSON.stringify({ from: COUNTY_FROM, to: [to], reply_to: COUNTY_REPLY_TO, subject: countySubject(letter),
        html: countyLetterHtml(letter), text: countyLetterText(letter), attachments: [{ filename: fileName, content: base64(bytes) }] }),
    })
    const j = await r.json().catch(() => ({}))
    if (!r.ok || typeof j?.id !== 'string') {
      console.error(`lwt-monthly send_email: Resend HTTP ${r.status}`)
      return bad('The email service refused the email, so nothing was sent. Try again, or download the file and email it yourself.', 'email_refused', 502)
    }
    resendId = j.id
  } catch (e) {
    console.error(`lwt-monthly send_email: no answer from Resend: ${(e as Error).name}`)
    return bad('The email service did not answer. It may have gone: check contact@unclogme.com before sending again.', 'email_no_answer', 502)
  }

  const { data: logged, error: logErr } = await sb.schema('derm').from('lwt_monthly_sends').insert({
    filing_id: Number(id), period: ym, file_format: format, file_name: fileName, file_bytes: bytes.byteLength, to_email: to,
    is_test: !!testTo, resend_email_id: resendId, sent_by_email: email }).select('id').single()
  if (logErr) console.error('lwt-monthly send_email: sent but not logged:', logErr.message)
  if (testTo) return json({ sent: true, test: true, to, resend_id: resendId }, 200, cors)

  // Recorded as filed through the record action's own bot call (the session's email, dry_run false, the ticket list).
  const spec = botRequest('record', { id, expect_tickets: b.expect_tickets }, email)!
  let status = 0, said = ''
  try {
    const rec = await call(spec.path, { method: spec.method, headers: { 'content-type': 'application/json' }, body: JSON.stringify(spec.json) })
    status = rec.status
    said = await rec.text()
  } catch (e) {
    console.error(`lwt-monthly send_email: record got no answer: ${(e as Error).name}`)
  }
  // A 2xx is not a record by itself: the bot says what happened in `said` (recorded, already, ...), as the page's own
  // record reads it (recordOutcome in the shared monthly rules).
  let state = ''
  try { const sd = JSON.parse(said)?.said; state = sd && sd.dry_run === false ? String(sd.state ?? '') : '' } catch { /* not JSON */ }
  const recorded = status >= 200 && status < 300 && state === 'recorded'
  if (logged?.id) {
    const { error } = await sb.schema('derm').from('lwt_monthly_sends')
      .update({ recorded, record_note: recorded ? null : `record HTTP ${status || 'no answer'}${state ? ` ${state}` : ''}` }).eq('id', logged.id)
    if (error) console.error('lwt-monthly send_email: record result not logged:', error.message)
  }
  return json({ sent: true, to, resend_id: resendId, recorded, record: { status, body: said } }, 200, cors)
}

// A person's name for the bot's ledger ("Handled by"). The bot keeps letters, digits, - and _ only, and honours this header
// only from the DERM app's key (bot commit after 2026-11-05; ignored harmlessly before it).
const firstName = (fullName: string | null | undefined, email: string) =>
  ((fullName ?? '').trim().split(/\s+/)[0] || email.split('@')[0]).replace(/[^A-Za-z0-9_-]/g, '')

// A database read or write AS THE CALLER, so hr.fn_require_app and hr.fn_check_app see the real person.
async function rpcAsCaller(token: string, fn: string, args: Record<string, unknown>, cors: Record<string, string>): Promise<Response> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'Content-Profile': 'derm', 'x-app-source': 'derm-tracker' },
    body: JSON.stringify(args),
  })
  const text = await r.text()
  if (r.ok) return new Response(text, { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } })
  let j: Record<string, unknown> = {}
  try { j = JSON.parse(text) } catch { /* not JSON */ }
  console.error(`lwt-monthly ${fn}: HTTP ${r.status} ${String(j.code ?? '')}`)
  if (j.code === '42501') return json({ error: 'no_access', message: String(j.message ?? 'You do not have access to do this.') }, 403, cors)
  if (j.code === '22023' || j.code === 'P0002') return json({ error: 'refused', message: String(j.message ?? 'That was refused.') }, 400, cors)
  return json({ error: 'server_error', message: 'The database could not answer, so nothing was changed. Try again.' }, 500, cors)
}

const PERIOD_RE = /^\d{4}-(0[1-9]|1[0-2])$/

Deno.serve(async (req) => {
  const cors = corsHeadersFor(req.headers.get('origin'))
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405, cors)

  // ---- staff auth (same as gdo-bot-file-visit) ------------------------------------------------
  const authHeader = req.headers.get('Authorization') ?? ''
  if (!authHeader.startsWith('Bearer ')) return json({ error: 'unauthorized', message: 'Sign in first.' }, 401, cors)
  const token = authHeader.replace(/^Bearer\s+/i, '')
  const userClient = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } })
  const { data: userData, error: userErr } = await userClient.auth.getUser()
  const email = userData?.user?.email ?? ''
  if (userErr || !email) return json({ error: 'unauthorized', message: 'Sign in first.' }, 401, cors)
  if (!(await isStaffEmail(token, email))) return json({ error: 'forbidden', message: 'Staff account required.' }, 403, cors)

  // ---- which action -----------------------------------------------------------------------------
  const queryAction = new URL(req.url).searchParams.get('action')
  let body: Record<string, unknown> = {}
  let action = queryAction ?? ''
  if (queryAction !== 'read_invoice') {
    try {
      const parsed = await req.json()
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('not an object')
      body = parsed
    } catch { return json({ error: 'bad_request', message: 'Invalid JSON body.' }, 400, cors) }
    action = String(body.action ?? '')
  }
  const level = Object.hasOwn(LEVEL, action) ? LEVEL[action] : null
  if (!level) return json({ error: 'bad_request', message: 'Unknown action.' }, 400, cors)

  // ---- access: the database decides, as the caller ---------------------------------------------
  const denied = await checkAppAction(token, level === 'edit' ? 'lwt_monthly_edit' : 'lwt_monthly_view')
  if (denied) return json({ error: 'no_access', message: denied.message }, denied.status, cors)

  const sb = createClient(SUPABASE_URL, SERVICE_KEY, { global: { headers: { 'x-app-source': 'derm-tracker' } } })

  // ---- our own database, as the caller ----------------------------------------------------------
  if (action === 'board') {
    if (!Array.isArray(body.tickets)) return json({ error: 'bad_request', message: 'Send the list of tickets.' }, 400, cors)
    return rpcAsCaller(token, 'lwt_board', { p_tickets: body.tickets, p_from: body.from ?? null, p_to: body.to ?? null }, cors)
  }
  if (action === 'suggest') return rpcAsCaller(token, 'lwt_stop_suggestions', { p_dump_date: body.dump_date ?? null, p_vehicle_id: body.vehicle_id ?? null }, cors)
  if (action === 'save_size') return rpcAsCaller(token, 'lwt_save_trap_size', { p_property_id: body.property_id ?? null, p_gallons: body.gallons ?? null }, cors)

  // ---- the work in progress ---------------------------------------------------------------------
  if (action === 'load_work' || action === 'save_work') {
    const period = String(body.period ?? '')
    if (!PERIOD_RE.test(period)) return json({ error: 'bad_request', message: 'A report month is required.' }, 400, cors)
    const path = `${period}.json`
    if (action === 'load_work') {
      const { data, error } = await sb.storage.from(WORK_BUCKET).download(path)
      if (error) {
        // deno-lint-ignore no-explicit-any
        const status = (error as any)?.originalError?.status ?? (error as any)?.status ?? (error as any)?.statusCode
        if (status === 404 || status === 400 || /not.?found/i.test(error.message ?? '')) return json({ work: null }, 200, cors)
        console.error('lwt-monthly load_work failed:', error.message)
        return json({ error: 'server_error', message: 'The saved work could not be read. Try again.' }, 500, cors)
      }
      return new Response(await data.text(), { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } })
    }
    const { data: person } = await sb.from('employees').select('full_name').ilike('email', email.replace(/[%_\\]/g, '\\$&')).limit(1)
    const savedAt = new Date().toISOString()
    const text = JSON.stringify({ work: body.work ?? null, saved_by: firstName(person?.[0]?.full_name, email), saved_at: savedAt })
    if (text.length > MAX_WORK_BYTES) return json({ error: 'too_large', message: 'This month is too big to save. Tell Fred.' }, 413, cors)
    const { error } = await sb.storage.from(WORK_BUCKET).upload(path, new Blob([text], { type: 'application/json' }), { upsert: true, contentType: 'application/json' })
    if (error) {
      console.error('lwt-monthly save_work failed:', error.message)
      return json({ error: 'server_error', message: 'Your work could not be saved. Try again before closing this page.' }, 500, cors)
    }
    return json({ saved_at: savedAt }, 200, cors)
  }

  // ---- the bot ------------------------------------------------------------------------------------
  if (!BOT_READY) return json({ error: 'not_enabled', message: "The report service's connection is not set up." }, 503, cors)

  const { data: who } = await sb.from('employees').select('full_name').ilike('email', email.replace(/[%_\\]/g, '\\$&')).limit(1)
  const actor = firstName(who?.[0]?.full_name, email)
  const headers: Record<string, string> = { 'x-run-key': BOT_KEY, 'x-acting-user': actor }

  if (action === 'send_email') return sendEmail(body, email, headers, sb, cors)

  let method = 'POST', path = '/monthly/invoice-parse'
  let outBody: BodyInit | undefined
  if (action === 'read_invoice') {
    const bytes = await req.arrayBuffer()
    if (bytes.byteLength === 0) return json({ error: 'bad_request', message: 'The file is empty.' }, 400, cors)
    if (bytes.byteLength > MAX_INVOICE_BYTES) return json({ error: 'too_large', message: 'That file is over 10 MB. Use the PDF from the county.' }, 413, cors)
    headers['content-type'] = 'application/octet-stream'
    outBody = bytes
  } else {
    let spec
    try { spec = botRequest(action, body, email) } catch (e) {
      if (e instanceof BadRequest) return json({ error: 'bad_request', message: e.message }, 400, cors)
      throw e
    }
    if (!spec) return json({ error: 'bad_request', message: 'Unknown action.' }, 400, cors)
    method = spec.method; path = spec.path
    if (spec.json !== undefined) { headers['content-type'] = 'application/json'; outBody = JSON.stringify(spec.json) }
  }

  let answer: Response
  try {
    answer = await fetch(BOT_ORIGIN + path, { method, headers, body: outBody, signal: AbortSignal.timeout(BOT_TIMEOUT_MS) })
  } catch (e) {
    console.error(`lwt-monthly ${action}: no answer from the bot: ${(e as Error).name}`)
    const maybeDone = action === 'generate' || action === 'record'
    return json({ error: 'bot_no_answer', message: maybeDone
      ? 'The report service did not answer. Check the filing history before pressing again.'
      : 'The report service did not answer. Nothing changed. Try again.' }, 502, cors)
  }

  if (action === 'download_pdf') return toPdf(answer, cors)
  if (action !== 'overview') return relay(answer, action, cors)

  // overview also says who is asking, so the page never asks twice and never decides access itself.
  if (!answer.ok) return relay(answer, action, cors)
  let data: Record<string, unknown>
  try { data = await answer.json() } catch { return json({ error: 'bot_error', message: 'The report service sent an answer that could not be read. Try again.' }, 502, cors) }
  const canEdit = (await checkAppAction(token, 'lwt_monthly_edit')) === null
  const { data: cfg } = await sb.from('app_config').select('value').eq('key', 'lwt_county_email').maybeSingle()
  const county = String(cfg?.value ?? '').trim()
  return json({ ...data, me: { name: actor, email, can_edit: canEdit }, county_email: county || null }, 200, cors)
})
