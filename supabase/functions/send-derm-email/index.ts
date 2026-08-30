// ============================================================================
// send-derm-email/index.ts — Edge Function
// ============================================================================
// Sends DERM manifests via Resend. TWO targets (body `target`, default 'client'):
//   target:'client' — "Send DERM to client": the FP Service Report to the client's own
//     email, friendly branded copy.
//   target:'city'   — "Send DERM to City": the FP Service Report to the municipal
//     FOG-program email(s) of the served location, formal copy, BCC derm@ayache.com.
// 🛑 NEITHER SENDS THE RAW MANIFEST IMAGES OR THE RECEIPT ANY MORE (Fred, 2026-08-26).
//   The Service Report embeds the redacted FOG eManifest and the WWTP receipt, so attaching
//   them alongside it would deliver the same two documents twice.
//
// Input (POST JSON):
//   { recipients: [{ manifest_id, client_id, property_id? }],   // or manifest_ids: number[]
//     target?: 'client' | 'city',                 // default 'client'
//     test_recipient?: string,                    // if set, send ONLY there (is_test) — real clients/city NOT emailed
//     test_cc?: string }                           // "send to both": REAL send to clients/city + BCC a copy here
//
// Logs every attempt to public.derm_email_sends with recipient_type = target.
// Auth: 🛑 CORRECTED 2026-08-28 - this said "anon-callable for MVP" and that is no longer
//       true. 79f24c7 added a real gate ~570 lines below: service_role OR a signed-in staff
//       user via auth.getUser(bearer); anon is refused 401. Still origin-restricted to
//       derm.unclogme.app, and the gate deliberately sits AFTER the OPTIONS reply.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// 🛑 COPIED BYTE-FOR-BYTE FROM send-visit-photos-email/index.ts (2026-08-25). Do not edit
//    one copy without the other, and do not retype either. Same incident, same reason:
//    std@0.224.0's encodeBase64 appends one character at a time and burns ~32 bytes of
//    V8 heap per output character, which OOM-kills the worker. An OOM is a PLATFORM kill,
//    so no catch runs, no finally runs, and derm_email_sends records nothing at all.
//    This function's worst measured payload is ~5.36MB across 2 attachments = ~7.15M
//    base64 chars = ~229MB, against a ceiling that killed a worker at 277.7MB. It had
//    single-digit percent headroom on the regulator-facing city path.
const B64_CHUNK = 3 * 16384 // 49152 bytes. MUST stay a multiple of 3 — see below.
const FROM_CHARCODE_MAX = 8192 // spread arg count; ~65536+ throws RangeError.

/**
 * Base64 without the cons-string explosion: encode in blocks, join once.
 *
 * 🛑 B64_CHUNK MUST BE A MULTIPLE OF 3. Base64 encodes 3 input bytes to 4 output chars,
 * so slicing on a multiple of 3 lets each block encode independently and the pieces
 * concatenate exactly. A chunk size that is NOT a multiple of 3 makes btoa emit '='
 * padding in the MIDDLE of the stream, which produces a corrupt attachment that still
 * looks like valid base64 and still sends — i.e. a broken PDF in a regulator's inbox with
 * no error anywhere. The round-trip assertion at the call site is what guards this.
 */
function encodeBase64Chunked(bytes: Uint8Array): string {
  const parts: string[] = []
  for (let i = 0; i < bytes.length; i += B64_CHUNK) {
    const chunk = bytes.subarray(i, Math.min(i + B64_CHUNK, bytes.length))
    let bin = ''
    for (let j = 0; j < chunk.length; j += FROM_CHARCODE_MAX) {
      bin += String.fromCharCode(...chunk.subarray(j, j + FROM_CHARCODE_MAX))
    }
    parts.push(btoa(bin))
  }
  return parts.join('')
}

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')
const RESEND_FROM = Deno.env.get('RESEND_FROM') ?? 'Unclogme <onboarding@resend.dev>'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

// 🛑 test_recipient REPLACES the real municipal recipients, so it is a redirect primitive, not a
// convenience. It used to accept any string containing '@'. Combined with the missing auth gate
// below, that let anyone holding the PUBLIC anon key have any manifest's compliance documents
// mailed to an address of their choosing. Same allowlist shape as send-visit-photos-email.
const ALLOWED_TEST_DOMAINS = ['ayache.com', 'unclogme.com']
const TEST_RECIPIENT_RE = /^[^@\s]+@(ayache\.com|unclogme\.com)$/i
// The list and the literal are two statements of one rule; assert they agree at module load
// rather than discovering the drift when a send is refused (or worse, allowed).
for (const d of ALLOWED_TEST_DOMAINS) {
  if (!TEST_RECIPIENT_RE.test(`probe@${d}`)) {
    throw new Error(`test-recipient allowlist drift: ${d} is listed but rejected by TEST_RECIPIENT_RE`)
  }
}
if (TEST_RECIPIENT_RE.test('probe@evil.com') || TEST_RECIPIENT_RE.test('probeXayache!com')) {
  throw new Error('test-recipient allowlist is too permissive; check the escaping in TEST_RECIPIENT_RE')
}

// Cc / Bcc are CALLER-SUPPLIED RECIPIENTS on a regulator- and client-facing email, held to exactly
// the same allowlist as the To address. Nothing about a copy makes it safer than the original.
const MAX_COPY_RECIPIENTS = 10
/**
 * 🛑 REFUSES, NEVER SILENTLY DROPS. Dropping a bad address sends the mail while the sender believes
 * someone was copied - they would never find out. The offending address is named back so the UI can
 * point at the right chip.
 */
function parseCopyList(raw: unknown, field: string, exclude: string[]): { list: string[] } | { error: string } {
  if (raw == null) return { list: [] }
  const arr = Array.isArray(raw) ? raw : [raw]
  const seen = new Set(exclude.filter(Boolean).map((e) => e.toLowerCase()))
  const out: string[] = []
  for (const v of arr) {
    const a = String(v ?? '').trim()
    if (!a) continue
    if (!TEST_RECIPIENT_RE.test(a)) return { error: `${field} address not allowed: ${a}` }
    const k = a.toLowerCase()
    if (seen.has(k)) continue
    seen.add(k)
    out.push(a)
  }
  if (out.length > MAX_COPY_RECIPIENTS) return { error: `${field} accepts at most ${MAX_COPY_RECIPIENTS} addresses` }
  return { list: out }
}

// ── THE CITY AND THE CLIENT BOTH GET THE FP SERVICE REPORT (Fred, 2026-08-26):
//    "we don't send the DERM Manifests, or the receipts anymore, we send the Report PDF
//    Files from the FP App." The report embeds both compliance documents.
// Both secrets already exist project-wide (generate-fog-manifest, send-visit-photos-email
// and others read them), so nothing new needs creating; the preflight below covers unset.
const PDF_SERVICE_URL = Deno.env.get('PDF_SERVICE_URL')
const PDF_SERVICE_API_KEY = Deno.env.get('PDF_SERVICE_API_KEY')
// ⚠ COPIED, NOT RE-TUNED. send-visit-photos-email measured 45s as too low and producing
// misleading 'pdf_service_unreachable' rows for renders that were about to succeed.
const PDF_TIMEOUT_MS = 65_000
// 🛑 THIS LOOP IS NOT THE SIBLING'S SINGLE SEND. `recipients` is caller-supplied and
// UNCAPPED, and the largest observed real burst is 7 city sends in one minute. Seven
// serial 65s renders is 455s in one invocation, and a platform wall-clock or OOM kill runs
// NO catch and NO finally, so derm_email_sends would record nothing at all and the operator
// would see a network error instead of results[]. This bounds the whole invocation.
const RENDER_DEADLINE_MS = 120_000
// 8 MiB, deliberately NOT the sibling's 25 MiB: that function sends one email per
// invocation, this one loops. Worst measured city payload is ~5.36MB across 2 attachments
// (~229MB of heap against a ceiling that killed a worker at 277.7MB). Over this the letter
// goes out with no attachment, which is a visible outcome rather than a dead worker.
const MAX_REPORT_BYTES = 8 * 1024 * 1024

// 🛑 ONE SOURCE OF TRUTH FOR THE BRANCH COPY. The HTML and text variants sit adjacent so a
// change cannot land in one and not the other: send-visit-photos-email shipped exactly that
// bug, where a plain-text reader saw wording the HTML reader did not.
// 🛑 `none` MUST NOT CLAIM AN ATTACHMENT. Fred chose that a visit with no Service Report
// still gets the letter, so this branch is reachable and the copy has to be honest: the
// attachment sentence is omitted entirely rather than promising a document that is not there
// and may never exist (a non-DERM visit has no report at all, ever).
const CITY_ATTACH_COPY = {
  report: {
    preheader: (name: string) =>
      `DERM Manifest submission for ${name} &mdash; Service Report attached, including the Manifest Form and the Transporter Manifest, for your compliance records.`,
    html: `<p style="margin:0 0 16px 0;font-size:15px;line-height:1.65;color:#374151;">Attached, you'll find our <strong style="color:#111827;">Service Report</strong> for this service, which includes the <strong style="color:#111827;">Manifest Form</strong> and the corresponding <strong style="color:#111827;">Transporter Manifest</strong>.</p>`,
    text: ["Attached, you'll find our Service Report for this service, which includes the Manifest Form and the corresponding Transporter Manifest.", ''],
  },
  none: {
    preheader: (name: string) =>
      `DERM Manifest submission for ${name} &mdash; service completion notice for your compliance records.`,
    html: '',
    text: [] as string[],
  },
} as const

