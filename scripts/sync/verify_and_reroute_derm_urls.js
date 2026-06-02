// ============================================================================
// verify_and_reroute_derm_urls.js — re-route derm_manifests URLs so that
// canonical derm_manifest_url ALWAYS points at the FOG eManifest form
// (the file with the printed white manifest number).
//
// Self-verifying: only swaps when OCR'd number matches the stored
// white_manifest_number. Won't act on shaky reads.
//
// Algorithm per manifest (where white_manifest_number IS NOT NULL):
//   1. OCR derm_manifest_url
//      → if extracted == stored white # → correctly routed, no swap
//   2. Else OCR derm_address_url
//      → if extracted == stored white # → SWAP the two URL columns
//   3. Else → flag as needs_review (neither URL agrees with stored number)
//
// CLI:
//   node scripts/sync/verify_and_reroute_derm_urls.js                       # dry-run, all
//   node scripts/sync/verify_and_reroute_derm_urls.js --limit=20            # dry-run, 20
//   node scripts/sync/verify_and_reroute_derm_urls.js --limit=20 --execute  # do 20
//   node scripts/sync/verify_and_reroute_derm_urls.js --execute             # full real run
//
// Audit: every UPDATE on derm_manifests is captured by audit_derm_manifests.
// Idempotent: already-correct rows are recognized on first OCR and skipped.
// ============================================================================

const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

if (!ANTHROPIC_API_KEY) throw new Error('ANTHROPIC_API_KEY required in .env');

const LIMIT = (process.argv.find(a => a.startsWith('--limit=')) || '').split('=')[1];
const EXECUTE = process.argv.includes('--execute');
const ONE = (process.argv.find(a => a.startsWith('--manifest-id=')) || '').split('=')[1];

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
      if (r.statusCode !== 200) return rej(new Error('HTTP ' + r.statusCode));
      const chunks = []; r.on('data', c => chunks.push(c));
      r.on('end', () => res({ buf: Buffer.concat(chunks), contentType: r.headers['content-type'] || 'image/jpeg' }));
    }).on('error', rej);
  });
}

