// ============================================================================
// rpa-derm-result/index.ts — Edge Function
// ============================================================================
// Write endpoint for Jonathan's GDO Online Reporting bot: "here is what happened."
// Work key = visit_id (the serviced visit reported); manifest_id is optional context.
// Contract: docs/handoffs/2026-07-21_rpa_bot_reply_to_john.md.
//
// POST /functions/v1/rpa-derm-result
// Body: { visit_id, manifest_id?, run_id, status, retryable, failure_reason?,
//         attempted_at (ISO 8601), portal_confirmation?,
//         screenshot? (base64 JPEG, max 5MB decoded),
//         screenshot_missing_reason?, dry_run? }
//   or, for a filing made on the bot dashboard ("Add a report by hand"), no visit_id and
//   manual_entry: { created_by, gdo_number, ticket_number, service_date, dump_date?, why? }
//   -> recordManualEntry (2026-10-26), see docs/reference/gdo-report-bot.md section 10.
//
// Rules enforced HERE (not trusted to the bot):
// - auth: x-rpa-key against RPA_BOT_KEYS (comma-separated, rotation-friendly);
// - idempotent on (visit_id, run_id): a retried POST returns 200
//   {deduped:true} and changes nothing — first write wins;
// - status must be a short uppercase code; failure_reason capped; manifest
//   is stored as sent (not looked up); unknown fields rejected;
// - every result carries a screenshot OR an explicit
//   screenshot_missing_reason (evidence-or-reason, DB CHECK backs this up);
// - screenshots go to the PRIVATE 'rpa-evidence' bucket; only the storage
//   path is recorded (never raw bytes in the table);
// - a run logged in gdo_bot_file_requests (a DERM Tracker "File it with the bot"
//   press, 2026-10-29) is recorded as real when the press was live, whatever the
//   visit date, with filed_by_email = who pressed; a dry press is never recorded.
// verify_jwt=false in config.toml — the header is the auth, same model as
// the webhook receivers. Server-to-server only.
// ============================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { slackHeader, slackIdentity, slackSections } from '../_shared/slack-notify.ts'

const MAX_SCREENSHOT_BYTES = 5 * 1024 * 1024

const KEYS = (Deno.env.get('RPA_BOT_KEYS') ?? '')
  .split(',')
  .map((k) => k.trim())
  .filter(Boolean)

// 🛑 gdo_id IS NOW USED (2026-08-31). It was accepted-and-ignored from 2026-08-11,
// because the queue served one permit per ticket at a time and the server could
// infer which permit a result was for. It now serves every permit on a ticket at
// once, so the inference is only right in the happy path and the bot's own value
// is the authority (validated against the visit's real permit set before it is
// trusted). gdo_number names the permit when gdo_id is missing (2026-10-29, see the permit block).
// Both stay listed here for the original reason, which has not changed: an unknown
// field is a 400, and a rejected result is a county filing we have no record of,
// which then gets served and filed AGAIN.
const ALLOWED_FIELDS = new Set([
  'visit_id', 'manifest_id', 'run_id', 'status', 'retryable', 'failure_reason',
  'attempted_at', 'portal_confirmation', 'screenshot',
  'screenshot_missing_reason', 'dry_run',
  'gdo_id', 'gdo_number',
  'manual_entry', // 2026-10-26: a filing made on the bot dashboard ("Add a report by hand"), see recordManualEntry
])

// ============================================================================
// BOT DASHBOARD MANUAL ENTRIES (2026-10-26)
// ----------------------------------------------------------------------------
// Fred, 2026-10-26: "what data means is that someone used [the bot] dashboard to file it manually ... so at the
// end of the day it was a manual filing, so we can just accept that new data as a criteria and we can classify it
// as a manual filing in our apps". First case: Yan filed 041-MB visit 8888 (2025-11-16, permit 14965, manifest
// 808783) that way at 12:00 ET; the bot posted it with `manual_entry` and got 400 unknown_field_manual_entry.
//
// A manual entry has NO visit_id: a person typed permit + manifest + service date on the bot's page. So:
//   1. the visit is FOUND from those three values inside v_derm_portal_fields, and only an exact, single answer
//      is used (one visit, one permit, a manifest that covers no other visit); anything else is refused;
//   2. it is recorded through public.fn_record_manual_gdo_report, the SAME function the DERM App's "Record a
//      manual filing" uses, so it gets the Manual chip and "Filed by" in the DERM Tracker and the client reads
//      Fred's 2026-08-20 sentence in the Field Portal. 🛑 Never insert a 'manual-' row directly: that function is
//      the one writer of manual rows (it checks the image exists, the permit, and "already filed"), and the
//      dry-run guard trusts 'manual-' rows because of it (2026-08-19_1558 migration header);
//   3. run_id is stored as 'manual-bot-<bot run_id>': is_manual reads run_id LIKE 'manual-%', the prefix keeps a
//      bot-dashboard filing distinguishable from a DERM App one, and it is deterministic so retries dedupe;
//   4. only a SUCCESS with a portal confirmation and an image is recorded. A test or failed manual entry writes
//      nothing: a stored failure row would hold the bot's queue for that permit (gates 2-3);
//   5. 🛑 A REFUSAL IS A 200 + A SLACK POST, NEVER A 4xx. The county already has the report; what is missing is our
//      record. A 4xx makes the bot retry hourly for ~11 hours and then post "Manually verify if the permit was
//      submitted to DERM", which is the wrong instruction. If the Slack post itself fails we return 500, so the
//      bot keeps retrying and the refusal cannot go silent (root CLAUDE.md s7.1).
// The bot side (Jon's repo) must send gdo_number, ticket_number and service_date inside manual_entry; until it
// does, every manual entry lands in the refusal path with "no permit, manifest or date".
// ============================================================================

