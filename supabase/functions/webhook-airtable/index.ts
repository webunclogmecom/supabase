// ============================================================================
// webhook-airtable/index.ts — Airtable webhook receiver (Edge Function)
// ============================================================================
// Airtable Webhooks API flow:
//   1. Register webhook (one-time, via register-airtable.js script)
//   2. Receive POST notification: { base, webhook, timestamp }
//   3. Fetch cursor-based payloads from Airtable API
//   4. Process changed records → upsert to v2 tables
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

// ---- Clients table → service_configs ----
async function handleClientRecord(recordId: string, fields: Record<string, unknown>): Promise<void> {
  // Find linked client via entity_source_links
  const clientId = await findEntityBySourceId('client', 'airtable', recordId)
  if (!clientId) {
    console.warn(`No client linked to Airtable record ${recordId} — skipping service_configs update`)
    return
  }

  // Airtable frequency fields: GT in MONTHS, CL in MONTHS, WD in DAYS
  const serviceTypes = [
    {
      type: 'GT',
      freq: numVal(fields, 'Grease Trap Frequency'),
      freqMultiplier: 30, // months → days
      price: numVal(fields, 'Grease Trap Price'),
      lastVisit: dateVal(fields, 'GT Last Visit'),
    },
    {
      type: 'CL',
      freq: numVal(fields, 'Cleaning Frequency'),
      freqMultiplier: 30,
      price: numVal(fields, 'Cleaning Price'),
      lastVisit: dateVal(fields, 'CL Last Visit'),
    },
    {
      type: 'WD',
      freq: numVal(fields, 'Water Drain Frequency'),
      freqMultiplier: 1, // already in days
      price: numVal(fields, 'Water Drain Price'),
      lastVisit: dateVal(fields, 'WD Last Visit'),
    },
  ]

  for (const svc of serviceTypes) {
    if (!svc.freq && !svc.price) continue // No data for this service type

    const row: Record<string, unknown> = {
      client_id: clientId,
      service_type: svc.type,
      frequency_days: svc.freq ? svc.freq * svc.freqMultiplier : null,
      price_per_visit: svc.price,
      last_visit: svc.lastVisit,
    }

    const { error } = await supabase
      .from('service_configs')
      .upsert(row, { onConflict: 'client_id,service_type' })

    if (error) console.error(`service_configs upsert failed for ${svc.type}:`, error.message)
  }

  // v2: zone/county live on properties, GDO permit on service_configs, client_code on clients
  const clientCode = strVal(fields, 'Client Code')
  if (clientCode) {
    await supabase.from('clients').update({ client_code: clientCode }).eq('id', clientId)
  }

  // Update zone + county on primary property
  const zone = strVal(fields, 'Zone')
  const county = strVal(fields, 'County')
  if (zone || county) {
    const { data: props } = await supabase
      .from('properties')
      .select('id')
      .eq('client_id', clientId)
      .eq('is_primary', true)
      .limit(1)

    if (props?.length) {
      const propUpdate: Record<string, unknown> = {}
      if (zone) propUpdate.zone = zone
      if (county) propUpdate.county = county
      await supabase.from('properties').update(propUpdate).eq('id', props[0].id)
    }
  }

  // GDO permit → service_configs.permit_number on the GT row
  const gdo = strVal(fields, 'GDO #')
  const gdoExp = dateVal(fields, 'GDO Expiration')
  if (gdo || gdoExp) {
    const permitUpdate: Record<string, unknown> = {}
    if (gdo) permitUpdate.permit_number = gdo
    if (gdoExp) permitUpdate.permit_expiration = gdoExp
    await supabase
      .from('service_configs')
      .update(permitUpdate)
      .eq('client_id', clientId)
      .eq('service_type', 'GT')
  }

  // GT size → service_configs.equipment_size_gallons on the GT row
  const gtSize = numVal(fields, 'GT Size') ?? numVal(fields, 'Grease Trap Size')
  if (gtSize) {
    await supabase
      .from('service_configs')
      .update({ equipment_size_gallons: gtSize })
      .eq('client_id', clientId)
      .eq('service_type', 'GT')
  }
}

// ---- DERM table → derm_manifests ----
async function handleDermRecord(recordId: string, fields: Record<string, unknown>): Promise<void> {
  const clientName = strVal(fields, 'Client Name')
  const manifestNumber = strVal(fields, 'Manifest #') ?? strVal(fields, 'White Manifest #')

  // Try to find the linked manifest
  const existingId = await findEntityBySourceId('derm_manifest', 'airtable', recordId)

  // v2 derm_manifests: service_date, dump_ticket_date, white_manifest_number,
  // yellow_ticket_number, manifest_images, address_images, sent_to_client, sent_to_city
  const row: Record<string, unknown> = {
    service_date: dateVal(fields, 'Date') ?? dateVal(fields, 'Manifest Date'),
    dump_ticket_date: dateVal(fields, 'Dump Ticket Date'),
    white_manifest_number: manifestNumber ?? strVal(fields, 'White Manifest #'),
    yellow_ticket_number: strVal(fields, 'Yellow Ticket #'),
    sent_to_client: fields['Sent to Client'] === true,
    sent_to_city: fields['Sent to City'] === true,
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

// ---- Table handler dispatcher ----
const RECORD_HANDLERS: Record<string, (recordId: string, fields: Record<string, unknown>) => Promise<void>> = {
  clients: handleClientRecord,
  derm: handleDermRecord,
  routes: handleRouteRecord,
  past_due: handleReceivableRecord,
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

  // Verify signature
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
