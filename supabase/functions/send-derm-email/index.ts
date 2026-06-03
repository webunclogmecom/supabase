// ============================================================================
// send-derm-email/index.ts — Edge Function
// ============================================================================
// Sends the "Your Manifest Form from Unclogme" email + the WWTP-receipt PDF to
// a manifest's client(s), via Resend. Replaces the Airtable "Send DERM to
// client" automation. Called from the DERM Tracker /manifests "email" modal.
//
// Flow:
//   browser (POST /functions/v1/send-derm-email, body below)
//     → this function resolves each manifest row SERVER-SIDE (client, email,
//       WWTP-receipt PDF url) using the service role, fetches the PDF, and
//       sends one email per row via Resend.
//
// Input (POST JSON):
//   { manifest_ids: number[],          // public.derm_manifests row ids (each = one client's manifest)
//     test_recipient?: string }        // if set, ALL emails go HERE instead of the real client (test mode)
//
// Env vars (Supabase Functions secrets — NOT in repo):
//   RESEND_API_KEY   — required; Resend API key
//   RESEND_FROM      — optional; default 'Unclogme <onboarding@resend.dev>' (Resend test sender,
//                      works before unclogme.com is verified). Set to
//                      'Unclogme <contact@unclogme.com>' once the domain is verified in Resend.
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — auto-injected; used for server-side lookups.
//
// Attachment = derm_manifests.derm_manifest_url (the WWTP/septage receipt — what the
// app labels "Manifest"). Recipient = client_contacts.email for the row's client.
//
// Auth: anon-callable for MVP (matches DERM Tracker), origin-restricted to derm.unclogme.app.
// NB (Phase 2): validate a Supabase JWT + restrict test_recipient — anon callers can
// currently target test_recipient with the fixed DERM template; low-risk but tighten with auth.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { encodeBase64 } from 'https://deno.land/std@0.224.0/encoding/base64.ts'

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')
const RESEND_FROM = Deno.env.get('RESEND_FROM') ?? 'Unclogme <onboarding@resend.dev>'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

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

// Brand assets / tokens (UnclogMe). Logo hosted in our own Storage (stable URL,
// not the Lovable build-hashed asset). Manrope leads the stack but email clients
// fall back to a system sans — the layout/colors carry the brand, not the font.
const LOGO_URL = 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/_brand/unclogme-logo.jpg'
const FONT_STACK = "'Manrope', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] ?? c))
}

// Branded, email-safe HTML (table layout + inline styles; renders in Gmail/Outlook/Apple Mail).
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

// Plain-text fallback (deliverability + text-only clients).
function buildText(clientName: string, number: string, ext: string): string {
  return [
    `Hi ${clientName},`,
    '',
    'Thank you for choosing Unclogme!',
    '',
    `Attached, you'll find your Manifest Form (DERM-Manifest-${number}.${ext}) required by the Water and Sewer Department. Please review it carefully and keep it for your records.`,
    '',
    'If you have any questions or need assistance regarding this document, please reach us at contact@unclogme.com or call us directly.',
    '',
    '--',
    'Unclogme LLC',
    '333 West 41st Street, Suite 606, Miami Beach, FL 33140',
    'contact@unclogme.com',
  ].join('\n')
}

