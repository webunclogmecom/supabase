// ============================================================================
// rpa-derm-monthly-filed — record that an LWT monthly form was actually filed
// ----------------------------------------------------------------------------
// Built 2026-08-26 for Jonathan's /monthly UI. Companion write endpoint to the
// read-only rpa-derm-monthly. Human-triggered AFTER the county form is submitted.
//
//   POST { run_id, tickets[], period_start, period_end, filed_at, ... } -> records it, ONCE.
//
// 🛑 THE GRAIN IS THE TICKET, NOT THE MONTH, AND THAT IS THE ENTIRE REASON THIS
// ENDPOINT LOOKS THE WAY IT DOES. Jonathan, 2026-08-25:
//   "the flag has to live on the ticket, not on the month ... your month= selects on
//    offload date, but our filing window is the invoice package, and packages don't
//    align to months -- SP00013840 runs 06/28-07/25. 'All tickets not yet marked
//    reported' replaces that guesswork."
// period_start/period_end record the PACKAGE's real window. They are not derived
// from, and must never be reconciled against, the month= parameter of the GET.
//
// 🛑 APPEND-ONLY, AND THAT IS THE SAFETY PROPERTY. This endpoint only ever INSERTs.
// It cannot update or delete a filing, and its role holds only SELECT + INSERT on
// both tables, so the inability is a GRANT, not a branch. A compliance record of
// "we told the county this" must not be silently rewritable by a machine.
//
// 🛑 IDEMPOTENT ON run_id, ENFORCED BY A UNIQUE CONSTRAINT, NOT BY A LOOK-THEN-WRITE.
// A replay returns the existing filing untouched. The check is a real unique index
// (lwt_filings_run_id_uniq), so two concurrent replays cannot both win: one inserts,
// the other takes the 23505 path. A read-then-insert would race.
//
// ⚠ AN UNKNOWN TICKET IS RECORDED, NOT REJECTED, AND REPORTED BACK. Jonathan:
//   "any difference against the invoice becomes a finding in either direction --
//    including the reverse case we can't detect today."
// Refusing a ticket we do not recognise would DESTROY that finding: the fact that
// they filed something we have no record of is exactly the discrepancy worth seeing.
// So it is stored with manifest_id NULL and echoed back in `unknown_tickets`.
//
// ⚠ dry_run filings are recorded but never make a ticket count as reported. See
// derm.v_lwt_ticket_reported, which filters them out. A rehearsal must not make a
// real ticket look filed.
//
// AUTH: same `x-rpa-key` as the other rpa-derm-* endpoints, verify_jwt=false in
// config.toml. Server-to-server only, no CORS (no browser calls this).
// ============================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2'

const KEYS = (Deno.env.get('RPA_BOT_KEYS') ?? '')
  .split(',')
  .map((k) => k.trim())
  .filter(Boolean)

// Same accept-and-reject discipline as rpa-derm-result / rpa-derm-evidence: an unknown
// field is a 400, so a typo in a field name can never be silently ignored and leave the
// caller believing something was recorded that was not.
const ALLOWED_FIELDS = new Set([
  'run_id',
  'tickets',
  'period_start',
  'period_end',
  'filed_at',
  'invoice_id',
  'confirmation_ref',
  'filed_by_email',
  'dry_run',
])