async function askClaude(imageBuf, contentType) {
  const mediaType = contentType.split(';')[0].trim();
  const body = JSON.stringify({
    model: 'claude-opus-4-7',
    max_tokens: 100,
    messages: [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: mediaType, data: imageBuf.toString('base64') } },
        { type: 'text', text:
`Look at this image. Is it a Miami-Dade DERM "Fats, Oils and Grease (FOG) Single Load Liquid Waste Transporter eManifest" form? The form has the header text "Fats, Oils and Grease (FOG)" and "Single Load Liquid Waste Transporter eManifest", with a preprinted serial number (white manifest number) in the top-right corner — 3 to 7 digits.

If YES — return ONLY the digits of the white manifest number (top-right corner serial, NOT handwritten DERM Decal in top-left, NOT the bottom Ticket Number). E.g. "265", "166", "07058".

If the image is a SEPTAGE RECEIVING RECEIPT (Broward / WWTP receipt) — return exactly: SEPTAGE_RECEIPT

If the image is something else entirely — return exactly: OTHER

No other text.`
        }
      ]
    }]
  });
  return new Promise((res, rej) => {
    const req = https.request({ hostname: 'api.anthropic.com', path: '/v1/messages', method: 'POST', headers: { 'x-api-key': ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ if(r.statusCode>=300) return rej(new Error('Anthropic ' + r.statusCode + ': ' + d.slice(0, 400))); try { res(JSON.parse(d)); } catch (e) { rej(e); } }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

function normalize(s) { return (s == null) ? '' : String(s).replace(/^0+/, '').trim(); }  // strip leading zeros for comparison

async function ocrUrl(url) {
  try {
    const { buf, contentType } = await fetchBytes(url);
    const resp = await askClaude(buf, contentType);
    return (resp.content || []).map(b => b.text || '').join('').trim();
  } catch (e) {
    return 'ERROR:' + e.message.slice(0, 80);
  }
}

function esc(s) { return s == null ? 'NULL' : "'" + String(s).replace(/'/g, "''") + "'"; }

(async () => {
  console.log(`# verify_and_reroute_derm_urls — ${new Date().toISOString()} ${EXECUTE ? 'EXECUTE' : '(DRY RUN)'}`);

  let where = `white_manifest_number IS NOT NULL AND (derm_manifest_url IS NOT NULL OR derm_address_url IS NOT NULL)`;
  if (ONE) where = `id = ${parseInt(ONE, 10)}`;
  const limitClause = LIMIT ? `LIMIT ${parseInt(LIMIT, 10)}` : '';

  // Order by id DESC so test-first picks newer manifests (more typical of current dataset shape)
  const manifests = await pg(`
    SELECT id, white_manifest_number, derm_manifest_url, derm_address_url
    FROM public.derm_manifests
    WHERE ${where}
    ORDER BY id DESC
    ${limitClause}`);

  console.log('Candidates:', manifests.length);

  const counts = { correctly_routed: 0, swapped: 0, needs_review: 0, errors: 0 };
  const swapDetails = [];
  const reviewDetails = [];

  for (const m of manifests) {
    const stored = normalize(m.white_manifest_number);
    let decision = 'needs_review';
    let reason = '';
    let manifestOcr = null, addressOcr = null;

    // 1. OCR manifest_url
    if (m.derm_manifest_url) {
      manifestOcr = await ocrUrl(m.derm_manifest_url);
      if (normalize(manifestOcr) === stored) {
        decision = 'correctly_routed';
        reason = `manifest_url matches #${stored}`;
      }
    }

    // 2. If not matched yet, try address_url
    if (decision === 'needs_review' && m.derm_address_url) {
      addressOcr = await ocrUrl(m.derm_address_url);
      if (normalize(addressOcr) === stored) {
        decision = 'swapped';
        reason = `address_url matches #${stored}, swap`;
      }
    }

    if (decision === 'needs_review') {
      reason = `manifest_url returned "${manifestOcr || '—'}", address_url returned "${addressOcr || '—'}", stored=${stored}`;
    }

    counts[decision]++;
    console.log(`  [${m.id}] white#=${m.white_manifest_number} → ${decision}: ${reason}`);

    if (decision === 'swapped') {
      swapDetails.push({ id: m.id, stored: m.white_manifest_number, manifest_ocr: manifestOcr, address_ocr: addressOcr });
      if (EXECUTE) {
        try {
          await pg(`
            UPDATE public.derm_manifests
               SET derm_manifest_url = ${esc(m.derm_address_url)},
                   derm_address_url  = ${esc(m.derm_manifest_url)}
             WHERE id = ${m.id}
               AND derm_manifest_url = ${esc(m.derm_manifest_url)}
               AND derm_address_url IS NOT DISTINCT FROM ${esc(m.derm_address_url)};
          `);
        } catch (e) {
          console.error(`    ! swap failed: ${e.message.slice(0, 200)}`);
          counts.errors++;
        }
      }
    }
    if (decision === 'needs_review') {
      reviewDetails.push({ id: m.id, stored: m.white_manifest_number, manifest_ocr: manifestOcr, address_ocr: addressOcr });
    }
  }

  console.log('\n=== Summary ===');
  console.log(`  correctly_routed: ${counts.correctly_routed}`);
  console.log(`  swapped:          ${counts.swapped}${EXECUTE ? '' : ' (dry-run; would swap)'}`);
  console.log(`  needs_review:     ${counts.needs_review}`);
  console.log(`  errors:           ${counts.errors}`);

  if (reviewDetails.length > 0 && reviewDetails.length <= 20) {
    console.log('\nNeeds-review details:');
    for (const r of reviewDetails) console.log('  ', r);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