type CityAttachMode = keyof typeof CITY_ATTACH_COPY
const CITY_BCC = 'derm@ayache.com'

const ALLOWED_ORIGINS = new Set(['https://derm.unclogme.app'])

function corsHeadersFor(origin: string | null): Record<string, string> {
  const allowed = origin && ALLOWED_ORIGINS.has(origin) ? origin : 'https://derm.unclogme.app'
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, content-type, x-client-info, apikey, x-app-source',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  }
}

function jsonResponse(body: Record<string, unknown>, status: number, cors: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
}

// The attachment is the FP Service Report since 2026-08-26, so the subject names that.
// A subject promising a "Manifest Form" over a Service Report is a small lie the client
// reads before opening anything.
const SUBJECT = 'Your Service Report from Unclogme'

// Brand assets / tokens (UnclogMe). Logo hosted in our own Storage (stable URL).
const LOGO_URL = 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/_brand/unclogme-logo.jpg'
const FONT_STACK = "'Manrope', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"

// content-type → extension (shared by the client single-attachment + the city fetchAttachment)
const CT_TO_EXT: Record<string, string> = { 'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/jpg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/heic': 'heic', 'image/heif': 'heif' }

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] ?? c))
}

// 'YYYY-MM-DD' → 'Month D, YYYY' (tz-safe; falls back to the raw string).
function fmtDate(d: string | null): string {
  if (!d) return ''
  try { return new Date(d + 'T12:00:00Z').toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' }) } catch { return d }
}

// ---- CLIENT email (friendly, single WWTP receipt) — unchanged --------------
function buildHtml(clientName: string, number: string, ext: string): string {
  const name = escapeHtml(clientName)
  const fileLabel = `DERM-Manifest-${escapeHtml(number)}.${escapeHtml(ext)}`
  const badge = escapeHtml(ext.toUpperCase()).slice(0, 4)
  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><meta http-equiv="X-UA-Compatible" content="IE=edge"><title>${SUBJECT}</title></head>
<body style="margin:0;padding:0;background-color:#f4f5f7;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;font-size:1px;line-height:1px;color:#f4f5f7;">Your Service Report is attached &mdash; it includes your DERM Manifest Form and disposal receipt. Please keep it for your records.</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f4f5f7;"><tr><td align="center" style="padding:32px 16px;">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;background-color:#ffffff;border-radius:12px;border:1px solid #e6e8eb;border-top:4px solid #f14714;">
<tr><td style="padding:28px 36px 20px 36px;border-bottom:1px solid #eef0f2;"><img src="${LOGO_URL}" alt="UnclogMe" width="144" height="48" style="display:block;border:0;outline:none;text-decoration:none;height:48px;width:144px;"></td></tr>
<tr><td style="padding:32px 36px 4px 36px;font-family:${FONT_STACK};">
<p style="margin:0 0 18px 0;font-size:18px;line-height:1.5;font-weight:700;color:#111827;">Hi ${name},</p>
<p style="margin:0 0 16px 0;font-size:15px;line-height:1.65;color:#374151;">Thank you for choosing Unclogme!</p>
<p style="margin:0 0 24px 0;font-size:15px;line-height:1.65;color:#374151;">Attached, you'll find your <strong style="color:#111827;">Service Report</strong>, which includes your <strong style="color:#111827;">Manifest Form</strong> required by the Water &amp; Sewer Department and the corresponding disposal receipt. Please review it carefully and keep it for your records.</p>
</td></tr>
<tr><td style="padding:0 36px 28px 36px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#fff7f4;border:1px solid #ffd9c9;border-radius:10px;"><tr><td style="padding:16px 18px;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
<td valign="middle" width="40" style="width:40px;"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr><td align="center" valign="middle" height="40" style="width:40px;height:40px;background-color:#f14714;border-radius:8px;font-family:Arial,Helvetica,sans-serif;font-size:11px;font-weight:bold;color:#ffffff;letter-spacing:0.5px;">${badge}</td></tr></table></td>
<td valign="middle" style="padding-left:14px;font-family:${FONT_STACK};">
<div style="font-size:14px;font-weight:600;color:#111827;line-height:1.3;">Service Report attached</div>
<div style="font-size:13px;color:#6b7280;line-height:1.3;padding-top:2px;">${fileLabel}</div>
</td></tr></table>
</td></tr></table>
</td></tr>
<tr><td style="padding:0 36px 32px 36px;font-family:${FONT_STACK};">
<p style="margin:0;font-size:15px;line-height:1.65;color:#374151;">If you have any questions or need assistance regarding this document, please reach us at <a href="mailto:contact@unclogme.com" style="color:#d63d12;text-decoration:underline;font-weight:600;">contact@unclogme.com</a> or call us directly.</p>
</td></tr>
<tr><td style="padding:22px 36px 26px 36px;background-color:#fafbfc;border-top:1px solid #eef0f2;font-family:${FONT_STACK};">
<p style="margin:0 0 4px 0;font-size:13px;font-weight:700;color:#374151;">Unclogme LLC</p>
<p style="margin:0 0 2px 0;font-size:12px;line-height:1.5;color:#9ca3af;">333 West 41st Street, Suite 606, Miami Beach, FL 33140</p>
<p style="margin:0;font-size:12px;line-height:1.5;color:#9ca3af;"><a href="mailto:contact@unclogme.com" style="color:#9ca3af;text-decoration:underline;">contact@unclogme.com</a></p>
</td></tr>
</table>
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;"><tr><td style="padding:16px 36px;text-align:center;font-family:${FONT_STACK};font-size:11px;color:#b6bcc4;line-height:1.5;">Sent by Unclogme LLC regarding your grease trap service. Please retain this manifest for your compliance records.</td></tr></table>
</td></tr></table>
</body></html>`
}

function buildText(clientName: string, number: string, ext: string): string {
  return [
    `Hi ${clientName},`, '',
    'Thank you for choosing Unclogme!', '',
    `Attached, you'll find your Service Report (DERM-Service-Report-${number}.${ext}), which includes your Manifest Form required by the Water and Sewer Department and the corresponding disposal receipt. Please review it carefully and keep it for your records.`, '',
    'If you have any questions or need assistance regarding this document, please reach us at contact@unclogme.com or call us directly.', '',
    '--', 'Unclogme LLC', '333 West 41st Street, Suite 606, Miami Beach, FL 33140', 'contact@unclogme.com',
  ].join('\n')
}

