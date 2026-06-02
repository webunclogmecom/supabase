// ============================================================================
// ocr_derm_manifest_numbers.js — Claude Vision backfill for missing
// white_manifest_number on manifests that already have a PDF/photo.
// ============================================================================
// Workflow:
//   1. Query derm.manifest_health for manifests where has_pdfs_no_number=true
//   2. For each, fetch the image bytes from Supabase Storage (public URL)
//   3. Send to Claude Vision asking ONLY for the white manifest number
//   4. Parse + classify confidence
//   5. INSERT a row in public.derm_manifest_number_proposals (status='pending')
//      — never auto-write to derm_manifests.white_manifest_number; ops review first
//
// CLI:
//   node scripts/sync/ocr_derm_manifest_numbers.js                     # all 121
//   node scripts/sync/ocr_derm_manifest_numbers.js --limit=5           # test run
//   node scripts/sync/ocr_derm_manifest_numbers.js --manifest-id=996   # one specific
//   node scripts/sync/ocr_derm_manifest_numbers.js --dry-run           # OCR but skip INSERT
//
// Required env:
//   ANTHROPIC_API_KEY, SUPABASE_PAT, SUPABASE_URL
// ============================================================================

const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
const PAT = process.env.SUPABASE_PAT;
const SUPABASE_URL = process.env.SUPABASE_URL;
const ref = SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

if (!ANTHROPIC_API_KEY) throw new Error('ANTHROPIC_API_KEY required in .env');

const LIMIT = (process.argv.find(a => a.startsWith('--limit='))    || '').split('=')[1];
const ONE   = (process.argv.find(a => a.startsWith('--manifest-id=')) || '').split('=')[1];
const DRY   = process.argv.includes('--dry-run');

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ if(r.statusCode>=300) return rej(new Error(r.statusCode+': '+d.slice(0,200))); res(JSON.parse(d)); }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

function fetchBytes(url) {
  return new Promise((res, rej) => {
    https.get(url, r => {
      // Follow one redirect if needed (AT URLs sometimes redirect)
      if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) {
        return fetchBytes(r.headers.location).then(res, rej);
      }
      if (r.statusCode !== 200) return rej(new Error('HTTP ' + r.statusCode + ' fetching ' + url));
      const chunks = [];
      r.on('data', c => chunks.push(c));
      r.on('end', () => res({ buf: Buffer.concat(chunks), contentType: r.headers['content-type'] || 'image/jpeg' }));
    }).on('error', rej);
  });
}

async function askClaude(imageBuf, contentType) {
  const mediaType = contentType.split(';')[0].trim();
  const body = JSON.stringify({
    model: 'claude-opus-4-7',
    max_tokens: 200,
    messages: [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: mediaType, data: imageBuf.toString('base64') } },
        { type: 'text', text:
`This is a photo of a Miami-Dade DERM "Fats, Oils and Grease (FOG) Single Load Liquid Waste Transporter eManifest" form.
The form typically has a header "Fats, Oils and Grease (FOG)" and "Single Load Liquid Waste Transporter eManifest", a version stamp like "DERM_V4.00_02-28-2019" in the top-right, and a serial number preprinted in the top-right corner near the version stamp.

Find the WHITE MANIFEST NUMBER. It is a preprinted serial number (NOT handwritten) in the top-right corner of the form, typically right above or to the right of the version stamp. It can be anywhere from 3 to 7 digits long. Examples seen in this dataset: "265", "07058", "824533".

Do NOT confuse with:
- The handwritten "DERM Decal No." or "EPD Decal" field (those are vehicle identifiers, usually 5-6 digits)
- The "Ticket No." in the Disposal Facility section at the bottom (those are 6-digit septage receipt numbers)
- Customer/client codes elsewhere on the form

Return ONLY the white manifest number digits with no other text, prefixes, or formatting.

If you can see this is a DERM FOG eManifest form but the white manifest number is unclear/cut off/missing, return exactly: UNKNOWN
If the image is a SEPTAGE RECEIVING RECEIPT (Broward County or similar — NOT the FOG eManifest), return exactly: WRONG_DOC_SEPTAGE_RECEIPT
If the image is something else entirely (photo of a person, unrelated paper), return exactly: NOT_A_MANIFEST

Examples of valid responses: "265", "07058", "824533", "UNKNOWN", "WRONG_DOC_SEPTAGE_RECEIPT", "NOT_A_MANIFEST"`
        }
      ]
    }]
  });

  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.anthropic.com', path: '/v1/messages', method: 'POST',
      headers: {
        'x-api-key': ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      }
    }, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => {
        if (r.statusCode >= 300) return rej(new Error('Anthropic ' + r.statusCode + ': ' + d.slice(0, 400)));
        try { res(JSON.parse(d)); } catch (e) { rej(e); }
      });
    });
    req.on('error', rej);
    req.write(body);
    req.end();
  });
}

