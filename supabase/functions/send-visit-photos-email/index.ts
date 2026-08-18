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

// 🛑 2026-08-15, SECOND PASS: THE ATTACHMENT IS NOW ONE PDF, NOT N LOOSE PHOTOS.
// Fred, after visually checking a real send: "we attached the image on the email ... but
// we can't know which images are for before and after service, so instead of those images,
// I think it's better if we get the report from the FP App, which let's us save it as a
// PDF." He is right, and loose attachments could not be fixed by naming them: Gmail shows
// thumbnails, so Before-1.jpg / After-1.jpg told the recipient nothing.
// The Field Portal already renders a print-ready 2-page Service Report with LABELLED
// "Before Service Pictures" / "After Service Pictures" sections, so that document is the
// answer and it is rendered to PDF by the pdf-service.
// ⇒ The whole ImageScript resize path is GONE, and with it the memory ceiling that capped
// attachments at 10 photos. One PDF carries every photo.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { encodeBase64 } from 'https://deno.land/std@0.224.0/encoding/base64.ts'

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')
const RESEND_FROM = Deno.env.get('RESEND_FROM') ?? 'Unclogme <onboarding@resend.dev>'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''

// 🛑 Hard-wired while city sending is off. Fred: "test-send only to me".
const TEST_RECIPIENT = 'fred@ayache.com'
const IS_TEST = true

// 🛑 THE SETTLING WINDOW. Photos keep arriving after a visit is completed, so a report
// sent too early can be missing one. Fred chose 48h on 2026-08-17 from these numbers,
// measured over 268 visits completed in the last 90 days (migration sources excluded,
// they backfilled months-old visits and produce a fake 2821h tail):
//
//   last photo lands within  6h 69.0% | 12h 89.9% | 24h 97.4% | 48h 100.0%
//   median 4.27h · p90 12.06h · worst case actually observed 42.40h
//
// ⚠ 24h leaves 7 of 268 visits (1 in 38) still receiving photos. 48h clears the worst
// observed case by only 5.6h, so treat this as SAFE, NOT CERTAIN: zero events in 268
// observations bounds the true miss rate at roughly 1 in 90, it does not prove zero.
// The `confirm_resend` path stays the backstop for the miss.
// 🛑 A "quiet for N hours since the last photo" rule was measured and REJECTED: the
// largest gap between consecutive photos on one visit is 35.68h, so a quiet rule needs
// ~36h to match this one. No safer, more moving parts. Do not reintroduce it.
const SETTLING_HOURS = 48

// 🛑 THE TEST RECIPIENT IS CALLER-SUPPLIED BUT DOMAIN-LOCKED, AND THE LOCK LIVES HERE.
// Fred, 2026-08-16, asked for a modal to choose which address the test goes to. That
// reintroduces a caller-supplied recipient, which is exactly the shape of the
// send-derm-email defect: it accepts `test_recipient` as ANY string containing '@' with
// no allowlist, so whoever can reach the function decides who receives a client's
// compliance documents. The difference that makes this acceptable is the allowlist below:
// the worst a caller can do is reach an internal inbox.
// ⚠ THE UI ALSO VALIDATES. THAT IS CONVENIENCE, NOT A CONTROL. A UI check is bypassed by
// anyone posting directly, so this regex is the only thing actually holding the line.
const ALLOWED_RECIPIENT_DOMAINS = ['ayache.com', 'unclogme.com']

// 🛑 A REGEX LITERAL, NOT A STRING PASSED TO new RegExp(). This was written the other way
// first and it was silently WRONG: inside a JS string literal '\s' is not a recognised
// escape and collapses to a bare 's', and '\.' collapses to '.', so
//     new RegExp('^[^@\s]+@(' + ... + ')$')
// compiled to ^[^@s]+@(ayache.com|unclogme.com)$ — MEASURED, that is the literal .source
// of the broken version. Two independent defects, in opposite directions:
//   accepts  fred@ayacheXcom, fred@ayache-com, fred@unclogmeQcom   (unescaped dots match
//            ANY character, so a lookalike domain passes the allowlist)
//   rejects  swanson@ayache.com                                    ([^@s] excludes the
//            letter "s", not whitespace, so valid addresses are refused)
// The false-ACCEPT is the one that matters: a domain allowlist that admits arbitrary
// lookalike domains is not an allowlist. Same class of bug as the SQL regex-transport
// trap in the root CLAUDE.md: the escape never survived the layer it was written in.
// A literal has no such layer.
const RECIPIENT_RE = /^[^@\s]+@(ayache\.com|unclogme\.com)$/i

