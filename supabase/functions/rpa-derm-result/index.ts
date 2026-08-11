// ============================================================================
// rpa-derm-result/index.ts — Edge Function
// ============================================================================
// Write endpoint for Jonathan's GDO Online Reporting bot: "here is what happened."
// Work key = visit_id (the serviced visit reported); manifest_id is optional context.
// Contract: docs/handoffs/2026-07-21_rpa_bot_reply_to_john.md.
//
// POST /functions/v1/rpa-derm-result
// Body: { visit_id, manifest_id?, run_id, status, retryable, failure_reason?,
//         attempted_at (ISO 8601), portal_confirmation?,
//         screenshot? (base64 JPEG, max 5MB decoded),
//         screenshot_missing_reason?, dry_run? }
//
// Rules enforced HERE (not trusted to the bot):
// - auth: x-rpa-key against RPA_BOT_KEYS (comma-separated, rotation-friendly);
// - idempotent on (visit_id, run_id): a retried POST returns 200
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
  'visit_id', 'manifest_id', 'run_id', 'status', 'retryable', 'failure_reason',
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

  const visitId = Number(body.visit_id)
  if (!Number.isInteger(visitId) || visitId <= 0) {
    return json({ error: 'visit_id_required_integer' }, 400)
  }
  const manifestId = body.manifest_id == null ? null : Number(body.manifest_id)
  if (manifestId !== null && (!Number.isInteger(manifestId) || manifestId <= 0)) {
    return json({ error: 'manifest_id_must_be_integer_or_omitted' }, 400)
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
  // attempted_at is DISPLAY/AUDIT ONLY (audit 2026-07-21f): the queue gates key
  // off the server-written created_at, so a skewed bot clock can neither wedge
  // nor prematurely release the queue. No skew hard-reject — rejecting a genuine
  // post-county-submission result would re-queue the manifest -> double-filing.
  // dry_run is DERIVED server-side, never trusted from the bot (audit 2026-07-21f):
  // the recorded flag must match the manifest's cutoff classification because the
  // queue gates all filter NOT dry_run. Computed after the manifest lookup below.
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

  // Decode the screenshot, but ACCEPT-AND-FLAG rather than reject on any problem
  // (audit 2026-07-21f): a real county submission must never be lost to a
  // screenshot issue and re-queued. Oversize/undecodable -> record the attempt
  // with a screenshot_missing_reason instead of a 4xx.
  let screenshotBytes: Uint8Array | null = null
  let screenshotDropReason: string | null = null
  if (screenshotB64) {
    // strip whitespace so the length check matches atob() (which ignores it);
    // wrapped/MIME base64 inflates length ~1.3% otherwise (audit finding 3).
    const b64 = screenshotB64.replace(/^data:image\/[a-z]+;base64,/, '').replace(/\s/g, '')
    if (b64.length > (MAX_SCREENSHOT_BYTES * 4) / 3 + 16) {
      screenshotDropReason = 'SCREENSHOT_TOO_LARGE'
    } else {
      try {
        const bin = atob(b64)
        const out = new Uint8Array(bin.length)
        for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
        if (out.length > MAX_SCREENSHOT_BYTES) {
          screenshotDropReason = 'SCREENSHOT_TOO_LARGE'
        } else {
          screenshotBytes = out
        }
      } catch {
        screenshotDropReason = 'SCREENSHOT_DECODE_FAILED'
      }
    }
  }

  // x-app-source tags every write from this bot as 'gdo-report-bot' so the
  // audit trail attributes the action to the Automated GDO Reporting bot
  // (not the generic service_role/sql fallback). 2026-07-21i.
  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { global: { headers: { 'x-app-source': 'gdo-report-bot' } } },
  )

  const { data: visit, error: vErr } = await sb
    .from('visits')
    .select('id, deleted_at, visit_date')
    .eq('id', visitId)
    .maybeSingle()
  if (vErr) {
    console.error('visit lookup failed:', vErr.message)
    return json({ error: 'visit_lookup_failed' }, 500)
  }
  if (!visit || visit.deleted_at) {
    return json({ error: 'visit_not_found_or_deleted' }, 422)
  }
  // Derive dry_run from the visit's service date vs the single-source cutoff
  // (2026-07-21g): store the DERIVED truth, ignore the bot's echoed flag; the
  // DB trigger is the final backstop.
  const { data: cutoffRow } = await sb.rpc('rpa_launch_cutoff')
  const cutoff = typeof cutoffRow === 'string' ? cutoffRow : '2026-07-21'
  const dryRun = !!visit.visit_date && visit.visit_date < cutoff
  // No optimistic success: a real SUCCESS must carry a portal confirmation.
  if (status === 'SUCCESS' && !dryRun && !portalConfirmation) {
    return json({ error: 'success_requires_portal_confirmation' }, 400)
  }

  // Idempotency: first write wins; a retried POST is a no-op acknowledgment.
  // screenshot_path/_missing_reason are selected so the deduped response can report
  // the STORED row's evidence state (2026-08-11): the caller cannot otherwise tell
  // "filed with evidence" from "filed without it", and on a dedupe we upload nothing,
  // so the honest answer is what is already on the row rather than what was posted.
  const { data: existing } = await sb
    .from('derm_portal_submissions')
    .select('id, screenshot_path, screenshot_missing_reason')
    .eq('visit_id', visitId)
    .eq('run_id', runId)
    .maybeSingle()
  if (existing) {
    return json({
      recorded: true,
      deduped: true,
      id: existing.id,
      screenshot_stored: existing.screenshot_path !== null,
      screenshot_missing_reason: existing.screenshot_missing_reason ?? null,
    }, 200)
  }

  let screenshotPath: string | null = null
  let evidenceDropReason: string | null = screenshotDropReason
  if (screenshotBytes) {
    // Deterministic key + upsert: a retried POST (same run_id) rewrites the same
    // object. DRY-RUN evidence is test-only, so it uses a PER-VISIT key
    // (`<visit>/dryrun.jpg`): repeated dry-run test runs OVERWRITE to one file
    // per visit instead of accumulating a new file per run_id (evidence-dup
    // cleanup 2026-07-24). LIVE keeps the per-run_id key so every real filing
    // attempt stays a distinct, non-overwritten evidence file — a genuine
    // re-attempt must remain visible (it is the double-file signal).
    screenshotPath = dryRun ? `${visitId}/dryrun.jpg` : `${visitId}/${runId}.jpg`
    let uploaded = false
    for (let attempt = 0; attempt < 3 && !uploaded; attempt++) {
      if (attempt > 0) await new Promise((r) => setTimeout(r, 200 * attempt))
      const { error: upErr } = await sb.storage
        .from('rpa-evidence')
        .upload(screenshotPath, screenshotBytes, { contentType: 'image/jpeg', upsert: true })
      if (!upErr) { uploaded = true; break }
      console.error(`screenshot upload attempt ${attempt + 1} failed:`, upErr.message)
    }
    if (!uploaded) {
      // Retries exhausted: record the ATTEMPT without evidence rather than lose
      // it (a lost result re-queues an already-filed manifest = double-filing).
      screenshotPath = null
      evidenceDropReason = 'STORE_FAILED'
    }
  }

  const { data: inserted, error: insErr } = await sb
    .from('derm_portal_submissions')
    .insert({
      visit_id: visitId,
      manifest_id: manifestId,
      run_id: runId,
      status,
      retryable: body.retryable,
      failure_reason: failureReason,
      portal_confirmation: portalConfirmation,
      attempted_at: attemptedAt.toISOString(),
      screenshot_path: screenshotPath,
      screenshot_missing_reason: screenshotPath ? null : (evidenceDropReason ?? missingReason),
      dry_run: dryRun,
    })
    .select('id')
    .single()
  if (insErr) {
    // Unique violation = concurrent duplicate POST; acknowledge idempotently.
    if (insErr.code === '23505') {
      const { data: dup } = await sb
        .from('derm_portal_submissions')
        .select('id, screenshot_path, screenshot_missing_reason')
        .eq('visit_id', visitId)
        .eq('run_id', runId)
        .maybeSingle()
      return json({
        recorded: true,
        deduped: true,
        id: dup?.id ?? null,
        screenshot_stored: dup ? dup.screenshot_path !== null : false,
        screenshot_missing_reason: dup?.screenshot_missing_reason ?? null,
      }, 200)
    }
    console.error('result insert failed:', insErr.message)
    return json({ error: 'result_store_failed_retry' }, 500)
  }

  // screenshot_stored mirrors EXACTLY what was written to the row above, so the
  // response can never disagree with the record. It stays 201 either way: an image
  // problem must never turn a real county filing into an unrecorded one.
  return json({
    recorded: true,
    deduped: false,
    id: inserted.id,
    screenshot_stored: screenshotPath !== null,
    screenshot_missing_reason: screenshotPath ? null : (evidenceDropReason ?? missingReason),
  }, 201)
})
