// ============================================================================
// derm-visit-report/index.ts — Edge Function (2026-09-24)
// ============================================================================
// Fred: a "Download Report" button on the DERM Tracker's visit page
// (derm.unclogme.app/visits/XXXX), before "Open in FP", that downloads the SAME
// Service Report the Field Portal's "Download report" produces.
//
// So this does not build a report. It asks the pdf-service to PRINT the Field
// Portal's own report page (/{slug}/visit/{public_id}/report) - the exact page FP
// users save as PDF - and streams the bytes back. Same structure, logic, style and
// theme by construction: there is one report, and this prints it.
//
// Flow:
//   browser (POST, body {visit_id}, the STAFF user's access token)
//     -> this function (staff gate, resolves public_id + client_code server-side)
//     -> pdf-service POST /generate/visit-report (bearer PDF_SERVICE_API_KEY)
//     -> application/pdf streamed back, Content-Disposition passed through
//
// Read-only: no storage write, no DB write.
//
// 🛑 verify_jwt = false in config.toml, and the gate is IN THE HANDLER: a real signed-in
// @ayache.com / @unclogme.com user. The gateway alone would accept the public anon key.
// 🛑 public_id and client_code are resolved HERE from visit_id, never taken from the caller:
// the Field Portal resolves a report from public_id alone, so a caller-supplied id would let
// anyone with a staff login pull any client's report under a different visit.
// client_code is still sent so the pdf-service refuses (409 client_mismatch) a report that
// does not name that client.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
const PDF_SERVICE_URL = Deno.env.get('PDF_SERVICE_URL')
const PDF_SERVICE_API_KEY = Deno.env.get('PDF_SERVICE_API_KEY')

// The renderer is a headless browser printing a page with photos. Same budget as the Admin
// Review email path (send-visit-photos-email), which calls the same endpoint.
const PDF_TIMEOUT_MS = 65_000

const ALLOWED_ORIGINS = new Set(['https://derm.unclogme.app'])
// The Lovable editor preview of the DERM Tracker, so the button can be tried before publishing.
const PREVIEW_ORIGIN = /^https:\/\/[a-z0-9-]+\.(lovable\.app|lovableproject\.com)$/

function corsHeadersFor(origin: string | null): Record<string, string> {
  const ok = !!origin && (ALLOWED_ORIGINS.has(origin) || PREVIEW_ORIGIN.test(origin))
  return {
    'Access-Control-Allow-Origin': ok ? origin! : 'https://derm.unclogme.app',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, content-type, x-client-info, apikey, x-app-source',
    'Access-Control-Expose-Headers': 'content-disposition',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  }
}

// `message` is shown to the operator verbatim, so it is a plain sentence. `error` is the code.
function fail(error: string, message: string, status: number, cors: Record<string, string>): Response {
  return new Response(JSON.stringify({ ok: false, error, message }), {
    status, headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  })
}

