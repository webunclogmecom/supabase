// ocr_derm_receipts_for_number_and_date.js
//
// Targets `derm_manifests.derm_manifest_url` (the disposal facility receipt —
// Broward Septage Receipt or Miami-Dade equivalent). Extracts:
//   - jurisdiction (broward / dade / unknown)
//   - ticket_or_manifest_number (yellow ticket # for Broward, white manifest # for Dade)
//   - dump_date (date stamped on the receipt below the ticket #)
//
// This is DIFFERENT from the earlier OCR script that targeted derm_address_url
// (the FOG eManifest form). Per Fred 2026-05-19, the canonical identifiers
// (white_manifest_number for Miami-Dade, yellow_ticket_number for Broward)
// live on the receipts, not the eManifest form.
//
// CLI:
//   node scripts/sync/ocr_derm_receipts_for_number_and_date.js
//   node scripts/sync/ocr_derm_receipts_for_number_and_date.js --manifest-id=579
//   node scripts/sync/ocr_derm_receipts_for_number_and_date.js --limit=3

const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

if (!ANTHROPIC_API_KEY) throw new Error('ANTHROPIC_API_KEY required in .env');

const ONE = (process.argv.find(a => a.startsWith('--manifest-id=')) || '').split('=')[1];
const LIMIT = (process.argv.find(a => a.startsWith('--limit=')) || '').split('=')[1];

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ if(r.statusCode>=300) return rej(new Error(r.statusCode+': '+d.slice(0,400))); res(JSON.parse(d)); }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

function fetchBytes(url) {
  return new Promise((res, rej) => {
    https.get(url, r => {
      if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) return fetchBytes(r.headers.location).then(res, rej);
      if (r.statusCode !== 200) return rej(new Error('HTTP ' + r.statusCode + ' fetching ' + url));
      const chunks = []; r.on('data', c => chunks.push(c));
      r.on('end', () => res({ buf: Buffer.concat(chunks), contentType: r.headers['content-type'] || 'image/jpeg' }));
    }).on('error', rej);
  });
}

async function askClaude(imageBuf, contentType) {
  const mediaType = contentType.split(';')[0].trim();
  const body = JSON.stringify({
    model: 'claude-opus-4-7',
    max_tokens: 400,
    messages: [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: mediaType, data: imageBuf.toString('base64') } },
        { type: 'text', text:
`This is a disposal facility receipt photo from a grease-trap pumping operation. It will be ONE of these document types:

(A) BROWARD COUNTY SEPTAGE RECEIVING RECEIPT — has "Broward County" / "SEPTAGE RECEIVING FACILITY" header, fields like "Ticket Number", "Ticket Date", "EPD Decal", "Customer", "Waste Volume". The ticket number is typically 6 digits like "305031".

(B) MIAMI-DADE DERM disposal receipt — has Miami-Dade county or DERM markings, with a printed manifest number typically 6 digits like "824533" and a date field.

(C) Something else — a FOG eManifest form, a generic photo, or unreadable.

Extract THREE values and return ONLY a single-line JSON object with these keys (no markdown fences, no other text):

{"jurisdiction":"broward"|"dade"|"unknown", "number":"<digits or null>", "dump_date":"<YYYY-MM-DD or null>"}

- "jurisdiction": which county/jurisdiction issued this receipt
- "number": the ticket number (Broward) or manifest number (Miami-Dade) — JUST digits, no prefix, no separator
- "dump_date": the date the waste was dumped/received at the facility, normalized to YYYY-MM-DD. Often appears below the ticket number. If multiple dates appear, prefer the one labeled "Ticket Date" / "Date Waste Received" / similar.

If any value is unreadable or missing, use null. If the document is type (C), return all-null with jurisdiction "unknown".

Example responses:
{"jurisdiction":"broward","number":"305031","dump_date":"2026-05-14"}
{"jurisdiction":"dade","number":"824533","dump_date":"2026-05-15"}
{"jurisdiction":"unknown","number":null,"dump_date":null}`
        }
      ]
    }]
  });
  return new Promise((res, rej) => {
    const req = https.request({ hostname: 'api.anthropic.com', path: '/v1/messages', method: 'POST', headers: { 'x-api-key': ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ if(r.statusCode>=300) return rej(new Error('Anthropic ' + r.statusCode + ': ' + d.slice(0, 400))); try { res(JSON.parse(d)); } catch (e) { rej(e); } }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log(`# OCR receipts for number+date — ${new Date().toISOString()}`);

  let where;
  if (ONE) where = `id = ${parseInt(ONE, 10)} AND derm_manifest_url IS NOT NULL`;
  else where = `derm_manifest_url IS NOT NULL
                AND ((white_manifest_number IS NULL AND yellow_ticket_number IS NULL)
                     OR dump_ticket_date IS NULL)`;
  const limitClause = LIMIT ? `LIMIT ${parseInt(LIMIT, 10)}` : '';

  const candidates = await pg(`
    SELECT id, white_manifest_number, yellow_ticket_number, dump_ticket_date::text AS dump_ticket_date,
           derm_manifest_url, client_id,
           (SELECT name FROM public.clients WHERE id = dm.client_id) AS client_name
    FROM public.derm_manifests dm
    WHERE ${where}
    ORDER BY id DESC
    ${limitClause}`);

  console.log('Candidates:', candidates.length);

  const results = [];
  for (const m of candidates) {
    process.stdout.write(`  [${m.id}] ${m.client_name || '(no client)'} ... `);
    try {
      const { buf, contentType } = await fetchBytes(m.derm_manifest_url);
      const resp = await askClaude(buf, contentType);
      const text = (resp.content || []).map(b => b.text || '').join('').trim();
      // Try parse JSON
      let parsed;
      try { parsed = JSON.parse(text); }
      catch { parsed = { raw: text, parseError: true }; }
      results.push({
        manifest_id: m.id,
        current: { white: m.white_manifest_number, yellow: m.yellow_ticket_number, dump_date: m.dump_ticket_date },
        proposed: parsed,
      });
      console.log(JSON.stringify(parsed));
    } catch (e) {
      console.log('ERROR:', e.message.slice(0, 120));
      results.push({ manifest_id: m.id, error: e.message });
    }
  }

  console.log('\n=== Proposed updates ===');
  for (const r of results) {
    if (r.error) { console.log(`  ${r.manifest_id}: ERROR ${r.error}`); continue; }
    const p = r.proposed;
    if (p.parseError) { console.log(`  ${r.manifest_id}: parse error — raw: "${p.raw}"`); continue; }
    const sets = [];
    if (p.number) {
      if (p.jurisdiction === 'broward' && !r.current.yellow) sets.push(`yellow_ticket_number = '${p.number}'`);
      else if (p.jurisdiction === 'dade' && !r.current.white) sets.push(`white_manifest_number = '${p.number}'`);
    }
    if (p.dump_date && !r.current.dump_date) sets.push(`dump_ticket_date = '${p.dump_date}'`);
    if (sets.length === 0) {
      console.log(`  ${r.manifest_id}: nothing to apply (current=${JSON.stringify(r.current)}, proposed=${JSON.stringify(p)})`);
    } else {
      console.log(`  ${r.manifest_id}: UPDATE public.derm_manifests SET ${sets.join(', ')} WHERE id = ${r.manifest_id};`);
    }
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
