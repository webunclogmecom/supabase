// smoke_test_derm_tracker_upload.js
//
// End-to-end test: simulates the DERM Tracker app's Bulk Upload flow
// against Prod, using the SAME anon key + endpoints the app uses.
//
// Steps:
//   1. INSERT a manifest row via anon (POST /rest/v1/derm_manifests)
//   2. Upload image to Storage at derm/{id}/manifest.png via anon
//   3. UPDATE the manifest with the URL via anon (PATCH)
//   4. Verify public URL is fetchable
//   5. Read back via derm.manifests view (the read path Lovable app uses)
//
// Test data is clearly marked with TEST-AUTOMATED-<timestamp> manifest number
// for easy identification + cleanup.
//
// Companion cleanup script: cleanup_derm_smoke_test.js
// Test marker is written to /tmp/derm_test_marker.json for the cleanup step.

const https = require('https');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env') });

const SUPABASE_URL = process.env.SUPABASE_URL;
const PAT = process.env.SUPABASE_PAT;
const ref = SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];
const host = SUPABASE_URL.replace('https://', '');

const TEST_FILE = process.argv[2] || 'C:\\Users\\FRED\\Downloads\\5315-apple_102578.png';
const MARKER_FILE = path.resolve(__dirname, '../../.derm_test_marker.json');

function api(method, p) {
  return new Promise((res, rej) => {
    const req = https.request({ hostname: 'api.supabase.com', path: p, method, headers: { Authorization: 'Bearer ' + PAT } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>res({s:r.statusCode,b:d})); });
    req.on('error', rej); req.end();
  });
}

function rest(method, urlPath, anon, body, contentType) {
  return new Promise((res, rej) => {
    const headers = { apikey: anon, Authorization: 'Bearer ' + anon };
    if (body) {
      headers['Content-Type'] = contentType || 'application/json';
      headers['Content-Length'] = Buffer.isBuffer(body) ? body.length : Buffer.byteLength(body);
      headers['Prefer'] = 'return=representation';
    }
    const req = https.request({ hostname: host, path: urlPath, method, headers }, r => {
      let chunks = [];
      r.on('data', c => chunks.push(c));
      r.on('end', () => res({ s: r.statusCode, b: Buffer.concat(chunks).toString(), headers: r.headers }));
    });
    req.on('error', rej);
    if (body) req.write(body);
    req.end();
  });
}

(async () => {
  // Anon key
  const keys = JSON.parse((await api('GET', '/v1/projects/' + ref + '/api-keys')).b);
  const anon = keys.find(k => k.name === 'anon').api_key;
  console.log('Got anon key:', anon.slice(0, 8) + '...' + anon.slice(-4));

  const fileBuf = fs.readFileSync(TEST_FILE);
  console.log('Test file:', TEST_FILE, '(' + fileBuf.length + ' bytes)');

  const testMarker = 'TEST-AUTOMATED-' + Date.now();
  console.log('Test marker:', testMarker);

  // === Step 1: INSERT manifest via anon ===
  const insertBody = JSON.stringify({
    white_manifest_number: testMarker,
    service_date: '2026-05-18',
    dump_ticket_date: '2026-05-18',
    disposal_facility_id: 1,
  });
  console.log('\n[1] INSERT public.derm_manifests as anon...');
  const ins = await rest('POST', '/rest/v1/derm_manifests', anon, insertBody);
  console.log('  status:', ins.s);
  if (ins.s >= 300) { console.error('  FAIL:', ins.b); process.exit(1); }
  const newRow = JSON.parse(ins.b)[0];
  console.log('  ✓ created manifest id', newRow.id, '/ number', newRow.white_manifest_number);

  // === Step 2: Storage upload ===
  const storagePath = 'derm/' + newRow.id + '/manifest.png';
  console.log('\n[2] POST /storage/v1/object/GT - Visits Images/' + storagePath + ' as anon...');
  const up = await rest('POST', '/storage/v1/object/GT%20-%20Visits%20Images/' + storagePath, anon, fileBuf, 'image/png');
  console.log('  status:', up.s, '/ body:', up.b.slice(0, 200));
  if (up.s >= 300) {
    console.error('  Storage upload FAILED');
  } else {
    console.log('  ✓ uploaded');
  }

  const publicUrl = SUPABASE_URL + '/storage/v1/object/public/GT%20-%20Visits%20Images/' + storagePath;
  console.log('  public URL:', publicUrl);

  // === Step 3: PATCH manifest with URL ===
  console.log('\n[3] PATCH derm_manifests.derm_manifest_url as anon...');
  const upd = await rest('PATCH', '/rest/v1/derm_manifests?id=eq.' + newRow.id, anon,
    JSON.stringify({ derm_manifest_url: publicUrl }));
  console.log('  status:', upd.s);
  if (upd.s < 300) console.log('  ✓ url written');

  // === Step 4: Verify URL fetchable ===
  console.log('\n[4] GET ' + publicUrl);
  const fetched = await new Promise((res, rej) => {
    https.get(publicUrl, r => {
      let chunks = []; r.on('data', c => chunks.push(c));
      r.on('end', () => res({ s: r.statusCode, ct: r.headers['content-type'], len: r.headers['content-length'], bytes: Buffer.concat(chunks).length }));
    }).on('error', rej);
  });
  console.log('  status:', fetched.s, '/ content-type:', fetched.ct, '/ bytes:', fetched.bytes);
  if (fetched.s === 200 && fetched.bytes === fileBuf.length) console.log('  ✓ public URL serves the exact bytes we uploaded');

  // === Step 5: Read back via derm.manifests view (Lovable read path) ===
  console.log('\n[5] GET derm.manifests view as anon (Lovable read path)...');
  const readBack = await rest('GET',
    '/rest/v1/manifests?id=eq.' + newRow.id + '&select=id,manifest_number,manifest_photo_url,service_date,dump_location',
    anon);
  // Need Accept-Profile: derm header for view reads
  const readBack2 = await new Promise((res, rej) => {
    https.request({
      hostname: host,
      path: '/rest/v1/manifests?id=eq.' + newRow.id + '&select=id,manifest_number,manifest_photo_url,service_date,dump_location',
      method: 'GET',
      headers: { apikey: anon, Authorization: 'Bearer ' + anon, 'Accept-Profile': 'derm' }
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>res({s:r.statusCode,b:d})); }).on('error', rej).end();
  });
  console.log('  status:', readBack2.s, '/ row:', readBack2.b);
  const rows = JSON.parse(readBack2.b);
  if (rows.length === 1 && rows[0].manifest_photo_url === publicUrl) {
    console.log('  ✓ view returns the correct row with the URL we just set');
  }

  // Write test marker for cleanup
  fs.writeFileSync(MARKER_FILE, JSON.stringify({ manifestId: newRow.id, testMarker, storagePath, publicUrl, fileSize: fileBuf.length, createdAt: new Date().toISOString() }, null, 2));
  console.log('\nMarker written:', MARKER_FILE);
  console.log('Run cleanup_derm_smoke_test.js to remove.');
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
