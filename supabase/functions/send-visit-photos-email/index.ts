// ============================================================================
// send-visit-photos-email — the Admin Review "Send email to City" button
// ============================================================================
// Fred, 2026-08-15: the gate is classification, "because the model for the email
// it's gonna be a text i give you + the classified photos attached to it."
//
// 🛑 THIS IS NOT send-derm-email. That one mails manifest PDFs to municipal FOG
// inboxes resolved from public.municipality_regulators. This one mails a body plus
// the visit's CLASSIFIED PHOTOS. Different payload, different gate, different log
// table (public.visit_photo_email_sends, NOT derm_email_sends).
//
// 🛑 CITY SENDING IS DISABLED (Fred, 2026-08-10: "the emailing functionality to the
// city is disabled for now, until i explicitly say otherwise"). Fred's instruction
// for THIS button on 2026-08-15 was "Build it, but test-send only to me", so the
// recipient is the hard-wired constant below and every row logs is_test = true.
// 🛑 THE RECIPIENT IS NOT READABLE FROM THE REQUEST BODY, DELIBERATELY. send-derm-email
// accepts `test_recipient` as any string containing '@' with no allowlist, which means
// a caller chooses who receives a client's documents. That mistake is not repeated
// here: to change the recipient you edit this file and redeploy.
//
// 🛑 AND UNLIKE send-derm-email, THIS FUNCTION ACTUALLY CHECKS WHO IS CALLING.
// send-derm-email is deployed verify_jwt=true but asserts no role, and the public
// anon key is a valid JWT, so its effective gate is "holds a key that ships in every
// browser bundle". Here the bearer token is validated with auth.getUser() and a
// request with no real user is refused. verify_jwt is half a gate; this is the
// other half.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { encodeBase64 } from 'https://deno.land/std@0.224.0/encoding/base64.ts'
import { decode, Image } from 'https://deno.land/x/imagescript@1.3.0/mod.ts'

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')
const RESEND_FROM = Deno.env.get('RESEND_FROM') ?? 'Unclogme <onboarding@resend.dev>'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''

// 🛑 Hard-wired while city sending is off. Fred: "test-send only to me".
const TEST_RECIPIENT = 'fred@ayache.com'
const IS_TEST = true

const BUCKET = 'GT - Visits Images'

// Attachment budget. Measured 2026-08-15 over the 57 visits that have classified
// photos: avg 9.9MB of source, p90 24.8MB, max 36.9MB, and one SINGLE source photo
// is 28.9MB. Raw attachment would exceed Resend's 40MB ceiling and would bounce off
// most municipal mail servers long before that (many .gov gateways cap at 10-25MB).
// So every image is re-encoded down before it is attached.
const MAX_EDGE_PX = 1280      // longest side
const JPEG_QUALITY = 72
const MAX_SOURCE_BYTES = 30 * 1024 * 1024   // refuse to decode a pathological source

// 🛑 THE WALL IS MEMORY, NOT CPU, AND THE FIRST DIAGNOSIS HERE WAS WRONG.
// Measured live, all three runs:
//     10 photos, all re-encoded          -> 200, 1.6MB, 6.6s
//     17 photos, all re-encoded          -> 546 WORKER_RESOURCE_LIMIT at 7.0s
//     17 photos, decode skipped entirely -> 546 WORKER_RESOURCE_LIMIT at 3.0s
// Removing every decode made it fail SOONER, which rules out compute: without the
// resize the buffers are bigger, so the accumulation hits the ceiling earlier. Two
// things pile up. Attachments must all be resident at once because Resend takes one
// JSON body, and base64 inflates by 4/3, then JSON.stringify and fetch each copy it.
// And ImageScript holds a full RGBA raster while decoding, which is width x height x 4
// (a 12MP phone photo is ~48MB) on top of that.
// So the control that matters is the TOTAL BYTES RESIDENT, not the photo count.
// Boundary found by bisection against the live worker, not chosen by taste:
//     10 photos, all re-encoded -> 200 (1.6MB, 6.6s)   <- works
//     12 photos, pass-through   -> 546                  <- fails
//     17 photos, either way     -> 546                  <- fails
// So RESIZE EVERYTHING (small output is what keeps the payload resident-safe) and stop
// at 10. Re-encoding is not the cost; carrying big buffers is.
const MAX_TOTAL_BYTES = 6 * 1024 * 1024
const MAX_PHOTOS = 10
const RESIZE_ABOVE_BYTES = 0          // 0 = always re-encode
const MAX_DECODES_PER_CALL = 10

