// ============================================================================
// gdo-bot-file-visit/index.ts - Edge Function
// ============================================================================
// The DERM Tracker's "File it with the bot" button (Trello xBCSvP6f, 2026-10-27). It asks the GDO
// report bot to file ONE permit of ONE visit with Miami-Dade, the way the bot dashboard's
// "process a permit by hand" form does, without anyone typing the data.
//
// Fred, 2026-10-27: "this button should be disabled until we have Jon's notification about it ...
// but we can have our side ready". So it ships OFF: until the secrets GDO_BOT_FILE_URL and
// GDO_BOT_FILE_KEY are set, `status` says enabled:false and `send` answers 503 and sends nothing.
// Turning it on = the two secrets (the bot's POST /gdo/process-one address, and the DERM app's own
// RUN_KEYS entry), a dry run, then one real visit. The app needs no change for that.
// Request (Jonathan's contract v1 + Fred 2026-10-29 "Button sends the details"): the queue's own item
// (_shared/rpa-queue-item.ts) for that visit and permit, plus requested_by.
//
// WHY AN EDGE FUNCTION. The bot's keys are personal run keys (RUN_KEYS) and a browser must never
// hold one; the bot also answers no CORS. And the rule for which permit may be sent lives once,
// here: the app only renders what `status` returns.
//
// THIS FUNCTION RECORDS NO FILING. The bot posts its result to rpa-derm-result like any other, and
// that is the only way a report reaches derm_portal_submissions. What it does write: the 20 h lease
// (real presses) and, since 2026-10-29, one row in public.gdo_bot_file_requests per run the bot
// started (its run_id from the 202). rpa-derm-result reads that row to record the run's result as a
// real filing by the person who pressed, also on a visit before the 2026-07-21 cutoff (Fred: "Yes,
// only for button presses"); a dry press is never recorded (2026-10-29_1245).
//
// Input (POST JSON):
//   { action: 'status', visit_id }                       -> { enabled, permits: [{ gdo_id, can_send, reason, sent_at }] }
//   { action: 'send', visit_id, gdo_id, dry_run: bool }  -> 202 { sent, sent_at, run_id, logged, message }
//                                                           | 200 { sent:false } already filing | 404 | 409 | 502 | 503
//
// Auth: verify_jwt = true, a signed-in staff account, and Edit in DERM Tracker (the same check as
// Record a manual filing, hr.check_app_action('record_manual_gdo_report')).
// Spec: Building Apps/DERM Tracker/docs/specs/2026-10-27-file-with-the-bot-button.md
// Check: node scripts/checks/gdo_bot_file_visit.mjs
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { isStaffEmail } from '../_shared/staff.ts'
import { checkAppAction } from '../_shared/access-check.ts'
import { toQueueItem } from '../_shared/rpa-queue-item.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
const BOT_URL = (Deno.env.get('GDO_BOT_FILE_URL') ?? '').trim()
const BOT_KEY = (Deno.env.get('GDO_BOT_FILE_KEY') ?? '').trim()
const ENABLED = BOT_URL !== '' && BOT_KEY !== ''

// The queue holds a served (visit, permit) for 20 h (rpa-derm-queue, derm_portal_leases). The same
// window decides "the bot has it", so the button and the hourly queue never both hand it over.
const LEASE_MS = 20 * 60 * 60 * 1000
const BOT_TIMEOUT_MS = 20_000

const SOON = "Coming soon: the bot's connection is not ready yet."

const ALLOWED_ORIGINS = new Set(['https://derm.unclogme.app'])
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

const etTime = (iso: string) =>
  new Date(iso).toLocaleTimeString('en-US', { timeZone: 'America/New_York', hour: 'numeric', minute: '2-digit' })

type Row = {
  visit_id: number, manifest_id: number | null, gdo_id: number | null, gdo_number: string | null,
  ticket_number: string | null, visit_date: string | null, dump_ticket_date: string | null,
  client_name: string | null, client_code: string | null, jurisdiction: string | null,
  can_record_manual: boolean | null, blocked_reason: string | null,
}
type Stamp = { gdo_id: number | null, at: string }

// The newest lease or attempt that covers this permit. A NULL gdo_id covers every permit of the
// visit, the way the queue reads a legacy lease.
const latest = (list: Stamp[], gdoId: number | null) =>
  list.filter((x) => x.gdo_id === null || x.gdo_id === gdoId).map((x) => x.at).sort().pop() ?? null

// THE RULE, once. Returns null when the permit can be sent, else the sentence for the person.
export function permitState(r: Row, leases: Stamp[], attempts: Stamp[], enabled: boolean, now = Date.now()) {
  const lease = latest(leases, r.gdo_id)
  const attempt = latest(attempts, r.gdo_id)
  // In the bot's hands = leased within 20 h and no attempt recorded since the lease.
  const sentAt = lease && now - Date.parse(lease) < LEASE_MS && (!attempt || Date.parse(lease) > Date.parse(attempt))
    ? lease : null
  let reason: string | null = null
  if (!enabled) reason = SOON
  else if (r.can_record_manual !== true) reason = r.blocked_reason ?? 'This permit cannot be sent.'
  else if (r.gdo_id === null || !r.gdo_number) reason = 'No GDO permit on file for this visit.'
  else if (!r.ticket_number) reason = 'Missing the dump ticket number.'
  else if (!r.visit_date) reason = 'Missing the cleaning date.'
  else if (sentAt) reason = `The bot has this permit since ${etTime(sentAt)}. Wait for its result.`
  return { gdo_id: r.gdo_id, can_send: reason === null, reason, sent_at: sentAt }
}

