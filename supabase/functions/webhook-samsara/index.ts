// ============================================================================
// webhook-samsara/index.ts — Samsara webhook receiver (Edge Function)
// ============================================================================
// PERMANENT INTEGRATION — Samsara is the only source that stays after May 2026.
//
// Handles:
//   - AddressCreated/Updated/Deleted → clients/properties GPS + geofence
//   - DriverCreated/Updated → employees
//   - VehicleStatsSnapshot → vehicle_telemetry_readings (3NF time-series)
//   - AlertTriggered (geofence) → visits GPS enrichment
//
// Samsara sends full payloads (not thin notifications like Jobber).
// ============================================================================

import { supabase } from '../_shared/supabase-client.ts'
import { upsertEntityLink, findEntityBySourceId, buildSourceMap } from '../_shared/entity-links.ts'
import { ok, badRequest, unauthorized, serverError, logWebhookEvent } from '../_shared/responses.ts'

// ---- HMAC verification ----
// Samsara webhook signature spec (per developers.samsara.com/docs/webhooks):
//   HMAC-SHA256 over the message "v1:<timestamp>:<body>" where
//     <timestamp> = value of the X-Samsara-Timestamp header
//     <body>      = raw POST body
//   The secretKey shown in the Samsara dashboard is base64-encoded — must be
//   decoded to raw bytes before being used as the HMAC key.
//   The X-Samsara-Signature header is "v1=<hex_digest>".
//
// SAMSARA_WEBHOOK_SECRETS env is a comma-separated list of base64 secrets
// (one per registered webhook); we try each until one matches.
async function verifySamsaraSignature(
  body: string,
  signature: string | null,
  timestamp: string | null,
): Promise<boolean> {
  const multi = Deno.env.get('SAMSARA_WEBHOOK_SECRETS')
  const single = Deno.env.get('SAMSARA_WEBHOOK_SECRET')
  const secrets = [
    ...(multi ? multi.split(',').map((s) => s.trim()).filter(Boolean) : []),
    ...(single ? [single] : []),
  ]
  if (secrets.length === 0) {
    console.warn('SAMSARA_WEBHOOK_SECRETS not set — skipping verification')
    return true
  }
  if (!signature || !timestamp) return false

  // Strip "v1=" prefix from signature header
  const expectedHex = signature.startsWith('v1=') ? signature.slice(3) : signature

  // Build the canonical signed message: "v1:<timestamp>:<body>"
  const messageBytes = new TextEncoder().encode(`v1:${timestamp}:${body}`)

  for (const b64Secret of secrets) {
    // Decode base64 secret → raw bytes
    let keyBytes: Uint8Array
    try {
      const bin = atob(b64Secret)
      keyBytes = new Uint8Array(bin.length)
      for (let i = 0; i < bin.length; i++) keyBytes[i] = bin.charCodeAt(i)
    } catch {
      continue
    }
    const key = await crypto.subtle.importKey(
      'raw',
      keyBytes,
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign'],
    )
    const sig = await crypto.subtle.sign('HMAC', key, messageBytes)
    const hex = Array.from(new Uint8Array(sig))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('')
    if (hex === expectedHex) return true
  }
  return false
}

// ============================================================================
// Address Handlers → clients (GPS + geofence)
// ============================================================================