// 🛑 PRIORITY IS NOT COSMETIC, IT DECIDES WHAT SURVIVES THE CAP. Fred's own copy calls
// the attachment a "Job Completion Report (with before & after photos)", so before and
// after are the evidence the municipality is actually being sent; internal and extra
// ride along only if there is room. Anything dropped is reported in `skipped` and
// recorded in the send log, never silently.
const PHASE_RANK: Record<string, number> = { before: 0, after: 1, internal: 2, extra: 3 }

const ALLOWED_ORIGINS = new Set([
  'https://admin.unclogme.app',
  'https://audit.unclogme.app',
])

function corsHeadersFor(origin: string | null): Record<string, string> {
  const allowed = origin && ALLOWED_ORIGINS.has(origin) ? origin : 'https://admin.unclogme.app'
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, content-type, x-client-info, apikey, x-app-source',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  }
}

function json(body: Record<string, unknown>, status: number, cors: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
}

const PHASE_LABEL: Record<string, string> = {
  before: 'Before', after: 'After', internal: 'Internal', extra: 'Extra',
}

// ---------------------------------------------------------------------------
// COPY. Fred's template, supplied verbatim 2026-08-15 ("email #1 for the city as
// soon as the job is completed"). Styling matches the DERM app on his instruction
// "remember to add the Style for it, like the DERM App does", so the brand tokens
// below are the SAME constants send-derm-email uses: same logo object, same font
// stack, same 600px card on #f4f5f7 with the #f14714 top rule and the grey footer.
//
// 🛑 THE BODY IS NOT A REQUEST PARAMETER, ON PURPOSE. To change the wording you edit
// this file and redeploy. If the caller could pass body text, the caller would choose
// what a regulator reads.
//
// ⚠ "Service Type: Grease Trap Cleaning" is FIXED TEXT because Fred's template
// hard-codes it, while [Client Name] / [Address] / [Date] are placeholders. It is
// deliberately not derived from visits.service_type. Flagged to Fred: a lift-station
// or grey-water visit would still say "Grease Trap Cleaning". Do not silently change
// it, that is his copy to a regulator.
// ---------------------------------------------------------------------------
const LOGO_URL = 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/_brand/unclogme-logo.jpg'
const FONT_STACK = "'Manrope', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
const SERVICE_TYPE_LABEL = 'Grease Trap Cleaning'
const CONTACT_EMAIL = 'contact@unclogme.com'
const CONTACT_PHONE = '(305) 339-5638'
const CONTACT_TEL = '+13053395638'
const DERM_PERMIT = 'DERM Permit #1404-25'

function escapeHtml(s: string | null): string {
  return (s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] ?? c))
}

// 'YYYY-MM-DD' -> 'Month D, YYYY'. Same tz-safe helper as send-derm-email.
function fmtDate(d: string | null): string {
  if (!d) return ''
  try {
    return new Date(d + 'T12:00:00Z').toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' })
  } catch { return d }
}

// 🛑 `properties.address` is INCONSISTENT and a blanket join duplicates the tail.
// Measured over the 894 properties that have one: 56 already contain the city inline
// and 9 contain the zip, while the other 838 are street-only. Naively joining all four
// parts produced this real subject line on the first live test:
//     "... 9509 Harding Ave, Surfside, FL 33154, Surfside, FL, 33154 ..."
// So append a part only when it is not already in the string. Note `state` is stored
// as "Florida" on some rows and "FL" on others, hence the abbreviation check too.
function composeAddress(address: string | null, city: string | null, state: string | null, zip: string | null): string {
  const base = (address ?? '').trim()
  const has = (needle: string | null) => {
    const n = (needle ?? '').trim()
    if (!n) return true   // nothing to add
    return base.toLowerCase().includes(n.toLowerCase())
  }
  const ST: Record<string, string> = { florida: 'FL' }
  const stateTxt = (state ?? '').trim()
  const stateAbbr = ST[stateTxt.toLowerCase()] ?? stateTxt
  const parts = [base]
  if (!has(city)) parts.push((city ?? '').trim())
  // US convention is "Surfside, FL 33154": state and zip are one field separated by a
  // space, not two comma-separated ones. Build that tail before joining.
  const tail = [
    (stateAbbr && !has(stateTxt) && !has(stateAbbr)) ? stateAbbr : '',
    !has(zip) ? (zip ?? '').trim() : '',
  ].filter(Boolean).join(' ')
  if (tail) parts.push(tail)
  const out = parts.filter(Boolean).join(', ').replace(/\s*,\s*,+/g, ',').trim()
  return out || 'Address not on file'
}

