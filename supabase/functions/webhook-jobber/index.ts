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
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Dedicated client that stamps inbound Jobber VISIT writes with app_source='jobber'
// (so the visit Activity tab reads "...in Jobber" instead of "System") + optionally the
// Jobber actor's name. NOT the shared `supabase` singleton — that one is reused for
// clients/jobs/invoices/line_items/visit_locations + by webhook-airtable/samsara and MUST
// stay headerless so their ADR-016 attribution is unaffected. Used ONLY for the visits-table
// writes in handleVisit. Completion names come from the stored visits.completed_by column;
// x-actor-name carries createdBy on insert (createdBy has no column).
const _jobberSbUrl = Deno.env.get('SUPABASE_URL')!
const _jobberSbKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
function jobberVisitClient(actorName?: string | null) {
  const headers: Record<string, string> = { 'x-app-source': 'jobber' }
  const a = (actorName ?? '').split('').filter((ch) => ch.charCodeAt(0) >= 32).join('').trim().slice(0, 120)
  if (a) headers['x-actor-name'] = a
  return createClient(_jobberSbUrl, _jobberSbKey, { auth: { persistSession: false, autoRefreshToken: false }, global: { headers } })
}
const supabaseJobber = jobberVisitClient()
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
// ET ('America/New_York') wall-clock { date, time } of a UTC timestamp.
function etParts(d: Date): { date: string; time: string } {
  const f = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false })
  const p: Record<string, string> = {}
  for (const part of f.formatToParts(d)) p[part.type] = part.value
  return { date: `${p.year}-${p.month}-${p.day}`, time: `${p.hour}:${p.minute}:${p.second}` }
}
// visit_date = the ET CLOCK date of the Jobber start (the day it actually ran, matching how
// Jobber displays it). The operating-night / overnight-shift concept is metadata for
// understanding WHICH shift did the work — it must NOT move the visit's date (Fred 2026-07-02).
// So no early-AM -1 shift: the DB trigger fn_reconcile_visit_operating_date enforces the same.
// (Still ET-based, so it does NOT reintroduce the old `.slice(0,10)` UTC +1 bug — 126 rows.)
function operatingDateET(iso: string | null | undefined): string | null {
  if (!iso) return null
  return etParts(new Date(iso)).date
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
        // Jobber's OAuth token endpoint requires application/x-www-form-urlencoded
        // (OAuth 2.0 spec). Posting JSON here silently fails the refresh and falls
        // back to the (also-expired) env token -> 401 on the next GraphQL call.
        // Fixed 2026-06-01.
        const resp = await fetch(JOBBER_TOKEN_URL, {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            grant_type: 'refresh_token',
            refresh_token: cached.refresh_token,
            client_id: cached.client_id,
            client_secret: cached.client_secret,
          }).toString(),
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
        customFields { __typename ... on CustomFieldText { label valueText } }
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
  //
  // ⚠⚠ 2026-07-31 — THE NAME IS NO LONGER THE SOURCE OF THE CODE.
  // Yannick added a `Client Code` custom field on Jobber clients and the naming
  // convention flips from "CODE name" to "name - CODE". Read the FIELD first and
  // treat the name only as a legacy fallback, because after the rename there is
  // no prefix left to parse.
  //
  // ⚠ THIS ORDERING IS LOAD-BEARING — DO NOT "SIMPLIFY" BACK TO PREFIX-ONLY.
  // The old parser matched `^NNN-XX ` and stored the REMAINDER as clients.name,
  // which is why our names are clean and codes live in their own column. Against
  // a renamed client ("Herzka Residence - 027-HER") it matches nothing, so it
  // would store the WHOLE STRING — code included — as the display name, for all
  // 274 renamed clients, within one */5 poll, and every app that renders a client
  // name inherits it. Measured before the migration; this block is the fix.
  //
  // Code charset includes '&' (131-M&U is live). The old class was [A-Z0-9]*,
  // which is exactly why 131-M&U is the ONE client whose stored name still
  // carries its prefix today — a working preview of the fleet-wide failure.
  const CODE_RE = String.raw`\d{2,3}\s*-\s*[A-Za-z0-9&]+`
  let parsedCode: string | null = null
  let nameNormalized = name

  // 1) the custom field — authoritative once Yannick's backfill has run
  const cfCode = (c.customFields ?? [])
    .find((f: any) => String(f?.label ?? '').trim().toLowerCase() === 'client code')
    ?.valueText
  if (cfCode && new RegExp(`^${CODE_RE}$`).test(String(cfCode).trim())) {
    parsedCode = String(cfCode).trim().replace(/\s+/g, '')
  }

  // 2) strip the code out of the display name wherever it sits, so clients.name
  //    stays the clean business name through BOTH naming conventions.
  //    Order matters: suffix (new) -> parenthetical -> prefix (legacy).
  const mSuffix = name.match(new RegExp(`^(.*?)\\s+-\\s+(${CODE_RE})\\s*$`))
  const mParen  = name.match(new RegExp(`^(.*?)\\s*[([]\\s*(${CODE_RE})\\s*[)\\]]\\s*$`))
  const mPrefix = name.match(new RegExp(`^\\s*(${CODE_RE})[\\s,:-]+(.+)$`))
  if (mSuffix)      { nameNormalized = mSuffix[1].trim(); parsedCode ??= mSuffix[2].replace(/\s+/g, '') }
  else if (mParen)  { nameNormalized = mParen[1].trim();  parsedCode ??= mParen[2].replace(/\s+/g, '') }
  else if (mPrefix) { nameNormalized = mPrefix[2].trim(); parsedCode ??= mPrefix[1].replace(/\s+/g, '') }
  else {
    // legacy bare "000- Kaffe" pollution: strip, but never promote to a code.
    const bare = name.match(/^\s*\d{3}-\s+/)
    if (bare) nameNormalized = name.replace(bare[0], '').trim()
  }

  // Check if client already exists via entity_source_links.
  // Lookup uses the full base64 GID (consistent with populate.js step 1
  // which stores `jc.id` directly — also a base64 GID).
  const existingId = await findEntityBySourceId('client', 'jobber', gid)

  // v2 clients table: id, client_code, name, status, balance, notes, client_class
  // NB: `status` is set per-branch below, NOT here. Airtable is canonical for the
  // ACTIVE/RECURRING/PAUSED/INACTIVE distinction; Jobber only knows archived/active.
  // Writing 'ACTIVE' unconditionally clobbered AT's RECURRING/PAUSED on every
  // cron_jobber replay (status flapped — fixed 2026-05-31). See
  // docs/fixes/2026-05-31_client_status_flapping.md.
  const clientRow: Record<string, unknown> = {
    name: nameNormalized,
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
  let entityId: number

  if (existingId) {
    // Read current status + code. Airtable owns the ACTIVE/RECURRING/PAUSED/
    // INACTIVE distinction, so DON'T clobber a richer AT status with 'ACTIVE':
    //   - Jobber archived       → INACTIVE (deactivation is authoritative)
    //   - reactivating INACTIVE → ACTIVE
    //   - otherwise             → leave status untouched (preserve AT value)
    const { data: cur } = await supabase
      .from('clients').select('client_code, status, client_class_source').eq('id', existingId).maybeSingle()
    // Respect a manual client_class override (e.g. residential clients that Jobber
    // reports isCompany=true — 119-ME/121-FRO/126-YM). The DB trigger
    // trg_clients_protect_manual_class also enforces this, but dropping the field
    // here avoids a guaranteed no-op write on every poll. See
    // docs/migrations/2026-06-24_clients_class_source.sql.
    if (cur && (cur as { client_class_source?: string }).client_class_source === 'manual') {
      delete clientRow.client_class
    }
    if (c.isArchived) {
      clientRow.status = 'INACTIVE'
    } else if (cur && cur.status === 'INACTIVE') {
      clientRow.status = 'ACTIVE'
    }
    // Self-heal client_code only if missing — Airtable owns the authoritative value,
    // and Jobber's company-name prefix is NOT reliable enough to overwrite an existing
    // code (Yan frequently typos/truncates it there: e.g. "133-MU" for 133-MUT,
    // "140-TCY" for 140-TYO). Drift correction is handled out-of-band by the
    // reconciliation probe scripts/probes/audit_client_code_drift.js, which only heals
    // when the Jobber prefix AND Airtable's Client Code #3 AGREE against a stale DB
    // value (the 2026-06-17 221-MP→224-MP case). See that probe + ADR / runbook.
    //
    // GUARD (2026-07-05): only heal if the parsed code isn't already held by another
    // ACTIVE client. Yan sometimes types the same NNN-XX prefix into TWO Jobber records
    // for one business (a Jobber-side duplicate — 145-NON on clients 152 + 153). Writing
    // the shared code onto this row 23505s on clients_active_client_code_uniq, and the
    // */5 poll re-throws + replays the same CLIENT_UPDATE forever (288 failures/day).
    // Skip the code write silently here; the duplicate is surfaced out-of-band
    // (client_insert_potential_dup warning at create time + the weekly dedup audit),
    // and collapsing the two Jobber records is a manual merge decision.
    let healCode = !!(parsedCode && cur && !cur.client_code)
    if (healCode) {
      const { data: codeHolder } = await supabase
        .from('clients').select('id')
        .eq('client_code', parsedCode as string)
        .neq('id', existingId)
        .neq('status', 'INACTIVE')
        .limit(1)
      if (codeHolder && codeHolder.length) healCode = false
    }
    if (healCode) clientRow.client_code = parsedCode
    // supabaseJobber: handleClient is only ever CLIENT_CREATE/UPDATE/DESTROY -> audit
    // app_source='jobber' ("Changed in Jobber") instead of bare 'sql'/"System".
    const { error } = await supabaseJobber.from('clients').update(clientRow).eq('id', existingId)
    if (error) throw new Error(`Client update failed: ${error.message}`)
    entityId = existingId
  } else {
    // INSERT — Jobber-only default; the AT webhook refines status later if the
    // client is in Airtable.
    clientRow.status = c.isArchived ? 'INACTIVE' : 'ACTIVE'
    if (parsedCode) clientRow.client_code = parsedCode
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
          // GUARD (2026-07-14): mirror the UPDATE-path guard (~L346). If a
          // NON-INACTIVE client already holds parsedCode, do NOT set it on this
          // INSERT — it 23505s on clients_active_client_code_uniq and the */5
          // poll replays the CLIENT_UPDATE forever (the 963-failure loop that
          // hit client 153 / gid 113794289 via the UPDATE path 2026-07-02→06,
          // before THAT path was guarded; this closes the symmetric INSERT gap).
          // Insert the client WITHOUT the code (Jobber GID is source of truth);
          // the warning below + weekly dedup audit surface it for a manual
          // merge / code assignment.
          if (parsedCode && dup.some((d) => (d as { status?: string }).status !== 'INACTIVE')) {
            delete clientRow.client_code
          }
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
    const { data: inserted, error } = await supabaseJobber
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
  //
  // ⚠ THE onConflict LIST IS PINNED TO A CONSTRAINT — DO NOT SHORTEN IT BACK.
  // Migration 2026-07-30_0539 replaced UNIQUE (client_id, contact_role) with
  //   UNIQUE NULLS NOT DISTINCT (client_id, property_id, contact_role)
  // so the Client App's "Add Contact" can hold one contact per ROLE per PROPERTY.
  // PostgREST requires onConflict to name a column set backed by a real unique
  // constraint; the old 2-column form now resolves to nothing and every contact
  // upsert would fail 42P10. Because the Jobber feed is poll-replayed rather than
  // fire-and-forget, that failure would repeat on every poll, not once.
  //
  // `property_id: null` is sent EXPLICITLY (not left to the column default) because
  // it is part of the conflict target. Jobber contacts are client-level: Jobber has
  // no concept of our per-property contacts. NULLS NOT DISTINCT is what keeps the
  // original guarantee intact here — the NULL is treated as a real value, so this
  // still de-duplicates to exactly one client-level `primary` row per client
  // (verified: after this upsert the row count stays 1, it does not become 2).
  if (primaryEmail || primaryPhone) {
    const contactRow = {
      client_id: entityId,
      property_id: null,
      contact_role: 'primary',
      name: name,
      email: primaryEmail ?? null,
      phone: primaryPhone ?? null,
    }
    await supabase
      .from('client_contacts')
      .upsert(contactRow, { onConflict: 'client_id,property_id,contact_role' })
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

// Stage 2 (2026-06-27): mirror Jobber's CURRENT assignedUsers into public.visit_team —
// the table the Calendar drawer's team-select AND the on-purpose push read — so the
// Calendar shows the real driver. Diff-only (skip the write when the set already matches,
// so no audit-log churn) and we DO NOT bump visits.team_rev: adopting Jobber's crew must
// never echo back to Jobber as an "office edit" (Jobber is the source of truth for crew).
// assigned_driver_id (NOT watched by trg_push_visit_update) tracks the primary for display.
async function syncVisitTeamFromJobber(visitId: number, nodes: any[] | undefined) {
  const want = new Set<number>()
  for (const member of (nodes || [])) {
    if (!member?.id) continue
    const empId = await findEntityBySourceId('employee', 'jobber', member.id)
    if (empId) want.add(empId)
  }
  const { data: curRows } = await supabase.from('visit_team').select('employee_id').eq('visit_id', visitId)
  const cur = new Set((curRows || []).map((r: any) => r.employee_id as number))
  const same = cur.size === want.size && [...want].every((id) => cur.has(id))
  if (same) return
  const ids = [...want]
  await supabase.from('visit_team').delete().eq('visit_id', visitId)
  if (ids.length) {
    await supabase.from('visit_team').insert(ids.map((id) => ({ visit_id: visitId, employee_id: id })))
  }
  await supabase.from('visits').update({ assigned_driver_id: ids[0] ?? null }).eq('id', visitId)
  console.log(`[handleVisit] visit_team mirrored from Jobber for ${visitId}: [${ids.join(',')}]`)
}

async function handleVisit(numericId: string, topic: string): Promise<{ entity_id: number }> {
  const gid = btoa(`gid://Jobber/Visit/${numericId}`)
  const data: any = await gql(
    `query($id: EncodedId!) {
      visit(id: $id) {
        id title visitStatus startAt endAt allDay completedAt completedBy createdBy { name { full } }
        job { id client { id } property { id } }
        invoice { id }
        assignedUsers { nodes { id name { first last } } }
        lineItems(first: 50) { nodes { name description quantity unitPrice totalPrice taxable } }
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
  // our DB. Matched by Jobber client GID. (Added 2026-05-30; emptied 2026-06-24 —
  // 112-YA "Yan's Restaurant" un-excluded per Fred so its visits are visible in
  // the Calendar: its old leftover recurring job that generated ~81 visits to 2030
  // was archived in the 2026-06-23 restructure, so 112-YA now has only its real
  // jobs/visits. Re-add a GID here to exclude a future test account.)
  const EXCLUDED_JOBBER_CLIENT_GIDS = new Set<string>([])
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
  // ⚠ VOCABULARY CHANGED 2026-08-03. service_type now carries the real service
  // names (Pumping / Cleaning / Warranty of Drainage) rather than GT/CL/WD/LS.
  // Lift Station folds into Pumping, per the service catalogue sheet's column G,
  // which classifies code 04 "Lift Station & Tank Cleaning" as Pumping.
  // The branch below is KEPT even though it now returns the same value as the
  // grease-trap branch: it preserves the documented ordering, and the equipment
  // distinction still lives in service_line_items.location_target.
  const inferServiceType = (title: string | null): string | null => {
    if (!title) return null
    const t = title.toLowerCase()
    if (/lyft\s*station/.test(t)) return 'Pumping'
    if (/grease trap|grease pump|grey water|gray water|\bgt\b/.test(t)) return 'Pumping'
    if (/service call|\bclog|emergency|hydrojet|\bdrain|\briser|fire pump|warranty|\brepair/.test(t)) return 'Cleaning'
    if (/\bservice\b/.test(t) && !/dump/.test(t)) return 'Cleaning'
    return null
  }

  // Derive service_type from the visit's LINE ITEMS (canonical), falling back to the title
  // guess, then defaulting to 'Pumping' so a registered visit is never left without one (Fred
  // 2026-06-08). Codes map per public.service_line_items.service_kind. This map is a pure
  // translation of the old one -- deliberately NOT extended to cover codes 03/04/10/11/15-18
  // etc., because adding them would change which visits get which value, and this change is a
  // rename, not a reclassification. Enrich it separately if ever wanted.
  const CODE_SVC: Record<string, string> = {
    '01': 'Pumping', '02': 'Pumping', '09': 'Pumping',
    '05': 'Cleaning', '06': 'Cleaning', '07': 'Cleaning',
    '12': 'Cleaning', '13': 'Cleaning', '14': 'Cleaning',
    '08': 'Warranty of Drainage',
  }
  const lineItemSvc = (name: string | null): string | null => {
    if (!name) return null
    const code = name.match(/^\s*(\d{2})\s*-/)?.[1]
    if (code && CODE_SVC[code]) return CODE_SVC[code]
    const t = name.toLowerCase()
    if (/grease trap/.test(t)) return 'Pumping'
    if (/warranty of drain/.test(t)) return 'Warranty of Drainage'
    if (/main line|auxiliary|aux cleaning|tank cleaning|\bcleaning\b/.test(t)) return 'Cleaning'
    return null
  }

  // The transitional dual-vocabulary lookup was REMOVED 2026-08-03 with Phase C1.
  // It existed because this edge function deploys separately from the SQL
  // migration, so there was necessarily a window where the DB held one
  // vocabulary and this code emitted the other -- and the placeholder-promotion
  // query below matches on service_type, so a mismatch silently INSERTED A
  // DUPLICATE VISIT instead of promoting the placeholder, with no error anywhere.
  // That window is closed: the CHECK constraints now admit only the real service
  // names, so a legacy value cannot exist to be matched. Reintroduce this shape
  // for any future vocabulary change -- the duplicate-visit failure is silent.
  const svcMatchSet = (s: unknown): string[] => (typeof s === 'string' ? [s] : [])

  // Track whether the derive is CONCRETE (line item or explicit title match) vs the bare default,
  // so the inbound UPDATE path can avoid clobbering a stored value with the default when a Jobber
  // title edit drops the keyword (2026-06-27 clobber-class fix). The default applies only to
  // INSERT/promote.
  let serviceTypeConcrete: string | null = null
  for (const li of (v.lineItems?.nodes ?? [])) { const s = lineItemSvc(li?.name ?? null); if (s) { serviceTypeConcrete = s; break } }
  if (!serviceTypeConcrete) serviceTypeConcrete = inferServiceType(v.title ?? null)
  const serviceType = serviceTypeConcrete ?? 'Pumping'

  const visitRow: Record<string, unknown> = {
    title: v.title ?? null,
    service_type: serviceType,
    visit_status: statusMap[v.visitStatus?.toLowerCase()] ?? 'scheduled',
    start_at: v.startAt ?? null,
    end_at: v.endAt ?? null,
    completed_at: v.completedAt ?? null,
    // completed_by = name of the user who clicked "Complete" in Jobber's app
    // (often Diego, the office processor — NOT the driver). Driver attribution
    // lives in visit_assignments via assignedUsers.
    completed_by: v.completedBy ?? null,
    // visit_date is NOT NULL — derive the ET OPERATING date from startAt → endAt → completedAt
    // (operatingDateET handles the overnight rule + all-day). If all three are missing, skip.
    visit_date: operatingDateET(v.startAt ?? v.endAt ?? v.completedAt),
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
    // Loop-guard (2026-06-01; widened 2026-06-24, audit follow-up #3): visits MASTERED by our
    // side — source='visit-calendar' (Calendar) OR 'supabase_cron' (SA generator) — own their
    // SCHEDULE + title; the Calendar/cron -> Jobber push (jobber-push-visit) is the writer. The
    // inbound Jobber poll must NOT clobber their visit_date/start_at/end_at/title/job_id (it would
    // corrupt Anytime/all-day visits — Jobber returns a concrete allDay startAt — and fight the
    // push). It MAY sync COMPLETION (visit_status/completed_at/completed_by) so a field-completed
    // visit reflects in our DB. EXCEPTION (2026-06-26): it MAY also FILL start_at/end_at when ours
    // is NULL and Jobber holds a real timed slot (allDay=false) — Diego routes still-untimed SA
    // visits by setting their hour in Jobber's weekly view; fill-if-empty captures that hour without
    // clobbering a Calendar-set time. Loop-safe: a visit_status change re-fires trg_push_visit_update,
    // but jobber-push-visit only re-asserts the SAME schedule -> Jobber unchanged -> no echo.
    const { data: existing } = await supabase.from('visits').select('source, start_at, visit_status').eq('id', existingId).maybeSingle()
    // A 'skipped' visit is intentionally REMOVED from Jobber. An in-flight Jobber replay
    // (VISIT_UPDATE/COMPLETE arriving before the removal propagates, or on a stale link if the
    // visitDelete failed) must NOT resurrect it — ignore the inbound change. The skip-removal retry
    // (resolve-stale cron) will unlink it; unskip_visit is the only sanctioned way back to Jobber.
    if (existing?.visit_status === 'skipped') {
      console.log(`[handleVisit] visit ${numericId} is skipped in DB — ignoring inbound Jobber change (not resurrecting)`)
      return { entity_id: existingId }
    }
    if (existing?.source === 'visit-calendar' || existing?.source === 'supabase_cron') {
      const compRow: Record<string, unknown> = {}
      if (v.completedAt !== undefined) compRow.completed_at = v.completedAt ?? null
      if (v.completedBy !== undefined) compRow.completed_by = v.completedBy ?? null
      const inStatus = statusMap[v.visitStatus?.toLowerCase() ?? '']
      if (inStatus) compRow.visit_status = inStatus
      // Adopt the route HOUR Diego sets in Jobber's weekly view for a STILL-UNTIMED visit:
      // FILL start_at/end_at ONLY when ours is NULL and Jobber holds a real timed slot
      // (allDay=false). Diego routes the SA-generated (supabase_cron) visits by dragging
      // them to an hour in Jobber; fill-if-empty captures that without clobbering a
      // Calendar-set time (an already-timed visit's re-time or date move stays the */30
      // drift reconciler's job). Same value flows back via the push -> Jobber unchanged.
      if (existing.start_at == null && v.allDay === false && v.startAt) {
        compRow.start_at = v.startAt
        compRow.end_at = v.endAt ?? null
      }
      if (Object.keys(compRow).length > 0) {
        const { error } = await supabaseJobber.from('visits').update(compRow).eq('id', existingId)
        if (error) throw new Error(`Visit completion/hour-sync failed: ${error.message}`)
      }
      // Stage 2 (2026-06-27): mirror Jobber's crew into visit_team so the Calendar drawer
      // shows the real driver (these DB-mastered supabase_cron/calendar visits are exactly
      // what the Calendar displays). Diff-only, no team_rev bump -> no echo back to Jobber.
      await syncVisitTeamFromJobber(existingId, v.assignedUsers?.nodes)
      console.log(`[handleVisit] visit ${numericId} -> ${existing.source}-mastered ${existingId}; completion + fill-hour-if-empty sync`)
      return { entity_id: existingId }
    }
    // Standard update path — Jobber-mastered visit. Do NOT clobber a stored service_type with
    // the bare default: when the derive is non-concrete, omit service_type so the stored value sticks.
    // This also protects a legacy-vocabulary row from being rewritten piecemeal during the
    // migration window; the SQL migration owns that conversion, not this handler.
    const updateRow = serviceTypeConcrete ? visitRow : (() => { const { service_type: _drop, ...rest } = visitRow; return rest })()
    const { error } = await supabaseJobber.from('visits').update(updateRow).eq('id', existingId)
    if (error) throw new Error(`Visit update failed: ${error.message}`)
    entityId = existingId
  } else {
    // Try to find a matching supabase_cron-generated scheduled placeholder
    // before inserting a new row. This keeps the Supabase cron's planned
    // schedule and Jobber's actual execution as a SINGLE row through the
    // visit lifecycle. Match criteria (kept tight to avoid false promotions):
    //   - client_id and service_type both match.
    //     ⚠ THIS MATCH IS THE SILENT FAILURE POINT OF ANY VOCABULARY CHANGE.
    //     If this handler and the stored placeholder ever disagree on the value,
    //     the match does not error — it finds nothing and INSERTS A DUPLICATE
    //     VISIT instead of promoting the placeholder. During the 2026-08-03
    //     rename this accepted both vocabularies for exactly that reason; that
    //     shim was removed with Phase C1 once legacy values became impossible.
    //     Reintroduce it before any future vocabulary change, not after.
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
        .in('service_type', svcMatchSet(visitRow.service_type))
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
      const { error } = await supabaseJobber.from('visits').update(promotionRow).eq('id', promoteId)
      if (error) throw new Error(`Visit promotion failed: ${error.message}`)
      entityId = promoteId
      promotedFromCron = true
      console.log(`[handleVisit] promoted supabase_cron row ${promoteId} → jobber GID ${gid.slice(0, 30)}…`)
    } else {
      // No matching placeholder; insert fresh.
      const { data: inserted, error } = await jobberVisitClient(v.createdBy?.name?.full)
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

  // Sync visit-scoped line items (idempotent: wipe + replace by visit_id). Mirrors the
  // invoice line-item sync — captures each scheduled visit's services verbatim (incl. the
  // formatted "NN - ..." codes) so the registered visit carries its full service detail.
  const visitLineNodes: any[] = v.lineItems?.nodes ?? []
  await supabase.from('line_items').delete().eq('visit_id', entityId)
  if (visitLineNodes.length > 0) {
    const liRows = visitLineNodes.map((n: any) => ({
      visit_id: entityId,
      name: n.name ?? null,
      description: n.description ?? null,
      quantity: n.quantity ?? null,
      unit_price: n.unitPrice ?? null,
      total_price: n.totalPrice ?? null,
      taxable: n.taxable ?? null,
    }))
    const { error: liErr } = await supabase.from('line_items').insert(liRows)
    if (liErr) console.error(`Visit ${numericId}: line_items insert failed:`, liErr.message)
  }

  // Derive DERM-required from this visit's line items (visit/invoice/job-scoped, per the taxonomy
  // "Requires DERM reporting" rule). MONOTONIC + idempotent in SQL: never demotes a known TRUE,
  // never writes NULL, only writes a real change. Best-effort/near-real-time; the nightly pg_cron
  // re-derive (derm-required-rederive) is the catch-up for invoice line items that arrive later.
  // supabaseJobber: the RPC's inner UPDATE inherits request.headers x-app-source='jobber'
  // (SECURITY INVOKER) -> the derm_required flip audits as "Changed in Jobber", not "System".
  const { error: dermErr } = await supabaseJobber.rpc('set_visit_derm_required', { p_visit_id: entityId })
  if (dermErr) console.error(`Visit ${numericId}: set_visit_derm_required failed:`, dermErr.message)

  // Maintain visit_locations (M:N): attribute the visit to its client's GDO-confirmed
  // manhole(s). Seed defaults ONLY when the visit has none yet, so FP/ops manual tagging
  // survives every replay. Single-location client -> its one location; multi-location ->
  // only locations carrying an active GDO (a confirmed manhole). Clients whose locations
  // lack a linked GDO (e.g. Wynd, pending D-track) stay unlinked until tagged.
  if (clientId) {
    const { data: existingVL } = await supabase
      .from('visit_locations').select('visit_id').eq('visit_id', entityId).limit(1)
    if (!existingVL || existingVL.length === 0) {
      const { data: locs } = await supabase
        .from('client_locations').select('id').eq('client_id', clientId)
      let targetLocIds: number[] = []
      if (locs && locs.length === 1) {
        targetLocIds = [locs[0].id]
      } else if (locs && locs.length > 1) {
        const locIds = locs.map((l: any) => l.id)
        const { data: gdoLocs } = await supabase
          .from('gdos').select('client_location_id')
          .eq('status', 'ACTIVE').in('client_location_id', locIds)
        targetLocIds = [...new Set((gdoLocs ?? [])
          .map((g: any) => g.client_location_id).filter((x: any) => x != null))]
      }
      if (targetLocIds.length > 0) {
        const { error: vlErr } = await supabaseJobber.from('visit_locations')
          .insert(targetLocIds.map((id) => ({ visit_id: entityId, client_location_id: id })))
        if (vlErr) console.error(`Visit ${numericId}: visit_locations insert failed:`, vlErr.message)
      }
    }
  }

  // Upsert visit_assignments for assigned team members (historical crew record;
  // upsert-only, never deletes). FIX 2026-05-15: pass member.id (full base64 gid)
  // directly — same format as entity_source_links.source_id stores.
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

  // Stage 2 (2026-06-27): mirror Jobber's crew into visit_team (Calendar drawer + push). No echo.
  await syncVisitTeamFromJobber(entityId, v.assignedUsers?.nodes)

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
      const { error: vErr } = await supabaseJobber.from('visits').update({ invoice_id: entityId }).eq('id', ourVisitId)
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
        customFields { __typename ... on CustomFieldNumeric { label valueNumeric } }
        lineItems(first: 50) { nodes { name description quantity unitPrice totalPrice taxable } }
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
  // Frequency (Jobber "Frequency" numeric custom field) → frequency_days (the SA cadence; SC = 0/absent)
  const freqCF = (j.customFields ?? []).find((cf: any) => (cf?.label ?? '').toLowerCase() === 'frequency')
  if (freqCF && typeof freqCF.valueNumeric === 'number') jobRow.frequency_days = freqCF.valueNumeric

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

  // Sync job-scoped line items. Idempotent: wipe job-scoped rows + re-insert what Jobber holds.
  //
  // 🛑 THE `if (isSA)` GATE WAS REMOVED 2026-08-06. It encoded "Service Agreement jobs carry
  // their agreed services; Service Call jobs carry none", which stopped being true when the
  // Client App gained fee lines (codes 25/26/27) on Service Call jobs. With the gate in place a
  // fee pushed to an SC job was real in Jobber but wiped from our mirror within 5 minutes, so
  // the job dialog rendered it UNCHECKED and the next save deleted it from Jobber for real.
  //
  // ⚠ This is writer 2 of THREE that must agree. The others are jobToRecord's `includeLines`
  // in save-client-job and `want = isSA ? nodes : []` in sync-jobber-job-drift. Re-introducing
  // the gate in any one of them re-arms the self-deleting fee. They are one change.
  //
  // ⚠ Safe for DERM only because 2026-08-06_1448 made fee lines answer NULL rather than FALSE
  // in fn_line_item_requires_derm. Mirroring a fee makes it an SC visit's only reachable line,
  // and FALSE would have derived "definitively not required".
  //
  // Measured before the change: of 630 SC jobs, the only 8 holding job-scoped lines in Jobber
  // were archived, so this widens what we mirror with no live back-fill surprise.
  const jobLineNodes: any[] = j.lineItems?.nodes ?? []
  await supabase.from('line_items').delete().eq('job_id', entityId)
  if (jobLineNodes.length > 0) {
    await supabase.from('line_items').insert(jobLineNodes.map((n: any) => ({
      job_id: entityId, name: n.name, description: n.description ?? '',
      quantity: n.quantity ?? 1, unit_price: n.unitPrice ?? 0,
      total_price: n.totalPrice ?? 0, taxable: !!n.taxable,
    })))
  }

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

  // ⚠ `?? null` does NOT catch an EMPTY STRING, and Jobber returns "" rather than null for a
  // property with no label. Found by dry-running the property poll before enabling it
  // (scripts/sync/dryrun_property_poll.js): of 389 matched properties, 4 would have had their
  // name rewritten, and one of those was a real loss - property 206 "Burger Fi Doral" -> "".
  // The other 3 were NULL -> "", pure churn that makes every future diff noisier.
  // So: blank from Jobber never overwrites a name we already hold.
  const jobberName = typeof p.name === 'string' ? p.name.trim() : null
  const row: Record<string, unknown> = {
    address: p.address?.street ?? null,
    city: p.address?.city ?? null,
    state: p.address?.province ?? 'FL',
    zip: p.address?.postalCode ?? null,
  }
  if (jobberName) row.name = jobberName
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
  // A 'skipped' visit is intentionally removed from Jobber by US — an inbound VISIT_DESTROY for it
  // (usually our own skip-removal echoing back through the poll before the unlink lands) must NOT
  // flip it to 'cancelled' (that would lose the skip status/reason and drop it out of the skip
  // watchdogs). Instead complete the skip's intended end-state: unlink the ESL and keep 'skipped'.
  if (entity_type === 'visit') {
    const { data: vrow } = await supabase.from('visits').select('visit_status').eq('id', existingId).maybeSingle()
    if (vrow?.visit_status === 'skipped') {
      await supabase.from('entity_source_links').delete()
        .eq('entity_type', 'visit').eq('entity_id', existingId).eq('source_system', 'jobber')
      console.log(`[softStatusFlip visit] ${existingId} is skipped in DB — unlinked instead of cancelling (skip-removal echo)`)
      return { entity_id: existingId }
    }
  }
  // supabaseJobber: every *_DESTROY / JOB_CLOSED topic is Jobber-originated -> the
  // cancel/archive audits as "Changed in Jobber" (visits/clients are user-visible).
  const { error } = await supabaseJobber.from(table).update({ [statusCol]: newStatus }).eq('id', existingId)
  if (error) throw new Error(`${table}.${statusCol}='${newStatus}' failed: ${error.message}`)
  return { entity_id: existingId }
}

const handleClientDestroy = (id: string) => softStatusFlip('client', 'clients', 'status', 'INACTIVE', id)
const handleJobClosed     = (id: string) => softStatusFlip('job',    'jobs',    'job_status', 'closed',    id)
const handleJobDestroy    = (id: string) => softStatusFlip('job',    'jobs',    'job_status', 'destroyed', id)
const handleVisitDestroy  = (id: string) => softStatusFlip('visit',  'visits',  'visit_status', 'cancelled', id) // double-L: canonical enum + visits_visit_status_chk
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
// Visit inbound from Jobber is DISABLED (2026-06-02, per Fred): the Calendar app now
// owns the full visit lifecycle (generated + completed in-app); Jobber visits are no
// longer pulled in, and the office mirrors Calendar visits into Jobber by hand. We still
// ACK these events with 200 so Jobber doesn't retry — we just don't process them.
async function handleVisitInboundDisabled(_id: string, topic: string): Promise<{ entity_id: number }> {
  console.log(`[webhook-jobber] visit-inbound disabled — ignoring ${topic}`)
  return { entity_id: 0 }
}

const TOPIC_HANDLERS: Record<string, (id: string, topic: string) => Promise<{ entity_id: number }>> = {
  CLIENT_CREATE: handleClient,
  CLIENT_UPDATE: handleClient,
  CLIENT_DESTROY: handleClientDestroy,
  // Visit inbound RE-ENABLED 2026-06-05 (Fred, TEMPORARY — repopulate visits from Jobber; turn off ~next week):
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
