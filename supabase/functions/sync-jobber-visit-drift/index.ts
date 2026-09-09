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
//
// 🛑 SHADOW MODE SINCE 2026-09-09: every SURFACE decision now also gets a last-writer-wins verdict
// computed against the observation ledger (migration 2026-09-09_1420) and logged to
// sync_log.details.lww_shadow + .lww_shadow_tally. IT ACTS ON NOTHING. Fred's policy is two-way
// LWW with the Calendar winning a tie; the reason it is not live yet is that the promotion gate
// requires a witnessed Jobber TRANSITION per visit, and the ledger only began recording on
// 2026-09-09. Until then every verdict reads `no_clock`, which is correct: one observation is not
// an interval. See lwwVerdict() below for the decision table and for why the push ACK is what makes
// the rule correct rather than inverted.
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
// re-scanned in full every run.
// Auth (CHANGED 2026-07-29): `Authorization: Bearer <service_role JWT>`, FAIL-CLOSED. Deployed WITH
// verify_jwt=true (pinned in supabase/config.toml) — the gateway verifies the signature and this
// handler additionally requires role=service_role, because bearerRole only DECODES the token and the
// PUBLIC anon key would otherwise satisfy the gateway on its own. Same model as jobber-push-visit.
// Caller is public.fn_request_jobber_sync('drift') via pg_cron.
// ⚠ The old `x-sync-key: <SYNC_TRIGGER_KEY>` shared secret is RETIRED. This function is the one
// config.toml named for the FAIL-OPEN idiom: `if (TRIGGER_KEY && ...)` skipped auth entirely whenever
// SYNC_TRIGGER_KEY was empty, on a verify_jwt=false function. Do not reintroduce it. A manual run now
// needs the bearer, e.g.
//   curl -H "Authorization: Bearer $SERVICE_ROLE" -H 'x-sync-wait: 1' -H 'x-no-heal: 1' <url>
// ============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
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

// Decode-only. The GATEWAY verifies the signature (verify_jwt=true in config.toml); this just reads
// the role claim so the public anon key cannot invoke the function. Identical to jobber-push-visit.
function bearerRole(req: Request): string | null {
  const m = (req.headers.get('authorization') || '').match(/^Bearer (.+)$/)
  if (!m) return null
  try { return JSON.parse(atob(m[1].split('.')[1])).role ?? null } catch { return null }
}

