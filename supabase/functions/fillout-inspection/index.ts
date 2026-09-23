// ============================================================================
// fillout-inspection — inbound pre/post SHIFT inspection intake
// ============================================================================
//
// Fred, 2026-09-23: "the idea is that later we will use a mobile app for the Drivers to do that
// inspection, but for now we could try to also get the data when posted from the Fillout".
//
// Two Fillout forms (Pre Shift Inspection 7FeakRTGTDus, Post Shift Inspection jBBi8r53nQus) collect
// a shift inspection and land it in Airtable. That path is LIVE and is NOT touched by this function.
// This is a SECOND destination so the submission also reaches the warehouse, which has been missing
// them since 2026-07-11.
//
// 🛑 THE BODY SHAPE IS OURS, NOT FILLOUT'S. Fillout's REST integration in Advanced mode lets you
// build the body as key -> form-field pairs, so this contract is one WE define. That is deliberate:
// the driver mobile app is meant to POST this identical body to this identical endpoint later, with
// no server change. Do not "simplify" this into parsing whatever Fillout happens to emit.
//
// AUTH: header `x-fillout-key` against the FILLOUT_WEBHOOK_KEY secret.
// 🛑 FAIL-CLOSED, ON PURPOSE. config.toml records the 2026-07-29 incident where three functions
// gated on `if (KEY && header !== KEY)` — an unset secret SKIPPED the check and left them open to
// the internet. A missing secret here refuses every request instead.
//
// verify_jwt = false is REQUIRED (Fillout cannot send a Supabase JWT) and is pinned in config.toml.
// config.toml also records the 2026-05-16 incident where a redeploy silently flipped this to true
// and 401'd every event at the gateway for days. If intake goes quiet, check that FIRST.

import { supabase } from '../_shared/supabase-client.ts'
import { ok, badRequest, unauthorized, serverError, logWebhookEvent } from '../_shared/responses.ts'

const SOURCE_SYSTEM = 'fillout'
const PHOTO_BUCKET = 'GT - Visits Images'

// ---------------------------------------------------------------------------
// Alias maps
// ---------------------------------------------------------------------------
// 🛑 EXPLICIT, NEVER FUZZY. Measured 2026-09-23: exact name matching resolves only 3 of the 12
// driver choices. `Marc` is our `Mark`, `Michael E` is `Michael Escobar`, `JEffry` differs by case,
// and four carry an `(OLD)` prefix. A near-miss here does not error, it silently drops the crew
// member — the same failure that made a driver vanish from the Calendar for weeks.
//
// Fred, 2026-09-23 on the (OLD) prefix: "It's the same one, it says OLD on some of them because
// they don't do it anymore, it's a drivers job and diego is no driver." So (OLD) is a statement
// about the person's CURRENT role, not a different person. Map it to the same employee.
const DRIVER_ALIASES: Record<string, string> = {
  'anthony': 'Anthony',
  'marc': 'Mark',
  'mark': 'Mark',
  'grecia': 'Grecia',
  'michael e': 'Michael Escobar',
  'michael escobar': 'Michael Escobar',
  'steven': 'Steven',
  'jeffry': 'Jeffry',
  'aaron': 'Aaron',
  '(old) ray': 'Raymond Lee',
  '(old) diego': 'Diego',
  '(old) ishad': 'Ishad Knight',
  '(old) yan': 'Yannick',
  '(old) kevis': 'Kevis Bell',
}

// ⚠ The number in the Fillout label is a NICKNAME, not a capacity, and it disagrees with the fleet
// record: "Goliath 5,000" is 4800 gallons here and "David 2,000" is 1800. Never parse it.
const TRUCK_ALIASES: Record<string, string> = {
  'moises 3800': 'Moises',
  'moises': 'Moises',
  'goliath 5,000': 'Goliath',
  'goliath 5000': 'Goliath',
  'goliath': 'Goliath',
  'david 2,000': 'David',
  'david 2000': 'David',
  'david': 'David',
  'cloggy pickup': 'Cloggy',
  'cloggy': 'Cloggy',
}

