// ============================================================================
// cron_generate_fog_manifests.js
// ============================================================================
// Generates the per-client FOG Manifest (a DERM Address rendered with ONLY the
// manifest row's own client facility) for any derm_manifests row missing
// fog_manifest_url, by calling the generate-fog-manifest Edge Function (which
// proxies to the Railway pdf-service). Idempotent — re-runnable, only touches
// rows that still lack a FOG Manifest. Covers NEW manifests regardless of how
// their address doc arrived (scanned via Airtable or generated).
//
//   node scripts/sync/cron_generate_fog_manifests.js
//   FOG_LIMIT=50 node ...   # cap rows processed per run
// ============================================================================
const https = require('https');
const fs = require('fs');
const path = require('path');

function fromEnvFile(k) {
  try {
    const p = path.resolve(__dirname, '../../.env');
    const l = fs.readFileSync(p, 'utf8').split(/\r?\n/).find((x) => x.startsWith(k + '='));
    return l ? l.slice(k.length + 1).trim() : null;
  } catch {
    return null;
  }
}
const SUPA_URL = process.env.SUPABASE_URL || fromEnvFile('SUPABASE_URL');
const SUPA_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || fromEnvFile('SUPABASE_SERVICE_ROLE_KEY');
if (!SUPA_URL || !SUPA_KEY) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');
const HOST = SUPA_URL.replace(/^https?:\/\//, '').replace(/\/$/, '');

function call(method, pathn, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : null;
    const r = https.request(
      {
        hostname: HOST,
        path: pathn,
        method,
        headers: {
          Authorization: 'Bearer ' + SUPA_KEY,
          apikey: SUPA_KEY,
          'Content-Type': 'application/json',
          ...(data ? { 'Content-Length': Buffer.byteLength(data) } : {}),
        },
      },
      (resp) => {
        let d = '';
        resp.on('data', (c) => (d += c));
        resp.on('end', () => resolve({ status: resp.statusCode, body: d }));
      }
    );
    r.on('error', reject);
    if (data) r.write(data);
    r.end();
  });
}

(async () => {
  const limit = parseInt(process.env.FOG_LIMIT || '500', 10);
  const got = await call('GET', `/rest/v1/derm_manifests?select=id&fog_manifest_url=is.null&order=id&limit=${limit}`);
  if (got.status >= 300) throw new Error(`list failed: ${got.status} ${got.body.slice(0, 200)}`);
  const rows = JSON.parse(got.body);
  console.log(`[fog-cron] ${rows.length} manifest(s) missing fog_manifest_url`);
  let ok = 0;
  let fail = 0;
  for (const row of rows) {
    const r = await call('POST', '/functions/v1/generate-fog-manifest', { manifest_id: row.id });
    if (r.status >= 200 && r.status < 300) {
      ok++;
    } else {
      fail++;
      console.log(`  FAIL ${row.id}: ${r.status} ${r.body.slice(0, 150)}`);
    }
  }
  console.log(`[fog-cron] done: ok=${ok} fail=${fail}`);
  if (fail > 0) process.exitCode = 1;
})();
