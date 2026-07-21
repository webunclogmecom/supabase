// ============================================================================
// rpa-derm-result/index.ts — Edge Function
// ============================================================================
// Write endpoint for Jonathan's RPA DERM-portal bot: "here is what happened."
// Contract: docs/handoffs/2026-07-21_rpa_bot_reply_to_john.md.
//
// POST /functions/v1/rpa-derm-result
// Body: { manifest_id, run_id, status, retryable, failure_reason?,
//         attempted_at (ISO 8601), portal_confirmation?,
//         screenshot? (base64 JPEG, max 5MB decoded),
//         screenshot_missing_reason?, dry_run? }
//
// Rules enforced HERE (not trusted to the bot):
// - auth: x-rpa-key against RPA_BOT_KEYS (comma-separated, rotation-friendly);
// - idempotent on (manifest_id, run_id): a retried POST returns 200
//   {deduped:true} and changes nothing — first write wins;
// - status must be a short uppercase code; failure_reason capped; manifest
//   must exist and be live; unknown fields rejected;
// - every result carries a screenshot OR an explicit
//   screenshot_missing_reason (evidence-or-reason, DB CHECK backs this up);
// - screenshots go to the PRIVATE 'rpa-evidence' bucket; only the storage
//   path is recorded (never raw bytes in the table).
// verify_jwt=false in config.toml — the header is the auth, same model as
// the webhook receivers. Server-to-server only.
// ============================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2'

const MAX_SCREENSHOT_BYTES = 5 * 1024 * 1024

const KEYS = (Deno.env.get('RPA_BOT_KEYS') ?? '')
  .split(',')
  .map((k) => k.trim())
  .filter(Boolean)