async function handleAddress(
  address: any,
  action: 'created' | 'updated' | 'deleted'
): Promise<{ entity_type: string; entity_id: number | null }> {
  const samsaraId = String(address.id)
  const name = address.name ?? address.formattedAddress ?? ''

  if (action === 'deleted') {
    // Don't hard-delete — just clear GPS data from the property
    const clientId = await findEntityBySourceId('client', 'samsara', samsaraId)
    if (clientId) {
      // Clear geofence from primary property
      const { data: props } = await supabase
        .from('properties')
        .select('id')
        .eq('client_id', clientId)
        .eq('is_primary', true)
        .limit(1)

      if (props?.length) {
        await supabase.from('properties').update({
          latitude: null,
          longitude: null,
          geofence_radius_meters: null,
          geofence_type: null,
        }).eq('id', props[0].id)
      }
    }
    return { entity_type: 'client', entity_id: clientId }
  }

  // Find existing client linked to this Samsara address
  let clientId = await findEntityBySourceId('client', 'samsara', samsaraId)

  // If no existing link, try fuzzy name match
  if (!clientId) {
    const { data: candidates } = await supabase
      .from('clients')
      .select('id, name')
      .ilike('name', `%${name.replace(/[%_]/g, '')}%`)
      .limit(5)

    if (candidates?.length === 1) {
      clientId = candidates[0].id
    } else {
      console.warn(`Samsara address "${name}" (${samsaraId}) has no client match — skipping`)
      return { entity_type: 'client', entity_id: null }
    }
  }

  // Extract geofence data
  const lat = address.latitude ?? address.geofence?.circle?.latitude ?? null
  const lng = address.longitude ?? address.geofence?.circle?.longitude ?? null
  const radius = address.geofence?.circle?.radiusMeters ?? null
  const geoType = address.geofence?.polygon ? 'polygon' : address.geofence?.circle ? 'circle' : null

  // v2: GPS + geofence lives on properties, not clients
  // Find or create primary property for this client
  const { data: props } = await supabase
    .from('properties')
    .select('id')
    .eq('client_id', clientId)
    .eq('is_primary', true)
    .limit(1)

  const propUpdate: Record<string, unknown> = {}
  if (lat !== null) propUpdate.latitude = lat
  if (lng !== null) propUpdate.longitude = lng
  if (radius !== null) propUpdate.geofence_radius_meters = radius
  if (geoType) propUpdate.geofence_type = geoType
  if (address.formattedAddress) propUpdate.address = address.formattedAddress

  if (Object.keys(propUpdate).length) {
    if (props?.length) {
      await supabase.from('properties').update(propUpdate).eq('id', props[0].id)
    } else {
      // Create primary property with GPS data
      const { data: newProp } = await supabase
        .from('properties')
        .insert({
          client_id: clientId,
          is_primary: true,
          name: name,
          ...propUpdate,
        })
        .select('id')
        .single()

      if (newProp) {
        await upsertEntityLink({
          entity_type: 'property',
          entity_id: newProp.id,
          source_system: 'samsara',
          source_id: `addr_${samsaraId}`,
          source_name: name,
          match_method: 'webhook_new',
        })
      }
    }
  }

  await upsertEntityLink({
    entity_type: 'client',
    entity_id: clientId,
    source_system: 'samsara',
    source_id: samsaraId,
    source_name: name,
    match_method: action === 'created' ? 'webhook_new' : 'webhook_update',
  })

  return { entity_type: 'client', entity_id: clientId }
}

// ============================================================================
// Driver Handlers → employees
// ============================================================================

/** Normalise a name or email for comparison: trim, lowercase, collapse whitespace. */
const normId = (v: unknown) => String(v ?? '').trim().toLowerCase().replace(/\s+/g, ' ')

/**
 * Find the employee this Samsara driver already IS, without guessing.
 *
 * Returns the id when exactly ONE candidate matches, null when none does, and
 * `ambiguous` when several do. Ambiguity is never resolved by picking the first row:
 * merging two different people is far worse than leaving one driver unlinked.
 *
 * ⚠ THE MATCHERS ARE ORDERED BY STRENGTH AND CONSTRAINED BY WHAT THE DATA ACTUALLY HAS.
 * Measured 2026-08-18 over all 20 employees: 6 carry an email, **0 carry a phone**, so a
 * phone matcher would be dead code. Samsara also sent NO email and NO phone for the driver
 * that caused the duplicate, so name matching is the only rule that could have caught it.
 * Most staff are stored first-name-only ("Michael"), while Samsara sends the full name
 * ("Michael Escobar"), which is what rule 3 exists for.
 */
