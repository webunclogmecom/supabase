// ============================================================================
// record-manual-gdo-report/index.ts - Edge Function
// ============================================================================
// Records a GDO Online Report that a PERSON filed with Miami-Dade by hand.
//
// WHY THIS EXISTS. John's RPA bot files these automatically, and when it succeeds the DERM App
// shows a "GDO Online Report" card built from derm.visit_gdo_report. When the bot CANNOT file -
// visit 6617 has four consecutive ERROR_LOGIN_FAILED runs on permit 11024 - somebody files it
// on the portal themselves, and until now there was nowhere to record that. The visit stayed in
// the bot's queue and the app kept showing nothing.
//
// WHY AN EDGE FUNCTION AND NOT A DIRECT APP WRITE. The DERM App already has an authenticated
// rpa-evidence surface, so this looks like it could be app-side. It cannot, because of the ORDER:
//
//   The storage INSERT policy is `rpa_evidence_staff_insert ... AND fn_is_gdo_evidence_path(name)`,
//   and fn_is_gdo_evidence_path only returns true for a path matching an EXISTING live
//   derm_portal_submissions row. So `authenticated` physically cannot upload before the row exists.
//
// That forces row-first for any app-side attempt, and row-first is the dangerous order: the row is
// what suppresses the bot, so a failed upload would leave a visit marked filed with no evidence.
// The service role bypasses that policy, so this function uploads FIRST and calls the RPC LAST.
// If anything fails before the RPC commits, NO suppression has happened and the only residue is an
// orphan object, which is deleted on the way out. Fail safe, not fail silent.
//
// THE RPC IS THE AUTHORITY, NOT THIS FILE. fn_record_manual_gdo_report re-checks every rule
// (completed visit, code-27 line item, no existing real filing, manifest link when post-cutoff,
// confirmation present, run_id prefix, screenshot path shape). The checks here exist to give a
// human a good error before we spend an upload, NOT to be the gate. Never relax the RPC because
// this function already checks something.
//
// Input (POST JSON):
//   { visit_id: number,
//     confirmation: string,          // the portal's confirmation / tracking text - required
//     attempted_at: string,          // ISO instant the person filed it
//     screenshot_b64: string,        // JPEG or PNG, <=5MB decoded - required, it is the evidence
//     acknowledge_stops_bot?: bool } // required ONLY when the visit is post-cutoff (see below)
//
// Auth: verify_jwt = true. The caller must be a signed-in @unclogme.com / @ayache.com staff
// account; their email is recorded as filed_by_email so the card can say who filed it.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''

// Same ceiling as rpa-derm-result, deliberately: both write the same bucket and a screenshot that
// the bot could store but a person could not would be an arbitrary difference.
const MAX_SCREENSHOT_BYTES = 5 * 1024 * 1024

const ALLOWED_ORIGINS = new Set(['https://derm.unclogme.app'])

function corsHeadersFor(origin: string | null): Record<string, string> {
  const allowed = origin && ALLOWED_ORIGINS.has(origin) ? origin : 'https://derm.unclogme.app'
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, content-type, x-client-info, apikey, x-app-source',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  }
}

function json(body: Record<string, unknown>, status: number, cors: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
}

// Sniff the REAL bytes. A declared content-type is caller-supplied and proves nothing; the storage
// object and the screenshot_path extension both have to match what the file actually is, or the
// card renders a broken image and the evidence is worthless at the moment it is needed.
function sniffImage(b: Uint8Array): { ext: 'jpg' | 'png'; mime: string } | null {
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return { ext: 'jpg', mime: 'image/jpeg' }
  if (b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 &&
      b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a) return { ext: 'png', mime: 'image/png' }
  return null
}

function decodeB64(s: string): Uint8Array | null {
  // strip any data: prefix and whitespace so the length maths matches atob(), which ignores it
  const b64 = s.replace(/^data:image\/[a-z+]+;base64,/, '').replace(/\s/g, '')
  if (b64.length > (MAX_SCREENSHOT_BYTES * 4) / 3 + 16) return null
  try {
    const bin = atob(b64)
    const out = new Uint8Array(bin.length)
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
    return out
  } catch {
    return null
  }
}

