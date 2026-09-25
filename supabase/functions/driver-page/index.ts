// =============================================================================
// driver-page: the public driver page's one door (Page Builder, build plan section 6)
// Plan: Building Apps/docs/2026-09-25_page-builder-and-driver-page-plan.md (D1, D3, D8, D11)
// DB:   Supabase/docs/migrations/2026-09-25_1330_property_pages.sql (public.fn_driver_page)
//
// WHAT. POST {code, staff} -> the APPROVED version of one property's driver page: the facts, hours,
// notes, contacts, the frozen site map, and every photo with a ready-to-load URL. The page lives at
// https://planner.unclogme.app/driver#code=<code> (a Picture Planner route); it calls this with fetch
// and loads no Supabase code.
//
// WHY NO LOGIN. Drivers have no staff accounts (zero have an @ayache.com / @unclogme.com address), and
// the page is opened from a link in the Jobber job at any hour. The 22-character code (about 131 bits)
// IS the credential, exactly like the intake collector's token. So CORS is '*': an origin allow-list
// would protect nothing a curl cannot bypass, and the code in the body is the only thing that opens a
// page.
//
// STRUCTURAL BOUND (the only things that limit this endpoint, since anyone may call it):
//   - read-only except the open log, and fn_driver_page writes at most ONE log row per page, minute and
//     staff flag (a unique key, insert ... on conflict do nothing);
//   - an unknown code costs one indexed lookup and returns nothing;
//   - a valid code returns one page with at most 80 photos (the content validator's cap), so one call
//     makes at most 80 signing calls (intake photos only; visit photos need none);
//   - nothing is written to storage and nothing is sent anywhere.
//
// WHAT A CODE OPENS, AND WHAT STOPS IT (all decided in fn_driver_page, never here):
//   the property's highest APPROVED version only; nothing when the link was rotated, never approved,
//   the property is removed or billing-only, or the client is INACTIVE. Every one of those is the same
//   "This link is not valid.", so the endpoint never confirms which codes exist.
//   Photos are resolved from their ids with the ownership rule re-checked on every open; the bucket
//   comes from the photo's link kind, never from anything the page stored.
//
// PHOTOS.
//   - Visit photos are in the PUBLIC bucket 'GT - Visits Images': a server-built render URL, no call.
//     ⚠ So a visit photo URL keeps working after a rotation (public bucket) until the pending
//     "DERM storage private + signed" work lands. Plan D11 says so.
//   - Intake photos are in the PRIVATE bucket 'intake-photos': a signed render URL, 6 hours.
//   - Both are rendered at width 1600 (thumb 480), which also turns HEIC into something a phone shows.
//   - A photo that cannot be signed is COUNTED (sign_failures), never silently dropped.
//
// 🛑 Never log the code, never echo it in a message, never put it in a Location header.
// 🛑 The service client sends x-app-source: driver-page, so the open-log writes are attributed.
// verify_jwt = false (config.toml), same posture as intake-submit.
// =============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const db = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
  global: { headers: { 'x-app-source': 'driver-page' } },
})

const MAX_BODY_BYTES = 4_096
const SIGNED_TTL = 6 * 60 * 60
const FULL = { width: 1600, quality: 80 }
const THUMB = { width: 480, quality: 70 }
const PUBLIC_BUCKET = 'GT - Visits Images'
const PRIVATE_BUCKET = 'intake-photos'
const CODE_RE = /^[A-Za-z0-9]{22}$/

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, content-type, x-client-info, apikey, x-app-source',
  'Access-Control-Max-Age': '86400',
}
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' },
  })
const fail = (status: number, message: string) => json(status, { ok: false, message })

type PagePhoto = {
  photo_id: number
  section: string
  note?: string | null
  marks?: unknown[] | null
  rot?: number | null
  rot_now?: number | null
  bucket: string
  path: string
}

const encPath = (p: string) => p.split('/').map(encodeURIComponent).join('/')
const publicRender = (path: string, t: { width: number; quality: number }) =>
  `${SUPABASE_URL}/storage/v1/render/image/public/${encodeURIComponent(PUBLIC_BUCKET)}/${encPath(path)}?width=${t.width}&quality=${t.quality}`

async function signedRender(path: string, t: { width: number; quality: number }): Promise<string | null> {
  const { data, error } = await db.storage.from(PRIVATE_BUCKET).createSignedUrl(path, SIGNED_TTL, { transform: t })
  return error || !data?.signedUrl ? null : data.signedUrl
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return fail(405, 'Method not allowed.')

  const bytes = new Uint8Array(await req.arrayBuffer())
  if (bytes.byteLength > MAX_BODY_BYTES) return fail(413, 'That request is too large.')
  let body: Record<string, unknown>
  try {
    const parsed = JSON.parse(new TextDecoder().decode(bytes) || '{}')
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return fail(400, 'Could not read the request.')
    body = parsed as Record<string, unknown>
  } catch {
    return fail(400, 'Could not read the request.')
  }

  const code = body.code
  if (typeof code !== 'string' || !CODE_RE.test(code)) return fail(404, 'This link is not valid.')
  const staff = body.staff === true

  const { data, error } = await db.rpc('fn_driver_page', {
    p_code: code,
    p_staff: staff,
    p_user_agent: (req.headers.get('user-agent') ?? '').slice(0, 200),
  })
  // A database error must never read as "not valid": the driver would think the link is dead.
  if (error) return fail(500, 'Could not open this page, please try again.')
  if (!data) return fail(404, 'This link is not valid.')

  const page = data as Record<string, unknown>
  const photos = Array.isArray(page.photos) ? (page.photos as PagePhoto[]) : []
  let signFailures = 0
  const out = await Promise.all(photos.map(async (p) => {
    let url: string | null = null
    let thumb: string | null = null
    if (p.bucket === PUBLIC_BUCKET) {
      url = publicRender(p.path, FULL)
      thumb = publicRender(p.path, THUMB)
    } else if (p.bucket === PRIVATE_BUCKET) {
      ;[url, thumb] = await Promise.all([signedRender(p.path, FULL), signedRender(p.path, THUMB)])
      if (url && !thumb) thumb = url
    }
    if (!url) {
      signFailures++
      return null
    }
    return {
      photo_id: p.photo_id,
      section: p.section,
      note: p.note ?? null,
      marks: Array.isArray(p.marks) ? p.marks : [],
      rot: p.rot ?? 0,
      rot_now: p.rot_now ?? 0,
      url,
      thumb,
    }
  }))

  return json(200, {
    ok: true,
    property: page.property,
    version: page.version,
    approved_at: page.approved_at,
    approved_by: page.approved_by,
    content: page.content,
    photos: out.filter(Boolean),
    photos_unavailable: Number(page.photos_unavailable ?? 0),
    sign_failures: signFailures,
  })
})