async function reconcileEmployee(
  name: string,
  email: string | null,
): Promise<{ id: number; how: string } | { ambiguous: true; how: string } | null> {
  const { data: rows, error } = await supabase
    .from('employees')
    .select('id, full_name, email, status')
  if (error) throw new Error(`employee reconcile read failed: ${error.message}`)
  const all = rows ?? []

  const pick = (cands: any[], how: string) => {
    if (cands.length === 1) return { id: cands[0].id as number, how }
    if (cands.length > 1) return { ambiguous: true as const, how }
    return null
  }

  // 1. email, exact. The only genuinely unambiguous key we hold.
  const e = normId(email)
  if (e) {
    const hit = pick(all.filter((r) => normId(r.email) === e), 'email')
    if (hit) return hit
  }

  const n = normId(name)
  if (!n) return null

  // 🛑 NAME RULES SEARCH **ACTIVE** EMPLOYEES ONLY. Retired rows are mostly duplicates of
  // people who are still here (`Anthony Clark` is a retired duplicate of the live `Anthony`, and
  // `Michael Escobar (samsara duplicate, retired ...)` of the live `Michael Escobar`), so matching
  // them does two bad things: it makes a live driver look AMBIGUOUS because his own retired twin
  // also matches, and where it does resolve it attaches live telemetry to a DEAD row, which is
  // worse than not linking at all. Both were caught by running this matcher against the real
  // employees table before shipping it, not by reading it.
  // Email is deliberately exempt (it is checked above, across all rows): it is unambiguous
  // identity, so it may legitimately land on someone who is currently inactive.
  const live = all.filter((r) => r.status === 'ACTIVE')

  // 2. full name, exact.
  const exact = pick(live.filter((r) => normId(r.full_name) === n), 'full_name')
  if (exact) return exact

  // 3. Samsara's FIRST token equals a first-name-only employee row. "Michael Escobar" -> "Michael".
  const first = n.split(' ')[0]
  if (first && first !== n) {
    const byFirst = pick(live.filter((r) => normId(r.full_name) === first), 'samsara_first_name')
    if (byFirst) return byFirst
  }

  // 4. The reverse: Samsara sends one token and we store the full name.
  const byStored = pick(
    live.filter((r) => {
      const f = normId(r.full_name)
      return f.includes(' ') && f.split(' ')[0] === n
    }),
    'stored_first_name',
  )
  if (byStored) return byStored

  return null
}

