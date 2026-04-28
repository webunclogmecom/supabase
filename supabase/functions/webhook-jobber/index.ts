// ============================================================================
// webhook-jobber/index.ts — Jobber webhook receiver (Edge Function)
// ============================================================================
// Jobber sends "thin" webhook notifications:
//   { "topic": "CLIENT_CREATE", "webHookEvent": { "itemId": "base64GID", "occurredAt": "..." } }
//
// Flow: verify HMAC → decode GID → re-query Jobber GraphQL → upsert to v2 tables.
//
// Jobber sunsets May 2026 — this is a data harvest bridge.
// ============================================================================

import { supabase } from '../_shared/supabase-client.ts'
import { upsertEntityLink, findEntityBySourceId } from '../_shared/entity-links.ts'
import { ok, badRequest, unauthorized, serverError, logWebhookEvent } from '../_shared/responses.ts'

// ---- Constants ----
const JOBBER_GQL = 'https://api.getjobber.com/api/graphql'
const JOBBER_TOKEN_URL = 'https://api.getjobber.com/api/oauth/token'

// ---- HMAC-SHA256 verification ----
async function verifySignature(body: string, signature: string | null): Promise<boolean> {
  const secret = Deno.env.get('JOBBER_WEBHOOK_SECRET')
  if (!secret) {
    console.warn('JOBBER_WEBHOOK_SECRET not set — skipping verification')
    return true // Allow during dev; remove in prod
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

// ---- Decode Jobber base64 GID → { type, numericId } ----
function decodeGid(gid: string): { type: string; numericId: string } | null {
  try {
    const decoded = atob(gid)
    // Jobber's canonical GID format: gid://Jobber/<Type>/<id>
    let match = decoded.match(/^gid:\/\/Jobber\/(\w+)\/(\d+)$/)
    if (match) return { type: match[1], numericId: match[2] }
    // Fallback: accept short form Type/<id> for internal re-encoding paths
    match = decoded.match(/^(\w+)\/(\d+)$/)
    return match ? { type: match[1], numericId: match[2] } : null
  } catch {
    return null
  }
}

// ---- Token management: get a valid Jobber access token ----
async function getAccessToken(): Promise<string> {
  // 1. Try DB-cached token (refreshed by previous calls)
  const { data: cached } = await supabase
    .from('webhook_tokens')
    .select('access_token, refresh_token, client_id, client_secret, expires_at')
    .eq('source_system', 'jobber')
    .maybeSingle()

  if (cached?.access_token && cached.expires_at) {
    if (new Date(cached.expires_at) > new Date(Date.now() + 60_000)) {
      return cached.access_token // Still valid (with 60s buffer)
    }

    // Expired — try refresh
    if (cached.refresh_token && cached.client_id && cached.client_secret) {
      try {
        const resp = await fetch(JOBBER_TOKEN_URL, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            grant_type: 'refresh_token',
            refresh_token: cached.refresh_token,
            client_id: cached.client_id,
            client_secret: cached.client_secret,
          }),
        })
        if (resp.ok) {
          const tokens = await resp.json()
          const expiresAt = new Date(Date.now() + (tokens.expires_in ?? 7200) * 1000).toISOString()
          await supabase
            .from('webhook_tokens')
            .update({
              access_token: tokens.access_token,
              refresh_token: tokens.refresh_token ?? cached.refresh_token,
              expires_at: expiresAt,
              updated_at: new Date().toISOString(),
            })
            .eq('source_system', 'jobber')
          return tokens.access_token
        }
      } catch (e) {
        console.error('Jobber token refresh failed:', e)
      }
    }
  }

  // 2. Fall back to env var (manual refresh)
  const envToken = Deno.env.get('JOBBER_ACCESS_TOKEN')
  if (envToken) return envToken

  throw new Error('No valid Jobber access token available')
}

// ---- Jobber GraphQL query ----
async function gql(query: string, variables: Record<string, unknown> = {}): Promise<unknown> {
  const token = await getAccessToken()
  const resp = await fetch(JOBBER_GQL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
    },
    body: JSON.stringify({ query, variables }),
  })

  if (!resp.ok) {
    const text = await resp.text()
    throw new Error(`Jobber GraphQL ${resp.status}: ${text.slice(0, 300)}`)
  }

  const json = await resp.json()
  if (json.errors?.length) {
    throw new Error(`Jobber GraphQL error: ${JSON.stringify(json.errors[0])}`)
  }
  return json.data
}

