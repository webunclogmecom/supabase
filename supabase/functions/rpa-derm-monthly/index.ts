// ============================================================================
// rpa-derm-monthly — the LWT monthly report feed (READ ONLY)
// ----------------------------------------------------------------------------
// GET /functions/v1/rpa-derm-monthly?month=YYYY-MM   header: x-rpa-key
//
// Built 2026-08-24 for Jonathan's Miami-Dade Liquid Waste Transporter generator.
// Design + every measurement behind it:
//   docs/specs/2026-08-24-lwt-monthly-endpoint-design.md
//
// 🛑 THIS ENDPOINT IS PURE. No lease, no side effects, safely re-callable.
// ⚠ There IS a cap, and there are TWO of them: MAX_ROWS = 1000 below, and PostgREST's own
//   max_rows: 1000, which is enforced regardless of a larger explicit .limit(). Truncation is
//   returned as 400 month_too_large rather than served -- a short compliance report is the
//   worst failure available. This banner read "no cap" while the constant sat 32 lines beneath
//   it. All four docs already described the cap correctly; only the source dissented, and the
//   source is what a reader treats as authoritative.
// 🛑 The guard was ALSO unreachable until 2026-08-26: it compared rows.length against our own
//   MAX_ROWS, but PostgREST had already clamped the page to 1000, so the comparison was
//   structurally false. Measured on a 2524-row table: limit=1001 and limit=5000 both return
//   exactly 1000. It now compares against count:'exact', which reports the true total through
//   the cap. A guard set exactly at the cap can never trip.
//
// 🛑 PURITY is what makes this the OPPOSITE of rpa-derm-queue, whose whole job is to never hand
// the same work out twice. Do not copy lease/dispense logic in here, and do not "unify" the
// two: a report that is not repeatable is broken, and a queue that is repeatable
// double-files to the county.
//
// 🛑 SCOPE IS PER ACTIVITY, NOT PER TICKET, and both naive builds are wrong:
//   * "offloaded in Dade" alone DROPS 11 tickets / 53 rows (Broward offloads that
//     carried Miami-Dade pickups).
//   * the OR at TICKET grain OVER-reports: measured on August 2026, ticket 311045 has
//     0 in-scope rows of 2, 312024 has 3 of 9, 310590 has 6 of 8.
// The predicate lives in derm.v_lwt_monthly_rows.in_scope, not here, so it can be
// tested without HTTP and so our own apps cannot grow a second, divergent copy.
//
// DEFAULT = in-scope rows only, because this feeds a regulatory filing and handing
// back rows that do not belong on the form invites printing them. Nothing is dropped
// SILENTLY though: excluded_rows is reported at both ticket and top level, and
// ?include=all returns the full superset for John's own filtering.
//
// AUTH: same x-rpa-key as the other three, verify_jwt=false in config.toml.
// ============================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2'

const KEYS = (Deno.env.get('RPA_BOT_KEYS') ?? '')
  .split(',')
  .map((k) => k.trim())
  .filter(Boolean)

// Far above real volume (2026 peak: 109 rows in a month). Exists so an unbounded
// query can never become an outage. 🛑 It RAISES rather than truncating: a short
// report on a compliance filing is the worst failure available here.
const MAX_ROWS = 1000

function json(body: Record<string, unknown>, status: number, extra: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...extra },
  })
}

