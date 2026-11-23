import { checkAppAction } from '../_shared/access-check.ts'   // 2026-10-21_0900 access phase 5
import { parsePermit, diag } from '../_shared/gdo-permit-read.ts'
export { diag }
// ============================================================================
// parse-gdo-permit — read a Miami-Dade DERM GDO operating-permit PDF and return
// the fields, so the Client App can pre-fill an Add/Edit Permit form instead of
// making staff retype what is already printed on the document.
// ============================================================================
// WHY THIS EXISTS (Fred, 2026-07-30): "the idea is for when adding a new Permit,
// is for the server to read the PDF and get the fields data by reading the pdf,
// so everything else we just need to fill out which are gonna be just Nickname
// and Property." Plus: if the PDF is not a GDO permit, the app must not let the
// user save.
//
// PROVEN BEFORE BUILDING. The same logic ran over 174 real permit PDFs from the
// gdo-permits bucket: 101 of 102 rows that already had a frequency agreed with
// their PDF, and it backfilled 48 missing DERM ceilings
// (scripts/lib/gdo_permit_parser.js, scripts/sync/backfill_gdo_frequency_from_pdf.js).
//
// THESE PDFS ARE TEXT, NOT SCANS. No OCR. Inflate the FlateDecode content
// streams, pull the PDF string literals, match ANCHORED patterns.
//
// ⚠ THE FREQUENCY PATTERN MUST STAY ANCHORED. The correct sentence lives under
// SPECIFIC CONDITIONS: "The Fats, Oils and Grease Control Device (FOG control
// device) shall be cleaned at a minimum every N day(s)." A greedy /(\d+) days?/
// instead matches the PENALTY boilerplate — "$2,000 per day and/or sixty (60)
// days in jail" — and returns a confident wrong ceiling. max_frequency_days
// drives over_gdo_max / compliant in customer.permits, so a wrong number is
// worse than a blank one. Do not "simplify" this regex.
//
// ⚠ SCOPE: Miami-Dade DERM only. Most clients have NO GDO (measured: 52% of Dade
// clients and 87% of Broward clients have none), and Broward/Palm Beach permits
// are a different document entirely. A non-DERM upload must fail LOUDLY with a
// reason, never yield partial junk.
// ============================================================================

const ALLOW_HEADERS_FALLBACK = 'authorization, x-client-info, apikey, content-type, x-app-source'
const MAX_STORE_ONLY_BYTES = 15 * 1024 * 1024   // a non-GDO permit PDF stored as it is (2026-11-02)

function corsHeaders(req: Request): Record<string, string> {
  // Echo the requested headers rather than hardcoding a list: a hardcoded list
  // silently breaks the moment the browser asks for one more (learned on the
  // Calendar's browser-called functions).
  const requested = req.headers.get('access-control-request-headers')
  return {
    'Access-Control-Allow-Origin': req.headers.get('origin') ?? '*',
    'Access-Control-Allow-Headers': requested && requested.length ? requested : ALLOW_HEADERS_FALLBACK,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin, Access-Control-Request-Headers',
  }
}

function json(body: unknown, status: number, req: Request) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(req), 'Content-Type': 'application/json' },
  })
}

// ---- PDF reading: _shared/gdo-permit-read.ts (moved verbatim 2026-11-24, shared with gdo-lookup) ----

