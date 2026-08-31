// ============================================================================
// rpa-derm-queue/index.ts — Edge Function
// ============================================================================
// Read endpoint for Jonathan's GDO Online Reporting bot: "what should I report?"
// Work unit = a Line-Item-27 VISIT linked to a manifest, not yet reported.
// Contract: docs/handoffs/2026-07-21_rpa_bot_reply_to_john.md.
//
// GET /functions/v1/rpa-derm-queue            → up to 25 live-queue manifests
// GET /functions/v1/rpa-derm-queue?mode=dryrun → historical sample (testing)
//
// Auth: header `x-rpa-key` matched against the RPA_BOT_KEYS secret
// (comma-separated list so a key rotation is add-new, swap, remove-old with
// zero downtime). verify_jwt=false in config.toml — the bot has no Supabase
// JWT; this header IS the auth. Server-to-server only, no CORS surface.
//
// Response shape (documented for Jonathan in the repo README):
// { generated_at, mode: 'live'|'dryrun', count, reports: [{
//     visit_id, manifest_id, dry_run, client_code, client_name, client_email,
//     address, city, zip, county, gdo_number, service_date, dump_ticket_date,
//     ticket_number, jurisdiction, white_manifest_number, disposal_facility,
//     documents: { address: [urls], receipt: [urls] }   // signed, 4h TTL
// }]}
// ticket_number (2026-07-24) = the dump-ticket number to file, regardless of
// county: Miami-Dade loads carry it as the white manifest #, Broward/PBC loads
// as the yellow Septage Receiving #. USE THIS, not white_manifest_number, which
// is NULL for Broward loads (kept only for back-compat). jurisdiction is
// 'dade' | 'broward' | 'unknown'.
//
// Lifecycle gates (SUCCESS permanent, 20h attempt cooldown, data-errors held
// until the manifest changes) live in public.v_derm_portal_queue — the DB is
// the single source of queue truth, this fn only signs URLs and shapes JSON.
// ============================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2'

const SIGNED_URL_TTL_SECONDS = 4 * 60 * 60 // 4 hours, sized to one bot run
const BATCH_CAP = 25

const KEYS = (Deno.env.get('RPA_BOT_KEYS') ?? '')
  .split(',')
  .map((k) => k.trim())
  .filter(Boolean)

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