const MAX_TICKETS = 2000
const RUN_ID_RE = /^[A-Za-z0-9_.-]{1,100}$/
const TICKET_RE = /^[A-Za-z0-9_.-]{1,64}$/
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)

  if (KEYS.length === 0) return json({ error: 'server_misconfigured' }, 500)
  if (!KEYS.includes(req.headers.get('x-rpa-key') ?? '')) {
    return json({ error: 'unauthorized' }, 401)
  }

  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return json({ error: 'invalid_json' }, 400)
  }
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    return json({ error: 'invalid_body' }, 400)
  }

  const unknown = Object.keys(body).filter((k) => !ALLOWED_FIELDS.has(k))
  if (unknown.length) return json({ error: 'unknown_fields', fields: unknown }, 400)

  // ---- validate -------------------------------------------------------------------
  const runId = body.run_id
  if (typeof runId !== 'string' || !RUN_ID_RE.test(runId)) {
    return json({ error: 'invalid_run_id', expected: RUN_ID_RE.source }, 400)
  }

  const filedBy = body.filed_by_email === undefined || body.filed_by_email === null
    ? null
    : String(body.filed_by_email)
  // Mirrors the DB CHECK lwt_filings_actor_markers_agree. Validated here too so the
  // caller gets a named error instead of a raw constraint violation.
  if ((filedBy !== null) !== runId.startsWith('manual-')) {
    return json({
      error: 'actor_markers_disagree',
      detail: 'filed_by_email must be present exactly when run_id starts with "manual-"',
    }, 400)
  }

  for (const f of ['period_start', 'period_end'] as const) {
    if (typeof body[f] !== 'string' || !DATE_RE.test(body[f] as string)) {
      return json({ error: 'invalid_' + f, expected: 'YYYY-MM-DD' }, 400)
    }
  }
  if ((body.period_end as string) < (body.period_start as string)) {
    return json({ error: 'period_end_before_period_start' }, 400)
  }

  if (typeof body.filed_at !== 'string' || Number.isNaN(Date.parse(body.filed_at))) {
    return json({ error: 'invalid_filed_at', expected: 'ISO 8601 timestamp' }, 400)
  }

  const tickets = body.tickets
  if (!Array.isArray(tickets) || tickets.length === 0) {
    return json({ error: 'tickets_required' }, 400)
  }
  if (tickets.length > MAX_TICKETS) {
    return json({ error: 'too_many_tickets', max: MAX_TICKETS }, 400)
  }
  const bad = tickets.filter((t) => typeof t !== 'string' || !TICKET_RE.test(t))
  if (bad.length) return json({ error: 'invalid_ticket_numbers', tickets: bad.slice(0, 20) }, 400)

  // De-duplicate. A caller sending the same ticket twice in one payload means it once.
  const uniqueTickets = [...new Set(tickets as string[])]

  const dryRun = body.dry_run === true

  const db = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  )

  // ---- record the filing ATOMICALLY -----------------------------------------------
  // 🛑 ONE RPC, NOT TWO WRITES. This used to insert the header and then the ticket rows as two
  // separate PostgREST calls, which is two transactions. The header insert is also what CLAIMS
  // the run_id, so a failure on the second call left the run_id burned and the filing
  // permanently EMPTY: a retry hit 23505, took the replay path, and returned already_recorded
  // with tickets_recorded 0 without inserting anything. On a record of what we told Miami-Dade.
  // fn_record_lwt_filing does both inserts in one transaction, so a ticket failure now rolls the
  // header back with it and a retry is genuinely clean. Proven with a forced-failure probe and a
  // deliberately non-atomic control (2026-08-27_1024).
  // ⚠ Do NOT reintroduce a second write here, however small. Atomicity is the whole point.
  const { data: result, error: rpcErr } = await db.rpc('fn_record_lwt_filing', {
    p_run_id: runId,
    p_tickets: uniqueTickets,
    p_period_start: body.period_start,
    p_period_end: body.period_end,
    p_filed_at: body.filed_at,
    p_invoice_id: body.invoice_id ?? null,
    p_confirmation_ref: body.confirmation_ref ?? null,
    p_filed_by_email: filedBy,
    p_dry_run: dryRun,
  })

  if (rpcErr) {
    // 23505 on run_id is handled INSIDE the function as the replay path, so reaching here means
    // a genuine failure and, because the write is atomic, nothing was recorded. A retry with the
    // same run_id is safe and is the right response.
    console.error('record filing failed:', rpcErr.code, rpcErr.message)
    return json({
      error: 'record_failed',
      detail: rpcErr.message,
      note: 'nothing was recorded; the write is atomic, so retrying with the same run_id is safe',
    }, 500)
  }

  // The function returns the response body already shaped, so there is exactly one place that
  // decides what a filing looks like. Adding a field means changing the function, not both.
  return json(result as Record<string, unknown>, 200)
})
