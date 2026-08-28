// Invoke ocr-address-sheet-rows in EXPLICIT mode for one ticket.
//
// WHY THIS EXISTS: derm.fn_sheet_row_ocr_targets (and the sheet-number sweep) deliberately skip
// folders whose cards are all placed, on the reasoning that a fully-placed sheet can never be
// auto-placed again. That premise is true for AUTO-PLACEMENT and false for VERIFICATION, so a
// fully-stamped sheet is exactly where a wrong row-to-client (or row-to-permit) binding survives.
// CLAUDE.md records this as the cause of the ticket-833813 transposition. The handlers carry an
// explicit mode for precisely this, and this script is the re-runnable way to reach it.
//
// Usage: node scripts/probes/fz_row_ocr_explicit.js <ticket> [--number]
//        --number also runs the sheet-NUMBER handler (payload shape differs: {tickets:[...]})
//
// Read-only in effect: it writes observations to derm.address_sheet_row_reads /
// address_sheet_scan_reads. It does NOT move a stamp, place a card, or touch geometry.
// NEVER prints the service-role key.
const fs = require('fs');
const path = require('path');

for (const line of fs.readFileSync(path.resolve(__dirname, '../../.env'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
  if (!m) continue;
  let v = m[2].trim();
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
  if (!(m[1] in process.env)) process.env[m[1]] = v;
}

const REF = process.env.SUPABASE_PROJECT_ID;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!KEY) { console.error('SUPABASE_SERVICE_ROLE_KEY missing from .env'); process.exit(1); }

const ticket = process.argv[2];
if (!ticket) { console.error('usage: node fz_row_ocr_explicit.js <ticket> [--number]'); process.exit(1); }
const alsoNumber = process.argv.includes('--number');

const call = async (slug, payload) => {
  const url = `https://${REF}.supabase.co/functions/v1/${slug}`;
  const r = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${KEY}`,
      apikey: KEY,
      'X-App-Source': 'sql',
    },
    body: JSON.stringify(payload),
  });
  const ctype = r.headers.get('content-type') || '';
  const text = await r.text();
  // Content-type guard: this estate has been bitten by an HTML body at HTTP 200.
  if (!ctype.includes('json')) {
    return { slug, status: r.status, nonJson: true, ctype, snippet: text.slice(0, 200) };
  }
  let body; try { body = JSON.parse(text); } catch { body = { parseError: true, snippet: text.slice(0, 200) }; }
  return { slug, status: r.status, body };
};

(async () => {
  if (alsoNumber) {
    const n = await call('ocr-address-sheet-number', { tickets: [ticket] });
    console.log('NUMBER >', JSON.stringify(n, null, 2).slice(0, 3000));
  }
  const rows = await call('ocr-address-sheet-rows', { ticket });
  console.log('ROWS   >', JSON.stringify(rows, null, 2).slice(0, 4000));
})();