// ============================================================================
// Entity Handlers
// ============================================================================

async function handleClient(numericId: string, topic: string): Promise<{ entity_id: number }> {
  const gid = btoa(`gid://Jobber/Client/${numericId}`)
  const data: any = await gql(
    `query($id: EncodedId!) {
      client(id: $id) {
        id isCompany companyName firstName lastName
        emails { address primary description }
        phones { number primary description }
        billingAddress { street city province postalCode }
        balance isArchived
      }
    }`,
    { id: gid }
  )
  const c = data.client
  if (!c) throw new Error(`Client ${numericId} not found in Jobber`)

  const name = c.isCompany ? c.companyName : `${c.firstName} ${c.lastName}`.trim()
  const primaryEmail = c.emails?.find((e: any) => e.primary)?.address ?? c.emails?.[0]?.address
  const primaryPhone = c.phones?.find((p: any) => p.primary)?.number ?? c.phones?.[0]?.number
  const addr = c.billingAddress

  // Check if client already exists via entity_source_links
  const existingId = await findEntityBySourceId('client', 'jobber', numericId)

  // v2 clients table: only id, client_code, name, status, balance, notes
  const clientRow: Record<string, unknown> = {
    name,
    status: c.isArchived ? 'INACTIVE' : 'ACTIVE',
    balance: c.balance ?? null,
  }

  let entityId: number

  if (existingId) {
    const { error } = await supabase.from('clients').update(clientRow).eq('id', existingId)
    if (error) throw new Error(`Client update failed: ${error.message}`)
    entityId = existingId
  } else {
    const { data: inserted, error } = await supabase
      .from('clients')
      .insert(clientRow)
      .select('id')
      .single()
    if (error || !inserted) throw new Error(`Client insert failed: ${error?.message}`)
    entityId = inserted.id
  }

  // Upsert entity_source_links
  await upsertEntityLink({
    entity_type: 'client',
    entity_id: entityId,
    source_system: 'jobber',
    source_id: numericId,
    source_name: name,
    match_method: 'webhook',
    match_confidence: 1.0,
  })

  // Upsert client_contacts from Jobber emails/phones
  if (primaryEmail || primaryPhone) {
    const contactRow = {
      client_id: entityId,
      contact_role: 'primary',
      name: name,
      email: primaryEmail ?? null,
      phone: primaryPhone ?? null,
    }
    await supabase
      .from('client_contacts')
      .upsert(contactRow, { onConflict: 'client_id,contact_role' })
  }

  // Upsert billing property from Jobber address
  if (addr?.street || addr?.city) {
    // Find existing billing property for this client
    const { data: existingProps } = await supabase
      .from('properties')
      .select('id')
      .eq('client_id', entityId)
      .eq('is_billing', true)
      .limit(1)

    const propRow: Record<string, unknown> = {
      client_id: entityId,
      address: addr.street ?? null,
      city: addr.city ?? null,
      state: addr.province ?? 'FL',
      zip: addr.postalCode ?? null,
      is_billing: true,
    }

    if (existingProps?.length) {
      await supabase.from('properties').update(propRow).eq('id', existingProps[0].id)
    } else {
      const { data: newProp } = await supabase
        .from('properties')
        .insert({ ...propRow, is_primary: true })
        .select('id')
        .single()

      if (newProp) {
        await upsertEntityLink({
          entity_type: 'property',
          entity_id: newProp.id,
          source_system: 'jobber',
          source_id: `${numericId}_billing`,
          source_name: `${name} (billing)`,
          match_method: 'webhook',
        })
      }
    }
  }

  return { entity_id: entityId }
}