// ---- CITY email (formal, to the municipal FOG office, two attachments) -----
// `mode` selects which attachment sentence the letter carries. It MUST agree with what is
// actually attached: under option B the city receives either one Service Report (which
// embeds both manifest documents) or the two manifest images, never both.
function buildCityHtml(clientName: string, address: string, visitDate: string, mode: CityAttachMode = 'none'): string {
  const name = escapeHtml(clientName)
  const addr = escapeHtml(address || '')
  const vdate = escapeHtml(visitDate || '')
  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><meta http-equiv="X-UA-Compatible" content="IE=edge"><title>DERM Manifest for ${name}</title></head>
<body style="margin:0;padding:0;background-color:#f4f5f7;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;font-size:1px;line-height:1px;color:#f4f5f7;">${CITY_ATTACH_COPY[mode].preheader(name)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f4f5f7;"><tr><td align="center" style="padding:32px 16px;">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;background-color:#ffffff;border-radius:12px;border:1px solid #e6e8eb;border-top:4px solid #f14714;">
<tr><td style="padding:28px 36px 20px 36px;border-bottom:1px solid #eef0f2;"><img src="${LOGO_URL}" alt="UnclogMe" width="144" height="48" style="display:block;border:0;outline:none;text-decoration:none;height:48px;width:144px;"></td></tr>
<tr><td style="padding:32px 36px 8px 36px;font-family:${FONT_STACK};">
<p style="margin:0 0 18px 0;font-size:16px;line-height:1.5;font-weight:700;color:#111827;">Dear Environmental Compliance Team,</p>
<p style="margin:0 0 16px 0;font-size:15px;line-height:1.65;color:#374151;">The service for our client <strong style="color:#111827;">${name}</strong> located at <strong style="color:#111827;">${addr}</strong> was performed on <strong style="color:#111827;">${vdate}</strong>.</p>
${CITY_ATTACH_COPY[mode].html}
<p style="margin:0 0 16px 0;font-size:15px;line-height:1.65;color:#374151;">If you have any questions or need assistance regarding this document, please feel free to reach us at <a href="mailto:contact@unclogme.com" style="color:#d63d12;text-decoration:underline;font-weight:600;">contact@unclogme.com</a> or call us directly.</p>
<p style="margin:0 0 22px 0;font-size:15px;line-height:1.65;color:#374151;">Thanks again for your hard work &mdash; and feel free to recommend us to the restaurants in your city ;-)</p>
<p style="margin:0 0 4px 0;font-size:15px;line-height:1.65;font-weight:700;color:#111827;">The Unclogme Team</p>
</td></tr>
<tr><td style="padding:18px 36px 26px 36px;background-color:#fafbfc;border-top:1px solid #eef0f2;font-family:${FONT_STACK};">
<p style="margin:0 0 4px 0;font-size:13px;font-weight:700;color:#374151;">Unclogme LLC</p>
<p style="margin:0 0 2px 0;font-size:12px;line-height:1.5;color:#9ca3af;">333 West 41st Street, Suite 606, Miami Beach, FL 33140</p>
<p style="margin:0;font-size:12px;line-height:1.5;color:#9ca3af;"><a href="mailto:contact@unclogme.com" style="color:#9ca3af;text-decoration:underline;">contact@unclogme.com</a></p>
</td></tr>
</table>
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;"><tr><td style="padding:16px 36px;text-align:center;font-family:${FONT_STACK};font-size:11px;color:#b6bcc4;line-height:1.5;">Sent by Unclogme LLC for FOG / grease-trap compliance submission.</td></tr></table>
</td></tr></table>
</body></html>`
}

function buildCityText(clientName: string, address: string, visitDate: string, mode: CityAttachMode = 'none'): string {
  return [
    'Dear Environmental Compliance Team,', '',
    `The service for our client ${clientName} located at ${address} was performed on ${visitDate}.`, '',
    ...CITY_ATTACH_COPY[mode].text,
    'If you have any questions or need assistance regarding this document, please feel free to reach us at contact@unclogme.com or call us directly.', '',
    'Thanks again for your hard work — and feel free to recommend us to the restaurants in your city ;-)', '',
    'The Unclogme Team', '',
    '--', 'Unclogme LLC', '333 West 41st Street, Suite 606, Miami Beach, FL 33140', 'contact@unclogme.com',
  ].join('\n')
}

// Service_role client used ONLY to sign storage objects for attachments. Kept at
// module scope so fetchAttachment can reach it without threading it through every
// call site.
const attachmentSigner = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } })

// Resolve a stored Supabase Storage URL to a service_role-SIGNED url.
//
// WHY: fetchAttachment used to do a bare unauthenticated `fetch(url)` against the
// stored `/object/public/...` values. That works only while the buckets are public.
// The DERM storage move puts the raw sheets in a PRIVATE bucket, at which point
// every city submission would fail `pdf_fetch_failed` — a COMPLIANCE path breaking,
// not a cosmetic one. Signing with service_role works on public AND private buckets,
// so this is safe to ship BEFORE the move and needs no follow-up during it.
//
// ⚠ The bucket segment is PERCENT-ENCODED in the stored data
// (`GT%20-%20Visits%20Images`, 1,362 urls). Passing that straight to .from() returns
// 400 in a way that reads like a bad path rather than an encoding bug, so both the
// bucket and each path segment must be decoded.
//
// Non-storage urls are returned unchanged, so any external link keeps working.
// On a signing failure it returns the original url rather than throwing: the caller
// is already fail-closed (`if (!att) fetchFailed = true`), so a genuine failure still
// aborts the send and logs `pdf_fetch_failed` instead of emailing the city a
// manifest with no attachment.
async function toSignedUrl(url: string): Promise<string> {
  const m = url.match(/\/storage\/v1\/object\/(?:public|sign)\/([^/]+)\/(.+)$/)
  if (!m) return url
  try {
    const bucket = decodeURIComponent(m[1])
    const path = m[2].split('?')[0].split('/').map(decodeURIComponent).join('/')
    const { data, error } = await attachmentSigner.storage.from(bucket).createSignedUrl(path, 600)
    if (error || !data?.signedUrl) return url
    // supabase-js returns an absolute url on some versions and a root-relative
    // path on others; normalise so fetch() always gets something absolute.
    return data.signedUrl.startsWith('http') ? data.signedUrl : `${SUPABASE_URL}/storage/v1${data.signedUrl}`
  } catch {
    return url
  }
}

// Fetch a URL into a Resend attachment {filename, content(base64), content_type}; null on fetch fail.
// Note the extension/content-type detection below deliberately keys off the ORIGINAL
// `url`, not the signed one, because a signed url carries a `?token=` query string.
async function fetchAttachment(url: string, baseName: string): Promise<{ filename: string; content: string; content_type: string } | null> {
  const resp = await fetch(await toSignedUrl(url))
  if (!resp.ok) return null
  const bytes = new Uint8Array(await resp.arrayBuffer())
  const b64 = encodeBase64Chunked(bytes)
  // The multiple-of-3 control. Base64 of n bytes is exactly 4*ceil(n/3); mid-stream '='
  // padding makes it LONGER. Returning null here is FAIL-CLOSED by construction: all three
  // call sites do `if (!att) { fetchFailed = true; break }` and then abandon the WHOLE
  // manifest with reason 'pdf_fetch_failed', so a corrupt attachment can never reach a
  // municipality. Verified against the call sites before this was written.
  // ⚠ The logged reason will read 'pdf_fetch_failed', which is not what happened, so the
  //   console line below is the only thing that tells the two apart in the edge log.
  if (b64.length !== 4 * Math.ceil(bytes.length / 3)) {
    console.error(`[send-derm-email] b64_length_mismatch ${b64.length}!=${4 * Math.ceil(bytes.length / 3)} for ${baseName}; refusing the attachment`)
    return null
  }
  const srcCt = (resp.headers.get('content-type') || '').split(';')[0].trim().toLowerCase()
  const extFromUrl = url.split('?')[0].match(/\.([a-z0-9]{2,5})$/i)?.[1]?.toLowerCase()
  const attExt = extFromUrl || CT_TO_EXT[srcCt] || 'pdf'
  const attType = srcCt || (attExt === 'pdf' ? 'application/pdf' : `image/${attExt === 'jpg' ? 'jpeg' : attExt}`)
  return { filename: `${baseName}.${attExt}`, content: b64, content_type: attType }
}

type RenderResult =
  | { ok: true; b64: string }
  | { ok: false; terminal: boolean; trip: boolean; reason: string }

/**
 * Render the Field Portal Service Report for one visit.
 *
 * 🛑 DO NOT ROUTE THIS THROUGH fetchAttachment(). That helper has no %PDF check, no
 * content-type validation and no size ceiling, and its extension logic would happily name
 * an HTML error page `.pdf` and mail it to a municipality.
 *
 * 🛑 client_code and public_id are derived SERVER-SIDE from our own rows keyed on
 * manifest_id. Never accept a visit id, public_id or report URL from the request body.
 *
 * Two failure classes, and the split is deliberate:
 *   TERMINAL (skip the manifest, send nothing) - the renderer is telling us our own
 *     resolution is wrong. The letter is built from that same resolution, so falling back
 *     would still name the wrong client, or assert a service our own system has retracted.
 *   FALLBACK (send today's two images) - availability or document-shape problems. Refusing
 *     would mean a municipal submission simply does not go out, which is worse.
 */
async function renderVisitReport(clientCode: string, publicId: string): Promise<RenderResult> {
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), PDF_TIMEOUT_MS)
  try {
    const up = await fetch(`${String(PDF_SERVICE_URL).replace(/\/$/, '')}/generate/visit-report`, {
      method: 'POST',
      signal: ctrl.signal,
      headers: { Authorization: `Bearer ${PDF_SERVICE_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ client_code: clientCode, public_id: publicId, include_photos: true }),
    })

    if (up.status === 409) {
      let code = 'report_not_available'
      try { code = (await up.clone().json())?.error ?? code } catch { /* keep default */ }
      return { ok: false, terminal: true, trip: false, reason: code }
    }
    if (up.status === 422) return { ok: false, terminal: true, trip: false, reason: 'invalid_input' }
    if (!up.ok) {
      // 🛑 READ THE BODY CODE ON 503. send-visit-photos-email branches on the status alone
      // and reports a permanent deploy fault (Chromium missing => renderer_unavailable) to
      // the operator as "the renderer is busy". Do not copy that.
      let reason = `pdf_service_${up.status}`
      if (up.status === 503) {
        try { reason = (await up.clone().json())?.error ?? reason } catch { /* keep default */ }
      }
      return { ok: false, terminal: false, trip: true, reason }
    }
    const ctype = up.headers.get('content-type') ?? ''
    if (!ctype.includes('pdf')) {
      return { ok: false, terminal: false, trip: true, reason: `pdf_service_bad_ctype:${ctype.slice(0, 40)}` }
    }
    const bytes = new Uint8Array(await up.arrayBuffer())
    // Per-document problems: do NOT trip the breaker, the next manifest may be fine.
    if (bytes.byteLength < 1000 || String.fromCharCode(...bytes.slice(0, 4)) !== '%PDF') {
      return { ok: false, terminal: false, trip: false, reason: `pdf_invalid:${bytes.byteLength}b` }
    }
    if (bytes.byteLength > MAX_REPORT_BYTES) {
      return { ok: false, terminal: false, trip: false, reason: `pdf_too_large:${bytes.byteLength}b` }
    }
    const b64 = encodeBase64Chunked(bytes)
    if (b64.length !== 4 * Math.ceil(bytes.byteLength / 3)) {
      return { ok: false, terminal: false, trip: false, reason: `b64_length_mismatch:${b64.length}` }
    }
    return { ok: true, b64 }
  } catch (e) {
    const msg = ctrl.signal.aborted ? `timeout after ${PDF_TIMEOUT_MS}ms` : String((e as Error)?.message ?? e)
    return { ok: false, terminal: false, trip: true, reason: `pdf_service:${msg}`.slice(0, 200) }
  } finally {
    clearTimeout(timer)
  }
}