Deno.serve(async (req: Request) => {
  const cors = corsHeadersFor(req.headers.get('origin'))
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors })
  if (req.method !== 'POST') return jsonResponse({ error: 'method_not_allowed' }, 405, cors)
  if (!RESEND_API_KEY) return jsonResponse({ error: 'email_not_configured', detail: 'RESEND_API_KEY not set' }, 503, cors)
  if (!SUPABASE_URL || !SERVICE_KEY) return jsonResponse({ error: 'service_not_configured' }, 503, cors)

  let body: { manifest_ids?: unknown; recipients?: unknown; test_recipient?: unknown }
  try { body = await req.json() } catch { return jsonResponse({ error: 'bad_json' }, 400, cors) }

  // Recipients are (manifest_id, client_id) pairs — one manifest can cover several clients
  // (a shared WWTP receipt links visits from multiple clients). Prefer `recipients`; fall back
  // to `manifest_ids` (client_id resolved to the manifest's own client below) for compatibility.
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
    recipients = (body.manifest_ids as unknown[])
      .map(Number)
      .filter((n) => Number.isFinite(n))
      .map((id) => ({ manifest_id: id, client_id: null }))
  }
  // de-dup on (manifest_id, client_id)
  const seenRec = new Set<string>()
  recipients = recipients.filter((r) => {
    const k = `${r.manifest_id}:${r.client_id ?? 'own'}`
    if (seenRec.has(k)) return false
    seenRec.add(k)
    return true
  })
  const testRecipient =
    typeof body?.test_recipient === 'string' && body.test_recipient.includes('@')
      ? body.test_recipient.trim()
      : null
  if (recipients.length === 0) return jsonResponse({ error: 'no_recipients' }, 400, cors)

  const sb = createClient(SUPABASE_URL, SERVICE_KEY)
  const results: Record<string, unknown>[] = []

  for (const rec of recipients) {
    const id = rec.manifest_id
    try {
      const { data: m, error: me } = await sb
        .from('derm_manifests')
        .select('id, client_id, white_manifest_number, yellow_ticket_number, derm_manifest_url, deleted_at')
        .eq('id', id)
        .maybeSingle()
      if (me) throw me
      if (!m || m.deleted_at) { results.push({ manifest_id: id, status: 'skipped', reason: 'not_found_or_deleted' }); continue }
      if (!m.derm_manifest_url) { results.push({ manifest_id: id, status: 'skipped', reason: 'no_pdf' }); continue }

      const number = m.white_manifest_number || m.yellow_ticket_number || String(id)

      // recipient client = explicit client_id from the pair, else the manifest's own client
      const clientId = rec.client_id ?? (m.client_id as number)
      const { data: c } = await sb.from('clients').select('name, client_code').eq('id', clientId).maybeSingle()
      const clientName = c?.name || 'Customer'
      const clientCode = c?.client_code || null

      let toEmail: string | null = testRecipient
      if (!toEmail) {
        const { data: cc } = await sb
          .from('client_contacts')
          .select('email')
          .eq('client_id', clientId)
          .not('email', 'is', null)
          .neq('email', '')
          .limit(1)
          .maybeSingle()
        toEmail = cc?.email ?? null
      }
      if (!toEmail) { results.push({ manifest_id: id, status: 'skipped', reason: 'no_email', client: clientCode }); continue }

      const pdfResp = await fetch(m.derm_manifest_url)
      if (!pdfResp.ok) { results.push({ manifest_id: id, status: 'error', reason: 'pdf_fetch_failed', http: pdfResp.status }); continue }
      const b64 = encodeBase64(new Uint8Array(await pdfResp.arrayBuffer()))

      // The WWTP receipt may be a PDF or an image (phone photo of the receipt). Use the source's
      // REAL media type (from the fetch response, URL extension as fallback) to both name AND type
      // the attachment — a JPEG renamed .pdf won't open in a PDF viewer (the bug we hit). Setting
      // content_type explicitly stops Gmail/Outlook from guessing wrong off the filename.
      const srcCt = (pdfResp.headers.get('content-type') || '').split(';')[0].trim().toLowerCase()
      const extFromUrl = m.derm_manifest_url.split('?')[0].match(/\.([a-z0-9]{2,5})$/i)?.[1]?.toLowerCase()
      const CT_TO_EXT: Record<string, string> = { 'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/jpg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/heic': 'heic', 'image/heif': 'heif' }
      const attExt = extFromUrl || CT_TO_EXT[srcCt] || 'pdf'
      const attType = srcCt || (attExt === 'pdf' ? 'application/pdf' : `image/${attExt === 'jpg' ? 'jpeg' : attExt}`)

      const emailRes = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from: RESEND_FROM,
          to: [toEmail],
          subject: SUBJECT,
          html: buildHtml(clientName, number, attExt),
          text: buildText(clientName, number, attExt),
          attachments: [{ filename: `DERM-Manifest-${number}.${attExt}`, content: b64, content_type: attType }],
        }),
      })
      const er = await emailRes.json().catch(() => ({}))
      if (!emailRes.ok) { results.push({ manifest_id: id, status: 'error', reason: 'resend_failed', detail: er, client: clientCode }); continue }

      results.push({ manifest_id: id, client_id: clientId, status: 'sent', to: testRecipient ? `${toEmail} (TEST)` : toEmail, client: clientCode, number, email_id: (er as { id?: string })?.id })
    } catch (e) {
      results.push({ manifest_id: id, status: 'error', reason: String((e as Error)?.message ?? e) })
    }
  }

  const sent = results.filter((r) => r.status === 'sent').length
  return jsonResponse({ ok: true, sent, total: recipients.length, test_mode: !!testRecipient, results }, 200, cors)
})
