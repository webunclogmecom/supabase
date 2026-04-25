// ============================================================================
// jobber_token.js — cross-session Jobber token manager
// ============================================================================
// Keeps JOBBER_ACCESS_TOKEN + JOBBER_REFRESH_TOKEN in sync across:
//   - Supabase/.env (this project)
//   - Slack/.env    (sibling Claude session)
//   - public.webhook_tokens (Supabase DB — what the Edge Function reads)
//
// Problem it solves: Jobber rotates the refresh_token on every refresh call.
// If Session A refreshes without informing Session B, B's next refresh attempt
// returns 401. Result: every session breaks independently and we're stuck
// re-running OAuth.
//
// Strategy: before giving out a token, pick the freshest across all envs,
// and if it's expired, try every known refresh_token (current + stale ones
// another session may have) to find one Jobber still honors. Whichever wins,
// write the result back to ALL envs + DB.
//
// CLI: node scripts/sync/jobber_token.js  →  prints the valid access token
// Lib: const { getValidToken } = require('./jobber_token')
// ============================================================================

const fs = require('fs');
const https = require('https');
const path = require('path');

const ENV_FILES = [
  path.resolve(__dirname, '../../.env'),
  'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Slack/.env',
];

function readEnv(filePath) {
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    const kv = {};
    for (const line of content.split(/\r?\n/)) {
      const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
      if (m) kv[m[1]] = m[2].trim();
    }
    return { filePath, content, kv };
  } catch { return null; }
}

function jwtExpMs(jwt) {
  if (!jwt) return 0;
  try { return (JSON.parse(Buffer.from(jwt.split('.')[1], 'base64').toString()).exp || 0) * 1000; }
  catch { return 0; }
}

function writeEnv(env, updates) {
  let content = env.content;
  for (const [k, v] of Object.entries(updates)) {
    const re = new RegExp(`^${k}=.*$`, 'm');
    if (re.test(content)) content = content.replace(re, `${k}=${v}`);
    else content += `\n${k}=${v}`;
  }
  fs.writeFileSync(env.filePath, content);
  env.content = content;
}

function httpsPostForm(url, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request({
      hostname: u.hostname, path: u.pathname, method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) },
    }, res => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => resolve({ status: res.statusCode, body: d }));
    });
    req.on('error', reject);
    req.setTimeout(30_000, () => req.destroy(new Error('timeout')));
    req.write(body); req.end();
  });
}

async function refreshWith(rt, clientId, clientSecret) {
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(rt)}&client_id=${encodeURIComponent(clientId)}&client_secret=${encodeURIComponent(clientSecret)}`;
  const r = await httpsPostForm('https://api.getjobber.com/api/oauth/token', body);
  if (r.status < 300) return JSON.parse(r.body);
  throw new Error(`HTTP ${r.status} ${r.body.slice(0, 200)}`);
}

async function syncDbTokens(envs, access_token, refresh_token, expires_at) {
  const first = envs[0];
  const url = first.kv.SUPABASE_URL;
  const key = first.kv.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return { skipped: 'no Supabase creds' };
  const body = JSON.stringify({ access_token, refresh_token, expires_at, updated_at: new Date().toISOString() });
  return new Promise((resolve, reject) => {
    const u = new URL(`${url}/rest/v1/webhook_tokens?source_system=eq.jobber`);
    const req = https.request({
      hostname: u.hostname, path: u.pathname + u.search, method: 'PATCH',
      headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, res => { let d=''; res.on('data', c=>d+=c); res.on('end', ()=>resolve({ status: res.statusCode })); });
    req.on('error', reject);
    req.write(body); req.end();
  });
}

async function getValidToken({ force = false, verbose = false } = {}) {
  const envs = ENV_FILES.map(readEnv).filter(Boolean);
  if (!envs.length) throw new Error('no .env files found');
  const log = (...a) => { if (verbose) console.log(...a); };

  const clientId = envs[0].kv.JOBBER_CLIENT_ID;
  const clientSecret = envs[0].kv.JOBBER_CLIENT_SECRET;
  if (!clientId || !clientSecret) throw new Error('JOBBER_CLIENT_ID / JOBBER_CLIENT_SECRET missing');

  // Pick the env with the latest-expiring access_token
  const ranked = envs.map(e => ({ env: e, exp: jwtExpMs(e.kv.JOBBER_ACCESS_TOKEN) })).sort((a, b) => b.exp - a.exp);
  const best = ranked[0];
  log(`[jobber-token] best exp: ${best.exp ? new Date(best.exp).toISOString() : '(none)'}  source: ${best.env.filePath}`);

  // Fast path: best still valid (60s buffer)
  if (!force && best.exp > Date.now() + 60_000) {
    log('[jobber-token] still valid, propagating to siblings');
    const updates = {
      JOBBER_ACCESS_TOKEN: best.env.kv.JOBBER_ACCESS_TOKEN,
      JOBBER_REFRESH_TOKEN: best.env.kv.JOBBER_REFRESH_TOKEN,
      JOBBER_TOKEN_EXPIRES_AT: new Date(best.exp).toISOString(),
    };
    for (const e of envs) {
      if (e.kv.JOBBER_ACCESS_TOKEN !== best.env.kv.JOBBER_ACCESS_TOKEN) writeEnv(e, updates);
    }
    // Also sync DB — Edge Function reads from webhook_tokens table, not .env
    await syncDbTokens(envs, best.env.kv.JOBBER_ACCESS_TOKEN, best.env.kv.JOBBER_REFRESH_TOKEN, new Date(best.exp).toISOString())
      .then(() => log('[jobber-token] DB webhook_tokens synced'))
      .catch(err => log(`[jobber-token] DB sync failed (non-fatal): ${err.message}`));
    return best.env.kv.JOBBER_ACCESS_TOKEN;
  }

  // Refresh path: try every known refresh_token in descending order of env recency
  const refreshTokens = [...new Set(ranked.map(r => r.env.kv.JOBBER_REFRESH_TOKEN).filter(Boolean))];
  log(`[jobber-token] refreshing; trying ${refreshTokens.length} refresh_token candidate(s)`);

  let lastErr;
  for (const rt of refreshTokens) {
    try {
      const result = await refreshWith(rt, clientId, clientSecret);
      const newExpMs = jwtExpMs(result.access_token);
      const newExpIso = new Date(newExpMs).toISOString();
      log(`[jobber-token] refresh OK, new exp ${newExpIso}`);
      const updates = {
        JOBBER_ACCESS_TOKEN: result.access_token,
        JOBBER_REFRESH_TOKEN: result.refresh_token || rt,
        JOBBER_TOKEN_EXPIRES_AT: newExpIso,
      };
      for (const e of envs) writeEnv(e, updates);
      await syncDbTokens(envs, result.access_token, result.refresh_token || rt, newExpIso);
      log('[jobber-token] DB webhook_tokens synced');
      return result.access_token;
    } catch (err) { lastErr = err; log(`[jobber-token] refresh_token failed: ${err.message.slice(0, 80)}`); }
  }
  throw new Error(`All refresh_tokens failed. Last: ${lastErr?.message || '?'}. Re-run scripts/jobber_auth.js.`);
}

module.exports = { getValidToken };

if (require.main === module) {
  (async () => {
    try {
      const token = await getValidToken({ verbose: true });
      const exp = jwtExpMs(token);
      console.log(`OK. Token valid until ${new Date(exp).toISOString()}`);
    } catch (e) { console.error('FAIL:', e.message); process.exit(1); }
  })();
}
