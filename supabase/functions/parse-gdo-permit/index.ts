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

// ---- PDF text extraction (Deno: no node:zlib, use DecompressionStream) ------
async function inflateWith(bytes: Uint8Array, fmt: 'deflate' | 'deflate-raw'): Promise<string> {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream(fmt))
  const buf = await new Response(stream).arrayBuffer()
  // Byte-preserving decode. NOT TextDecoder('latin1') — in Deno that is an alias for
  // windows-1252 and remaps 0x80-0x9F, which corrupts the text we then regex over.
  const u8 = new Uint8Array(buf)
  let s = ''
  const CH = 0x8000
  for (let i = 0; i < u8.length; i += CH) s += String.fromCharCode(...u8.subarray(i, i + CH))
  return s
}

// ⚠ WHATWG DecompressionStream is STRICTER than Node's zlib.inflateSync, which is why
// the first two deploys of this function returned "not a DERM permit" on a real permit
// while the Node parser handled the identical file: Node tolerates a truncated or
// trailing-garbage tail, DecompressionStream throws "corrupt deflate stream" for the
// whole stream. PDF FlateDecode is nominally zlib (RFC 1950), but some producers emit
// raw deflate, and our byte slice can carry the EOL before `endstream`. So try both
// framings, and drop the 2-byte zlib header for the raw attempt.
async function inflate(bytes: Uint8Array): Promise<string> {
  try { return await inflateWith(bytes, 'deflate') } catch { /* fall through */ }
  try { return await inflateWith(bytes, 'deflate-raw') } catch { /* fall through */ }
  if (bytes.length > 2) {
    try { return await inflateWith(bytes.slice(2), 'deflate-raw') } catch { /* fall through */ }
  }
  // Trailing EOL bytes before `endstream` can break a strict decoder; retry trimmed.
  let end = bytes.length
  while (end > 0 && (bytes[end - 1] === 0x0a || bytes[end - 1] === 0x0d || bytes[end - 1] === 0x20)) end--
  if (end !== bytes.length) {
    try { return await inflateWith(bytes.slice(0, end), 'deflate') } catch { /* fall through */ }
  }
  throw new Error('all inflate strategies failed')
}

// ⚠ DO NOT round-trip the binary through a string here. Node's
// buf.toString('latin1') is byte-preserving ISO-8859-1, but the WHATWG
// TextDecoder('latin1') available in Deno is an ALIAS FOR windows-1252, which
// remaps bytes 0x80-0x9F to different codepoints. charCodeAt() then cannot
// recover the original bytes, every inflate throws, and the function reports
// "not a DERM permit" on a perfectly good permit. That is exactly how the first
// deploy of this function failed its own test against a real PDF.
// So: find the stream boundaries in the BYTE array and slice bytes.
function indexOfSeq(hay: Uint8Array, needle: string, from = 0): number {
  const n = needle.length
  outer: for (let i = from; i <= hay.length - n; i++) {
    for (let j = 0; j < n; j++) if (hay[i + j] !== needle.charCodeAt(j)) continue outer
    return i
  }
  return -1
}

export const diag = { streams: 0, inflated: 0, failed: 0, firstError: '' }

async function flattenPdf(pdf: Uint8Array): Promise<string> {
  diag.streams = 0; diag.inflated = 0; diag.failed = 0; diag.firstError = ''
  let text = ''
  let pos = 0
  for (;;) {
    const s = indexOfSeq(pdf, 'stream', pos)
    if (s < 0) break
    // skip the EOL after the `stream` keyword (CR, LF or CRLF)
    let a = s + 6
    if (pdf[a] === 0x0d) a++
    if (pdf[a] === 0x0a) a++
    const e = indexOfSeq(pdf, 'endstream', a)
    if (e < 0) break
    diag.streams++
    // COPY, do not pass a subarray view: Blob over a shared-buffer view has bitten
    // this before, and the cost of a copy here is irrelevant next to a wrong answer.
    const slice = new Uint8Array(pdf.slice(a, e))
    try {
      text += await inflate(slice)
      diag.inflated++
    } catch (err) {
      diag.failed++
      if (!diag.firstError) diag.firstError = (err instanceof Error ? err.message : String(err)).slice(0, 120)
    }
    pos = e + 9
  }
  const lits = text.match(/\((?:[^()\\]|\\.)*\)/g) ?? []
  return lits.map((x) => x.slice(1, -1))
             .join(' ')
             .replace(/\\([()\\])/g, '$1')
             .replace(/\s+/g, ' ')
             .trim()
}

const MONTHS: Record<string, string> = {
  JAN: '01', FEB: '02', MAR: '03', APR: '04', MAY: '05', JUN: '06',
  JUL: '07', AUG: '08', SEP: '09', OCT: '10', NOV: '11', DEC: '12',
}
function toIso(d: string): string | null {
  const m = /^(\d{1,2})-([A-Za-z]{3})-(\d{4})$/.exec(d)
  if (!m) return null
  const mo = MONTHS[m[2].toUpperCase()]
  return mo ? `${m[3]}-${mo}-${m[1].padStart(2, '0')}` : null
}

