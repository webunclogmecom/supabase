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

function buildHtml(clientName: string): string {
  return [
    `Hi ${clientName},`,
    '',
    'Thank you for choosing Unclogme!',
    '',
    "Attached, you'll find your Manifest Form required by the Water and Sewer Department. Please review it carefully and keep it for your records.",
    '',
    'If you have any questions or need assistance regarding this document, please feel free to reach us at contact@unclogme.com or call us directly.',
  ].join('<br>')
}

Deno.serve(async (req: Request) => {
  const cors = corsHeadersFor(req.headers.get('origin'))
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors })
  if (req.method !== 'POST') return jsonResponse({ error: 'method_not_allowed' }, 405, cors)
  if (!RESEND_API_KEY) return jsonResponse({ error: 'email_not_configured', detail: 'RESEND_API_KEY not set' }, 503, cors)
  if (!SUPABASE_URL || !SERVICE_KEY) return jsonResponse({ error: 'service_not_configured' }, 503, cors)

  let body: { manifest_ids?: unknown; test_recipient?: unknown }
  try { body = await req.json() } catch { return jsonResponse({ error: 'bad_json' }, 400, cors) }

  const manifestIds = Array.isArray(body?.manifest_ids)
    ? [...new Set((body.manifest_ids as unknown[]).map(Number).filter((n) => Number.isFinite(n)))]
    : []
  const testRecipient =
    typeof body?.test_recipient === 'string' && body.test_recipient.includes('@')
      ? body.test_recipient.trim()
      : null
  if (manifestIds.length === 0) return jsonResponse({ error: 'no_manifest_ids' }, 400, cors)

  const sb = createClient(SUPABASE_URL, SERVICE_KEY)
  const results: Record<string, unknown>[] = []

  for (const id of manifestIds) {
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

      const { data: c } = await sb.from('clients').select('name, client_code').eq('id', m.client_id).maybeSingle()
      const clientName = c?.name || 'Customer'
      const clientCode = c?.client_code || null

      let toEmail: string | null = testRecipient
      if (!toEmail) {
        const { data: cc } = await sb
          .from('client_contacts')
          .select('email')
          .eq('client_id', m.client_id)
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

      const emailRes = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from: RESEND_FROM,
          to: [toEmail],
          subject: SUBJECT,
          html: buildHtml(clientName),
          attachments: [{ filename: `DERM-Manifest-${number}.pdf`, content: b64 }],
        }),
      })
      const er = await emailRes.json().catch(() => ({}))
      if (!emailRes.ok) { results.push({ manifest_id: id, status: 'error', reason: 'resend_failed', detail: er, client: clientCode }); continue }

      results.push({ manifest_id: id, status: 'sent', to: testRecipient ? `${toEmail} (TEST)` : toEmail, client: clientCode, number, email_id: (er as { id?: string })?.id })
    } catch (e) {
      results.push({ manifest_id: id, status: 'error', reason: String((e as Error)?.message ?? e) })
    }
  }

  const sent = results.filter((r) => r.status === 'sent').length
  return jsonResponse({ ok: true, sent, total: manifestIds.length, test_mode: !!testRecipient, results }, 200, cors)
})