// The request to the bot's POST /gdo/process-one (Jonathan's contract v1, 2026-10-28; Fred, 2026-10-29: "Button
// sends the details"): exactly the item the hourly queue serves (_shared/rpa-queue-item.ts, built from the same
// public.v_derm_portal_fields row), plus who pressed. dry_run is the press's own, never defaulted.
// deno-lint-ignore no-explicit-any
export function toBotRequest(fields: Record<string, any>, requestedBy: string, dryRun: boolean) {
  return { ...toQueueItem(fields, dryRun), requested_by: requestedBy }
}

// The bot's answer to a press: 202 {accepted:true, run_id} started a run; 200 {accepted:false, run_id, reason}
// means that visit is already being filed. Only a started run is logged (public.gdo_bot_file_requests): its result
// is then recorded as a real filing by the person who pressed, also on a visit before 2026-07-21 (2026-10-29_1245).
const RUN_ID_RE = /^[A-Za-z0-9_.-]{1,100}$/
export function readBotAnswer(status: number, j: Record<string, unknown> | null) {
  const runId = typeof j?.run_id === 'string' && RUN_ID_RE.test(j.run_id) ? j.run_id : null
  const started = status === 202 && j?.accepted !== false
  return { runId, started, alreadyFiling: status === 200 && j?.accepted === false }
}