type Parsed = {
  isDermPermit: boolean
  ok: boolean
  missing: string[]
  fields: Record<string, unknown>
  chars: number
}

async function parsePermit(pdf: Uint8Array): Promise<Parsed> {
  const flat = await flattenPdf(pdf)
  const fields: Record<string, unknown> = {}
  const missing: string[] = []

  // Two independent markers, so a random PDF fails clearly rather than yielding junk.
  const isDermPermit = /OFFICIAL DOCUMENT/i.test(flat) &&
    (/Miami-Dade County Pollution Control Ordinance/i.test(flat) ||
     /Fats,?\s*Oils and Grease Control Device/i.test(flat))

  // Printed zero-padded to 6 ("GDO-000951"); we store 5 ("GDO-00951").
  const gm = flat.match(/GDO[-\s]?(\d{3,7})/i)
  if (gm) {
    fields.gdo_number = 'GDO-' + String(parseInt(gm[1], 10)).padStart(5, '0')
  } else missing.push('gdo_number')

  const vm = flat.match(/valid\s+from\s+(\d{1,2}-[A-Za-z]{3}-\d{4})\s+through\s+(\d{1,2}-[A-Za-z]{3}-\d{4})/i)
  if (vm) {
    fields.permit_effective = toIso(vm[1])
    fields.permit_expiration = toIso(vm[2])
  } else missing.push('permit_expiration')

  // ⚠ ANCHORED. See the header note before touching this.
  const fm = flat.match(/Grease Control Device[^.]{0,80}?cleaned\s+at\s+a\s+minimum\s+every\s+(\d{1,3})\s*day/i)
  if (fm) fields.max_frequency_days = parseInt(fm[1], 10)
  else missing.push('max_frequency_days')

  // Context for the reviewer; not written to gdos by the app.
  const it = flat.match(/Permit Issued To:\s*(.{2,90}?)\s*Facility Location:/i)
  if (it) fields.issued_to = it[1].trim()
  const fl = flat.match(/Facility Location:\s*(.{2,110}?)\s*Contact Name/i)
  if (fl) fields.facility_location = fl[1].trim()
  const cap = flat.match(/Capacity\s*\(GPM\)\s*(\d+)\s+(\d+)/i)
  if (cap) fields.capacity_gpm = parseInt(cap[2], 10)

  // status is NOT printed on the permit; derive it from the validity window.
  if (fields.permit_expiration) {
    const today = new Date().toISOString().slice(0, 10)
    fields.status = (fields.permit_expiration as string) < today ? 'EXPIRED' : 'ACTIVE'
  }

  return {
    isDermPermit,
    ok: isDermPermit && !!fields.gdo_number && !!fields.permit_expiration && fields.max_frequency_days != null,
    missing,
    fields,
    chars: flat.length,
  }
}

Deno.serve(async (req: Request) => {
  // ⚠ PREFLIGHT BEFORE AUTH. If the auth gate runs first, the browser's OPTIONS
  // gets a 401 with no CORS headers and the real POST is never sent — which
  // presents as a silent network failure, not an auth error.
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) })
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405, req)

  // verify_jwt = true in config.toml, so the gateway has already rejected an
  // unauthenticated caller. This is staff-only tooling.
  try {
    const ct = req.headers.get('content-type') ?? ''
    let pdf: Uint8Array | null = null
    let filename = 'upload.pdf'

    if (ct.includes('multipart/form-data')) {
      const form = await req.formData()
      const f = form.get('file')
      if (f instanceof File) {
        filename = f.name || filename
        pdf = new Uint8Array(await f.arrayBuffer())
      }
    } else {
      const body = await req.json().catch(() => ({}))
      if (typeof body.pdf_base64 === 'string') {
        const bin = atob(body.pdf_base64)
        pdf = new Uint8Array(bin.length)
        for (let i = 0; i < bin.length; i++) pdf[i] = bin.charCodeAt(i)
      }
      if (typeof body.filename === 'string') filename = body.filename
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

    const parsed = await parsePermit(pdf)

    if (!parsed.isDermPermit) {
      return json({
        ok: false, isDermPermit: false, reason: 'not_a_derm_permit', chars: parsed.chars,
        diag: { ...diag },
        message: parsed.chars < 200
          ? 'No readable text in that PDF — it may be a scan. GDO permits from DERM are text PDFs; check you uploaded the permit itself.'
          : 'That PDF does not look like a Miami-Dade DERM operating permit. GDO permits are Miami-Dade only; Broward and Palm Beach use different documents.',
      }, 200, req)
    }

    if (!parsed.ok) {
      return json({
        ok: false, isDermPermit: true, reason: 'fields_missing', missing: parsed.missing,
        fields: parsed.fields,
        message: `This looks like a DERM permit, but ${parsed.missing.join(' and ')} could not be read from it.`,
      }, 200, req)
    }

    return json({ ok: true, isDermPermit: true, filename, fields: parsed.fields }, 200, req)
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    return json({ error: 'parse_failed', message: msg.slice(0, 200) }, 500, req)
  }
})