function buildSubject(v: VisitRow): string {
  return `Grease Trap Service Completed — ${v.client_name}, ${v.address} (${fmtDate(v.visit_date)})`
}

function detailRow(label: string, value: string): string {
  return `<tr>
<td valign="top" style="padding:4px 14px 4px 0;font-family:${FONT_STACK};font-size:14px;line-height:1.6;color:#6b7280;white-space:nowrap;">${label}</td>
<td valign="top" style="padding:4px 0;font-family:${FONT_STACK};font-size:14px;line-height:1.6;color:#111827;font-weight:600;">${value}</td>
</tr>`
}

function buildHtml(v: VisitRow, photos: Prepared[]): string {
  const name = escapeHtml(v.client_name)
  const addr = escapeHtml(v.address)
  const vdate = escapeHtml(fmtDate(v.visit_date))
  const beforeN = photos.filter((p) => p.phase === 'before').length
  const afterN = photos.filter((p) => p.phase === 'after').length
  const breakdown = (['before', 'after', 'internal', 'extra'] as const)
    .map((p) => [PHASE_LABEL[p], photos.filter((x) => x.phase === p).length] as const)
    .filter(([, n]) => n > 0)
    .map(([l, n]) => `${l} ${n}`)
    .join(' &middot; ')

  // The TEST strip sits OUTSIDE the card, so the card itself is byte-for-byte what
  // a municipality would receive. Fred needs to review the real thing, not a
  // watermarked approximation of it.
  const testStrip = IS_TEST
    ? `<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;"><tr><td style="padding:0 0 14px 0;font-family:${FONT_STACK};font-size:12px;line-height:1.5;color:#92400e;background:#fffbeb;border:1px solid #fcd34d;border-radius:8px;padding:10px 14px;"><strong>INTERNAL TEST.</strong> City sending is disabled; this went only to the internal test address. Everything below the line is exactly what the municipality would receive.</td></tr></table>`
    : ''

  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><meta http-equiv="X-UA-Compatible" content="IE=edge"><title>Grease Trap Service Completed</title></head>
<body style="margin:0;padding:0;background-color:#f4f5f7;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;font-size:1px;line-height:1px;color:#f4f5f7;">Grease trap service completed for ${name} at ${addr} on ${vdate}. Job Completion Report with before &amp; after photos attached.</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f4f5f7;"><tr><td align="center" style="padding:32px 16px;">
${testStrip}
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;background-color:#ffffff;border-radius:12px;border:1px solid #e6e8eb;border-top:4px solid #f14714;">
<tr><td style="padding:28px 36px 20px 36px;border-bottom:1px solid #eef0f2;"><img src="${LOGO_URL}" alt="UnclogMe" width="144" height="48" style="display:block;border:0;outline:none;text-decoration:none;height:48px;width:144px;"></td></tr>

<tr><td style="padding:32px 36px 8px 36px;font-family:${FONT_STACK};">
<p style="margin:0 0 18px 0;font-size:16px;line-height:1.5;font-weight:700;color:#111827;">Dear Environmental Compliance Team,</p>
<p style="margin:0 0 22px 0;font-size:15px;line-height:1.65;color:#374151;">We are writing to confirm that the scheduled grease trap service for the location below has been successfully completed.</p>
</td></tr>

<tr><td style="padding:0 36px 24px 36px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#fff7f4;border:1px solid #ffd9c9;border-radius:10px;"><tr><td style="padding:16px 18px;">
<p style="margin:0 0 10px 0;font-family:${FONT_STACK};font-size:12px;font-weight:700;letter-spacing:0.6px;text-transform:uppercase;color:#d63d12;">Service Details</p>
<table role="presentation" cellpadding="0" cellspacing="0" border="0">
${detailRow('Client', name)}
${detailRow('Location', addr)}
${detailRow('Service Date', vdate)}
${detailRow('Service Type', SERVICE_TYPE_LABEL)}
</table>
</td></tr></table>
</td></tr>

<tr><td style="padding:0 36px 24px 36px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f8fafc;border:1px solid #e6e8eb;border-radius:10px;"><tr><td style="padding:16px 18px;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
<td valign="middle" width="40" style="width:40px;"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr><td align="center" valign="middle" height="40" style="width:40px;height:40px;background-color:#f14714;border-radius:8px;font-family:Arial,Helvetica,sans-serif;font-size:11px;font-weight:bold;color:#ffffff;letter-spacing:0.5px;">${photos.length}</td></tr></table></td>
<td valign="middle" style="padding-left:14px;font-family:${FONT_STACK};">
<div style="font-size:14px;font-weight:600;color:#111827;line-height:1.3;">Job Completion Report${beforeN > 0 && afterN > 0 ? ' (with before &amp; after photos)' : ' (service photos)'}</div>
<div style="font-size:13px;color:#6b7280;line-height:1.3;padding-top:2px;">${breakdown}</div>
</td></tr></table>
</td></tr></table>
</td></tr>

<tr><td style="padding:0 36px 8px 36px;font-family:${FONT_STACK};">
<p style="margin:0 0 20px 0;font-size:14px;line-height:1.65;color:#374151;background-color:#f8fafc;border-left:3px solid #cbd5e1;padding:12px 14px;border-radius:0 6px 6px 0;"><strong style="color:#111827;">Please note:</strong> The DERM Manifest and Transporter Manifest will be sent in a separate email once the collected material has been delivered to the approved disposal facility. You will receive that confirmation shortly.</p>
<p style="margin:0 0 16px 0;font-size:15px;line-height:1.65;color:#374151;">If you have any questions or need additional information regarding this service, please don't hesitate to reach out to us at <a href="mailto:${CONTACT_EMAIL}" style="color:#d63d12;text-decoration:underline;font-weight:600;">${CONTACT_EMAIL}</a> or call us directly at <a href="tel:${CONTACT_TEL}" style="color:#d63d12;text-decoration:underline;font-weight:600;">${CONTACT_PHONE}</a>.</p>
<p style="margin:0 0 22px 0;font-size:15px;line-height:1.65;color:#374151;">Thank you for your continued partnership in keeping our community compliant and clean.</p>
<p style="margin:0 0 4px 0;font-size:15px;line-height:1.65;font-weight:700;color:#111827;">The UnclogMe Team</p>
</td></tr>

<tr><td style="padding:18px 36px 26px 36px;background-color:#fafbfc;border-top:1px solid #eef0f2;font-family:${FONT_STACK};">
<p style="margin:0 0 4px 0;font-size:13px;font-weight:700;color:#374151;">Licensed Grease Trap Hauler &middot; Miami-Dade &amp; Broward</p>
<p style="margin:0 0 6px 0;font-size:12px;line-height:1.5;color:#6b7280;">${DERM_PERMIT}</p>
<p style="margin:0;font-size:12px;line-height:1.5;color:#9ca3af;"><a href="mailto:${CONTACT_EMAIL}" style="color:#9ca3af;text-decoration:underline;">${CONTACT_EMAIL}</a> &middot; ${CONTACT_PHONE} &middot; <a href="https://unclogme.com" style="color:#9ca3af;text-decoration:underline;">unclogme.com</a></p>
</td></tr>
</table>
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;"><tr><td style="padding:16px 36px;text-align:center;font-family:${FONT_STACK};font-size:11px;color:#b6bcc4;line-height:1.5;">Sent by Unclogme LLC for FOG / grease-trap compliance notification.</td></tr></table>
</td></tr></table>
</body></html>`
}

// Plain-text alternative. Resend sends both; a text part measurably helps deliverability
// to municipal gateways, which is the whole audience for this message.
function buildText(v: VisitRow, photos: Prepared[]): string {
  return [
    'Dear Environmental Compliance Team,', '',
    'We are writing to confirm that the scheduled grease trap service for the location below has been successfully completed.', '',
    'Service Details:',
    `  - Client: ${v.client_name}.`,
    `  - Location: ${v.address}.`,
    `  - Service Date: ${fmtDate(v.visit_date)}.`,
    `  - Service Type: ${SERVICE_TYPE_LABEL}.`, '',
    `Attached: Job Completion Report (${photos.length} photo${photos.length === 1 ? '' : 's'})`, '',
    'Please note: The DERM Manifest and Transporter Manifest will be sent in a separate email once the collected material has been delivered to the approved disposal facility. You will receive that confirmation shortly.', '',
    `If you have any questions or need additional information regarding this service, please don't hesitate to reach out to us at ${CONTACT_EMAIL} or call us directly at ${CONTACT_PHONE}.`, '',
    'Thank you for your continued partnership in keeping our community compliant and clean.', '',
    'The UnclogMe Team',
    'Licensed Grease Trap Hauler - Miami-Dade & Broward',
    DERM_PERMIT,
    `${CONTACT_EMAIL} - ${CONTACT_PHONE} - unclogme.com`,
  ].join('\n')
}