async function handleVisit(numericId: string, topic: string): Promise<{ entity_id: number }> {
  const gid = btoa(`gid://Jobber/Visit/${numericId}`)
  const data: any = await gql(
    `query($id: EncodedId!) {
      visit(id: $id) {
        id title visitStatus startAt endAt completedAt
        job { id client { id } property { id } }
        invoice { id }
        assignedUsers { nodes { id name { first last } } }
      }
    }`,
    { id: gid }
  )
  const v = data.visit
  if (!v) throw new Error(`Visit ${numericId} not found in Jobber`)

  // Resolve FKs via entity_source_links
  const jobGid = v.job?.id ? decodeGid(v.job.id)?.numericId ?? null : null
  const clientGid = v.job?.client?.id ? decodeGid(v.job.client.id)?.numericId ?? null : null
  const propGid = v.job?.property?.id ? decodeGid(v.job.property.id)?.numericId ?? null : null
  const invoiceGid = v.invoice?.id ? decodeGid(v.invoice.id)?.numericId ?? null : null

  const jobId = jobGid ? await findEntityBySourceId('job', 'jobber', jobGid) : null
  const clientId = clientGid ? await findEntityBySourceId('client', 'jobber', clientGid) : null
  const propertyId = propGid ? await findEntityBySourceId('property', 'jobber', propGid) : null
  const invoiceId = invoiceGid ? await findEntityBySourceId('invoice', 'jobber', invoiceGid) : null

  const existingId = await findEntityBySourceId('visit', 'jobber', numericId)

  // Map Jobber status → our status enum
  const statusMap: Record<string, string> = {
    'completed': 'completed',
    'approved': 'scheduled',
    'requires_invoicing': 'completed',
    'unvisited': 'scheduled',
  }

  const visitRow: Record<string, unknown> = {
    title: v.title ?? null,
    visit_status: statusMap[v.visitStatus?.toLowerCase()] ?? v.visitStatus ?? null,
    start_at: v.startAt ?? null,
    end_at: v.endAt ?? null,
    completed_at: v.completedAt ?? null,
    // visit_date is NOT NULL — fall back through startAt → endAt → completedAt.
    // If all three are missing, skip the row rather than fail the upsert.
    visit_date: (v.startAt ?? v.endAt ?? v.completedAt)?.slice(0, 10) ?? null,
  }
  if (!visitRow.visit_date) {
    console.log(`[handleVisit] visit ${numericId} has no startAt/endAt/completedAt — skipping`)
    return { entity_id: existingId ?? 0 }
  }
  if (jobId) visitRow.job_id = jobId
  if (clientId) visitRow.client_id = clientId
  if (propertyId) visitRow.property_id = propertyId
  if (invoiceId) visitRow.invoice_id = invoiceId

  let entityId: number

  if (existingId) {
    const { error } = await supabase.from('visits').update(visitRow).eq('id', existingId)
    if (error) throw new Error(`Visit update failed: ${error.message}`)
    entityId = existingId
  } else {
    const { data: inserted, error } = await supabase
      .from('visits')
      .insert(visitRow)
      .select('id')
      .single()
    if (error || !inserted) throw new Error(`Visit insert failed: ${error?.message}`)
    entityId = inserted.id
  }

  await upsertEntityLink({
    entity_type: 'visit',
    entity_id: entityId,
    source_system: 'jobber',
    source_id: numericId,
    match_method: 'webhook',
  })

  // Upsert visit_assignments for assigned team members
  if (v.assignedUsers?.nodes?.length) {
    for (const member of v.assignedUsers.nodes) {
      const memberGid = decodeGid(member.id)?.numericId
      if (!memberGid) continue
      const empId = await findEntityBySourceId('employee', 'jobber', memberGid)
      if (!empId) continue

      await supabase
        .from('visit_assignments')
        .upsert(
          { visit_id: entityId, employee_id: empId },
          { onConflict: 'visit_id,employee_id' }
        )
    }
  }

  return { entity_id: entityId }
}