Deno.serve(async (req: Request) => {
  // ⚠ PREFLIGHT BEFORE AUTH. If the auth gate runs first, the browser's OPTIONS
  // gets a 401 with no CORS headers and the real POST is never sent — which
  // presents as a silent network failure, not an auth error.
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) })
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405, req)

  // verify_jwt = true in config.toml, so the gateway has already rejected an
  // unauthenticated caller. This is staff-only tooling.
  // Access phase 5 (2026-10-21_0900): Edit in the Client App, as the caller (hr.check_app_action).
  const denied = await checkAppAction((req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, ''), 'parse_gdo_permit')
  if (denied) return json({ error: 'no_access', message: denied.message }, denied.status, req)
  try {
    const ct = req.headers.get('content-type') ?? ''
    let pdf: Uint8Array | null = null
    let filename = 'upload.pdf'
    let permitType = 'GDO'

    if (ct.includes('multipart/form-data')) {
      const form = await req.formData()
      const f = form.get('file')
      if (f instanceof File) {
        filename = f.name || filename
        pdf = new Uint8Array(await f.arrayBuffer())
      }
      const t = form.get('permit_type')
      if (typeof t === 'string' && t.trim()) permitType = t.trim().toUpperCase()
    } else {
      const body = await req.json().catch(() => ({}))
      if (typeof body.pdf_base64 === 'string') {
        const bin = atob(body.pdf_base64)
        pdf = new Uint8Array(bin.length)
        for (let i = 0; i < bin.length; i++) pdf[i] = bin.charCodeAt(i)
      }
      if (typeof body.filename === 'string') filename = body.filename
      if (typeof body.permit_type === 'string' && body.permit_type.trim()) permitType = body.permit_type.trim().toUpperCase()
    }
    if (!/^[A-Z0-9]{2,10}$/.test(permitType)) {
      return json({ error: 'bad_permit_type', message: 'Pick the permit type before attaching its PDF.' }, 400, req)
    }

    if (!pdf || pdf.length === 0) {
      return json({ error: 'no_file', message: 'Send the PDF as multipart "file" or JSON "pdf_base64".' }, 400, req)
    }
    if (String.fromCharCode(...pdf.slice(0, 5)) !== '%PDF-') {
      return json({
        ok: false, isDermPermit: false, reason: 'not_a_pdf',
        message: 'That file is not a PDF. Upload the DERM operating permit PDF.',
      }, 200, req)
    }

    // 2026-11-02 (permits for every county, Fred: "the PDF is optional" and a CCN is "just a number"): a permit
    // that is not a Miami-Dade GDO is stored as it is, never read. Its fields are typed in the Client App. The
    // gdo-permit-label reader skips it too (public.fn_gdo_permit_label_targets keeps to permit_types.reads_pdf).
    if (permitType !== 'GDO') {
      if (pdf.length > MAX_STORE_ONLY_BYTES) {
        return json({ ok: false, reason: 'too_large', message: 'That PDF is over 15 MB. Attach a smaller copy.' }, 200, req)
      }
      const svc = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
      const url = Deno.env.get('SUPABASE_URL') ?? ''
      // A fresh name every time (upsert false): an upload never replaces another permit's document.
      const path = `${permitType.toLowerCase()}/${new Date().toISOString().slice(0, 10)}-${crypto.randomUUID().slice(0, 8)}.pdf`
      const r = await fetch(`${url}/storage/v1/object/gdo-permits/${path}`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${svc}`, apikey: svc, 'Content-Type': 'application/pdf', 'x-upsert': 'false' },
        body: new Blob([pdf], { type: 'application/pdf' }),
      })
      if (!r.ok) {
        console.error('parse-gdo-permit store-only', r.status, (await r.text()).slice(0, 200))
        return json({ ok: false, reason: 'store_failed', message: 'The PDF could not be stored. Try again.' }, 200, req)
      }
      return json({ ok: true, isDermPermit: false, read: false, filename, permit_type: permitType,
        fields: { permit_document_path: path }, stored: true, store_note: null }, 200, req)
    }

    const parsed = await parsePermit(pdf)

    if (!parsed.isDermPermit) {
      return json({
        ok: false, isDermPermit: false, reason: 'not_a_derm_permit', chars: parsed.chars,
        message: parsed.chars < 200
          ? 'No readable text in that PDF, so it may be a scan. GDO permits from DERM are text PDFs; check you uploaded the permit itself.'
          : 'That PDF does not look like a Miami-Dade DERM operating permit. GDO permits are Miami-Dade only; Broward and Palm Beach use different documents.',
      }, 200, req)
    }

    if (!parsed.ok) {
      // 2026-11-18 (Trello #227, Fred: "check if the drag and drop also shows errors"): the sentence names the
      // fields in words. The codes travel as `missing_fields`, NOT `missing`: both permit dialogs (Client App and
      // Ops Portal) append "Missing: <the codes>" when a `missing` array is present, which showed staff
      // "gdo_number, permit_expiration, max_frequency_days".
      const words: Record<string, string> = {
        gdo_number: 'the permit number',
        permit_expiration: 'the expiration date',
        max_frequency_days: 'how often it must be cleaned',
      }
      const named = parsed.missing.map((k) => words[k] ?? k)
      const list = named.length > 1 ? `${named.slice(0, -1).join(', ')} and ${named[named.length - 1]}` : named[0]
      return json({
        ok: false, isDermPermit: true, reason: 'fields_missing', missing_fields: parsed.missing,
        fields: parsed.fields,
        message: `This looks like a DERM permit, but ${list} could not be read from it. Try another copy of the permit, or fill in the fields by hand.`,
      }, 200, req)
    }

    // ---- store the PDF, server-side -------------------------------------------
    // The app CANNOT upload this itself: there is no INSERT policy on
    // storage.objects for the gdo-permits bucket, so an authenticated client-side
    // upload is denied by RLS. Doing it here also means permit_document_path is
    // always server-set, which is why the form no longer has a path field.
    //
    // ⚠ NEVER OVERWRITE AN EXISTING PERMIT DOCUMENT. 14 existing rows were found
    // carrying a PDF belonging to a DIFFERENT permit; an upsert here would let the
    // next bad upload destroy a good document under a name that looks right. So
    // upload with upsert:false and fall back to a suffixed name on conflict.
    const svc = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    const url = Deno.env.get('SUPABASE_URL') ?? ''
    const gdo = String(parsed.fields.gdo_number)
    let storedPath: string | null = null
    let storeNote: string | null = null

    if (svc && url) {
      const attempts: string[] = []
      const put = async (path: string, upsert: boolean) => {
        const r = await fetch(`${url}/storage/v1/object/gdo-permits/${path}`, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${svc}`,
            apikey: svc,
            'Content-Type': 'application/pdf',
            'x-upsert': upsert ? 'true' : 'false',
          },
          body: new Blob([pdf], { type: 'application/pdf' }),
        })
        if (r.ok) return path
        attempts.push(`${path} -> ${r.status} ${(await r.text()).slice(0, 120)}`)
        return null
      }
      storedPath = await put(`gdo/${gdo}.pdf`, false)
      if (!storedPath) {
        // Name taken. Keep BOTH documents and let a human reconcile.
        const stamp = new Date().toISOString().slice(0, 10)
        storedPath = await put(`gdo/${gdo}-uploaded-${stamp}.pdf`, true)
        storeNote = storedPath
          ? `A document already existed for ${gdo}, so this upload was stored alongside it as ${storedPath} rather than replacing it. Check which is current.`
          : null
      }
      if (!storedPath) storeNote = 'The permit was read successfully but could not be stored. Try saving again.'
    }

    return json({
      ok: true,
      isDermPermit: true,
      filename,
      fields: { ...parsed.fields, permit_document_path: storedPath },
      stored: !!storedPath,
      store_note: storeNote,
    }, 200, req)
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    return json({ error: 'parse_failed', message: msg.slice(0, 200) }, 500, req)
  }
})
