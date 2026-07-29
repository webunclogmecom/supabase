// ============================================================================
// sync-jobber-upcoming-visits — Edge Function (Supabase-native upcoming-visit poll)
// ============================================================================
// Pulls Jobber's materialized upcoming (startAt >= today) visits and replays each
// through webhook-jobber's handleVisit (upsert + promote/dedup), then VERIFIES every
// eligible visit is now in our DB. Deno port of scripts/sync/cron_jobber_upcoming_visits.js.
//
// WHY this exists: GitHub Actions throttles frequent (*/15) schedules unreliably. This
// function is driven by pg_cron (every 15 min) via pg_net — a cadence that runs INSIDE
// the database, immune to GitHub's scheduler. Jobber sends us no real-time webhook (our
// whole integration is poll-and-replay), so this poll cadence is what determines how fast
// a new Jobber visit reaches our DB.
//
// The sync runs as a background task (EdgeRuntime.waitUntil) so it always completes even
// though pg_net's default timeout closes the connection after ~5s — the caller gets an
// immediate 202 and the result is written to public.sync_log. Pass `x-sync-wait: 1` to run
// synchronously and get the result back in the response (used for manual testing).
//
// Auth (CHANGED 2026-07-29): caller must present `Authorization: Bearer <service_role JWT>`,
// FAIL-CLOSED. Deployed WITH verify_jwt=true (pinned in supabase/config.toml) — the gateway verifies
// the signature and this handler additionally requires role=service_role, because bearerRole only
// DECODES the token and the PUBLIC anon key would otherwise satisfy the gateway on its own. Same
// model as jobber-push-visit. Caller is public.fn_request_jobber_sync('upcoming') via pg_cron.
// ⚠ The old `x-sync-key: <SYNC_TRIGGER_KEY>` shared secret is RETIRED. Its gate was
// `if (TRIGGER_KEY && ...)`, which skipped auth entirely whenever SYNC_TRIGGER_KEY was empty, on a
// verify_jwt=false function. Do not reintroduce that idiom. A manual run now needs the bearer, e.g.
//   curl -H "Authorization: Bearer $SERVICE_ROLE" -H 'x-sync-wait: 1' <url>
// Reads/refreshes the Jobber token from public.webhook_tokens.
// ============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const GRAPHQL_VERSION = '2026-04-16'
const EXCLUDED_CLIENT_GIDS = new Set<string>([]) // none (112-YA un-excluded 2026-06-24 per Fred; its leftover recurring job is archived). Re-add a GID to exclude a future test account.
const supabase = createClient(SUPABASE_URL, SERVICE_KEY)

// Decode-only. The GATEWAY verifies the signature (verify_jwt=true in config.toml); this just reads
// the role claim so the public anon key cannot invoke the function. Identical to jobber-push-visit.
function bearerRole(req: Request): string | null {
  const m = (req.headers.get('authorization') || '').match(/^Bearer (.+)$/)
  if (!m) return null
  try { return JSON.parse(atob(m[1].split('.')[1])).role ?? null } catch { return null }
}

async function gql(token: string, query: string) {
  const r = await fetch('https://api.getjobber.com/api/graphql', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': GRAPHQL_VERSION },
    body: JSON.stringify({ query }),
  })
  const j = await r.json()
  if (j.errors?.length) throw new Error(`GraphQL: ${JSON.stringify(j.errors[0]).slice(0, 200)}`)
  return j.data
}

