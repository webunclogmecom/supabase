// ============================================================================
// sync-jobber-visit-drift — Edge Function · "Gate #4" Calendar->Jobber drift watchdog
// ============================================================================
// Detects + (safely) heals Calendar/cron visit reschedules whose fire-and-forget
// push to Jobber SILENTLY FAILED (DB says date X, Jobber stuck on date Y). This is
// the blind spot ops.v_calendar_push_health can't see: a failed reschedule is
// already LINKED (has a GID) and the update push path writes no visit_sync_flags
// row, so only reading Jobber's actual startAt reveals it.
//
// "Calendar is master, but drivers/Diego use Jobber" (Fred, 2026-06-26). So the
// heal is DIRECTION-SAFE: it re-pushes DB->Jobber ONLY when the audit trail proves
// it was OUR push that failed -- i.e. a visit_date-changing audit UPDATE set the
// CURRENT DB date AND Jobber still holds the exact PRE-edit value. Any other Jobber
// value (a deliberate Jobber-side move / time assignment by a driver or Diego)
// does NOT match and is SURFACED for review, never reverted.
//
// HOW:
//   1. candidates = public.calendar_visit_drift_candidates() — calendar/cron,
//      scheduled, Jobber-linked, live visits in [today-7, today+6mo].
//   2. pull Jobber upcoming visits (startAt >= today-7), paginated; map gid->startAt.
//   3. compare ET-floored, OVERNIGHT-AWARE: an untimed visit's visit_date is the
//      logical OPERATING date; a Jobber start in the early-AM (< 06:00 ET) of the
//      NEXT clock day is the overnight execution of that operating date (commercial
//      trucks run 10pm-3am) -> NOT drift. (Without this, every overnight visit
//      false-flags.) Timed visit -> compare date + ET HH:MM.
//   4. classify each drift via public.visit_last_schedule_edit (audit): OUR failed
//      push (Jobber==pre-edit value) -> healable; else -> surfaced (jobber-origin).
//   5. heal healable via rpc('fn_request_jobber_push') + re-read to confirm; bounded.
//      Kill-switch: env DRIFT_HEAL_DISABLED=1 (or header x-no-heal:1) -> detect-only.
//   6. one public.sync_log row (sync_source='jobber_visit_drift').
//
// Self-healing: window re-scanned in full every run (no cursor). Never reads
// net._http_response (no visit_id + ~6h TTL).
//
// Auth: caller must present `x-sync-key: <SYNC_TRIGGER_KEY>`. Deployed --no-verify-jwt.
// Reads/refreshes the Jobber READ token from public.webhook_tokens('jobber').
// ============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const TRIGGER_KEY = Deno.env.get('SYNC_TRIGGER_KEY') ?? ''
const HEAL_DISABLED_ENV = (Deno.env.get('DRIFT_HEAL_DISABLED') ?? '') === '1'
const GRAPHQL_VERSION = '2026-04-16'
const TZ = 'America/New_York'
const BACK_DAYS = 7
const FWD_DAYS = 184
const MAX_PAGES = 100
const MAX_HEAL_PER_RUN = 50
const OVERNIGHT_CUTOFF = '06:00'   // a Jobber start before this on visit_date+1 = overnight execution of visit_date
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
function addDays(dateStr: string, n: number): string {
  const d = new Date(`${dateStr}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10)
}

// true if Jobber's startAt diverges from the DB schedule. Untimed -> operating-date
// compare with an overnight allowance; timed -> date + ET HH:MM.
function isDrift(c: Cand, jobberStartAt: string): boolean {
  const jEt = etParts(new Date(jobberStartAt))
  if (!c.start_at) {
    if (jEt.date === c.visit_date) return false
    if (jEt.date === addDays(c.visit_date, 1) && jEt.time.slice(0, 5) < OVERNIGHT_CUTOFF) return false  // overnight execution of the operating date
    return true
  }
  // timed visit: Jobber's startAt must match the DB start_at (the clock time we
  // pushed) -- compare to dbEt, NOT visit_date (the operating-date label), so a
  // correctly-stored timed OVERNIGHT visit (start_at on visit_date+1 early-AM) is
  // not false-flagged.
  const dbEt = etParts(new Date(c.start_at))
  return jEt.date !== dbEt.date || jEt.time.slice(0, 5) !== dbEt.time.slice(0, 5)
}

async function jobberStartAtByGid(token: string, gid: string): Promise<string | null> {
  const d = await gql(token, `{ visit(id:"${gid}"){ startAt } }`)
  return d?.visit?.startAt ?? null
}

async function runSync(healEnabled: boolean): Promise<Record<string, unknown>> {
  const startedAt = new Date().toISOString(); const startMs = Date.now()
  try {
    const token = await getToken()

    // 1. candidates
    const { data: candidates, error: cErr } = await supabase.rpc('calendar_visit_drift_candidates', { p_back_days: BACK_DAYS, p_fwd_days: FWD_DAYS })
    if (cErr) throw new Error(`candidates rpc: ${cErr.message}`)
    const cands = (candidates ?? []) as Cand[]
    const byGid = new Map(cands.map((c) => [c.jobber_gid, c]))

    // 2. pull Jobber upcoming startAt (>= today-7)
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

    // 3. compare (overnight-aware)
    const drifted: Cand[] = []
    let readFail = 0
    for (const c of cands) {
      const jsa = jobberStart.get(c.jobber_gid)
      if (!jsa) { readFail++; continue }
      if (isDrift(c, jsa)) drifted.push(c)
    }

    // 4. classify: OUR failed push (healable) vs Jobber-origin (surface only)
    const healable: Cand[] = []
    const surfaced: Array<{ id: number; jobber_date: string; reason: string; app_source: string | null }> = []
    for (const c of drifted) {
      const jDate = etParts(new Date(jobberStart.get(c.jobber_gid)!)).date
      const { data: le } = await supabase.rpc('visit_last_schedule_edit', { p_visit_id: c.id })
      const last = (Array.isArray(le) ? le[0] : le) as { old_date: string; new_date: string; app_source: string | null } | undefined
      const ourFailedPush = !!last && last.new_date === c.visit_date && last.old_date === jDate   // we set current; Jobber holds pre-edit value
      if (ourFailedPush) healable.push(c)
      else surfaced.push({ id: c.id, jobber_date: jDate, reason: last ? 'jobber_value_unexpected' : 'no_our_edit', app_source: last?.app_source ?? null })
    }

    // 5. heal only the healable class (provable failed-our-push) when enabled
    let healed = 0, residual = 0
    if (healEnabled && healable.length) {
      const toHeal = healable.slice(0, MAX_HEAL_PER_RUN)
      for (const d of toHeal) await supabase.rpc('fn_request_jobber_push', { p_visit_id: d.id, p_op: 'upsert' })
      await new Promise((s) => setTimeout(s, 8000))
      for (const d of toHeal) {
        try { const jsa = await jobberStartAtByGid(token, d.jobber_gid); if (jsa && !isDrift(d, jsa)) healed++; else residual++ } catch { residual++ }
      }
      residual += Math.max(0, healable.length - toHeal.length)
    } else {
      residual = healable.length   // not healed (kill-switch on)
    }

    // 6. log. attention = anything still needing eyes (unhealed failed-push OR jobber-origin drift).
    const dur = Math.round((Date.now() - startMs) / 1000)
    const needsAttention = residual > 0 || surfaced.length > 0
    const status = drifted.length === 0 ? 'success' : (needsAttention ? 'attention' : 'success')
    await supabase.from('sync_log').insert({
      sync_source: 'jobber_visit_drift', started_at: startedAt, finished_at: new Date().toISOString(),
      rows_updated: healed, rows_errored: residual, duration_seconds: dur, status,
      details: {
        heal_enabled: healEnabled, checked: cands.length, drift_found: drifted.length,
        healable: healable.length, drift_healed: healed, residual_drift: residual,
        jobber_origin: surfaced.length, jobber_origin_visits: surfaced.slice(0, 50),
        read_fail: readFail, healable_visit_ids: healable.map((d) => d.id).slice(0, 100),
      },
    })
    return { heal_enabled: healEnabled, checked: cands.length, drift_found: drifted.length, healable: healable.length, drift_healed: healed, residual_drift: residual, jobber_origin: surfaced.length, jobber_origin_visits: surfaced.slice(0, 50), read_fail: readFail }
  } catch (e) {
    const dur = Math.round((Date.now() - startMs) / 1000)
    await supabase.from('sync_log').insert({ sync_source: 'jobber_visit_drift', started_at: startedAt, finished_at: new Date().toISOString(), rows_updated: 0, rows_errored: 0, duration_seconds: dur, status: 'error', details: { error: String(e).slice(0, 300) } }).catch(() => {})
    return { error: String(e).slice(0, 300) }
  }
}

Deno.serve(async (req) => {
  if (TRIGGER_KEY && req.headers.get('x-sync-key') !== TRIGGER_KEY) return new Response('forbidden', { status: 403 })
  const healEnabled = !HEAL_DISABLED_ENV && req.headers.get('x-no-heal') !== '1'   // heal the safe class by default; kill-switch via env or header
  if (req.headers.get('x-sync-wait') === '1') {
    const res = await runSync(healEnabled)
    return new Response(JSON.stringify(res), { status: res.error ? 500 : ((res.drift_found as number) ? 207 : 200), headers: { 'Content-Type': 'application/json' } })
  }
  // @ts-ignore — EdgeRuntime is provided by the Supabase Edge runtime.
  EdgeRuntime.waitUntil(runSync(healEnabled))
  return new Response(JSON.stringify({ accepted: true }), { status: 202, headers: { 'Content-Type': 'application/json' } })
})