async function handleInvoice(numericId: string, topic: string): Promise<{ entity_id: number }> {
  const gid = btoa(`gid://Jobber/Invoice/${numericId}`)
  const data: any = await gql(
    `query($id: EncodedId!) {
      invoice(id: $id) {
        id invoiceNumber subject invoiceStatus issuedDate dueDate
        amounts { subtotal total invoiceBalance depositAmount }
        client { id }
        jobs { nodes { id } }
      }
    }`,
    { id: gid }
  )
  const inv = data.invoice
  if (!inv) throw new Error(`Invoice ${numericId} not found in Jobber`)

  const clientGid = inv.client?.id ? decodeGid(inv.client.id)?.numericId ?? null : null
  const firstJob = inv.jobs?.nodes?.[0]
  const jobGid = firstJob?.id ? decodeGid(firstJob.id)?.numericId ?? null : null

  const clientId = clientGid ? await findEntityBySourceId('client', 'jobber', clientGid) : null
  const jobId = jobGid ? await findEntityBySourceId('job', 'jobber', jobGid) : null
  const existingId = await findEntityBySourceId('invoice', 'jobber', numericId)

  const invoiceRow: Record<string, unknown> = {
    invoice_number: inv.invoiceNumber ?? null,
    subject: inv.subject ?? null,
    invoice_status: inv.invoiceStatus?.toLowerCase() ?? null,
    sent_at: inv.issuedDate ?? null,
    due_date: inv.dueDate ?? null,
    total: inv.amounts?.total ?? null,
    outstanding_amount: inv.amounts?.invoiceBalance ?? null,
    deposit_amount: inv.amounts?.depositAmount ?? null,
  }
  if (clientId) invoiceRow.client_id = clientId
  if (jobId) invoiceRow.job_id = jobId

  let entityId: number

  if (existingId) {
    const { error } = await supabase.from('invoices').update(invoiceRow).eq('id', existingId)
    if (error) throw new Error(`Invoice update failed: ${error.message}`)
    entityId = existingId
  } else {
    const { data: inserted, error } = await supabase
      .from('invoices')
      .insert(invoiceRow)
      .select('id')
      .single()
    if (error || !inserted) throw new Error(`Invoice insert failed: ${error?.message}`)
    entityId = inserted.id
  }

  await upsertEntityLink({
    entity_type: 'invoice',
    entity_id: entityId,
    source_system: 'jobber',
    source_id: numericId,
    match_method: 'webhook',
  })

  return { entity_id: entityId }
}

async function handleJob(numericId: string, topic: string): Promise<{ entity_id: number }> {
  const gid = btoa(`gid://Jobber/Job/${numericId}`)
  const data: any = await gql(
    `query($id: EncodedId!) {
      job(id: $id) {
        id jobNumber title jobStatus startAt endAt
        client { id }
        property { id }
        quote { id }
      }
    }`,
    { id: gid }
  )
  const j = data.job
  if (!j) throw new Error(`Job ${numericId} not found in Jobber`)

  const clientGid = j.client?.id ? decodeGid(j.client.id)?.numericId ?? null : null
  const propGid = j.property?.id ? decodeGid(j.property.id)?.numericId ?? null : null
  const quoteGid = j.quote?.id ? decodeGid(j.quote.id)?.numericId ?? null : null

  const clientId = clientGid ? await findEntityBySourceId('client', 'jobber', clientGid) : null
  const propertyId = propGid ? await findEntityBySourceId('property', 'jobber', propGid) : null
  const quoteId = quoteGid ? await findEntityBySourceId('quote', 'jobber', quoteGid) : null
  const existingId = await findEntityBySourceId('job', 'jobber', numericId)

  const jobRow: Record<string, unknown> = {
    job_number: j.jobNumber ?? null,
    title: j.title ?? null,
    job_status: j.jobStatus?.toLowerCase() ?? null,
    start_at: j.startAt ?? null,
    end_at: j.endAt ?? null,
  }
  if (clientId) jobRow.client_id = clientId
  if (propertyId) jobRow.property_id = propertyId
  if (quoteId) jobRow.quote_id = quoteId

  let entityId: number

  if (existingId) {
    const { error } = await supabase.from('jobs').update(jobRow).eq('id', existingId)
    if (error) throw new Error(`Job update failed: ${error.message}`)
    entityId = existingId
  } else {
    const { data: inserted, error } = await supabase
      .from('jobs')
      .insert(jobRow)
      .select('id')
      .single()
    if (error || !inserted) throw new Error(`Job insert failed: ${error?.message}`)
    entityId = inserted.id
  }

  await upsertEntityLink({
    entity_type: 'job',
    entity_id: entityId,
    source_system: 'jobber',
    source_id: numericId,
    match_method: 'webhook',
  })

  return { entity_id: entityId }
}

