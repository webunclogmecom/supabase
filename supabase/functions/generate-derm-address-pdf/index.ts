// ============================================================================
// generate-derm-address-pdf/index.ts — Edge Function
// ============================================================================
// Thin proxy from the browser (DERM Tracker Lovable app) to the Railway-hosted
// unclogme-pdf-service. Keeps the PDF_SERVICE_API_KEY off the client.
//
// Flow:
//   browser (POST /functions/v1/generate-derm-address-pdf, body: {manifest_id})
//     → this Edge Function (validates body, adds bearer, restricts origin)
//     → Railway PDF service (renders PDF, uploads to Storage, updates DB)
//     → response bubbles back to browser as {manifest_id, url, storage_path}
//
// Env vars (set in Supabase Functions secrets, NOT in repo):
//   PDF_SERVICE_URL       — full URL to Railway service (e.g. https://...up.railway.app)
//   PDF_SERVICE_API_KEY   — bearer token, matches Railway's PDF_SERVICE_API_KEY
//
// Auth: anon-callable for MVP (matches DERM Tracker app's anon auth model).
// Origin-checked via CORS so casual browsers from elsewhere can't call it.
// TODO Phase 2: validate Supabase JWT and check the user actually owns / can
// access the manifest before forwarding.
// ============================================================================

const PDF_SERVICE_URL = Deno.env.get('PDF_SERVICE_URL')
const PDF_SERVICE_API_KEY = Deno.env.get('PDF_SERVICE_API_KEY')

// Origins that may call this function. Add new app subdomains here.
const ALLOWED_ORIGINS = new Set([
  'https://derm.unclogme.app',
  // Lovable preview origin pattern is `https://<project-id>--<branch>.lovable.app`
  // — list the DERM Tracker project preview origin if we want to test against
  // the unpublished preview. For now we only allow the production subdomain.
])

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

  // Preflight
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

  let body: { manifest_id?: unknown }
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400, cors)
  }

  // Accept both 42 and "42": PostgREST bigint ids round-trip as strings in
  // some client paths (the DERM Tracker's first live call sent "1445"), and
  // rejecting the string form only manufactures avoidable 400s.
  const manifestId = Number(body.manifest_id)
  if (!Number.isInteger(manifestId) || manifestId <= 0) {
    return jsonResponse({ error: 'manifest_id_required_integer' }, 400, cors)
  }

  const target = `${PDF_SERVICE_URL.replace(/\/$/, '')}/generate/derm-address`

  let upstream: Response
  try {
    upstream = await fetch(target, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${PDF_SERVICE_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ manifest_id: manifestId }),
    })
  } catch (e) {
    console.error('Forward to PDF service failed:', e)
    return jsonResponse({ error: 'pdf_service_unreachable' }, 502, cors)
  }

  const text = await upstream.text()
  return new Response(text, {
    status: upstream.status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  })
})
