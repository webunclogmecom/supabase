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
// Auth: caller must present `x-sync-key: <SYNC_TRIGGER_KEY>`. Deployed --no-verify-jwt.
// Reads/refreshes the Jobber token from public.webhook_tokens.
// ============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const TRIGGER_KEY = Deno.env.get('SYNC_TRIGGER_KEY') ?? ''
const GRAPHQL_VERSION = '2026-04-16'
const EXCLUDED_CLIENT_GIDS = new Set(['Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ=']) // 112-YA test account
const supabase = createClient(SUPABASE_URL, SERVICE_KEY)

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

async function runSync(): Promise<Record<string, unknown>> {
  const startedAt = new Date().toISOString(); const startMs = Date.now()
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
      await new Promise((s) => setTimeout(s, 800))
    }
    const eligible = visits.filter((v) => !EXCLUDED_CLIENT_GIDS.has(v.client?.id))
    const excluded = visits.length - eligible.length

    // Replay each through webhook-jobber (VISIT_UPDATE) — handleVisit upserts + promotes/dedups.
    let ok = 0, fail = 0
    for (const v of eligible) {
      const payload = JSON.stringify({ topic: 'VISIT_UPDATE', webHookEvent: { itemId: v.id, occurredAt: new Date().toISOString() } })
      const sig = await hmacB64(clientSecret, payload)
      const wr = await fetch(`${SUPABASE_URL}/functions/v1/webhook-jobber`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-jobber-hmac-sha256': sig }, body: payload })
      if (wr.ok) ok++; else fail++
    }

    // VERIFY: every eligible upcoming visit must now be in our DB. Residual gap = real bug.
    const gids = eligible.map((v) => v.id)
    let inDb = 0; let stillMissing: string[] = []
    if (gids.length) {
      const { data: present } = await supabase.from('entity_source_links').select('source_id')
        .eq('entity_type', 'visit').eq('source_system', 'jobber').in('source_id', gids)
      const set = new Set((present ?? []).map((r: any) => r.source_id))
      inDb = set.size
      stillMissing = eligible.filter((v) => !set.has(v.id)).map((v) => v.id)
    }
    const dur = Math.round((Date.now() - startMs) / 1000)
    await supabase.from('sync_log').insert({
      sync_source: 'jobber_upcoming_visits_pgcron', started_at: startedAt, finished_at: new Date().toISOString(),
      rows_inserted: ok, rows_updated: 0, rows_errored: fail, duration_seconds: dur,
      status: (stillMissing.length === 0 && fail === 0) ? 'success' : 'partial',
      details: { pulled: visits.length, excluded_112ya: excluded, replayed_ok: ok, replayed_fail: fail, residual_gap: stillMissing.length },
    })
    return { pulled: visits.length, eligible: eligible.length, ok, fail, in_db: inDb, residual_gap: stillMissing.length }
  } catch (e) {
    const dur = Math.round((Date.now() - startMs) / 1000)
    await supabase.from('sync_log').insert({ sync_source: 'jobber_upcoming_visits_pgcron', started_at: startedAt, finished_at: new Date().toISOString(), rows_inserted: 0, rows_updated: 0, rows_errored: 0, duration_seconds: dur, status: 'error', details: { error: String(e).slice(0, 300) } }).catch(() => {})
    return { error: String(e).slice(0, 300) }
  }
}

Deno.serve(async (req) => {
  if (TRIGGER_KEY && req.headers.get('x-sync-key') !== TRIGGER_KEY) return new Response('forbidden', { status: 403 })
  if (req.headers.get('x-sync-wait') === '1') {
    const res = await runSync()
    return new Response(JSON.stringify(res), { status: res.error ? 500 : (res.residual_gap ? 207 : 200), headers: { 'Content-Type': 'application/json' } })
  }
  // Background task: complete the sync regardless of the caller's connection timeout (pg_net ~5s).
  // @ts-ignore — EdgeRuntime is provided by the Supabase Edge runtime.
  EdgeRuntime.waitUntil(runSync())
  return new Response(JSON.stringify({ accepted: true }), { status: 202, headers: { 'Content-Type': 'application/json' } })
})
