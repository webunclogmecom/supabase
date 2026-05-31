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

// ---- City → county fallback ----
// AT enrichment is the authoritative source for properties.county, but
// Jobber-only clients (residential, no AT entry) never get AT data, so
// county would stay NULL forever. This fallback sets county on INSERT
// only — AT can still override on subsequent updates. Built from the
// 2026-05-20 backfill audit (auto-classified 278 of 279 properties).
function inferCountyFromCity(city: string | null | undefined): string | null {
  if (!city) return null
  const c = city.toLowerCase().trim()
  const DADE = new Set([
    'miami','miami beach','surfside','north miami beach','bay harbor islands',
    'aventura','bal harbour','hialeah','pinecrest','indian creek','medley',
    'biscayne park','beverly hills','sunny isles beach','coral gables','doral',
    'miami shores','miami gardens','cutler bay','kendall','south miami',
    'north miami','miami-dade county',
  ])
  const BROWARD = new Set([
    'hollywood','hallandale beach','fort lauderdale','pompano beach',
    'pembroke pines','margate',
  ])
  // Boca Raton is geographically Palm Beach but ops classifies as Broward.
  const BROWARD_BY_CONVENTION = new Set(['boca raton'])
  if (DADE.has(c)) return 'Dade'
  if (BROWARD.has(c) || BROWARD_BY_CONVENTION.has(c)) return 'Broward'
  return null
}

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

