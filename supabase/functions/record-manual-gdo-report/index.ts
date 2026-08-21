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
//     (NO confirmation field - see below)
//     attempted_at: string,          // ISO instant the person filed it
//     screenshot_b64: string,        // JPEG or PNG, <=5MB decoded - required, it is the evidence
//     gdo_id?: number,               // REQUIRED when the visit has >1 GDO permit (see below)
//     acknowledge_stops_bot?: bool } // required ONLY when the visit is post-cutoff (see below)
//
// ⚠ gdo_id is not optional in practice. 44% of eligible visits carry 2-3 GDO permits, and the RPC
// refuses those unless it is told which one was filed under - recording the wrong permit is worse
// than recording nothing, because the row still suppresses the bot while the permit that was
// actually filed looks handled. The app reads permit_count from
// derm.visit_gdo_manual_eligibility and makes the person choose.
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

// 🛑 A BARE DATE MUST NOT BECOME MIDNIGHT UTC, OR EVERY FILING DISPLAYS A DAY EARLY.
// The form sends "2026-08-20". `new Date("2026-08-20")` is parsed as midnight UTC, and every app
// here renders in Eastern, so it came out as "Aug 19, 8:00 PM ET" - the day before the person
// filed. `new Date(y, m, d)` is not the fix either: it anchors to the BROWSER's zone, and this
// workspace runs from Spain half the time.
// Anchoring a bare date at 12:00 UTC lands at 08:00 ET, the same calendar day, and stays on the
// right day across both DST offsets. A full ISO instant is passed through untouched, so a caller
// that knows the real time still gets it stored exactly.
function toInstant(input: string): string {
  return /^\d{4}-\d{2}-\d{2}$/.test(input)
    ? new Date(input + 'T12:00:00Z').toISOString()
    : new Date(input).toISOString()
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
  // 🛑 NO `confirmation` INPUT, AND DO NOT ADD ONE BACK.
  // Fred: "it asks for a confirmation number, but there is not such a thing." Measured across all
  // 535 rows, portal_confirmation has held three values ever, and every live success carries the
  // same literal, which itself says "no tracking number". Twelve DB objects reference the column and
  // all twelve only test IS NULL / IS NOT NULL - nothing parses it.
  // It is also CLIENT-FACING: customer.gdo_reports exposes it to the Field Portal, where 84 reports
  // across 7 clients read it today under a heading that says "Confirmation". So the sentence is
  // written by fn_record_manual_gdo_report as a constant, and no caller can inject text a paying
  // customer reads.
  const attemptedAt = String(body.attempted_at ?? '').trim()
  const screenshotB64 = String(body.screenshot_b64 ?? '')
  // Absent means "the visit has one permit or none, let the function fill it in". A malformed value
  // is NOT coerced to absent: that would quietly turn a chosen permit into a guessed one.
  const gdoId = body.gdo_id === undefined || body.gdo_id === null ? null : Number(body.gdo_id)
  if (gdoId !== null && !Number.isInteger(gdoId)) {
    return json({ error: 'bad_request', message: 'gdo_id must be a whole number.' }, 400, cors)
  }

  if (!Number.isInteger(visitId) || visitId <= 0) {
    return json({ error: 'bad_request', message: 'visit_id is required.' }, 400, cors)
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

  // ---- the bot-suppression acknowledgement -----------------------------------------------------
  // Recording a filing on a visit the bot actually works REMOVES it from the queue permanently, so
  // the person has to know that is what they are doing. On a visit the bot was never going to
  // touch, demanding the same acknowledgement would be asking them to confirm a consequence that
  // does not exist. The warning has to be true or it stops being read.
  const { data: visitRow, error: visitErr } = await sb
    .from('visits').select('visit_date').eq('id', visitId).maybeSingle()
  if (visitErr) return json({ error: 'server_error', message: 'Could not read the visit.' }, 500, cors)
  if (!visitRow) return json({ error: 'not_found', message: `Visit ${visitId} was not found.` }, 404, cors)

  // 🛑 READ suppresses_bot FROM THE VIEW. Do NOT recompute it from post_cutoff here.
  // This function originally gated on `visit_date >= rpa_launch_cutoff()`. The UI was moved onto
  // derm.visit_gdo_manual_eligibility.suppresses_bot 25 minutes later (96a90c7) and this was never
  // revisited, which made the two disagree and produced a DEAD END: the UI only renders the
  // acknowledgement when suppresses_bot is true, so on a post-cutoff visit where it is false it
  // never sends acknowledge_stops_bot, and this returned 409 confirm_required with no control
  // anywhere on screen that could satisfy it. Measured 2026-08-20: 204 of 1,079 recordable visits
  // (19%) were in exactly that state - every eligible post-cutoff visit, because suppresses_bot is
  // true for none of them. The manual path has never committed a row in its history.
  // One rule, one place: the view decides, both sides read it.
  // 🛑 .schema('derm') IS LOAD-BEARING. This view lives in `derm`, and `sb` is built without a
  // `db.schema` option, so it resolves names against `public` by default. Without this the read
  // failed for EVERY visit and the function returned the 500 below, which is why the manual path
  // had never committed a single row. Measured end to end on 2026-08-21 (visit 7276).
  // Do NOT "fix" this by pinning the whole client to `derm`: the other two calls in this function
  // (.from('visits') and .rpc('fn_record_manual_gdo_report')) are both `public` and would break.
  const { data: elig, error: eligErr } = await sb
    .schema('derm')
    .from('visit_gdo_manual_eligibility')
    .select('suppresses_bot')
    .eq('visit_id', visitId)
    .maybeSingle()
  if (eligErr || !elig) {
    console.error('eligibility lookup failed:', eligErr?.message ?? 'no row')
    return json({ error: 'server_error', message: 'Could not check whether this stops the bot, so nothing was recorded.' }, 500, cors)
  }
  if (elig.suppresses_bot === true && body.acknowledge_stops_bot !== true) {
    return json({
      error: 'confirm_required',
      suppresses_bot: true,
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
    p_attempted_at: toInstant(attemptedAt),
    p_run_id: runId,
    p_screenshot_path: path,
    p_filed_by_email: email,
    p_gdo_id: gdoId,
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
