// ============================================================================
// sync-jobber-visit-drift — Edge Function · "Gate #4" Calendar->Jobber drift watchdog
// ============================================================================
// Detects (and, when explicitly enabled, heals) Calendar/cron visit reschedules
// whose fire-and-forget push to Jobber SILENTLY FAILED (DB says date X, Jobber
// stuck on date Y). This is the blind spot ops.v_calendar_push_health cannot see:
// a failed reschedule is already LINKED (has a Jobber GID) and the update push
// path writes no visit_sync_flags row, so only reading Jobber's actual startAt
// reveals it. Ripple cascades fire one push per shifted row, so any subset can
// fail independently — this checks every candidate in the window.
//
// SAFE-BY-DEFAULT: this function DETECTS + LOGS on every run, but only HEALS
// (re-pushes DB->Jobber) when explicitly enabled via env DRIFT_HEAL_ENABLED=1 or
// a per-call `x-heal: 1` header. Reason: a state reconcile cannot tell a failed
// OUR-push (DB right, heal it) from a deliberate JOBBER-side edit (Jobber right,
// do NOT clobber). First production scan (2026-06-26) found 3 such ambiguous
// divergences (cron visits DB=06/25 vs Jobber=06/26 — slipped visits moved in
// Jobber). Until a heal-direction policy is set (or push-intent is tracked),
// drift is surfaced to sync_log for review rather than auto-reverted.
//
// HOW (state reconcile, DB is master per the inbound clobber guard):
//   1. candidates = public.calendar_visit_drift_candidates() — calendar/cron,
//      scheduled, Jobber-linked, live visits in [today-7, today+6mo].
//   2. pull Jobber upcoming visits (startAt >= today-7), paginated, stopping once
//      every candidate GID is seen; map gid -> Jobber startAt.
//   3. compare ET-FLOORED (mirrors jobber-push-visit etParts/visitSchedule):
//      untimed -> date only; timed -> date + ET HH:MM. Jobber returns an all-day
//      startAt as ET-midnight-in-UTC (04:00Z), which floors to the visit_date, so
//      this does NOT false-positive (verified on visit 6036).
//   4. (heal only) re-push each drifted visit via rpc('fn_request_jobber_push')
//      (reuses the proven trigger path: vault key -> jobber-push-visit), then
//      RE-READ Jobber per GID to confirm convergence. Idempotent; op='upsert' on a
//      linked visit never creates/deletes. Bounded per run.
//   5. one public.sync_log row (sync_source='jobber_visit_drift').
//
// Self-healing: the window is re-scanned in full every run (level-triggered, no
// cursor). Reads net._http_response NOT AT ALL (no visit_id + ~6h TTL).
//
// Auth: caller must present `x-sync-key: <SYNC_TRIGGER_KEY>`. Deployed --no-verify-jwt.
// Reads/refreshes the Jobber READ token from public.webhook_tokens('jobber').
// ============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const TRIGGER_KEY = Deno.env.get('SYNC_TRIGGER_KEY') ?? ''
const HEAL_ENV = (Deno.env.get('DRIFT_HEAL_ENABLED') ?? '') === '1'
const GRAPHQL_VERSION = '2026-04-16'
const TZ = 'America/New_York'
const BACK_DAYS = 7
const FWD_DAYS = 184           // ~6 months, matches the SA generator horizon
const MAX_PAGES = 100          // hard cap; early-exit once all candidate GIDs are seen
const MAX_HEAL_PER_RUN = 50    // blast-radius cap; overflow counts as residual
const supabase = createClient(SUPABASE_URL, SERVICE_KEY)

type Cand = { id: number; visit_date: string; start_at: string | null; end_at: string | null; jobber_gid: string }

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

