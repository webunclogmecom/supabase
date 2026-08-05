// ============================================================================
// ocr_address_sheet_numbers.js — read the sheet number printed on a SCANNED
// DERM address sheet, so the Stamp auto-place can tell whether the paper the
// driver used is the sheet we generated.
// ============================================================================
// WHY
//   The auto-place positions stamps from the slot order of the sheet WE
//   generated. On ticket 831710 the driver used a pre-printed pad sheet (1008)
//   instead of our generated sheet (1079), so a client's stamp landed on
//   another client's row. The causality guard (2026-08-04_1912) catches sheets
//   generated AFTER the dump; this catches the rest, by reading the number DERM
//   already prints top-right.
//
//   🛑 We may NOT put a QR code or any mark on the sheet (Fred, 2026-08-04) —
//      it is a regulator-facing compliance form. Reading it is allowed.
//
// SEMANTICS THAT MATTER
//   * Writes derm.address_sheet_scan_reads. The gate is DISAGREEMENT-ONLY:
//     a read that names a different sheet blocks placement; NO read means no
//     opinion. So this script can never break auto-placement by not having run.
//   * `sheet_no_read = NULL` with confidence 'unreadable' means "the reader ran
//     and could not read it". That is NOT the same as having no row. Both are
//     recorded so a future sweep can tell them apart.
//   * Never writes to derm.address_sheets or derm.address_row_map. Same rule as
//     ocr_derm_manifest_numbers.js: observe, do not mutate the record.
//
// CLI
//   node scripts/sync/ocr_address_sheet_numbers.js                # all unread
//   node scripts/sync/ocr_address_sheet_numbers.js --limit=3
//   node scripts/sync/ocr_address_sheet_numbers.js --ticket=831710
//   node scripts/sync/ocr_address_sheet_numbers.js --all          # re-read everything
//   node scripts/sync/ocr_address_sheet_numbers.js --dry-run      # read, do not write
//
// Required env (Supabase/.env): ANTHROPIC_API_KEY, SUPABASE_PAT, SUPABASE_URL
// ============================================================================

const https = require('https');
const path = require('path');
const fs = require('fs');

