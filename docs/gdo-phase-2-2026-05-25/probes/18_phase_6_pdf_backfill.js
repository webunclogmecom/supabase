// Phase 6: backfill gdos.permit_document_path from bot results.
//
// 1. Create private Supabase Storage bucket 'gdo-permits' if missing.
// 2. Collect gdo_number -> pdf_url from all bot results JSONs.
// 3. For each ACTIVE gdo with a bot-supplied pdf_url:
//    - download from DERM
//    - upload to gdo-permits/gdo/<gdo_number>.pdf
//    - UPDATE public.gdos SET permit_document_path = 'gdo/<gdo_number>.pdf'
// 4. Report counts.
//
// Idempotent: skip uploads where permit_document_path already set + bucket
// already has the object.

const https = require('https');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });

const PAT = process.env.SUPABASE_PAT;
const SUPABASE_URL = process.env.SUPABASE_URL || 'https://wbasvhvvismukaqdnouk.supabase.co';
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = 'wbasvhvvismukaqdnouk';
const BUCKET = 'gdo-permits';

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${PROJECT}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => {
      let d = '';
      r.on('data', c => (d += c));
      r.on('end', () => { try { res({ status: r.statusCode, body: JSON.parse(d) }); } catch (_) { res({ status: r.statusCode, body: d }); } });
    });
    req.on('error', rej);
    req.write(body);
    req.end();
  });
}

function httpFetch(url) {
  return new Promise((res, rej) => {
    const u = new URL(url);
    const lib = u.protocol === 'https:' ? require('https') : require('http');
    lib.get(url, r => {
      // follow redirects
      if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) {
        res(httpFetch(r.headers.location));
        return;
      }
      const chunks = [];
      r.on('data', c => chunks.push(c));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(chunks), headers: r.headers }));
    }).on('error', rej);
  });
}

function uploadToBucket(objectPath, body, contentType) {
  return new Promise((res, rej) => {
    const u = new URL(`${SUPABASE_URL}/storage/v1/object/${BUCKET}/${objectPath}`);
    const req = https.request({
      hostname: u.hostname,
      path: u.pathname + u.search,
      method: 'POST',
      headers: {
        Authorization: `Bearer ${SERVICE_KEY}`,
        'Content-Type': contentType,
        'Content-Length': body.length,
        'x-upsert': 'true',
      },
    }, r => {
      let d = '';
      r.on('data', c => (d += c));
      r.on('end', () => res({ status: r.statusCode, body: d }));
    });
    req.on('error', rej);
    req.write(body);
    req.end();
  });
}

