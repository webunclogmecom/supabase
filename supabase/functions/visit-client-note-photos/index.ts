// visit-client-note-photos — READ-ONLY window into Jobber's client-note photos for one visit.
//
// Fred, 2026-08-18, deciding the ClientNote policy from the August photo audit: *"for the
// client notes go with option c, show them read-only."*
//
// WHY THIS EXISTS. Clients' notes in Jobber are used as photo albums (measured: 399
// unattributed images, 23 unique in-window this August). The importer skips client notes BY
// DESIGN — they repeat on every visit of the client, so importing them is the over-attach
// class the 2026-08-14 audit closed. But reviewers (Yannick) SEE those photos in Jobber and
// read their absence in the app as data loss. Option (c): show them, never import them.
//
// 🛑 HARD RULES, all deliberate:
//  - NOTHING IS WRITTEN. No photos row, no photo_links row, no storage object. The response
//    is ephemeral. These images can never enter classification or a city email.
//  - URLS ARE NOT STORED ANYWHERE. Jobber's attachment URLs are S3-presigned and EXPIRE;
//    a stored URL is a broken image and a false "we have it". The app must fetch fresh on
//    each view.
//  - THE WINDOW MATCHES THE AUDIT: an image is shown when its attachment createdAt OR its
//    note createdAt is within ±2 days of the visit's date (noon-anchored). Albums carry
//    years-old note dates with fresh attachments, so attachment time is what usually
//    matches — this is exactly why "import them with the window rule" was a no-op and (c)
//    was chosen over it.
//  - Pinned client notes are INCLUDED (read-only display carries no attach risk; the
//    sync's pinned handling is a separate concern).
//
// Auth: staff only, same shape as send-visit-photos-email — a real signed-in user on the
// staff domains. verify_jwt=true in config.toml is half the gate; the domain check here is
// the other half.
//
// Jobber cost: one query per call, notes(first:30){fileAttachments(first:20)} ≈ ~600 points
// of the ~10,000 budget (⚠ nested page sizes MULTIPLY — see the 2026-08-18 memory: 100×100
// is the whole budget and self-throttles into silence). Reviewer traffic is dozens of views
// a day; negligible next to the sync sweeps.

import { createClient } from 'jsr:@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
const JOBBER_TOKEN_URL = 'https://api.getjobber.com/api/oauth/token'
const GQL_VERSION = '2026-04-16'
const WINDOW_MS = 2 * 86400000

const sb = createClient(SUPABASE_URL, SERVICE_KEY)

// 🛑 CORS: REFLECT the requested headers, never hand-maintain the list.
// This shipped with a fixed list of four (authorization, x-client-info, apikey,
// content-type) and the section rendered NOTHING in the app while every manual probe
// returned 200 with 7 photos. The Admin Review supabase client sets a GLOBAL
// `X-App-Source: admin-review` header (ADR 016 attribution), so the browser's preflight
// asked for a fifth header, the allow-list did not name it, and Chrome BLOCKED the POST
// before it was ever sent. Nothing reached this function: no log, no gateway row, and
// supabase-js surfaced only a generic fetch error, which the app renders as "no photos".
// A hand-written allow-list is a copy of someone else's header list that goes stale
// silently - the same class as every hand-maintained list this repo warns about.
const baseCors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Max-Age': '86400',
  'Vary': 'Origin, Access-Control-Request-Headers',
}
const corsFor = (req: Request) => ({
  ...baseCors,
  'Access-Control-Allow-Headers':
    req.headers.get('access-control-request-headers') ??
    'authorization, content-type, x-client-info, apikey, x-app-source',
})
const json = (body: unknown, status: number, headers: Record<string, string>) =>
  new Response(JSON.stringify(body), { status, headers: { ...headers, 'Content-Type': 'application/json' } })

async function getJobberToken(): Promise<string> {
  const { data: t } = await sb.from('webhook_tokens')
    .select('access_token, refresh_token, client_id, client_secret, expires_at')
    .eq('source_system', 'jobber').maybeSingle()
  if (!t) throw new Error('no jobber token row')
  if (t.access_token && t.expires_at && new Date(t.expires_at) > new Date(Date.now() + 60_000)) {
    return t.access_token
  }
  // OAuth refresh MUST be form-encoded (JSON silently fails — 2026-06-01 lesson)
  const resp = await fetch(JOBBER_TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token', refresh_token: t.refresh_token,
      client_id: t.client_id, client_secret: t.client_secret,
    }).toString(),
  })
  if (!resp.ok) throw new Error(`token refresh ${resp.status}`)
  const j = await resp.json()
  const exp = JSON.parse(atob(j.access_token.split('.')[1])).exp * 1000
  await sb.from('webhook_tokens').update({
    access_token: j.access_token, refresh_token: j.refresh_token ?? t.refresh_token,
    expires_at: new Date(exp).toISOString(), updated_at: new Date().toISOString(),
  }).eq('source_system', 'jobber')
  return j.access_token
}

