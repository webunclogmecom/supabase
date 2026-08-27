// ============================================================================
// rotate-photo/index.ts — Edge Function
// ============================================================================
// Thin proxy from Admin Review's photo preview modal to the Railway-hosted
// unclogme-pdf-service, which does the actual pixel rotation. Keeps
// PDF_SERVICE_API_KEY off the client.
//
//   browser  POST /functions/v1/rotate-photo
//            { photo_id, rotation_deg, expected_storage_path }
//     -> this function (staff gate, adds the service bearer, stamps the actor)
//     -> Railway  POST /images/rotate  (rotates pixels, uploads, CAS-updates the row)
//     -> response bubbles straight back
//
// Env (Supabase Functions secrets, never in the repo):
//   PDF_SERVICE_URL, PDF_SERVICE_API_KEY
//
// 🛑 WHY THE ROTATION IS NOT DONE HERE. Deno was the obvious home for this and it
// is the wrong one twice over. ImageScript, this estate's precedent for image
// editing, SCRAMBLES non-square images on .rotate(90) and .rotate(270): measured
// on 1.3.1 at 810x1080, 81.4% of bytes differ after four rotations that must be
// an identity, while the dimensions come back CORRECT so a shape check passes.
// (Upstream issue 29, open since 2023. redact-manifest-sheet has never hit it
// because it only ever rotates 180, which is a plain reverse.) And edge functions
// cap at 256MB while 21.6% of the corpus is 12MP or larger, where a decoded frame
// alone is ~190MB. Do not "simplify" this by moving the rotation in-process.
//
// ⚠ THE ORIGINAL FILE IS NEVER OVERWRITTEN. The service writes the rotated image
// to a new path and the DB repoints at it. Storage keeps one version per object,
// PITR does not cover storage, and 3,514 photos (29.2%) have no upstream to
// re-fetch from, so an in-place overwrite would be permanent.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0'

const PDF_SERVICE_URL = Deno.env.get('PDF_SERVICE_URL')
const PDF_SERVICE_API_KEY = Deno.env.get('PDF_SERVICE_API_KEY')

const db = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  { auth: { persistSession: false } },
)

const ALLOWED_ORIGINS = new Set([
  'https://admin.unclogme.app',
  'https://grease-buddy-dash.lovable.app',   // the project's default host, still served
])

function cors(origin: string | null): Record<string, string> {
  const allowed = origin && ALLOWED_ORIGINS.has(origin) ? origin : 'https://admin.unclogme.app'
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, content-type, x-client-info, apikey, x-app-source',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  }
}

const json = (body: Record<string, unknown>, status: number, h: Record<string, string>) =>
  new Response(JSON.stringify(body), { status, headers: { ...h, 'Content-Type': 'application/json' } })

Deno.serve(async (req: Request) => {
  const h = cors(req.headers.get('origin'))

  // ⚠ Answer the preflight BEFORE any auth work. A browser sends OPTIONS without
  // credentials, so gating it produces a CORS failure that reads as "the function
  // is down" rather than "you are not signed in".
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h })
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405, h)

  if (!PDF_SERVICE_URL || !PDF_SERVICE_API_KEY) {
    console.error('rotate-photo: PDF_SERVICE_URL / PDF_SERVICE_API_KEY not configured')
    return json({ error: 'service_not_configured' }, 503, h)
  }

  // ---- staff gate ----------------------------------------------------------
  // 🛑 STRICTER THAN THE GATEWAY ON PURPOSE. `verify_jwt = true` only proves the
  // token is validly signed, and the PUBLIC ANON KEY is itself a validly signed
  // JWT, so it passes the gateway on its own. This function writes to compliance
  // evidence, so it resolves the actual user and requires a staff domain.
  const m = (req.headers.get('authorization') ?? '').match(/^Bearer (.+)$/)
  if (!m) return json({ error: 'forbidden', detail: 'Staff account required.' }, 403, h)
  const { data: userData, error: userErr } = await db.auth.getUser(m[1])
  const email = String(userData?.user?.email ?? '').toLowerCase()
  if (userErr || !userData?.user?.id ||
      (!email.endsWith('@ayache.com') && !email.endsWith('@unclogme.com'))) {
    return json({ error: 'forbidden', detail: 'Staff account required.' }, 403, h)
  }

  const body = await req.json().catch(() => null)
  if (!body || typeof body !== 'object') return json({ error: 'invalid_body' }, 400, h)

  const photoId = Number(body.photo_id)
  const rotation = Number(body.rotation_deg)
  const expected = typeof body.expected_storage_path === 'string' ? body.expected_storage_path : ''

  if (!Number.isInteger(photoId) || photoId <= 0) return json({ error: 'photo_id_required_integer' }, 400, h)
  // ⚠ The angle is ABSOLUTE, not a delta. The client coalesces rapid clicks and sends
  // the final angle once, so a dropped or duplicated request can never leave a photo
  // at an angle nobody chose. Validate it here too rather than trusting the caller.
  if (![0, 90, 180, 270].includes(rotation)) return json({ error: 'rotation_deg_must_be_0_90_180_270' }, 400, h)
  if (!expected) return json({ error: 'expected_storage_path_required' }, 400, h)

  let upstream: Response
  try {
    upstream = await fetch(`${PDF_SERVICE_URL.replace(/\/+$/, '')}/images/rotate`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${PDF_SERVICE_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        photo_id: photoId,
        rotation_deg: rotation,
        expected_storage_path: expected,
        // The human, resolved here from their own token. The service never sees it,
        // so a caller cannot claim to be someone else.
        rotated_by: userData.user.id,
      }),
    })
  } catch (err) {
    console.error('rotate-photo: could not reach the pdf service:', String(err))
    return json({ error: 'rotate_service_unreachable' }, 502, h)
  }

  const text = await upstream.text()
  let payload: Record<string, unknown>
  try {
    payload = JSON.parse(text)
  } catch {
    // ⚠ A non-JSON body from upstream means an error PAGE, not a result. Returning it
    // verbatim would hand the app something it would read as success.
    console.error('rotate-photo: upstream returned non-JSON at HTTP', upstream.status, text.slice(0, 200))
    return json({ error: 'rotate_service_bad_response', status: upstream.status }, 502, h)
  }

  if (!upstream.ok) {
    console.error('rotate-photo: upstream HTTP', upstream.status, text.slice(0, 300))
  } else {
    console.log('rotate-photo:', email, 'set photo', photoId, 'to', rotation,
      (payload as { superseded?: boolean }).superseded ? '(superseded)' : '')
  }
  return json(payload, upstream.status, h)
})