const ALLOWED_FIELDS = new Set([
  'manifest_id', 'run_id', 'status', 'retryable', 'failure_reason',
  'attempted_at', 'portal_confirmation', 'screenshot',
  'screenshot_missing_reason', 'dry_run',
])

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)

  if (KEYS.length === 0) {
    console.error('RPA_BOT_KEYS secret not configured')
    return json({ error: 'service_not_configured' }, 503)
  }
  if (!KEYS.includes(req.headers.get('x-rpa-key') ?? '')) {
    return json({ error: 'unauthorized' }, 401)
  }

  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return json({ error: 'invalid_json' }, 400)
  }

  for (const k of Object.keys(body)) {
    if (!ALLOWED_FIELDS.has(k)) return json({ error: `unknown_field_${k}` }, 400)
  }

  const manifestId = Number(body.manifest_id)
  if (!Number.isInteger(manifestId) || manifestId <= 0) {
    return json({ error: 'manifest_id_required_integer' }, 400)
  }
  const runId = typeof body.run_id === 'string' ? body.run_id.trim() : ''
  if (!/^[A-Za-z0-9_.-]{1,100}$/.test(runId)) {
    // run_id becomes part of a storage object key: charset-restricted so a
    // stray '/' or storage-hostile character cannot poison every retry
    // (review finding 3 - a permanently unstorable result would re-queue an
    // already-submitted manifest).
    return json({ error: 'run_id_must_be_alnum_dot_dash_underscore_max100' }, 400)
  }
  const status = typeof body.status === 'string' ? body.status.trim() : ''
  if (!/^[A-Z0-9_]{1,64}$/.test(status)) {
    return json({ error: 'status_must_be_short_uppercase_code' }, 400)
  }
  if (typeof body.retryable !== 'boolean') {
    return json({ error: 'retryable_boolean_required' }, 400)
  }
  const failureReason = body.failure_reason == null ? null : String(body.failure_reason)
  if (failureReason !== null && failureReason.length > 1000) {
    return json({ error: 'failure_reason_max_1000_chars' }, 400)
  }
  const portalConfirmation = body.portal_confirmation == null ? null : String(body.portal_confirmation)
  if (portalConfirmation !== null && portalConfirmation.length > 200) {
    return json({ error: 'portal_confirmation_max_200_chars' }, 400)
  }
  const attemptedAt = typeof body.attempted_at === 'string' ? new Date(body.attempted_at) : null
  if (!attemptedAt || isNaN(attemptedAt.getTime())) {
    return json({ error: 'attempted_at_must_be_iso8601' }, 400)
  }
  // Clock-skew guard (review finding 8): a future attempted_at would wedge
  // the manifest's cooldown/data-error gates with no office-side release.
  const skewMs = attemptedAt.getTime() - Date.now()
  if (skewMs > 15 * 60 * 1000 || skewMs < -48 * 60 * 60 * 1000) {
    return json({ error: 'attempted_at_out_of_range_check_clock_use_utc' }, 400)
  }
  const dryRun = body.dry_run === true
  // The no-optimistic-success rule, enforced server-side (review finding 10):
  // a real SUCCESS must carry whatever confirmation the portal returned.
  if (status === 'SUCCESS' && !dryRun && !portalConfirmation) {
    return json({ error: 'success_requires_portal_confirmation' }, 400)
  }
  const screenshotB64 = body.screenshot == null ? null : String(body.screenshot)
  const missingReason = body.screenshot_missing_reason == null
    ? null
    : String(body.screenshot_missing_reason)
  if (missingReason !== null && missingReason.length > 300) {
    return json({ error: 'screenshot_missing_reason_max_300_chars' }, 400)
  }
  if (!screenshotB64 && !missingReason) {
    return json({ error: 'screenshot_or_screenshot_missing_reason_required' }, 400)
  }

  let screenshotBytes: Uint8Array | null = null
  if (screenshotB64) {
    // Reject oversize BEFORE decoding (review finding 2): decoding first
    // burns the CPU budget and lets the platform kill the request with an
    // opaque error instead of this clean 400 the bot can act on.
    const b64 = screenshotB64.replace(/^data:image\/[a-z]+;base64,/, '')
    if (b64.length > (MAX_SCREENSHOT_BYTES * 4) / 3 + 4096) {
      return json({ error: 'screenshot_max_5mb_send_compressed_jpeg' }, 400)
    }
    try {
      const bin = atob(b64)
      const out = new Uint8Array(bin.length)
      for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
      screenshotBytes = out
    } catch {
      return json({ error: 'screenshot_invalid_base64' }, 400)
    }
    if (screenshotBytes.length > MAX_SCREENSHOT_BYTES) {
      return json({ error: 'screenshot_max_5mb_send_compressed_jpeg' }, 400)
    }
  }

  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  const { data: manifest, error: mErr } = await sb
    .from('derm_manifests')
    .select('id, deleted_at, dump_ticket_date')
    .eq('id', manifestId)
    .maybeSingle()
  if (mErr) {
    console.error('manifest lookup failed:', mErr.message)
    return json({ error: 'manifest_lookup_failed' }, 500)
  }
  if (!manifest || manifest.deleted_at) {
    return json({ error: 'manifest_not_found_or_deleted' }, 422)
  }
  // dry_run is derivable server-side, never trusted (review finding 4): the
  // dryrun sample is strictly pre-launch-cutoff manifests, the live queue is
  // strictly on/after the cutoff. A mistagged flag either re-queues a manifest
  // the county already received or permanently dequeues one it never did.
  const LAUNCH_CUTOFF = '2026-07-21' // keep in sync with v_derm_portal_queue
  const isPreCutoff = !!manifest.dump_ticket_date && manifest.dump_ticket_date < LAUNCH_CUTOFF
  if (dryRun !== isPreCutoff) {
    return json({ error: 'dry_run_mismatch_for_this_manifest' }, 422)
  }

  // Idempotency: first write wins; a retried POST is a no-op acknowledgment.
  const { data: existing } = await sb
    .from('derm_portal_submissions')
    .select('id')
    .eq('manifest_id', manifestId)
    .eq('run_id', runId)
    .maybeSingle()
  if (existing) return json({ recorded: true, deduped: true, id: existing.id }, 200)

  let screenshotPath: string | null = null
  let storeFailed = false
  if (screenshotBytes) {
    // Deterministic key + upsert (review finding 11): a retried POST rewrites
    // the same object instead of orphaning one copy per retry.
    screenshotPath = `${manifestId}/${runId}.jpg`
    const { error: upErr } = await sb.storage
      .from('rpa-evidence')
      .upload(screenshotPath, screenshotBytes, {
        contentType: 'image/jpeg',
        upsert: true,
      })
    if (upErr) {
      // Last-resort acceptance (review finding 1): recording the ATTEMPT
      // matters more than the evidence - a result that can never be stored
      // would re-queue an already-submitted manifest and double-submit to
      // the county. Record without the screenshot, flagged.
      console.error('screenshot upload failed, recording without evidence:', upErr.message)
      screenshotPath = null
      storeFailed = true
    }
  }

  const { data: inserted, error: insErr } = await sb
    .from('derm_portal_submissions')
    .insert({
      manifest_id: manifestId,
      run_id: runId,
      status,
      retryable: body.retryable,
      failure_reason: failureReason,
      portal_confirmation: portalConfirmation,
      attempted_at: attemptedAt.toISOString(),
      screenshot_path: screenshotPath,
      screenshot_missing_reason: screenshotPath ? null : (storeFailed ? 'STORE_FAILED' : missingReason),
      dry_run: dryRun,
    })
    .select('id')
    .single()
  if (insErr) {
    // Unique violation = concurrent duplicate POST; acknowledge idempotently.
    if (insErr.code === '23505') {
      const { data: dup } = await sb
        .from('derm_portal_submissions')
        .select('id')
        .eq('manifest_id', manifestId)
        .eq('run_id', runId)
        .maybeSingle()
      return json({ recorded: true, deduped: true, id: dup?.id ?? null }, 200)
    }
    console.error('result insert failed:', insErr.message)
    return json({ error: 'result_store_failed_retry' }, 500)
  }

  return json({ recorded: true, deduped: false, id: inserted.id }, 201)
})
