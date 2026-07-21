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
      // Object syntax — positional call was passing 'client' as the whole link
      // object, leaving entity_type undefined → NULL constraint violation.
      await upsertEntityLink({
        entity_type: 'client',
        entity_id: clientId,
        source_system: 'airtable',
        source_id: recordId,
      })
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
  // Service Type multi-select is canonical. AT label → our code (audit 2026-05-14):
  //   "Grease Trap"          → GT
  //   "Gray Water pumping"   → GT  (GT-alternative service per Fred)
  //   "AUX Cleaning"         → CL  (NOT "Main CL" — that's a label only)
  //   "Warranty of drainage" → WD
  //   "Lift Station"         → LS  (NOT 'lyft' — old typo)
  //   "Main CL", "Catch Bassin", "Floor Drain Cleaning",
  //   "Requires Phone Call"  → no mapping (Main CL is org-label only;
  //                            Catch Bassin / Floor Drain Cleaning are
  //                            services we don't perform per Fred 2026-05-14)
  const serviceTypeRaw = fields['Service Type']
  const subscribedTypes = new Set<string>()
  if (Array.isArray(serviceTypeRaw)) {
    for (const v of serviceTypeRaw) {
      const name = (v && typeof v === 'object' && 'name' in (v as Record<string, unknown>))
        ? String((v as Record<string, unknown>).name).toLowerCase()
        : String(v).toLowerCase()
      if (name.includes('grease trap') || name === 'gt' || name.includes('gray water pumping')) subscribedTypes.add('GT')
      else if (name.includes('aux cleaning') || name === 'cl') subscribedTypes.add('CL')
      else if (name === 'wd' || name.includes('warranty') || name.includes('water dis')) subscribedTypes.add('WD')
      else if (name.includes('lift station') || name === 'ls') subscribedTypes.add('LS')
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

  // -- 4. GDO permit (GT only) — Phase 4b canonical-only 2026-05-25 --------
  // Writes the GDO Number + expiration to public.gdos (canonical source of
  // truth). The legacy dual-write to service_configs.permit_* was removed
  // in Phase 4b after view rewires (25t) confirmed no readers depend on
  // the legacy columns. The columns themselves are dropped in migration 25u.
  // GUARD 1c (2026-07-21): normalize zero-padding BEFORE any guard or write.
  //
  // public.gdos is unique on (client_id, gdo_number), so "GDO-000951" and "GDO-00951" are two
  // DIFFERENT keys for the same client and both rows coexist. That is exactly what happened to
  // 132-PUM Pummarola: inserted padded on 05-20, hand-repaired to GDO-00951 on 05-25, then
  // RE-CREATED padded by an AT re-ingest on 05-26, after which it was demoted and re-promoted
  // four times (06-01/06-05, 06-27/06-29, 07-17).
  //
  // GUARD 1b below does NOT catch this: "GDO-000951" is a perfectly canonical ^GDO-\d+$ string.
  // It is not a placeholder, it is a real number with an extra leading zero, so it sails through
  // and lands as a duplicate permit. Deleting the duplicate row does NOT fix it either — the AT
  // field still carries the padded value, so the next client touch re-INSERTs it as ACTIVE.
  // Normalizing on the way in is the only durable fix: the padded form now resolves onto the
  // existing correct row and UPDATEs it instead of creating a twin.
  //
  // Strip leading zeros, then re-pad to the 5-digit house style (all 182 canonical permits in
  // Prod are 5 digits). Deliberately does NOT cap the length: a genuinely longer permit
  // (e.g. GDO-123456) has no leading zeros to strip and passes through untouched. Do not
  // "simplify" this to a fixed-width pad — that would corrupt a real 6+ digit permit.
  // The hyphen is REQUIRED here on purpose, matching GUARD 1b exactly. A tolerant `GDO-?` would
  // newly accept "GDO11886", which GUARD 1b rejects today — and 0 hyphenless values have ever been
  // written to public.gdos, so that tolerance would be unverified widening of a write path. Read
  // tolerance is the GDO Slack bot's business; writes stay strict. Anything not matching falls
  // through untouched to GUARD 1 / 1b, which is what rejects it.
  const normalizeGdo = (raw: string): string => {
    const m = /^\s*GDO-(\d+)\s*$/i.exec(raw)
    if (!m) return raw.trim()
    const digits = m[1].replace(/^0+/, '') || '0'
    return `GDO-${digits.padStart(5, '0')}`
  }

  const gdoRaw = strVal(fields, 'GDO Number')
  const gdo = gdoRaw ? normalizeGdo(gdoRaw) : gdoRaw
  if (gdoRaw && gdo !== gdoRaw.trim()) {
    console.log(`webhook-airtable: normalized gdo_number "${gdoRaw}" -> "${gdo}" for client ${clientId}`)
  }
  const gdoExp = dateVal(fields, 'GDO expiration date')
  if (gdo || gdoExp) {
    // CANONICAL write to public.gdos.
    // Requires gdo_number (can't insert from expiration alone). Idempotent:
    // try UPDATE on (client_id, gdo_number); INSERT only if no match.
    if (gdo) {
      // GUARD 1: BW placeholder — Broward county has no GDO program (Miami-Dade
      // DERM only). AT data-entry sometimes uses "BW"/"bw" as a marker on Broward
      // clients; that's not a real permit. Reject before any DB write so a sync
      // can't undo the 2026-05-27 Broward cleanup (see probes 72/73).
      if (/^\s*bw\s*$/i.test(gdo)) {
        console.log(
          `webhook-airtable: skipped gdos write for client ${clientId} — gdo_number="${gdo}" is a BW placeholder, Broward has no GDO program`,
        )
      } else if (!/^GDO-\d+$/.test(gdo.trim())) {
        // GUARD 1b (2026-07-21): only canonical GDO-<digits> values may reach
        // public.gdos. AT's "GDO Number" field also carries placeholders
        // ("Not available", "Needs review") and combined strings; the 07-17
        // patch stopped the UPDATE path from re-promoting demoted rows, but
        // this INSERT path kept landing placeholders as ACTIVE rows (ids
        // 211/222 on 07-05 + 07-14), which then surfaced as literal permit
        // numbers on the Field Portal and Calendar. AT is read-only for us
        // and still carries these values, so without the guard they recur.
        console.log(
          `webhook-airtable: skipped gdos write for client ${clientId} — gdo_number="${gdo}" is not a canonical GDO-<digits> permit (placeholder or malformed)`,
        )
      } else {
        const { data: prop } = await supabase
          .from('properties')
          .select('id, county')
          .eq('client_id', clientId)
          .eq('is_primary', true)
          .limit(1)
          .maybeSingle()

        if (prop?.id) {
          // GUARD 2: defence-in-depth — if the primary property is in Broward,
          // skip even if AT supplied a non-BW gdo_number. DERM only issues
          // permits in Miami-Dade. Caller might just have a real-looking
          // GDO-NNNNN typo mapped to a Broward address.
          if (prop.county && /^\s*broward\s*$/i.test(prop.county)) {
            console.log(
              `webhook-airtable: skipped gdos write for client ${clientId}/${gdo} — primary property is in Broward county, DERM only issues in Miami-Dade`,
            )
          } else {
            // UPDATE existing row if (client_id, gdo_number) already present.
            // ⚠ NEVER touch status here (2026-07-17): this path used to force
            // status='ACTIVE', which silently RE-PROMOTED rows the GDO
            // reconciliation had demoted as wrong-permit (PDF proves a
            // different business/address) — Airtable still carries ~28 wrong
            // GDO numbers, so every AT client touch undid the demotions.
            // The row's status is OUR curated belongs/doesn't-belong verdict;
            // AT may refresh the expiration only. New permits INSERT as
            // ACTIVE below. See docs/audits/2026-07-17_gdo_full_audit.md.
            if (gdoExp) {
              const { error: upErr } = await supabase
                .from('gdos')
                .update({ permit_expiration: gdoExp })
                .eq('client_id', clientId)
                .eq('gdo_number', gdo)
              if (upErr) console.error(`gdos expiration update failed for ${clientId}/${gdo}:`, upErr.message)
            }
            const { data: updated, error: upErr } = await supabase
              .from('gdos')
              .select('id')
              .eq('client_id', clientId)
              .eq('gdo_number', gdo)

            if (upErr) {
              console.error(`gdos lookup failed for ${clientId}/${gdo}:`, upErr.message)
            } else if (!updated || updated.length === 0) {
              // No existing row — INSERT new canonical permit
              const { error: insErr } = await supabase.from('gdos').insert({
                client_id: clientId,
                property_id: prop.id,
                gdo_number: gdo,
                permit_expiration: gdoExp || null,
                status: 'ACTIVE',
                notes: `[webhook-airtable] Inserted from AT GDO Number update on ${new Date().toISOString().slice(0, 10)}`,
              })
              if (insErr) console.error(`gdos insert failed for ${clientId}/${gdo}:`, insErr.message)
            }
          }
        } else {
          console.warn(`webhook-airtable: client ${clientId} has no primary property; skipped gdos write for ${gdo}`)
        }
      }
    }
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
// ---- DERM PDF mirror: AT signed URLs expire every ~2h, so we download
// each attachment and re-upload to Supabase Storage with a permanent path.
// Called inline from handleDermRecord after the row's id is known.
const DERM_BUCKET = 'GT - Visits Images'
const DERM_BUCKET_PATH = 'GT%20-%20Visits%20Images'

function extFromContentType(ct: string | null): string {
  if (!ct) return 'jpg'
  if (ct.includes('png')) return 'png'
  if (ct.includes('pdf')) return 'pdf'
  if (ct.includes('webp')) return 'webp'
  return 'jpg'
}

async function mirrorAttachmentToStorage(
  manifestId: number,
  atUrl: string,
  kind: 'manifest' | 'address',
  pageNo = 1,
): Promise<string | null> {
  // Skip if already on Supabase Storage (idempotent — e.g. an update where
  // the URL was already mirrored on a previous webhook fire).
  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
  if (atUrl.startsWith(SUPABASE_URL)) return atUrl
  try {
    const dl = await fetch(atUrl)
    if (!dl.ok) {
      console.warn(`[derm-mirror] download failed ${dl.status} for ${atUrl.slice(0, 60)}...`)
      return null
    }
    const bytes = new Uint8Array(await dl.arrayBuffer())
    const ext = extFromContentType(dl.headers.get('content-type'))
    // Page 1 keeps the legacy path (derm/<id>/manifest.<ext>) so existing URLs
    // in the DB stay valid. Page 2+ get a suffix.
    const objectPath = pageNo === 1
      ? `derm/${manifestId}/${kind}.${ext}`
      : `derm/${manifestId}/${kind}_p${pageNo}.${ext}`
    const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const up = await fetch(
      `${SUPABASE_URL}/storage/v1/object/${DERM_BUCKET_PATH}/${encodeURIComponent(objectPath)}`,
      {
        method: 'POST',
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          'Content-Type': dl.headers.get('content-type') || 'image/jpeg',
          'x-upsert': 'true',
        },
        body: bytes,
      },
    )
    if (!up.ok) {
      console.warn(`[derm-mirror] upload failed ${up.status} for ${objectPath}`)
      return null
    }
    return `${SUPABASE_URL}/storage/v1/object/public/${DERM_BUCKET_PATH}/${encodeURI(objectPath)}`
  } catch (e) {
    console.warn(`[derm-mirror] error: ${(e as Error).message}`)
    return null
  }
}

async function handleDermRecord(recordId: string, fields: Record<string, unknown>): Promise<void> {
  const existingId = await findEntityBySourceId('derm_manifest', 'airtable', recordId)

  // Extract AT attachment URLs. AT fields "DERM Manifest" + "DERM Address"
  // are multipleAttachments arrays of { id, url, ... }. Mapping per DERM
  // Tracker CLAUDE.md rule #4 is 1:1 at the canonical layer (Field Portal
  // view does the inverse mapping later). 2026-05-21 fix — handler was
  // never extracting these, so every webhook-created manifest landed with
  // NULL urls and showed "No PDF" in the app.
  // 2026-05-21 (later): after the row is persisted, mirror these URLs into
  // Supabase Storage (mirrorAttachmentToStorage) so the stored URL is
  // permanent (AT signed URLs expire every ~2h).
  function firstAttachmentUrl(name: string): string | null {
    const v = fields[name]
    if (!Array.isArray(v) || v.length === 0) return null
    const first = v[0] as Record<string, unknown> | string
    if (typeof first === 'string') return null
    return typeof first?.url === 'string' ? (first.url as string) : null
  }

  // 2026-05-27 — multi-page support. AT attachments are an ordered array;
  // previously only [0] was kept, dropping pages 2+ when a manifest spanned
  // several scans. Returns pages 2+ for storage in derm_manifest_extra_urls
  // / derm_address_extra_urls.
  function extraAttachmentUrls(name: string): string[] {
    const v = fields[name]
    if (!Array.isArray(v) || v.length <= 1) return []
    return v.slice(1).map((a) => {
      if (a && typeof a === 'object' && typeof (a as Record<string, unknown>).url === 'string') {
        return (a as Record<string, unknown>).url as string
      }
      return null
    }).filter((u): u is string => !!u)
  }

  const row: Record<string, unknown> = {
    service_date: dateVal(fields, 'Date Dump Ticket') ?? dateVal(fields, 'GT Last Visit'),
    dump_ticket_date: dateVal(fields, 'Date Dump Ticket'),
    white_manifest_number: strVal(fields, 'White Manifest #'),
    yellow_ticket_number: strVal(fields, 'Yellow Ticket #'),
    sent_to_client: fields['Send To Client'] === true,
    sent_to_city: fields['Send To City'] === true,
    derm_manifest_url: firstAttachmentUrl('DERM Manifest'),
    derm_address_url:  firstAttachmentUrl('DERM Address'),
    derm_manifest_extra_urls: extraAttachmentUrls('DERM Manifest'),
    derm_address_extra_urls:  extraAttachmentUrls('DERM Address'),
  }

  // Resolve client_id. Prefer AT `Client` array (always carries the GID) over
  // the `Client Name (from Client)` lookup — that lookup is empty at trigger
  // time when ops drop a manifest in without re-saving the Client field,
  // which previously left 22+ manifests orphaned (no client_id, invisible
  // in DERM Tracker). Fix 2026-05-19.
  const atClient = (fields['Client'] as unknown[] | undefined)?.[0]
  const atClientGid = typeof atClient === 'string'
    ? atClient
    : (atClient && typeof atClient === 'object' && 'id' in (atClient as Record<string, unknown>))
      ? String((atClient as Record<string, unknown>).id)
      : null
  if (atClientGid) {
    const { data: link } = await supabase
      .from('entity_source_links')
      .select('entity_id')
      .eq('entity_type', 'client').eq('source_system', 'airtable').eq('source_id', atClientGid)
      .maybeSingle()
    if (link) row.client_id = link.entity_id
  }
  if (!row.client_id) {
    const clientName = strVal(fields, 'Client Name (from Client)') ?? strVal(fields, 'Client Name')
    if (clientName) {
      const { data: clients } = await supabase
        .from('clients').select('id').ilike('name', `%${clientName}%`).limit(1)
      if (clients?.length) row.client_id = clients[0].id
    }
  }

  // 2026-05-20 prevention guards. New AT events for empty/orphan rows used to
  // pile up as junk:
  //   - 5 NULL-client orphans (440, 1004, 1008, 1012, 1013)
  //   - 75 hollow rows (client_id but no WM#/YT#/PDFs/dump_date)
  //   - 3 true dupes (same client_id + WM# or YT#)
  // Now blocked at the gate.
  const hasData =
    row.white_manifest_number != null ||
    row.yellow_ticket_number != null ||
    row.dump_ticket_date != null ||
    row.derm_manifest_url != null ||
    row.derm_address_url != null
  if (!existingId && !hasData) {
    // Empty placeholder — orphan (no client) or hollow (client only). Either
    // way, nothing useful to store yet. Skip insert; AT will re-fire once
    // ops fills it in, at which point hasData will be true.
    return
  }
  if (!existingId && !row.client_id) {
    // Has data but client couldn't be resolved (unsynced AT client). Skip
    // rather than insert as orphan. Will retry on next AT update once the
    // client gets synced.
    return
  }

  // 2026-forward only (Fred 2026-06-01): the DB intentionally holds NO pre-2026
  // DERM history — the 598 pre-2026 manifests were backed up + hard-deleted, and
  // missing-2025-data is intentional, not a bug. Don't let an old AT record
  // re-introduce one when it fires (this is how #488184 / 2025-03-31 crept back
  // in 2026-06-03). Block CREATION of a manifest whose date is positively before
  // 2026; existing manifests (updates) are left untouched. Undated records pass
  // (year unknown — they'll be re-evaluated once ops enters a date).
  const manifestDate = (row.service_date as string | null) ?? (row.dump_ticket_date as string | null)
  if (!existingId && manifestDate && manifestDate < '2026-01-01') {
    console.log(`webhook-airtable: skipped pre-2026 DERM record ${recordId} (date ${manifestDate}) — DB is 2026-forward only`)
    return
  }

  let entityId: number

  if (existingId) {
    const { error } = await supabase.from('derm_manifests').update(row).eq('id', existingId)
    if (error) throw new Error(`DERM update failed: ${error.message}`)
    entityId = existingId
  } else {
    // Dedup-on-insert: if (client_id, WM#) or (client_id, YT#) already exists
    // (because AT sometimes creates parallel rows for the same client+manifest),
    // route to that existing row instead of creating a new one. The unique
    // constraint added 2026-05-20 backs this up.
    let dupId: number | null = null
    if (row.client_id && row.white_manifest_number) {
      const { data } = await supabase.from('derm_manifests').select('id')
        .eq('client_id', row.client_id).eq('white_manifest_number', row.white_manifest_number)
        .maybeSingle()
      if (data) dupId = data.id
    }
    if (!dupId && row.client_id && row.yellow_ticket_number) {
      const { data } = await supabase.from('derm_manifests').select('id')
        .eq('client_id', row.client_id).eq('yellow_ticket_number', row.yellow_ticket_number)
        .maybeSingle()
      if (data) dupId = data.id
    }
    if (dupId) {
      // Update the existing row with any new fields from this AT payload.
      await supabase.from('derm_manifests').update(row).eq('id', dupId)
      entityId = dupId
      // Re-link only when the existing row has NO AT link yet (orphan from a
      // prior dedup-and-skip). If it already has an AT link to a different
      // record id, preserve that — the upsert's onConflict would otherwise
      // rotate the link to the new (duplicate) AT id on every replay. The
      // first AT record to reach the row wins. Fix 2026-05-27.
      const { data: existingLink } = await supabase
        .from('entity_source_links')
        .select('source_id')
        .eq('entity_type', 'derm_manifest')
        .eq('entity_id', dupId)
        .eq('source_system', 'airtable')
        .maybeSingle()
      if (existingLink && existingLink.source_id !== recordId) {
        // AT-side duplicate. Keep the original link, no-op the rest.
        return
      }
      // Falls through to upsertEntityLink — either no link exists (orphan
      // re-link) or the link already points to this same recordId (idempotent).
    } else {
      const { data: inserted, error } = await supabase
        .from('derm_manifests')
        .insert(row)
        .select('id')
        .single()
      if (error || !inserted) throw new Error(`DERM insert failed: ${error?.message}`)
      entityId = inserted.id
    }
  }

  await upsertEntityLink({
    entity_type: 'derm_manifest',
    entity_id: entityId,
    source_system: 'airtable',
    source_id: recordId,
    match_method: 'webhook',
  })

  // Mirror AT attachments to Supabase Storage. Skipped if URL already
  // points at Storage (idempotent), so re-firing webhooks doesn't re-upload.
  // Failures are logged but don't fail the webhook — the AT URL stays in the
  // DB as a stopgap until the 15-min cron picks it up.
  // Page 1 → derm_manifest_url / derm_address_url. Page 2+ → *_extra_urls[].
  const updates: Record<string, unknown> = {}
  if (typeof row.derm_manifest_url === 'string') {
    const newUrl = await mirrorAttachmentToStorage(entityId, row.derm_manifest_url, 'manifest', 1)
    if (newUrl && newUrl !== row.derm_manifest_url) updates.derm_manifest_url = newUrl
  }
  if (typeof row.derm_address_url === 'string') {
    const newUrl = await mirrorAttachmentToStorage(entityId, row.derm_address_url, 'address', 1)
    if (newUrl && newUrl !== row.derm_address_url) updates.derm_address_url = newUrl
  }
  // Multi-page: mirror each extra page, store the mirrored URL in the
  // *_extra_urls array. Page numbering starts at 2 (page 1 is the singular).
  const manifestExtras = (row.derm_manifest_extra_urls as string[]) || []
  if (manifestExtras.length > 0) {
    const mirrored: string[] = []
    for (let i = 0; i < manifestExtras.length; i++) {
      const mirroredUrl = await mirrorAttachmentToStorage(entityId, manifestExtras[i], 'manifest', i + 2)
      mirrored.push(mirroredUrl ?? manifestExtras[i])
    }
    updates.derm_manifest_extra_urls = mirrored
  }
  const addressExtras = (row.derm_address_extra_urls as string[]) || []
  if (addressExtras.length > 0) {
    const mirrored: string[] = []
    for (let i = 0; i < addressExtras.length; i++) {
      const mirroredUrl = await mirrorAttachmentToStorage(entityId, addressExtras[i], 'address', i + 2)
      mirrored.push(mirroredUrl ?? addressExtras[i])
    }
    updates.derm_address_extra_urls = mirrored
  }
  if (Object.keys(updates).length > 0) {
    await supabase.from('derm_manifests').update(updates).eq('id', entityId)
  }

  // (2026-07-07) REMOVED the fuzzy manifest_visits linker that upserted a link
  // for every completed GT visit within ±2 days of "GT Last Visit". That ±2-day
  // window was the source of the over-attach mis-links (a client's NEXT visit
  // attached to the wrong dump — 6 unlinked 2026-07-07). The AT→DERM automation is
  // retired: DERM Tracker writes derm_manifests directly (since 2026-06-26) and is
  // the sole live writer of manifest_visits; linking is human-only there. The DB now
  // guards this table anyway (trg_aa_link_same_client, trg_ab_link_one_white,
  // trg_ac_link_visit_not_after_dump). Manifest doc-mirroring above stays intact.
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
    // No Airtable-source-id match, but the SAME physical inspection
    // (shift_date, vehicle_id, employee_id, inspection_type) may already exist
    // under a DIFFERENT Airtable recordId (record deleted+recreated, or a
    // duplicate AT row) — a plain INSERT then 23505s on
    // idx_inspections_shift_unique (the bug behind 29 dropped events,
    // 2026-06/07). Fall back to the natural key to stay idempotent (Rule 5);
    // that unique index is PARTIAL (vehicle_id/employee_id NOT NULL) so
    // PostgREST .upsert() can't target it — look up + update in code.
    let naturalId: number | null = null
    if (vehicle_id && employee_id) {
      const { data: nat } = await supabase.from('inspections').select('id')
        .eq('shift_date', shift_date).eq('vehicle_id', vehicle_id)
        .eq('employee_id', employee_id).eq('inspection_type', inspection_type).limit(1)
      if (nat?.length) naturalId = nat[0].id
    }
    if (naturalId) {
      const { error } = await supabase.from('inspections').update(row).eq('id', naturalId)
      if (error) throw new Error(`Inspection update failed: ${error.message}`)
      entityId = naturalId
    } else {
      const { data: inserted, error } = await supabase.from('inspections').insert(row).select('id').single()
      if (error || !inserted) throw new Error(`Inspection insert failed: ${error?.message}`)
      entityId = inserted.id
    }
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
  // UNREACHABLE as of 2026-07-21 — nothing maps to 'derm' anymore. Both dispatch sites were
  // checked: ENTITY_TO_HANDLER (severed, see the note there) and TABLE_HANDLERS (fully
  // commented out, the native changedTablesById path has never been wired). Kept only so the
  // handler body remains readable next to the rest. Re-pointing anything at this WILL
  // reintroduce NULL disposal_facility_id inserts, which public.derm_manifests now REJECTS
  // via derm_manifests_dump_fields_present_chk — you would get a 23514, not a silent NULL.
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
  // 'derm_manifest': SEVERED 2026-07-21 (Fred's explicit call). DO NOT RE-ADD.
  //
  // CLAUDE.md has said since 2026-06-26 that the AT→DERM automation is retired and
  // the DERM Tracker is the sole writer of derm_manifests. That was NOT true in code:
  // this entry was still live and fired 55 times in the 30 days to 2026-07-14.
  //
  // Two concrete harms, both measured before removal:
  //  1. handleDermRecord NEVER sets disposal_facility_id (the column appears 0 times in
  //     this file), and the `hasData` gate admits a row on a URL alone with no dump date.
  //     It really did insert such rows (manifests 1245/1250/1251 on 2026-06-30).
  //  2. Its `.update(row)` sends every key including nulls, so an empty Airtable field
  //     overwrote a real value — it wiped the dump date on manifests 1061, 579 and 999.
  //
  // Business rule (Fred, 2026-07-21): the DERM address manifest is only uploaded AFTER it
  // comes back from the city, by Diego, reading the finished paper sheet. Both the dump
  // date and the facility are printed on it at that moment. So the manifest is born
  // complete, and Airtable has no role in creating one.
  //
  // KNOWN, ACCEPTED CONSEQUENCE: this also ends PDF doc-mirroring from Airtable
  // attachments into Supabase storage (last used 2026-07-14; 545/546 live manifests are
  // already mirrored, 0 still point at Airtable). Fred accepted this on 2026-07-21:
  // nobody should be attaching DERM PDFs in Airtable anymore — they go in the DERM Tracker.
  // Any that still arrive land in webhook_events_log as status='skipped' rather than
  // vanishing, so the loss is visible. Check there before concluding "the feed is fine".
  //
  // Unmapped entities fall through to the !handlerKey branch below: logged as 'skipped'
  // with HTTP 200, so Airtable gets no error and will not retry-storm.
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
