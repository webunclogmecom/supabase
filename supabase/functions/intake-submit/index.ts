// ============================================================================
// intake-submit — the collector side of the Client Intake System
// Section 4 of Building Apps/docs/2026-09-23_client-intake-build-plan.md
// ============================================================================
// WHAT. The one endpoint the person on site talks to. Four operations ride a single
// POST, all authorised by the intake TOKEN and nothing else. A GET is reserved for
// sending the collector to the form; see the GET branch for why it cannot BE the form:
//
//   GET ?t=<token>                                     -> 503 today, a 302 once the form has a host
//
//   load    { token }                                  -> the questions to show
//   upload  { token, content_type }                    -> a short-lived signed upload URL
//   attach  { token, path, role, caption }             -> links an uploaded photo to the intake
//   submit  { token, collector, answers }              -> writes the immutable submission
//
// WHY NO LOGIN. Fred's decision 6, 2026-09-22: "No need to log in, but bear in mind
// the security of it, simple security is enough." Measured reason it has to be this
// way: of the four ACTIVE field staff, ZERO hold an @ayache.com or @unclogme.com
// address, which is the domain gate every staff app enforces, and Grecia (the
// collector named in the flow, already the assignee on 40 of 75 calendar tasks) has
// no email on file at all. The estate precedent is DUMP Schedule, live on shared
// driver phones with no auth by design.
//
// 🛑 THE REASON-PHOTOS GATES DO NOT TRANSFER, AND THIS IS THE REPLACEMENT.
//    2026-09-16_2030_client_reason_photos.sql gates uploads three ways and every one
//    is keyed on a signed-in staff identity: the storage policy is `to authenticated`,
//    fn_reason_photo_path_ok opens with `if auth.uid() is null then return false`, and
//    the attach RPC compares storage owner_id to the caller. An anonymous collector
//    has none of those. So the gates here are TOKEN-DERIVED instead:
//      1. the storage folder is the INTAKE ID the token resolves to, so one intake cannot
//         write into another intake's folder. 🛑 It is the id and NEVER the token itself:
//         photos.storage_path is readable by every staff session (public.photos carries
//         three authenticated SELECT policies with qual true, and client.photos is an
//         unfiltered view), so a token in the path is a live token published to staff.
//         Found by the 2026-09-23 adversarial review of the viewer migration; 0 photos
//         had been stored under the old token-named scheme, so nothing needed moving,
//      2. the number of photo slots per intake is capped (PHOTO_CAP),
//      3. the signed upload URL is short-lived,
//      4. the token itself expires (property_intakes.expires_at) and dies on submit.
//
// STRUCTURAL CEILINGS, stated here the way dump-visit-create states its own
// (that one carries ROUTES_DAILY_CAP = 500; this file's equivalents are below).
// They are the only thing standing between an unauthenticated endpoint and an
// unbounded write, so change them deliberately:
//   MAX_BODY_BYTES 262144   PHOTO_CAP 40        MAX_ANSWER_KEYS 200
//   MAX_VALUE_CHARS 4000    MAX_COLLECTOR 120   SIGNED_UPLOAD_TTL 900s
//
// CORS IS `*` ON PURPOSE, and that is not laziness. The authorisation here is the
// bearer token in the body; there is no cookie and no ambient credential, so an
// origin allow-list would protect nothing a token holder could not already do from
// curl. Same posture and same threat model as dump-visit-create. The collector form
// has no domain yet; pinning becomes worth doing when it has one AND something
// ambient exists to protect.
//
// verify_jwt = false in config.toml, deliberately: the caller is anonymous by design.
//
// ⚠ MEASURED 2026-09-22, and it is the consequence of that line: this endpoint answers
//   200 with NO apikey header at all. It is fully public. The token is therefore the
//   ONLY gate, which is what makes the ceilings above load-bearing rather than tidy.
//   Verified end to end the same day, 21 of 21 cases: an unknown token 404s, a
//   malformed one 400s, an expired one 410s, an oversized body 413s, a photo path
//   outside the intake's own folder 400s (the folder was the token until 2026-09-23 and
//   is the intake id since; see point 1 above), a second submit 409s and does NOT overwrite
//   the first, and an upload after submit 409s.
// ============================================================================

import { supabase } from '../_shared/supabase-client.ts'
// form-page.ts is NOT imported: the gateway cannot serve it (see the GET branch).
// It stays in the repo as the finished form, ready to port to a real web origin.

const MAX_BODY_BYTES = 262_144
const PHOTO_CAP = 40
const MAX_ANSWER_KEYS = 200
const MAX_VALUE_CHARS = 4_000
const MAX_COLLECTOR = 120
const SIGNED_UPLOAD_TTL = 900
const BUCKET = 'intake-photos'
const ALLOWED_MIME = new Set(['image/jpeg', 'image/png', 'image/webp', 'image/heic'])

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, content-type, x-client-info, apikey, x-app-source',
  'Access-Control-Max-Age': '86400',
}
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const fail = (status: number, message: string, extra: Record<string, unknown> = {}) =>
  json(status, { ok: false, message, ...extra })