type Cand = { id: number; visit_date: string; start_at: string | null; end_at: string | null; jobber_gid: string }
// `at` is the instant WE witnessed this value, stamped per PAGE as that page's response lands.
// It becomes `hi` in the observation ledger, so it must be the read time and not the run's start:
// the paging loop sleeps 700ms between pages and can span tens of seconds, and a single run-level
// timestamp would smear every page's witness onto one instant.
type JV = { startAt: string; endAt: string | null; at: string }

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
// operating-date = that date. Timed -> keep the clock start/end + visit_date = the ET
// CLOCK date of start_at.
// ALIGNED 2026-07-09 with the live BEFORE trigger trg_aa_reconcile_operating_date Branch 3
// (Fred 2026-07-02: visit_date = the ET clock date, the operating-night shift was REMOVED).
// The old early-AM -1 shift here diverged from the trigger, so the time_refinement guard
// (t.visit_date === c.visit_date) could never match an early-AM (<06:00 ET) re-time and the
// reconciler SURFACED it forever instead of adopting — the 6708 case found in the 3-month
// DB↔Jobber audit. Clock date makes early-AM re-times adopt like any other.
// ================================================================================================
// LAST-WRITER-WINS, SHADOW MODE (2026-09-09). Computes a verdict and ACTS ON NOTHING.
// ================================================================================================
// Fred's policy, verbatim: "Jobber is not authoritative, the Calendar App + Jobber, is a two-way
// partnership, where who ever gets the latest change wins... if i changed a visit at Jobber at
// 9:30AM but at the calendar i made a change at 9:31AM then Jobber adopts Calendar, same thing vice
// versa", and on a tie: "the Calendar Wins, so you need to push the Calendar on Jobber."
//
// 🛑 JOBBER GIVES AN INTERVAL, NOT AN INSTANT. Its GraphQL Visit type has NO updatedAt (31 fields,
//    includeDeprecated:true, verified live 2026-09-09), so Jobber's change time is OBSERVED, and an
//    observation only proves Jobber changed somewhere in (lo, hi]. Our edit T is a known instant:
//        T <= lo       -> Jobber strictly newer  -> adopt
//        T >  hi       -> we strictly newer      -> push  (our push almost certainly never landed)
//        lo < T <= hi  -> undecidable            -> push  (Fred's tie-break)
//    Comparing T against `hi` alone would hand Fred's OWN example to Jobber: the */30 poll would not
//    witness the 09:30 Jobber edit until 10:00, and 10:00 looks newer than a 09:31 Calendar edit.
//
// 🛑 THE PUSH ACK IS WHAT MAKES `lo` SHARP, AND WITHOUT IT THIS RULE IS NOT WEAKER, IT IS INVERTED.
//    Backtested against the 30 visits behind all 1,078 jobber_time_differs appearances in 45 days:
//      poll-only ledger  -> PUSH 30 of 30, wrong on all 27 that were ever resolved
//      with the push ACK -> ADOPT 30 of 30, right on 27 of 27
//    (oracle: the value that actually stuck was Jobber's in 19 and ours in 0.)
//    So if the ACK writer in jobber-push-visit is ever removed or bypassed, this rule must be
//    switched off, not left running on a poll-only ledger.
//
// 🛑 T COMES FROM visit_last_office_schedule_edit, NOT visit_last_schedule_edit. The latter excludes
//    only app_source='jobber' and therefore reads four Jobber-ADOPTION writers as office edits,
//    including the manual "Sync from Jobber" button (which audits as 'sql'). Visit 6729 re-surfaced
//    33 times because a human resolving the conflict is what made it unresolvable.
type LwwShadow = {
  id: number; reason: string; verdict: string; why: string
  our_edit_at: string | null; our_edit_source: string | null
  lo_at: string | null; hi_at: string | null
  jobber_start_at: string; our_start_at: string | null
  decidable: boolean; vetoes: string[]
}

async function lwwVerdict(c: Cand, jv: JV, _jDate: string, jobberAllDay: boolean, reason: string): Promise<LwwShadow> {
  const out: LwwShadow = {
    id: c.id, reason, verdict: 'unknown', why: '',
    our_edit_at: null, our_edit_source: null, lo_at: null, hi_at: null,
    jobber_start_at: jv.startAt, our_start_at: c.start_at ?? null,
    decidable: false, vetoes: [],
  }
  try {
    const { data: le } = await supabase.rpc('visit_last_office_schedule_edit', { p_visit_id: c.id })
    const office = (Array.isArray(le) ? le[0] : le) as { changed_at: string; app_source: string | null } | undefined
    const { data: iv } = await supabase.rpc('fn_jobber_visit_schedule_interval', { p_visit_id: c.id })
    const win = (Array.isArray(iv) ? iv[0] : iv) as { lo_at: string | null; hi_at: string | null; decidable: boolean } | undefined

    out.our_edit_at = office?.changed_at ?? null
    out.our_edit_source = office?.app_source ?? null
    out.lo_at = win?.lo_at ?? null
    out.hi_at = win?.hi_at ?? null
    out.decidable = !!win?.decidable

    // VETOES apply to the ADOPT side only, and are recorded even when the verdict is push so the
    // shadow log shows how often they would bite.
    //  * all-day: adoptTarget() returns start_at=null for an all-day Jobber value, so adopting one
    //    WIPES the office's time. This is exactly what the existing `t.start_at !== null` conjunct
    //    was written to prevent and it stays.
    //  * early-AM: the BEFORE trigger derives visit_date from the ET CLOCK date (Fred 2026-07-02),
    //    so adopting a Jobber start before 06:00 ET silently moves the visit a day.
    if (jobberAllDay) out.vetoes.push('all_day_would_wipe_our_time')
    if (etParts(new Date(jv.startAt)).time.slice(0, 5) < OVERNIGHT_CUTOFF) out.vetoes.push('early_am_would_shift_visit_date')

    if (!win || !win.decidable) {
      out.verdict = 'no_clock'
      out.why = 'no witnessed Jobber transition yet (the ledger began 2026-09-09; a single observation is not an interval)'
      return out
    }
    if (!office) {
      out.verdict = 'adopt_never_edited'
      out.why = 'we have never decided this schedule, so Jobber is the only writer'
    } else if (new Date(office.changed_at) <= new Date(win.lo_at!)) {
      out.verdict = 'adopt'
      out.why = 'our edit precedes the whole interval in which Jobber changed'
    } else if (new Date(office.changed_at) > new Date(win.hi_at!)) {
      out.verdict = 'push'
      out.why = 'our edit is later than the whole interval, so our push did not land'
    } else {
      out.verdict = 'push_undecidable'
      out.why = 'our edit falls inside the interval; the Calendar wins the tie (Fred rule 1)'
    }

    if (out.verdict.startsWith('adopt') && out.vetoes.length) {
      out.why = `would ${out.verdict}, vetoed by ${out.vetoes.join(',')}`
      out.verdict = 'surface_vetoed'
    }
  } catch (e) {
    out.verdict = 'error'
    out.why = e instanceof Error ? e.message : String(e)
  }
  return out
}