/**
 * Build the FP Service Report attachment for one (manifest, client) pair.
 *
 * 🛑 ONE COPY, CALLED BY BOTH TARGETS. Fred, 2026-08-26: "we don't send the DERM Manifests,
 * or the receipts anymore, we send the Report PDF Files from the FP App." The city path and
 * the client path now attach the SAME document, so the resolution and validation live here
 * rather than being written twice. Two copies of a rule is how the base64 encoder nearly
 * drifted, and that one at least had a test asserting the copies matched.
 *
 * ⚠ PHOTO CLASSIFICATION IS NOT A CONDITION. Fred, 2026-08-25: "have it or not the photos
 * classified it will send it, if it have the photos classified it will attach it, and if not,
 * it doesn't matter." Verified on visit 6974 (20 images, 0 classified): the report renders
 * correctly with no photo sections at all.
 *
 * Returns `att: null` with a `reason` when no correct report can be produced. The caller
 * sends the letter anyway with nothing attached (Fred's explicit choice), EXCEPT when
 * `terminal` is set, which means the renderer says our own resolution is wrong and the letter
 * itself would be false.
 */
interface ReportAttachResult {
  att: { filename: string; content: string; content_type: string } | null
  reason: string
  visitDate: string | null
  address: string | null
  terminal: string | null
  trip: string | null
  incomplete: string
}

async function buildReportAttachment(
  sb: ReturnType<typeof createClient>,
  opts: { manifestId: number; clientId: number; clientCode: string | null; visitIds: number[]; number: string },
): Promise<ReportAttachResult> {
  const out: ReportAttachResult = { att: null, reason: '', visitDate: null, address: null, terminal: null, trip: null, incomplete: '' }
  const { manifestId, clientId, clientCode, visitIds } = opts
  try {
    if (!PDF_SERVICE_URL || !PDF_SERVICE_API_KEY) { out.reason = 'pdf_service_not_configured'; out.trip = out.reason; return out }
    if (!visitIds.length) { out.reason = 'no_resolved_visit'; return out }

    // ── Exactly ONE completed, DERM-required visit for THIS client on THIS manifest.
    // manifest_visits is uncapped and a report is per VISIT: picking one of several would
    // assert to Miami-Dade that this manifest documents that single service. No tie-break is
    // defensible (service_date is the dump-date misnomer, visit_date has ties).
    // ⚠ Deliberately NOT the caller's existing visitDate resolver: its second arm drops
    // visit_status='completed' and can resolve a scheduled or cancelled visit.
    const { data: cands, error: candErr } = await sb.from('visits')
      .select('id, public_id, visit_date, derm_required, property_id, properties(address)')
      .in('id', visitIds)
      .eq('client_id', clientId)
      .eq('visit_status', 'completed')
      .is('deleted_at', null)
    if (candErr) throw new Error(`visit resolve: ${candErr.message}`)
    // `!== false`, never `=== true`: derm_required NULL means REQUIRED and HAS a report.
    const V = (cands ?? []).filter((v) => (v as { derm_required: boolean | null }).derm_required !== false)
    if (V.length === 0) { out.reason = 'no_resolved_visit'; return out }
    if (V.length > 1) { out.reason = 'ambiguous_visit'; return out }

    const rv = V[0] as {
      id: number; public_id: string | null; visit_date: string | null
      property_id: number | null; properties?: { address: string | null } | null
    }
    // The renderer 422s on a malformed value; failing our own check first is a clean
    // no-attachment outcome instead of a logged 422.
    if (!clientCode || !/^[0-9]{3}-[A-Za-z0-9]+$/.test(clientCode)) { out.reason = 'bad_client_code'; return out }
    if (!rv.public_id || !/^[A-Za-z0-9_-]{6,32}$/.test(rv.public_id)) { out.reason = 'bad_public_id'; return out }

    // 🛑 .schema('customer') is load-bearing: sb is built with no schema, so omitting it
    // silently queries a nonexistent public.work_orders. Join on `id` (the view's first
    // column is v.public_id AS id), NOT visit_id.
    const { data: wo, error: woErr } = await sb.schema('customer').from('work_orders')
      .select('derm_manifest_url, wwtp_receipt_url, manifest_id')
      .eq('id', rv.public_id).maybeSingle()
    if (woErr) throw new Error(`work_orders: ${woErr.message}`)
    const w = wo as { derm_manifest_url: string | null; wwtp_receipt_url: string | null; manifest_id: number | null } | null
    if (!w) { out.reason = 'report_not_available'; return out }
    // The report prints ITS OWN manifest number, chosen by a LATERAL ORDER BY service_date
    // DESC with no tiebreaker. Attaching one that names a different manifest than the letter
    // would misstate the document itself.
    if (w.manifest_id !== manifestId) { out.reason = 'report_other_manifest'; return out }

    // ⚠ NOT A CONDITION, BY DESIGN, BUT IT MUST BE VISIBLE. There is no fallback attachment
    // any more, so a report missing one of the two compliance documents still goes out.
    // Measured 2026-08-26: 123 of 123 city-sendable pairs carry both, because the
    // `no_redacted_sheet` guard on the city path already blocks the slow half. If that ever
    // stops being true, this line is what says so.
    out.incomplete = [w.derm_manifest_url ? null : 'fog', w.wwtp_receipt_url ? null : 'wwtp'].filter(Boolean).join('+')
    if (out.incomplete) {
      console.error(`[send-derm-email] report_incomplete manifest=${manifestId} client=${clientId} missing=${out.incomplete}`)
    }

    const rendered = await renderVisitReport(clientCode, rv.public_id)
    if (rendered.ok) {
      out.att = {
        filename: `DERM-Service-Report-${opts.number}.pdf`,
        content: rendered.b64,
        content_type: 'application/pdf',
      }
      out.reason = out.incomplete ? `incomplete:${out.incomplete}` : ''
      // The letter must describe the visit the attached report covers, not an arbitrary
      // ORDER BY visit_date DESC pick and not the first inbox-carrying property. Returning
      // both makes the letter and the document agree by construction.
      out.visitDate = rv.visit_date
      out.address = rv.properties?.address ?? null
      return out
    }
    // client_mismatch / 422: the renderer is telling us our own resolution is wrong, and the
    // LETTER is built from that same resolution, so sending it would name the wrong client.
    // report_not_available is NOT terminal: it is exactly "no report", which Fred chose to
    // send the letter for.
    if (rendered.terminal && rendered.reason !== 'report_not_available') { out.terminal = rendered.reason; return out }
    out.reason = rendered.reason
    if (rendered.trip) out.trip = rendered.reason
    return out
  } catch (ge) {
    out.reason = 'gate_read_failed'
    console.error(`[send-derm-email] gate_read_failed manifest=${manifestId} client=${clientId}: ${String((ge as Error)?.message ?? ge).slice(0, 200)}`)
    return out
  }
}