async function handleDriver(
  driver: any,
  action: 'created' | 'updated'
): Promise<{ entity_type: string; entity_id: number }> {
  const samsaraId = String(driver.id)
  const name = driver.name ?? `${driver.firstName ?? ''} ${driver.lastName ?? ''}`.trim()

  const empId = await findEntityBySourceId('employee', 'samsara', samsaraId)

  // 🛑 SAMSARA MUST NEVER OVERWRITE A VALUE WE ALREADY HOLD. It may only FILL A BLANK.
  // This handler used to write `{ full_name: name || null, phone: driver.phone ?? null,
  // email: driver.email ?? null }` on every update, so a driver payload without an email
  // BLANKED the employee's email. `?? null` does not protect you: null is exactly what
  // Samsara sends for a field it has nothing for. Same class as the property name-blanking
  // bug in CLAUDE.md, and it became live for Michael the moment his samsara link moved onto
  // the row that holds his real email.
  // Rule 4 also settles the direction: Jobber owns employees; Samsara owns field telemetry.
  const enrichOnly = async (id: number) => {
    const { data: cur, error: readErr } = await supabase
      .from('employees').select('full_name, email, phone').eq('id', id).maybeSingle()
    if (readErr) throw new Error(`employee read failed: ${readErr.message}`)
    const patch: Record<string, unknown> = {}
    const blank = (v: unknown) => v === null || v === undefined || String(v).trim() === ''
    if (blank(cur?.full_name) && !blank(name)) patch.full_name = name
    if (blank(cur?.email) && !blank(driver.email)) patch.email = driver.email
    if (blank(cur?.phone) && !blank(driver.phone)) patch.phone = driver.phone
    if (Object.keys(patch).length === 0) return
    const { error } = await supabase.from('employees').update(patch).eq('id', id)
    if (error) throw new Error(`Employee enrich failed: ${error.message}`)
    console.log(`[handleDriver] enriched employee ${id} with ${Object.keys(patch).join(', ')}`)
  }

  if (empId) {
    await enrichOnly(empId)
    await upsertEntityLink({
      entity_type: 'employee', entity_id: empId, source_system: 'samsara',
      source_id: samsaraId, source_name: name,
      match_method: action === 'created' ? 'webhook_new' : 'webhook_update',
    })
    return { entity_type: 'employee', entity_id: empId }
  }

  // 🛑 AN UNKNOWN SAMSARA ID IS NOT AUTOMATICALLY A NEW PERSON, AND THIS NO LONGER CREATES ONE.
  // It used to INSERT unconditionally, which is how we ended up with two Michaels 67 minutes
  // apart: the Jobber side had already created him, Samsara did not look, and inserted a second
  // row. `Mark noltion` and `Anthony Clark` are older residue of the same thing.
  // The correct end state is ONE employee carrying BOTH a jobber and a samsara link, which is
  // what entity_source_links exists for and what Grecia, Mark and Anthony already look like.
  const match = await reconcileEmployee(name, driver.email ?? null)

  if (match && 'id' in match) {
    await enrichOnly(match.id)
    await upsertEntityLink({
      entity_type: 'employee', entity_id: match.id, source_system: 'samsara',
      source_id: samsaraId, source_name: name,
      match_method: `reconciled_${match.how}`,
    })
    console.log(`[handleDriver] samsara driver ${samsaraId} "${name}" matched existing employee ${match.id} by ${match.how}; linked, not created`)
    return { entity_type: 'employee', entity_id: match.id }
  }

  // No confident match. Do NOT invent an employee: return 0 so the dispatcher logs this as
  // `skipped` WITH THE FULL PAYLOAD in webhook_events_log, where a person can see it and
  // create the employee properly (employees originate from Jobber, per rule 4). Nothing is
  // lost; the next driver event for the same id will reconcile once the row exists.
  console.warn(
    `[handleDriver] SKIPPED samsara driver ${samsaraId} "${name}": ` +
    (match && 'ambiguous' in match
      ? `several employees matched by ${match.how}, refusing to guess`
      : 'no employee matched') +
    '. Create the employee (with its Jobber link) and this will attach on the next event.'
  )
  return { entity_type: 'employee', entity_id: 0 }
}

// ============================================================================
// Vehicle Stats → vehicle_telemetry_readings (3NF time-series)
// ============================================================================
// 3NF: each row is one observation of vehicle_id at recorded_at. Every column
// (fuel_percent, odometer_meters, engine_state, engine_hours_seconds) is a
// direct reading from Samsara. fuel_gallons is NOT stored — it's computed on
// read in v_vehicle_telemetry_latest via JOIN to vehicles.fuel_tank_capacity_gallons.