async function getToken(): Promise<string> {
  const { data: row } = await supabase.from('webhook_tokens')
    .select('access_token, refresh_token, client_id, client_secret, expires_at').eq('source_system', 'jobber').single()
  if (!row) throw new Error('No jobber row in webhook_tokens')
  let token = row.access_token as string
  if (new Date(row.expires_at).getTime() <= Date.now() + 60_000) {
    const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(row.client_id)}&client_secret=${encodeURIComponent(row.client_secret)}`
    const tr = await fetch('https://api.getjobber.com/api/oauth/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body })
    if (!tr.ok) {
      const { data: row2 } = await supabase.from('webhook_tokens').select('access_token, expires_at').eq('source_system', 'jobber').single()
      if (row2 && new Date(row2.expires_at).getTime() > Date.now() + 60_000) return row2.access_token
      throw new Error(`Refresh failed ${tr.status}`)
    }
    const t = await tr.json()
    const newExp = JSON.parse(atob(t.access_token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).exp * 1000
    await supabase.from('webhook_tokens').update({
      access_token: t.access_token, refresh_token: t.refresh_token || row.refresh_token,
      expires_at: new Date(newExp).toISOString(), updated_at: new Date().toISOString(),
    }).eq('source_system', 'jobber')
    token = t.access_token
  }
  return token
}

// UTC instant -> ET wall-clock { date, time }. Mirrors jobber-push-visit/etParts.
function etParts(d: Date) {
  const f = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false })
  const p: Record<string, string> = {}
  for (const part of f.formatToParts(d)) p[part.type] = part.value
  return { date: `${p.year}-${p.month}-${p.day}`, time: `${p.hour}:${p.minute}:${p.second}` }
}

// true if Jobber's startAt diverges from the DB schedule (ET-floored), mirroring
// exactly what visitSchedule() sends: untimed -> date only; timed -> date + HH:MM.
function isDrift(c: Cand, jobberStartAt: string): boolean {
  const jEt = etParts(new Date(jobberStartAt))
  if (!c.start_at) return jEt.date !== c.visit_date
  const dbEt = etParts(new Date(c.start_at))
  return jEt.date !== c.visit_date || jEt.time.slice(0, 5) !== dbEt.time.slice(0, 5)
}

async function jobberStartAtByGid(token: string, gid: string): Promise<string | null> {
  const d = await gql(token, `{ visit(id:"${gid}"){ startAt } }`)
  return d?.visit?.startAt ?? null
}

async function runSync(heal: boolean): Promise<Record<string, unknown>> {
  const startedAt = new Date().toISOString(); const startMs = Date.now()
  try {
    const token = await getToken()

    // 1. candidates
    const { data: candidates, error: cErr } = await supabase.rpc('calendar_visit_drift_candidates', { p_back_days: BACK_DAYS, p_fwd_days: FWD_DAYS })
    if (cErr) throw new Error(`candidates rpc: ${cErr.message}`)
    const cands = (candidates ?? []) as Cand[]
    const byGid = new Map(cands.map((c) => [c.jobber_gid, c]))

    // 2. pull Jobber upcoming startAt (>= today-7), paginate until all candidate GIDs seen
    const back = new Date(); back.setUTCHours(0, 0, 0, 0); back.setUTCDate(back.getUTCDate() - BACK_DAYS); const afterIso = back.toISOString()
    const jobberStart = new Map<string, string>()
    let cursor: string | null = null, page = 0
    while (page++ < MAX_PAGES) {
      const after = cursor ? `, after: "${cursor}"` : ''
      const data = await gql(token, `{ visits(first: 50, filter: { startAt: { after: "${afterIso}" } }${after}) { pageInfo { hasNextPage endCursor } nodes { id startAt } } }`)
      for (const n of data.visits.nodes) if (byGid.has(n.id)) jobberStart.set(n.id, n.startAt)
      if (jobberStart.size >= byGid.size) break
      if (!data.visits.pageInfo.hasNextPage) break
      cursor = data.visits.pageInfo.endCursor
      await new Promise((s) => setTimeout(s, 700))
    }

    // 3. compare
    const drifted: Cand[] = []
    let readFail = 0
    for (const c of cands) {
      const jsa = jobberStart.get(c.jobber_gid)
      if (!jsa) { readFail++; continue }   // absent from Jobber (deleted/beyond horizon) — orphan path, not this gate
      if (isDrift(c, jsa)) drifted.push(c)
    }

    // 4. heal (only when explicitly enabled): re-push via the proven primitive, then re-verify
    let healed = 0, residual = 0, healAttempted = 0
    if (heal && drifted.length) {
      const toHeal = drifted.slice(0, MAX_HEAL_PER_RUN)
      healAttempted = toHeal.length
      for (const d of toHeal) await supabase.rpc('fn_request_jobber_push', { p_visit_id: d.id, p_op: 'upsert' })
      await new Promise((s) => setTimeout(s, 8000))   // let the fire-and-forget pushes land
      for (const d of toHeal) {
        try {
          const jsa = await jobberStartAtByGid(token, d.jobber_gid)
          if (jsa && !isDrift(d, jsa)) healed++; else residual++
        } catch { residual++ }
      }
      residual += Math.max(0, drifted.length - toHeal.length)   // overflow beyond the cap
    }

    // 5. one sync_log row. read_fail is informational (orphan path), does NOT degrade status.
    const dur = Math.round((Date.now() - startMs) / 1000)
    const status = drifted.length === 0
      ? 'success'
      : (heal ? (residual === 0 ? 'success' : 'partial') : 'attention')   // attention = drift detected, heal disabled
    await supabase.from('sync_log').insert({
      sync_source: 'jobber_visit_drift', started_at: startedAt, finished_at: new Date().toISOString(),
      rows_updated: healed, rows_errored: residual, duration_seconds: dur, status,
      details: {
        heal_enabled: heal, checked: cands.length, drift_found: drifted.length,
        heal_attempted: healAttempted, drift_healed: healed, residual_drift: residual, read_fail: readFail,
        drifted_visit_ids: drifted.map((d) => d.id).slice(0, 100),
      },
    })
    return { heal_enabled: heal, checked: cands.length, drift_found: drifted.length, drift_healed: healed, residual_drift: residual, read_fail: readFail, drifted_visit_ids: drifted.map((d) => d.id).slice(0, 100) }
  } catch (e) {
    const dur = Math.round((Date.now() - startMs) / 1000)
    await supabase.from('sync_log').insert({ sync_source: 'jobber_visit_drift', started_at: startedAt, finished_at: new Date().toISOString(), rows_updated: 0, rows_errored: 0, duration_seconds: dur, status: 'error', details: { error: String(e).slice(0, 300) } }).catch(() => {})
    return { error: String(e).slice(0, 300) }
  }
}

Deno.serve(async (req) => {
  if (TRIGGER_KEY && req.headers.get('x-sync-key') !== TRIGGER_KEY) return new Response('forbidden', { status: 403 })
  const heal = HEAL_ENV || req.headers.get('x-heal') === '1'   // safe-by-default: detect+log unless explicitly enabled
  if (req.headers.get('x-sync-wait') === '1') {
    const res = await runSync(heal)
    return new Response(JSON.stringify(res), { status: res.error ? 500 : ((res.drift_found as number) ? 207 : 200), headers: { 'Content-Type': 'application/json' } })
  }
  // @ts-ignore — EdgeRuntime is provided by the Supabase Edge runtime.
  EdgeRuntime.waitUntil(runSync(heal))
  return new Response(JSON.stringify({ accepted: true }), { status: 202, headers: { 'Content-Type': 'application/json' } })
})