async function ensureBucket() {
  // List buckets
  const list = await new Promise((res, rej) => {
    const u = new URL(`${SUPABASE_URL}/storage/v1/bucket`);
    https.get({ hostname: u.hostname, path: u.pathname, headers: { Authorization: `Bearer ${SERVICE_KEY}` } }, r => {
      let d = '';
      r.on('data', c => (d += c));
      r.on('end', () => { try { res(JSON.parse(d)); } catch (_) { res(d); } });
    }).on('error', rej);
  });
  if (Array.isArray(list) && list.find(b => b.name === BUCKET)) {
    console.log(`Bucket '${BUCKET}' already exists.`);
    return;
  }
  // Create
  const created = await new Promise((res, rej) => {
    const body = JSON.stringify({ id: BUCKET, name: BUCKET, public: false });
    const u = new URL(`${SUPABASE_URL}/storage/v1/bucket`);
    const req = https.request({
      hostname: u.hostname,
      path: u.pathname,
      method: 'POST',
      headers: {
        Authorization: `Bearer ${SERVICE_KEY}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    }, r => {
      let d = '';
      r.on('data', c => (d += c));
      r.on('end', () => res({ status: r.statusCode, body: d }));
    });
    req.on('error', rej);
    req.write(body);
    req.end();
  });
  console.log(`Bucket create: HTTP ${created.status}: ${created.body.slice(0, 200)}`);
}

function loadGdoUrlMap() {
  const map = new Map();  // gdo_number -> { pdf_url, source }
  for (const fn of ['09_phase_2b_results.json', '12_phase_2c_results.json']) {
    const p = path.join(__dirname, fn);
    if (!fs.existsSync(p)) continue;
    const data = JSON.parse(fs.readFileSync(p, 'utf8'));
    for (const r of data.results) {
      const bot = r.bot || {};
      // Both bot's returned gdo_number (for renames) and our_gdo (for matches)
      const candidates = [bot.gdo_number, r.gdo_number].filter(Boolean);
      for (const g of candidates) {
        if (bot.pdf_url && !map.has(g)) {
          map.set(g, { pdf_url: bot.pdf_url, source: fn });
        }
      }
    }
  }
  return map;
}

(async () => {
  if (!PAT || !SERVICE_KEY) { console.error('Need SUPABASE_PAT + SUPABASE_SERVICE_ROLE_KEY'); process.exit(1); }
  await ensureBucket();

  const urlMap = loadGdoUrlMap();
  console.log(`\nLoaded ${urlMap.size} gdo_number -> pdf_url entries from bot results JSONs.`);

  // Get all ACTIVE gdos
  const activeGdos = (await pg(`
    SELECT id, gdo_number, permit_document_path
    FROM public.gdos
    WHERE status = 'ACTIVE'
    ORDER BY gdo_number;
  `)).body;
  console.log(`Found ${activeGdos.length} ACTIVE gdos.`);

  let uploaded = 0, skipped_no_url = 0, skipped_already = 0, errors = 0;
  for (const g of activeGdos) {
    const objectPath = `gdo/${g.gdo_number}.pdf`;
    // If permit_document_path is already set to our convention, skip
    if (g.permit_document_path === objectPath) { skipped_already++; continue; }

    const entry = urlMap.get(g.gdo_number);
    if (!entry?.pdf_url) { skipped_no_url++; continue; }

    process.stdout.write(`${g.gdo_number} -> downloading + uploading... `);
    try {
      const fetched = await httpFetch(entry.pdf_url);
      if (fetched.status !== 200) {
        console.log(`DL HTTP ${fetched.status}`);
        errors++;
        continue;
      }
      const contentType = entry.pdf_url.toLowerCase().endsWith('.tif')
        ? 'image/tiff'
        : 'application/pdf';
      const ext = contentType === 'image/tiff' ? '.tif' : '.pdf';
      const finalPath = `gdo/${g.gdo_number}${ext}`;
      const up = await uploadToBucket(finalPath, fetched.body, contentType);
      if (up.status !== 200 && up.status !== 201) {
        console.log(`UP HTTP ${up.status}: ${up.body.slice(0, 100)}`);
        errors++;
        continue;
      }
      // Update gdos.permit_document_path
      await pg(`UPDATE public.gdos SET permit_document_path = '${finalPath}', notes = COALESCE(notes || E'\\n', '') || '[2026-05-25 Phase 6] permit_document_path backfilled from DERM bot pdf_url; uploaded to Supabase Storage bucket "${BUCKET}".' WHERE id = ${g.id} AND (permit_document_path IS NULL OR permit_document_path <> '${finalPath}');`);
      uploaded++;
      console.log(`OK -> ${finalPath} (${fetched.body.length} bytes)`);
    } catch (e) {
      console.log(`ERR ${String(e).slice(0, 100)}`);
      errors++;
    }
  }

  console.log(`\n=== Phase 6 backfill summary ===`);
  console.log(`Uploaded:           ${uploaded}`);
  console.log(`Skipped (no URL):   ${skipped_no_url}`);
  console.log(`Skipped (already):  ${skipped_already}`);
  console.log(`Errors:             ${errors}`);
  console.log(`Total ACTIVE gdos:  ${activeGdos.length}`);

  // Final check
  const after = (await pg(`
    SELECT
      COUNT(*) FILTER (WHERE status='ACTIVE')::int AS active,
      COUNT(*) FILTER (WHERE status='ACTIVE' AND permit_document_path IS NOT NULL)::int AS with_pdf
    FROM public.gdos;
  `)).body;
  console.log(`\nDB final: ${JSON.stringify(after)}`);
})().catch(e => { console.error('FATAL', e); process.exit(1); });