async function handleVehicleStats(
  event: any
): Promise<{ entity_type: string; entity_id: number | null; readings: number }> {
  const vehicle = event.vehicle ?? event.data?.vehicle
  if (!vehicle?.id) {
    console.warn('VehicleStats event missing vehicle.id')
    return { entity_type: 'vehicle', entity_id: null, readings: 0 }
  }

  const samsaraVehicleId = String(vehicle.id)

  // Look up our vehicle via entity_source_links
  let vehicleId = await findEntityBySourceId('vehicle', 'samsara', samsaraVehicleId)

  // Fallback: try by vehicle name
  if (!vehicleId && vehicle.name) {
    const { data } = await supabase
      .from('vehicles')
      .select('id')
      .ilike('name', vehicle.name)
      .limit(1)
    if (data?.length) vehicleId = data[0].id
  }

  if (!vehicleId) {
    console.warn(`No vehicle found for Samsara ID ${samsaraVehicleId} (${vehicle.name})`)
    return { entity_type: 'vehicle', entity_id: null, readings: 0 }
  }

  // Extract telemetry from Samsara payload (multiple shapes supported)
  const stats = event.data?.stats ?? event.stats ?? []
  const fuelStat        = stats.find?.((s: any) => s.type === 'fuelPercent') ?? event.data?.fuelPercent ?? event.fuelPercent
  const odometerStat    = stats.find?.((s: any) => s.type === 'obdOdometerMeters' || s.type === 'odometerMeters') ?? event.data?.obdOdometerMeters ?? event.data?.odometerMeters
  const engineStat      = stats.find?.((s: any) => s.type === 'engineState') ?? event.data?.engineState
  const engineHoursStat = stats.find?.((s: any) => s.type === 'engineSeconds' || s.type === 'engineHours') ?? event.data?.engineSeconds

  const fuelPercent       = typeof fuelStat === 'object' ? fuelStat?.value : fuelStat
  const fuelTime          = typeof fuelStat === 'object' ? fuelStat?.time : event.eventTime
  const odometerValue     = typeof odometerStat === 'object' ? odometerStat?.value : odometerStat
  const engineValue       = typeof engineStat === 'object' ? engineStat?.value : engineStat
  const engineHoursValue  = typeof engineHoursStat === 'object' ? engineHoursStat?.value : engineHoursStat

  // Skip if no telemetry at all — don't write empty rows
  if (
    (fuelPercent === null || fuelPercent === undefined) &&
    (odometerValue === null || odometerValue === undefined) &&
    (engineValue === null || engineValue === undefined) &&
    (engineHoursValue === null || engineHoursValue === undefined)
  ) {
    console.log(`VehicleStats for ${vehicle.name}: no telemetry in this event`)
    return { entity_type: 'vehicle', entity_id: vehicleId, readings: 0 }
  }

  // Append-only insert — no derived columns, all direct observations (3NF)
  const { error } = await supabase.from('vehicle_telemetry_readings').insert({
    vehicle_id: vehicleId,
    fuel_percent: fuelPercent !== null && fuelPercent !== undefined ? Number(fuelPercent) : null,
    odometer_meters: odometerValue ? Number(odometerValue) : null,
    engine_state: engineValue ?? null,
    engine_hours_seconds: engineHoursValue ? Number(engineHoursValue) : null,
    recorded_at: fuelTime ?? event.eventTime ?? new Date().toISOString(),
  })

  if (error) {
    console.error(`Telemetry insert failed for vehicle ${vehicleId}:`, error.message)
    return { entity_type: 'vehicle', entity_id: vehicleId, readings: 0 }
  }

  return { entity_type: 'vehicle', entity_id: vehicleId, readings: 1 }
}

// ============================================================================
// Geofence Alert → visits GPS enrichment
// ============================================================================

async function handleGeofenceAlert(
  alert: any
): Promise<{ entity_type: string; entity_id: number | null }> {
  // Geofence events tell us a vehicle entered/exited a client location
  const vehicle = alert.vehicle ?? alert.data?.vehicle
  const address = alert.address ?? alert.data?.address ?? alert.geofence
  const eventTime = alert.eventTime ?? alert.triggeredAt ?? alert.time

  if (!vehicle?.id || !address?.id) {
    console.warn('Geofence alert missing vehicle or address ID')
    return { entity_type: 'visit', entity_id: null }
  }

  const vehicleId = await findEntityBySourceId('vehicle', 'samsara', String(vehicle.id))
  const clientId = await findEntityBySourceId('client', 'samsara', String(address.id))

  if (!vehicleId || !clientId) {
    return { entity_type: 'visit', entity_id: null }
  }

  // Determine if this is entry or exit
  const isEntry = alert.alertType === 'geofenceEntry' ||
    alert.conditionType === 'insideGeofence' ||
    alert.type?.toLowerCase()?.includes('enter')

  const isExit = alert.alertType === 'geofenceExit' ||
    alert.conditionType === 'outsideGeofence' ||
    alert.type?.toLowerCase()?.includes('exit')

  if (!isEntry && !isExit) {
    return { entity_type: 'visit', entity_id: null }
  }

  // Find the most recent visit for this client + vehicle within +-12h window
  const eventDate = new Date(eventTime)
  const windowStart = new Date(eventDate.getTime() - 12 * 60 * 60 * 1000).toISOString()
  const windowEnd = new Date(eventDate.getTime() + 12 * 60 * 60 * 1000).toISOString()

  const { data: visits } = await supabase
    .from('visits')
    .select('id')
    .eq('client_id', clientId)
    .eq('vehicle_id', vehicleId)
    .gte('start_at', windowStart)
    .lte('start_at', windowEnd)
    .order('start_at', { ascending: false })
    .limit(1)

  if (!visits?.length) {
    // No matching visit — could be unscheduled stop. Log but don't create.
    console.log(`Geofence ${isEntry ? 'entry' : 'exit'} for client ${clientId}, vehicle ${vehicleId} — no matching visit`)
    return { entity_type: 'visit', entity_id: null }
  }

  const visitId = visits[0].id
  const update: Record<string, unknown> = {
    is_gps_confirmed: true,
  }

  if (isEntry) {
    update.actual_arrival_at = eventTime
  } else if (isExit) {
    update.actual_departure_at = eventTime
  }

  await supabase.from('visits').update(update).eq('id', visitId)

  return { entity_type: 'visit', entity_id: visitId }
}