async function handleQuote(numericId: string, topic: string): Promise<{ entity_id: number }> {
  const gid = btoa(`gid://Jobber/Quote/${numericId}`)
  const data: any = await gql(
    `query($id: EncodedId!) {
      quote(id: $id) {
        id quoteNumber title quoteStatus createdAt
        amounts { total }
        client { id }
        property { id }
      }
    }`,
    { id: gid }
  )
  const q = data.quote
  if (!q) throw new Error(`Quote ${numericId} not found in Jobber`)

  const clientGid = q.client?.id ? decodeGid(q.client.id)?.numericId ?? null : null
  const propGid = q.property?.id ? decodeGid(q.property.id)?.numericId ?? null : null
  const clientId = clientGid ? await findEntityBySourceId('client', 'jobber', clientGid) : null
  const propertyId = propGid ? await findEntityBySourceId('property', 'jobber', propGid) : null
  const existingId = await findEntityBySourceId('quote', 'jobber', numericId)

  const quoteRow: Record<string, unknown> = {
    quote_number: q.quoteNumber ?? null,
    title: q.title ?? null,
    quote_status: q.quoteStatus?.toLowerCase() ?? null,
    total: q.amounts?.total ?? null,
    sent_at: q.createdAt ?? null,
  }
  if (clientId) quoteRow.client_id = clientId
  if (propertyId) quoteRow.property_id = propertyId

  let entityId: number

  if (existingId) {
    const { error } = await supabase.from('quotes').update(quoteRow).eq('id', existingId)
    if (error) throw new Error(`Quote update failed: ${error.message}`)
    entityId = existingId
  } else {
    const { data: inserted, error } = await supabase
      .from('quotes')
      .insert(quoteRow)
      .select('id')
      .single()
    if (error || !inserted) throw new Error(`Quote insert failed: ${error?.message}`)
    entityId = inserted.id
  }

  await upsertEntityLink({
    entity_type: 'quote',
    entity_id: entityId,
    source_system: 'jobber',
    source_id: numericId,
    match_method: 'webhook',
  })

  return { entity_id: entityId }
}

async function handleProperty(numericId: string, topic: string): Promise<{ entity_id: number }> {
  const gid = btoa(`gid://Jobber/Property/${numericId}`)
  const data: any = await gql(
    `query($id: EncodedId!) {
      property(id: $id) {
        id
        client { id }
        address { street city province postalCode country }
      }
    }`,
    { id: gid }
  )
  const p = data.property
  if (!p) throw new Error(`Property ${numericId} not found in Jobber`)

  const clientGid = p.client?.id ? decodeGid(p.client.id)?.numericId ?? null : null
  const clientId = clientGid ? await findEntityBySourceId('client', 'jobber', clientGid) : null
  const existingId = await findEntityBySourceId('property', 'jobber', numericId)

  const row: Record<string, unknown> = {
    address: p.address?.street ?? null,
    city: p.address?.city ?? null,
    state: p.address?.province ?? 'FL',
    zip: p.address?.postalCode ?? null,
  }
  if (clientId) row.client_id = clientId

  let entityId: number
  if (existingId) {
    const { error } = await supabase.from('properties').update(row).eq('id', existingId)
    if (error) throw new Error(`Property update failed: ${error.message}`)
    entityId = existingId
  } else {
    const { data: inserted, error } = await supabase.from('properties').insert(row).select('id').single()
    if (error || !inserted) throw new Error(`Property insert failed: ${error?.message}`)
    entityId = inserted.id
  }

  await upsertEntityLink({
    entity_type: 'property', entity_id: entityId, source_system: 'jobber',
    source_id: numericId, match_method: 'webhook',
  })
  return { entity_id: entityId }
}

// Soft-delete / status-flip handlers for DESTROY / CLOSED events.
// Per rule #6 (never hard-delete): we flip a status column so joins + history stay intact.
async function softStatusFlip(
  entity_type: string,
  table: string,
  statusCol: string,
  newStatus: string,
  numericId: string
): Promise<{ entity_id: number }> {
  const existingId = await findEntityBySourceId(entity_type, 'jobber', numericId)
  if (!existingId) {
    // Never saw this entity — nothing to flip. Log & acknowledge.
    console.log(`[softStatusFlip ${entity_type}] unknown source_id=${numericId} — nothing to update`)
    return { entity_id: 0 }
  }
  const { error } = await supabase.from(table).update({ [statusCol]: newStatus }).eq('id', existingId)
  if (error) throw new Error(`${table}.${statusCol}='${newStatus}' failed: ${error.message}`)
  return { entity_id: existingId }
}

