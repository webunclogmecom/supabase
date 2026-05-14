// ============================================================================
// webhook-airtable/index.ts — Airtable webhook receiver (Edge Function)
// ============================================================================
// Two supported inbound paths (dispatched by auth header shape):
//
//  Path A — Airtable-native webhook API (legacy / never activated):
//    - Verifies HMAC signature header `x-airtable-content-mac`
//    - Receives `{base, webhook, timestamp}` notification
//    - Fetches cursor-based payloads from Airtable
//    - Kept in place for forward-compat, not currently used in prod
//
//  Path B — Airtable automation "Run script" POST (ACTIVE PATH):
//    - Validates `Authorization: Bearer <AIRTABLE_WEBHOOK_TOKEN>` header
//    - Expects body: {entity, recordId, fields, changeType}
//    - Routes directly to the right handler (no cursor fetch — the script
//      already serialized the record's fields for us)
//    - Each watched Airtable table has one automation ("when record
//      created or updated") that POSTs here via Run Script action
//
// Tables we watch:
//   - Clients       → service_configs (GT/CL/WD frequencies, pricing)
//   - DERM          → derm_manifests
//   - Route Creation→ routes + route_stops
//   - Past Due      → receivables
//
// Airtable sunsets May 2026 — this is a data harvest bridge.
// ============================================================================

import { supabase } from '../_shared/supabase-client.ts'
import { upsertEntityLink, findEntityBySourceId } from '../_shared/entity-links.ts'
import { ok, badRequest, unauthorized, serverError, logWebhookEvent } from '../_shared/responses.ts'

// ---- Config ----
const AIRTABLE_API = 'https://api.airtable.com/v0'
const BASE_ID = Deno.env.get('AIRTABLE_BASE_ID') ?? ''
const API_KEY = Deno.env.get('AIRTABLE_API_KEY') ?? ''

// ---- Table ID → handler mapping ----
// These IDs are set after webhook registration; update with actual table IDs.
// Use register-airtable.js to discover them.
const TABLE_HANDLERS: Record<string, string> = {
  // 'tblXXXXXX': 'clients',
  // 'tblXXXXXX': 'derm',
  // 'tblXXXXXX': 'routes',
  // 'tblXXXXXX': 'past_due',
}