// ---- Date helpers for the visit-merge logic (Supabase-cron promotion) ----
// Used by handleVisit to find a matching supabase_cron-scheduled placeholder
// within ±7 days of the incoming Jobber visit and PROMOTE it in place.
function addDaysISO(isoDate: string, days: number): string {
  const [y, m, d] = isoDate.split('-').map(Number)
  const date = new Date(Date.UTC(y, m - 1, d))
  date.setUTCDate(date.getUTCDate() + days)
  return date.toISOString().slice(0, 10)
}
function dateDiff(isoA: string, isoB: string): number {
  // Returns isoA - isoB in days
  const [ya, ma, da] = isoA.split('-').map(Number)
  const [yb, mb, db] = isoB.split('-').map(Number)
  return Math.round((Date.UTC(ya, ma - 1, da) - Date.UTC(yb, mb - 1, db)) / (1000 * 60 * 60 * 24))
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
        id isCompany companyName firstName lastName name
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

  // Name resolution: prefer the structured field for the entity flavor,
  // but always fall back to Jobber's denormalized `name` field — many
  // residential records have isCompany=false yet empty firstName/lastName,
  // with the actual display name only in `name`. Without this fallback the
  // webhook landed 4 clients with blank name in 2026-05 (audited 05-12).
  const structured = c.isCompany
    ? (c.companyName || '')
    : `${c.firstName || ''} ${c.lastName || ''}`.trim()
  const name = structured || c.name || ''

  // Skip Jobber test/junk client patterns — these were hard-deleted from our DB
  // 2026-05-04 (X 1-15, "test test", "NOT USE Capas Burger"). Webhook updates
  // on those Jobber-side records would otherwise re-create them in our DB.
  // Pattern allows: "X 1", "X 12", "x 11" (case-insensitive, optional double space),
  // "test", "TEST FOO", "NOT USE ..." prefix.
  if (/^\s*x\s+\d+\s*$/i.test(name) || /^\s*test\b/i.test(name) || /^\s*NOT\s*USE\b/i.test(name)) {
    console.log(`[skip] client ${numericId} matches test/junk name pattern: "${name}"`)
    return { entity_id: -1 }
  }
  const primaryEmail = c.emails?.find((e: any) => e.primary)?.address ?? c.emails?.[0]?.address
  const primaryPhone = c.phones?.find((p: any) => p.primary)?.number ?? c.phones?.[0]?.number
  const addr = c.billingAddress

  // client_code originates in Airtable, but Yan often types the NNN-XX prefix
  // into Jobber's Company Name field too (e.g. "062-TCE The carrot express ...").
  // Parse it on insert so Jobber-only clients still get a code without waiting
  // on Airtable enrichment. We do NOT overwrite an existing code on update —
  // that would clobber Airtable's authoritative value.
  //
  // Patterns we strip (in order of how Yan types them in Jobber):
  //   "062-TCE The carrot..."        — tight  (3 digits + dash + alpha — no space)
  //   "205- SAS Signor SASSI"        — loose  (3 digits + dash + ws + alpha + ws)
  //   "000- Kaffe"                   — bare   (3 digits + dash + ws only, no alpha suffix)
  // The trailing `\s+` requires whitespace between the prefix and the real
  // business name so we don't accidentally strip part of a real name.
  let parsedCode: string | null = null
  let nameNormalized = name
  const codeMatch = name.match(/^\s*(\d{3})-\s*([A-Z0-9]*)\s+/)
  if (codeMatch) {
    const [fullMatch, numericPart, alphaPart] = codeMatch
    // Only treat as a valid client_code if it has the NNN-XX shape. Bare
    // "000-" prefixes are pollution — still strip from the name but don't
    // promote the orphan numeric part to client_code.
    if (alphaPart) parsedCode = `${numericPart}-${alphaPart}`
    nameNormalized = name.replace(fullMatch, '').trim()
  }

  // Check if client already exists via entity_source_links.
  // Lookup uses the full base64 GID (consistent with populate.js step 1
  // which stores `jc.id` directly — also a base64 GID).
  const existingId = await findEntityBySourceId('client', 'jobber', gid)

  // v2 clients table: id, client_code, name, status, balance, notes, client_class
  const clientRow: Record<string, unknown> = {
    name: nameNormalized,
    status: c.isArchived ? 'INACTIVE' : 'ACTIVE',
    balance: c.balance ?? null,
  }
  // client_class: Jobber's `isCompany` is the canonical source of truth for
  // Commercial vs Residential. Added 2026-05-29 (migration
  // 2026-05-29_clients_class.sql). Only writes when isCompany is a real
  // boolean so we don't clobber a backfilled value with NULL on partial
  // payloads.
  if (typeof c.isCompany === 'boolean') {
    clientRow.client_class = c.isCompany ? 'commercial' : 'residential'
  }
  if (!existingId && parsedCode) clientRow.client_code = parsedCode

  let entityId: number

  if (existingId) {
    // Self-heal: if existing row has no client_code yet and the new name has
    // a parseable prefix, fill it in. Don't overwrite an existing code —
    // Airtable owns the authoritative value.
    if (parsedCode) {
      const { data: cur } = await supabase
        .from('clients').select('client_code').eq('id', existingId).maybeSingle()
      if (cur && !cur.client_code) clientRow.client_code = parsedCode
    }
    const { error } = await supabase.from('clients').update(clientRow).eq('id', existingId)
    if (error) throw new Error(`Client update failed: ${error.message}`)
    entityId = existingId
  } else {
    // Sanity check before INSERT: warn if a client with the same client_code,
    // email, or phone already exists. We DO insert (Jobber GID is the source
    // of truth), but log a warning so the weekly dedup audit can catch the
    // mistake. Yan sometimes creates the same business twice in Jobber under
    // different codes/typos — this catches it on day 1 instead of week 4.
    if (parsedCode || primaryEmail || primaryPhone) {
      const orParts: string[] = []
      if (parsedCode) orParts.push(`client_code.eq.${parsedCode}`)
      // Note: email/phone aren't on clients directly (they live on
      // client_contacts). For the warning we just check client_code here;
      // contact-level dedup is the weekly audit's job.
      if (orParts.length) {
        const { data: dup } = await supabase
          .from('clients').select('id, name, status').or(orParts.join(','))
          .limit(3)
        if (dup && dup.length) {
          await supabase.from('webhook_events_log').insert({
            source_system: 'jobber',
            event_type: 'client_insert_potential_dup',
            status: 'warning',
            error_message: `New client "${name}" (gid ${gid.slice(0, 24)}…) inserted with code ${parsedCode}; ${dup.length} existing client(s) share the code: ${dup.map(d => `${d.id}/${d.name}`).join(' | ')}`,
            payload: { new_gid: gid, new_name: name, parsed_code: parsedCode, candidates: dup },
          })
        }
      }
    }
    const { data: inserted, error } = await supabase
      .from('clients')
      .insert(clientRow)
      .select('id')
      .single()
    if (error || !inserted) throw new Error(`Client insert failed: ${error?.message}`)
    entityId = inserted.id
  }

  // Upsert entity_source_links — store full base64 GID for consistency with
  // populate.js (which stores `jc.id` directly = base64 GID). Migration
  // scripts feed this value back to Jobber's GraphQL EncodedId param.
  await upsertEntityLink({
    entity_type: 'client',
    entity_id: entityId,
    source_system: 'jobber',
    source_id: gid,
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
    // NOTE: Jobber GraphQL ClientAddress type does NOT expose `coordinates`
    // (only the Address type on Property does — see handleProperty). New Jobber
    // clients land with NULL lat/lng here; the weekly geo-backfill cron fills
    // them in via Samsara/Google. Don't add `coordinates` to billingAddress —
    // the GraphQL query will 400 on every CLIENT_UPDATE event.

    if (existingProps?.length) {
      // UPDATE — do NOT touch county; AT enrichment may have set it.
      await supabase.from('properties').update(propRow).eq('id', existingProps[0].id)
    } else {
      // INSERT — fallback county from city so Jobber-only clients aren't NULL.
      // Check if client already has ANY primary property (from a prior
      // PROPERTY_CREATE or CLIENT_UPDATE) — if yes, this new billing-address
      // row is NOT primary, to honor uq_properties_one_primary_per_client
      // (partial unique on (client_id) WHERE is_primary=true). Race-safe
      // against concurrent full-sync replays + live webhooks.
      const { data: existingPrimary } = await supabase
        .from('properties')
        .select('id')
        .eq('client_id', entityId)
        .eq('is_primary', true)
        .limit(1)
      const insertRow = {
        ...propRow,
        is_primary: !(existingPrimary && existingPrimary.length > 0),
        county: inferCountyFromCity(addr.city),
      }
      const { data: newProp } = await supabase
        .from('properties')
        .insert(insertRow)
        .select('id')
        .single()

      if (newProp) {
        await upsertEntityLink({
          entity_type: 'property',
          entity_id: newProp.id,
          source_system: 'jobber',
          source_id: `${gid}_billing`,
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
        id title visitStatus startAt endAt completedAt completedBy
        job { id client { id } property { id } }
        invoice { id }
        assignedUsers { nodes { id name { first last } } }
      }
    }`,
    { id: gid }
  )
  const v = data.visit
  if (!v) throw new Error(`Visit ${numericId} not found in Jobber`)

  // Pre-2026 cutoff (Fred 2026-05-01): we don't track visits before 2026-01-01.
  // Skip the upsert entirely; if it already exists in our DB, the cleanup
  // migration will eventually catch it. Don't error — just no-op.
  const dateForCutoff = (v.startAt ?? v.endAt ?? v.completedAt)?.slice(0, 10)
  if (dateForCutoff && dateForCutoff < '2026-01-01') {
    console.log(`[handleVisit] visit ${numericId} dated ${dateForCutoff} — pre-2026, skipping`)
    return { entity_id: 0 }
  }

  // Excluded test / non-synced accounts: their Jobber visits must NEVER enter
  // our DB. 112-YA "Yan's Restaurant" is Yan's test account — it still has a
  // leftover Jobber recurring job generating ~81 visits out to 2030. We already
  // exclude it from our own generator; this is the matching guard on the inbound
  // Jobber sync (both the real-time webhook and cron_jobber's replay funnel
  // through here). Matched by Jobber client GID. Added 2026-05-30.
  const EXCLUDED_JOBBER_CLIENT_GIDS = new Set<string>([
    'Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ=', // 112-YA Yan's Restaurant (test)
  ])
  if (v.job?.client?.id && EXCLUDED_JOBBER_CLIENT_GIDS.has(v.job.client.id)) {
    console.log(`[handleVisit] visit ${numericId} belongs to excluded test client ${v.job.client.id} (112-YA) — skipping`)
    return { entity_id: 0 }
  }

  // Resolve FKs via entity_source_links
  // FK lookups — use the full base64 GID directly from Jobber's GraphQL
  // response. Don't decode to numericId; ESL.source_id stores the GID.
  const jobId = v.job?.id ? await findEntityBySourceId('job', 'jobber', v.job.id) : null
  const clientId = v.job?.client?.id ? await findEntityBySourceId('client', 'jobber', v.job.client.id) : null
  const propertyId = v.job?.property?.id ? await findEntityBySourceId('property', 'jobber', v.job.property.id) : null
  const invoiceId = v.invoice?.id ? await findEntityBySourceId('invoice', 'jobber', v.invoice.id) : null

  const existingId = await findEntityBySourceId('visit', 'jobber', gid)

  // Map Jobber status → our status enum
  const statusMap: Record<string, string> = {
    // Canonical enum: 'scheduled' | 'completed' | 'canceled'
    // Jobber returns various scheduling-status values (UPCOMING, TODAY, LATE,
    // UNSCHEDULED, APPROVED, UNVISITED) — all collapse to 'scheduled' for our
    // purposes. COMPLETED and REQUIRES_INVOICING both indicate the visit was
    // performed → 'completed'. Cancellation comes via the DESTROY topic which
    // softStatusFlip sets to 'canceled' separately.
    'completed': 'completed',
    'requires_invoicing': 'completed',
    'upcoming': 'scheduled',
    'today': 'scheduled',
    'late': 'scheduled',
    'unscheduled': 'scheduled',
    'approved': 'scheduled',
    'unvisited': 'scheduled',
  }

  // Infer service_type from the visit title — Jobber's API doesn't expose this
  // field directly. populate.js (one-shot 2026-04-29) got it from matched
  // Airtable visits, but webhook-arrived visits had no enrichment path —
  // resulting in 71% of completed visits having NULL service_type and breaking
  // cadence audits (e.g. Yannick reported 069-TCE config 30d but seeing 60d).
  //
  // Title patterns observed in production (NULL audit 2026-05-12):
  //   "grease trap", standalone "gt" (e.g. "gt & cleaning")  → GT
  //   "lyft station …"                                       → LS
  //   "service call", "clog", "emergency", "hydrojet",
  //     "drain", "riser", "fire pump", "warranty", "repair"  → CL
  //   standalone "service" (not "dump")                      → CL
  //   "dump", inspection / camera / dye / leak / smell       → null
  //     (operational or one-off — not a subscription service)
  //
  // Order matters: LS before GT (so "lyft station cleaning" doesn't get
  // pulled into a future "cleaning"→GT branch); GT before CL (so
  // "gt & cleaning" resolves to GT instead of falling through to CL).
  const inferServiceType = (title: string | null): string | null => {
    if (!title) return null
    const t = title.toLowerCase()
    if (/lyft\s*station/.test(t)) return 'LS'
    if (/grease trap|grease pump|grey water|gray water|\bgt\b/.test(t)) return 'GT'
    if (/service call|\bclog|emergency|hydrojet|\bdrain|\briser|fire pump|warranty|\brepair/.test(t)) return 'CL'
    if (/\bservice\b/.test(t) && !/dump/.test(t)) return 'CL'
    return null
  }

  const visitRow: Record<string, unknown> = {
    title: v.title ?? null,
    service_type: inferServiceType(v.title ?? null),
    visit_status: statusMap[v.visitStatus?.toLowerCase()] ?? 'scheduled',
    start_at: v.startAt ?? null,
    end_at: v.endAt ?? null,
    completed_at: v.completedAt ?? null,
    // completed_by = name of the user who clicked "Complete" in Jobber's app
    // (often Diego, the office processor — NOT the driver). Driver attribution
    // lives in visit_assignments via assignedUsers.
    completed_by: v.completedBy ?? null,
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
  let promotedFromCron = false

  if (existingId) {
    // Standard update path — we've seen this Jobber visit before.
    const { error } = await supabase.from('visits').update(visitRow).eq('id', existingId)
    if (error) throw new Error(`Visit update failed: ${error.message}`)
    entityId = existingId
  } else {
    // Try to find a matching supabase_cron-generated scheduled placeholder
    // before inserting a new row. This keeps the Supabase cron's planned
    // schedule and Jobber's actual execution as a SINGLE row through the
    // visit lifecycle. Match criteria (kept tight to avoid false promotions):
    //   - client_id, service_type both match
    //   - visit_status='scheduled'
    //   - source='supabase_cron' (i.e., it's a placeholder, not a real Jobber row)
    //   - visit_date within ±7 days of the incoming Jobber visit
    // If multiple match, pick the closest in date.
    let promoteId: number | null = null
    if (clientId && visitRow.service_type && visitRow.visit_date) {
      const targetDate = visitRow.visit_date as string
      const { data: candidates } = await supabase
        .from('visits')
        .select('id, visit_date')
        .eq('client_id', clientId)
        .eq('service_type', visitRow.service_type)
        .eq('visit_status', 'scheduled')
        .eq('source', 'supabase_cron')
        .gte('visit_date', addDaysISO(targetDate, -7))
        .lte('visit_date', addDaysISO(targetDate, 7))
      if (candidates && candidates.length > 0) {
        // Pick the one with smallest |date diff|
        candidates.sort((a: any, b: any) =>
          Math.abs(dateDiff(a.visit_date, targetDate)) -
          Math.abs(dateDiff(b.visit_date, targetDate)))
        promoteId = candidates[0].id
      }
    }

    if (promoteId) {
      // PROMOTE the cron-scheduled placeholder: claim it as the canonical row
      // for this Jobber visit. source becomes 'jobber'; visit_date adopts the
      // Jobber-reported date (which may differ slightly from the planned one).
      const promotionRow = { ...visitRow, source: 'jobber' }
      const { error } = await supabase.from('visits').update(promotionRow).eq('id', promoteId)
      if (error) throw new Error(`Visit promotion failed: ${error.message}`)
      entityId = promoteId
      promotedFromCron = true
      console.log(`[handleVisit] promoted supabase_cron row ${promoteId} → jobber GID ${gid.slice(0, 30)}…`)
    } else {
      // No matching placeholder; insert fresh.
      const { data: inserted, error } = await supabase
        .from('visits')
        .insert(visitRow)
        .select('id')
        .single()
      if (error || !inserted) throw new Error(`Visit insert failed: ${error?.message}`)
      entityId = inserted.id
    }
  }

  await upsertEntityLink({
    entity_type: 'visit',
    entity_id: entityId,
    source_system: 'jobber',
    source_id: gid,
    match_method: promotedFromCron ? 'webhook_promoted_from_cron' : 'webhook',
  })

  // Upsert visit_assignments for assigned team members.
  // FIX 2026-05-15: pass member.id (full base64 gid) directly — same format as
  // entity_source_links.source_id stores. Previously decoded to numericId
  // (e.g. '3866470'), which never matched the stored full-gid (e.g.
  // 'Z2lkOi8vSm9iYmVyL1VzZXIvMzg2NjQ3MA==') → silent skip for every assignment
  // since the webhook started running. populate.js worked because it keys by
  // u.id directly (line 1073). All other lookups in this file use full gid
  // (lines 205/364/369) — only this one was inconsistent.
  if (v.assignedUsers?.nodes?.length) {
    for (const member of v.assignedUsers.nodes) {
      if (!member?.id) continue
      const empId = await findEntityBySourceId('employee', 'jobber', member.id)
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
  // Pull active jobs + archivedJobs + visits.job (fallback chain) so we
  // always find the link. Also pull line items + visit IDs so we can sync
  // invoice-scoped line_items and update linked visits.invoice_id in the
  // same call — Jobber doesn't send VISIT_UPDATE webhooks when only the
  // invoice link changes, so this is the only reliable path to keep
  // visits.invoice_id current.
  const data: any = await gql(
    `query($id: EncodedId!) {
      invoice(id: $id) {
        id invoiceNumber subject invoiceStatus issuedDate dueDate
        amounts { subtotal total invoiceBalance depositAmount }
        client { id }
        jobs { nodes { id } }
        archivedJobs { nodes { id } }
        visits(first: 25) { nodes { id job { id } } }
        lineItems(first: 50) {
          nodes { name description quantity unitPrice totalPrice taxable }
        }
      }
    }`,
    { id: gid }
  )
  const inv = data.invoice
  if (!inv) throw new Error(`Invoice ${numericId} not found in Jobber`)

  // Job resolution: active → archived → via-visit
  const jobGid: string | null =
    inv.jobs?.nodes?.[0]?.id ??
    inv.archivedJobs?.nodes?.[0]?.id ??
    (inv.visits?.nodes ?? []).map((v: any) => v?.job?.id).filter(Boolean)[0] ??
    null

  const clientId = inv.client?.id ? await findEntityBySourceId('client', 'jobber', inv.client.id) : null
  const jobId = jobGid ? await findEntityBySourceId('job', 'jobber', jobGid) : null
  const existingId = await findEntityBySourceId('invoice', 'jobber', gid)

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
    source_id: gid,
    match_method: 'webhook',
  })

  // Sync invoice-scoped line items. Idempotent: wipe + replace.
  // (Invoice line items have no stable Jobber ID we sync, so dedup by
  // invoice_id is the simplest correct strategy.)
  const lineItemNodes: any[] = inv.lineItems?.nodes ?? []
  await supabase.from('line_items').delete().eq('invoice_id', entityId)
  if (lineItemNodes.length > 0) {
    const lineRows = lineItemNodes.map((n: any) => ({
      invoice_id: entityId,
      name: n.name ?? null,
      description: n.description ?? null,
      quantity: n.quantity ?? null,
      unit_price: n.unitPrice ?? null,
      total_price: n.totalPrice ?? null,
      taxable: n.taxable ?? null,
    }))
    const { error: liErr } = await supabase.from('line_items').insert(lineRows)
    if (liErr) {
      console.error(`Invoice ${numericId}: line_items insert failed:`, liErr.message)
      // Don't throw — invoice itself succeeded, line items can be backfilled
    }
  }

  // Update linked visits' invoice_id. cron_jobber pulls visits with a
  // completedAt cursor — once a visit is completed it's never re-pulled,
  // so the visits.invoice_id sync only works if THIS handler updates them
  // when the invoice arrives.
  const visitGids: string[] = (inv.visits?.nodes ?? []).map((v: any) => v?.id).filter(Boolean)
  for (const vGid of visitGids) {
    const ourVisitId = await findEntityBySourceId('visit', 'jobber', vGid)
    if (ourVisitId) {
      const { error: vErr } = await supabase.from('visits').update({ invoice_id: entityId }).eq('id', ourVisitId)
      if (vErr) console.error(`Invoice ${numericId}: visit ${ourVisitId} invoice_id update failed:`, vErr.message)
    }
  }

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

  const clientId = j.client?.id ? await findEntityBySourceId('client', 'jobber', j.client.id) : null
  const propertyId = j.property?.id ? await findEntityBySourceId('property', 'jobber', j.property.id) : null
  const quoteId = j.quote?.id ? await findEntityBySourceId('quote', 'jobber', j.quote.id) : null
  const existingId = await findEntityBySourceId('job', 'jobber', gid)

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
    source_id: gid,
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

  const clientId = q.client?.id ? await findEntityBySourceId('client', 'jobber', q.client.id) : null
  const propertyId = q.property?.id ? await findEntityBySourceId('property', 'jobber', q.property.id) : null
  const existingId = await findEntityBySourceId('quote', 'jobber', gid)

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
    source_id: gid,
    match_method: 'webhook',
  })

  return { entity_id: entityId }
}

async function handleProperty(numericId: string, topic: string): Promise<{ entity_id: number }> {
  const gid = btoa(`gid://Jobber/Property/${numericId}`)
  // Jobber exposes property.name (the human-readable label, e.g. "Main location"
  // or the client's company name). Handler was previously not pulling it →
  // 470/470 properties had NULL name (audit 2026-05-13).
  const data: any = await gql(
    `query($id: EncodedId!) {
      property(id: $id) {
        id
        name
        client { id }
        address { street city province postalCode country coordinates { latitude longitude } }
      }
    }`,
    { id: gid }
  )
  const p = data.property
  if (!p) throw new Error(`Property ${numericId} not found in Jobber`)

  const clientId = p.client?.id ? await findEntityBySourceId('client', 'jobber', p.client.id) : null
  const existingId = await findEntityBySourceId('property', 'jobber', gid)

  // Defer-if-orphan: if the property's owning Jobber client hasn't been
  // materialized in canonical yet (race condition: PROPERTY_UPDATE arrived
  // before CLIENT_UPDATE for the same client, or full-sync replay ordering),
  // skip with a log. The next CLIENT_UPDATE webhook will materialize the
  // client, and a subsequent PROPERTY_UPDATE (or full-sync) will pick this
  // property up. Inserting with NULL client_id violates NOT NULL.
  if (!existingId && !clientId) {
    console.log(`[handleProperty] property ${numericId} has no canonical client yet (jobber client.id=${p.client?.id}) — deferring; next CLIENT_UPDATE will materialize`)
    return { entity_id: 0 }
  }

  const row: Record<string, unknown> = {
    name: p.name ?? null,
    address: p.address?.street ?? null,
    city: p.address?.city ?? null,
    state: p.address?.province ?? 'FL',
    zip: p.address?.postalCode ?? null,
  }
  if (clientId) row.client_id = clientId
  // Coordinates: only set if Jobber returned a non-null value, so we don't
  // overwrite an existing geocoded/Samsara value with NULL.
  if (p.address?.coordinates?.latitude != null)  row.latitude  = p.address.coordinates.latitude
  if (p.address?.coordinates?.longitude != null) row.longitude = p.address.coordinates.longitude

  let entityId: number
  if (existingId) {
    // UPDATE — preserve county (AT may have set it).
    const { error } = await supabase.from('properties').update(row).eq('id', existingId)
    if (error) throw new Error(`Property update failed: ${error.message}`)
    entityId = existingId
  } else {
    // INSERT — fallback county from city so new Jobber properties aren't NULL.
    // properties.is_primary column DEFAULT is `true`. If this client already
    // has a primary property (from PRIOR PROPERTY_CREATE or CLIENT_UPDATE's
    // billing-property path), default would violate uq_properties_one_primary_per_client.
    // Check first; force is_primary=false when a primary already exists. Only
    // the first property for a client gets primary=true via the default.
    let isPrimary: boolean | undefined = undefined  // let DB default kick in (true)
    if (clientId) {
      const { data: existingPrimary } = await supabase
        .from('properties')
        .select('id')
        .eq('client_id', clientId)
        .eq('is_primary', true)
        .limit(1)
      if (existingPrimary && existingPrimary.length > 0) isPrimary = false
    }
    const insertRow = {
      ...row,
      county: inferCountyFromCity(p.address?.city),
      ...(isPrimary === false ? { is_primary: false } : {}),
    }
    const { data: inserted, error } = await supabase.from('properties').insert(insertRow).select('id').single()
    if (error || !inserted) throw new Error(`Property insert failed: ${error?.message}`)
    entityId = inserted.id
  }

  await upsertEntityLink({
    entity_type: 'property', entity_id: entityId, source_system: 'jobber',
    source_id: gid, match_method: 'webhook',
  })
  return { entity_id: entityId }
}

// Soft-delete / status-flip handlers for DESTROY / CLOSED events.
// Per rule #6 (never hard-delete): we flip a status column so joins + history stay intact.

// Map our entity_type → Jobber's GID Type token (for re-encoding numericId → GID)
const JOBBER_GID_TYPE: Record<string, string> = {
  client: 'Client', job: 'Job', visit: 'Visit',
  invoice: 'Invoice', quote: 'Quote', property: 'Property',
}

async function softStatusFlip(
  entity_type: string,
  table: string,
  statusCol: string,
  newStatus: string,
  numericId: string
): Promise<{ entity_id: number }> {
  // ESL.source_id stores the full base64 GID — reconstruct it for the lookup.
  const gid = btoa(`gid://Jobber/${JOBBER_GID_TYPE[entity_type]}/${numericId}`)
  const existingId = await findEntityBySourceId(entity_type, 'jobber', gid)
  if (!existingId) {
    // Never saw this entity — nothing to flip. Log & acknowledge.
    console.log(`[softStatusFlip ${entity_type}] unknown source_id=${gid} — nothing to update`)
    return { entity_id: 0 }
  }
  const { error } = await supabase.from(table).update({ [statusCol]: newStatus }).eq('id', existingId)
  if (error) throw new Error(`${table}.${statusCol}='${newStatus}' failed: ${error.message}`)
  return { entity_id: existingId }
}

const handleClientDestroy = (id: string) => softStatusFlip('client', 'clients', 'status', 'INACTIVE', id)
const handleJobClosed     = (id: string) => softStatusFlip('job',    'jobs',    'job_status', 'closed',    id)
const handleJobDestroy    = (id: string) => softStatusFlip('job',    'jobs',    'job_status', 'destroyed', id)
const handleVisitDestroy  = (id: string) => softStatusFlip('visit',  'visits',  'visit_status', 'canceled', id)
const handleInvoiceDestroy= (id: string) => softStatusFlip('invoice','invoices','invoice_status','destroyed',id)
const handleQuoteDestroy  = (id: string) => softStatusFlip('quote',  'quotes',  'quote_status','destroyed', id)
async function handlePropertyDestroy(numericId: string): Promise<{ entity_id: number }> {
  const gid = btoa(`gid://Jobber/Property/${numericId}`)
  const existingId = await findEntityBySourceId('property', 'jobber', gid)
  if (!existingId) { console.log(`[PROPERTY_DESTROY] unknown ${gid}`); return { entity_id: 0 } }
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