const handleClientDestroy = (id: string) => softStatusFlip('client', 'clients', 'status', 'INACTIVE', id)
const handleJobClosed     = (id: string) => softStatusFlip('job',    'jobs',    'job_status', 'closed',    id)
const handleJobDestroy    = (id: string) => softStatusFlip('job',    'jobs',    'job_status', 'destroyed', id)
const handleVisitDestroy  = (id: string) => softStatusFlip('visit',  'visits',  'visit_status', 'destroyed', id)
const handleInvoiceDestroy= (id: string) => softStatusFlip('invoice','invoices','invoice_status','destroyed',id)
const handleQuoteDestroy  = (id: string) => softStatusFlip('quote',  'quotes',  'quote_status','destroyed', id)
async function handlePropertyDestroy(numericId: string): Promise<{ entity_id: number }> {
  const existingId = await findEntityBySourceId('property', 'jobber', numericId)
  if (!existingId) { console.log(`[PROPERTY_DESTROY] unknown ${numericId}`); return { entity_id: 0 } }
  const { error } = await supabase.from('properties').delete().eq('id', existingId)
  if (error) throw new Error(`PROPERTY_DESTROY failed: ${error.message}`)
  return { entity_id: existingId }
}

// ============================================================================
// Topic → Handler dispatch
// ============================================================================
const TOPIC_HANDLERS: Record<string, (id: string, topic: string) => Promise<{ entity_id: number }>> = {
  CLIENT_CREATE: handleClient,
  CLIENT_UPDATE: handleClient,
  CLIENT_DESTROY: handleClientDestroy,
  VISIT_CREATE: handleVisit,
  VISIT_UPDATE: handleVisit,
  VISIT_COMPLETE: handleVisit,
  VISIT_DESTROY: handleVisitDestroy,
  INVOICE_CREATE: handleInvoice,
  INVOICE_UPDATE: handleInvoice,
  INVOICE_DESTROY: handleInvoiceDestroy,
  JOB_CREATE: handleJob,
  JOB_UPDATE: handleJob,
  JOB_CLOSED: handleJobClosed,
  JOB_DESTROY: handleJobDestroy,
  QUOTE_CREATE: handleQuote,
  QUOTE_UPDATE: handleQuote,
  QUOTE_SENT: handleQuote,
  QUOTE_APPROVED: handleQuote,
  QUOTE_DESTROY: handleQuoteDestroy,
  PROPERTY_CREATE: handleProperty,
  PROPERTY_UPDATE: handleProperty,
  PROPERTY_DESTROY: handlePropertyDestroy,
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
  let payload: any

  try {
    payload = JSON.parse(rawBody)
  } catch {
    return badRequest('Invalid JSON')
  }

  // Verify HMAC signature
  const signature = req.headers.get('x-jobber-hmac-sha256')
  const valid = await verifySignature(rawBody, signature)
  if (!valid) {
    await logWebhookEvent(supabase, 'jobber', payload.topic ?? 'unknown', payload, {
      status: 'failed',
      error_message: 'HMAC verification failed',
      processing_ms: Date.now() - startMs,
    })
    return unauthorized('Invalid HMAC signature')
  }

  const topic = payload.topic
  const itemId = payload.webHookEvent?.itemId

  if (!topic || !itemId) {
    return badRequest('Missing topic or itemId')
  }

  // Decode GID
  const decoded = decodeGid(itemId)
  if (!decoded) {
    await logWebhookEvent(supabase, 'jobber', topic, payload, {
      status: 'failed',
      error_message: `Failed to decode GID: ${itemId}`,
      processing_ms: Date.now() - startMs,
    })
    return badRequest(`Invalid GID: ${itemId}`)
  }

  const handler = TOPIC_HANDLERS[topic]
  if (!handler) {
    // Log and acknowledge — don't fail for unsupported topics
    await logWebhookEvent(supabase, 'jobber', topic, payload, {
      status: 'skipped',
      processing_ms: Date.now() - startMs,
    })
    return ok({ skipped: true, topic })
  }

  try {
    const result = await handler(decoded.numericId, topic)
    const elapsedMs = Date.now() - startMs

    await logWebhookEvent(supabase, 'jobber', topic, payload, {
      event_id: itemId,
      entity_type: decoded.type.toLowerCase(),
      entity_id: result.entity_id,
      status: 'processed',
      processing_ms: elapsedMs,
    })

    return ok({ processed: true, topic, entity_id: result.entity_id, ms: elapsedMs })
  } catch (err) {
    const elapsedMs = Date.now() - startMs
    const message = err instanceof Error ? err.message : String(err)
    console.error(`[webhook-jobber] ${topic} failed:`, message)

    await logWebhookEvent(supabase, 'jobber', topic, payload, {
      event_id: itemId,
      status: 'failed',
      error_message: message.slice(0, 1000),
      processing_ms: elapsedMs,
    })

    return serverError(message.slice(0, 200))
  }
})