// ============================================================================
// Event type → Handler dispatch
// ============================================================================
async function routeEvent(
  eventType: string,
  event: any
): Promise<{ entity_type: string; entity_id: number | null; extra?: Record<string, unknown> }> {
  const data = event.data ?? event

  switch (eventType) {
    case 'AddressCreated':
      return handleAddress(data.address ?? data, 'created')

    case 'AddressUpdated':
      return handleAddress(data.address ?? data, 'updated')

    case 'AddressDeleted':
      return handleAddress(data.address ?? data, 'deleted')

    case 'DriverCreated':
      return handleDriver(data.driver ?? data, 'created')

    case 'DriverUpdated':
      return handleDriver(data.driver ?? data, 'updated')

    case 'VehicleStatsSnapshot':
    case 'VehicleStatsUpdated':
    case 'vehicleStats': {
      const result = await handleVehicleStats(event)
      return { ...result, extra: { readings: result.readings } }
    }

    case 'AlertTriggered':
    case 'GeofenceEntry':
    case 'GeofenceExit':
      return handleGeofenceAlert(event)

    default:
      console.log(`Unhandled Samsara event type: ${eventType}`)
      return { entity_type: 'unknown', entity_id: null }
  }
}

// ============================================================================
// Main handler
// ============================================================================
Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return badRequest('POST only')
  }

  const startMs = Date.now()
  const rawBody = await req.text()
  let event: any

  try {
    event = JSON.parse(rawBody)
  } catch {
    return badRequest('Invalid JSON')
  }

  // Verify signature (Samsara: HMAC over "v1:<timestamp>:<body>")
  const signature =
    req.headers.get('x-samsara-signature') ??
    req.headers.get('x-webhook-signature')
  const timestamp = req.headers.get('x-samsara-timestamp')
  const valid = await verifySamsaraSignature(rawBody, signature, timestamp)
  if (!valid) {
    await logWebhookEvent(supabase, 'samsara', event.eventType ?? 'unknown', event, {
      status: 'failed',
      error_message: 'Signature verification failed',
      processing_ms: Date.now() - startMs,
    })
    return unauthorized('Invalid signature')
  }

  // Samsara event types can be in different fields
  const eventType =
    event.eventType ?? event.type ?? event.alertType ?? 'unknown'

  try {
    const result = await routeEvent(eventType, event)
    const elapsedMs = Date.now() - startMs

    await logWebhookEvent(supabase, 'samsara', eventType, event, {
      event_id: event.eventId ?? event.id ?? null,
      entity_type: result.entity_type,
      entity_id: result.entity_id ?? undefined,
      status: result.entity_id ? 'processed' : 'skipped',
      processing_ms: elapsedMs,
    })

    return ok({
      processed: !!result.entity_id,
      eventType,
      entity_type: result.entity_type,
      entity_id: result.entity_id,
      ...(result.extra ?? {}),
      ms: elapsedMs,
    })
  } catch (err) {
    const elapsedMs = Date.now() - startMs
    const message = err instanceof Error ? err.message : String(err)
    console.error(`[webhook-samsara] ${eventType} failed:`, message)

    await logWebhookEvent(supabase, 'samsara', eventType, event, {
      status: 'failed',
      error_message: message.slice(0, 1000),
      processing_ms: elapsedMs,
    })

    return serverError(message.slice(0, 200))
  }
})