// Storage values are stored as full public-object URLs. Extract {bucket, path}
// so we can mint signed URLs (works today on the public bucket and keeps
// working when DERM storage goes private).
function parseStorageUrl(url: string): { bucket: string; path: string } | null {
  // new URL().pathname drops query strings/fragments for free; the alternation
  // also handles stored sign/authenticated-shaped URLs (review finding 6).
  // Any throw (malformed URL, stray % breaking decodeURIComponent) returns
  // null so one bad row degrades one link, never the whole queue response.
  try {
    const pathname = new URL(url).pathname
    const m = pathname.match(/\/storage\/v1\/object\/(?:public\/|sign\/|authenticated\/)?([^/]+)\/(.+)$/)
    if (!m) return null
    return { bucket: decodeURIComponent(m[1]), path: decodeURIComponent(m[2]) }
  } catch {
    return null
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'GET') return json({ error: 'method_not_allowed' }, 405)

  if (KEYS.length === 0) {
    console.error('RPA_BOT_KEYS secret not configured')
    return json({ error: 'service_not_configured' }, 503)
  }
  const presented = req.headers.get('x-rpa-key') ?? ''
  if (!KEYS.includes(presented)) return json({ error: 'unauthorized' }, 401)

  const url = new URL(req.url)
  const mode = url.searchParams.get('mode') === 'dryrun' ? 'dryrun' : 'live'
  const view = mode === 'dryrun' ? 'v_derm_portal_dryrun' : 'v_derm_portal_queue'

  // x-app-source tags the lease writes as 'gdo-report-bot' for the activity
  // trail (Automated GDO Reporting), not the generic fallback. 2026-07-21i.
  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { global: { headers: { 'x-app-source': 'gdo-report-bot' } } },
  )

  const { data: rows, error } = await sb
    .from(view)
    .select('*')
    .order('dump_ticket_date', { ascending: true })
    .order('manifest_id', { ascending: true })
    .limit(BATCH_CAP)
  if (error) {
    console.error('queue query failed:', error.message)
    return json({ error: 'queue_query_failed' }, 500)
  }

  const sign = async (raw: string | null): Promise<string | null> => {
    if (!raw) return null
    try {
      const parsed = parseStorageUrl(raw)
      if (!parsed) return raw // non-storage URL: pass through untouched
      const { data, error: signErr } = await sb.storage
        .from(parsed.bucket)
        .createSignedUrl(parsed.path, SIGNED_URL_TTL_SECONDS)
      if (signErr || !data?.signedUrl) {
        console.error(`sign failed for ${parsed.path}: ${signErr?.message}`)
        return raw // TODO when DERM storage goes PRIVATE: fail closed instead
        // (drop the manifest from the batch) — a raw URL will 400 by then and
        // the bot would submit without its documents.
      }
      return data.signedUrl
    } catch (e) {
      console.error(`sign threw for a stored URL: ${e}`)
      return raw
    }
  }

  // One row per code-27 VISIT to report online (its linked manifest gives docs).
  const reports = []
  for (const r of rows ?? []) {
    const addressDocs = [r.derm_address_url, ...(r.derm_address_extra_urls ?? [])].filter(Boolean)
    const receiptDocs = [r.derm_manifest_url, ...(r.derm_manifest_extra_urls ?? [])].filter(Boolean)
    reports.push({
      visit_id: r.visit_id,
      manifest_id: r.manifest_id,
      // 🛑 gdo_id is the PERMIT this item is for, and since 2026-08-31 a single
      // visit can legitimately be served SEVERAL items at once (Casa Neos has
      // three ACTIVE permits on one manifest, and DERM wants a report per
      // permit). Echo it back on the result POST: without it, rpa-derm-result
      // has to INFER the permit from the visit, which is only sound while one
      // permit is in flight at a time. Additive field; a bot that ignores it
      // still works, it just attributes by arrival order.
      gdo_id: r.gdo_id,
      dry_run: mode === 'dryrun',
      client_code: r.client_code,
      client_name: r.client_name,
      client_email: r.client_email,
      address: r.address,
      city: r.city,
      zip: r.zip,
      county: r.county,
      gdo_number: r.gdo_number,
      service_date: r.visit_date,
      dump_ticket_date: r.dump_ticket_date,
      ticket_number: r.ticket_number, // the number to file (white OR yellow), 24d
      jurisdiction: r.jurisdiction, // 'dade' | 'broward' | 'unknown'
      white_manifest_number: r.white_manifest_number, // back-compat; NULL for Broward
      disposal_facility: r.disposal_facility,
      documents: {
        address: await Promise.all(addressDocs.map(sign)),
        receipt: await Promise.all(receiptDocs.map(sign)),
      },
    })
  }

  // Dispense lease (hardening 2026-07-21f): hold each LIVE code-27 VISIT we hand
  // out for 20h even before any result lands, so a crash between the portal
  // report and the result POST cannot cause a re-dispense -> double-report.
  // Dryrun fetches do not lease. Best-effort: a lease failure must not block
  // serving the batch (the submission gates are the backstop).
  if (mode === 'live' && reports.length > 0) {
    const { error: leaseErr } = await sb
      .from('derm_portal_leases')
      // 🛑 The lease is per (VISIT, PERMIT) since 2026-08-31. It used to be keyed
      // on the visit alone, which meant dispensing one permit of a multi-permit
      // manifest hid its siblings for the full 20h, which is what made Casa Neos
      // take three days to file three permits. A NULL gdo_id still blocks the
      // whole ticket (legacy rows, and the conservative direction).
      .upsert(
        reports.map((r) => ({
          visit_id: r.visit_id,
          gdo_id: r.gdo_id ?? null,
          leased_at: new Date().toISOString(),
        })),
        { onConflict: 'visit_id,gdo_id' },
      )
    if (leaseErr) console.error('lease upsert failed (serving anyway):', leaseErr.message)
  }

  // ---- why is the queue empty? -------------------------------------------------
  // Jonathan, 2026-08-25: "the queue read empty on the 21st-23rd while 11024 sat
  // excluded, so 'empty' and 'stuck' looked identical. Even a one-line count like
  // '1 row excluded (data-error)' would have saved the archaeology on both ends."
  //
  // 🛑 count:0 used to mean BOTH "nothing to file" and "a filing is stuck and nobody
  //    can see it". GDO-11024 sat behind exactly that ambiguity for three days.
  //
  // ⚠ ADDITIVE ONLY. `count` and `reports` keep their exact meaning; anything already
  //   parsing this response cannot break.
  // ⚠ A failure here must NOT fail the queue. `held.available:false` says the summary
  //   could not be computed, because an ABSENT `held` and an EMPTY `held` must not
  //   look the same - that is the very confusion this block exists to remove.
  let held: Record<string, unknown> = { available: false }
  try {
    const { data: heldRows, error: heldErr } = await sb
      .from('v_derm_portal_queue_held')
      .select('held_by')
      .not('held_by', 'is', null)
    if (heldErr) throw new Error(heldErr.message)
    const by: Record<string, number> = {}
    for (const r of (heldRows ?? []) as { held_by: string }[]) {
      by[r.held_by] = (by[r.held_by] ?? 0) + 1
    }
    // sibling_won_this_pass is NOT a hold - the queue serves one permit per manifest
    // per pass and it comes up next time. Counting it as held would send someone
    // hunting a problem that does not exist.
    const { sibling_won_this_pass: siblings = 0, before_launch_cutoff: preCutoff = 0, ...gates } = by
    const gateTotal = Object.values(gates).reduce((n, v) => n + v, 0)
    held = {
      available: true,
      total: gateTotal,
      by_reason: gates,
      not_held: {
        sibling_won_this_pass: siblings,
        before_launch_cutoff: preCutoff,
      },
      note:
        'Rows this pass is NOT serving, and why. `total`/`by_reason` are real holds. ' +
        '`already_filed` is the healthy steady state, not a problem. `data_error` means a ' +
        'non-retryable failure is holding the row until something about it changes - if you ' +
        'fixed the cause OUTSIDE our database (a county portal credential, a permit ' +
        'registration) tell us and we will re-open it; we cannot see that from here. ' +
        '`not_held` entries are not problems: a sibling permit simply won this pass, or the ' +
        'visit predates the launch cutoff.',
    }
  } catch (e) {
    console.error('held summary failed (serving anyway):', e instanceof Error ? e.message : String(e))
    held = { available: false, error: 'held_summary_unavailable' }
  }

  return json(
    { generated_at: new Date().toISOString(), mode, count: reports.length, reports, held },
    200,
  )
})