Deno.serve(async (req: Request) => {
  const cors = corsHeadersFor(req.headers.get('origin'))
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors })
  if (req.method !== 'POST') return fail('method_not_allowed', 'Use POST.', 405, cors)

  // -- AUTH: a real signed-in staff user, not merely a valid-looking JWT ---------------------
  const bearer = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
  if (!bearer) return fail('unauthorized', 'Sign in again to download the report.', 401, cors)
  const { data: userData, error: userErr } = await createClient(SUPABASE_URL, ANON_KEY || SERVICE_KEY)
    .auth.getUser(bearer)
  const email = String(userData?.user?.email ?? '').toLowerCase()
  if (userErr || !userData?.user?.id || !(email.endsWith('@ayache.com') || email.endsWith('@unclogme.com'))) {
    return fail('unauthorized', 'Sign in with your UnclogMe account to download the report.', 401, cors)
  }

  if (!PDF_SERVICE_URL || !PDF_SERVICE_API_KEY) {
    console.error('[derm-visit-report] PDF_SERVICE_URL or PDF_SERVICE_API_KEY not set')
    return fail('service_not_configured', 'The report service is not set up. Nothing was downloaded.', 503, cors)
  }

  let body: { visit_id?: unknown }
  try { body = await req.json() } catch { return fail('bad_json', 'The request was not readable.', 400, cors) }
  const visitId = Number(body?.visit_id)
  if (!Number.isInteger(visitId) || visitId <= 0) return fail('visit_id_required', 'No visit was given.', 400, cors)

  // -- resolve the visit server-side --------------------------------------------------------
  const sb = createClient(SUPABASE_URL, SERVICE_KEY, { global: { headers: { 'x-app-source': 'derm-visit-report' } } })
  const { data: v, error: vErr } = await sb.from('visits')
    .select('id, public_id, deleted_at, clients(client_code)')
    .eq('id', visitId).maybeSingle()
  if (vErr) {
    console.error(`[derm-visit-report] visit ${visitId} lookup failed: ${vErr.message}`)
    return fail('lookup_failed', 'Could not look up this visit. Try again.', 502, cors)
  }
  if (!v || v.deleted_at) return fail('visit_not_found', 'This visit no longer exists.', 404, cors)
  const publicId = String((v as any).public_id ?? '').trim()
  if (!publicId) return fail('no_report', 'This visit has no service report yet.', 409, cors)
  const clientCode = String(((v as any).clients as any)?.client_code ?? '').trim() || null

  // -- ask the pdf-service to print the Field Portal report ---------------------------------
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), PDF_TIMEOUT_MS)
  let up: Response
  try {
    up = await fetch(`${PDF_SERVICE_URL.replace(/\/$/, '')}/generate/visit-report`, {
      method: 'POST', signal: ctrl.signal,
      headers: { Authorization: `Bearer ${PDF_SERVICE_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(clientCode
        ? { client_code: clientCode, public_id: publicId, include_photos: true }
        : { public_id: publicId, include_photos: true }),
    })
  } catch (e) {
    clearTimeout(timer)
    const msg = ctrl.signal.aborted ? `timeout after ${PDF_TIMEOUT_MS}ms` : String((e as Error)?.message ?? e)
    console.error(`[derm-visit-report] visit ${visitId}: pdf-service unreachable: ${msg}`)
    return fail('pdf_service_unreachable', 'The report took too long to prepare. Try again.', 504, cors)
  }

  if (up.status === 409) {
    clearTimeout(timer)
    let code = 'report_not_available'
    try { code = (await up.json())?.error ?? code } catch { /* keep default */ }
    return code === 'client_mismatch'
      ? fail(code, 'The report the Field Portal returned is for a different client, so it was not downloaded.', 409, cors)
      : fail(code, 'The Field Portal has no service report for this visit.', 409, cors)
  }
  if (up.status === 503) {
    clearTimeout(timer)
    return fail('renderer_busy', 'The report maker is busy. Try again in a moment.', 503, cors)
  }
  if (!up.ok) {
    clearTimeout(timer)
    console.error(`[derm-visit-report] visit ${visitId}: pdf-service ${up.status}: ${(await up.text().catch(() => '')).slice(0, 300)}`)
    return fail('pdf_service_failed', 'The report could not be prepared. Try again.', 502, cors)
  }
  // 🛑 Check the CONTENT TYPE and the bytes, not just the status: an upstream that answers HTML
  // at 200 must never be handed to the browser as a "report".
  const ctype = up.headers.get('content-type') ?? ''
  let bytes: Uint8Array
  try { bytes = new Uint8Array(await up.arrayBuffer()) } finally { clearTimeout(timer) }
  if (!ctype.includes('pdf') || bytes.length < 5 || new TextDecoder().decode(bytes.slice(0, 5)) !== '%PDF-') {
    console.error(`[derm-visit-report] visit ${visitId}: not a PDF (content-type ${ctype}, ${bytes.length} bytes)`)
    return fail('not_a_pdf', 'The report could not be prepared. Try again.', 502, cors)
  }

  const headers: Record<string, string> = { ...cors, 'Content-Type': 'application/pdf', 'Cache-Control': 'no-store' }
  const disp = up.headers.get('Content-Disposition')
  headers['Content-Disposition'] = disp ?? `attachment; filename="Service-Report-${visitId}.pdf"`
  return new Response(bytes, { status: 200, headers })
})
