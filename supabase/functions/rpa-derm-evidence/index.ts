// ============================================================================
// rpa-derm-evidence — attach the evidence image to an ALREADY-RECORDED result
// ----------------------------------------------------------------------------
// Built 2026-08-24 for the GDO Online Reporting bot (Jonathan). The bot now posts
// the COUNTY CONFIRMATION EMAIL, rendered as an image, as the evidence for a
// filing. That email usually lands the same minute as the submit, but not always,
// so a run can legitimately finish before its evidence exists.
//
//   POST { visit_id, run_id, screenshot }   ->  fills the image in, ONCE.
//
// 🛑 FILL-ONCE IS THE WHOLE SAFETY PROPERTY, AND IT IS ENFORCED IN THE PREDICATE,
// NOT IN THE BRANCHES. The UPDATE carries `.is('screenshot_path', null)`, so the
// write is MONOTONIC: NULL -> a path, never a path -> a different path. The bot may
// retry this endpoint forever, in any order, concurrently with itself, and can never
// overwrite evidence we already hold. A branch can be raced; a predicate cannot.
//
// ⚠ THIS IS THE BOT'S RULE, NOT THE STAFF RULE. Staff REPLACE evidence through the
// DERM Tracker (`fn_set_gdo_evidence_ext`) and that is deliberate and in use — three
// replacements exist in `audit.logs`, two of them by Fred on 2026-08-24 swapping a
// portal screenshot for the county email. A human correcting a bad capture is an
// audited decision; a machine retrying is not. Do not "unify" these two paths.
//
// ⚠ ORDERING: the RESULT must exist first. Evidence for an unknown (visit_id, run_id)
// is a 404, never a stored orphan. A floating image nothing references is worse than
// a loud error, because nothing would ever reconcile it.
//
// AUTH: same `x-rpa-key` as rpa-derm-queue / rpa-derm-result, verify_jwt=false in
// config.toml. Server-to-server only, no CORS (no browser calls this).
// ============================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2'

const MAX_SCREENSHOT_BYTES = 5 * 1024 * 1024

const KEYS = (Deno.env.get('RPA_BOT_KEYS') ?? '')
  .split(',')
  .map((k) => k.trim())
  .filter(Boolean)

// Same accept-and-reject discipline as rpa-derm-result: an unknown field is a 400 so
// a typo can never be silently ignored. `manifest_id` and `dry_run` are accepted and
// IGNORED so a bot echoing its result body verbatim cannot get a 400 on an attach
// that is otherwise perfectly valid — dry_run is read from the STORED row, never
// from the caller.
const ALLOWED_FIELDS = new Set(['visit_id', 'run_id', 'screenshot', 'manifest_id', 'dry_run'])

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

