// ============================================================================
// get-derm-doc/index.ts — Edge Function: short-lived SIGNED URLs for DERM docs
// ============================================================================
// Replaces the public-bucket URLs the apps embed today, so the `GT - Visits Images`
// + `manifests` buckets can go PRIVATE (closes the enumerable-path leak: the raw
// DERM Address sheet rosters every co-client on a shared dump ticket).
//
// Input (POST JSON):
//   { manifest_id: number, client_code: string, kind: 'fog' | 'address' | 'manifest' }
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
const KINDS = new Set(['fog', 'address', 'manifest'])

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
  for (const b of ['manifests', 'GT - Visits Images']) {
    if (raw.startsWith(b + '/')) return { bucket: b, path: raw.slice(b.length + 1).split('?')[0] }
  }
  return null
}

Deno.serve(async (req: Request): Promise<Response> => {
  const cors = corsHeadersFor(req.headers.get('origin'))
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405, cors)

  let body: { manifest_id?: number; client_code?: string; kind?: string }
  try { body = await req.json() } catch { return json({ error: 'invalid JSON' }, 400, cors) }
  const manifest_id = Number(body.manifest_id)
  const client_code = (body.client_code ?? '').trim()
  const kind = body.kind ?? ''
  if (!Number.isInteger(manifest_id) || manifest_id <= 0 || !client_code || !KINDS.has(kind)) {
    return json({ error: 'manifest_id (positive int), client_code, and kind (fog|address|manifest) are required' }, 400, cors)
  }

  const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } })

  // resolve the client slug
  const { data: cl } = await db.from('clients').select('id').eq('client_code', client_code).maybeSingle()
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
