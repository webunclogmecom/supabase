// ============================================================================
// Jobber OAuth — HTTPS-redirect manual flow (no local server)
// ============================================================================
// Jobber's Developer Center now REQUIRES the redirect URI to be https://, which
// a plain local http server (scripts/jobber_auth.js) can't satisfy. This script
// does the OAuth flow WITHOUT serving anything:
//
//   1. node scripts/jobber_auth_https.js
//        -> prints the Jobber consent URL
//   2. open it in a browser logged in as the ADMIN (Yannick), click "Allow"
//   3. the browser lands on  https://localhost:3000/callback?code=XXXX
//        -> the page WON'T load (nothing is serving it) — that's EXPECTED.
//           copy the whole URL (or just the code=... value) from the address bar
//   4. node scripts/jobber_auth_https.js --code "<paste-code-or-full-url>"
//        -> exchanges it for tokens, saves them to .env
//
// The token inherits the permissions of whoever clicked "Allow" (the admin), so
// it doesn't matter who runs step 4 — Fred can exchange a code Yannick produced.
//
// Required in .env first (from the Jobber app's OAuth settings):
//   JOBBER_CLIENT_ID, JOBBER_CLIENT_SECRET
//   JOBBER_REDIRECT_URI=https://localhost:3000/callback   (must match Jobber exactly)
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });
const https = require('https');
const { URL } = require('url');
const fs = require('fs');
const path = require('path');

const CLIENT_ID = process.env.JOBBER_CLIENT_ID;
const CLIENT_SECRET = process.env.JOBBER_CLIENT_SECRET;
const REDIRECT_URI = process.env.JOBBER_REDIRECT_URI || 'https://localhost:3000/callback';
const TOKEN_URL = 'https://api.getjobber.com/api/oauth/token';

if (!CLIENT_ID || !CLIENT_SECRET) {
  console.error('ERROR: set JOBBER_CLIENT_ID and JOBBER_CLIENT_SECRET in .env first');
  process.exit(1);
}
if (!REDIRECT_URI.startsWith('https://')) {
  console.error(`ERROR: JOBBER_REDIRECT_URI must be https:// (got "${REDIRECT_URI}")`);
  process.exit(1);
}

const AUTH_URL =
  `https://api.getjobber.com/api/oauth/authorize?client_id=${CLIENT_ID}` +
  `&redirect_uri=${encodeURIComponent(REDIRECT_URI)}&response_type=code`;

// ---- POST x-www-form-urlencoded (no external deps) ----
function postForm(urlString, formData) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlString);
    const body = Object.entries(formData)
      .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
      .join('&');
    const req = https.request(
      { hostname: u.hostname, path: u.pathname + u.search, method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) } },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          try {
            const parsed = JSON.parse(data);
            if (res.statusCode >= 200 && res.statusCode < 300) resolve(parsed);
            else reject(new Error(`HTTP ${res.statusCode}: ${data}`));
          } catch (e) { reject(new Error(`Bad JSON response: ${data}`)); }
        });
      });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// ---- write token values back into .env ----
function updateEnvFile(updates) {
  const envPath = path.resolve(__dirname, '../.env');
  let content = fs.readFileSync(envPath, 'utf8');
  for (const [key, value] of Object.entries(updates)) {
    const regex = new RegExp(`^${key}=.*$`, 'm');
    if (regex.test(content)) content = content.replace(regex, `${key}=${value}`);
    else content += `\n${key}=${value}`;
  }
  fs.writeFileSync(envPath, content);
}

// ---- accept a bare code OR the full redirected URL ----
function extractCode(input) {
  if (!input) return null;
  if (input.includes('code=')) {
    try { return new URL(input).searchParams.get('code'); }
    catch { const m = input.match(/[?&]code=([^&\s]+)/); return m ? decodeURIComponent(m[1]) : null; }
  }
  return input.trim();
}

const codeArgIdx = process.argv.indexOf('--code');

if (codeArgIdx === -1) {
  // Mode 1 — print the consent URL
  console.log('\n=== Jobber authorization (Phase 2 write-back) ===\n');
  console.log('1) Open this URL in a browser logged in as the ADMIN (Yannick), then click "Allow":\n');
  console.log(AUTH_URL + '\n');
  console.log(`2) The browser will redirect to  ${REDIRECT_URI}?code=XXXX`);
  console.log('   That page will NOT load (nothing is serving it) — THAT IS EXPECTED.');
  console.log('   Copy the FULL URL (or just the code=... part) from the address bar.\n');
  console.log('3) Exchange it for tokens:\n');
  console.log('   node scripts/jobber_auth_https.js --code "<paste-code-or-full-url-here>"\n');
  process.exit(0);
}

// Mode 2 — exchange the code for tokens
const code = extractCode(process.argv[codeArgIdx + 1]);
if (!code) { console.error('ERROR: could not parse a code from the --code argument'); process.exit(1); }

(async () => {
  console.log('Exchanging authorization code for tokens...');
  const t = await postForm(TOKEN_URL, {
    client_id: CLIENT_ID, client_secret: CLIENT_SECRET,
    grant_type: 'authorization_code', code, redirect_uri: REDIRECT_URI,
  });
  const expiresAt = t.expires_in
    ? new Date(Date.now() + t.expires_in * 1000).toISOString()
    : new Date(Date.now() + 3600 * 1000).toISOString();
  updateEnvFile({
    JOBBER_ACCESS_TOKEN: t.access_token,
    JOBBER_REFRESH_TOKEN: t.refresh_token,
    JOBBER_TOKEN_EXPIRES_AT: expiresAt,
  });
  console.log('\n✓ SUCCESS — tokens saved to .env');
  console.log('  Access token expires:', expiresAt);
  console.log('  Refresh token: stored (the long-lived one we need).');
  console.log('\nNow tell Claude it is done — it will move these into public.webhook_tokens.');
})().catch((e) => {
  console.error('\nFATAL:', e.message);
  console.error('(If it says invalid_grant: the code is single-use + expires fast — re-run Mode 1 for a fresh one.)');
  process.exit(1);
});