Deno.serve(async (req: Request) => {
  const cors = corsFor(req)
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    console.log(`[cnp] req ua=${(req.headers.get('user-agent') ?? '').slice(0, 40)} ci=${req.headers.get('x-client-info') ?? '-'}`)
    // ---- staff auth (the SERVER check is the gate; the app hiding things is convenience) --
    const authHeader = req.headers.get('Authorization') ?? ''
    const userClient = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } })
    const { data: userData, error: uErr } = await userClient.auth.getUser()
    const email = userData?.user?.email?.toLowerCase() ?? ''
    if (uErr || !email) { console.log(`[cnp] auth_required uErr=${uErr?.message ?? '-'}`); return json({ error: 'auth_required' }, 401, cors) }
    if (!email.endsWith('@ayache.com') && !email.endsWith('@unclogme.com')) {
      return json({ error: 'staff_only' }, 403, cors)
    }

    let body: Record<string, unknown>
    try { body = await req.json() } catch { return json({ error: 'bad_json' }, 400, cors) }
    const visitId = Number(body?.visit_id)
    if (!Number.isFinite(visitId) || visitId <= 0) return json({ error: 'visit_id_required' }, 400, cors)

    const { data: v, error: vErr } = await sb.from('visits')
      .select('id, visit_date, deleted_at, job_id').eq('id', visitId).maybeSingle()
    if (vErr) throw new Error(`visit lookup: ${vErr.message}`)
    if (!v || v.deleted_at) return json({ error: 'visit_not_found' }, 404, cors)

    const { data: jl } = await sb.from('entity_source_links')
      .select('source_id').eq('entity_type', 'job').eq('entity_id', v.job_id)
      .eq('source_system', 'jobber').maybeSingle()
    if (!jl?.source_id) return json({ photos: [], note: 'visit has no jobber job link' }, 200, cors)

    // ---- one Jobber query, content-type guarded (the HTTP-200 HTML waiting room) ---------
    const tok = await getJobberToken()
    const q = `query($id: EncodedId!) { job(id: $id) { notes(first: 30) { nodes {
      __typename
      ... on ClientNote { id message createdAt fileAttachments(first: 20) {
        nodes { id fileName contentType url createdAt } pageInfo { hasNextPage } } }
    } } } }`
    const r = await fetch('https://api.getjobber.com/api/graphql', {
      method: 'POST',
      headers: { Authorization: `Bearer ${tok}`, 'X-JOBBER-GRAPHQL-VERSION': GQL_VERSION, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: q, variables: { id: jl.source_id } }),
    })
    const ctype = r.headers.get('content-type') ?? ''
    if (!ctype.includes('json')) {
      // diagnostic: the app was observed getting 503s while manual replicas got 200 (2026-08-18)
      console.log(`[cnp] non-json from Jobber: ctype=${ctype} http=${r.status} visit=${visitId}`)
      return json({ error: 'jobber_busy', detail: `Jobber returned ${ctype} at HTTP ${r.status}` }, 503, cors)
    }
    const g = await r.json()
    if (g.errors?.some((e: any) => e.extensions?.code === 'THROTTLED')) {
      console.log(`[cnp] THROTTLED visit=${visitId}`)
      return json({ error: 'jobber_busy', detail: 'throttled' }, 503, cors)
    }
    if (g.errors || !('data' in g)) return json({ error: 'jobber_error', detail: JSON.stringify(g.errors ?? {}).slice(0, 200) }, 502, cors)

    const visitMs = Date.parse(`${String(v.visit_date).slice(0, 10)}T12:00:00Z`)
    const inWindow = (iso: string | null) => {
      if (!iso) return false
      const n = Date.parse(iso)
      return Number.isFinite(n) && Math.abs(n - visitMs) <= WINDOW_MS
    }
    const photos: unknown[] = []
    let truncated = 0
    for (const n of (g.data.job?.notes?.nodes ?? [])) {
      if (n.__typename !== 'ClientNote') continue
      if (n.fileAttachments?.pageInfo?.hasNextPage) truncated += 1
      for (const f of (n.fileAttachments?.nodes ?? [])) {
        if (!String(f.contentType ?? '').startsWith('image/')) continue
        if (!inWindow(f.createdAt) && !inWindow(n.createdAt)) continue
        photos.push({
          url: f.url, file_name: f.fileName, content_type: f.contentType,
          attached_at: f.createdAt ?? null, note_created_at: n.createdAt ?? null,
          note_excerpt: String(n.message ?? '').slice(0, 200),
        })
      }
    }
    console.log(`[cnp] ok visit=${visitId} photos=${photos.length}`)
    return json({ photos, truncated_notes: truncated, urls_expire: true }, 200, cors)
  } catch (e) {
    console.error('[visit-client-note-photos]', (e as Error).message)
    return json({ error: 'internal', detail: (e as Error).message.slice(0, 200) }, 500, cors)
  }
})
