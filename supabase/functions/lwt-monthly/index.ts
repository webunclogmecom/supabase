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
  overview: 'view', tickets: 'view', archive_state: 'view', download: 'view', board: 'view', suggest: 'view', load_work: 'view',
  read_invoice: 'edit', check: 'edit', generate: 'edit', record: 'edit', discard: 'edit', restore: 'edit',
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
    let detail: unknown = null; let refusedBy: unknown = null
    try { const j = JSON.parse(text); detail = j?.detail ?? null; refusedBy = j?.refused_by ?? null } catch { /* not JSON */ }
    return json({ error: 'bot_error', detail: typeof detail === 'string' ? detail : null, refused_by: refusedBy,
      message: typeof detail === 'string' ? detail : 'The report service had a problem, so nothing was done. Try again.' }, 502, cors)
  }
  const bytes = await r.arrayBuffer()
  return new Response(bytes, { status: r.status, headers: { ...cors, ...forwardedHeaders(r.headers) } })
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

  if (action !== 'overview') return relay(answer, action, cors)

  // overview also says who is asking, so the page never asks twice and never decides access itself.
  if (!answer.ok) return relay(answer, action, cors)
  let data: Record<string, unknown>
  try { data = await answer.json() } catch { return json({ error: 'bot_error', message: 'The report service sent an answer that could not be read. Try again.' }, 502, cors) }
  const canEdit = (await checkAppAction(token, 'lwt_monthly_edit')) === null
  return json({ ...data, me: { name: actor, email, can_edit: canEdit } }, 200, cors)
})