// ---- HMAC verification (Airtable uses base64-encoded HMAC-SHA256) ----
async function verifyAirtableSignature(body: string, signature: string | null): Promise<boolean> {
  const secret = Deno.env.get('AIRTABLE_WEBHOOK_SECRET')
  if (!secret) {
    console.warn('AIRTABLE_WEBHOOK_SECRET not set — skipping verification')
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
  const computed = btoa(String.fromCharCode(...new Uint8Array(sig)))
  return computed === signature
}

// ---- Fetch cursor-based payloads from Airtable ----
interface AirtablePayload {
  cursor: number
  mightHaveMore: boolean
  payloads: Array<{
    timestamp: string
    baseTransactionNumber: number
    changedTablesById: Record<
      string,
      {
        changedRecordsById?: Record<string, { current: { cellValuesByFieldId: Record<string, unknown> } }>
        createdRecordsById?: Record<string, { cellValuesByFieldId: Record<string, unknown> }>
        destroyedRecordIds?: string[]
      }
    >
  }>
}

async function fetchPayloads(webhookId: string, cursor?: number): Promise<AirtablePayload> {
  const url = new URL(`${AIRTABLE_API}/bases/${BASE_ID}/webhooks/${webhookId}/payloads`)
  if (cursor !== undefined) url.searchParams.set('cursor', String(cursor))

  const resp = await fetch(url.toString(), {
    headers: { Authorization: `Bearer ${API_KEY}` },
  })
  if (!resp.ok) {
    const text = await resp.text()
    throw new Error(`Airtable payload fetch ${resp.status}: ${text.slice(0, 300)}`)
  }
  return resp.json()
}

// ---- Fetch full record from Airtable (for created/changed records) ----
async function fetchRecord(tableIdOrName: string, recordId: string): Promise<any> {
  const resp = await fetch(`${AIRTABLE_API}/${BASE_ID}/${tableIdOrName}/${recordId}`, {
    headers: { Authorization: `Bearer ${API_KEY}` },
  })
  if (!resp.ok) {
    const text = await resp.text()
    throw new Error(`Airtable record fetch ${resp.status}: ${text.slice(0, 300)}`)
  }
  return resp.json()
}

// ============================================================================
// Record Handlers — one per watched Airtable table
// ============================================================================

function fieldVal(fields: Record<string, unknown>, name: string): unknown {
  return fields[name] ?? null
}

function strVal(fields: Record<string, unknown>, name: string): string | null {
  const v = fields[name]
  if (v === null || v === undefined) return null
  // Airtable single-select / single-collaborator fields arrive as
  //   { id, name, color }   (since ~2026 — used to be plain strings).
  // Multi-select fields arrive as an array of those objects. Pick the
  // human-readable `name`. String(obj) → "[object Object]" otherwise.
  if (typeof v === 'object') {
    const obj = v as Record<string, unknown>
    if (Array.isArray(v)) {
      const first = (v as unknown[])[0]
      if (first && typeof first === 'object' && 'name' in (first as Record<string, unknown>)) {
        return String((first as Record<string, unknown>).name).trim() || null
      }
      return v.length ? String(v[0]).trim() || null : null
    }
    if ('name' in obj && typeof obj.name === 'string') return obj.name.trim() || null
  }
  return String(v).trim() || null
}

function numVal(fields: Record<string, unknown>, name: string): number | null {
  const v = fields[name]
  if (v === null || v === undefined || v === '') return null
  const n = Number(v)
  return isFinite(n) ? n : null
}

function dateVal(fields: Record<string, unknown>, name: string): string | null {
  const v = fields[name]
  if (!v) return null
  return String(v).slice(0, 10)
}

// ---- Clients table → clients + properties + service_configs ----
//
// Field-name + behavior fixes 2026-05-13 (Fred's audit found 307 drift rows
// across 145 fields because this handler was reading non-existent AT field
// names, skipping clients.status entirely, and never touching access_hours).
// The Airtable schema actually exposes:
//   "GT Frequency", "CL Frequency", "WD Frequency"          (all in DAYS)
//   "GT $ per Visit", "CL$ Price per Visit", "WD$ Price per Visit"
//   "Client Code #3"            (formula, not "Client Code")
//   "GDO Number", "GDO expiration date"
//   "Size GT in Gallon"
//   "ACTIVE/INACTIVE", "Service Type" (multiSelect — canonical for subscriptions)
//   "Hours in", "Hours out", "Days of the week"             (access window)
// We also normalize the "Recuring" typo on status to "RECURRING".
async function handleClientRecord(recordId: string, fields: Record<string, unknown>): Promise<void> {
  let clientId = await findEntityBySourceId('client', 'airtable', recordId)

  // Fallback for new AT records: when a client first lands in Sbx via the
  // Jobber path (cron_jobber → webhook-jobber), it has a `client_code` but
  // no AT ESL link yet. The next AT event for that client would otherwise
  // be silently dropped here, leaving its service_configs / status / access
  // hours unsynced indefinitely. Match by Client Code #3 and lazily create
  // the AT ESL link so subsequent updates take the fast path.
  const code = strVal(fields, 'Client Code #3')
  if (!clientId && code) {
    const { data: byCode } = await supabase
      .from('clients').select('id')
      .eq('client_code', code).limit(1)
    if (byCode?.length) {
      clientId = byCode[0].id as number
      await upsertEntityLink('client', clientId, 'airtable', recordId)
      console.log(`[handleClient] linked AT ${recordId} → client ${clientId} via client_code ${code}`)
    }
  }

  if (!clientId) {
    console.warn(`No client linked to Airtable record ${recordId} — skipping`)
    return
  }

  // -- 1. Update client-level fields (status + client_code) ---------------
  const clientUpdate: Record<string, unknown> = {}
  if (code) clientUpdate.client_code = code
  let status = strVal(fields, 'ACTIVE/INACTIVE')
  if (status) {
    status = status.toUpperCase().trim()
    if (status === 'RECURING') status = 'RECURRING'
    clientUpdate.status = status
  }
  if (Object.keys(clientUpdate).length) {
    await supabase.from('clients').update(clientUpdate).eq('id', clientId)
  }

  // -- 2. Update primary property (access window + zone + county + manholes) ----
  const propUpdate: Record<string, unknown> = {}
  const hin = strVal(fields, 'Hours in');   if (hin)  propUpdate.access_hours_start = hin
  const hout = strVal(fields, 'Hours out'); if (hout) propUpdate.access_hours_end   = hout
  const zone = strVal(fields, 'Zone');      if (zone) propUpdate.zone = zone
  const county = strVal(fields, 'County');  if (county) propUpdate.county = county
  const manholesRaw = numVal(fields, 'manholes')
  if (manholesRaw != null && manholesRaw >= 0) propUpdate.grease_trap_manhole_count = Math.round(manholesRaw)
  // Days of the week — multipleSelects → array of {id,name} → text[] of short names
  const daysRaw = fields['Days of the week']
  if (Array.isArray(daysRaw)) {
    const days = daysRaw.map((d: unknown) => {
      const name = (d && typeof d === 'object' && 'name' in (d as Record<string, unknown>))
        ? (d as Record<string, unknown>).name as string
        : String(d)
      return String(name).toLowerCase().slice(0, 3)
    }).filter(Boolean)
    if (days.length) propUpdate.access_days = days
  }
  if (Object.keys(propUpdate).length) {
    const { data: props } = await supabase
      .from('properties').select('id')
      .eq('client_id', clientId).eq('is_primary', true).limit(1)
    if (props?.length) {
      await supabase.from('properties').update(propUpdate).eq('id', props[0].id)
    }
  }

  // -- 3. Service-config rows — ONLY for services the client subscribes to ----
  // Service Type multi-select is canonical (per memory rule and audit
  // 2026-05-13: GT/CL/WD Frequency fields can carry junk values for clients
  // who don't actually subscribe, e.g. 021-GRA had GT Frequency=360 even
  // though Service Type was just [CL, WD]).
  const serviceTypeRaw = fields['Service Type']
  const subscribedTypes = new Set<string>()
  if (Array.isArray(serviceTypeRaw)) {
    for (const v of serviceTypeRaw) {
      const name = (v && typeof v === 'object' && 'name' in (v as Record<string, unknown>))
        ? String((v as Record<string, unknown>).name).toLowerCase()
        : String(v).toLowerCase()
      if (name.includes('grease trap') || name === 'gt') subscribedTypes.add('GT')
      else if (name.includes('main cl') || name.includes('cleaning') || name === 'cl') subscribedTypes.add('CL')
      else if (name === 'wd' || name.includes('warranty') || name.includes('water dis')) subscribedTypes.add('WD')
      else if (name.includes('lyft')) subscribedTypes.add('LS')
    }
  }

  // AT field names per service (verified against schema 2026-05-13)
  const SVC_FIELDS: Record<string, { freq: string; price: string }> = {
    GT: { freq: 'GT Frequency',  price: 'GT $ per Visit' },
    CL: { freq: 'CL Frequency',  price: 'CL$ Price per Visit' },
    WD: { freq: 'WD Frequency',  price: 'WD$ Price per Visit' },
  }
  for (const type of ['GT', 'CL', 'WD']) {
    if (!subscribedTypes.has(type)) continue
    const f = SVC_FIELDS[type]
    const row: Record<string, unknown> = {
      client_id: clientId,
      service_type: type,
      frequency_days: numVal(fields, f.freq),
      price_per_visit: numVal(fields, f.price),
    }
    const { error } = await supabase.from('service_configs')
      .upsert(row, { onConflict: 'client_id,service_type' })
    if (error) console.error(`service_configs upsert failed for ${type}:`, error.message)
  }

  // -- 4. GDO permit (GT only) ----
  const gdo = strVal(fields, 'GDO Number')
  const gdoExp = dateVal(fields, 'GDO expiration date')
  if (gdo || gdoExp) {
    const permitUpdate: Record<string, unknown> = {}
    if (gdo) permitUpdate.permit_number = gdo
    if (gdoExp) permitUpdate.permit_expiration = gdoExp
    await supabase.from('service_configs').update(permitUpdate)
      .eq('client_id', clientId).eq('service_type', 'GT')
  }

  // -- 5. GT tank size ----
  const gtSize = numVal(fields, 'Size GT in Gallon')
  if (gtSize) {
    await supabase
      .from('service_configs')
      .update({ equipment_size_gallons: gtSize })
      .eq('client_id', clientId)
      .eq('service_type', 'GT')
  }
}

// ---- DERM table → derm_manifests ----
//
// Field-name fixes 2026-05-13: AT DERM schema actually exposes:
//   "Date Dump Ticket"            (date — when waste was disposed)
//   "GT Last Visit"               (date — when the GT service happened)
//   "White Manifest #"            (singleLineText)
//   "Yellow Ticket #"             (singleLineText)
//   "Send To Client" (capital To) (checkbox)
//   "Send To City"   (capital To) (checkbox)
//   "Client Name (from Client)"   (lookup, parens in the field name)
async function handleDermRecord(recordId: string, fields: Record<string, unknown>): Promise<void> {
  const clientName = strVal(fields, 'Client Name (from Client)') ?? strVal(fields, 'Client Name')
  const existingId = await findEntityBySourceId('derm_manifest', 'airtable', recordId)

  const row: Record<string, unknown> = {
    service_date: dateVal(fields, 'Date Dump Ticket') ?? dateVal(fields, 'GT Last Visit'),
    dump_ticket_date: dateVal(fields, 'Date Dump Ticket'),
    white_manifest_number: strVal(fields, 'White Manifest #'),
    yellow_ticket_number: strVal(fields, 'Yellow Ticket #'),
    sent_to_client: fields['Send To Client'] === true,
    sent_to_city: fields['Send To City'] === true,
  }

  // Resolve client_id
  if (clientName) {
    const { data: clients } = await supabase
      .from('clients')
      .select('id')
      .ilike('name', `%${clientName}%`)
      .limit(1)
    if (clients?.length) row.client_id = clients[0].id
  }

  let entityId: number

  if (existingId) {
    const { error } = await supabase.from('derm_manifests').update(row).eq('id', existingId)
    if (error) throw new Error(`DERM update failed: ${error.message}`)
    entityId = existingId
  } else {
    const { data: inserted, error } = await supabase
      .from('derm_manifests')
      .insert(row)
      .select('id')
      .single()
    if (error || !inserted) throw new Error(`DERM insert failed: ${error?.message}`)
    entityId = inserted.id
  }

  await upsertEntityLink({
    entity_type: 'derm_manifest',
    entity_id: entityId,
    source_system: 'airtable',
    source_id: recordId,
    match_method: 'webhook',
  })
}

// ---- Route Creation → routes + route_stops ----
async function handleRouteRecord(recordId: string, fields: Record<string, unknown>): Promise<void> {
  const existingId = await findEntityBySourceId('route', 'airtable', recordId)

  // v2 routes: route_date, status, assignee, zone, vehicle_id, employee_id, notes
  const row: Record<string, unknown> = {
    route_date: dateVal(fields, 'Date') ?? dateVal(fields, 'Route Date'),
    zone: strVal(fields, 'Zone') ?? strVal(fields, 'Route Name') ?? strVal(fields, 'Name'),
    notes: strVal(fields, 'Notes'),
    status: strVal(fields, 'Status') ?? 'planned',
    assignee: strVal(fields, 'Assignee'),
  }

  // Resolve vehicle from truck name
  const truckName = strVal(fields, 'Truck') ?? strVal(fields, 'Vehicle')
  if (truckName) {
    const { data: vehicles } = await supabase
      .from('vehicles')
      .select('id')
      .ilike('name', `%${truckName}%`)
      .limit(1)
    if (vehicles?.length) row.vehicle_id = vehicles[0].id
  }

  let entityId: number

  if (existingId) {
    const { error } = await supabase.from('routes').update(row).eq('id', existingId)
    if (error) throw new Error(`Route update failed: ${error.message}`)
    entityId = existingId
  } else {
    const { data: inserted, error } = await supabase
      .from('routes')
      .insert(row)
      .select('id')
      .single()
    if (error || !inserted) throw new Error(`Route insert failed: ${error?.message}`)
    entityId = inserted.id
  }

  await upsertEntityLink({
    entity_type: 'route',
    entity_id: entityId,
    source_system: 'airtable',
    source_id: recordId,
    match_method: 'webhook',
  })
}

// ---- Past Due → receivables ----
async function handleReceivableRecord(recordId: string, fields: Record<string, unknown>): Promise<void> {
  const existingId = await findEntityBySourceId('receivable', 'airtable', recordId)

  // v2 receivables: amount_due, status, assignee, notes
  const row: Record<string, unknown> = {
    amount_due: numVal(fields, 'Amount') ?? numVal(fields, 'Balance'),
    notes: strVal(fields, 'Notes'),
    status: strVal(fields, 'Status') ?? 'open',
    assignee: strVal(fields, 'Assignee'),
  }

  // Resolve client
  const clientName = strVal(fields, 'Client') ?? strVal(fields, 'Client Name')
  if (clientName) {
    const { data: clients } = await supabase
      .from('clients')
      .select('id')
      .ilike('name', `%${clientName}%`)
      .limit(1)
    if (clients?.length) row.client_id = clients[0].id
  }

  let entityId: number

  if (existingId) {
    const { error } = await supabase.from('receivables').update(row).eq('id', existingId)
    if (error) throw new Error(`Receivable update failed: ${error.message}`)
    entityId = existingId
  } else {
    const { data: inserted, error } = await supabase
      .from('receivables')
      .insert(row)
      .select('id')
      .single()
    if (error || !inserted) throw new Error(`Receivable insert failed: ${error?.message}`)
    entityId = inserted.id
  }

  await upsertEntityLink({
    entity_type: 'receivable',
    entity_id: entityId,
    source_system: 'airtable',
    source_id: recordId,
    match_method: 'webhook',
  })
}

async function handleInspectionRecord(recordId: string, fields: Record<string, unknown>): Promise<void> {
  // Airtable "PRE-POST insptection" table → public.inspections
  // Columns we care about:
  //   Date (datetime)                 → shift_date + submitted_at
  //   Pre/Post (text)                 → inspection_type ('PRE' | 'POST')
  //   Driver (text name)              → employee_id (resolved by full_name ilike)
  //   Truck (text name)               → vehicle_id (resolved by name ilike)
  //   SLUDGE Tank level (number)      → sludge_gallons
  //   Gas Level (text — '1/4' etc.)   → gas_level
  // Photo attachment fields are present but we don't process them here — that
  // runs through a separate photos+photo_links migration pass (ADR 009).
  const dateRaw = fields['Date']
  const shift_date = typeof dateRaw === 'string' ? dateRaw.slice(0, 10) : null
  if (!shift_date) {
    console.warn(`Inspection ${recordId} has no Date — skipping`)
    return
  }

  const rawType = strVal(fields, 'Pre/Post')?.toUpperCase()
  const inspection_type = rawType?.startsWith('PRE') ? 'PRE' : rawType?.startsWith('POST') ? 'POST' : null
  if (!inspection_type) {
    console.warn(`Inspection ${recordId} has unrecognized Pre/Post='${rawType}' — skipping`)
    return
  }

  // Resolve vehicle by Truck name. AT sends "Moises 9,000" / "David 2,000" /
  // "Cloggy 120" / "Goliath 5,000" — vehicles.name is just "Moises"/"David"/
  // "Cloggy"/"Goliath". Strip everything after the first word so the ILIKE
  // matches. Caught 2026-05-13: 276/276 inspections had NULL vehicle_id
  // because of the unstripped comparison.
  let vehicle_id: number | null = null
  const truckRaw = strVal(fields, 'Truck')
  const truckName = truckRaw ? truckRaw.split(/[\s,]/)[0] : null
  if (truckName) {
    const { data: v } = await supabase.from('vehicles').select('id').ilike('name', truckName).limit(1)
    if (v?.length) vehicle_id = v[0].id
  }

  // Resolve employee by Driver name
  let employee_id: number | null = null
  const driverName = strVal(fields, 'Driver')
  if (driverName) {
    const { data: e } = await supabase.from('employees').select('id').ilike('full_name', `%${driverName}%`).limit(1)
    if (e?.length) employee_id = e[0].id
  }

  const row: Record<string, unknown> = {
    shift_date,
    inspection_type,
    submitted_at: typeof dateRaw === 'string' ? dateRaw : null,
    sludge_gallons: Math.round(numVal(fields, 'SLUDGE Tank level') ?? 0) || null,
    water_gallons:  Math.round(numVal(fields, 'WATER Tank level')  ?? 0) || null,
    gas_level: strVal(fields, 'Gas Level'),
  }
  if (vehicle_id)  row.vehicle_id = vehicle_id
  if (employee_id) row.employee_id = employee_id

  const existingId = await findEntityBySourceId('inspection', 'airtable', recordId)
  let entityId: number
  if (existingId) {
    const { error } = await supabase.from('inspections').update(row).eq('id', existingId)
    if (error) throw new Error(`Inspection update failed: ${error.message}`)
    entityId = existingId
  } else {
    const { data: inserted, error } = await supabase.from('inspections').insert(row).select('id').single()
    if (error || !inserted) throw new Error(`Inspection insert failed: ${error?.message}`)
    entityId = inserted.id
  }

  await upsertEntityLink({
    entity_type: 'inspection',
    entity_id: entityId,
    source_system: 'airtable',
    source_id: recordId,
    match_method: 'webhook',
  })
}

// ---- Table handler dispatcher ----
const RECORD_HANDLERS: Record<string, (recordId: string, fields: Record<string, unknown>) => Promise<void>> = {
  clients: handleClientRecord,
  derm: handleDermRecord,
  routes: handleRouteRecord,
  past_due: handleReceivableRecord,
  inspections: handleInspectionRecord,
}

// ============================================================================
// Process a single Airtable webhook payload
// ============================================================================
async function processPayload(payload: any): Promise<{ processed: number; errors: number }> {
  let processed = 0
  let errors = 0

  const changedTables = payload.changedTablesById ?? {}

  for (const [tableId, changes] of Object.entries(changedTables) as Array<[string, any]>) {
    const handlerName = TABLE_HANDLERS[tableId]
    if (!handlerName) {
      console.log(`Skipping unregistered table ${tableId}`)
      continue
    }

    const handler = RECORD_HANDLERS[handlerName]
    if (!handler) continue

    // Process created records
    if (changes.createdRecordsById) {
      for (const [recordId, record] of Object.entries(changes.createdRecordsById) as Array<[string, any]>) {
        try {
          // Fetch full record (created records in webhook only have field IDs, not names)
          const fullRecord = await fetchRecord(tableId, recordId)
          await handler(recordId, fullRecord.fields ?? {})
          processed++
        } catch (e) {
          console.error(`Error processing created record ${recordId}:`, e)
          errors++
        }
      }
    }

    // Process changed records
    if (changes.changedRecordsById) {
      for (const [recordId, _record] of Object.entries(changes.changedRecordsById)) {
        try {
          // Fetch full record to get field names (webhook only sends field IDs)
          const fullRecord = await fetchRecord(tableId, recordId)
          await handler(recordId, fullRecord.fields ?? {})
          processed++
        } catch (e) {
          console.error(`Error processing changed record ${recordId}:`, e)
          errors++
        }
      }
    }

    // Process destroyed records (mark as deleted/inactive — we don't hard-delete)
    if (changes.destroyedRecordIds) {
      for (const recordId of changes.destroyedRecordIds) {
        try {
          // Find the entity and mark it as deleted
          const link = await supabase
            .from('entity_source_links')
            .select('entity_type, entity_id')
            .eq('source_system', 'airtable')
            .eq('source_id', recordId)
            .maybeSingle()

          if (link.data) {
            // Soft-delete: update status to indicate deletion from Airtable
            const table = link.data.entity_type === 'derm_manifest' ? 'derm_manifests' : `${link.data.entity_type}s`
            await supabase
              .from(table)
              .update({ notes: `[Deleted from Airtable ${new Date().toISOString().slice(0, 10)}]` })
              .eq('id', link.data.entity_id)
          }
          processed++
        } catch (e) {
          console.error(`Error processing destroyed record ${recordId}:`, e)
          errors++
        }
      }
    }
  }

  return { processed, errors }
}

// ============================================================================
// Path B handler — Airtable automation "Run script" POST
// ============================================================================
//
// Payload shape (assembled by the automation script — template in
// docs/airtable-automation-setup.md):
//   {
//     "entity": "client" | "derm_manifest" | "route" | "receivable",
//     "recordId": "recXXXX",
//     "fields": { ...record fields keyed by field NAME (not id)... },
//     "changeType": "created" | "updated" | "destroyed"
//   }
//
// Maps `entity` to the existing RECORD_HANDLERS and passes the pre-
// serialized fields through. No cursor fetch needed — the automation
// already had the record in hand.

const ENTITY_TO_HANDLER: Record<string, string> = {
  'client': 'clients',
  'derm_manifest': 'derm',
  'route': 'routes',
  'receivable': 'past_due',
  'inspection': 'inspections',
}

async function handleAutomationRequest(payload: any, startMs: number): Promise<Response> {
  const entity = payload.entity as string | undefined
  const recordId = payload.recordId as string | undefined
  const fields = (payload.fields ?? {}) as Record<string, unknown>
  const changeType = (payload.changeType ?? 'updated') as string

  if (!entity || !recordId) {
    return badRequest('Missing entity or recordId in payload')
  }

  // Soft-delete path — unlinks and marks deleted without caring about handler
  if (changeType === 'destroyed') {
    try {
      const { data: link } = await supabase
        .from('entity_source_links')
        .select('entity_type, entity_id')
        .eq('source_system', 'airtable')
        .eq('source_id', recordId)
        .maybeSingle()

      if (link) {
        const table = link.entity_type === 'derm_manifest' ? 'derm_manifests' : `${link.entity_type}s`
        await supabase
          .from(table)
          .update({ notes: `[Deleted from Airtable ${new Date().toISOString().slice(0, 10)}]` })
          .eq('id', link.entity_id)
      }

      await logWebhookEvent(supabase, 'airtable', `automation_${entity}`, payload, {
        event_id: recordId,
        status: 'processed',
        processing_ms: Date.now() - startMs,
      })
      return ok({ processed: true, entity, recordId, changeType: 'destroyed' })
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      await logWebhookEvent(supabase, 'airtable', `automation_${entity}`, payload, {
        event_id: recordId,
        status: 'failed',
        error_message: msg.slice(0, 1000),
        processing_ms: Date.now() - startMs,
      })
      return serverError(msg.slice(0, 200))
    }
  }

  // Route to handler
  const handlerKey = ENTITY_TO_HANDLER[entity]
  if (!handlerKey) {
    await logWebhookEvent(supabase, 'airtable', `automation_${entity}`, payload, {
      event_id: recordId,
      status: 'skipped',
      error_message: `No handler registered for entity '${entity}'. Payload captured for future handler work.`,
      processing_ms: Date.now() - startMs,
    })
    return ok({ skipped: true, reason: `no handler for ${entity}` })
  }

  const handler = RECORD_HANDLERS[handlerKey]
  if (!handler) {
    return serverError(`Handler key '${handlerKey}' maps to missing function`)
  }

  try {
    await handler(recordId, fields)
    await logWebhookEvent(supabase, 'airtable', `automation_${entity}`, payload, {
      event_id: recordId,
      status: 'processed',
      processing_ms: Date.now() - startMs,
    })
    return ok({ processed: true, entity, recordId })
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    console.error(`[webhook-airtable] handler(${entity}, ${recordId}) failed:`, msg)
    await logWebhookEvent(supabase, 'airtable', `automation_${entity}`, payload, {
      event_id: recordId,
      status: 'failed',
      error_message: msg.slice(0, 1000),
      processing_ms: Date.now() - startMs,
    })
    return serverError(msg.slice(0, 200))
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
  let notification: any

  try {
    notification = JSON.parse(rawBody)
  } catch {
    return badRequest('Invalid JSON')
  }

  // ---- Path B: Bearer token auth (Airtable automation Run-script POSTs) ----
  // Check this FIRST because it's the active path and has a distinct header
  // shape from Airtable's native HMAC webhook flow.
  const authHeader = req.headers.get('authorization')
  if (authHeader?.toLowerCase().startsWith('bearer ')) {
    const token = authHeader.slice(7).trim()
    const expected = Deno.env.get('AIRTABLE_WEBHOOK_TOKEN')
    if (!expected) {
      console.warn('AIRTABLE_WEBHOOK_TOKEN not set — rejecting Bearer auth')
      return unauthorized('Bearer auth not configured on server')
    }
    if (token !== expected) {
      await logWebhookEvent(supabase, 'airtable', 'automation_unauthed', notification, {
        status: 'failed',
        error_message: 'Invalid bearer token',
        processing_ms: Date.now() - startMs,
      })
      return unauthorized('Invalid bearer token')
    }
    return handleAutomationRequest(notification, startMs)
  }

  // ---- Path A: Airtable-native HMAC webhook flow ----
  const signature = req.headers.get('x-airtable-content-mac')
  const valid = await verifyAirtableSignature(rawBody, signature)
  if (!valid) {
    await logWebhookEvent(supabase, 'airtable', 'notification', notification, {
      status: 'failed',
      error_message: 'Signature verification failed',
      processing_ms: Date.now() - startMs,
    })
    return unauthorized('Invalid signature')
  }

  const webhookId = notification.webhook?.id
  if (!webhookId) {
    return badRequest('Missing webhook ID')
  }

  // Respond quickly (Airtable expects fast ACK), then process
  // Note: Edge Functions are synchronous, so we process inline.
  // For production scale, consider a queue pattern.

  try {
    let totalProcessed = 0
    let totalErrors = 0
    let cursor: number | undefined

    // Fetch all payloads (may require multiple pages)
    let hasMore = true
    while (hasMore) {
      const result = await fetchPayloads(webhookId, cursor)

      for (const payload of result.payloads) {
        const { processed, errors } = await processPayload(payload)
        totalProcessed += processed
        totalErrors += errors
      }

      cursor = result.cursor
      hasMore = result.mightHaveMore
    }

    const elapsedMs = Date.now() - startMs

    await logWebhookEvent(supabase, 'airtable', 'notification', notification, {
      event_id: webhookId,
      status: totalErrors > 0 ? 'partial' : 'processed',
      processing_ms: elapsedMs,
      error_message: totalErrors > 0 ? `${totalErrors} record(s) failed` : undefined,
    })

    return ok({ processed: totalProcessed, errors: totalErrors, ms: elapsedMs })
  } catch (err) {
    const elapsedMs = Date.now() - startMs
    const message = err instanceof Error ? err.message : String(err)
    console.error('[webhook-airtable] Processing failed:', message)

    await logWebhookEvent(supabase, 'airtable', 'notification', notification, {
      event_id: webhookId,
      status: 'failed',
      error_message: message.slice(0, 1000),
      processing_ms: elapsedMs,
    })

    return serverError(message.slice(0, 200))
  }
})
