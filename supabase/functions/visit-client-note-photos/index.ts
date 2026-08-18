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

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
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
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    // ---- staff auth (the SERVER check is the gate; the app hiding things is convenience) --
    const authHeader = req.headers.get('Authorization') ?? ''
    const userClient = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } })
    const { data: userData, error: uErr } = await userClient.auth.getUser()
    const email = userData?.user?.email?.toLowerCase() ?? ''
    if (uErr || !email) return json({ error: 'auth_required' }, 401, cors)
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
    if (!ctype.includes('json')) return json({ error: 'jobber_busy', detail: `Jobber returned ${ctype} at HTTP ${r.status}` }, 503, cors)
    const g = await r.json()
    if (g.errors?.some((e: any) => e.extensions?.code === 'THROTTLED')) {
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
    return json({ photos, truncated_notes: truncated, urls_expire: true }, 200, cors)
  } catch (e) {
    console.error('[visit-client-note-photos]', (e as Error).message)
    return json({ error: 'internal', detail: (e as Error).message.slice(0, 200) }, 500, cors)
  }
})
