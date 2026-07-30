// Miami-Dade DERM GDO operating-permit PDF parser.
// Text-based PDFs (no OCR): inflate the FlateDecode content streams, pull the PDF
// string literals, then match ANCHORED patterns. Anchoring is not optional - see
// FREQ below for the boilerplate that a greedy pattern grabs instead.
const zlib = require('zlib');

function flattenPdf(buf) {
  const s = buf.toString('latin1');
  let text = '';
  const re = /stream\r?\n?([\s\S]*?)endstream/g;
  let m;
  while ((m = re.exec(s))) {
    try { text += zlib.inflateSync(Buffer.from(m[1], 'latin1')).toString('latin1'); } catch (e) {}
  }
  const lits = text.match(/\((?:[^()\\]|\\.)*\)/g) || [];
  return lits.map(x => x.slice(1, -1))
             .join(' ')
             .replace(/\\([()\\])/g, '$1')
             .replace(/\s+/g, ' ')
             .trim();
}

const MONTHS = { JAN:'01',FEB:'02',MAR:'03',APR:'04',MAY:'05',JUN:'06',
                 JUL:'07',AUG:'08',SEP:'09',OCT:'10',NOV:'11',DEC:'12' };

function toIso(d) {
  const m = /^(\d{1,2})-([A-Z]{3})-(\d{4})$/i.exec(d);
  if (!m) return null;
  const mo = MONTHS[m[2].toUpperCase()];
  if (!mo) return null;
  return `${m[3]}-${mo}-${String(m[1]).padStart(2, '0')}`;
}

function parseGdoPermit(buf) {
  const flat = flattenPdf(buf);
  const out = { ok: false, fields: {}, missing: [], isDermPermit: false, chars: flat.length };

  // Is this even a Miami-Dade DERM operating permit? Two independent markers, so a
  // random PDF (or a Broward document) fails clearly instead of yielding junk.
  const isOfficial = /OFFICIAL DOCUMENT/i.test(flat);
  const isDerm = /Miami-Dade County Pollution Control Ordinance/i.test(flat)
              || /Fats,?\s*Oils and Grease Control Device/i.test(flat);
  out.isDermPermit = isOfficial && isDerm;

  // GDO / case number. Printed zero-padded to 6 digits ("GDO-000951") while the DB
  // stores 5 ("GDO-00951"), so normalise on the numeric part.
  const gm = flat.match(/GDO[-\s]?(\d{3,7})/i);
  if (gm) {
    const n = parseInt(gm[1], 10);
    out.fields.gdo_number = 'GDO-' + String(n).padStart(5, '0');
    out.fields.gdo_number_raw = gm[0];
    out.fields.gdo_number_digits = n;
  } else out.missing.push('gdo_number');

  // Validity window: "shall be valid from 01-JAN-2026 through 31-DEC-2026".
  const vm = flat.match(/valid\s+from\s+(\d{1,2}-[A-Z]{3}-\d{4})\s+through\s+(\d{1,2}-[A-Z]{3}-\d{4})/i);
  if (vm) {
    out.fields.permit_effective = toIso(vm[1]);
    out.fields.permit_expiration = toIso(vm[2]);
  } else out.missing.push('permit_expiration');

  // FREQ - THE ONE THAT MUST BE ANCHORED.
  // Correct sentence, under SPECIFIC CONDITIONS:
  //   "The Fats, Oils and Grease Control Device (FOG control device) shall be
  //    cleaned at a minimum every N day(s)."
  // A greedy /(\d+)\s*days?/ instead grabs the PENALTY boilerplate
  //   "...not to exceed $2,000 per day and/or sixty (60) days in jail"
  // and confidently returns 30/60 for permits that state something else. This value
  // is the DERM compliance ceiling feeding over_gdo_max, so a wrong number is worse
  // than a blank one.
  const fm = flat.match(/Grease Control Device[^.]{0,80}?cleaned\s+at\s+a\s+minimum\s+every\s+(\d{1,3})\s*day/i);
  if (fm) out.fields.max_frequency_days = parseInt(fm[1], 10);
  else out.missing.push('max_frequency_days');

  // Useful extras, not written by the backfill.
  const it = flat.match(/Permit Issued To:\s*(.{2,90}?)\s*Facility Location:/i);
  if (it) out.fields.issued_to = it[1].trim();
  const fl = flat.match(/Facility Location:\s*(.{2,110}?)\s*Contact Name/i);
  if (fl) out.fields.facility_location = fl[1].trim();
  const cap = flat.match(/Capacity\s*\(GPM\)\s*(\d+)\s+(\d+)/i);
  if (cap) out.fields.capacity_gpm = parseInt(cap[2], 10);

  out.ok = out.isDermPermit && !!out.fields.gdo_number
           && !!out.fields.permit_expiration && out.fields.max_frequency_days != null;
  return out;
}

module.exports = { parseGdoPermit, flattenPdf };