// Cheap stable hash for the ETag. Not cryptographic: it only has to change when the
// result changes, so his preview UI can re-poll a month for free.
function etagOf(s: string): string {
  let h1 = 0x811c9dc5, h2 = 0x01000193
  for (let i = 0; i < s.length; i++) {
    h1 = (h1 ^ s.charCodeAt(i)) >>> 0
    h1 = (h1 * 0x01000193) >>> 0
    h2 = (h2 + s.charCodeAt(i) * (i + 1)) >>> 0
  }
  return `W/"${h1.toString(16)}${h2.toString(16)}"`
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'GET') return json({ error: 'method_not_allowed' }, 405)

  if (KEYS.length === 0) {
    console.error('RPA_BOT_KEYS secret not configured')
    return json({ error: 'service_not_configured' }, 503)
  }
  if (!KEYS.includes(req.headers.get('x-rpa-key') ?? '')) {
    return json({ error: 'unauthorized' }, 401)
  }

  const url = new URL(req.url)
  const month = (url.searchParams.get('month') ?? '').trim()
  const includeAll = (url.searchParams.get('include') ?? '') === 'all'

  // 🛑 ?unreported=1 SELECTS BY FILING STATE, NOT BY MONTH, AND IGNORES month= ENTIRELY.
  // Jonathan, 2026-08-25: "your month= selects on offload date, but our filing window is the
  // invoice package, and packages don't align to months -- SP00013840 runs 06/28-07/25.
  // 'All tickets not yet marked reported' replaces that guesswork."
  // A month-windowed fetch cannot express a package that straddles a boundary, so this mode
  // exists to avoid making the caller guess which months to pull.
  // ⚠ month= is REJECTED alongside it rather than ignored: silently disregarding a parameter the
  // caller supplied is how someone ends up believing they filtered when they did not.
  const unreportedOnly = (url.searchParams.get('unreported') ?? '') === '1'
  if (unreportedOnly && month) {
    return json({ error: 'month_and_unreported_are_exclusive' }, 400)
  }

  if (!unreportedOnly && !/^\d{4}-(0[1-9]|1[0-2])$/.test(month)) {
    return json({ error: 'month_required_yyyy_mm' }, 400)
  }

  // Range on the OFFLOAD date, so a ticket is never split across two reports.
  // ⚠ A pickup can therefore fall in the PREVIOUS month (real: ticket 831710 offloaded
  // 2026-08-02 carries a 2026-07-30 pickup). That is deliberate and is an open question
  // for John, not something to silently "fix" by filtering on pickup_date too.
  // In unreported mode there is no month window; these are unused and set to safe sentinels
  // so the month guard rails below cannot fire on a request that has no month.
  const [y, m] = unreportedOnly ? [0, 0] : month.split('-').map(Number)
  const start = unreportedOnly ? null : `${month}-01`
  const endD = unreportedOnly ? null : new Date(Date.UTC(y, m, 1)) // first of the next month
  const end = endD ? endD.toISOString().slice(0, 10) : null

  // Guard rails: nothing before the first manifest, nothing far in the future.
  if (!unreportedOnly && (y < 2024 || endD!.getTime() > Date.now() + 62 * 24 * 3600 * 1000)) {
    return json({ error: 'month_out_of_range' }, 400)
  }

  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { global: { headers: { 'x-app-source': 'gdo-report-bot' } } },
  )

  // 🛑 .schema('derm') IS LOAD-BEARING. This view lives in `derm`, and `sb` is built
  // without a `db.schema` option, so it resolves names against `public` by default.
  // Omitting it is exactly the defect that made record-manual-gdo-report fail for
  // every visit in its entire history (fixed 2026-08-24, commit e30f28f). The failure
  // is a plain "relation does not exist" that reads like the view was never created.
  // Filing state, keyed by ticket. Read for BOTH modes: in unreported mode it selects the rows,
  // and in month mode it decorates them, so a caller pulling a month can see what is already
  // filed without a second call.
  // 🛑 This read had no limit and no overflow check, and it is the read that SELECTS the filing
  // set in unreported mode. PostgREST's max_rows: 1000 applies here too, so past 1000 distinct
  // tickets it would silently serve the first 1000 and the bot would file a short month with an
  // HTTP 200. 127 tickets today. Counting is the only way to see the cap bite.
  const { data: repRows, error: repErr, count: repCount } = await sb
    .schema('derm')
    .from('v_lwt_ticket_reported')
    .select('ticket_number, reported, invoice_id, period_start, period_end, filed_at, confirmation_ref, filed_by_email',
      { count: 'exact' })
  if (repErr) {
    console.error('reported lookup failed:', repErr.message)
    return json({ error: 'reported_lookup_failed' }, 500)
  }
  if (typeof repCount === 'number' && repCount > (repRows ?? []).length) {
    console.error('reported lookup truncated:', repCount, 'exist,', (repRows ?? []).length, 'returned')
    return json({
      error: 'reported_lookup_truncated',
      total_tickets: repCount,
      returned: (repRows ?? []).length,
      note: 'filing state was truncated by a server row cap; the unreported set would be short',
    }, 500)
  }
  const reportedByTicket = new Map(
    (repRows ?? []).map((r) => [String(r.ticket_number), r]),
  )
  const unreportedTickets = (repRows ?? [])
    .filter((r) => r.reported !== true)
    .map((r) => String(r.ticket_number))

  // ⚠ An empty result here is a legitimate answer ("everything is filed"), NOT an error, and it
  // must not fall through to an unfiltered .in() -- PostgREST treats `in.()` as matching nothing
  // in some versions and everything in others, and guessing which would be a silent full dump of
  // the estate. Return the empty shape explicitly instead.
  if (unreportedOnly && unreportedTickets.length === 0) {
    return json({
      month: null,
      mode: 'unreported',
      ticket_count: 0,
      tickets: [],
      generated_at: new Date().toISOString(),
      note: 'every in-scope ticket has been recorded as filed',
    }, 200)
  }

  let qy = sb
    .schema('derm')
    .from('v_lwt_monthly_rows')
    // 🛑 count:'exact' is what makes the overflow guard below REACHABLE. PostgREST is configured
    // max_rows: 1000 and enforces it regardless of a larger explicit .limit(), so comparing
    // rows.length against our own MAX_ROWS could never fire: measured on a 2524-row table,
    // limit=1001 and limit=5000 both return exactly 1000. The count header keeps reporting the
    // TRUE total through the cap (content-range 0-999/2524), so it is the only honest signal.
    .select('*', { count: 'exact' })
  qy = unreportedOnly
    ? qy.in('ticket_number', unreportedTickets)
    : qy.gte('offload_date', start!).lt('offload_date', end!)

  const { data, error, count } = await qy
    .order('offload_date', { ascending: true })
    .order('ticket_number', { ascending: true })
    .order('pickup_date', { ascending: true })
    // 🛑 THE LAST TWO KEYS MAKE THE SORT TOTAL, AND THAT IS NOT COSMETIC.
    // The first three leave ties: 175 tie GROUPS covering 571 of 690 rows (largest group 8), so
    // Postgres was free to return them in a different order on two identical calls.
    // ⚠ A first draft of this comment said "175 of 690 rows", which was wrong and understated it
    // by more than half: 175 is the count of GROUPS. The query had a `lateral (select c)` that
    // yields ONE row per group, so it was counting groups while its own column was named
    // rows_in_tie_groups. Summing the group sizes is what gives the row count. The honest figure
    // is 83% of rows, not 25%. Measured 2026-08-25 -- the same
    // month with unchanged data served two different ETags (2026-06 gave 5e7d3878b24945c0 and
    // e0c5cae0b244faeb) because etagOf() hashes the serialised payload, and 50 rows had swapped
    // positions. Two consequences: a conditional GET could miss a 304 it deserved, and the
    // PRINTED LINE ORDER of a county filing was not reproducible between two pulls even though
    // the row SET was identical.
    // visit_id is unique across all 690 rows today; manifest_id is belt-and-braces so the order
    // stays total if a visit is ever linked to two manifests.
    .order('visit_id', { ascending: true })
    .order('manifest_id', { ascending: true })
    .limit(MAX_ROWS + 1)

  if (error) {
    console.error('monthly query failed:', error.message)
    return json({ error: 'monthly_query_failed' }, 500)
  }
  const rows = data ?? []
  // Loud, never a silent truncation. Compare against the TRUE count rather than our own cap:
  // this fires whenever the server returned fewer rows than exist, whichever limit bit first
  // (ours at MAX_ROWS + 1, or PostgREST's max_rows, which is currently the lower of the two).
  // The previous form, rows.length > MAX_ROWS, was structurally unreachable.
  if (typeof count === 'number' && count > rows.length) {
    return json({
      error: 'month_too_large',
      max_rows: rows.length,
      total_rows: count,
      note: 'the result was truncated by a server row cap; nothing here is safe to file',
    }, 400)
  }

  // ---- data-quality overlay ----------------------------------------------------
  // Rows that assert something physically impossible still SHIP, deliberately: this
  // report feeds a county filing, and silently clamping or hiding a compliance date
  // is worse than printing an odd one. But John must not file one unknowingly, so
  // every conflict is named in the response and flagged on the row it affects.
  //
  // ⚠ .schema('derm') again. Same load-bearing call as the query above.
  // ⚠ Fetched WITHOUT a date filter and matched by visit_id in TS on purpose: the
  //   view's visit_not_completed conflicts can carry a NULL offload_date, and a
  //   .gte('offload_date', ...) would silently drop exactly those. The table is tiny
  //   (4 rows on 2026-08-24); the cap below is a runaway guard, not a page size.
  const MAX_CONFLICTS = 500
  const { data: conflictData, error: conflictError } = await sb
    .schema('derm')
    .from('v_manifest_link_date_conflicts')
    .select('visit_id, ticket_number, conflict_kind, days_after_offload, violates_guard, client_code, offload_date, pickup_date, visit_status')
    // 🛑 ORDERED FOR THE SAME REASON THE MAIN QUERY IS, AND IT WAS MISSED THE FIRST TIME.
    // These rows land in data_quality.conflicts, which is inside the object handed to etagOf(),
    // so an unstable order here produces an unstable ETag exactly as the main query's ties did.
    // Measured: a 2-element conflicts array forward vs reversed hashes differently. The view
    // carries no ORDER BY of its own, so without this the order is unspecified.
    // It is inert today only because the whole fleet holds 4 conflicts, one per month, and a
    // 1-element array has only one order -- which is precisely the kind of "can't happen yet"
    // that stops being true without anyone noticing.
    // The .limit() below compounds it: unordered + limited means WHICH rows come back is
    // unspecified too, not just their sequence.
    .order('offload_date', { ascending: true })
    .order('visit_id', { ascending: true })
    .limit(MAX_CONFLICTS)

  // A failure here must NOT fail the report. Report the degradation instead of
  // returning a clean-looking body that quietly checked nothing.
  if (conflictError) console.error('conflict overlay failed:', conflictError.message)
  const conflictAvailable = !conflictError
  const conflictByVisit = new Map<number, Record<string, unknown>>()
  for (const c of (conflictData ?? []) as Record<string, any>[]) {
    conflictByVisit.set(Number(c.visit_id), c)
  }

  // ---- group rows into tickets -------------------------------------------------
  type Row = Record<string, any>
  const byTicket = new Map<string, Row[]>()
  for (const r of rows as Row[]) {
    const k = String(r.ticket_number)
    if (!byTicket.has(k)) byTicket.set(k, [])
    byTicket.get(k)!.push(r)
  }

  let excludedTotal = 0
  const tickets: Record<string, unknown>[] = []

  for (const [ticketNumber, all] of byTicket) {
    const kept = includeAll ? all : all.filter((r) => r.in_scope === true)
    const excluded = all.length - all.filter((r) => r.in_scope === true).length
    // A ticket with no in-scope activity is not a Miami-Dade activity at all
    // (measured: August ticket 311045, 2 rows, 0 in scope). Drop the whole ticket in
    // the default view, but still count its rows as excluded so the omission is
    // visible rather than silent.
    // ⚠ include=all must mean ALL: it keeps these tickets, or the flag does not do
    // what its name says and John cannot see what he is filtering out.
    if (!includeAll && all.every((r) => r.in_scope !== true)) {
      excludedTotal += all.length
      continue
    }
    excludedTotal += excluded

    const head = all[0]
    tickets.push({
      ticket_number: ticketNumber,
      ticket_kind: head.ticket_kind,
      offload_in_dade: head.offload_in_dade,
      offload_date: head.offload_date,
      disposal_facility: head.disposal_facility,
      trucks: [...new Set(all.map((r) => r.truck).filter(Boolean))],
      // Parallel to `trucks`, for a caller that resolves per ticket rather than per row.
      // ⚠ NOT positionally aligned with `trucks`: both are de-duplicated independently, and a
      // truck with no decal contributes to `trucks` and not here, so the arrays can differ in
      // length. Join on the row's own truck_decal, never by index.
      truck_decals: [...new Set(all.map((r) => r.truck_decal).filter(Boolean))],
      excluded_rows: excluded,
      // Filing state for this ticket. `reported` is an EXISTENCE question, not a state machine:
      // true means some non-dry-run filing recorded this ticket. A refiled ticket reports the
      // most recent real filing. dry_run filings never set it.
      // ⚠ confirmation_ref is routinely null and that is NOT a failure: Jonathan, 2026-08-25,
      // "the county gives no confirmation number for the monthly form -- none of the six filed
      // months has one." Do not infer anything from its absence.
      reported: reportedByTicket.get(ticketNumber)?.reported === true,
      filing: reportedByTicket.get(ticketNumber)?.reported === true
        ? {
          invoice_id: reportedByTicket.get(ticketNumber)!.invoice_id,
          period_start: reportedByTicket.get(ticketNumber)!.period_start,
          period_end: reportedByTicket.get(ticketNumber)!.period_end,
          filed_at: reportedByTicket.get(ticketNumber)!.filed_at,
          confirmation_ref: reportedByTicket.get(ticketNumber)!.confirmation_ref,
          filed_by_email: reportedByTicket.get(ticketNumber)!.filed_by_email,
        }
        : null,
      rows: kept.map((r) => ({
        pickup_date: r.pickup_date,
        client_code: r.client_code,
        client_name: r.client_name,
        address: r.address,
        city: r.city,
        state: r.state,
        zip: r.zip,
        county: r.county,
        pickup_in_dade: r.pickup_in_dade,
        in_scope: r.in_scope,
        truck: r.truck,
        // numeric() arrives as a string over PostgREST; emit a number or null.
        // ⚠ INTERNAL FLEET FACT, NOT THE FILED QUANTITY. Corrected 2026-08-26 after Jonathan:
        // "The county invoice bills actual gallons per manifest -- 828837 is 3,800 on the
        // invoice, which as you noted matches no truck -- and the form's fee is computed from
        // those gallons. So decal capacity can't fill Quantity." Ticket 828837 is Moises /
        // decal C1184 / 9000 here, against 3,800 billed. Nothing on the county form is computed
        // from this number. An earlier comment here claimed the opposite; do not restore it.
        truck_capacity_gallons: r.truck_capacity_gallons == null
          ? null
          : Number(r.truck_capacity_gallons),
        // The vehicle's ACTIVE Miami-Dade decal, added 2026-08-26. It is the PERMIT NUMBER
        // identifying which vehicle carried the manifest; the payload previously carried only
        // truck names, which are not stable identifiers to a regulator.
        // 🛑 It does NOT resolve a quantity. The county bills MEASURED gallons per manifest off
        // the invoice, and nothing on the form is computed from the decal or from capacity. This
        // comment said "the caller resolves quantity from a decal-keyed table" until 2026-08-26,
        // which was the sixth surviving copy of a claim retracted that morning, and it survived a
        // phrase sweep because it words the same claim differently. Grep the MEANING, not one
        // phrasing.
        // null on 51 of 700 rows: Cloggy (45 rows, 43 of them in scope, across 27 in-scope
        // tickets) holds no decal in any jurisdiction, and 6 rows carry no truck at all, so
        // 45 + 6 is the 51. ⚠ Quote both figures: 51 counts every row and 43 counts only in-scope
        // ones, so "43 rows" beside "51 of 700" reads as arithmetic that does not close.
        // A null must make the caller REFUSE the ticket. Never substitute a capacity, a truck
        // name, or another jurisdiction's decal: that would put a wrong permit number on a
        // county filing.
        truck_decal: r.truck_decal ?? null,
        // ALWAYS null. We store no measured volume (0 non-null of 700), and the county bills
        // measured gallons, so any value here would be a guess presented as a fact.
        gallons: null,
        visit_id: r.visit_id,
        // null on a healthy row. Present = this activity is internally contradictory
        // and should be checked against the paper manifest before it is filed.
        anomaly: conflictByVisit.get(Number(r.visit_id))
          ? {
            kind: conflictByVisit.get(Number(r.visit_id))!.conflict_kind,
            days_after_offload: conflictByVisit.get(Number(r.visit_id))!.days_after_offload,
            note: 'pickup is dated after its own offload, or the visit is not marked completed - grease is pumped before it is dumped, so one of the two records is wrong',
          }
          : null,
      })),
    })
  }

  // Only conflicts that actually appear in THIS month's returned rows. A conflict on
  // some other month is not this report's problem and would just be noise.
  const shownVisitIds = new Set<number>()
  for (const t of tickets) {
    for (const r of t.rows as Record<string, any>[]) shownVisitIds.add(Number(r.visit_id))
  }
  const monthConflicts = [...conflictByVisit.values()].filter((c) =>
    shownVisitIds.has(Number(c.visit_id))
  )

  const body = {
    // null in unreported mode: the selection was not a month, and emitting a month here would
    // invite a caller to believe the package window equals a calendar month, which is the exact
    // assumption this mode exists to remove.
    month: unreportedOnly ? null : month,
    mode: unreportedOnly ? 'unreported' : 'month',
    generated_at: new Date().toISOString(),
    county: 'Miami-Dade',
    scope: 'picked up in Miami-Dade OR offloaded in Miami-Dade, evaluated per activity',
    include: includeAll ? 'all' : 'in_scope',
    ticket_count: tickets.length,
    row_count: tickets.reduce((n, t) => n + (t.rows as unknown[]).length, 0),
    excluded_rows: excludedTotal,
    // Nothing here is filtered out of `tickets`. This is a heads-up, not a filter:
    // check these against the paper manifest before filing.
    // `checked: false` means the overlay query itself failed, so an empty `conflicts`
    // list proves nothing. Never read conflict_count === 0 as an all-clear without it.
    data_quality: {
      checked: conflictAvailable,
      conflict_count: conflictAvailable ? monthConflicts.length : null,
      conflicts: monthConflicts,
    },
    tickets,
  }

  // ETag ignores generated_at, or every call would look different.
  const { generated_at: _ignored, ...stable } = body
  const etag = etagOf(JSON.stringify(stable))
  if ((req.headers.get('if-none-match') ?? '') === etag) {
    return new Response(null, { status: 304, headers: { ETag: etag } })
  }

  return json(body, 200, { ETag: etag, 'Cache-Control': 'no-cache' })
})