Deno.serve(async (req) => {
  const origin = req.headers.get('origin')
  const cors = corsHeadersFor(origin)
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405, cors)

  // ---- staff auth -----------------------------------------------------------------------------
  const authHeader = req.headers.get('Authorization') ?? ''
  if (!authHeader.startsWith('Bearer ')) return json({ error: 'unauthorized', message: 'Sign in first.' }, 401, cors)

  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  })
  const { data: userData, error: userErr } = await userClient.auth.getUser()
  const email = userData?.user?.email ?? ''
  if (userErr || !email) return json({ error: 'unauthorized', message: 'Sign in first.' }, 401, cors)
  if (!email.endsWith('@ayache.com') && !email.endsWith('@unclogme.com')) {
    return json({ error: 'forbidden', message: 'Staff account required.' }, 403, cors)
  }

  // ---- input ----------------------------------------------------------------------------------
  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return json({ error: 'bad_request', message: 'Invalid JSON body.' }, 400, cors)
  }

  const visitId = Number(body.visit_id)
  const confirmation = String(body.confirmation ?? '').trim()
  const attemptedAt = String(body.attempted_at ?? '').trim()
  const screenshotB64 = String(body.screenshot_b64 ?? '')

  if (!Number.isInteger(visitId) || visitId <= 0) {
    return json({ error: 'bad_request', message: 'visit_id is required.' }, 400, cors)
  }
  if (!confirmation) {
    return json({ error: 'bad_request', message: 'Enter the confirmation number the portal gave you.' }, 400, cors)
  }
  if (confirmation.length > 200) {
    return json({ error: 'bad_request', message: 'That confirmation is too long (200 characters max).' }, 400, cors)
  }
  if (!attemptedAt || Number.isNaN(Date.parse(attemptedAt))) {
    return json({ error: 'bad_request', message: 'Enter the date you filed it.' }, 400, cors)
  }
  if (!screenshotB64) {
    return json({ error: 'bad_request', message: 'Attach a screenshot of the portal confirmation.' }, 400, cors)
  }

  const bytes = decodeB64(screenshotB64)
  if (!bytes) {
    return json({ error: 'bad_request', message: 'That screenshot is over 5MB or could not be read.' }, 400, cors)
  }
  if (bytes.length > MAX_SCREENSHOT_BYTES) {
    return json({ error: 'bad_request', message: 'That screenshot is over 5MB.' }, 400, cors)
  }
  const kind = sniffImage(bytes)
  if (!kind) {
    return json({ error: 'bad_request', message: 'The screenshot must be a JPEG or PNG.' }, 400, cors)
  }

  const sb = createClient(SUPABASE_URL, SERVICE_KEY, {
    global: { headers: { 'x-app-source': 'derm-tracker' } },
  })

  // ---- the post-cutoff acknowledgement --------------------------------------------------------
  // Recording a filing on a post-cutoff visit REMOVES it from the bot's queue permanently, so the
  // person has to know that is what they are doing. On a PRE-cutoff visit the bot was never going
  // to touch it, so demanding the same acknowledgement would be asking them to confirm a
  // consequence that does not exist. The warning has to be true or it stops being read.
  const { data: visitRow, error: visitErr } = await sb
    .from('visits').select('visit_date').eq('id', visitId).maybeSingle()
  if (visitErr) return json({ error: 'server_error', message: 'Could not read the visit.' }, 500, cors)
  if (!visitRow) return json({ error: 'not_found', message: `Visit ${visitId} was not found.` }, 404, cors)

  // Destructure the error and FAIL CLOSED. A discarded error here returns data:null, which would
  // read as "not post-cutoff" and silently skip the acknowledgement on exactly the visits that
  // need it. A guard that cannot prove its own precondition must refuse, not wave things through.
  const { data: cutoff, error: cutoffErr } = await sb.rpc('rpa_launch_cutoff')
  if (cutoffErr || !cutoff) {
    console.error('rpa_launch_cutoff unavailable:', cutoffErr?.message ?? 'null result')
    return json({ error: 'server_error', message: 'Could not check the bot cutoff date, so nothing was recorded.' }, 500, cors)
  }
  const postCutoff = String(visitRow.visit_date) >= String(cutoff)
  if (postCutoff && body.acknowledge_stops_bot !== true) {
    return json({
      error: 'confirm_required',
      post_cutoff: true,
      message: 'Recording this stops the bot from filing this visit. Confirm to continue.',
    }, 409, cors)
  }

  // ---- upload FIRST, then the row -------------------------------------------------------------
  // run_id doubles as the storage key, so it must satisfy the RPC's ^manual-[A-Za-z0-9_.-]{1,90}$
  // and the table's 100-char run_id CHECK. crypto.randomUUID() is hex+dashes, both safe.
  const runId = `manual-${crypto.randomUUID()}`
  const path = `${visitId}/${runId}.${kind.ext}`

  const { error: upErr } = await sb.storage
    .from('rpa-evidence')
    .upload(path, bytes, { contentType: kind.mime, upsert: false })
  if (upErr) {
    console.error('evidence upload failed:', upErr.message)
    return json({
      error: 'upload_failed',
      message: 'The screenshot could not be stored, so nothing was recorded. Try again.',
    }, 502, cors)
  }

  const { data: row, error: rpcErr } = await sb.rpc('fn_record_manual_gdo_report', {
    p_visit_id: visitId,
    p_confirmation: confirmation,
    p_attempted_at: new Date(attemptedAt).toISOString(),
    p_run_id: runId,
    p_screenshot_path: path,
    p_filed_by_email: email,
  })

  if (rpcErr) {
    // The row is what suppresses the bot. It did not commit, so nothing is suppressed - clean up
    // the orphan we just wrote rather than leaving evidence for a filing that is not on record.
    const { error: rmErr } = await sb.storage.from('rpa-evidence').remove([path])
    if (rmErr) console.error('orphan cleanup failed for', path, rmErr.message)
    console.error('fn_record_manual_gdo_report refused:', rpcErr.message)
    return json({ error: 'rejected', message: rpcErr.message }, 400, cors)
  }

  return json({
    ok: true,
    visit_id: visitId,
    run_id: runId,
    screenshot_path: path,
    filed_by_email: email,
    row,
  }, 200, cors)
})
