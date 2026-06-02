// cleanup_derm_smoke_test.js
//
// Removes the test artifacts created by smoke_test_derm_tracker_upload.js.
// Uses service_role (bypasses RLS — anon doesn't have DELETE on derm_manifests).
// Per Rule 6 (never hard-delete business data) this is allowed because:
//   - Test data is clearly marked with TEST-AUTOMATED-<timestamp>
//   - The script verifies the marker matches before deleting
//   - Cleanup of test artifacts is not "business data"

const https = require('https');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env') });

const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PAT = process.env.SUPABASE_PAT;
const ref = SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];
const host = SUPABASE_URL.replace('https://', '');
const MARKER_FILE = path.resolve(__dirname, '../../.derm_test_marker.json');

function pg(s) {
  return new Promise((r, j) => {
    const b = JSON.stringify({ query: s });
    const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) } }, rs => { let d=''; rs.on('data',c=>d+=c); rs.on('end',()=>{ if(rs.statusCode>=300) return j(new Error(rs.statusCode+': '+d)); r(JSON.parse(d)); }); });
    req.on('error', j); req.write(b); req.end();
  });
}

function storageDelete(svcKey, p) {
  return new Promise((res, rej) => {
    const req = https.request({ hostname: host, path: '/storage/v1/object/GT%20-%20Visits%20Images/' + p, method: 'DELETE', headers: { Authorization: 'Bearer ' + svcKey } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>res({s:r.statusCode,b:d})); });
    req.on('error', rej); req.end();
  });
}

(async () => {
  if (!fs.existsSync(MARKER_FILE)) {
    console.error('No marker file at ' + MARKER_FILE + '. Nothing to clean up.');
    process.exit(1);
  }
  const marker = JSON.parse(fs.readFileSync(MARKER_FILE, 'utf-8'));
  console.log('Marker:', marker);

  // Verify the row is still the test row before deleting
  const rows = await pg(`SELECT id, white_manifest_number, derm_manifest_url FROM public.derm_manifests WHERE id = ${marker.manifestId}`);
  if (rows.length === 0) {
    console.log('Row already gone. Cleaning marker file only.');
  } else if (rows[0].white_manifest_number !== marker.testMarker) {
    console.error('SAFETY HALT: row id ' + marker.manifestId + ' has white_manifest_number "' + rows[0].white_manifest_number + '" (expected "' + marker.testMarker + '"). Refusing to delete.');
    process.exit(1);
  } else {
    console.log('Row matches marker. Safe to clean.');

    // 1) Delete any manifest_visits linked to this manifest
    const linked = await pg(`SELECT visit_id FROM public.manifest_visits WHERE manifest_id = ${marker.manifestId}`);
    if (linked.length > 0) {
      console.log('Found ' + linked.length + ' linked visits; deleting...');
      await pg(`DELETE FROM public.manifest_visits WHERE manifest_id = ${marker.manifestId}`);
    }

    // 2) Delete the manifest row
    console.log('Deleting derm_manifests row id=' + marker.manifestId + '...');
    await pg(`DELETE FROM public.derm_manifests WHERE id = ${marker.manifestId} AND white_manifest_number = '${marker.testMarker}'`);
    console.log('  ✓ row deleted');
  }

  // 3) Delete storage object
  console.log('Deleting Storage object ' + marker.storagePath + '...');
  const sd = await storageDelete(SVC, marker.storagePath);
  console.log('  status:', sd.s, '/ body:', sd.b.slice(0, 200));

  // 4) Remove marker file
  fs.unlinkSync(MARKER_FILE);
  console.log('  ✓ marker file removed');

  // 5) Verify cleanup
  const after = await pg(`SELECT COUNT(*)::int AS n FROM public.derm_manifests WHERE white_manifest_number LIKE 'TEST-AUTOMATED-%'`);
  console.log('\nPost-cleanup TEST-AUTOMATED-% manifests remaining:', after[0].n);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
