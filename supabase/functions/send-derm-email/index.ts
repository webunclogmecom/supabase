// ============================================================================
// send-derm-email/index.ts — Edge Function
// ============================================================================
// Sends DERM manifests via Resend. TWO targets (body `target`, default 'client'):
//   target:'client' — the existing "Send DERM to client": the WWTP receipt
//     (derm_manifest_url) to the client's own email, friendly branded copy.
//   target:'city'   — "Send DERM to City": BOTH PDFs (Manifest Form = derm_address_url,
//     Transporter Manifest = derm_manifest_url) to the municipal FOG-program email(s)
//     of the served location, formal copy, BCC derm@ayache.com (real sends only).
//
// Input (POST JSON):
//   { recipients: [{ manifest_id, client_id }],   // or manifest_ids: number[]
//     target?: 'client' | 'city',                 // default 'client'
//     test_recipient?: string,                    // if set, send ONLY there (is_test) — real clients/city NOT emailed
//     test_cc?: string }                           // "send to both": REAL send to clients/city + BCC a copy here
//
// Logs every attempt to public.derm_email_sends with recipient_type = target.
// Auth: anon-callable for MVP, origin-restricted to derm.unclogme.app.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { encodeBase64 } from 'https://deno.land/std@0.224.0/encoding/base64.ts'

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')
const RESEND_FROM = Deno.env.get('RESEND_FROM') ?? 'Unclogme <onboarding@resend.dev>'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
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

const SUBJECT = 'Your Manifest Form from Unclogme'

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
<div style="display:none;max-height:0;overflow:hidden;opacity:0;font-size:1px;line-height:1px;color:#f4f5f7;">Your DERM Manifest Form is attached &mdash; required by the Water &amp; Sewer Department. Please keep it for your records.</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f4f5f7;"><tr><td align="center" style="padding:32px 16px;">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;background-color:#ffffff;border-radius:12px;border:1px solid #e6e8eb;border-top:4px solid #f14714;">
<tr><td style="padding:28px 36px 20px 36px;border-bottom:1px solid #eef0f2;"><img src="${LOGO_URL}" alt="UnclogMe" width="144" height="48" style="display:block;border:0;outline:none;text-decoration:none;height:48px;width:144px;"></td></tr>
<tr><td style="padding:32px 36px 4px 36px;font-family:${FONT_STACK};">
<p style="margin:0 0 18px 0;font-size:18px;line-height:1.5;font-weight:700;color:#111827;">Hi ${name},</p>
<p style="margin:0 0 16px 0;font-size:15px;line-height:1.65;color:#374151;">Thank you for choosing Unclogme!</p>
<p style="margin:0 0 24px 0;font-size:15px;line-height:1.65;color:#374151;">Attached, you'll find your <strong style="color:#111827;">Manifest Form</strong> required by the Water &amp; Sewer Department. Please review it carefully and keep it for your records.</p>
</td></tr>
<tr><td style="padding:0 36px 28px 36px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#fff7f4;border:1px solid #ffd9c9;border-radius:10px;"><tr><td style="padding:16px 18px;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
<td valign="middle" width="40" style="width:40px;"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr><td align="center" valign="middle" height="40" style="width:40px;height:40px;background-color:#f14714;border-radius:8px;font-family:Arial,Helvetica,sans-serif;font-size:11px;font-weight:bold;color:#ffffff;letter-spacing:0.5px;">${badge}</td></tr></table></td>
<td valign="middle" style="padding-left:14px;font-family:${FONT_STACK};">
<div style="font-size:14px;font-weight:600;color:#111827;line-height:1.3;">Manifest Form attached</div>
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
    `Attached, you'll find your Manifest Form (DERM-Manifest-${number}.${ext}) required by the Water and Sewer Department. Please review it carefully and keep it for your records.`, '',
    'If you have any questions or need assistance regarding this document, please reach us at contact@unclogme.com or call us directly.', '',
    '--', 'Unclogme LLC', '333 West 41st Street, Suite 606, Miami Beach, FL 33140', 'contact@unclogme.com',
  ].join('\n')
}