Deno.serve(async (req: Request) => {
  const cors = corsHeadersFor(req.headers.get('origin'))
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors })
  if (req.method !== 'POST') return jsonResponse({ error: 'method_not_allowed' }, 405, cors)
  if (!RESEND_API_KEY) return jsonResponse({ error: 'email_not_configured', detail: 'RESEND_API_KEY not set' }, 503, cors)
  if (!SUPABASE_URL || !SERVICE_KEY) return jsonResponse({ error: 'service_not_configured' }, 503, cors)

  // -- AUTH GATE. A real caller, not merely a valid-looking JWT. ----------------------------
  // 🛑 THE ANON KEY IS PUBLIC BY DESIGN. It ships inside every app's JavaScript, so "presented a
  // valid JWT" is not authentication. Until 2026-08-28 this function had no gate at all and no
  // config.toml block, so ONE request carrying the public anon key plus a test_recipient could
  // have any manifest's compliance documents mailed to any address: the key got past the door,
  // nothing asked who was calling, and test_recipient replaces the real city recipients.
  //
  // Exactly two callers are legitimate:
  //   service_role - the hourly city-email sweep. No human, so the actor below stays null.
  //   a real user  - the DERM Tracker button, forwarding the signed-in staff JWT.
  // The anon key is NEITHER: it is a validly signed JWT with NO user attached, which is precisely
  // the branch getUser() rejects. That is why the check is getUser and not a claims read.
  //
  // ⚠ This sits AFTER the OPTIONS reply on purpose. A browser preflight carries no Authorization
  // header, so gating before it would break every in-app call with an opaque CORS failure.
  const bearer = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
  if (!bearer) return jsonResponse({ error: 'unauthorized', detail: 'no bearer token' }, 401, cors)
  let bearerRole: string | null = null
  try {
    const part = bearer.split('.')[1]
    if (part) {
      let b64 = part.replace(/-/g, '+').replace(/_/g, '/')
      while (b64.length % 4) b64 += '='
      bearerRole = (JSON.parse(atob(b64)) as { role?: string }).role ?? null
    }
  } catch { bearerRole = null }
  // Exact-match first so the sweep does not depend on claim parsing; the claim check is the
  // fallback for a rotated key. The gateway validates the signature before we ever run, so a
  // forged role claim cannot reach this line.
  const isMachineCaller = bearer === SERVICE_KEY || bearerRole === 'service_role'
  if (!isMachineCaller) {
    const authClient = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } })
    const { data: gu, error: guErr } = await authClient.auth.getUser(bearer)
    if (guErr || !gu?.user?.id) {
      return jsonResponse({ error: 'unauthorized', detail: 'a signed-in staff user is required' }, 401, cors)
    }
  }

  let body: { manifest_ids?: unknown; recipients?: unknown; test_recipient?: unknown; test_cc?: unknown; target?: unknown; cc?: unknown; bcc?: unknown }
  try { body = await req.json() } catch { return jsonResponse({ error: 'bad_json' }, 400, cors) }

  // `property_id` is OPTIONAL and NARROWS the city recipient to that one property.
  // 🛑 Why it exists: without it this function unions city_emails across EVERY property the
  // client owns. Measured 2026-08-28 over the 107 manifests the automatic sweep can send:
  // 38 of them would reach a STRICT SUPERSET of the right inbox, i.e. a municipality where
  // the service did not happen. It never misses one, so this is over-sending, not under-.
  // Fred, 2026-08-27: *"It's sent via the City Email property we have saved in our db for
  // that client property"* - singular. The automatic sweep therefore passes the property it
  // resolved through the visit, and derm.v_city_email_queue.property_id is that value.
  // Omitting it preserves the existing manual behaviour EXACTLY; this is additive.
  type Rec = { manifest_id: number; client_id: number | null; property_id: number | null }
  let recipients: Rec[] = []
  if (Array.isArray(body?.recipients)) {
    recipients = (body.recipients as unknown[])
      .map((r) => {
        const o = (r ?? {}) as { manifest_id?: unknown; client_id?: unknown; property_id?: unknown }
        return {
          manifest_id: Number(o.manifest_id),
          client_id: o.client_id == null ? null : Number(o.client_id),
          property_id: o.property_id == null || !Number.isFinite(Number(o.property_id)) ? null : Number(o.property_id),
        }
      })
      .filter((r) => Number.isFinite(r.manifest_id))
  } else if (Array.isArray(body?.manifest_ids)) {
    recipients = (body.manifest_ids as unknown[]).map(Number).filter((n) => Number.isFinite(n)).map((id) => ({ manifest_id: id, client_id: null, property_id: null }))
  }
  const seenRec = new Set<string>()
  recipients = recipients.filter((r) => {
    const k = `${r.manifest_id}:${r.client_id ?? 'own'}:${r.property_id ?? 'all'}`
    if (seenRec.has(k)) return false
    seenRec.add(k)
    return true
  })
  const rawTestRecipient = typeof body?.test_recipient === 'string' ? body.test_recipient.trim() : ''
  // 🛑 REFUSE an unrecognised address, NEVER silently ignore it. Ignoring it would fall through to
  // the REAL municipal recipients, i.e. the exact opposite of what the caller asked for, and a
  // typo in a test would become a live regulator send.
  if (rawTestRecipient !== '' && !TEST_RECIPIENT_RE.test(rawTestRecipient)) {
    return jsonResponse({
      error: 'bad_test_recipient',
      detail: `Test emails may only go to ${ALLOWED_TEST_DOMAINS.map((d) => '@' + d).join(' or ')}.`,
    }, 400, cors)
  }
  // `let`, not `const`: the city testing-phase gate below can FORCE this (see CITY GATE).
  let testRecipient = rawTestRecipient !== '' ? rawTestRecipient : null
  // test_cc = the "send to BOTH" copy (Fred 2026-07-09): a REAL send to the clients/city
  // PLUS a BCC copy to this address so the sender can verify what went out. Distinct from
  // test_recipient (which SUPPRESSES the real send). Ignored when test_recipient is set
  // (that path already sends only to the test address, so there is no real send to copy).
  // 🛑 test_cc WAS VALIDATED ONLY BY `.includes('@')` - the identical hole closed on test_recipient
  // earlier today, left open on the CC path. The city gate happens to neutralise it for
  // target='city' (the gate forces testRecipient, and this is gated on !testRecipient), but the
  // target='client' path has NO gate, so a caller could BCC a real client-facing DERM email to any
  // address. Now held to the same allowlist, and REFUSED rather than ignored.
  const rawTestCc = !testRecipient && typeof body?.test_cc === 'string' ? body.test_cc.trim() : ''
  if (rawTestCc !== '' && !TEST_RECIPIENT_RE.test(rawTestCc)) {
    return jsonResponse({
      error: 'bad_test_cc',
      detail: `test_cc may only be ${ALLOWED_TEST_DOMAINS.map((d) => '@' + d).join(' or ')}.`,
    }, 400, cors)
  }
  const testCc = rawTestCc !== '' ? rawTestCc : null

  const ccParsed = parseCopyList(body?.cc, 'Cc', [])
  if ('error' in ccParsed) return jsonResponse({ error: 'recipient_not_allowed', detail: ccParsed.error }, 422, cors)
  const bccParsed = parseCopyList(body?.bcc, 'Bcc', ccParsed.list)
  if ('error' in bccParsed) return jsonResponse({ error: 'recipient_not_allowed', detail: bccParsed.error }, 422, cors)
  const ccList = ccParsed.list
  const bccList = bccParsed.list
  const target = body?.target === 'city' ? 'city' : 'client'
  if (recipients.length === 0) return jsonResponse({ error: 'no_recipients' }, 400, cors)

  const sb = createClient(SUPABASE_URL, SERVICE_KEY, { global: { headers: { 'x-app-source': 'send-derm-email' } } })
  const results: Record<string, unknown>[] = []

  // ══ CITY GATE — THE TESTING-PHASE CONTROL ════════════════════════════════════════════════
  // Fred, 2026-08-10 and re-stated 2026-08-28: *"do not send anything to the city, only @ayache
  // or @unclogme domains for the emails to test."*
  //
  // 🛑 THAT INSTRUCTION WAS ONLY ENFORCED ON THE OTHER MAILER. `send-visit-photos-email` has a
  // hardcoded IS_TEST=true, but THIS function is the one that actually reaches municipal inboxes
  // (its 17 real sends prove it), and it had no equivalent. A human clicking the DERM Tracker's
  // "send to city" button reached real regulators with no gate in front of them. The queue's
  // start_from switch does not help: it only holds the CRON back, never a person.
  //
  // While city_email_live_sends is not 'true', every target='city' send is FORCED to the internal
  // address and the real recipients are never used. This overrides the caller, so it does not
  // matter who calls or from where.
  //
  // 🛑 IT FAILS CLOSED. Any error reading the config forces the internal address rather than
  // falling through to the municipal list, because "we could not check" and "it is safe to send
  // to a regulator" must never be the same branch.
  // 🛑 THE GATE NOW COVERS BOTH TARGETS. It used to cover target='city' only, and that left the
  // BIGGER live surface wide open: the DERM Tracker's "Send to N clients" button reaches real
  // customers, and has - 37 real sends to 23 distinct client addresses, most recently 2026-08-19.
  // With an empty "Send a test to" field one click mails all of them. Fred, 2026-08-28:
  // *"REMEMBER TO NOT SEND TO THE CLIENTS YET ... we're testing so you can't send emails to the
  // clients yet."*
  //
  // Each target has its OWN flag, so client sending can be restored without also opening the city,
  // and vice versa. Both ship false during the testing phase.
  // ⚠ client_email_live_sends=false DISABLES A WORKING PRODUCTION FEATURE. That is deliberate and
  // temporary; one config update restores it.
  let cityGate: string | null = null
  {
    const liveKey = target === 'city' ? 'city_email_live_sends' : 'client_email_live_sends'
    let live = false
    let fallback = ''
    try {
      const { data: cfg, error: cfgErr } = await sb.from('app_config')
        .select('key, value').in('key', [liveKey, 'city_email_test_recipient'])
      if (cfgErr) throw cfgErr
      const m = new Map(((cfg ?? []) as { key: string; value: string | null }[])
        .map((r) => [r.key, String(r.value ?? '').trim()]))
      live = (m.get(liveKey) ?? '').toLowerCase() === 'true'
      // One internal inbox serves both targets. The key name is historical.
      fallback = m.get('city_email_test_recipient') ?? ''
    } catch (e) {
      console.error(`[send-derm-email] SEND GATE config read failed, failing closed: ${String((e as Error)?.message ?? e)}`)
      live = false
    }
    if (!live) {
      // 🛑 REFUSE rather than send. If the gate is on but its address is unusable, the only
      // alternative would be mailing the real city, which is the thing being prevented.
      if (!TEST_RECIPIENT_RE.test(fallback)) {
        return jsonResponse({
          error: 'city_gate_misconfigured',
          detail: `${target === 'city' ? 'City' : 'Client'} sending is disabled and app_config.city_email_test_recipient is not a valid `
            + ALLOWED_TEST_DOMAINS.map((d) => '@' + d).join(' / ') + ' address. Refusing to send.',
        }, 503, cors)
      }
      cityGate = fallback
      if (testRecipient && testRecipient !== fallback) {
        console.warn(`[send-derm-email] CITY GATE overrode test_recipient ${testRecipient} -> ${fallback}`)
      }
      testRecipient = fallback
    }
  }

  const isTest = !!testRecipient

  // Activity-trail attribution (2026-07-21h): this fn runs as service_role, so
  // the audit trigger cannot see the user. The DERM Tracker forwards the
  // signed-in user's JWT on functions.invoke; decode it (read-only, the app is
  // auth-gated) to record WHO triggered the send. Anon/service callers -> null.
  let actorEmail: string | null = null
  let actorUserId: string | null = null
  try {
    const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
    const part = jwt.split('.')[1]
    if (part) {
      let b64 = part.replace(/-/g, '+').replace(/_/g, '/')
      while (b64.length % 4) b64 += '='
      const claims = JSON.parse(atob(b64)) as { role?: string; email?: string; sub?: string }
      if (claims.role && claims.role !== 'anon' && claims.role !== 'service_role') {
        actorEmail = claims.email ?? null
        actorUserId = claims.sub ?? null
      }
    }
  } catch { /* leave actor null on any decode issue */ }

  // Append-only send log; never throws (a logging failure must not break the email response).
  const logSend = async (
    manifestId: number, clientId: number | null, recipientEmail: string | null,
    resendEmailId: string | null, status: string, reason: string | null, recipientType = 'client',
  ): Promise<void> => {
    if (clientId == null) { console.warn(`[send-derm-email] log skipped (no client_id) manifest=${manifestId} status=${status}`); return }
    try {
      const { error } = await sb.from('derm_email_sends').insert({
        manifest_id: manifestId, client_id: clientId, recipient_email: recipientEmail,
        resend_email_id: resendEmailId, status, reason, is_test: isTest, recipient_type: recipientType,
        // 🛑 The ONLY record a Bcc ever leaves. Nobody on the thread can see it.
        cc_emails: ccList, bcc_emails: bccList,
        sent_by_email: actorEmail, sent_by_user_id: actorUserId,
      })
      if (error) console.error(`[send-derm-email] log insert failed: ${error.message}`)
    } catch (e) {
      console.error(`[send-derm-email] log insert threw: ${String((e as Error)?.message ?? e)}`)
    }
  }

  // 🛑 INVOCATION-SCOPED, AND IT MUST COVER BOTH TARGETS. Declared above the target split
  // because the city and client paths are two separate loops: scoping it inside one of them
  // left the other referencing an undefined binding, which failed every client send with
  // "renderDisabled is not defined". Caught by the first client test, not by the deploy.
  // Once the renderer has refused or broken once, every remaining manifest in this batch
  // sends with no attachment instead of attempting another render. The renderer runs
  // VISIT_REPORT_MAX_CONCURRENCY = 2 and SHEDS rather than queues, so a refusal thirty
  // seconds ago is strong evidence about the next one.
  let renderDisabled: string | null = null
  const invocationStart = Date.now()

  if (target === 'city') {
    // ===== CITY: both PDFs to the municipal FOG office, formal letter, BCC compliance =====
    // 🛑 THE CITY INBOX MOVED FROM THE CITY TO THE PROPERTY (2026-08-21,
    //    docs/migrations/2026-08-21_2130_property_city_emails_per_property.sql).
    //    There is no municipality_regulators lookup here any more: that table still holds its rows
    //    for history, but it is EMPTY of live addresses and no longer feeds anything. Reading it
    //    now would resolve zero recipients and every send would log 'no_city_email' - a silent,
    //    total failure that looks exactly like "no city has been configured yet".
    //    Recipients come from public.properties.city_emails, per property.

    // 🛑 CIRCUIT BREAKER, INVOCATION-SCOPED. Once the renderer has refused or broken once,
    // every remaining manifest in this batch falls back without attempting a render. The
    // renderer runs VISIT_REPORT_MAX_CONCURRENCY = 2 and SHEDS rather than queues, so a
    // refusal thirty seconds ago is strong evidence about the next one. This bounds the worst
    // case at ONE render failure per invocation regardless of how many recipients were passed.
    for (const rec of recipients) {
      const id = rec.manifest_id
      let logClientId: number | null = rec.client_id ?? null
      let logEmail: string | null = null
      try {
        const { data: m, error: me } = await sb.from('derm_manifests')
          .select('id, client_id, white_manifest_number, yellow_ticket_number, derm_manifest_url, derm_manifest_extra_urls, derm_address_url, derm_address_extra_urls, deleted_at')
          .eq('id', id).maybeSingle()
        if (me) throw me
        if (!m || m.deleted_at) { results.push({ manifest_id: id, status: 'skipped', reason: 'not_found_or_deleted' }); await logSend(id, logClientId, null, null, 'skipped', 'not_found_or_deleted', 'city'); continue }
        logClientId = rec.client_id ?? (m.client_id as number)
        const clientId = rec.client_id ?? (m.client_id as number)
        const number = m.white_manifest_number || m.yellow_ticket_number || String(id)
        // 🛑 client_code is read HERE, from clientId, and NEVER off the resolved visit's own
        // client join. The renderer's client_mismatch guard compares the code we send against
        // the code printed on the rendered page: sourced from the RECIPIENT side it catches a
        // wrong-visit resolution, sourced from the visit it would merely confirm itself.
        const { data: c } = await sb.from('clients').select('name, client_code').eq('id', clientId).maybeSingle()
        const clientName = c?.name || 'Customer'
        const clientCode = (c as { client_code?: string | null } | null)?.client_code ?? null

        // Guard: BOTH PDFs required (Manifest Form + Transporter Manifest)
        if (!m.derm_manifest_url || !m.derm_address_url) { results.push({ manifest_id: id, status: 'skipped', reason: 'missing_attachments', client: clientName }); await logSend(id, logClientId, null, null, 'skipped', 'missing_attachments', 'city'); continue }

        // Resolve the client's city inboxes off ITS OWN PROPERTIES + a served address.
        // ⚠ DEDUPE BY EMAIL, NOT BY MUNICIPALITY. The old code kept the FIRST regulator row per
        //   municipality and skipped the rest, which was right when the address belonged to the
        //   city (every property in Miami resolved the same row). Now two properties in the SAME
        //   city can legitimately carry DIFFERENT addresses, so keying the set on municipality
        //   would silently drop the second one and mail only the first property's contact.
        // ⚠ deleted_at IS NULL is new here and deliberate: a soft-deleted property must not drag
        //   its stale inbox into a live send. client.properties already filters the same way.
        // 🛑 `client_id` STAYS on this query even when a property_id is supplied. The narrowing
        // is an INTERSECTION, never a redirect: a property_id belonging to another client
        // matches zero rows and the send is skipped 'no_city_email' rather than mailing a
        // stranger's municipal inbox. The caller must not be able to choose the recipient.
        let propQ = sb.from('properties')
          .select('id, address, city, city_emails').eq('client_id', clientId).is('deleted_at', null)
        if (rec.property_id != null) propQ = propQ.eq('id', rec.property_id)
        const { data: props } = await propQ
        const cityEmailSet = new Set<string>()
        const muniSet = new Set<string>()
        // Which properties actually carry a city inbox. G10 below requires the resolved
        // visit's property to be one of them, because the letter prints servedAddress (the
        // FIRST inbox-carrying property) while the report renders the VISIT's property. On a
        // regulator-facing document those two addresses must not disagree.
        const inboxPropIds = new Set<number>()
        const propAddrById = new Map<number, string>()
        let servedAddress = ''
        for (const p of (props || []) as { id: number; address: string | null; city: string | null; city_emails: string[] | null }[]) {
          const emails = (p.city_emails || [])
            .map((e) => String(e ?? '').trim().toLowerCase())
            .filter((e) => e.includes('@'))
          if (!emails.length) continue
          inboxPropIds.add(p.id)
          propAddrById.set(p.id, String(p.address ?? ''))
          for (const e of emails) cityEmailSet.add(e)
          const muni = String(p.city ?? '').trim()
          if (muni) muniSet.add(muni)
          if (!servedAddress && p.address) servedAddress = p.address
        }
        const cityEmails = [...cityEmailSet]
        const municipality = [...muniSet].join(', ')
        const toList = testRecipient ? [testRecipient] : cityEmails
        if (toList.length === 0) { results.push({ manifest_id: id, status: 'skipped', reason: 'no_city_email', client: clientName }); await logSend(id, logClientId, null, null, 'skipped', 'no_city_email', 'city'); continue }
        logEmail = testRecipient ? testRecipient : cityEmails.join(', ')

        // Most recent completed linked visit's date (fallback: any non-deleted)
        const { data: mvs } = await sb.from('manifest_visits').select('visit_id').eq('manifest_id', id)
        const visitIds = ((mvs || []) as { visit_id: number }[]).map((x) => x.visit_id)
        let visitDate = ''
        if (visitIds.length) {
          const { data: vc } = await sb.from('visits').select('visit_date').in('id', visitIds).eq('client_id', clientId).eq('visit_status', 'completed').is('deleted_at', null).order('visit_date', { ascending: false }).limit(1).maybeSingle()
          if (vc?.visit_date) visitDate = vc.visit_date as string
          else {
            const { data: va } = await sb.from('visits').select('visit_date').in('id', visitIds).eq('client_id', clientId).is('deleted_at', null).order('visit_date', { ascending: false }).limit(1).maybeSingle()
            visitDate = (va?.visit_date as string) || ''
          }
        }
        if (!servedAddress && props?.length) servedAddress = (props[0] as { address: string | null }).address || ''

        // Attachments: the Manifest Form is a MULTI-SHEET doc — the shared DERM Address
        // sheet spills to extra images (derm_address_extra_urls) when one dump run covers
        // more clients than fit on one sheet. Attaching only the primary made the City see
        // just the sheet-1 clients and warn about the rest (Fred, 2026-07-09, #829216 = 12
        // clients / 4 sheets). Attach the primary + EVERY extra so the City gets the full
        // manifest. Same for the Transporter Manifest. Require all to fetch (a missing sheet
        // = the bug we're fixing — fail loudly rather than send an incomplete manifest).
        // 🛑 2026-08-10 (Fred, relaying Yannick): the City gets the BLACKED-OUT sheet, not the full one.
        //
        // WHY. The DERM Address sheet is SHARED across every client on one dump run, so attaching it
        // whole hands a municipal regulator the compliance rows of businesses they have no
        // jurisdiction over. Measured before this change: of the 114 city sends possible today,
        // **114 disclosed other clients** and **0 disclosed none**, averaging 7.15 other clients and
        // peaking at 18. There was no benign case.
        //
        // We already produce exactly the right artifact. The Field Portal blackout
        // (`derm.redacted_manifest_docs`) renders one image per (manifest, client) with ONLY that
        // client's band visible and every other facility row blacked, while keeping the transporter
        // block, both certifications, the disposal facility, ticket number and gallons intact.
        // 114 of 114 city-eligible pairs already have one, so nothing needs generating.
        //
        // ⚠ THIS SUPERSEDES THE PARAGRAPH ABOVE, AND THAT PARAGRAPH'S REASON STILL MATTERS.
        // On 2026-07-09 the City was sent only sheet 1 of a 4-sheet run (#829216, 12 clients) and
        // warned about the clients it could not see, which is why every extra sheet was attached.
        // Redaction answers that differently: we no longer claim the other clients at all, so there
        // is nothing dangling for the regulator to chase. **If a city ever objects that the document
        // looks incomplete, that is the trade being made here, and it is Fred's call to revisit.**
        //
        // 🛑 NEVER FALL BACK TO THE FULL SHEET. A missing redaction SKIPS the send. Falling back
        // would silently restore the exact disclosure this exists to prevent, on the one path where
        // nobody would be looking.
        const rdRes = await fetch(
          `${SUPABASE_URL}/rest/v1/redacted_manifest_docs?manifest_id=eq.${id}&client_id=eq.${clientId}&select=url`,
          { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Accept-Profile': 'derm' } },
        )
        // Both branches SKIP, but they are different problems and must not share a label. A failed
        // lookup ("Accept-Profile dropped", schema cache cold, 500) would otherwise be indexed under
        // "no redacted sheet" and send someone to regenerate artifacts that already exist.
        // Verified 2026-08-10 with three controls: a known pair returns the row; an impossible pair
        // returns 200 `[]`; the same call without `Accept-Profile: derm` returns 404 (PGRST205).
        // So `[]` genuinely means absent, and a non-ok response genuinely means the lookup broke.
        if (!rdRes.ok) {
          const rdErr = await rdRes.text().catch(() => '')
          console.error(`[send-derm-email] redaction lookup failed manifest=${id} client=${clientId} status=${rdRes.status} ${rdErr.slice(0, 200)}`)
          results.push({ manifest_id: id, status: 'skipped', reason: 'redaction_lookup_failed', client: clientName })
          await logSend(id, logClientId, null, null, 'skipped', 'redaction_lookup_failed', 'city')
          continue
        }
        const rdRows = await rdRes.json()
        const redactedUrl: string | null = Array.isArray(rdRows) && rdRows[0]?.url ? String(rdRows[0].url) : null
        if (!redactedUrl) {
          results.push({ manifest_id: id, status: 'skipped', reason: 'no_redacted_sheet', client: clientName })
          await logSend(id, logClientId, null, null, 'skipped', 'no_redacted_sheet', 'city')
          continue
        }
        // ══ THE CITY GETS THE FP SERVICE REPORT, AND NOTHING ELSE ══════════════════════
        // Fred, 2026-08-26: "we don't send the DERM Manifests, or the receipts anymore, we
        // send the Report PDF Files from the FP App." The report already embeds the redacted
        // FOG eManifest and the WWTP receipt, so it REPLACES both attachments.
        // 🛑 When no correct report can be produced the letter still goes out with NOTHING
        // attached (Fred's explicit choice, 2026-08-26) rather than being skipped.
        let reportAtt: { filename: string; content: string; content_type: string } | null = null
        let attachMode: CityAttachMode = 'none'
        let attachReason = ''
        let letterDate = visitDate
        let letterAddress = servedAddress
        if (renderDisabled) {
          attachReason = renderDisabled
        } else if (Date.now() - invocationStart > RENDER_DEADLINE_MS) {
          renderDisabled = 'render_deadline'
          attachReason = renderDisabled
        } else {
          const r = await buildReportAttachment(sb, { manifestId: id, clientId, clientCode, visitIds, number })
          if (r.terminal) {
            console.error(`[send-derm-email] render_terminal manifest=${id} client=${clientId} reason=${r.terminal}`)
            results.push({ manifest_id: id, status: 'skipped', reason: r.terminal, client: clientName })
            await logSend(id, logClientId, null, null, 'skipped', r.terminal, 'city')
            continue
          }
          if (r.trip) renderDisabled = r.trip
          attachReason = r.reason
          if (r.att) {
            reportAtt = r.att
            attachMode = 'report'
            letterDate = r.visitDate ?? visitDate
            letterAddress = r.address || servedAddress
          } else {
            console.error(`[send-derm-email] no_attachment manifest=${id} client=${clientId} reason=${r.reason}`)
          }
        }

        // 🛑 THE CITY NO LONGER RECEIVES THE MANIFEST IMAGES (Fred, 2026-08-26): "we don't send
        // the DERM Manifests, or the receipts anymore, we send the Report PDF Files from the FP
        // App." The redacted FOG sheet and the transporter manifest are both EMBEDDED in that
        // report, so attaching them as well would send the same two documents twice.
        //
        // ⚠ The `no_redacted_sheet` guard ABOVE is deliberately kept even though the redacted
        // sheet is no longer an attachment. It is what makes the report CONTAIN the FOG
        // manifest (customer.work_orders.derm_manifest_url IS derm.redacted_manifest_docs.url),
        // so removing it would start mailing regulators reports with that document missing.
        //
        // ⚠ NO ATTACHMENT IS A VALID OUTCOME, BY FRED'S EXPLICIT CHOICE. When no report can be
        // produced the letter still goes out with nothing attached, rather than being skipped.
        const attachments: { filename: string; content: string; content_type: string }[] = []
        if (reportAtt) attachments.push(reportAtt)

        const payload: Record<string, unknown> = {
          from: RESEND_FROM,
          to: toList,
          subject: `DERM Manifest for ${clientName}`,
          html: buildCityHtml(clientName, letterAddress, fmtDate(letterDate), attachMode),
          text: buildCityText(clientName, letterAddress, fmtDate(letterDate), attachMode),
          attachments,
        }
        // BCC = compliance copy on real sends (CITY_BCC) + the test_cc "send-to-both" copy
        // + whatever the sender blind-copied. Deduped: CITY_BCC must not appear twice if a sender
        // types it by hand.
        const cityBcc = [...new Set([
          ...(!testRecipient ? [CITY_BCC] : []),
          ...(testCc ? [testCc] : []),
          ...bccList,
        ].map((e) => e.trim()).filter(Boolean))]
        if (cityBcc.length) payload.bcc = cityBcc
        if (ccList.length) payload.cc = ccList

        const emailRes = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        })
        const er = await emailRes.json().catch(() => ({}))
        if (!emailRes.ok) { results.push({ manifest_id: id, status: 'error', reason: 'resend_failed', detail: er, client: clientName }); await logSend(id, logClientId, logEmail, null, 'error', 'resend_failed', 'city'); continue }

        const sentEmailId = (er as { id?: string })?.id ?? null
        results.push({ manifest_id: id, client_id: clientId, status: 'sent', to: testRecipient ? `${toList.join(', ')} (TEST)` : toList.join(', '), municipality, number, email_id: sentEmailId, attachment: attachMode, attachment_reason: attachReason || null })
        // 🛑 THE BRANCH IS WRITTEN ON EVERY SUCCESS ROW, AND THAT IS MANDATORY, NOT POLISH.
        // The fallback is fail-OPEN: 85-90% of pairs already take it, so the report path could
        // stop firing entirely and look identical to normal operation. That is the
        // redact-manifest-sweep shape, which reported `succeeded` every five minutes for 34
        // blocked clients because an empty work queue is a successful run.
        // ⚠ `reason` has meant "why this did NOT happen" until now. The `attachment:` prefix
        // disambiguates, and `status='sent' AND reason IS NOT NULL` is unambiguous, but a
        // reader needs telling. Query with `reason LIKE 'attachment:%'`.
        await logSend(id, logClientId, logEmail, sentEmailId, 'sent',
          attachMode === 'report' ? 'attachment:report' : `attachment:manifest_images:${attachReason || 'unknown'}`, 'city')
      } catch (e) {
        const msg = String((e as Error)?.message ?? e)
        results.push({ manifest_id: id, status: 'error', reason: msg })
        await logSend(id, logClientId, logEmail, null, 'error', msg, 'city')
      }
    }
  } else {
    // ===== CLIENT: single WWTP receipt to the client's email (existing behavior) =====
    for (const rec of recipients) {
      const id = rec.manifest_id
      let logClientId: number | null = rec.client_id ?? null
      let logEmail: string | null = null
      try {
        const { data: m, error: me } = await sb
          .from('derm_manifests')
          .select('id, client_id, white_manifest_number, yellow_ticket_number, derm_manifest_url, derm_manifest_extra_urls, deleted_at')
          .eq('id', id)
          .maybeSingle()
        if (me) throw me
        if (!m || m.deleted_at) { results.push({ manifest_id: id, status: 'skipped', reason: 'not_found_or_deleted' }); await logSend(id, logClientId, logEmail, null, 'skipped', 'not_found_or_deleted'); continue }
        logClientId = rec.client_id ?? (m.client_id as number)
        if (!m.derm_manifest_url) { results.push({ manifest_id: id, status: 'skipped', reason: 'no_pdf' }); await logSend(id, logClientId, logEmail, null, 'skipped', 'no_pdf'); continue }

        const number = m.white_manifest_number || m.yellow_ticket_number || String(id)

        const clientId = rec.client_id ?? (m.client_id as number)
        const { data: c } = await sb.from('clients').select('name, client_code').eq('id', clientId).maybeSingle()
        const clientName = c?.name || 'Customer'
        const clientCode = c?.client_code || null

        let toEmail: string | null = testRecipient
        if (!toEmail) {
          // ⚠ THE ORDER BY IS LOAD-BEARING — do not drop it as noise.
          // This used to be a bare .limit(1) with NO ordering, so with more than one
          // emailed contact the recipient of a client's DERM manifest was whichever
          // row Postgres happened to return. That was survivable only because
          // client_contacts was capped at one row per role per client (max 3).
          // Migration 2026-07-30_0539 added per-property contacts for the Client App's
          // "Add Contact", which makes multi-contact clients the normal case — so
          // unordered selection would mean adding a contact could silently redirect a
          // client-facing compliance email to a different person.
          // Deterministic preference: client-level (property_id IS NULL) first, then
          // the `primary` role, then oldest row. That is the narrowest reading of the
          // previous intent ("the client's main email").
          const { data: cc } = await sb
            .from('client_contacts')
            .select('email, property_id, contact_role, id')
            .eq('client_id', clientId)
            .not('email', 'is', null)
            .neq('email', '')
            .order('property_id', { ascending: true, nullsFirst: true })
            // DESCENDING is deliberate, and it is the one line here that is easy to
            // "tidy" into a bug. The role vocabulary is exactly three values, fixed by
            // the CHECK in client.create_client_contact: accounting | city | primary.
            // Descending alphabetical yields primary > city > accounting, so `primary`
            // sorts FIRST. Ascending would put `accounting` first and send the client's
            // DERM manifest to their bookkeeper. PostgREST cannot ORDER BY a CASE
            // expression, so this ordering carries the preference. ⚠ If a fourth role is
            // ever added, re-derive this rather than assuming it still holds.
            .order('contact_role', { ascending: false })
            .order('id', { ascending: true })
            .limit(1)
            .maybeSingle()
          toEmail = cc?.email ?? null
        }
        if (!toEmail) { results.push({ manifest_id: id, status: 'skipped', reason: 'no_email', client: clientCode }); await logSend(id, logClientId, null, null, 'skipped', 'no_email'); continue }
        logEmail = toEmail

        // 🛑 THE CLIENT NO LONGER RECEIVES THE RAW WWTP RECEIPT (Fred, 2026-08-26): "we don't
        // send the DERM Manifests, or the receipts anymore, we send the Report PDF Files from
        // the FP App." The Service Report embeds that receipt along with the FOG eManifest and
        // the before/after photos, so it replaces the bare image the client used to get.
        // ⚠ The old co-client rule is now enforced upstream rather than here: the report is
        // per VISIT and renders only this client's own documents, so the shared DERM Address
        // sheet can never reach a client through it.
        // 🛑 No report => the letter still goes out with NOTHING attached (Fred's choice).
        const { data: mvsC } = await sb.from('manifest_visits').select('visit_id').eq('manifest_id', id)
        const visitIdsC = ((mvsC || []) as { visit_id: number }[]).map((x) => x.visit_id)
        const attachments: { filename: string; content: string; content_type: string }[] = []
        let attachReasonC = ''
        if (renderDisabled) {
          attachReasonC = renderDisabled
        } else if (Date.now() - invocationStart > RENDER_DEADLINE_MS) {
          renderDisabled = 'render_deadline'
          attachReasonC = renderDisabled
        } else {
          const rC = await buildReportAttachment(sb, { manifestId: id, clientId, clientCode, visitIds: visitIdsC, number })
          if (rC.terminal) {
            console.error(`[send-derm-email] render_terminal manifest=${id} client=${clientId} reason=${rC.terminal}`)
            results.push({ manifest_id: id, status: 'skipped', reason: rC.terminal, client: clientCode })
            await logSend(id, logClientId, null, null, 'skipped', rC.terminal)
            continue
          }
          if (rC.trip) renderDisabled = rC.trip
          attachReasonC = rC.reason
          if (rC.att) attachments.push(rC.att)
          else console.error(`[send-derm-email] no_attachment manifest=${id} client=${clientId} reason=${rC.reason}`)
        }
        const attExt = 'pdf'

        const emailRes = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            from: RESEND_FROM,
            to: [toEmail],
            subject: SUBJECT,
            html: buildHtml(clientName, number, attExt),
            text: buildText(clientName, number, attExt),
            attachments,
            ...(ccList.length ? { cc: ccList } : {}),
            // "send to both": real client send + a BCC copy to the test address, plus any the
            // sender blind-copied. Deduped so one address cannot be listed twice.
            ...((() => {
              const b = [...new Set([...(testCc ? [testCc] : []), ...bccList])]
              return b.length ? { bcc: b } : {}
            })()),
          }),
        })
        const er = await emailRes.json().catch(() => ({}))
        if (!emailRes.ok) { results.push({ manifest_id: id, status: 'error', reason: 'resend_failed', detail: er, client: clientCode }); await logSend(id, logClientId, logEmail, null, 'error', 'resend_failed'); continue }

        const sentEmailId = (er as { id?: string })?.id ?? null
        results.push({ manifest_id: id, client_id: clientId, status: 'sent', to: testRecipient ? `${toEmail} (TEST)` : toEmail, client: clientCode, number, email_id: sentEmailId })
        await logSend(id, logClientId, logEmail, sentEmailId, 'sent', null)
      } catch (e) {
        const msg = String((e as Error)?.message ?? e)
        results.push({ manifest_id: id, status: 'error', reason: msg })
        await logSend(id, logClientId, logEmail, null, 'error', msg)
      }
    }
  }

  const sent = results.filter((r) => r.status === 'sent').length
  // `city_gate` names the address every city send was FORCED to, or null when live sending is
  // enabled. Surfaced rather than left as an internal flag so a tester can see the gate fired
  // instead of inferring it from where the mail landed.
  return jsonResponse({ ok: true, target, sent, total: recipients.length, test_mode: !!testRecipient, city_gate: cityGate, cc_test: !!testCc, results }, 200, cors)
})