// The literal above and the list are two statements of one rule, so assert they agree at
// module load rather than discovering a drift when a send is refused.
for (const d of ALLOWED_RECIPIENT_DOMAINS) {
  if (!RECIPIENT_RE.test(`probe@${d}`)) {
    throw new Error(`recipient allowlist drift: ${d} is listed but rejected by RECIPIENT_RE`)
  }
}
if (RECIPIENT_RE.test('probe@evil.com') || RECIPIENT_RE.test('probeXayache!com')) {
  throw new Error('recipient allowlist is too permissive; check the escaping in RECIPIENT_RE')
}

// 🛑 AT PROD CUTOVER THIS WHOLE PARAMETER IS DELETED, ALONG WITH THE MODAL.
// Fred, 2026-08-16: "when changed to prod we need to remove that modal. On prod it needs
// to send directly to the correct email set for it." The real recipient must then be
// resolved server-side from public.municipality_regulators, matched on the property's
// city, the way send-derm-email does. NEVER from the request.
// While IS_TEST is true the blast radius of a caller-supplied address is an internal
// inbox; the moment city sending is enabled it becomes "anyone can direct a client's DERM
// document anywhere". So do not flip IS_TEST without removing this in the same change.
// Checklist: Building Apps/Admin Review/docs/11-city-email.md
function resolveTestRecipient(raw: unknown): { email: string } | { error: string } {
  if (raw === undefined || raw === null || raw === '') return { email: TEST_RECIPIENT }
  if (typeof raw !== 'string') return { error: 'recipient_not_allowed' }
  const candidate = raw.trim()
  // ⚠ fullmatch semantics: the anchors plus the [^@\s]+ class mean a trailing newline or a
  // second address cannot be smuggled in. "a@ayache.com,b@evil.com" fails, as it must.
  if (!RECIPIENT_RE.test(candidate)) return { error: 'recipient_not_allowed' }
  return { email: candidate }
}

// The Field Portal report, rendered to PDF by the pdf-service on Railway. Both secrets
// already exist for generate-fog-manifest / generate-derm-address-pdf; reused, not new.
const PDF_SERVICE_URL = Deno.env.get('PDF_SERVICE_URL')
const PDF_SERVICE_API_KEY = Deno.env.get('PDF_SERVICE_API_KEY')
// ⚠ MUST EXCEED THE RENDERER'S OWN WORST CASE, OR WE GIVE UP FIRST AND LOG A TIMEOUT
// FOR A RENDER THAT WAS ABOUT TO SUCCEED. Measured on the pdf-service: 30s render wall
// + up to 10s context close + up to 10s browser close = ~50s worst case. 45s was under
// that and would have produced misleading "pdf_service_unreachable" rows.
const PDF_TIMEOUT_MS = 65_000

// 🛑 THE OLD 10-PHOTO CAP IS GONE, AND SO IS THE REASON FOR IT.
// The first version attached N re-encoded JPEGs and hit the worker's MEMORY ceiling
// (measured: 10 photos worked at 1.6MB/6.6s; 17 returned WORKER_RESOURCE_LIMIT, and 17
// with every decode REMOVED failed FASTER, at 3.0s, which is what ruled out CPU).
// Attaching a single server-rendered PDF removes that whole class of problem: nothing is
// decoded here, one document carries every photo, and the FP report labels which are
// before and which are after. The Resend ceiling is 40MB and a rendered report is a
// couple of MB, so the only guard still needed is the sanity check on the returned bytes.
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

// `counts` is the CLASSIFICATION tally for the visit, not a count of attachments: there
// is exactly one attachment now (the report), and it contains all of the photos.
// 🛑 THE PHASES THE ATTACHMENT ACTUALLY CONTAINS. `internal` is deliberately absent.
// ONE definition, used by BOTH builders. There were two independent `Object.values(counts)` sums
// here (HTML and plain text) and fixing only the first left the plain-text body still saying
// "(17 photos)" — which is the exact line the regulator reads. Keeping two copies in step by
// hand is what produced this defect; do not re-inline it.
const CUSTOMER_PHASES = ['before', 'after', 'extra'] as const
const customerPhotoCount = (counts: Record<string, number>): number =>
  CUSTOMER_PHASES.reduce((a, p) => a + (counts[p] ?? 0), 0)

