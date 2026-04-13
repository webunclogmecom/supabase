// ============================================================================
// webhook-samsara/index.ts — Samsara webhook receiver (Edge Function)
// ============================================================================
// PERMANENT INTEGRATION — Samsara is the only source that stays after May 2026.
//
// Handles:
//   - AddressCreated/Updated/Deleted → clients/properties GPS + geofence
//   - DriverCreated/Updated → employees
//   - VehicleStatsSnapshot → vehicle_fuel_readings (3NF time-series)
//   - AlertTriggered (geofence) → visits GPS enrichment
//
// Samsara sends full payloads (not thin notifications like Jobber).
// ============================================================================

import { supabase } from '../_shared/supabase-client.ts'
import { upsertEntityLink, findEntityBySourceId, buildSourceMap } from '../_shared/entity-links.ts'
import { ok, badRequest, unauthorized, serverError, logWebhookEvent } from '../_shared/responses.ts'

// ---- HMAC verification ----
async function verifySamsaraSignature(body: string, signature: string | null): Promise<boolean> {
  const secret = Deno.env.get('SAMSARA_WEBHOOK_SECRET')
  if (!secret) {
    console.warn('SAMSARA_WEBHOOK_SECRET not set — skipping verification')
    return true
  }
  if (!signature) return false

  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  )
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body))
  const computed = Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
  // Samsara may send hex or base64 — compare both
  return computed === signature || btoa(String.fromCharCode(...new Uint8Array(sig))) === signature
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

async function handleDriver(
  driver: any,
  action: 'created' | 'updated'
): Promise<{ entity_type: string; entity_id: number }> {
  const samsaraId = String(driver.id)
  const name = driver.name ?? `${driver.firstName ?? ''} ${driver.lastName ?? ''}`.trim()

  let empId = await findEntityBySourceId('employee', 'samsara', samsaraId)

  // v2 employees: full_name, role, status, shift, email, phone, hire_date, notes, access_level
  const empRow: Record<string, unknown> = {
    full_name: name || null,
    phone: driver.phone ?? null,
    email: driver.email ?? null,
  }

  if (empId) {
    const { error } = await supabase.from('employees').update(empRow).eq('id', empId)
    if (error) throw new Error(`Employee update failed: ${error.message}`)
  } else {
    // New driver — determine access level
    const officeStaff = ['yannick', 'aaron', 'diego']
    const isOffice = officeStaff.some((n) => name.toLowerCase().includes(n))

    empRow.status = 'ACTIVE'
    empRow.role = isOffice ? 'Office Manager' : 'Technician'
    empRow.access_level = isOffice ? 'office' : 'field'

    const { data: inserted, error } = await supabase
      .from('employees')
      .insert(empRow)
      .select('id')
      .single()
    if (error || !inserted) throw new Error(`Employee insert failed: ${error?.message}`)
    empId = inserted.id
  }

  await upsertEntityLink({
    entity_type: 'employee',
    entity_id: empId!,
    source_system: 'samsara',
    source_id: samsaraId,
    source_name: name,
    match_method: action === 'created' ? 'webhook_new' : 'webhook_update',
  })

  return { entity_type: 'employee', entity_id: empId! }
}

// ============================================================================
// Vehicle Stats → vehicle_fuel_readings (3NF time-series)
// ============================================================================

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

  // Get tank capacity for gallons calculation
  const { data: veh } = await supabase
    .from('vehicles')
    .select('tank_capacity_gallons')
    .eq('id', vehicleId)
    .single()

  const tankCapacity = veh?.tank_capacity_gallons ?? null

  // Extract fuel data — Samsara may send it in various formats
  const stats = event.data?.stats ?? event.stats ?? []
  const fuelStat = stats.find?.((s: any) => s.type === 'fuelPercent') ?? event.data?.fuelPercent ?? event.fuelPercent
  const odometerStat = stats.find?.((s: any) =>
    s.type === 'obdOdometerMeters' || s.type === 'odometerMeters'
  ) ?? event.data?.obdOdometerMeters ?? event.data?.odometerMeters
  const engineStat = stats.find?.((s: any) => s.type === 'engineState') ?? event.data?.engineState

  // If no fuel data in this event, skip
  const fuelPercent = typeof fuelStat === 'object' ? fuelStat?.value : fuelStat
  const fuelTime = typeof fuelStat === 'object' ? fuelStat?.time : event.eventTime
  const odometerValue = typeof odometerStat === 'object' ? odometerStat?.value : odometerStat
  const engineValue = typeof engineStat === 'object' ? engineStat?.value : engineStat

  if (fuelPercent === null || fuelPercent === undefined) {
    console.log(`VehicleStats for ${vehicle.name}: no fuel data in this event`)
    return { entity_type: 'vehicle', entity_id: vehicleId, readings: 0 }
  }

  // Compute gallons from percent + tank capacity
  const fuelGallons =
    tankCapacity !== null && fuelPercent !== null
      ? Math.round((Number(fuelPercent) * Number(tankCapacity)) / 100 * 100) / 100
      : null

  // Insert fuel reading (append-only, never update)
  const { error } = await supabase.from('vehicle_fuel_readings').insert({
    vehicle_id: vehicleId,
    fuel_percent: Number(fuelPercent),
    fuel_gallons: fuelGallons,
    odometer_meters: odometerValue ? Number(odometerValue) : null,
    engine_state: engineValue ?? null,
    recorded_at: fuelTime ?? new Date().toISOString(),
  })

  if (error) {
    console.error(`Fuel reading insert failed for vehicle ${vehicleId}:`, error.message)
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

  // Verify signature
  const signature =
    req.headers.get('x-samsara-signature') ??
    req.headers.get('x-webhook-signature')
  const valid = await verifySamsaraSignature(rawBody, signature)
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