// ---- CITY email (formal, to the municipal FOG office, two attachments) -----
function buildCityHtml(clientName: string, address: string, visitDate: string): string {
  const name = escapeHtml(clientName)
  const addr = escapeHtml(address || '')
  const vdate = escapeHtml(visitDate || '')
  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><meta http-equiv="X-UA-Compatible" content="IE=edge"><title>DERM Manifest for ${name}</title></head>
<body style="margin:0;padding:0;background-color:#f4f5f7;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;font-size:1px;line-height:1px;color:#f4f5f7;">DERM Manifest submission for ${name} &mdash; Manifest Form + Transporter Manifest attached for your compliance records.</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f4f5f7;"><tr><td align="center" style="padding:32px 16px;">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;background-color:#ffffff;border-radius:12px;border:1px solid #e6e8eb;border-top:4px solid #f14714;">
<tr><td style="padding:28px 36px 20px 36px;border-bottom:1px solid #eef0f2;"><img src="${LOGO_URL}" alt="UnclogMe" width="144" height="48" style="display:block;border:0;outline:none;text-decoration:none;height:48px;width:144px;"></td></tr>
<tr><td style="padding:32px 36px 8px 36px;font-family:${FONT_STACK};">
<p style="margin:0 0 18px 0;font-size:16px;line-height:1.5;font-weight:700;color:#111827;">Dear Environmental Compliance Team,</p>
<p style="margin:0 0 16px 0;font-size:15px;line-height:1.65;color:#374151;">The service for our client <strong style="color:#111827;">${name}</strong> located at <strong style="color:#111827;">${addr}</strong> was performed on <strong style="color:#111827;">${vdate}</strong>.</p>
<p style="margin:0 0 16px 0;font-size:15px;line-height:1.65;color:#374151;">Attached, you'll find the <strong style="color:#111827;">Manifest Form</strong> and the corresponding <strong style="color:#111827;">Transporter Manifest</strong>.</p>
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

function buildCityText(clientName: string, address: string, visitDate: string): string {
  return [
    'Dear Environmental Compliance Team,', '',
    `The service for our client ${clientName} located at ${address} was performed on ${visitDate}.`, '',
    "Attached, you'll find the Manifest Form and the corresponding Transporter Manifest.", '',
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
  const b64 = encodeBase64(new Uint8Array(await resp.arrayBuffer()))
  const srcCt = (resp.headers.get('content-type') || '').split(';')[0].trim().toLowerCase()
  const extFromUrl = url.split('?')[0].match(/\.([a-z0-9]{2,5})$/i)?.[1]?.toLowerCase()
  const attExt = extFromUrl || CT_TO_EXT[srcCt] || 'pdf'
  const attType = srcCt || (attExt === 'pdf' ? 'application/pdf' : `image/${attExt === 'jpg' ? 'jpeg' : attExt}`)
  return { filename: `${baseName}.${attExt}`, content: b64, content_type: attType }
}

Deno.serve(async (req: Request) => {
  const cors = corsHeadersFor(req.headers.get('origin'))
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors })
  if (req.method !== 'POST') return jsonResponse({ error: 'method_not_allowed' }, 405, cors)
  if (!RESEND_API_KEY) return jsonResponse({ error: 'email_not_configured', detail: 'RESEND_API_KEY not set' }, 503, cors)
  if (!SUPABASE_URL || !SERVICE_KEY) return jsonResponse({ error: 'service_not_configured' }, 503, cors)

  let body: { manifest_ids?: unknown; recipients?: unknown; test_recipient?: unknown; test_cc?: unknown; target?: unknown }
  try { body = await req.json() } catch { return jsonResponse({ error: 'bad_json' }, 400, cors) }

  type Rec = { manifest_id: number; client_id: number | null }
  let recipients: Rec[] = []
  if (Array.isArray(body?.recipients)) {
    recipients = (body.recipients as unknown[])
      .map((r) => {
        const o = (r ?? {}) as { manifest_id?: unknown; client_id?: unknown }
        return { manifest_id: Number(o.manifest_id), client_id: o.client_id == null ? null : Number(o.client_id) }
      })
      .filter((r) => Number.isFinite(r.manifest_id))
  } else if (Array.isArray(body?.manifest_ids)) {
    recipients = (body.manifest_ids as unknown[]).map(Number).filter((n) => Number.isFinite(n)).map((id) => ({ manifest_id: id, client_id: null }))
  }
  const seenRec = new Set<string>()
  recipients = recipients.filter((r) => {
    const k = `${r.manifest_id}:${r.client_id ?? 'own'}`
    if (seenRec.has(k)) return false
    seenRec.add(k)
    return true
  })
  const testRecipient =
    typeof body?.test_recipient === 'string' && body.test_recipient.includes('@') ? body.test_recipient.trim() : null
  // test_cc = the "send to BOTH" copy (Fred 2026-07-09): a REAL send to the clients/city
  // PLUS a BCC copy to this address so the sender can verify what went out. Distinct from
  // test_recipient (which SUPPRESSES the real send). Ignored when test_recipient is set
  // (that path already sends only to the test address, so there is no real send to copy).
  const testCc =
    !testRecipient && typeof body?.test_cc === 'string' && body.test_cc.includes('@') ? body.test_cc.trim() : null
  const target = body?.target === 'city' ? 'city' : 'client'
  if (recipients.length === 0) return jsonResponse({ error: 'no_recipients' }, 400, cors)

  const sb = createClient(SUPABASE_URL, SERVICE_KEY, { global: { headers: { 'x-app-source': 'send-derm-email' } } })
  const results: Record<string, unknown>[] = []
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
        sent_by_email: actorEmail, sent_by_user_id: actorUserId,
      })
      if (error) console.error(`[send-derm-email] log insert failed: ${error.message}`)
    } catch (e) {
      console.error(`[send-derm-email] log insert threw: ${String((e as Error)?.message ?? e)}`)
    }
  }

  if (target === 'city') {
    // ===== CITY: both PDFs to the municipal FOG office, formal letter, BCC compliance =====
    // 🛑 THE CITY INBOX MOVED FROM THE CITY TO THE PROPERTY (2026-08-21,
    //    docs/migrations/2026-08-21_2130_property_city_emails_per_property.sql).
    //    There is no municipality_regulators lookup here any more: that table still holds its rows
    //    for history, but it is EMPTY of live addresses and no longer feeds anything. Reading it
    //    now would resolve zero recipients and every send would log 'no_city_email' - a silent,
    //    total failure that looks exactly like "no city has been configured yet".
    //    Recipients come from public.properties.city_emails, per property.

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
        const { data: c } = await sb.from('clients').select('name').eq('id', clientId).maybeSingle()
        const clientName = c?.name || 'Customer'

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
        const { data: props } = await sb.from('properties')
          .select('address, city, city_emails').eq('client_id', clientId).is('deleted_at', null)
        const cityEmailSet = new Set<string>()
        const muniSet = new Set<string>()
        let servedAddress = ''
        for (const p of (props || []) as { address: string | null; city: string | null; city_emails: string[] | null }[]) {
          const emails = (p.city_emails || [])
            .map((e) => String(e ?? '').trim().toLowerCase())
            .filter((e) => e.includes('@'))
          if (!emails.length) continue
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
        // ONE image by design: the redaction targets the page carrying this client's row
        // (`effective_page`), so the other pages are exactly the ones we are declining to disclose.
        const addressUrls = [redactedUrl]
        const transUrls = [m.derm_manifest_url, ...(((m.derm_manifest_extra_urls as string[] | null) || []))].filter(Boolean)
        const attachments: { filename: string; content: string; content_type: string }[] = []
        let fetchFailed = false
        for (let i = 0; i < addressUrls.length; i++) {
          const suffix = addressUrls.length > 1 ? `-${i + 1}` : ''
          const att = await fetchAttachment(addressUrls[i], `DERM-Manifest-Form-${number}${suffix}`)
          if (!att) { fetchFailed = true; break }
          attachments.push(att)
        }
        if (!fetchFailed) for (let i = 0; i < transUrls.length; i++) {
          const suffix = transUrls.length > 1 ? `-${i + 1}` : ''
          const att = await fetchAttachment(transUrls[i], `DERM-Transporter-Manifest-${number}${suffix}`)
          if (!att) { fetchFailed = true; break }
          attachments.push(att)
        }
        if (fetchFailed) { results.push({ manifest_id: id, status: 'error', reason: 'pdf_fetch_failed', client: clientName }); await logSend(id, logClientId, logEmail, null, 'error', 'pdf_fetch_failed', 'city'); continue }

        const payload: Record<string, unknown> = {
          from: RESEND_FROM,
          to: toList,
          subject: `DERM Manifest for ${clientName}`,
          html: buildCityHtml(clientName, servedAddress, fmtDate(visitDate)),
          text: buildCityText(clientName, servedAddress, fmtDate(visitDate)),
          attachments,
        }
        // BCC = compliance copy on real sends (CITY_BCC) + the test_cc "send-to-both" copy.
        const cityBcc = [...(!testRecipient ? [CITY_BCC] : []), ...(testCc ? [testCc] : [])]
        if (cityBcc.length) payload.bcc = cityBcc

        const emailRes = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        })
        const er = await emailRes.json().catch(() => ({}))
        if (!emailRes.ok) { results.push({ manifest_id: id, status: 'error', reason: 'resend_failed', detail: er, client: clientName }); await logSend(id, logClientId, logEmail, null, 'error', 'resend_failed', 'city'); continue }

        const sentEmailId = (er as { id?: string })?.id ?? null
        results.push({ manifest_id: id, client_id: clientId, status: 'sent', to: testRecipient ? `${toList.join(', ')} (TEST)` : toList.join(', '), municipality, number, email_id: sentEmailId })
        await logSend(id, logClientId, logEmail, sentEmailId, 'sent', null, 'city')
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

        // The WWTP receipt can be multi-page (derm_manifest_extra_urls). Send the primary
        // + every extra so a multi-page receipt reaches the client complete. (This is the
        // client's OWN WWTP receipt only — NEVER the shared DERM Address sheet, which lists
        // co-clients; that stays City-only to avoid a co-client PII leak.)
        const manUrls = [m.derm_manifest_url, ...(((m.derm_manifest_extra_urls as string[] | null) || []))].filter(Boolean)
        const attachments: { filename: string; content: string; content_type: string }[] = []
        let fetchFailed = false
        for (let i = 0; i < manUrls.length; i++) {
          const suffix = manUrls.length > 1 ? `-${i + 1}` : ''
          const att = await fetchAttachment(manUrls[i], `DERM-Manifest-${number}${suffix}`)
          if (!att) { fetchFailed = true; break }
          attachments.push(att)
        }
        if (fetchFailed) { results.push({ manifest_id: id, status: 'error', reason: 'pdf_fetch_failed' }); await logSend(id, logClientId, logEmail, null, 'error', 'pdf_fetch_failed'); continue }
        const attExt = attachments[0].filename.split('.').pop() || 'pdf'

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
            // "send to both": real client send + a BCC copy to the test address.
            ...(testCc ? { bcc: [testCc] } : {}),
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
  return jsonResponse({ ok: true, target, sent, total: recipients.length, test_mode: !!testRecipient, cc_test: !!testCc, results }, 200, cors)
})