// Body key -> photo_links.role. Every role here is one ALREADY IN USE on live inspection links
// (measured 2026-09-23), so a consumer never meets an unknown tile. The migration's VERIFY asserts
// that precedent and fails if a role here has none.
// ⚠ This vocabulary is RICHER than ADR 009's table, which lists tires/boots (never used) and omits
// six that are. The live data is the contract, not the ADR.
const PHOTO_FIELDS: Record<string, string> = {
  photo_dashboard: 'dashboard',
  photo_cabin: 'cabin',
  photo_cabin_left: 'cabin_left',
  photo_cabin_right: 'cabin_right',
  photo_front: 'front',
  photo_back: 'back',
  photo_left_side: 'left_side',
  photo_right_side: 'right_side',
  photo_sludge_level: 'sludge_level',
  photo_water_level: 'water_level',
  photo_remote: 'remote',
  photo_derm_manifest: 'derm_manifest',
  photo_derm_address: 'derm_address',
  photo_closed_valve: 'closed_valve',
  photo_issue: 'issue',
  photo_expense_receipt: 'expense_receipt',
  // Two fields on the form have no established role yet. They are enqueued as `other` rather than
  // invented, because a new role value is a schema-shaped decision, not a mapping detail.
  photo_hose_extensions: 'other',
  photo_truck_off_switch: 'other',
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

/** Constant-time string compare, so the secret cannot be recovered by timing the 401. */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

function str(v: unknown): string | null {
  if (v === null || v === undefined) return null
  const s = String(v).trim()
  return s === '' ? null : s
}

/** Fillout numerics arrive as strings and may carry separators. Returns null rather than NaN or 0. */
function num(v: unknown): number | null {
  const s = str(v)
  if (s === null) return null
  const cleaned = s.replace(/[, ]/g, '')
  const n = Number(cleaned)
  return Number.isFinite(n) ? Math.round(n) : null
}

/**
 * ⚠ A blank checkbox is FALSE, but an ABSENT field is UNKNOWN. Returning false for both would
 * assert "the valve was open" on a form that never asked.
 */
function bool(v: unknown): boolean | null {
  const s = str(v)
  if (s === null) return null
  const l = s.toLowerCase()
  if (['true', 'yes', 'y', '1', 'checked', 'on'].includes(l)) return true
  if (['false', 'no', 'n', '0', 'unchecked', 'off'].includes(l)) return false
  return null
}

/** The ET CLOCK date, per the operating-date rule. Never a UTC slice: an evening ET submission is
 *  the next day in UTC, which would file the whole night under tomorrow. */
function etClockDate(iso: string | null): string | null {
  if (!iso) return null
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return null
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/New_York',
    year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(d)
  const get = (t: string) => parts.find((p) => p.type === t)?.value
  return `${get('year')}-${get('month')}-${get('day')}`
}

/** "Pre Inspection" | "pre" | "PRE" -> 'PRE'. The column stores PRE/POST (measured). */
function inspectionType(v: unknown): 'PRE' | 'POST' | null {
  const s = str(v)?.toLowerCase()
  if (!s) return null
  if (s.startsWith('pre')) return 'PRE'
  if (s.startsWith('post')) return 'POST'
  return null
}

/** Accepts a single URL or several. Fillout's exact multi-file encoding is confirmed by the first
 *  real submission (see the raw payload in webhook_events_log), so both shapes are handled. */
function urls(v: unknown): string[] {
  if (Array.isArray(v)) return v.map((x) => str(x)).filter((x): x is string => !!x)
  const s = str(v)
  if (!s) return []
  return s.split(/[\s,]+/).map((x) => x.trim()).filter((x) => /^https?:\/\//i.test(x))
}

// ---------------------------------------------------------------------------
// handler
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  const startedAt = Date.now()

  if (req.method !== 'POST') return badRequest('POST only')

  // --- auth, fail-closed -----------------------------------------------------
  const expected = Deno.env.get('FILLOUT_WEBHOOK_KEY')
  if (!expected) {
    console.error('FILLOUT_WEBHOOK_KEY is not set; refusing every request')
    return serverError('intake is not configured')
  }
  const presented = req.headers.get('x-fillout-key') ?? ''
  if (!safeEqual(presented, expected)) return unauthorized('bad or missing x-fillout-key')

  // --- body ------------------------------------------------------------------
  // Accept JSON or form-encoded: the builder emits JSON, but a form post must not silently 500.
  let body: Record<string, unknown>
  try {
    const ctype = req.headers.get('content-type') ?? ''
    if (ctype.includes('application/json')) {
      body = await req.json()
    } else {
      const form = await req.formData()
      body = Object.fromEntries([...form.entries()].map(([k, v]) => [k, String(v)]))
    }
  } catch (e) {
    return badRequest(`unreadable body: ${e instanceof Error ? e.message : String(e)}`)
  }

  const submissionId = str(body.submission_id)
  const type = inspectionType(body.pre_post ?? body.inspection_type)
  const eventType = type ? `${type.toLowerCase()}_shift_inspection` : 'shift_inspection'

  // 🛑 LOG THE RAW PAYLOAD BEFORE ANYTHING CAN FAIL. If the mapping below is wrong, the submission
  // is still recoverable from here rather than lost. This is also how the exact Fillout encoding of
  // a multi-file answer was confirmed rather than assumed.
  await logWebhookEvent(supabase, SOURCE_SYSTEM, eventType, body, {
    event_id: submissionId ?? undefined,
    entity_type: 'inspection',
    status: 'received',
  })

  if (!submissionId) return badRequest('submission_id is required; it is the idempotency key')
  if (!type) return badRequest('pre_post must say which form this is')

  const submittedAt = str(body.date) ?? new Date().toISOString()
  const shiftDate = etClockDate(submittedAt)
  if (!shiftDate) return badRequest(`unparseable date: ${str(body.date)}`)

  try {
    // --- resolve the people and the truck ------------------------------------
    // Unknown resolves to NULL and is REPORTED. It is never guessed, and it never drops the row:
    // an inspection with no driver is worth more than no inspection.
    const unresolved: string[] = []

    const driverRaw = str(body.driver)
    let employeeId: number | null = null
    if (driverRaw) {
      const target = DRIVER_ALIASES[driverRaw.toLowerCase()]
      if (!target) {
        unresolved.push(`driver:${driverRaw}`)
      } else {
        const { data } = await supabase
          .from('employees').select('id').eq('full_name', target).maybeSingle()
        if (data) employeeId = data.id
        else unresolved.push(`driver:${driverRaw}->${target}`)
      }
    }

    const truckRaw = str(body.truck)
    let vehicleId: number | null = null
    if (truckRaw) {
      const target = TRUCK_ALIASES[truckRaw.toLowerCase()]
      if (!target) {
        unresolved.push(`truck:${truckRaw}`)
      } else {
        const { data } = await supabase
          .from('vehicles').select('id').eq('name', target).maybeSingle()
        if (data) vehicleId = data.id
        else unresolved.push(`truck:${truckRaw}->${target}`)
      }
    }

    const issueNote = str(body.issue_note)
    const row = {
      vehicle_id: vehicleId,
      employee_id: employeeId,
      shift_date: shiftDate,
      inspection_type: type,
      submitted_at: submittedAt,
      sludge_gallons: num(body.sludge_gallons),
      water_gallons: num(body.water_gallons),
      gas_level: str(body.gas_level),
      is_valve_closed: bool(body.valve_closed),
      // has_issue is explicit if the form asked, otherwise derived from a note being present.
      has_issue: bool(body.has_issue) ?? (issueNote ? true : null),
      issue_note: issueNote,
    }

    // --- idempotency ----------------------------------------------------------
    // Rule 5. Fillout retries a delivery it thinks timed out, so without this a slow response
    // creates a duplicate inspection. The Submission ID is the natural key.
    const { data: link } = await supabase
      .from('entity_source_links')
      .select('entity_id')
      .eq('entity_type', 'inspection')
      .eq('source_system', SOURCE_SYSTEM)
      .eq('source_id', submissionId)
      .maybeSingle()

    let inspectionId: number
    let replayed = false

    if (link?.entity_id) {
      inspectionId = link.entity_id
      replayed = true
      const { error } = await supabase.from('inspections').update(row).eq('id', inspectionId)
      if (error) throw new Error(`update inspection ${inspectionId}: ${error.message}`)
    } else {
      const { data: ins, error } = await supabase
        .from('inspections').insert(row).select('id').single()
      if (error || !ins) throw new Error(`insert inspection: ${error?.message ?? 'no row'}`)
      inspectionId = ins.id

      const { error: linkErr } = await supabase.from('entity_source_links').insert({
        entity_type: 'inspection',
        entity_id: inspectionId,
        source_system: SOURCE_SYSTEM,
        source_id: submissionId,
      })
      // 🛑 A missing link is worse than a failed insert: the next retry would not find this row and
      // would create a second one. Fail loudly so the retry re-runs the whole thing.
      if (linkErr) throw new Error(`link inspection ${inspectionId}: ${linkErr.message}`)
    }

    // --- photos: enqueue, never fetch ----------------------------------------
    // Up to 17 attachments. Fetching them here would hold Fillout's request open and invite the
    // retry that duplicates the row, and it is how the documented edge-function OOM happens.
    const queued: Array<Record<string, unknown>> = []
    for (const [key, role] of Object.entries(PHOTO_FIELDS)) {
      for (const url of urls(body[key])) {
        queued.push({
          entity_type: 'inspection',
          entity_id: inspectionId,
          source_system: SOURCE_SYSTEM,
          role,
          source_url: url,
          target_bucket: PHOTO_BUCKET,
        })
      }
    }
    // 🛑 Through the RPC, NOT .from(). `sync` is not an exposed PostgREST schema (measured:
    // public, graphql_public, customer, derm, ops, client, hr), so a direct .from() would fail at
    // runtime with a schema-not-found. public.fn_enqueue_inbound_file is the service_role-only
    // wrapper, and it is idempotent, so a replay re-queues nothing.
    let queuedOk = 0
    for (const q of queued) {
      const { error } = await supabase.rpc('fn_enqueue_inbound_file', {
        p_entity_type: q.entity_type,
        p_entity_id: q.entity_id,
        p_source_system: q.source_system,
        p_role: q.role,
        p_source_url: q.source_url,
        p_target_bucket: q.target_bucket,
      })
      // A queue failure must not lose the inspection: the row is already committed and the URLs are
      // in webhook_events_log, so this is recoverable. Report it, do not throw.
      if (error) console.error(`queue ${q.role} for inspection ${inspectionId}: ${error.message}`)
      else queuedOk++
    }

    await logWebhookEvent(supabase, SOURCE_SYSTEM, eventType, body, {
      event_id: submissionId,
      entity_type: 'inspection',
      entity_id: inspectionId,
      status: 'processed',
      processing_ms: Date.now() - startedAt,
      error_message: unresolved.length ? `unresolved: ${unresolved.join(', ')}` : undefined,
    })

    return ok({
      ok: true,
      inspection_id: inspectionId,
      replayed,
      // Report what was ACTUALLY queued, not what we intended to queue. Those differ exactly when
      // something is wrong, which is when the number matters.
      photos_seen: queued.length,
      photos_queued: queuedOk,
      unresolved,
    })
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e)
    await logWebhookEvent(supabase, SOURCE_SYSTEM, eventType, body, {
      event_id: submissionId,
      entity_type: 'inspection',
      status: 'error',
      error_message: message,
      processing_ms: Date.now() - startedAt,
    })
    // 🛑 Return 500 so Fillout RETRIES. The raw payload is already logged, and the idempotency key
    // makes a retry safe, so a transient failure should not silently lose a shift inspection.
    return serverError(message)
  }
})