// The bot sends the NAME of the dashboard key that filed it, never an email (its server.py _operator_name).
// filed_by_email is required on every 'manual-' row (CHECK actor_markers_agree). Names from Fred, 2026-10-26.
const OPERATOR_EMAILS: Record<string, string> = {
  yan: 'yannick@ayache.com',
  fred: 'fred@ayache.com',
  diego: 'contact@unclogme.com',
}
const MANUAL_ENTRY_FIELDS = new Set(['created_by', 'why', 'gdo_number', 'ticket_number', 'service_date', 'dump_date'])
const SLACK_CHANNEL = 'C0BJYHQKZM1' // #apps-notifications

// The bot strips "GDO-" but keeps whatever zeros were typed; we store GDO-09853. Compare digits without zeros.
const permitKey = (s: string) => s.trim().toUpperCase().replace(/^GDO-/, '').replace(/^0+/, '')
const ticketKey = (s: string) => s.trim().toUpperCase().replace(/^0+(?=.)/, '')

// YYYY-MM-DD or MM/DD/YYYY (the bot accepts both on its page) -> YYYY-MM-DD, or null when it is not a real date.
function isoDate(raw: string): string | null {
  const t = raw.trim()
  let m = /^(\d{4})-(\d{2})-(\d{2})/.exec(t)
  let iso = m ? `${m[1]}-${m[2]}-${m[3]}` : null
  if (!iso) {
    m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(t)
    if (m) iso = `${m[3]}-${m[1].padStart(2, '0')}-${m[2].padStart(2, '0')}`
  }
  if (!iso) return null
  const d = new Date(`${iso}T00:00:00Z`)
  return !isNaN(d.getTime()) && d.toISOString().slice(0, 10) === iso ? iso : null
}

function decodeImage(b64raw: string): { bytes: Uint8Array; ext: 'jpg' | 'png'; mime: string } | null {
  const b64 = b64raw.replace(/^data:image\/[a-z]+;base64,/, '').replace(/\s/g, '')
  if (!b64 || b64.length > (MAX_SCREENSHOT_BYTES * 4) / 3 + 16) return null
  try {
    const bin = atob(b64)
    const bytes = new Uint8Array(bin.length)
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
    const kind = bytes.length <= MAX_SCREENSHOT_BYTES ? sniffImage(bytes) : null
    return kind ? { bytes, ...kind } : null
  } catch {
    return null
  }
}

async function postRefusal(detail: string[], reason: string): Promise<boolean> {
  const token = Deno.env.get('SLACK_BOT_TOKEN') ?? ''
  if (!token) {
    console.error('SLACK_BOT_TOKEN not set: manual entry refusal not posted')
    return false
  }
  const main = '🧾 *GDO report filed by hand on the bot, not recorded in our apps:* ' + reason
  const body = [main, ...detail,
    'The county already has this report. Record it in the DERM App on the visit (Record a manual filing) with the ' +
    'county confirmation email from fog@. Do not file it again.'].join('\n')
  try {
    const as = await slackIdentity(token, 'DERM Tracker', 'derm-tracker')
    const res = await fetch('https://slack.com/api/chat.postMessage', {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json; charset=utf-8' },
      body: JSON.stringify({
        channel: SLACK_CHANNEL,
        text: `GDO report filed by hand on the bot, not recorded: ${reason}`,
        blocks: [slackHeader('🧾 GDO report not recorded'), ...slackSections(body)],
        ...as,
      }),
    })
    const out = await res.json().catch(() => ({}))
    if (!out.ok) console.error('manual entry refusal post failed:', out.error ?? res.status)
    return !!out.ok
  } catch (e) {
    console.error('manual entry refusal post failed:', (e as Error).message)
    return false
  }
}