// 🛑 SNIFF THE REAL BYTES. The bot's evidence changed from a portal screenshot (JPEG)
// to a rendered email (PNG) on 2026-08-24, and rpa-derm-result used to hardcode
// `.jpg` + image/jpeg for everything. Storing PNG bytes at a .jpg key labelled
// image/jpeg is silently wrong and only surfaces downstream, where something trusts
// the extension. A declared content-type is caller-supplied and proves nothing.
function sniffImage(b: Uint8Array): { ext: 'jpg' | 'png'; mime: string } | null {
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) {
    return { ext: 'jpg', mime: 'image/jpeg' }
  }
  if (
    b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 &&
    b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a
  ) {
    return { ext: 'png', mime: 'image/png' }
  }
  return null
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
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    return json({ error: 'invalid_json' }, 400)
  }
  for (const k of Object.keys(body)) {
    if (!ALLOWED_FIELDS.has(k)) return json({ error: `unknown_field_${k}` }, 400)
  }

  const visitId = Number(body.visit_id)
  if (!Number.isInteger(visitId) || visitId <= 0) {
    return json({ error: 'visit_id_required_integer' }, 400)
  }
  const runId = body.run_id == null ? '' : String(body.run_id)
  if (!/^[A-Za-z0-9_.-]{1,100}$/.test(runId)) {
    return json({ error: 'run_id_must_be_alnum_dot_dash_underscore_max100' }, 400)
  }

  const screenshotB64 = body.screenshot == null ? '' : String(body.screenshot)
  if (!screenshotB64) return json({ error: 'screenshot_required' }, 400)

  // ⚠ Unlike rpa-derm-result, a bad image here IS a 4xx and that is correct. There
  // the accept-and-flag rule exists because rejecting would lose a real county
  // filing and re-queue it. Here the filing is already safely recorded, so refusing
  // a broken attach costs nothing and telling the bot plainly is the useful answer.
  const b64 = screenshotB64.replace(/^data:image\/[a-z]+;base64,/, '').replace(/\s/g, '')
  if (b64.length > (MAX_SCREENSHOT_BYTES * 4) / 3 + 16) {
    return json({ error: 'screenshot_too_large' }, 400)
  }
  let bytes: Uint8Array
  try {
    const bin = atob(b64)
    bytes = new Uint8Array(bin.length)
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  } catch {
    return json({ error: 'screenshot_decode_failed' }, 400)
  }
  if (bytes.length > MAX_SCREENSHOT_BYTES) return json({ error: 'screenshot_too_large' }, 400)
  const kind = sniffImage(bytes)
  if (!kind) return json({ error: 'screenshot_must_be_jpeg_or_png' }, 400)

  const sb = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { global: { headers: { 'x-app-source': 'gdo-report-bot' } } },
  )

  // ---- find the result this evidence belongs to -----------------------------------
  const { data: rows, error: selErr } = await sb
    .from('derm_portal_submissions')
    .select('id, screenshot_path, screenshot_missing_reason, dry_run')
    .eq('visit_id', visitId)
    .eq('run_id', runId)

  if (selErr) {
    console.error('submission lookup failed:', selErr.message)
    return json({ error: 'submission_lookup_failed' }, 500)
  }
  if (!rows || rows.length === 0) {
    return json({ error: 'result_not_found_for_visit_run' }, 404)
  }
  // (visit_id, run_id) is the dedupe key rpa-derm-result enforces, so more than one
  // row is not a state we can attribute evidence to. Refuse rather than guess.
  if (rows.length > 1) {
    return json({ error: 'multiple_results_for_visit_run' }, 409)
  }
  const row = rows[0]

  // ---- already has evidence: idempotent no-op, NOT an error -------------------------
  // Checked BEFORE uploading, so a repeat attach never even writes an object. This is
  // the common case for a retrying bot and must be cheap and harmless.
  if (row.screenshot_path) {
    return json({
      attached: false,
      already_had_evidence: true,
      id: row.id,
      screenshot_path: row.screenshot_path,
    }, 200)
  }

  // ---- upload -----------------------------------------------------------------------
  // Mirrors rpa-derm-result's key scheme, including its per-visit dry-run key so test
  // attaches overwrite one object instead of accumulating one per run.
  const path = row.dry_run
    ? `${visitId}/dryrun.${kind.ext}`
    : `${visitId}/${runId}.${kind.ext}`

  const { error: upErr } = await sb.storage
    .from('rpa-evidence')
    .upload(path, bytes, { contentType: kind.mime, upsert: true })
  if (upErr) {
    console.error('evidence upload failed:', upErr.message)
    return json({ error: 'evidence_store_failed_retry' }, 500)
  }

  // ---- the guarded fill --------------------------------------------------------------
  // 🛑 `.is('screenshot_path', null)` is the fill-once guarantee. Do not remove it, and
  // do not "simplify" this into an unconditional update because the branch above already
  // checked: that check and this write are not atomic, and two concurrent attaches would
  // both pass it. The predicate is what makes the second one a no-op.
  // Both columns are set in ONE statement so a row can never show an image and a reason
  // it is missing at the same time.
  const { data: updated, error: updErr } = await sb
    .from('derm_portal_submissions')
    .update({ screenshot_path: path, screenshot_missing_reason: null })
    .eq('id', row.id)
    .is('screenshot_path', null)
    .select('id, screenshot_path')

  if (updErr) {
    console.error('evidence fill failed:', updErr.message)
    return json({ error: 'evidence_fill_failed_retry' }, 500)
  }

  if (!updated || updated.length === 0) {
    // Lost a race with a concurrent attach. The other writer won; report their result.
    // ⚠ Deliberately does NOT delete the object we just uploaded: on the same
    // (visit, run) the key is deterministic, so it may be the very file the winner
    // recorded. Deleting here could destroy live evidence.
    const { data: now } = await sb
      .from('derm_portal_submissions')
      .select('id, screenshot_path')
      .eq('id', row.id)
      .single()
    return json({
      attached: false,
      already_had_evidence: true,
      id: row.id,
      screenshot_path: now?.screenshot_path ?? null,
    }, 200)
  }

  return json({
    attached: true,
    id: row.id,
    screenshot_path: updated[0].screenshot_path,
    screenshot_stored: true,
    cleared_missing_reason: row.screenshot_missing_reason,
  }, 200)
})
