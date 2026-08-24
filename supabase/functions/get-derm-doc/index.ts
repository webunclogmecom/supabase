// ============================================================================
// get-derm-doc/index.ts — Edge Function: short-lived SIGNED URLs for DERM docs
// ============================================================================
// Replaces the public-bucket URLs the apps embed today, so the `GT - Visits Images`
// + `manifests` buckets can go PRIVATE (closes the enumerable-path leak: the raw
// DERM Address sheet rosters every co-client on a shared dump ticket).
//
// Input (POST JSON):
//   { manifest_id: number, client_code: string, kind: 'fog'|'address'|'manifest'|'gdo_report',
//     gdo_id?: number }   // gdo_id: OPTIONAL, gdo_report only, narrows to ONE permit
//     - fog      → fog_manifest_url            (per-client REDACTED FOG — Field Portal)
//     - address  → address sheet(s), UNIONED across the manifest's client rows (DERM Tracker)
//     - manifest → WWTP receipt / manifest page(s), UNIONED across the rows
//   Returns { urls: string[] } — the union for address/manifest matches what the apps render.
//
// AUTHORIZATION (slug-scoped — Fred 2026-07-01 "slug-scope now, harden later"):
//   the manifest must belong to `client_code`'s client — either the row's own client_id or a
//   linked visit's client_id (covers cross-client Move links). This stops the blind manifest_id
//   enumeration the public bucket allowed. NOTE: `client_code` is guessable (no per-client UUID
//   today), so a caller who already knows a client's code can still reach that client's own docs
//   — same trust as the QR. The "harden later" step is a real per-client token / app auth.
//
// Anon-callable (frontends hold no secret) → the fn does its OWN authorization.
// Deploy: verify_jwt=false; origin-restricted to fp.unclogme.app + derm.unclogme.app.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const SIGNED_TTL = 3600 // 1 hour

const ALLOWED_ORIGINS = new Set(['https://fp.unclogme.app', 'https://derm.unclogme.app'])
// 'gdo_report' (2026-08-02) — the Miami-Dade GDO filing confirmation screenshot for the Field
// Portal's "Online Report" section. Manifest-keyed like the others, so it reuses the entitlement
// check below unchanged; no validation was loosened to add it.
const KINDS = new Set(['fog', 'address', 'manifest', 'gdo_report'])

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

function json(body: Record<string, unknown>, status: number, cors: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
}

// Stored value → { bucket, path }. Handles a full public/sign URL (today's contract) OR a
// raw "bucket/path" (the future pdf-service paths contract). Returns null if unrecognized.
function toBucketPath(v: unknown): { bucket: string; path: string } | null {
  if (typeof v !== 'string' || !v) return null
  const m = v.match(/\/storage\/v1\/object\/(?:public|sign)\/([^/]+)\/(.+)$/)
  if (m) return { bucket: decodeURIComponent(m[1]), path: decodeURIComponent(m[2].split('?')[0]) }
  const raw = v.replace(/^\/+/, '')
  for (const b of ['manifests', 'GT - Visits Images', 'rpa-evidence']) {
    if (raw.startsWith(b + '/')) return { bucket: b, path: raw.slice(b.length + 1).split('?')[0] }
  }
  return null
}

