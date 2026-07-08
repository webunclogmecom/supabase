// ============================================================================
// sync-jobber-visit-drift — Edge Function · "Gate #4" Calendar<->Jobber drift reconciler
// ============================================================================
// Two-way reconciler for calendar/cron-mastered visit schedules vs Jobber, for the
// silent fire-and-forget push-failure blind spot (DB date X, Jobber date Y, no trace;
// ops.v_calendar_push_health can't see it because the visit is linked + unflagged).
//
// "Calendar is master, but drivers/Diego use Jobber" (Fred, 2026-06-26). So each
// drift is classified from the AUDIT trail and handled by direction:
//   * HEAL  (DB->Jobber): our push failed -- audit proves WE set the current DB value
//     (BOTH halves: date AND start_at, tightened 2026-07-08) AND Jobber still holds the
//     exact PRE-edit value. Re-push via fn_request_jobber_push.
//   * ADOPT (Jobber->DB): we NEVER edited it (no schedule audit UPDATE) -> a driver/
//     Diego scheduled it in Jobber -> Jobber is authoritative -> pull its schedule into
//     our DB via adopt_visit_schedule_from_jobber (push-suppressed; AUDITED app_source
//     ='jobber' via the X-App-Source header so the visit's Activity history shows it).
//   * ADOPT/time_refinement (Jobber->DB, added 2026-07-08 — Yan's stale-Calendar report):
//     we DID edit it, but our last edit was DATE-BEARING and Jobber's ET clock date still
//     equals visit_date with a TIMED start -> the date intent agrees; the residual drift
//     is dispatch re-timing the stop inside Jobber AFTER our push landed -> Jobber owns
//     route times -> adopt. Guards (2-skeptic reviewed): Jobber start timed (all-day
//     re-flags never wipe an office time), jDate === visit_date (early-AM <06:00 ET
//     re-times keep surfacing — the BEFORE trigger stores the CLOCK date, Fred 2026-07-02,
//     so adopting one would silently flip visit_date +1), and the last office edit moved
//     the DATE (a pure time-only office edit with a third Jobber value keeps surfacing).
//   * SURFACE (review): anything else ambiguous -> log only, never auto-resolve.
// Adopts pass the candidate snapshot as expected values (p_enforce_expected): if the office
// dragged the visit between our snapshot and the write, the RPC refuses (adoptFail, fresh
// retry next run) instead of clobbering the newer office edit.
// Completed visits are out of scope (only `scheduled` checked; completions sync inbound).
//
// Compare is ET-floored + OVERNIGHT-AWARE: an untimed visit's visit_date is the logical
// OPERATING date; a Jobber start in the early-AM (< 06:00 ET) of the next clock day is
// the overnight (10pm-3am) execution of that operating date -> NOT drift. Timed visits
// compare to the DB start_at, not visit_date.
//
// Reconcile writes (heal + adopt) are ON by default; kill-switch env
// DRIFT_HEAL_DISABLED=1 (or header x-no-heal:1) -> detect-only. One sync_log row/run.
// Never reads net._http_response (no visit_id + ~6h TTL). Self-healing: window
// re-scanned in full every run. Auth: x-sync-key. Deployed --no-verify-jwt.
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
const MAX_RECONCILE_PER_RUN = 50
const OVERNIGHT_CUTOFF = '06:00'
const supabase = createClient(SUPABASE_URL, SERVICE_KEY)
// Adopt writes (Jobber->DB) go through this client so audit.logs.app_source='jobber'
// (per ADR 016: X-App-Source overrides) — the visit's Activity history shows "from Jobber".
const supabaseJobber = createClient(SUPABASE_URL, SERVICE_KEY, { global: { headers: { 'x-app-source': 'jobber' } } })

type Cand = { id: number; visit_date: string; start_at: string | null; end_at: string | null; jobber_gid: string }
type JV = { startAt: string; endAt: string | null }

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