Deno.serve(async (req) => {
  const cors = corsHeadersFor(req.headers.get('origin'))
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405, cors)

  // ---- staff auth (same as record-manual-gdo-report) -----------------------------------------
  const authHeader = req.headers.get('Authorization') ?? ''
  if (!authHeader.startsWith('Bearer ')) return json({ error: 'unauthorized', message: 'Sign in first.' }, 401, cors)
  const token = authHeader.replace(/^Bearer\s+/i, '')
  const userClient = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } })
  const { data: userData, error: userErr } = await userClient.auth.getUser()
  const email = userData?.user?.email ?? ''
  if (userErr || !email) return json({ error: 'unauthorized', message: 'Sign in first.' }, 401, cors)
  if (!(await isStaffEmail(token, email))) return json({ error: 'forbidden', message: 'Staff account required.' }, 403, cors)

  let body: Record<string, unknown>
  try { body = await req.json() } catch { return json({ error: 'bad_request', message: 'Invalid JSON body.' }, 400, cors) }
  const action = body.action
  const visitId = Number(body.visit_id)
  if (action !== 'status' && action !== 'send') return json({ error: 'bad_request', message: "action must be 'status' or 'send'." }, 400, cors)
  if (!Number.isInteger(visitId) || visitId <= 0) return json({ error: 'bad_request', message: 'visit_id is required.' }, 400, cors)

  const denied = await checkAppAction(token, 'record_manual_gdo_report')

  // ---- what we know about this visit's permits ------------------------------------------------
  const sb = createClient(SUPABASE_URL, SERVICE_KEY, { global: { headers: { 'x-app-source': 'derm-tracker' } } })
  const [rowsQ, leasesQ, attemptsQ] = await Promise.all([
    sb.schema('derm').from('visit_gdo_our_record')
      .select('visit_id, manifest_id, gdo_id, gdo_number, ticket_number, visit_date, dump_ticket_date, client_name, client_code, jurisdiction, can_record_manual, blocked_reason')
      .eq('visit_id', visitId),
    sb.from('derm_portal_leases').select('gdo_id, leased_at').eq('visit_id', visitId),
    sb.from('derm_portal_submissions').select('gdo_id, created_at').eq('visit_id', visitId).not('dry_run', 'is', true),
  ])
  if (rowsQ.error || leasesQ.error || attemptsQ.error) {
    console.error('lookup failed:', rowsQ.error?.message, leasesQ.error?.message, attemptsQ.error?.message)
    return json({ error: 'server_error', message: 'Could not read this visit, so nothing was sent.' }, 500, cors)
  }
  const rows = (rowsQ.data ?? []) as Row[]
  const leases: Stamp[] = (leasesQ.data ?? []).map((l: { gdo_id: number | null, leased_at: string }) => ({ gdo_id: l.gdo_id, at: l.leased_at }))
  const attempts: Stamp[] = (attemptsQ.data ?? []).map((s: { gdo_id: number | null, created_at: string }) => ({ gdo_id: s.gdo_id, at: s.created_at }))

  if (action === 'status') {
    const permits = rows.map((r) => {
      const st = permitState(r, leases, attempts, ENABLED)
      return denied && st.can_send ? { ...st, can_send: false, reason: denied.message } : st
    })
    return json({ enabled: ENABLED, permits }, 200, cors)
  }

  // ---- send ----------------------------------------------------------------------------------
  if (!ENABLED) return json({ error: 'not_enabled', message: SOON }, 503, cors)
  if (denied) return json({ error: 'no_access', message: denied.message }, denied.status, cors)
  const gdoId = Number(body.gdo_id)
  if (!Number.isInteger(gdoId) || gdoId <= 0) return json({ error: 'bad_request', message: 'gdo_id is required.' }, 400, cors)
  // The bot's own rule: an omitted dry_run is never read as "for real".
  if (typeof body.dry_run !== 'boolean') return json({ error: 'bad_request', message: 'dry_run must be true or false.' }, 400, cors)
  const dryRun = body.dry_run
  const row = rows.find((r) => r.gdo_id === gdoId)
  if (!row) return json({ error: 'not_found', message: 'That permit is not on this visit.' }, 404, cors)
  const st = permitState(row, leases, attempts, ENABLED)
  if (!st.can_send) return json({ error: 'not_sendable', message: st.reason, sent_at: st.sent_at }, 409, cors)

  // The row the bot files: the queue's own source view, the same visit, permit and manifest as the page showed.
  let fq = sb.from('v_derm_portal_fields').select('*').eq('visit_id', visitId).eq('gdo_id', gdoId)
  if (row.manifest_id != null) fq = fq.eq('manifest_id', row.manifest_id)
  const { data: fieldRows, error: fErr } = await fq.limit(1)
  if (fErr) {
    console.error('fields lookup failed:', fErr.message)
    return json({ error: 'server_error', message: 'Could not read this visit, so nothing was sent.' }, 500, cors)
  }
  const fields = fieldRows?.[0]
  if (!fields) return json({ error: 'not_found', message: 'That permit is not on this visit.' }, 404, cors)

  let answered = false
  let botOk = false
  let botStatus = 0
  let botMessage = ''
  // deno-lint-ignore no-explicit-any
  let botJson: Record<string, any> | null = null
  try {
    const r = await fetch(BOT_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-run-key': BOT_KEY },
      body: JSON.stringify(toBotRequest(fields, email, dryRun)),
      signal: AbortSignal.timeout(BOT_TIMEOUT_MS),
    })
    answered = true
    botOk = r.ok
    botStatus = r.status
    const text = await r.text().catch(() => '')
    try { botJson = JSON.parse(text); botMessage = String(botJson?.detail ?? botJson?.reason ?? botJson?.message ?? '') } catch { botMessage = text.slice(0, 300) }
    if (!botOk) console.error(`bot refused visit ${visitId} permit ${gdoId}: HTTP ${r.status} ${botMessage}`)
  } catch (e) {
    console.error(`bot did not answer for visit ${visitId} permit ${gdoId}: ${(e as Error).message}`)
  }

  if (answered && !botOk) {
    return json({ error: 'bot_refused', message: botMessage ? `The bot refused: ${botMessage}` : 'The bot refused this permit.' }, 502, cors)
  }

  // Accepted, or no answer (the bot may be filing it): a real run holds the hourly queue on this
  // permit for 20 h so the bot cannot also file it from there. A dry run files nothing, so no lease.
  const sentAt = new Date().toISOString()
  if (!dryRun) {
    const { error: leaseErr } = await sb.from('derm_portal_leases')
      .upsert({ visit_id: visitId, gdo_id: gdoId, leased_at: sentAt }, { onConflict: 'visit_id,gdo_id' })
    if (leaseErr) console.error('lease upsert failed (the bot has it anyway):', leaseErr.message)
  }
  if (!answered) {
    return json({ error: 'bot_no_answer', message: 'The bot did not answer in time. Check the bot dashboard before pressing again.', sent_at: dryRun ? null : sentAt }, 502, cors)
  }

  const ans = readBotAnswer(botStatus, botJson)
  if (ans.alreadyFiling) {
    return json({ sent: false, run_id: ans.runId, sent_at: sentAt, message: 'The bot is already filing this permit. Wait for its result.' }, 200, cors)
  }
  // Log the run the bot started. Without this row, rpa-derm-result records the result of an older visit as a dry
  // run and names nobody as the filer, so a failure here is said, not swallowed.
  let logged = false
  if (ans.started && ans.runId) {
    const { error: logErr } = await sb.from('gdo_bot_file_requests')
      .insert({ visit_id: visitId, gdo_id: gdoId, run_id: ans.runId, dry_run: dryRun, requested_by: email })
    if (logErr) console.error(`press log failed for visit ${visitId} permit ${gdoId} run ${ans.runId}:`, logErr.message)
    else logged = true
  } else {
    console.error(`bot answered HTTP ${botStatus} for visit ${visitId} permit ${gdoId} without a usable run_id`)
  }
  const notLogged = logged ? '' : ' It could not be logged here, so tell Fred before pressing again.'
  return json({
    sent: true, dry_run: dryRun, sent_at: sentAt, run_id: ans.runId, logged,
    message: (dryRun
      ? 'Dry run sent to the bot. It opens the portal and files nothing.'
      : `Sent to the bot at ${etTime(sentAt)}. The report shows here once the county confirms.`) + notLogged,
  }, 202, cors)
})