Deno.serve(async (req: Request): Promise<Response> => {
  const cors = corsHeadersFor(req.headers.get('origin'))
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405, cors)

  let body: { manifest_id?: number; client_code?: string; kind?: string; gdo_id?: number }
  try { body = await req.json() } catch { return json({ error: 'invalid JSON' }, 400, cors) }
  const manifest_id = Number(body.manifest_id)
  const client_code = (body.client_code ?? '').trim()
  const kind = body.kind ?? ''
  // OPTIONAL, and only meaningful for kind='gdo_report' (2026-08-24). A visit can hold filings for
  // SEVERAL permits; without this the query below returns whichever submission on the manifest was
  // newest, which is the wrong permit on any multi-GDO client. Omitted = previous behaviour, so
  // every existing caller is unaffected.
  const gdo_id = body.gdo_id == null ? null : Number(body.gdo_id)
  if (gdo_id !== null && !Number.isInteger(gdo_id)) {
    return json({ error: 'gdo_id must be an integer when provided' }, 400, cors)
  }
  if (!Number.isInteger(manifest_id) || manifest_id <= 0 || !client_code || !KINDS.has(kind)) {
    return json({ error: 'manifest_id (positive int), client_code, and kind (fog|address|manifest|gdo_report) are required' }, 400, cors)
  }

  const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } })

  // ── kind='address' REQUIRES A REAL SIGNED-IN CALLER ──────────────────────
  // WHY: `address` returns the RAW DERM Address sheet, which rosters EVERY
  // co-client on a shared dump ticket (business name + street address, up to 19
  // per sheet). The Field Portal's blackout pipeline exists precisely to hide
  // that from a customer — but until 2026-07-29 this endpoint handed the
  // UNREDACTED sheet to anyone, with NO apikey, from ANY origin. Verified:
  //     POST {manifest_id, client_code, kind:'address'}  (no key, evil origin)
  //       -> 200 + signed URL -> 288,553 bytes of the raw sheet
  // The only gate was `client_code`, which is printed on invoices and manifests
  // and is therefore not a secret. So knowing one client code exposed that
  // client's whole co-tenancy graph. Privatising the storage buckets does NOT
  // fix this: the function signs as service_role and reaches the object anyway.
  //
  // ⚠ SCOPED TO 'address' ONLY, AND THAT NARROWNESS IS THE POINT.
  //   fog      — the per-client REDACTED sheet. Field Portal, anon BY DESIGN.
  //   manifest — the WWTP receipt card. ALSO Field Portal, anon BY DESIGN.
  // An earlier analysis recommended gating `address` AND `manifest`; that would
  // have taken the WWTP Disposal Receipt card offline for every customer.
  // DERM Tracker (the only `address` consumer) is staff-authenticated, so it is
  // unaffected — its client carries the session, confirmed header-level
  // (`role: authenticated`, `is_anonymous: false`).
  //
  // Accepts a real user JWT, or service_role for server-side callers. The anon
  // publishable key is rejected in both its JWT and its newer opaque form,
  // because neither resolves to a user and neither carries role=service_role.
  if (kind === 'address') {
    const authz = req.headers.get('Authorization') ?? ''
    const token = authz.startsWith('Bearer ') ? authz.slice(7).trim() : ''
    let allowed = false

    if (token) {
      const { data } = await db.auth.getUser(token)
      if (data?.user) allowed = true
      if (!allowed) {
        // service_role presents a valid JWT with no `sub`, so getUser() returns
        // nothing — check the role claim directly rather than rejecting it.
        try {
          const payload = JSON.parse(atob(token.split('.')[1] ?? ''))
          if (payload?.role === 'service_role') allowed = true
        } catch { /* not a JWT (opaque publishable key) → stays denied */ }
      }
    }

    if (!allowed) {
      // Explicit and loud: a staff app that loses its session must fail
      // diagnosably, not render an empty gallery that looks like "no documents".
      return json({
        error: 'authentication_required',
        detail: "kind='address' returns the raw multi-client DERM sheet and requires a signed-in staff session",
      }, 401, cors)
    }
  }

  // Resolve the client slug — CASE-INSENSITIVE (2026-07-27). The FP route slug is lowercase
  // ('150-kos') while clients.client_code is uppercase ('150-KOS'), so the old exact `.eq()`
  // returned 403 on every call; the sibling RPC customer.get_visit_by_slug_and_token already
  // does `lower(c.client_code) = lower(p_slug)`, so this fn was the inconsistent one. Found by
  // the Building Apps session during the FP signed-URL re-wire (they shipped an uppercase
  // workaround frontend-side; this makes it unnecessary and both cases keep working).
  // ilike with no wildcards = case-insensitive equality; client_code has no % or _ .
  const { data: cl } = await db.from('clients').select('id').ilike('client_code', client_code).maybeSingle()
  if (!cl) return json({ error: 'forbidden' }, 403, cors)

  // Read via the derm.manifests VIEW so address/manifest carry the UNION of sheets across the
  // manifest's client rows (the view unions them + filters soft-deletes). fog is per-client → raw.
  const { data: v } = await db.schema('derm').from('manifests')
    .select('client_id, address_photo_url, address_photo_extra_urls, manifest_photo_url, manifest_photo_extra_urls')
    .eq('id', manifest_id).maybeSingle()
  if (!v) return json({ error: 'not found' }, 404, cors)

  // AUTHORIZE: manifest's own client, or a linked (non-deleted) visit's client
  let entitled = v.client_id === cl.id
  if (!entitled) {
    const { data: links } = await db.from('manifest_visits').select('visit_id').eq('manifest_id', manifest_id)
    const visitIds = (links ?? []).map((r: { visit_id: number }) => r.visit_id)
    if (visitIds.length) {
      const { data: hit } = await db.from('visits').select('id').in('id', visitIds).eq('client_id', cl.id).is('deleted_at', null).limit(1)
      entitled = !!(hit && hit.length)
    }
  }
  if (!entitled) return json({ error: 'forbidden' }, 403, cors)

  // gather the kind's stored value(s)
  let values: unknown[]
  if (kind === 'address') values = [v.address_photo_url, ...(Array.isArray(v.address_photo_extra_urls) ? v.address_photo_extra_urls : [])]
  else if (kind === 'manifest') values = [v.manifest_photo_url, ...(Array.isArray(v.manifest_photo_extra_urls) ? v.manifest_photo_extra_urls : [])]
  else if (kind === 'gdo_report') {
    // 🛑 LIVE SUCCESS ONLY — this filter is a SECURITY control, not a tidiness one.
    // `rpa-evidence` holds two kinds of screenshot and they are NOT equally safe (verified by
    // opening one of each, 2026-08-02):
    //   LIVE  `<visit>/<run_id>.jpg` -> the county's bare "Report Submitted" page. No client data.
    //   DRY   `<visit>/dryrun.jpg`   -> the full Preview FORM: facility name, address, phone, our
    //                                   transporter # and company details.
    // A dry-run image served here would leak ANOTHER facility's details to a customer. Also note
    // dry-run paths are a FIXED filename per visit, so they are trivially guessable — the filter is
    // the only thing standing between a caller and one. Never relax to `status <> 'ERROR%'`.
    // ⚠ PER PERMIT when gdo_id is supplied. The manifest_id filter alone returns the newest
    //   submission on the manifest regardless of which GDO it belongs to, so a customer with two
    //   permits saw one permit's screenshot under both. Narrowing by gdo_id is additive: it can only
    //   ever return a SUBSET of what the un-narrowed query returned, so it cannot widen access.
    let subQ = db.from('derm_portal_submissions')
      .select('screenshot_path')
      .eq('manifest_id', manifest_id)
      .eq('dry_run', false)
      .eq('status', 'SUCCESS')
      .not('screenshot_path', 'is', null)
    if (gdo_id !== null) subQ = subQ.eq('gdo_id', gdo_id)
    const { data: sub } = await subQ
      .order('created_at', { ascending: false })
      .limit(1).maybeSingle()
    // Prefix the bucket so toBucketPath resolves it; the column stores a bare object path.
    values = sub?.screenshot_path ? [`rpa-evidence/${sub.screenshot_path}`] : []
  }
  else { // fog — per-client redacted FOG, from the raw table (the view doesn't expose it)
    const { data: raw } = await db.from('derm_manifests').select('fog_manifest_url').eq('id', manifest_id).is('deleted_at', null).maybeSingle()
    values = raw ? [raw.fog_manifest_url] : []
  }

  // sign each (de-dup by bucket+path); skip anything unrecognized
  const seen = new Set<string>()
  const urls: string[] = []
  for (const val of values) {
    const bp = toBucketPath(val)
    if (!bp) continue
    const key = bp.bucket + ' ' + bp.path
    if (seen.has(key)) continue
    seen.add(key)
    const { data: signed, error } = await db.storage.from(bp.bucket).createSignedUrl(bp.path, SIGNED_TTL)
    if (!error && signed?.signedUrl) urls.push(signed.signedUrl)
  }

  return json({ urls, expires_in: SIGNED_TTL }, 200, cors)
})