interface VisitRow {
  visit_id: number; client_name: string; client_code: string | null
  address: string; visit_date: string
}
interface Prepared {
  filename: string; content: string; content_type: string; phase: string; bytes: number
}

Deno.serve(async (req: Request) => {
  const cors = corsHeadersFor(req.headers.get('origin'))
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405, cors)
  if (!RESEND_API_KEY) return json({ error: 'email_not_configured', detail: 'RESEND_API_KEY not set' }, 503, cors)

  // -- AUTH. A real signed-in user, not merely a valid-looking JWT. -----------
  const bearer = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
  if (!bearer) return json({ error: 'unauthorized', detail: 'no bearer token' }, 401, cors)
  const authClient = createClient(SUPABASE_URL, ANON_KEY || SERVICE_KEY)
  const { data: userData, error: userErr } = await authClient.auth.getUser(bearer)
  const user = userData?.user
  if (userErr || !user?.id) {
    // This is the branch the anon key lands in: it is a valid JWT with no user.
    return json({ error: 'unauthorized', detail: 'a signed-in staff user is required' }, 401, cors)
  }
  const actorEmail = user.email ?? null
  const actorUserId = user.id

  let body: Record<string, unknown>
  try { body = await req.json() } catch { return json({ error: 'bad_json' }, 400, cors) }
  const visitId = Number(body?.visit_id)
  if (!Number.isFinite(visitId) || visitId <= 0) return json({ error: 'visit_id_required' }, 400, cors)
  const confirmResend = body?.confirm_resend === true

  const sb = createClient(SUPABASE_URL, SERVICE_KEY, {
    global: { headers: { 'x-app-source': 'send-visit-photos-email' } },
  })

  const logSend = async (
    status: string, reason: string | null, photoCount: number, bytes: number,
    resendId: string | null, subject: string | null,
  ) => {
    try {
      const { error } = await sb.from('visit_photo_email_sends').insert({
        visit_id: visitId, recipient_email: TEST_RECIPIENT, status, reason,
        is_test: IS_TEST, photo_count: photoCount, bytes_sent: bytes,
        resend_email_id: resendId, subject,
        sent_by_email: actorEmail, sent_by_user_id: actorUserId,
      })
      if (error) console.error(`[send-visit-photos-email] log insert failed: ${error.message}`)
    } catch (e) {
      console.error(`[send-visit-photos-email] log insert threw: ${String((e as Error)?.message ?? e)}`)
    }
  }

  try {
    // -- visit + client + address -------------------------------------------
    const { data: v, error: vErr } = await sb
      .from('visits')
      // ⚠ properties columns are address / city / state / zip. NOT address_line1 or
      // postal_code: those were a guess, and PostgREST reported them only at runtime
      // (the deploy succeeded regardless, so nothing caught it until the first call).
      .select('id, visit_date, deleted_at, client_id, property_id, clients(name, client_code), properties(address, city, state, zip)')
      .eq('id', visitId)
      .maybeSingle()
    if (vErr) throw new Error(`visit lookup failed: ${vErr.message}`)
    if (!v) { await logSend('skipped', 'visit_not_found', 0, 0, null, null); return json({ error: 'visit_not_found' }, 404, cors) }
    if (v.deleted_at) { await logSend('skipped', 'visit_deleted', 0, 0, null, null); return json({ error: 'visit_deleted' }, 409, cors) }

    const cl = (v as Record<string, any>).clients ?? {}
    const pr = (v as Record<string, any>).properties ?? {}
    const visitRow: VisitRow = {
      visit_id: visitId,
      client_name: cl?.name ?? 'Unknown client',
      client_code: cl?.client_code ?? null,
      address: composeAddress(pr?.address, pr?.city, pr?.state, pr?.zip),
      visit_date: String(v.visit_date ?? '').slice(0, 10),
    }

    // -- the gate: EVERY image on this visit must be classified --------------
    const { data: links, error: lErr } = await sb
      .from('photo_links')
      .select('id, photos!inner(storage_path, file_name, content_type, size_bytes)')
      .eq('entity_type', 'visit').eq('entity_id', visitId).is('deleted_at', null)
    if (lErr) throw new Error(`photo lookup failed: ${lErr.message}`)

    const images = (links ?? []).filter((l: any) => String(l.photos?.content_type ?? '').startsWith('image/'))
    if (images.length === 0) { await logSend('skipped', 'no_photos', 0, 0, null, null); return json({ error: 'no_photos' }, 409, cors) }

    const { data: cls, error: cErr } = await sb
      .from('photo_classifications')
      .select('photo_link_id, service_phase')
      .in('photo_link_id', images.map((l: any) => l.id))
    if (cErr) throw new Error(`classification lookup failed: ${cErr.message}`)
    const phaseBy = new Map<number, string>((cls ?? []).map((c: any) => [c.photo_link_id, c.service_phase]))

    const unclassified = images.length - phaseBy.size
    if (unclassified > 0) {
      await logSend('skipped', `not_classified:${unclassified}`, 0, 0, null, null)
      return json({ error: 'not_classified', unclassified, total: images.length }, 409, cors)
    }

    // -- idempotency: send-derm-email has none, and it double-sent 9 times ----
    const { data: prior, error: pErr } = await sb
      .from('visit_photo_email_sends')
      .select('id, sent_at, sent_by_email, photo_count')
      .eq('visit_id', visitId).eq('status', 'sent')
      .order('sent_at', { ascending: false }).limit(1)
    if (pErr) throw new Error(`send-log lookup failed: ${pErr.message}`)
    if (prior && prior.length > 0 && !confirmResend) {
      return json({
        error: 'already_sent',
        detail: 'This visit was already emailed. Re-send with confirm_resend to override.',
        previous: prior[0],
      }, 409, cors)
    }

    // -- fetch, downscale, attach -------------------------------------------
    const ordered = [...images].sort((a: any, b: any) => {
      const rank = (id: number) => PHASE_RANK[phaseBy.get(id) ?? 'extra'] ?? 3
      return rank(a.id) - rank(b.id)
    })

    const prepared: Prepared[] = []
    const skipped: { file: string; reason: string }[] = []
    let total = 0
    let decodes = 0

    for (const l of ordered) {
      if (prepared.length >= MAX_PHOTOS) { skipped.push({ file: l.photos.file_name ?? String(l.id), reason: 'photo_cap' }); continue }
      if (total >= MAX_TOTAL_BYTES) { skipped.push({ file: l.photos.file_name ?? String(l.id), reason: 'size_cap' }); continue }
      const srcBytes = Number(l.photos.size_bytes ?? 0)
      if (srcBytes > MAX_SOURCE_BYTES) { skipped.push({ file: l.photos.file_name ?? String(l.id), reason: 'source_too_large' }); continue }

      try {
        const { data: blob, error: dErr } = await sb.storage.from(BUCKET).download(l.photos.storage_path)
        if (dErr || !blob) { skipped.push({ file: l.photos.file_name ?? String(l.id), reason: 'download_failed' }); continue }
        const raw = new Uint8Array(await blob.arrayBuffer())

        let out: Uint8Array
        let ct = String(l.photos.content_type ?? 'image/jpeg')
        let ext = ct === 'image/png' ? 'png' : ct === 'image/webp' ? 'webp' : 'jpg'

        if (raw.byteLength <= RESIZE_ABOVE_BYTES || decodes >= MAX_DECODES_PER_CALL) {
          // Already small enough to attach as-is. Skipping the decode is what keeps
          // this call inside the worker's compute budget.
          out = raw
        } else {
          decodes++
          try {
            const img = await decode(raw)
            if (!(img instanceof Image)) throw new Error('not a raster image')
            if (Math.max(img.width, img.height) > MAX_EDGE_PX) {
              if (img.width >= img.height) img.resize(MAX_EDGE_PX, Image.RESIZE_AUTO)
              else img.resize(Image.RESIZE_AUTO, MAX_EDGE_PX)
            }
            out = await img.encodeJPEG(JPEG_QUALITY)
            ct = 'image/jpeg'; ext = 'jpg'
          } catch {
            // Undecodable (HEIC, corrupt, animated). Attach the original only if it is
            // small enough to be worth it; never blow the budget on it.
            if (raw.byteLength > 4 * 1024 * 1024) { skipped.push({ file: l.photos.file_name ?? String(l.id), reason: 'undecodable_and_large' }); continue }
            out = raw
          }
        }

        if (total + out.byteLength > MAX_TOTAL_BYTES) { skipped.push({ file: l.photos.file_name ?? String(l.id), reason: 'size_cap' }); continue }
        total += out.byteLength

        const phase = phaseBy.get(l.id) ?? 'extra'
        const n = prepared.filter((p) => p.phase === phase).length + 1
        prepared.push({
          filename: `${PHASE_LABEL[phase] ?? 'Photo'}-${n}.${ext}`,
          content: encodeBase64(out),
          content_type: ct,
          phase, bytes: out.byteLength,
        })
      } catch (e) {
        skipped.push({ file: l.photos.file_name ?? String(l.id), reason: String((e as Error)?.message ?? e).slice(0, 80) })
      }
    }

    if (prepared.length === 0) {
      await logSend('error', 'no_attachable_photos', 0, 0, null, null)
      return json({ error: 'no_attachable_photos', skipped }, 502, cors)
    }

    // Fred's subject line, verbatim: "Grease Trap Service Completed — [Client Name],
    // [Address] ([Date])". While IS_TEST the real subject is prefixed so a stray copy in
    // an inbox is unmistakable; the BODY is left exactly as a municipality would see it.
    const realSubject = buildSubject(visitRow)
    const subject = IS_TEST ? `[TEST] ${realSubject}` : realSubject
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: RESEND_FROM,
        to: [TEST_RECIPIENT],
        reply_to: CONTACT_EMAIL,
        subject,
        html: buildHtml(visitRow, prepared),
        text: buildText(visitRow, prepared),
        attachments: prepared.map((p) => ({ filename: p.filename, content: p.content, content_type: p.content_type })),
      }),
    })
    const er = await res.json().catch(() => ({}))
    if (!res.ok) {
      await logSend('error', 'resend_failed', prepared.length, total, null, subject)
      return json({ error: 'resend_failed', detail: er }, 502, cors)
    }

    const resendId = (er as { id?: string })?.id ?? null
    await logSend('sent', null, prepared.length, total, resendId, subject)
    return json({
      ok: true, is_test: IS_TEST, sent_to: TEST_RECIPIENT, visit_id: visitId,
      attached: prepared.length, bytes: total,
      by_phase: prepared.reduce((a, p) => { a[p.phase] = (a[p.phase] ?? 0) + 1; return a }, {} as Record<string, number>),
      skipped, resend_email_id: resendId, subject,
    }, 200, cors)
  } catch (e) {
    const msg = String((e as Error)?.message ?? e)
    await logSend('error', msg.slice(0, 200), 0, 0, null, null)
    return json({ error: 'unexpected', detail: msg }, 500, cors)
  }
})
