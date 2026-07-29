// ============================================================================
// get-permit-doc/index.ts — Edge Function: short-lived SIGNED URLs for GDO permits
// ============================================================================
// WHY THIS EXISTS
// The `gdo-permits` bucket originally had NO storage.objects policies at all, so
// anon could not LIST it — it behaved like `GT - Visits Images` does today.
// `2026-07-29a` added an anon SELECT policy so the Field Portal's permit link
// (which signs client-side as anon) would work again, and its header claimed
// "Net change in what anon can read: zero". That was WRONG: the policy also
// enabled the LIST endpoint, and all 164 permit filenames became enumerable with
// only the publishable key, each then fetchable with no key at all. A hash or an
// obscure path defeats GUESSING; it does nothing against LIST.
//
// This function replaces that client-side signing so the anon SELECT policy can
// be reverted. The Field Portal is the ONLY consumer that signs `gdo-permits`;
// the Visit Calendar and Client App build /object/public/ URLs, which bypass RLS
// on a public bucket and are therefore unaffected either way.
//
// Input (POST JSON):
//   { client_code: string, permit_number: string }
//   Returns { url: string, expires_in: number }
//
// AUTHORIZATION (slug-scoped — same model as get-derm-doc, deliberately):
//   the permit must belong to `client_code`'s client. The caller never names a
//   storage PATH — it names a permit NUMBER, and the path is resolved server-side
//   from public.gdos. That is the important difference from client-side signing:
//   with the anon policy, a caller could sign ANY object in the bucket, including
//   ones belonging to other clients. Here the bucket is not reachable at all
//   except through this ownership check.
//   ⚠ `client_code` is guessable (no per-client secret today), so a caller who
//   already knows a client's code can still reach that client's OWN permit —
//   same trust boundary as the Field Portal QR link itself. That is the
//   documented "slug-scope now, harden later" posture, not an oversight.
//
// Anon-callable (the Field Portal holds no secret) → the fn does its OWN
// authorization. Deploy with verify_jwt=false.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const SIGNED_TTL = 3600 // 1 hour, same as the client-side call it replaces
const BUCKET = 'gdo-permits'

// Calendar + Client App are included so they can migrate off /object/public/
// later without a second deploy; they do not use this today.
const ALLOWED_ORIGINS = new Set([
  'https://fp.unclogme.app',
  'https://calendar.unclogme.app',
  'https://clients.unclogme.app',
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

function json(body: Record<string, unknown>, status: number, cors: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
}

Deno.serve(async (req: Request): Promise<Response> => {
  const cors = corsHeadersFor(req.headers.get('origin'))
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405, cors)
  if (!SUPABASE_URL || !SERVICE_KEY) return json({ error: 'service_not_configured' }, 503, cors)

  let body: { client_code?: string; permit_number?: string }
  try { body = await req.json() } catch { return json({ error: 'invalid JSON' }, 400, cors) }

  const clientCode = (body.client_code ?? '').trim()
  const permitNumber = (body.permit_number ?? '').trim()
  if (!clientCode || !permitNumber) {
    return json({ error: 'client_code and permit_number are required' }, 400, cors)
  }

  const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } })

  // Resolve the client CASE-INSENSITIVELY: the Field Portal route slug is
  // lowercase ('168-ava') while clients.client_code is uppercase ('168-AVA').
  // get-derm-doc was briefly broken by an exact .eq() for exactly this reason.
  // ilike with no wildcards = case-insensitive equality, and client_code contains
  // no % or _ , so there is no pattern-injection surface here.
  const { data: cl } = await db
    .from('clients').select('id').ilike('client_code', clientCode).maybeSingle()
  if (!cl) return json({ error: 'forbidden' }, 403, cors)

  // AUTHORIZE + resolve the path in one step: the permit must belong to THIS
  // client. The caller never supplies a storage path.
  // ⚠ COLUMN NAMES DIFFER ACROSS THE TWO SURFACES. The Field Portal reads
  // `customer.permits`, whose column is `permit_number`; the canonical table
  // `public.gdos` calls the same value `gdo_number`. Verified they agree on all
  // 131 rows that carry a permit doc, so the caller's `permit_number` is the
  // right lookup key here — it just has a different name on this side.
  const { data: gdo } = await db
    .from('gdos')
    .select('permit_document_path')
    .eq('client_id', cl.id)
    .eq('gdo_number', permitNumber)
    .not('permit_document_path', 'is', null)
    .maybeSingle()
  if (!gdo?.permit_document_path) return json({ error: 'not found' }, 404, cors)

  // Stored value is bucket-relative ('gdo/GDO-00092.pdf'), verified across all
  // 174 rows — not a full URL. Tolerate a stray leading slash or bucket prefix.
  const raw = String(gdo.permit_document_path).replace(/^\/+/, '')
  const path = raw.startsWith(BUCKET + '/') ? raw.slice(BUCKET.length + 1) : raw

  const { data: signed, error } = await db.storage.from(BUCKET).createSignedUrl(path, SIGNED_TTL)
  if (error || !signed?.signedUrl) return json({ error: 'sign_failed' }, 502, cors)

  return json({ url: signed.signedUrl, expires_in: SIGNED_TTL }, 200, cors)
})
