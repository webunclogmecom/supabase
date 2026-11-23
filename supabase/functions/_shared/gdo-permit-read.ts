// The reading of a Miami-Dade DERM GDO operating-permit PDF, shared by parse-gdo-permit (the permit form's reader,
// which stores the file) and gdo-lookup (Trello #242, which reads county permits without storing them).
// Moved here VERBATIM from parse-gdo-permit/index.ts on 2026-11-24: change it here, and both functions follow.
// Read parse-gdo-permit's header before touching the frequency pattern.

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

export async function flattenPdf(pdf: Uint8Array): Promise<string> {
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
export function toIso(d: string): string | null {
  const m = /^(\d{1,2})-([A-Za-z]{3})-(\d{4})$/.exec(d)
  if (!m) return null
  const mo = MONTHS[m[2].toUpperCase()]
  return mo ? `${m[3]}-${mo}-${m[1].padStart(2, '0')}` : null
}

export type Parsed = {
  isDermPermit: boolean
  ok: boolean
  missing: string[]
  fields: Record<string, unknown>
  chars: number
}

export async function parsePermit(pdf: Uint8Array): Promise<Parsed> {
  const flat = await flattenPdf(pdf)
  const fields: Record<string, unknown> = {}
  const missing: string[] = []

  // Two independent markers, so a random PDF fails clearly rather than yielding junk.
  const isDermPermit = /OFFICIAL DOCUMENT/i.test(flat) &&
    (/Miami-Dade County Pollution Control Ordinance/i.test(flat) ||
     /Fats,?\s*Oils and Grease Control Device/i.test(flat))

  // Printed zero-padded to 6 ("GDO-000951"), and stored that way since Trello #227 (Fred, 2026-11-19: "One form,
  // 6 digits"; the database refuses any other length). Until then we stored 5 ("GDO-00951").
  const gm = flat.match(/GDO[-\s]?(\d{3,7})/i)
  if (gm) {
    fields.gdo_number = 'GDO-' + String(parseInt(gm[1], 10)).padStart(6, '0')
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