// No external deps by convention (see docs/superpowers/plans/2026-07-01-...): parse .env inline
// rather than requiring dotenv, which is not installed in this repo.
const ENV = (() => {
  const out = {};
  const p = path.resolve(__dirname, '../../.env');
  if (!fs.existsSync(p)) return out;
  for (const line of fs.readFileSync(p, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!m) continue;
    out[m[1]] = m[2].trim().replace(/^["']|["']$/g, '');
  }
  return out;
})();

const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || ENV.ANTHROPIC_API_KEY;
const PAT = process.env.SUPABASE_PAT || ENV.SUPABASE_PAT;
const SUPABASE_URL = (process.env.SUPABASE_URL || ENV.SUPABASE_URL || '').replace(/\/$/, '');
if (!ANTHROPIC_API_KEY) throw new Error('ANTHROPIC_API_KEY required in Supabase/.env');
if (!PAT) throw new Error('SUPABASE_PAT required in Supabase/.env');
const ref = SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

const MODEL = 'claude-sonnet-5';
const arg = n => (process.argv.find(a => a.startsWith('--' + n + '=')) || '').split('=')[1];
const LIMIT = arg('limit');
const TICKET = arg('ticket');
const ALL = process.argv.includes('--all');
const DRY = process.argv.includes('--dry-run');

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST',
      headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }
    }, r => { let d = ''; r.on('data', c => d += c); r.on('end', () => {
      if (r.statusCode >= 300) return rej(new Error(r.statusCode + ': ' + d.slice(0, 300)));
      res(JSON.parse(d)); }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

const S = v => (v === null || v === undefined) ? 'null' : "'" + String(v).replace(/'/g, "''") + "'";

function fetchBytes(url, depth = 0) {
  return new Promise((res, rej) => {
    https.get(url, r => {
      if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location && depth < 2)
        return res(fetchBytes(r.headers.location, depth + 1));
      if (r.statusCode !== 200) return rej(new Error('image ' + r.statusCode));
      const parts = []; r.on('data', c => parts.push(c)); r.on('end', () => res(Buffer.concat(parts)));
    }).on('error', rej);
  });
}

// Ask ONLY for the sheet number. Anchored to its fixed position, and explicitly
// told to say UNREADABLE rather than guess -- a guessed number here would block a
// legitimate placement (false positive) or clear a bad one (false negative).
const PROMPT =
  'This is a scanned Miami-Dade DERM "Fats, Oils and Grease (FOG) Single Load Liquid Waste ' +
  'Transporter eManifest" address sheet. In the TOP RIGHT corner there is a large pre-printed ' +
  'sheet number, for example 1008, 1059, 1071, or a multi-page form like 1072-1 or 1072-2. ' +
  'Report EXACTLY that number as printed, including any "-1" / "-2" page suffix. ' +
  'Do not report the ticket number, the DERM decal number, the GDO numbers, the gallons, or any ' +
  'handwritten value. Reply with ONLY the number, nothing else. ' +
  'If you cannot read it clearly, or you are not certain it is the top-right sheet number, ' +
  'reply with exactly: UNREADABLE';

function askVision(buf, mediaType) {
  const body = JSON.stringify({
    model: MODEL, max_tokens: 32,
    messages: [{ role: 'user', content: [
      { type: 'image', source: { type: 'base64', media_type: mediaType, data: buf.toString('base64') } },
      { type: 'text', text: PROMPT }
    ] }]
  });
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.anthropic.com', path: '/v1/messages', method: 'POST',
      headers: { 'x-api-key': ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01',
                 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }
    }, r => { let d = ''; r.on('data', c => d += c); r.on('end', () => {
      if (r.statusCode >= 300) return rej(new Error('anthropic ' + r.statusCode + ': ' + d.slice(0, 200)));
      const j = JSON.parse(d);
      res((j.content && j.content[0] && j.content[0].text || '').trim()); }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

// Accept 1008 or 1072-1. Anything else is treated as unreadable rather than coerced.
function classify(raw) {
  const t = (raw || '').trim();
  if (/^UNREADABLE$/i.test(t)) return { sheet_no: null, confidence: 'unreadable' };
  const m = t.match(/^(\d{3,5})(?:\s*-\s*(\d))?$/);
  if (!m) return { sheet_no: null, confidence: 'unreadable' };
  return { sheet_no: m[1] + (m[2] ? '-' + m[2] : ''), confidence: 'high' };
}

(async () => {
  console.log('# OCR address-sheet numbers — ' + new Date().toISOString() + (DRY ? '  (DRY RUN)' : ''));

  // ⚠ Resolve page images with derm.ticket_page_images(), NOT address_row_map.image_url.
  // That column is stale: on ticket 310429 the stamp_page-2 rows point at address_1.jpeg, so
  // reading from it OCR'd page 1 twice and reported 1072-1 for both pages; and on 831710 it is
  // the literal 'pending', which skipped the one sheet we most needed to read. The resolver is
  // what the Studio itself renders from, and it returns the right file per page.
  const rows = await pg(`
    with tickets as (
      select distinct r.dump_folder, r.white_manifest_number as ticket
        from derm.address_row_map r
       where r.white_manifest_number is not null
         ${TICKET ? 'and r.white_manifest_number = ' + S(TICKET) : ''}
    )
    select t.dump_folder, t.ticket, p.page::int as page, p.image_url
      from tickets t
      cross join lateral (
        select ord as page, url as image_url
          from unnest(derm.ticket_page_images(t.ticket)) with ordinality as u(url, ord)
      ) p
     where p.image_url is not null
       and p.image_url <> 'pending'
       ${ALL || TICKET ? '' : `and not exists (select 1 from derm.address_sheet_scan_reads sr
                                                where sr.dump_folder = t.dump_folder and sr.page = p.page)`}
     order by t.dump_folder, p.page
     ${LIMIT ? 'limit ' + parseInt(LIMIT, 10) : ''}`);

  if (!rows.length) { console.log('nothing to read'); return; }
  console.log(rows.length + ' page(s) to read\n');

  let ok = 0, unreadable = 0, failed = 0;
  for (const r of rows) {
    const url = /^https?:/.test(r.image_url) ? r.image_url : SUPABASE_URL + (r.image_url.startsWith('/') ? '' : '/') + r.image_url;
    const ext = (url.split('.').pop() || '').toLowerCase().split('?')[0];
    const mediaType = ext === 'png' ? 'image/png' : 'image/jpeg';
    let raw = '', cls = { sheet_no: null, confidence: 'unreadable' };
    try {
      const buf = await fetchBytes(url);
      raw = await askVision(buf, mediaType);
      cls = classify(raw);
    } catch (e) {
      failed++; console.log(`  ${r.dump_folder} p${r.page}  ERROR ${e.message}`); continue;
    }
    cls.sheet_no ? ok++ : unreadable++;
    console.log(`  ${r.dump_folder} p${r.page}  read=${cls.sheet_no || 'UNREADABLE'}  (raw ${JSON.stringify(raw)})`);

    if (!DRY) {
      await pg(`insert into derm.address_sheet_scan_reads
                  (dump_folder, page, sheet_no_read, raw_read, confidence, model, image_url, read_at)
                values (${S(r.dump_folder)}, ${r.page}, ${S(cls.sheet_no)}, ${S(raw)},
                        ${S(cls.confidence)}, ${S(MODEL)}, ${S(r.image_url)}, now())
                on conflict (dump_folder, page) do update
                   set sheet_no_read = excluded.sheet_no_read, raw_read = excluded.raw_read,
                       confidence = excluded.confidence, model = excluded.model,
                       image_url = excluded.image_url, read_at = excluded.read_at`);
    }
  }

  console.log(`\nread ${ok}   unreadable ${unreadable}   failed ${failed}`);

  // Always report disagreements: these are the rows that will now block an auto-place.
  const bad = await pg(`
    select sr.dump_folder, sr.sheet_no_read, s.sheet_no as our_sheet_no
      from derm.address_sheet_scan_reads sr
      join public.derm_manifests m
        on coalesce(m.white_manifest_number, m.yellow_ticket_number) = replace(sr.dump_folder,'ticket-','')
       and m.deleted_at is null
      join derm.address_sheet_manifests l on l.manifest_id = m.id
      join derm.address_sheets s on s.id = l.sheet_id and s.deleted_at is null
     where sr.sheet_no_read is not null
       and sr.sheet_no_read <> s.sheet_no::text
     group by 1,2,3 order by 1`);
  console.log('\nDISAGREEMENTS (scan says one sheet, we linked another) — these now block auto-place:');
  console.log(bad.length ? JSON.stringify(bad, null, 1) : '  none');
})();