function classify(text) {
  const t = (text || '').trim();
  if (t === 'UNKNOWN' || t === '') return { proposed_number: null, confidence: 'unknown' };
  if (t === 'NOT_A_MANIFEST') return { proposed_number: null, confidence: 'unknown' };
  if (t === 'WRONG_DOC_SEPTAGE_RECEIPT') return { proposed_number: null, confidence: 'unknown' };
  // Strip everything but digits
  const digits = t.replace(/\D/g, '');
  if (digits.length === 0) return { proposed_number: null, confidence: 'unknown' };
  // White manifest numbers seen in dataset: 3-digit "265" (newer forms) up to 6-digit "824533" (older AT-typed)
  if (digits.length >= 3 && digits.length <= 6) return { proposed_number: digits, confidence: 'high' };
  if (digits.length === 7) return { proposed_number: digits, confidence: 'medium' };
  return { proposed_number: digits, confidence: 'low' };
}

function escSql(s) { return s == null ? 'NULL' : "'" + String(s).replace(/'/g, "''") + "'"; }

(async () => {
  console.log('# OCR backfill — ' + new Date().toISOString() + (DRY ? ' (DRY RUN)' : ''));

  // Pull candidates
  let where;
  if (ONE) {
    where = `id = ${parseInt(ONE, 10)}`;
  } else {
    where = `health_state = 'has_pdfs_no_number'
             AND NOT EXISTS (
               SELECT 1 FROM public.derm_manifest_number_proposals p
               WHERE p.manifest_id = manifest_health.id
                 AND p.review_status IN ('pending','approved')
             )`;
  }
  const limitClause = LIMIT ? `LIMIT ${parseInt(LIMIT, 10)}` : '';
  const sql = `
    SELECT id, manifest_photo_url, address_photo_url, client_name, service_date
    FROM derm.manifest_health
    WHERE ${where}
    ORDER BY id DESC
    ${limitClause}`;
  const candidates = await pg(sql);
  console.log('Candidates:', candidates.length);

  let proposed = 0, unknown = 0, errors = 0;
  for (const m of candidates) {
    // File routing in this dataset is INCONSISTENT — historically about 95% of
    // FOG eManifest forms live in derm_address_url (inverted from the column
    // name) while ~5% live in derm_manifest_url (correct per column name).
    // Strategy: try both URLs; first one that returns a valid number wins.
    const urls = [m.address_photo_url, m.manifest_photo_url].filter(Boolean);
    if (urls.length === 0) { console.log('  [skip] manifest', m.id, '— no image URLs at all'); continue; }
    const imgUrl = urls[0];
    if (!imgUrl) { console.log('  [skip] manifest', m.id, '— no image URL'); continue; }

    process.stdout.write(`  [${m.id}] ${m.client_name || '(no client)'} ${m.service_date} ... `);

    try {
      let text, proposed_number, confidence, usedUrl;
      for (const tryUrl of urls) {
        const { buf, contentType } = await fetchBytes(tryUrl);
        const resp = await askClaude(buf, contentType);
        text = (resp.content || []).map(b => b.text || '').join('').trim();
        const c = classify(text);
        proposed_number = c.proposed_number;
        confidence = c.confidence;
        usedUrl = tryUrl;
        // Stop iterating if we got a real number, OR if both URLs say WRONG_DOC (no point trying more)
        if (proposed_number) break;
        if (text === 'NOT_A_MANIFEST') break;
        // If WRONG_DOC, the OTHER URL is probably the right one — try it
      }

      console.log(`raw="${text}" → number=${proposed_number} conf=${confidence}${usedUrl !== urls[0] ? ' (fallback URL)' : ''}`);

      if (DRY) continue;

      await pg(`
        INSERT INTO public.derm_manifest_number_proposals
          (manifest_id, proposed_number, confidence, source, source_image_url, raw_response, review_status)
        VALUES (
          ${m.id},
          ${escSql(proposed_number)},
          ${escSql(confidence)},
          'claude_vision',
          ${escSql(usedUrl)},
          ${escSql(text)},
          'pending'
        )
        ON CONFLICT (manifest_id, proposed_number, source) DO NOTHING;
      `);

      if (proposed_number) proposed++; else unknown++;
    } catch (e) {
      console.log('ERROR: ' + e.message);
      errors++;
    }
  }

  console.log('\nSummary:');
  console.log('  Candidates:', candidates.length);
  console.log('  Proposals written:', proposed);
  console.log('  Unknown / unreadable:', unknown);
  console.log('  Errors:', errors);
  console.log(DRY ? '\n(DRY — nothing written to DB)' : '\nProposals queue: SELECT * FROM derm.manifest_number_proposals WHERE review_status=\'pending\'');
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