function etParts(d: Date) {
  const f = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false })
  const p: Record<string, string> = {}
  for (const part of f.formatToParts(d)) p[part.type] = part.value
  return { date: `${p.year}-${p.month}-${p.day}`, time: `${p.hour}:${p.minute}:${p.second}` }
}
function addDays(dateStr: string, n: number): string {
  const d = new Date(`${dateStr}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10)
}

function isDrift(c: Cand, jobberStartAt: string): boolean {
  const jEt = etParts(new Date(jobberStartAt))
  if (!c.start_at) {
    if (jEt.date === c.visit_date) return false
    if (jEt.date === addDays(c.visit_date, 1) && jEt.time.slice(0, 5) < OVERNIGHT_CUTOFF) return false  // overnight execution of the operating date
    return true
  }
  // timed: compare Jobber startAt to the DB start_at (clock time we pushed), not visit_date
  const dbEt = etParts(new Date(c.start_at))
  return jEt.date !== dbEt.date || jEt.time.slice(0, 5) !== dbEt.time.slice(0, 5)
}

// Jobber schedule -> the DB row we should adopt. All-day (ET midnight) -> untimed +
// operating-date = that date. Timed -> keep the clock start/end; operating-date is the
// overnight-adjusted date (an early-AM start belongs to the previous operating day).
// NOTE (2026-07-08): the early-AM -1 shift below is LEGACY vs the live BEFORE trigger
// trg_aa_reconcile_operating_date Branch 3 (Fred 2026-07-02), which derives visit_date as
// the ET CLOCK date of start_at on every timed write — overriding whatever date we pass.
// The classifier's jDate === c.visit_date guard keeps early-AM re-times SURFACED, so the
// divergence is inert here; align this fn if the operating-date rule is ever revisited.
function adoptTarget(jv: JV): { visit_date: string; start_at: string | null; end_at: string | null } {
  const e = etParts(new Date(jv.startAt))
  if (e.time === '00:00:00') return { visit_date: e.date, start_at: null, end_at: null }
  const visit_date = e.time.slice(0, 5) < OVERNIGHT_CUTOFF ? addDays(e.date, -1) : e.date
  return { visit_date, start_at: jv.startAt, end_at: jv.endAt }
}

async function jobberStartAtByGid(token: string, gid: string): Promise<string | null> {
  const d = await gql(token, `{ visit(id:"${gid}"){ startAt } }`)
  return d?.visit?.startAt ?? null
}

async function runSync(reconcile: boolean): Promise<Record<string, unknown>> {
  const startedAt = new Date().toISOString(); const startMs = Date.now()
  try {
    const token = await getToken()

    const { data: candidates, error: cErr } = await supabase.rpc('calendar_visit_drift_candidates', { p_back_days: BACK_DAYS, p_fwd_days: FWD_DAYS })
    if (cErr) throw new Error(`candidates rpc: ${cErr.message}`)
    const cands = (candidates ?? []) as Cand[]
    const byGid = new Map(cands.map((c) => [c.jobber_gid, c]))

    const back = new Date(); back.setUTCHours(0, 0, 0, 0); back.setUTCDate(back.getUTCDate() - BACK_DAYS); const afterIso = back.toISOString()
    const jobberStart = new Map<string, JV>()
    let cursor: string | null = null, page = 0
    while (page++ < MAX_PAGES) {
      const after = cursor ? `, after: "${cursor}"` : ''
      const data = await gql(token, `{ visits(first: 50, filter: { startAt: { after: "${afterIso}" } }${after}) { pageInfo { hasNextPage endCursor } nodes { id startAt endAt } } }`)
      for (const n of data.visits.nodes) if (byGid.has(n.id)) jobberStart.set(n.id, { startAt: n.startAt, endAt: n.endAt ?? null })
      if (jobberStart.size >= byGid.size) break
      if (!data.visits.pageInfo.hasNextPage) break
      cursor = data.visits.pageInfo.endCursor
      await new Promise((s) => setTimeout(s, 700))
    }

    // compare (overnight-aware)
    const drifted: Cand[] = []
    let readFail = 0
    for (const c of cands) {
      const jv = jobberStart.get(c.jobber_gid)
      if (!jv) { readFail++; continue }
      if (isDrift(c, jv.startAt)) drifted.push(c)
    }

    // classify by audit: our failed push (heal) / never-edited (adopt) /
    // same-date time refinement (adopt) / ambiguous (surface)
    const healable: Cand[] = []
    const adoptable: Cand[] = []
    const refinedIds: number[] = []
    const surfaced: Array<{ id: number; jobber_date: string; reason: string; app_source: string | null }> = []
    // null-safe instant compare (audit JSONB text vs PostgREST ISO text — formats differ, compare epochs)
    const sameInstant = (a: string | null | undefined, b: string | null | undefined): boolean =>
      (a == null && b == null) || (a != null && b != null && new Date(a).getTime() === new Date(b).getTime())
    for (const c of drifted) {
      const jv = jobberStart.get(c.jobber_gid)!
      const jET = etParts(new Date(jv.startAt))
      const jDate = jET.date
      const { data: le, error: leErr } = await supabase.rpc('visit_last_schedule_edit', { p_visit_id: c.id })
      if (leErr) {
        // audit read failed — NEVER let a transient error route an office-edited visit into the
        // unguarded never-edited ADOPT branch; surface it and retry with the next run.
        surfaced.push({ id: c.id, jobber_date: jDate, reason: 'audit_read_fail', app_source: null })
        continue
      }
      const last = (Array.isArray(le) ? le[0] : le) as { old_date: string; new_date: string; old_start_at: string | null; new_start_at: string | null; app_source: string | null } | undefined
      // HEAL only when our push simply FAILED: our last (non-Jobber) edit set the current DB value AND
      // Jobber STILL holds our EXACT pre-edit schedule — date AND, for a timed pre-edit, the clock time
      // (an untimed pre-edit must still be all-day in Jobber). If Jobber holds ANY other value, a
      // driver/Diego moved it in Jobber after our push -> we must NOT silently revert it -> SURFACE.
      // (visit_last_schedule_edit excludes app_source='jobber', so an inbound Jobber start_at FILL is
      // never mistaken for our office edit — that misread is what reverted 152-DAV/6356 on 2026-07-02.)
      let jobberHoldsPreEdit = false
      if (last) {
        if (last.old_start_at) {
          const preET = etParts(new Date(last.old_start_at))
          jobberHoldsPreEdit = jET.date === preET.date && jET.time.slice(0, 5) === preET.time.slice(0, 5)
        } else {
          jobberHoldsPreEdit = jDate === last.old_date && jET.time === '00:00:00'
        }
      }
      // "our last edit set the current DB value" must hold for BOTH halves (date AND start_at).
      // Adopts are audited app_source='jobber' and invisible to visit_last_schedule_edit, so after an
      // adopt the DB start_at no longer equals last.new_start_at — HEAL must NOT re-push a mixed
      // office-date + adopted-time value over a deliberate Jobber restore (tightened 2026-07-08).
      const dbStillOurEdit = !!last && last.new_date === c.visit_date && sameInstant(last.new_start_at, c.start_at)
      if (last && dbStillOurEdit && jobberHoldsPreEdit) healable.push(c)                             // our push failed (Jobber still holds our exact pre-edit value)
      else if (!last) adoptable.push(c)                                                              // we never edited it -> Jobber authoritative
      else {
        // Same-operating-date TIME refinement -> ADOPT (Jobber owns dispatch reality). Guards:
        //  * t.start_at !== null       — a Jobber all-day re-flag never wipes an office time (surface)
        //  * t.visit_date === c.visit_date && jDate === c.visit_date — date intent agrees on the ET
        //    CLOCK date; blocks early-AM (<06:00 ET) re-times, where the BEFORE trigger's clock-date
        //    rule (Fred 2026-07-02) would silently flip visit_date +1 under a "time refinement" tag
        //  * last.old_date !== last.new_date — the office's last edit moved the DATE (e.g. a bulk
        //    day-shift); a pure time-only office edit with a third Jobber value keeps surfacing
        const t = adoptTarget(jv)
        if (t.start_at !== null && t.visit_date === c.visit_date && jDate === c.visit_date && last.old_date !== last.new_date) {
          adoptable.push(c)
          refinedIds.push(c.id)
        } else {
          surfaced.push({ id: c.id, jobber_date: jDate, reason: 'jobber_value_unexpected', app_source: last.app_source ?? null })  // ambiguous -> review, never auto-revert
        }
      }
    }

    let healed = 0, healFail = 0, adopted = 0, adoptFail = 0
    if (reconcile) {
      // HEAL DB->Jobber
      for (const d of healable.slice(0, MAX_RECONCILE_PER_RUN)) await supabase.rpc('fn_request_jobber_push', { p_visit_id: d.id, p_op: 'upsert' })
      if (healable.length) await new Promise((s) => setTimeout(s, 8000))
      for (const d of healable.slice(0, MAX_RECONCILE_PER_RUN)) {
        try { const jsa = await jobberStartAtByGid(token, d.jobber_gid); if (jsa && !isDrift(d, jsa)) healed++; else healFail++ } catch { healFail++ }
      }
      healFail += Math.max(0, healable.length - MAX_RECONCILE_PER_RUN)
      // ADOPT Jobber->DB (push-suppressed, audited app_source='jobber'). p_enforce_expected: the
      // RPC refuses if the row moved since our snapshot (office dragged it mid-run) — adoptFail,
      // fresh retry next run — instead of clobbering the newer office edit.
      for (const c of adoptable.slice(0, MAX_RECONCILE_PER_RUN)) {
        const t = adoptTarget(jobberStart.get(c.jobber_gid)!)
        try {
          const { data: ok, error } = await supabaseJobber.rpc('adopt_visit_schedule_from_jobber', {
            p_visit_id: c.id, p_visit_date: t.visit_date, p_start_at: t.start_at, p_end_at: t.end_at,
            p_expected_visit_date: c.visit_date, p_expected_start_at: c.start_at, p_enforce_expected: true,
          })
          if (!error && ok) adopted++; else adoptFail++
        } catch { adoptFail++ }
      }
      adoptFail += Math.max(0, adoptable.length - MAX_RECONCILE_PER_RUN)
    } else { healFail = healable.length; adoptFail = adoptable.length }

    const residual = healFail + adoptFail   // reconcile writes that didn't land
    const dur = Math.round((Date.now() - startMs) / 1000)
    const needsAttention = residual > 0 || surfaced.length > 0
    const status = drifted.length === 0 ? 'success' : (needsAttention ? 'attention' : 'success')
    await supabase.from('sync_log').insert({
      sync_source: 'jobber_visit_drift', started_at: startedAt, finished_at: new Date().toISOString(),
      rows_updated: healed + adopted, rows_errored: residual, duration_seconds: dur, status,
      details: {
        reconcile_enabled: reconcile, checked: cands.length, drift_found: drifted.length,
        healable: healable.length, healed, adoptable: adoptable.length, adopted,
        jobber_origin_surfaced: surfaced.length, surfaced_visits: surfaced.slice(0, 50),
        residual, read_fail: readFail,
        healable_visit_ids: healable.map((d) => d.id).slice(0, 100), adoptable_visit_ids: adoptable.map((d) => d.id).slice(0, 100),
        time_refined_visit_ids: refinedIds.slice(0, 100),
      },
    })
    return { reconcile_enabled: reconcile, checked: cands.length, drift_found: drifted.length, healable: healable.length, healed, adoptable: adoptable.length, adopted, time_refined: refinedIds.length, jobber_origin_surfaced: surfaced.length, surfaced_visits: surfaced.slice(0, 50), residual, read_fail: readFail }
  } catch (e) {
    const dur = Math.round((Date.now() - startMs) / 1000)
    await supabase.from('sync_log').insert({ sync_source: 'jobber_visit_drift', started_at: startedAt, finished_at: new Date().toISOString(), rows_updated: 0, rows_errored: 0, duration_seconds: dur, status: 'error', details: { error: String(e).slice(0, 300) } }).catch(() => {})
    return { error: String(e).slice(0, 300) }
  }
}

Deno.serve(async (req) => {
  if (TRIGGER_KEY && req.headers.get('x-sync-key') !== TRIGGER_KEY) return new Response('forbidden', { status: 403 })
  const reconcile = !HEAL_DISABLED_ENV && req.headers.get('x-no-heal') !== '1'
  if (req.headers.get('x-sync-wait') === '1') {
    const res = await runSync(reconcile)
    return new Response(JSON.stringify(res), { status: res.error ? 500 : ((res.drift_found as number) ? 207 : 200), headers: { 'Content-Type': 'application/json' } })
  }
  // @ts-ignore — EdgeRuntime is provided by the Supabase Edge runtime.
  EdgeRuntime.waitUntil(runSync(reconcile))
  return new Response(JSON.stringify({ accepted: true }), { status: 202, headers: { 'Content-Type': 'application/json' } })
})