type Intake = {
  id: number
  property_id: number
  form_snapshot: Record<string, unknown>
  requested: string[]
  expires_at: string
  submitted_at: string | null
  cancelled_at: string | null
}

/** Resolve the token to a usable intake, or return the reason it is not usable. */
async function resolveToken(token: unknown): Promise<{ intake?: Intake; error?: Response }> {
  if (typeof token !== 'string' || token.length < 8 || token.length > 64 || !/^[A-Za-z0-9_-]+$/.test(token)) {
    return { error: fail(400, 'This link is not valid.') }
  }
  const { data, error } = await supabase
    .from('property_intakes')
    .select('id, property_id, form_snapshot, requested, expires_at, submitted_at, cancelled_at')
    .eq('token', token)
    .maybeSingle()

  if (error) return { error: fail(500, 'Could not open this form, please try again.') }
  // Same message for "no such token" and "cancelled": do not let the endpoint confirm
  // which tokens exist.
  if (!data || data.cancelled_at) return { error: fail(404, 'This link is no longer active.') }
  if (new Date(data.expires_at).getTime() < Date.now()) {
    return { error: fail(410, 'This link has expired. Ask the office for a new one.') }
  }
  return { intake: data as Intake }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })

  // ------------------------------------------------------------------ GET
  // 🛑 AN EDGE FUNCTION CANNOT SERVE THE FORM. MEASURED 2026-09-23, DO NOT RETRY IT.
  //    Serving form-page.ts from here was the plan, and it does not work: the Supabase
  //    edge gateway REWRITES an HTML response to `content-type: text/plain` and stamps
  //    `content-security-policy: default-src 'none'; sandbox` on it. `sandbox` with no
  //    `allow-scripts` kills the inline script, so even the rendered page would be
  //    inert. Confirmed in a browser: it displays the raw source as text.
  //    This is NOT a header this function can override, and it is an anti-abuse control
  //    on the platform, so it should not be worked around. JSON from this same function
  //    is untouched (`application/json`), which is how we know it is HTML-specific.
  //
  //    ⇒ THE FORM MUST LIVE ON A REAL WEB ORIGIN. When it does, this GET becomes a 302
  //      to `<form host>/?t=<token>` rather than a page. Keeping the redirect HERE is
  //      deliberate: every link the office has already handed out stays valid, and a
  //      change of form host is then one deploy instead of a reissue of every token.
  //      `form-page.ts` holds the finished form and is the thing to port to that host.
  if (req.method === 'GET') {
    return new Response(
      'This form is not ready yet. Please ask the office for the new link.',
      { status: 503, headers: { ...cors, 'Content-Type': 'text/plain; charset=utf-8', 'Referrer-Policy': 'no-referrer' } },
    )
  }

  if (req.method !== 'POST') return fail(405, 'Method not allowed.')

  const raw = await req.text()
  if (raw.length > MAX_BODY_BYTES) {
    return fail(413, 'That is too much data to send at once. Submit fewer answers or smaller notes.')
  }

  let body: Record<string, unknown>
  try {
    body = JSON.parse(raw || '{}')
  } catch {
    return fail(400, 'Could not read the request.')
  }

  const op = String(body.op ?? 'load')
  const { intake, error } = await resolveToken(body.token)
  if (error) return error
  const i = intake!

  // ---------------------------------------------------------------- load
  if (op === 'load') {
    const { data: prop } = await supabase
      .from('properties')
      .select('name, address, city, client_id')
      .eq('id', i.property_id)
      .maybeSingle()

    return json(200, {
      ok: true,
      intake_id: i.id,
      already_submitted: i.submitted_at !== null,
      submitted_at: i.submitted_at,
      expires_at: i.expires_at,
      requested: i.requested,
      form: i.form_snapshot,
      property: prop ? { name: prop.name, address: prop.address, city: prop.city } : null,
      photo_cap: PHOTO_CAP,
    })
  }

  if (i.submitted_at) {
    return fail(409, 'This form has already been submitted. Ask the office if something needs changing.')
  }

  // -------------------------------------------------------------- upload
  if (op === 'upload') {
    const contentType = String(body.content_type ?? 'image/jpeg')
    if (!ALLOWED_MIME.has(contentType)) return fail(400, 'That file type is not supported. Use a photo.')

    const { count, error: cErr } = await supabase
      .from('photo_links')
      .select('id', { count: 'exact', head: true })
      .eq('entity_type', 'property_intake')
      .eq('entity_id', i.id)
      .is('deleted_at', null)
    if (cErr) return fail(500, 'Could not prepare the upload, please try again.')
    if ((count ?? 0) >= PHOTO_CAP) {
      return fail(429, `That is the maximum of ${PHOTO_CAP} photos for this visit.`)
    }

    // The folder is the INTAKE the token resolved to (i.id), never the token: see the
    // header, point 1. The server builds the path, so the collector cannot choose it,
    // and attach re-checks the exact shape below.
    const ext = contentType === 'image/png' ? 'png' : contentType === 'image/webp' ? 'webp'
      : contentType === 'image/heic' ? 'heic' : 'jpg'
    const path = `${i.id}/${crypto.randomUUID()}.${ext}`

    const { data: signed, error: sErr } = await supabase.storage
      .from(BUCKET)
      .createSignedUploadUrl(path, { upsert: false })
    if (sErr || !signed) return fail(500, 'Could not prepare the upload, please try again.')

    return json(200, { ok: true, path, token: signed.token, signed_url: signed.signedUrl, expires_in: SIGNED_UPLOAD_TTL })
  }

  // -------------------------------------------------------------- attach
  if (op === 'attach') {
    const path = String(body.path ?? '')
    const role = String(body.role ?? '').slice(0, 120)
    const caption = body.caption == null ? null : String(body.caption).slice(0, MAX_VALUE_CHARS)

    // Re-derive rather than trust: the path must be EXACTLY the shape upload issues for
    // THIS intake. A startsWith check alone would accept `5/../6/x.jpg` or junk.
    const PATH_RE = new RegExp(`^${i.id}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.(jpg|png|webp|heic)$`)
    if (!PATH_RE.test(path)) return fail(400, 'That photo does not belong to this form.')
    if (!role) return fail(400, 'A photo needs to say which question it belongs to.')

    const { data: photo, error: pErr } = await supabase
      .from('photos')
      .insert({ storage_path: `${BUCKET}/${path}`, source: 'intake_upload', content_type: String(body.content_type ?? 'image/jpeg') })
      .select('id')
      .single()
    if (pErr || !photo) return fail(500, 'Could not save the photo, please try again.')

    // entity_type is 'property_intake', never 'property'. See the section 2 migration:
    // customer.client_access_photos publishes 'property' rows to an anon-reachable portal.
    const { error: lErr } = await supabase
      .from('photo_links')
      .insert({ photo_id: photo.id, entity_type: 'property_intake', entity_id: i.id, role, caption })
    if (lErr) return fail(500, 'Could not attach the photo, please try again.')

    return json(200, { ok: true, photo_id: photo.id })
  }

  // -------------------------------------------------------------- submit
  if (op === 'submit') {
    const collector = String(body.collector ?? '').trim().slice(0, MAX_COLLECTOR)
    if (!collector) return fail(400, 'Put your name so the office knows who collected this.')

    const rawAnswers = body.answers
    if (rawAnswers === null || typeof rawAnswers !== 'object' || Array.isArray(rawAnswers)) {
      return fail(400, 'Could not read the answers.')
    }
    const entries = Object.entries(rawAnswers as Record<string, unknown>)
    if (entries.length > MAX_ANSWER_KEYS) return fail(413, 'Too many answers in one submission.')

    // Normalise to the { value: ... } shape public.fn_intake_answered expects. A bare
    // scalar from the form is wrapped rather than rejected, so the predicate that the
    // whole status column rests on can never see a shape it was not written for.
    const answers: Record<string, unknown> = {}
    for (const [k, v] of entries) {
      if (typeof k !== 'string' || k.length > 120) return fail(400, 'One of the answers has a bad name.')
      const wrapped = (v !== null && typeof v === 'object' && !Array.isArray(v) && 'value' in (v as object))
        ? v as Record<string, unknown>
        : { value: v }
      const val = wrapped.value
      if (typeof val === 'string' && val.length > MAX_VALUE_CHARS) {
        return fail(413, 'One of the notes is too long.')
      }
      answers[k] = wrapped
    }

    // Atomic compare-and-set: only the first submit wins. `.is('submitted_at', null)`
    // is the whole guard, so two taps on a bad signal cannot produce two submissions.
    const { data: updated, error: uErr } = await supabase
      .from('property_intakes')
      .update({ answers, collector, submitted_at: new Date().toISOString() })
      .eq('id', i.id)
      .is('submitted_at', null)
      .select('id, submitted_at')

    if (uErr) return fail(500, 'Could not save the form, please try again.')
    if (!updated || updated.length === 0) {
      return fail(409, 'This form has already been submitted.')
    }

    const missing = (i.requested ?? []).filter((k) => {
      const a = answers[k] as Record<string, unknown> | undefined
      if (!a || !('value' in a)) return true
      const v = a.value
      if (v === null || v === undefined) return true
      if (typeof v === 'string') return v.trim() === ''
      if (Array.isArray(v)) return v.length === 0
      if (typeof v === 'object') return Object.keys(v as object).length === 0
      return false
    })

    return json(200, {
      ok: true,
      intake_id: i.id,
      submitted_at: updated[0].submitted_at,
      // Mirrors client.v_property_intake so the form can say the same thing the office
      // will see. The VIEW remains the source of truth for the status column.
      status: missing.length === 0 ? 'Complete' : 'Incomplete',
      missing_keys: missing,
    })
  }

  return fail(400, 'Unknown operation.')
})
