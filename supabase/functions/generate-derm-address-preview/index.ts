// ============================================================================
// generate-derm-address-preview/index.ts — Edge Function
// ============================================================================
// Download-only preview of the DERM Address PDF. Takes a list of visit_ids and
// streams the rendered PDF bytes back to the browser. No storage upload, no DB
// write. The sibling `generate-derm-address-pdf` function still handles the
// "save as the manifest's canonical address" flow.
//
// Flow:
//   browser (POST /functions/v1/generate-derm-address-preview, body: {visit_ids})
//     -> this Edge Function (validates body, adds bearer, restricts origin)
//     -> Railway PDF service /generate/derm-address/preview (renders + returns PDF)
//     -> response streamed back as application/pdf for browser download
//
// Env vars (set in Supabase Functions secrets, NOT in repo):
//   PDF_SERVICE_URL       — same Railway URL as the storage-saving function
//   PDF_SERVICE_API_KEY   — same bearer token
// ============================================================================

const PDF_SERVICE_URL = Deno.env.get('PDF_SERVICE_URL')
const PDF_SERVICE_API_KEY = Deno.env.get('PDF_SERVICE_API_KEY')

const ALLOWED_ORIGINS = new Set([
  'https://derm.unclogme.app',
])

function corsHeadersFor(origin: string | null): Record<string, string> {
  const allowed = origin && ALLOWED_ORIGINS.has(origin) ? origin : 'https://derm.unclogme.app'
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, content-type, x-client-info, apikey, x-app-source',
    'Access-Control-Expose-Headers': 'content-disposition, x-form-kind',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  }
}

function jsonResponse(
  body: Record<string, unknown>,
  status: number,
  cors: Record<string, string>,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req: Request) => {
  const cors = corsHeadersFor(req.headers.get('origin'))

  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: cors })
  }

  if (req.method !== 'POST') {
    return jsonResponse({ error: 'method_not_allowed' }, 405, cors)
  }

  if (!PDF_SERVICE_URL || !PDF_SERVICE_API_KEY) {
    console.error('Edge function missing PDF_SERVICE_URL or PDF_SERVICE_API_KEY')
    return jsonResponse({ error: 'service_not_configured' }, 503, cors)
  }

  let body: { visit_ids?: unknown; disposal_facility_id?: unknown }
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400, cors)
  }

  if (!Array.isArray(body.visit_ids) || body.visit_ids.length === 0) {
    return jsonResponse({ error: 'visit_ids_required_non_empty_array' }, 400, cors)
  }
  const visit_ids = body.visit_ids.filter(
    (v) => typeof v === 'number' && Number.isInteger(v) && v > 0,
  ) as number[]
  if (visit_ids.length === 0) {
    return jsonResponse({ error: 'visit_ids_must_be_positive_integers' }, 400, cors)
  }

  // WHERE THE TRUCK WILL DUMP. This chooses the FORM: a Broward facility gets the
  // FDEP 62-705.300(3) sheet (one page per visit), a Miami-Dade one gets the
  // DERM_V4.00 sheet. It is NOT the client's county.
  //
  // 🛑 THE BODY BELOW IS REBUILT, NOT PASSED THROUGH, AND THAT IS WHY THIS BLOCK
  // HAS TO EXIST. `JSON.stringify({ visit_ids })` silently drops every other key
  // under an HTTP 200, so an app that starts sending a facility gets a cheerful
  // success and the Miami-Dade form every single time. Rebuilding is the right
  // shape (it is what stops an arbitrary caller-controlled payload reaching the
  // PDF service), so each new field must be admitted deliberately, here.
  // ⚠ There is a SECOND place it can vanish: pydantic v2 defaults to
  // extra='ignore', so the field is declared on GenerateDermAddressPreviewRequest
  // too. Both halves are needed.
  let disposal_facility_id: number | undefined
  if (body.disposal_facility_id !== undefined && body.disposal_facility_id !== null) {
    const v = body.disposal_facility_id
    if (typeof v !== 'number' || !Number.isInteger(v) || v <= 0) {
      return jsonResponse({ error: 'disposal_facility_id_must_be_a_positive_integer' }, 400, cors)
    }
    disposal_facility_id = v
  }

  const target = `${PDF_SERVICE_URL.replace(/\/$/, '')}/generate/derm-address/preview`

  let upstream: Response
  try {
    upstream = await fetch(target, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${PDF_SERVICE_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(
        disposal_facility_id === undefined
          ? { visit_ids }
          : { visit_ids, disposal_facility_id },
      ),
    })
  } catch (e) {
    console.error('Forward to PDF service failed:', e)
    return jsonResponse({ error: 'pdf_service_unreachable' }, 502, cors)
  }

  // If upstream errored, return its JSON error body untouched.
  if (!upstream.ok) {
    const text = await upstream.text()
    return new Response(text, {
      status: upstream.status,
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  }

  // Stream the PDF bytes through. Preserve Content-Disposition so the browser
  // downloads with the filename Railway suggested.
  const headers: Record<string, string> = {
    ...cors,
    'Content-Type': upstream.headers.get('Content-Type') ?? 'application/pdf',
    'Cache-Control': 'no-store',
  }
  const disp = upstream.headers.get('Content-Disposition')
  if (disp) headers['Content-Disposition'] = disp
  // Which form actually came back. Without this the caller cannot tell a
  // correctly-rendered Miami-Dade sheet from a Broward request whose facility
  // was dropped somewhere in the chain: both are a valid PDF at HTTP 200.
  const formKind = upstream.headers.get('X-Form-Kind')
  if (formKind) headers['X-Form-Kind'] = formKind

  return new Response(upstream.body, { status: 200, headers })
})
