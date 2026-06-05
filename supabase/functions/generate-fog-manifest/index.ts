// ============================================================================
// generate-fog-manifest/index.ts — Edge Function
// ============================================================================
// Thin proxy to the Railway-hosted unclogme-pdf-service /generate/fog-manifest
// endpoint, which renders the PER-CLIENT FOG Manifest (a DERM Address showing
// only this manifest row's own client facility), uploads it to Storage, and sets
// derm_manifests.fog_manifest_url. Keeps PDF_SERVICE_API_KEY off the client.
//
// Callers: the generate-fog-manifests cron (server-side) for new manifests, and
// the DERM Tracker if it wants to regenerate on demand. Server-side callers
// bypass CORS; browser callers are origin-restricted below.
//
// Env (Supabase Functions secrets, shared with generate-derm-address-pdf):
//   PDF_SERVICE_URL, PDF_SERVICE_API_KEY
// ============================================================================

const PDF_SERVICE_URL = Deno.env.get('PDF_SERVICE_URL')
const PDF_SERVICE_API_KEY = Deno.env.get('PDF_SERVICE_API_KEY')

const ALLOWED_ORIGINS = new Set([
  'https://fp.unclogme.app',
  'https://derm.unclogme.app',
])

function corsHeadersFor(origin: string | null): Record<string, string> {
  const allowed = origin && ALLOWED_ORIGINS.has(origin) ? origin : 'https://fp.unclogme.app'
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
  if (typeof body.manifest_id !== 'number' || !Number.isInteger(body.manifest_id) || body.manifest_id <= 0) {
    return jsonResponse({ error: 'manifest_id_required_integer' }, 400, cors)
  }

  const target = `${PDF_SERVICE_URL.replace(/\/$/, '')}/generate/fog-manifest`

  let upstream: Response
  try {
    upstream = await fetch(target, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${PDF_SERVICE_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ manifest_id: body.manifest_id }),
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