function adoptTarget(jv: JV): { visit_date: string; start_at: string | null; end_at: string | null } {
  const e = etParts(new Date(jv.startAt))
  if (e.time === '00:00:00') return { visit_date: e.date, start_at: null, end_at: null }
  return { visit_date: e.date, start_at: jv.startAt, end_at: jv.endAt }
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
      const pageAt = new Date().toISOString()
      for (const n of data.visits.nodes) if (byGid.has(n.id)) jobberStart.set(n.id, { startAt: n.startAt, endAt: n.endAt ?? null, at: pageAt })
      if (jobberStart.size >= byGid.size) break
      if (!data.visits.pageInfo.hasNextPage) break
      cursor = data.visits.pageInfo.endCursor
      await new Promise((s) => setTimeout(s, 700))
    }

    // ---------------------------------------------------------------------------------------
    // OBSERVATION LEDGER (2026-09-09, migration 2026-09-09_1420). Record EVERY candidate, every
    // run, including the ones that are NOT drifting.
    // 🛑 THE NON-DRIFTING ONES ARE THE POINT. `lo` is "the last instant we witnessed the value
    //    Jobber has now replaced", so it can only exist if we were watching a visit BEFORE it
    //    drifted. Recording only the drifting ones would leave `lo` unbounded exactly when the
    //    decision needs it, which is the shape of the surfaced_visits history that migration
    //    2026-08-03_1900 already warned is not a general ledger of Jobber values.
    // 🛑 AN ABSENT NODE IS NO OBSERVATION, NOT AN EMPTY ONE. A gid Jobber did not return is
    //    recorded as `gid_absent`, which advances the attempt clock and touches neither the value
    //    nor `last_seen_at`. Silence here would read as "unchanged" and silently widen every
    //    interval: read failures are not rare (730 across 566 of 2,154 runs in 45 days).
    // 🛑 VIA THE PUBLIC WRAPPER: `sync` is not a PostgREST-exposed schema and .from() there
    //    returns a silent 200 without writing.
    // Best effort: the ledger must never be able to fail a reconciler run.
    try {
      const obs = cands.map((c) => {
        const jv = jobberStart.get(c.jobber_gid)
        return jv
          ? { visit_id: c.id, jobber_gid: c.jobber_gid, start_at: jv.startAt, end_at: jv.endAt,
              source: 'poll', outcome: 'hit', observed_at: jv.at }
          : { visit_id: c.id, jobber_gid: c.jobber_gid, source: 'poll', outcome: 'gid_absent',
              observed_at: new Date().toISOString() }
      })
      for (let i = 0; i < obs.length; i += 200) {
        const { error } = await supabase.rpc('fn_record_visit_schedule_observations', { p_rows: obs.slice(i, i + 200) })
        if (error) { console.error(`[drift] ledger write failed: ${error.message}`); break }
      }
    } catch (e) {
      console.error('[drift] ledger write threw:', e instanceof Error ? e.message : String(e))
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
    // Surfaced records carry Jobber's ACTUAL value, not just its date, so the Calendar can word the
    // warning honestly. Before 2026-08-03 every surfaced visit got the single reason
    // 'jobber_value_unexpected' and the UI printed "changed in Jobber by a person" — an assertion the
    // reconciler never verified and which was wrong for 2 of the 3 visits surfaced that day (both were
    // same-DATE time disagreements, one of them a time that had originally come FROM Jobber).
    const surfaced: Array<{
      id: number; jobber_date: string; reason: string; app_source: string | null
      jobber_start_at?: string | null; jobber_all_day?: boolean; our_start_at?: string | null
    }> = []
    // SHADOW MODE: what the last-writer-wins rule WOULD have decided on each surfaced visit.
    // Written to sync_log.details only. Nothing reads it to act.
    const lwwShadow: LwwShadow[] = []
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
          // ambiguous -> review, NEVER auto-revert. Classify precisely: the three shapes need very
          // different wording, and only the first is a real "which day is right" conflict.
          //   jobber_date_differs        — genuine disagreement about the DAY
          //   jobber_all_day_vs_our_time — same day; Jobber has no time, we do (the guard above)
          //   jobber_time_differs        — same day, both timed, clock times differ
          const jobberAllDay = t.start_at === null
          const reason = jDate !== c.visit_date ? 'jobber_date_differs'
                       : jobberAllDay            ? 'jobber_all_day_vs_our_time'
                                                 : 'jobber_time_differs'
          surfaced.push({
            id: c.id, jobber_date: jDate, reason, app_source: last.app_source ?? null,
            jobber_start_at: jv.startAt, jobber_all_day: jobberAllDay, our_start_at: c.start_at ?? null,
          })
          // SHADOW MODE (2026-09-09): compute the last-writer-wins verdict and LOG it. Acts on
          // nothing. Promotion criteria are in the migration header for 2026-09-09_1420 and in
          // Building Apps/Visit Calendar/docs/. Deliberately placed here, on the branch that
          // currently gives up, so the shadow log measures exactly the population the rule is
          // meant to take over.
          lwwShadow.push(await lwwVerdict(c, jv, jDate, jobberAllDay, reason))
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
        lww_shadow: lwwShadow.slice(0, 50),
        lww_shadow_tally: lwwShadow.reduce((m: Record<string, number>, s) => (m[s.verdict] = (m[s.verdict] ?? 0) + 1, m), {}),
        residual, read_fail: readFail,
        healable_visit_ids: healable.map((d) => d.id).slice(0, 100), adoptable_visit_ids: adoptable.map((d) => d.id).slice(0, 100),
        time_refined_visit_ids: refinedIds.slice(0, 100),
      },
    })
    return { reconcile_enabled: reconcile, checked: cands.length, drift_found: drifted.length, healable: healable.length, healed, adoptable: adoptable.length, adopted, time_refined: refinedIds.length, jobber_origin_surfaced: surfaced.length, surfaced_visits: surfaced.slice(0, 50), lww_shadow: lwwShadow.slice(0, 50), residual, read_fail: readFail }
  } catch (e) {
    const dur = Math.round((Date.now() - startMs) / 1000)
    await supabase.from('sync_log').insert({ sync_source: 'jobber_visit_drift', started_at: startedAt, finished_at: new Date().toISOString(), rows_updated: 0, rows_errored: 0, duration_seconds: dur, status: 'error', details: { error: String(e).slice(0, 300) } }).catch(() => {})
    return { error: String(e).slice(0, 300) }
  }
}

Deno.serve(async (req) => {
  // FAIL-CLOSED: no bearer, unparseable bearer, or any role other than service_role is rejected.
  if (bearerRole(req) !== 'service_role') return new Response('forbidden', { status: 403 })
  const reconcile = !HEAL_DISABLED_ENV && req.headers.get('x-no-heal') !== '1'
  if (req.headers.get('x-sync-wait') === '1') {
    const res = await runSync(reconcile)
    return new Response(JSON.stringify(res), { status: res.error ? 500 : ((res.drift_found as number) ? 207 : 200), headers: { 'Content-Type': 'application/json' } })
  }
  // @ts-ignore — EdgeRuntime is provided by the Supabase Edge runtime.
  EdgeRuntime.waitUntil(runSync(reconcile))
  return new Response(JSON.stringify({ accepted: true }), { status: 202, headers: { 'Content-Type': 'application/json' } })
})
