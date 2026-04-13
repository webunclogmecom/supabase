// One-shot: set GitHub Actions secrets on webunclogmecom/supabase from local .env
const fs = require('fs');
const path = require('path');
const https = require('https');
const sodium = require('libsodium-wrappers');

const REPO = 'webunclogmecom/supabase';
const CLAUDE_ENV = path.resolve('C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/.env');
const LOCAL_ENV  = path.resolve(__dirname, '../../.env');

function parseEnv(p) {
  const o = {};
  for (const line of fs.readFileSync(p, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
    if (m) o[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
  return o;
}

const claudeEnv = parseEnv(CLAUDE_ENV);
const localEnv = parseEnv(LOCAL_ENV);
const GH = claudeEnv.GITHUB_PAT_TOKEN;
if (!GH) { console.error('GITHUB_PAT_TOKEN missing'); process.exit(1); }

const SECRETS = [
  'SUPABASE_PAT',
  'SUPABASE_URL',
  'SUPABASE_SERVICE_ROLE_KEY',
  'JOBBER_CLIENT_ID',
  'JOBBER_CLIENT_SECRET',
  'JOBBER_ACCESS_TOKEN',
  'JOBBER_REFRESH_TOKEN',
  'SAMSARA_API_TOKEN',
  'AIRTABLE_API_KEY',
  'AIRTABLE_BASE_ID',
  'FILLOUT_API_KEY',
];

function ghApi(method, apiPath, body) {
  return new Promise((resolve, reject) => {
    const bodyStr = body ? JSON.stringify(body) : '';
    const req = https.request({
      hostname: 'api.github.com',
      path: apiPath,
      method,
      headers: {
        Authorization: `Bearer ${GH}`,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'unclogme-sync',
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(bodyStr),
      },
    }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    if (bodyStr) req.write(bodyStr);
    req.end();
  });
}

(async () => {
  await sodium.ready;
  const pkRes = await ghApi('GET', `/repos/${REPO}/actions/secrets/public-key`);
  if (pkRes.status !== 200) { console.error('pubkey fetch failed:', pkRes.body); process.exit(1); }
  const { key, key_id } = JSON.parse(pkRes.body);
  const pubKey = sodium.from_base64(key, sodium.base64_variants.ORIGINAL);

  for (const name of SECRETS) {
    const val = localEnv[name] || claudeEnv[name];
    if (!val) { console.log(`SKIP ${name} (not in .env)`); continue; }
    const enc = sodium.crypto_box_seal(sodium.from_string(val), pubKey);
    const encoded = sodium.to_base64(enc, sodium.base64_variants.ORIGINAL);
    const r = await ghApi('PUT', `/repos/${REPO}/actions/secrets/${name}`, {
      encrypted_value: encoded,
      key_id,
    });
    console.log(`${r.status === 201 || r.status === 204 ? 'OK  ' : 'FAIL'} ${name} (HTTP ${r.status})`);
    if (r.status >= 300) console.log('   ', r.body.slice(0, 200));
  }
})();