function buildHtml(v: VisitRow, counts: Record<string, number>): string {
  const name = escapeHtml(v.client_name)
  const addr = escapeHtml(v.address)
  const vdate = escapeHtml(fmtDate(v.visit_date))
  const beforeN = counts.before ?? 0
  const afterN = counts.after ?? 0
  // 🛑 THE COUNT MUST MATCH THE ATTACHMENT, AND `internal` IS NOT IN THE ATTACHMENT (2026-08-16).
  // This summed EVERY classification, internal included, so the covering email told a municipal
  // regulator "(17 photos)" while the PDF carried 14. Measured on visit 7751: before 5 + after 5 +
  // extra 4 = 14 in the report, internal 3, total 17 in the email. A regulator who counts the
  // photos finds three fewer than promised, which on a compliance document reads as withheld
  // evidence — the exact impression the internal filter exists to prevent.
  // ⚠ `internal` is ALSO struck from the breakdown below: naming it would announce to the city that
  // photos exist which they are not being shown. Worse than the wrong total.
  // ⇒ Anything added to PHASE_LABEL that the customer payload does not serve must be excluded here
  // too. The rule is "count what is in the attachment", not "count what we hold".
  const totalN = customerPhotoCount(counts)
  const breakdown = CUSTOMER_PHASES
    .map((p) => [PHASE_LABEL[p], counts[p] ?? 0] as const)
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
<td valign="middle" width="40" style="width:40px;"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr><td align="center" valign="middle" height="40" style="width:40px;height:40px;background-color:#f14714;border-radius:8px;font-family:Arial,Helvetica,sans-serif;font-size:11px;font-weight:bold;color:#ffffff;letter-spacing:0.5px;">PDF</td></tr></table></td>
<td valign="middle" style="padding-left:14px;font-family:${FONT_STACK};">
<div style="font-size:14px;font-weight:600;color:#111827;line-height:1.3;">Job Completion Report${beforeN > 0 && afterN > 0 ? ' (with before &amp; after photos)' : ' (service photos)'}</div>
<div style="font-size:13px;color:#6b7280;line-height:1.3;padding-top:2px;">${totalN} photo${totalN === 1 ? '' : 's'}${breakdown ? ' &middot; ' + breakdown : ''}</div>
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
function buildText(v: VisitRow, counts: Record<string, number>): string {
  const totalN = customerPhotoCount(counts)   // NOT Object.values(counts) — that included internal
  return [
    'Dear Environmental Compliance Team,', '',
    'We are writing to confirm that the scheduled grease trap service for the location below has been successfully completed.', '',
    'Service Details:',
    `  - Client: ${v.client_name}.`,
    `  - Location: ${v.address}.`,
    `  - Service Date: ${fmtDate(v.visit_date)}.`,
    `  - Service Type: ${SERVICE_TYPE_LABEL}.`, '',
    `Attached: Job Completion Report (${totalN} photo${totalN === 1 ? '' : 's'})`, '',
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
  address: string; visit_date: string; public_id: string | null
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

  const resolved = resolveTestRecipient((body as Record<string, unknown>)?.test_recipient)
  if ('error' in resolved) {
    // Refused BEFORE any render or send, and deliberately not logged to
    // visit_photo_email_sends: nothing was attempted, so a log row would imply one was.
    return json({
      error: 'recipient_not_allowed',
      detail: `Test emails may only go to ${ALLOWED_RECIPIENT_DOMAINS.map((d) => '@' + d).join(' or ')}.`,
      allowed_domains: ALLOWED_RECIPIENT_DOMAINS,
    }, 422, cors)
  }
  const recipient = resolved.email

  const sb = createClient(SUPABASE_URL, SERVICE_KEY, {
    global: { headers: { 'x-app-source': 'send-visit-photos-email' } },
  })

  const logSend = async (
    status: string, reason: string | null, photoCount: number, bytes: number,
    resendId: string | null, subject: string | null,
  ) => {
    try {
      const { error } = await sb.from('visit_photo_email_sends').insert({
        visit_id: visitId, recipient_email: recipient, status, reason,
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
      .select('id, visit_date, completed_at, deleted_at, client_id, property_id, public_id, derm_required, clients(name, client_code), properties(address, city, state, zip)')
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
      public_id: (v as Record<string, any>).public_id ?? null,
    }

    // -- GATE 1: the visit must be DERM-required ------------------------------
    // 🛑 Fred, 2026-08-15: "it means the visit needs to be DERM Required, because the way
    // it shows in the FP app is if it's a derm required." That is not a preference, it is
    // a hard dependency: the FP report reads `customer.work_orders`, which ends with
    // `AND COALESCE(v.derm_required, true) = true`, so a non-DERM visit has NO report at
    // all. Verified live: visit 7751 (true) renders the full 2-page report; visit 7674
    // (false) renders "Report not available".
    // ⚠ THE EXPRESSION IS `COALESCE(..., true)`, NOT `IS TRUE`. NULL counts as required
    // and is the fail-safe answer (39 completed NULL visits ARE visible in the portal).
    // Writing `=== true` here would silently refuse those.
    const dermRequired = (v as Record<string, any>).derm_required
    if (dermRequired === false) {
      await logSend('skipped', 'not_derm_required', 0, 0, null, null)
      return json({
        error: 'not_derm_required',
        detail: 'The Field Portal only publishes a Service Report for DERM-required visits, so there is nothing to attach.',
      }, 409, cors)
    }
    if (!visitRow.client_code || !visitRow.public_id) {
      await logSend('skipped', 'no_report_url', 0, 0, null, null)
      return json({ error: 'no_report_url', detail: 'Visit has no client_code or public_id, so the report URL cannot be built.' }, 409, cors)
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

    // -- GATE: the photo set must have SETTLED (see SETTLING_HOURS at the top) -----
    // This runs AFTER the classification gate on purpose: if photos are still untagged,
    // "go classify them" is the more useful thing to say than "come back tomorrow".
    // ⚠ It is the SERVER check that is the control. The app hides the button too, but
    // per docs/11-city-email.md Rule 3 the UI check is convenience, never the gate.
    const completedAtRaw = (v as Record<string, any>).completed_at
    const completedAt = completedAtRaw ? new Date(completedAtRaw) : null
    if (!completedAt || Number.isNaN(completedAt.getTime())) {
      // Fail CLOSED. A visit with no completion time has no clock to measure against, so
      // we cannot show the window has passed, and "cannot show it passed" is not "passed".
      await logSend('skipped', 'not_settled:no_completed_at', 0, 0, null, null)
      return json({
        error: 'not_settled',
        detail: 'This visit has no completion time recorded, so the 48 hour settling window cannot be checked.',
      }, 409, cors)
    }
    const readyAt = new Date(completedAt.getTime() + SETTLING_HOURS * 3600_000)
    const msLeft = readyAt.getTime() - Date.now()
    if (msLeft > 0) {
      const hoursLeft = Math.ceil(msLeft / 3600_000)
      await logSend('skipped', `not_settled:${hoursLeft}h`, 0, 0, null, null)
      return json({
        error: 'not_settled',
        detail: `Photos can still arrive for up to ${SETTLING_HOURS} hours after a visit is completed. This one can be sent in about ${hoursLeft} hour${hoursLeft === 1 ? '' : 's'}.`,
        ready_at: readyAt.toISOString(),
        hours_left: hoursLeft,
        settling_hours: SETTLING_HOURS,
      }, 409, cors)
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

    // -- render the Field Portal Service Report to PDF -----------------------
    // ONE attachment, produced from the FP page the client already sees, so the
    // municipality gets labelled "Before Service Pictures" / "After Service Pictures"
    // sections instead of N indistinguishable images.
    if (!PDF_SERVICE_URL || !PDF_SERVICE_API_KEY) {
      await logSend('error', 'pdf_service_not_configured', 0, 0, null, null)
      return json({ error: 'service_not_configured', detail: 'PDF_SERVICE_URL / PDF_SERVICE_API_KEY not set' }, 503, cors)
    }

    const phaseCounts = { before: 0, after: 0, internal: 0, extra: 0 } as Record<string, number>
    for (const p of phaseBy.values()) if (p in phaseCounts) phaseCounts[p]++

    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), PDF_TIMEOUT_MS)
    let pdfBytes: Uint8Array
    try {
      const target = `${PDF_SERVICE_URL.replace(/\/$/, '')}/generate/visit-report`
      const up = await fetch(target, {
        method: 'POST', signal: ctrl.signal,
        headers: { Authorization: `Bearer ${PDF_SERVICE_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ client_code: visitRow.client_code, public_id: visitRow.public_id }),
      })

      // 🛑 409 means the renderer REFUSED, and every reason it refuses is a reason not
      // to send. Never fall through and email a PDF of an error page to a regulator.
      //   report_not_available -> the FP page showed the placeholder. For a DERM-required
      //                           visit that should be impossible, so it means something
      //                           upstream changed and a human needs to look.
      //   client_mismatch      -> the rendered report is for a DIFFERENT client than the
      //                           one we asked about. Measured 2026-08-15: the FP report
      //                           resolves purely from public_id and IGNORES the client
      //                           slug in the URL, so /293-alc/visit/<306-16 id>/report
      //                           happily serves 306-16's report. Sending that would put
      //                           one client's compliance document in a regulator's inbox
      //                           under another client's name.
      if (up.status === 409) {
        let code = 'report_not_available'
        try { code = (await up.clone().json())?.error ?? code } catch { /* keep default */ }
        await logSend('skipped', code, 0, 0, null, null)
        return json({
          error: code,
          detail: code === 'client_mismatch'
            ? 'The rendered report belongs to a different client. Nothing was sent.'
            : 'The Field Portal has no report for this visit.',
        }, 409, cors)
      }
      // The renderer caps concurrent Chromium instances; a burst is a retry, not a failure.
      if (up.status === 503) {
        await logSend('skipped', 'renderer_busy', 0, 0, null, null)
        return json({ error: 'renderer_busy', detail: 'The report renderer is busy. Try again in a moment.' }, 503, cors)
      }
      if (!up.ok) {
        const detail = (await up.text().catch(() => '')).slice(0, 300)
        await logSend('error', `pdf_service_${up.status}`, 0, 0, null, null)
        return json({ error: 'pdf_service_failed', status: up.status, detail }, 502, cors)
      }

      // ⚠ Check the CONTENT TYPE, not just the status. The repo has been bitten by an
      // upstream returning HTML at HTTP 200 (Jobber's waiting room), and a PDF-shaped
      // pipeline that accepts HTML would attach an error page.
      const ctype = up.headers.get('content-type') ?? ''
      if (!ctype.includes('pdf')) {
        await logSend('error', `pdf_service_bad_ctype:${ctype.slice(0, 40)}`, 0, 0, null, null)
        return json({ error: 'pdf_service_bad_content_type', detail: ctype }, 502, cors)
      }
      pdfBytes = new Uint8Array(await up.arrayBuffer())
    } catch (e) {
      const msg = ctrl.signal.aborted ? `timeout after ${PDF_TIMEOUT_MS}ms` : String((e as Error)?.message ?? e)
      await logSend('error', `pdf_service:${msg}`.slice(0, 200), 0, 0, null, null)
      return json({ error: 'pdf_service_unreachable', detail: msg }, 502, cors)
    } finally {
      clearTimeout(timer)
    }

    // A PDF starts with %PDF. Cheap structural check so a 0-byte or truncated render
    // cannot be emailed as if it were a document.
    if (pdfBytes.byteLength < 1000 || String.fromCharCode(...pdfBytes.slice(0, 4)) !== '%PDF') {
      await logSend('error', `pdf_invalid:${pdfBytes.byteLength}b`, 0, 0, null, null)
      return json({ error: 'pdf_invalid', bytes: pdfBytes.byteLength }, 502, cors)
    }

    const total = pdfBytes.byteLength
    const reportName = `Service-Report-${visitRow.client_code}-${visitRow.visit_date}.pdf`
    const prepared: Prepared[] = [{
      filename: reportName,
      content: encodeBase64(pdfBytes),
      content_type: 'application/pdf',
      phase: 'report',
      bytes: total,
    }]
    const skipped: { file: string; reason: string }[] = []

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
        to: [recipient],
        reply_to: CONTACT_EMAIL,
        subject,
        html: buildHtml(visitRow, phaseCounts),
        text: buildText(visitRow, phaseCounts),
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
      ok: true, is_test: IS_TEST, sent_to: recipient, visit_id: visitId,
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