async function recordManualEntry(body: Record<string, unknown>): Promise<Response> {
  const me = body.manual_entry
  if (me === null || typeof me !== 'object' || Array.isArray(me)) {
    return json({ error: 'manual_entry_must_be_an_object' }, 400)
  }
  const entry = me as Record<string, unknown>
  for (const k of Object.keys(entry)) {
    if (!MANUAL_ENTRY_FIELDS.has(k)) return json({ error: `unknown_field_manual_entry.${k}` }, 400)
  }
  // Never trust a visit, manifest or permit id on a hand entry: the person typed none of them.
  if (body.visit_id != null || body.manifest_id != null || body.gdo_id != null) {
    return json({ error: 'manual_entry_must_not_carry_visit_manifest_or_gdo_id' }, 400)
  }
  const botRunId = typeof body.run_id === 'string' ? body.run_id.trim() : ''
  if (!/^[A-Za-z0-9_.-]{1,86}$/.test(botRunId)) {
    // 86 so 'manual-bot-' + it fits fn_record_manual_gdo_report's ^manual-[A-Za-z0-9_.-]{1,90}$
    return json({ error: 'run_id_must_be_alnum_dot_dash_underscore_max86' }, 400)
  }
  const runId = `manual-bot-${botRunId}`
  const status = typeof body.status === 'string' ? body.status.trim() : ''
  const confirmation = body.portal_confirmation == null ? '' : String(body.portal_confirmation).trim()
  const attemptedAt = typeof body.attempted_at === 'string' ? new Date(body.attempted_at) : null
  if (!attemptedAt || isNaN(attemptedAt.getTime())) return json({ error: 'attempted_at_must_be_iso8601' }, 400)

  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { global: { headers: { 'x-app-source': 'gdo-report-bot' } } },
  )

  // Dedupe FIRST, on the stored run_id alone: a retry after a lost 201 must get the same answer even if the
  // visit match would now come out differently.
  const { data: prior, error: priorErr } = await sb
    .from('derm_portal_submissions')
    .select('id, visit_id, gdo_id, screenshot_path')
    .eq('run_id', runId)
    .limit(1)
  if (priorErr) {
    console.error('manual entry dedupe lookup failed:', priorErr.message)
    return json({ error: 'result_lookup_failed_retry' }, 500)
  }
  if (prior && prior.length > 0) {
    return json({ recorded: true, deduped: true, manual_entry: true, id: prior[0].id, visit_id: prior[0].visit_id,
      gdo_id: prior[0].gdo_id, run_id: runId, screenshot_stored: prior[0].screenshot_path !== null }, 200)
  }

  // A test run or a failed filing is not a filing: nothing to record, nobody to tell.
  if (status !== 'SUCCESS' || body.dry_run === true || !confirmation) {
    return json({ recorded: false, manual_entry: true, reason: 'only_a_successful_filing_is_recorded' }, 200)
  }

  const by = String(entry.created_by ?? '').trim()
  const permit = String(entry.gdo_number ?? '').trim()
  const ticket = String(entry.ticket_number ?? '').trim()
  const rawDate = String(entry.service_date ?? '').trim()
  const when = attemptedAt.toLocaleString('en-US', { timeZone: 'America/New_York', dateStyle: 'medium', timeStyle: 'short' })
  const detail = [
    `*Permit:* ${permit || 'not sent'}`,
    `*Manifest:* ${ticket || 'not sent'}`,
    `*Service date:* ${rawDate || 'not sent'}`,
    `*Filed by:* ${by || 'unknown'} on ${when} ET`,
    `*Bot run:* ${botRunId}`,
  ]
  const refuse = async (reason: string, code: string) => {
    if (!(await postRefusal(detail, reason))) return json({ error: 'refusal_not_announced_retry', reason: code }, 500)
    return json({ recorded: false, manual_entry: true, reason: code, announced: true }, 200)
  }

  if (!permit || !ticket || !rawDate) {
    return await refuse('the bot did not send the permit, manifest and service date, so we cannot tell which visit it is.',
      'manual_entry_missing_permit_manifest_or_date')
  }
  const serviceDate = isoDate(rawDate)
  if (!serviceDate) return await refuse(`"${rawDate}" is not a date we can read.`, 'manual_entry_bad_service_date')

  // Exact match only, inside v_derm_portal_fields (the GDO-report visits, one row per ACTIVE permit). The same
  // view is what fn_record_manual_gdo_report checks the permit against, so a match here is a permit it accepts.
  const { data: rows, error: fErr } = await sb
    .from('v_derm_portal_fields')
    .select('visit_id, gdo_id, gdo_number, ticket_number, manifest_id')
    .eq('visit_date', serviceDate)
  if (fErr) {
    console.error('manual entry visit lookup failed:', fErr.message)
    return json({ error: 'visit_lookup_failed_retry' }, 500)
  }
  const hits = (rows ?? []).filter((r) =>
    r.gdo_id != null && permitKey(String(r.gdo_number ?? '')) === permitKey(permit) &&
    ticketKey(String(r.ticket_number ?? '')) === ticketKey(ticket))
  const visits = [...new Set(hits.map((h) => h.visit_id))]
  const permits = [...new Set(hits.map((h) => h.gdo_id))]
  if (visits.length === 0) {
    return await refuse('no GDO-report visit on that service date has that permit and manifest.', 'manual_entry_no_matching_visit')
  }
  if (visits.length > 1 || permits.length > 1) {
    return await refuse(`it matches ${visits.length} visits and ${permits.length} permits, so we cannot tell which one.`,
      'manual_entry_ambiguous')
  }
  const visitId = visits[0] as number
  const gdoId = permits[0] as number
  // A manifest that covers two visits can turn a typed DUMP date into the OTHER visit's service date (measured:
  // ticket 815951, visits 1353/1360). Never guess there: a person picks the visit.
  const { data: siblings, error: sErr } = await sb
    .from('manifest_visits')
    .select('visit_id')
    .eq('manifest_id', hits[0].manifest_id)
  if (sErr) {
    console.error('manual entry manifest check failed:', sErr.message)
    return json({ error: 'visit_lookup_failed_retry' }, 500)
  }
  if ((siblings ?? []).length > 1) {
    return await refuse(`manifest ${ticket} covers ${(siblings ?? []).length} visits, so a person has to pick visit ${visitId} or the other.`,
      'manual_entry_manifest_covers_several_visits')
  }
  detail.unshift(`*Visit:* ${visitId}`)

  const img = body.screenshot == null ? null : decodeImage(String(body.screenshot))
  if (!img) {
    return await refuse('it came without a readable image (JPEG or PNG), and a manual filing needs one.', 'manual_entry_no_image')
  }

  const filedBy = OPERATOR_EMAILS[by.toLowerCase()] ?? `GDO bot dashboard (${by || 'unknown'})`
  const path = `${visitId}/${runId}.${img.ext}`
  const { error: upErr } = await sb.storage
    .from('rpa-evidence')
    .upload(path, img.bytes, { contentType: img.mime, upsert: true })
  if (upErr) {
    console.error('manual entry evidence upload failed:', upErr.message)
    return json({ error: 'evidence_store_failed_retry' }, 500)
  }
  const { data: row, error: rpcErr } = await sb.rpc('fn_record_manual_gdo_report', {
    p_visit_id: visitId,
    p_attempted_at: attemptedAt.toISOString(),
    p_run_id: runId,
    p_screenshot_path: path,
    p_filed_by_email: filedBy,
    p_gdo_id: gdoId,
  })
  if (rpcErr) {
    // Re-read BEFORE removing anything. The image at `path` is a recorded row's evidence when a concurrent duplicate
    // of THIS run recorded first (the bot resends after its 30 s client timeout while this request still runs), or when
    // this RPC committed and only its answer was lost. Same read as the dedupe above.
    const { data: won, error: wonErr } = await sb
      .from('derm_portal_submissions')
      .select('id, visit_id, gdo_id, screenshot_path')
      .eq('run_id', runId)
      .limit(1)
    if (wonErr) {
      // Cannot tell whether a row points at the image: keep it. The bot retries; its retry dedupes or records.
      console.error('manual entry re-read after a record error failed:', wonErr.message, '| record error:', rpcErr.message)
      return json({ error: 'result_lookup_failed_retry' }, 500)
    }
    if (won && won.length > 0) {
      return json({ recorded: true, deduped: true, manual_entry: true, id: won[0].id, visit_id: won[0].visit_id,
        gdo_id: won[0].gdo_id, run_id: runId, screenshot_stored: won[0].screenshot_path !== null }, 200)
    }
    if (rpcErr.code === '23505' || rpcErr.code === '22023') {
      // A refusal, and no row carries this run_id (fn_record_manual_gdo_report pins every manual path to
      // <visit>/<run_id>.<ext>), so nothing references `path`: remove it so no orphan image stays. Any other error
      // keeps it: the bot retries and the retry rewrites the same path.
      await sb.storage.from('rpa-evidence').remove([path])
    }
    if (rpcErr.code === '23505') {
      // "already has a filing on record for that GDO permit": maybe recorded in the DERM App, maybe a SECOND county
      // filing. Either way a person looks; retrying cannot help.
      return await refuse(`visit ${visitId} already has a filing on record for this permit. Check whether the county now has it twice.`,
        'manual_entry_already_filed')
    }
    if (rpcErr.code === '22023') {
      return await refuse(`our manual-filing check refused it: ${rpcErr.message}`, 'manual_entry_refused_by_check')
    }
    console.error('manual entry record failed:', rpcErr.message)
    return json({ error: 'result_store_failed_retry' }, 500)
  }
  const rec = row as { id?: number } | null
  return json({ recorded: true, deduped: false, manual_entry: true, id: rec?.id ?? null, visit_id: visitId,
    gdo_id: gdoId, run_id: runId, filed_by: filedBy, screenshot_stored: true }, 201)
}

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