async function getCreds(): Promise<{ token: string; clientSecret: string }> {
  const { data: row } = await supabase.from('webhook_tokens')
    .select('access_token, refresh_token, client_id, client_secret, expires_at').eq('source_system', 'jobber').single()
  if (!row) throw new Error('No jobber row in webhook_tokens')
  let token = row.access_token as string
  if (new Date(row.expires_at).getTime() <= Date.now() + 60_000) {
    const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(row.client_id)}&client_secret=${encodeURIComponent(row.client_secret)}`
    const tr = await fetch('https://api.getjobber.com/api/oauth/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body })
    if (!tr.ok) {
      const { data: row2 } = await supabase.from('webhook_tokens').select('access_token, expires_at').eq('source_system', 'jobber').single()
      if (row2 && new Date(row2.expires_at).getTime() > Date.now() + 60_000) return { token: row2.access_token, clientSecret: row.client_secret }
      throw new Error(`Refresh failed ${tr.status}`)
    }
    const t = await tr.json()
    const payloadB64 = t.access_token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')
    const newExp = JSON.parse(atob(payloadB64)).exp * 1000
    await supabase.from('webhook_tokens').update({
      access_token: t.access_token, refresh_token: t.refresh_token || row.refresh_token,
      expires_at: new Date(newExp).toISOString(), updated_at: new Date().toISOString(),
    }).eq('source_system', 'jobber')
    token = t.access_token
  }
  return { token, clientSecret: row.client_secret }
}

async function hmacB64(secret: string, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(payload))
  return btoa(String.fromCharCode(...new Uint8Array(sig)))
}

// ---------------------------------------------------------------------------
// REWORK 2026-07-03 (round-B smoke finding): the old runSync replayed EVERY eligible
// visit sequentially (241+ after the Jun-24 SA backfill) with 800ms page sleeps and
// wrote sync_log only at the END — the isolate was killed mid-run every time, so the
// job was silently dead for 9 days while pg_cron reported "succeeded" (202-accepted).
// Now: (1) HEARTBEAT — the sync_log row is inserted FIRST (status='started') and
// updated at the end, so isolate death leaves a visible stalled 'started' row;
// (2) BOUNDED work — replay all MISSING visits first (cap 50) plus a ROTATING refresh
// slice (25/run, cursor carried in details.next_offset), small concurrency (4), and a
// 90s time budget. Full refresh sweep ≈ every 2-3 hours at */15; missing visits are
// caught on the next run. (3) page sleep 800ms -> 150ms (5-6 pages, leaky-bucket safe).
// ---------------------------------------------------------------------------
const MISSING_CAP = 50, REFRESH_PER_RUN = 25, CONCURRENCY = 4, TIME_BUDGET_MS = 90_000

async function replayOne(clientSecret: string, gid: string): Promise<boolean> {
  const payload = JSON.stringify({ topic: 'VISIT_UPDATE', webHookEvent: { itemId: gid, occurredAt: new Date().toISOString() } })
  const sig = await hmacB64(clientSecret, payload)
  const wr = await fetch(`${SUPABASE_URL}/functions/v1/webhook-jobber`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-jobber-hmac-sha256': sig }, body: payload })
  return wr.ok
}

async function runSync(): Promise<Record<string, unknown>> {
  const startedAt = new Date().toISOString(); const startMs = Date.now()
  // HEARTBEAT first — a run that dies leaves a visible 'started' row instead of silence.
  let hbId: number | null = null
  try {
    const { data: hb } = await supabase.from('sync_log').insert({
      sync_source: 'jobber_upcoming_visits_pgcron', started_at: startedAt,
      rows_inserted: 0, rows_updated: 0, rows_errored: 0, status: 'started', details: { phase: 'pull' },
    }).select('id').single()
    hbId = (hb as any)?.id ?? null
  } catch (_e) { /* heartbeat failure must not block the sync */ }
  const done = async (patch: Record<string, unknown>) => {
    const row = { finished_at: new Date().toISOString(), duration_seconds: Math.round((Date.now() - startMs) / 1000), ...patch }
    try {
      if (hbId != null) await supabase.from('sync_log').update(row).eq('id', hbId)
      else await supabase.from('sync_log').insert({ sync_source: 'jobber_upcoming_visits_pgcron', started_at: startedAt, rows_inserted: 0, rows_updated: 0, rows_errored: 0, ...row })
    } catch (_e) { /* logged best-effort */ }
  }
  try {
    const { token, clientSecret } = await getCreds()
    const today = new Date(); today.setUTCHours(0, 0, 0, 0); const afterIso = today.toISOString()

    // Pull all materialized upcoming Jobber visits (startAt >= today), paginated.
    let visits: any[] = [], cursor: string | null = null, page = 0
    while (page++ < 40) {
      const after = cursor ? `, after: "${cursor}"` : ''
      const data = await gql(token, `{ visits(first: 50, filter: { startAt: { after: "${afterIso}" } }${after}) { pageInfo { hasNextPage endCursor } nodes { id title client { id } } } }`)
      visits.push(...data.visits.nodes)
      if (!data.visits.pageInfo.hasNextPage) break
      cursor = data.visits.pageInfo.endCursor
      await new Promise((s) => setTimeout(s, 150))
    }
    const eligible = visits.filter((v) => !EXCLUDED_CLIENT_GIDS.has(v.client?.id))
    const excluded = visits.length - eligible.length

    // Rotation cursor from the most recent run that recorded one.
    let offset = 0
    try {
      const { data: prev } = await supabase.from('sync_log').select('details')
        .eq('sync_source', 'jobber_upcoming_visits_pgcron').not('details->next_offset', 'is', null)
        .order('started_at', { ascending: false }).limit(1)
      offset = Number((prev?.[0] as any)?.details?.next_offset ?? 0) || 0
    } catch (_e) { offset = 0 }

    // Verify FIRST: replay everything missing from our DB, then a rotating refresh slice.
    const gids = eligible.map((v) => v.id)
    const set = new Set<string>()
    for (let i = 0; i < gids.length; i += 200) {
      const { data: present } = await supabase.from('entity_source_links').select('source_id')
        .eq('entity_type', 'visit').eq('source_system', 'jobber').in('source_id', gids.slice(i, i + 200))
      for (const r of (present ?? []) as any[]) set.add(r.source_id)
    }
    const missing = eligible.filter((v) => !set.has(v.id))
    const linked = eligible.filter((v) => set.has(v.id))
    const slice: any[] = []
    if (linked.length) {
      const o = offset % linked.length
      slice.push(...linked.slice(o, o + REFRESH_PER_RUN))
      if (slice.length < REFRESH_PER_RUN && linked.length > REFRESH_PER_RUN) slice.push(...linked.slice(0, REFRESH_PER_RUN - slice.length))
    }
    const work = [...missing.slice(0, MISSING_CAP), ...slice]

    let ok = 0, fail = 0, budgetHit = false
    for (let i = 0; i < work.length; i += CONCURRENCY) {
      if (Date.now() - startMs > TIME_BUDGET_MS) { budgetHit = true; break }
      const res = await Promise.all(work.slice(i, i + CONCURRENCY).map((v) => replayOne(clientSecret, v.id).catch(() => false)))
      for (const r of res) { if (r) ok++; else fail++ }
    }
    const nextOffset = linked.length ? (offset + REFRESH_PER_RUN) % linked.length : 0

    // Residual check on the missing set only (cheap): still-absent after replay = real gap.
    let residual = 0
    const missCapGids = missing.slice(0, MISSING_CAP).map((v) => v.id)
    if (missCapGids.length) {
      const { data: present2 } = await supabase.from('entity_source_links').select('source_id')
        .eq('entity_type', 'visit').eq('source_system', 'jobber').in('source_id', missCapGids)
      const set2 = new Set((present2 ?? []).map((r: any) => r.source_id))
      residual = missCapGids.filter((g) => !set2.has(g)).length
    }
    await done({
      rows_inserted: ok, rows_errored: fail,
      status: (fail === 0 && residual === 0 && !budgetHit) ? 'success' : 'partial',
      details: {
        pulled: visits.length, eligible: eligible.length, excluded_112ya: excluded,
        missing: missing.length, replayed: work.length, replayed_ok: ok, replayed_fail: fail,
        residual_gap: residual, next_offset: nextOffset, budget_hit: budgetHit,
      },
    })
    return { pulled: visits.length, eligible: eligible.length, missing: missing.length, replayed: work.length, ok, fail, residual_gap: residual, next_offset: nextOffset, budget_hit: budgetHit }
  } catch (e) {
    await done({ status: 'error', details: { error: String(e).slice(0, 300) } })
    return { error: String(e).slice(0, 300) }
  }
}

Deno.serve(async (req) => {
  // FAIL-CLOSED: no bearer, unparseable bearer, or any role other than service_role is rejected.
  if (bearerRole(req) !== 'service_role') return new Response('forbidden', { status: 403 })
  if (req.headers.get('x-sync-wait') === '1') {
    const res = await runSync()
    return new Response(JSON.stringify(res), { status: res.error ? 500 : (res.residual_gap ? 207 : 200), headers: { 'Content-Type': 'application/json' } })
  }
  // Background task: complete the sync regardless of the caller's connection timeout (pg_net ~5s).
  // @ts-ignore — EdgeRuntime is provided by the Supabase Edge runtime.
  EdgeRuntime.waitUntil(runSync())
  return new Response(JSON.stringify({ accepted: true }), { status: 202, headers: { 'Content-Type': 'application/json' } })
})