// 🛑 SNIFF THE REAL BYTES (added 2026-08-24). This used to hardcode `.jpg` +
// image/jpeg for every upload. That was harmless only while the bot sent portal
// screenshots, which were genuinely JPEG. It now sends the county confirmation
// EMAIL rendered as an image, which is typically PNG, so the old code would have
// stored PNG bytes at a .jpg key labelled image/jpeg from the first post, silently.
// A declared content-type is caller-supplied and proves nothing; the bytes do.
// ⚠ An UNRECOGNISED type still stores as .jpg, exactly as before. Do not turn that
// into a rejection: the accept-and-flag rule here exists because losing a real
// county filing over an image problem re-queues the manifest and risks a double
// filing. Sniffing is allowed to improve the label, never to drop the evidence.
function sniffImage(b: Uint8Array): { ext: 'jpg' | 'png'; mime: string } | null {
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) {
    return { ext: 'jpg', mime: 'image/jpeg' }
  }
  if (
    b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 &&
    b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a
  ) {
    return { ext: 'png', mime: 'image/png' }
  }
  return null
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)

  if (KEYS.length === 0) {
    console.error('RPA_BOT_KEYS secret not configured')
    return json({ error: 'service_not_configured' }, 503)
  }
  if (!KEYS.includes(req.headers.get('x-rpa-key') ?? '')) {
    return json({ error: 'unauthorized' }, 401)
  }

  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return json({ error: 'invalid_json' }, 400)
  }

  for (const k of Object.keys(body)) {
    if (!ALLOWED_FIELDS.has(k)) return json({ error: `unknown_field_${k}` }, 400)
  }
  if (body.manual_entry != null) return await recordManualEntry(body)

  const visitId = Number(body.visit_id)
  if (!Number.isInteger(visitId) || visitId <= 0) {
    return json({ error: 'visit_id_required_integer' }, 400)
  }
  const manifestId = body.manifest_id == null ? null : Number(body.manifest_id)
  if (manifestId !== null && (!Number.isInteger(manifestId) || manifestId <= 0)) {
    return json({ error: 'manifest_id_must_be_integer_or_omitted' }, 400)
  }
  const runId = typeof body.run_id === 'string' ? body.run_id.trim() : ''
  if (!/^[A-Za-z0-9_.-]{1,100}$/.test(runId)) {
    // run_id becomes part of a storage object key: charset-restricted so a
    // stray '/' or storage-hostile character cannot poison every retry
    // (review finding 3 - a permanently unstorable result would re-queue an
    // already-submitted manifest).
    return json({ error: 'run_id_must_be_alnum_dot_dash_underscore_max100' }, 400)
  }
  const status = typeof body.status === 'string' ? body.status.trim() : ''
  if (!/^[A-Z0-9_]{1,64}$/.test(status)) {
    return json({ error: 'status_must_be_short_uppercase_code' }, 400)
  }
  if (typeof body.retryable !== 'boolean') {
    return json({ error: 'retryable_boolean_required' }, 400)
  }
  const failureReason = body.failure_reason == null ? null : String(body.failure_reason)
  if (failureReason !== null && failureReason.length > 1000) {
    return json({ error: 'failure_reason_max_1000_chars' }, 400)
  }
  const portalConfirmation = body.portal_confirmation == null ? null : String(body.portal_confirmation)
  if (portalConfirmation !== null && portalConfirmation.length > 200) {
    return json({ error: 'portal_confirmation_max_200_chars' }, 400)
  }
  const attemptedAt = typeof body.attempted_at === 'string' ? new Date(body.attempted_at) : null
  if (!attemptedAt || isNaN(attemptedAt.getTime())) {
    return json({ error: 'attempted_at_must_be_iso8601' }, 400)
  }
  // attempted_at is DISPLAY/AUDIT ONLY (audit 2026-07-21f): the queue gates key
  // off the server-written created_at, so a skewed bot clock can neither wedge
  // nor prematurely release the queue. No skew hard-reject — rejecting a genuine
  // post-county-submission result would re-queue the manifest -> double-filing.
  // dry_run is DERIVED server-side, never trusted from the bot (audit 2026-07-21f):
  // the recorded flag must match the manifest's cutoff classification because the
  // queue gates all filter NOT dry_run. Computed after the manifest lookup below.
  const screenshotB64 = body.screenshot == null ? null : String(body.screenshot)
  const missingReason = body.screenshot_missing_reason == null
    ? null
    : String(body.screenshot_missing_reason)
  if (missingReason !== null && missingReason.length > 300) {
    return json({ error: 'screenshot_missing_reason_max_300_chars' }, 400)
  }
  if (!screenshotB64 && !missingReason) {
    return json({ error: 'screenshot_or_screenshot_missing_reason_required' }, 400)
  }

  // Decode the screenshot, but ACCEPT-AND-FLAG rather than reject on any problem
  // (audit 2026-07-21f): a real county submission must never be lost to a
  // screenshot issue and re-queued. Oversize/undecodable -> record the attempt
  // with a screenshot_missing_reason instead of a 4xx.
  let screenshotBytes: Uint8Array | null = null
  let screenshotDropReason: string | null = null
  if (screenshotB64) {
    // strip whitespace so the length check matches atob() (which ignores it);
    // wrapped/MIME base64 inflates length ~1.3% otherwise (audit finding 3).
    const b64 = screenshotB64.replace(/^data:image\/[a-z]+;base64,/, '').replace(/\s/g, '')
    if (b64.length > (MAX_SCREENSHOT_BYTES * 4) / 3 + 16) {
      screenshotDropReason = 'SCREENSHOT_TOO_LARGE'
    } else {
      try {
        const bin = atob(b64)
        const out = new Uint8Array(bin.length)
        for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
        if (out.length > MAX_SCREENSHOT_BYTES) {
          screenshotDropReason = 'SCREENSHOT_TOO_LARGE'
        } else {
          screenshotBytes = out
        }
      } catch {
        screenshotDropReason = 'SCREENSHOT_DECODE_FAILED'
      }
    }
  }

  // x-app-source tags every write from this bot as 'gdo-report-bot' so the
  // audit trail attributes the action to the Automated GDO Reporting bot
  // (not the generic service_role/sql fallback). 2026-07-21i.
  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { global: { headers: { 'x-app-source': 'gdo-report-bot' } } },
  )

  const { data: visit, error: vErr } = await sb
    .from('visits')
    .select('id, deleted_at, visit_date, client_id')
    .eq('id', visitId)
    .maybeSingle()
  if (vErr) {
    console.error('visit lookup failed:', vErr.message)
    return json({ error: 'visit_lookup_failed' }, 500)
  }
  if (!visit || visit.deleted_at) {
    return json({ error: 'visit_not_found_or_deleted' }, 422)
  }
  // 2026-10-29 (Trello xBCSvP6f): was this run a "File it with the bot" press? gdo-bot-file-visit logs every
  // press the bot accepted, with the run_id from its 202. A logged LIVE press is a real filing, also on a visit
  // before the cutoff (Fred: "Yes, only for button presses"), filed by the person who pressed. A logged DRY press
  // is never recorded. A failed lookup is a 500 so the bot retries: guessing would store a real filing of an older
  // visit as a dry run.
  const { data: press, error: pressErr } = await sb
    .from('gdo_bot_file_requests')
    .select('gdo_id, dry_run, requested_by')
    .eq('visit_id', visitId)
    .eq('run_id', runId)
    .maybeSingle()
  if (pressErr) {
    console.error('press lookup failed:', pressErr.message)
    return json({ error: 'result_store_failed_retry' }, 500)
  }
  if (press?.dry_run === true) {
    return json({ recorded: false, ignored: 'dry_run_press', note: 'A dry run of a button press is never recorded.' }, 200)
  }
  const livePress = press != null

  // Derive dry_run from the visit's service date vs the single-source cutoff
  // (2026-07-21g): store the DERIVED truth, ignore the bot's echoed flag; the
  // DB trigger is the final backstop. A logged live press is real whatever the date (2026-10-29_1245).
  const { data: cutoffRow } = await sb.rpc('rpa_launch_cutoff')
  const cutoff = typeof cutoffRow === 'string' ? cutoffRow : '2026-07-21'
  const dryRun = !livePress && !!visit.visit_date && visit.visit_date < cutoff
  // No optimistic success: a real SUCCESS must carry a portal confirmation.
  if (status === 'SUCCESS' && !dryRun && !portalConfirmation) {
    return json({ error: 'success_requires_portal_confirmation' }, 400)
  }

  // Idempotency: first write wins; a retried POST is a no-op acknowledgment.
  // screenshot_path/_missing_reason are selected so the deduped response can report
  // the STORED row's evidence state (2026-08-11): the caller cannot otherwise tell
  // "filed with evidence" from "filed without it", and on a dedupe we upload nothing,
  // so the honest answer is what is already on the row rather than what was posted.
  const { data: existing } = await sb
    .from('derm_portal_submissions')
    .select('id, screenshot_path, screenshot_missing_reason')
    .eq('visit_id', visitId)
    .eq('run_id', runId)
    .maybeSingle()
  if (existing) {
    return json({
      recorded: true,
      deduped: true,
      id: existing.id,
      screenshot_stored: existing.screenshot_path !== null,
      screenshot_missing_reason: existing.screenshot_missing_reason ?? null,
    }, 200)
  }

  // Which GDO permit this filing covered.
  //
  // 🛑 REWRITTEN 2026-08-31, AND THE OLD REASONING NO LONGER HOLDS. This used to
  // say: "the queue serves ONE (ticket, permit) pair per ticket at a time -- the
  // 20h manifest-grained lease is what guarantees that -- so there is exactly one
  // permit this result can be for." That guarantee is GONE ON PURPOSE. The lease
  // is now per (visit, permit) and the queue is keyed on (manifest_id, gdo_id), so
  // a manifest with three permits is served as three items in ONE run. Inferring
  // the permit from the visit would then attribute results by ARRIVAL ORDER, which
  // is correct only in the happy path: if the bot files permits A and C and A
  // fails, the inference records C's SUCCESS against A.
  //
  // So the BOT'S OWN gdo_id wins when it sends one, and it is VALIDATED against
  // this visit's real permit set first -- a wrong id must never be trusted into a
  // county filing record. The DB inference stays as the fallback for a bot that
  // does not send it, which keeps this endpoint backward compatible.
  //
  // Unchanged and still load-bearing: resolved BEFORE the insert, because our own
  // row would otherwise change the answer; and a failure here is LOGGED AND
  // SWALLOWED, because a real county filing must never be rejected over the permit
  // field. A NULL SUCCESS still retires every permit of the ticket (gate 1: under-serve, never re-file). A NULL
  // FAILURE no longer holds a permitted row past the 20h cooldown (gate 3 is exact-pair since 2026-10-20_1345);
  // the retry-loop health count catches it if it repeats (2026-10-20_1405).
  let gdoId: number | null = null
  {
    // A logged press knows its permit, so it stands in when the bot sends no gdo_id (2026-10-29).
    const claimed = typeof body.gdo_id === 'number' && Number.isInteger(body.gdo_id)
      ? body.gdo_id
      : (typeof press?.gdo_id === 'number' ? press.gdo_id : null)
    if (claimed !== null) {
      const { data: ok, error: vErr } = await sb
        .from('v_derm_portal_fields')
        .select('gdo_id')
        .eq('visit_id', visitId)
        .eq('gdo_id', claimed)
        .limit(1)
      if (vErr) {
        console.error('permit validation failed, falling back to inference:', vErr.message)
      } else if (ok && ok.length > 0) {
        gdoId = claimed
      } else {
        // 2026-10-20: the claimed permit can leave v_derm_portal_fields between the serve and this
        // POST (demoted, renumbered, line 27 removed; the bot's pending cache re-posts up to 72h later). Inferring
        // then recorded THIS filing against a DIFFERENT permit, which gate 1 retires unfiled: the exact case the
        // bot's echo exists to close. Keep the bot's permit when it is one of this visit's client's permits, in
        // any status. Only a permit of another client falls back to inference.
        // (Visible since 2026-10-20_1405: log_rpa_derm_health raises gdo_filed_permit_changed when the visit then
        // has another permit, so a person sees the second report.)
        if (visit.client_id == null) {
          console.error(`visit ${visitId} has no client, so gdo_id ${claimed} cannot be checked; falling back to inference`)
        } else {
          const { data: own, error: oErr } = await sb
            .from('gdos')
            .select('id')
            .eq('id', claimed)
            .eq('client_id', visit.client_id)
            .limit(1)
          if (oErr) {
            console.error(`permit ownership check failed for gdo_id ${claimed}, falling back to inference:`, oErr.message)
          } else if (own && own.length > 0) {
            gdoId = claimed
            console.info(`gdo_id ${claimed} is no longer in the queue's fields for visit ${visitId}; kept (same client)`)
          } else {
            console.error(
              `bot reported gdo_id ${claimed} which is not a permit of visit ${visitId}'s client; ` +
              'falling back to inference',
            )
          }
        }
      }
    }
    // 2026-10-29 (Jonathan): with no usable gdo_id, the permit NUMBER names it. Same key as a manual entry
    // (permitKey: no GDO- prefix, no leading zeros, any case), first among this visit's queue permits, then among
    // its client's permits in any status. Only one exact match counts; otherwise inference, as before.
    const number = typeof body.gdo_number === 'string' ? body.gdo_number.trim() : ''
    if (gdoId === null && permitKey(number) !== '') {
      const key = permitKey(number)
      const { data: own, error: nErr } = await sb
        .from('v_derm_portal_fields')
        .select('gdo_id, gdo_number')
        .eq('visit_id', visitId)
      if (nErr) console.error(`permit number lookup failed for visit ${visitId}:`, nErr.message)
      let hits = (own ?? [])
        .filter((r: { gdo_id: number | null, gdo_number: string | null }) => r.gdo_id != null && permitKey(String(r.gdo_number ?? '')) === key)
        .map((r: { gdo_id: number }) => r.gdo_id)
      if (hits.length === 0 && visit.client_id != null) {
        const { data: cg, error: cErr } = await sb
          .from('gdos')
          .select('id, gdo_number')
          .eq('client_id', visit.client_id)
        if (cErr) console.error(`client permit lookup failed for visit ${visitId}:`, cErr.message)
        hits = (cg ?? [])
          .filter((g: { id: number, gdo_number: string | null }) => permitKey(String(g.gdo_number ?? '')) === key)
          .map((g: { id: number }) => g.id)
      }
      const found = [...new Set(hits)]
      if (found.length === 1) {
        gdoId = found[0]
      } else {
        console.error(`gdo_number ${number} matched ${found.length} permits of visit ${visitId}; falling back to inference`)
      }
    }
    if (gdoId === null) {
      const { data: resolved, error: gErr } = await sb
        .rpc('fn_resolve_rpa_permit', { p_visit_id: visitId })
      if (gErr) {
        console.error('permit resolve failed (recording without a permit):', gErr.message)
      } else if (typeof resolved === 'number') {
        gdoId = resolved
        if (claimed === null) {
          console.info(`permit inferred for visit ${visitId}: bot sent no gdo_id`)
        }
      }
    }
  }

  let screenshotPath: string | null = null
  let evidenceDropReason: string | null = screenshotDropReason
  if (screenshotBytes) {
    // Deterministic key + upsert: a retried POST (same run_id) rewrites the same
    // object. DRY-RUN evidence is test-only, so it uses a PER-VISIT key
    // (`<visit>/dryrun.jpg`): repeated dry-run test runs OVERWRITE to one file
    // per visit instead of accumulating a new file per run_id (evidence-dup
    // cleanup 2026-07-24). LIVE keeps the per-run_id key so every real filing
    // attempt stays a distinct, non-overwritten evidence file — a genuine
    // re-attempt must remain visible (it is the double-file signal).
    // Extension and content-type come from the BYTES (see sniffImage). An
    // unrecognised type falls back to jpg, which is exactly the pre-2026-08-24
    // behaviour, so this can only ever improve a label and never drop a filing.
    const kind = sniffImage(screenshotBytes)
    const ext = kind?.ext ?? 'jpg'
    const mime = kind?.mime ?? 'image/jpeg'
    screenshotPath = dryRun ? `${visitId}/dryrun.${ext}` : `${visitId}/${runId}.${ext}`
    let uploaded = false
    for (let attempt = 0; attempt < 3 && !uploaded; attempt++) {
      if (attempt > 0) await new Promise((r) => setTimeout(r, 200 * attempt))
      const { error: upErr } = await sb.storage
        .from('rpa-evidence')
        .upload(screenshotPath, screenshotBytes, { contentType: mime, upsert: true })
      if (!upErr) { uploaded = true; break }
      console.error(`screenshot upload attempt ${attempt + 1} failed:`, upErr.message)
    }
    if (!uploaded) {
      // Retries exhausted: record the ATTEMPT without evidence rather than lose
      // it (a lost result re-queues an already-filed manifest = double-filing).
      screenshotPath = null
      evidenceDropReason = 'STORE_FAILED'
    }
  }

  const { data: inserted, error: insErr } = await sb
    .from('derm_portal_submissions')
    .insert({
      visit_id: visitId,
      manifest_id: manifestId,
      gdo_id: gdoId,
      run_id: runId,
      status,
      retryable: body.retryable,
      failure_reason: failureReason,
      portal_confirmation: portalConfirmation,
      attempted_at: attemptedAt.toISOString(),
      screenshot_path: screenshotPath,
      screenshot_missing_reason: screenshotPath ? null : (evidenceDropReason ?? missingReason),
      dry_run: dryRun,
      filed_by_email: press?.requested_by ?? null, // who pressed "File it with the bot" (D4); null for the hourly run
    })
    .select('id')
    .single()
  if (insErr) {
    // Unique violation = concurrent duplicate POST; acknowledge idempotently.
    if (insErr.code === '23505') {
      const { data: dup } = await sb
        .from('derm_portal_submissions')
        .select('id, screenshot_path, screenshot_missing_reason')
        .eq('visit_id', visitId)
        .eq('run_id', runId)
        .maybeSingle()
      return json({
        recorded: true,
        deduped: true,
        id: dup?.id ?? null,
        screenshot_stored: dup ? dup.screenshot_path !== null : false,
        screenshot_missing_reason: dup?.screenshot_missing_reason ?? null,
      }, 200)
    }
    console.error('result insert failed:', insErr.message)
    return json({ error: 'result_store_failed_retry' }, 500)
  }

  // screenshot_stored mirrors EXACTLY what was written to the row above, so the
  // response can never disagree with the record. It stays 201 either way: an image
  // problem must never turn a real county filing into an unrecorded one.
  return json({
    recorded: true,
    deduped: false,
    id: inserted.id,
    screenshot_stored: screenshotPath !== null,
    screenshot_missing_reason: screenshotPath ? null : (evidenceDropReason ?? missingReason),
  }, 201)
})
