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

// The OAuth app a Jobber access_token belongs to. Used to refuse cross-app
// contamination: this helper manages the READ app ('jobber' row) only, and a
// token whose app_id != the row's client_id must never be picked or stored.
function jwtAppId(jwt) {
  if (!jwt) return null;
  try { return JSON.parse(Buffer.from(jwt.split('.')[1], 'base64').toString()).app_id || null; }
  catch { return null; }
}

function writeEnv(env, updates) {
  // GitHub Actions runner has no .env file — the env is synthesized from
  // process.env. There's nothing to write to, so just no-op.
  if (env.synthetic) return;
  let content = env.content;
  for (const [k, v] of Object.entries(updates)) {
    const re = new RegExp(`^${k}=.*$`, 'm');
    if (re.test(content)) content = content.replace(re, `${k}=${v}`);
    else content += `\n${k}=${v}`;
  }
  fs.writeFileSync(env.filePath, content);
  env.content = content;
}

// Synthesize a virtual env from process.env. The only hard requirement is
// SUPABASE_URL + SERVICE_ROLE_KEY (so we can read webhook_tokens). CLIENT_ID
// / CLIENT_SECRET / REFRESH_TOKEN are only needed if we have to refresh —
// callers like jobber_notes_photos.js pass JOBBER_ACCESS_TOKEN only and rely
// on the DB row for freshness.
function envFromProcess() {
  if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) return null;
  return {
    filePath: '<process.env>',
    content: '',
    synthetic: true,
    kv: {
      JOBBER_CLIENT_ID:      process.env.JOBBER_CLIENT_ID || '',
      JOBBER_CLIENT_SECRET:  process.env.JOBBER_CLIENT_SECRET || '',
      JOBBER_ACCESS_TOKEN:   process.env.JOBBER_ACCESS_TOKEN || '',
      JOBBER_REFRESH_TOKEN:  process.env.JOBBER_REFRESH_TOKEN || '',
      JOBBER_TOKEN_EXPIRES_AT: process.env.JOBBER_TOKEN_EXPIRES_AT || '',
      SUPABASE_URL:          process.env.SUPABASE_URL,
      SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
    },
  };
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

// Read the latest tokens from public.webhook_tokens. The DB row is the single
// source of truth that all surfaces (Edge Functions, crons, local sessions)
// converge on after every successful refresh — so it's the freshest signal
// when stale .env / process.env tokens would otherwise trigger a doomed refresh
// (e.g. when GitHub Actions secrets carry an old CLIENT_ID/SECRET).
async function readDbTokens(envs) {
  const first = envs[0];
  const url = first.kv.SUPABASE_URL;
  const key = first.kv.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return null;
  return new Promise((resolve) => {
    const u = new URL(`${url}/rest/v1/webhook_tokens?source_system=eq.jobber&select=access_token,refresh_token,expires_at,client_id,client_secret`);
    const req = https.request({
      hostname: u.hostname, path: u.pathname + u.search, method: 'GET',
      headers: { apikey: key, Authorization: `Bearer ${key}` },
    }, res => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => {
        if (res.statusCode >= 300) return resolve(null);
        try {
          const rows = JSON.parse(d);
          if (!rows.length) return resolve(null);
          const row = rows[0];
          if (!row.access_token) return resolve(null);
          resolve(row);
        } catch { resolve(null); }
      });
    });
    req.on('error', () => resolve(null));
    req.setTimeout(15_000, () => { req.destroy(); resolve(null); });
    req.end();
  });
}

async function getValidToken({ force = false, verbose = false } = {}) {
  let envs = ENV_FILES.map(readEnv).filter(Boolean);
  if (!envs.length) {
    // GitHub Actions / containers without .env files: fall back to process.env.
    const synth = envFromProcess();
    if (!synth) throw new Error('no .env files found and process.env missing JOBBER_CLIENT_ID/CLIENT_SECRET/REFRESH_TOKEN');
    envs = [synth];
  }
  const log = (...a) => { if (verbose) console.log(...a); };

  // The webhook_tokens 'jobber' row is the canonical READ app. Its client_id +
  // client_secret define the ONLY app whose tokens are valid here — the guard
  // against cross-app contamination (a sibling .env holding the WRITE app's
  // token must never be picked or written into the read row). DB row = identity
  // source of truth; .env is only a fallback when there is no row.
  const dbRow = await readDbTokens(envs);
  const clientId = (dbRow && dbRow.client_id) || envs[0].kv.JOBBER_CLIENT_ID;
  const clientSecret = (dbRow && dbRow.client_secret) || envs[0].kv.JOBBER_CLIENT_SECRET;
  if (dbRow) {
    envs.push({
      filePath: '<webhook_tokens>',
      content: '',
      synthetic: true,
      kv: {
        JOBBER_CLIENT_ID:        clientId,
        JOBBER_CLIENT_SECRET:    clientSecret,
        JOBBER_ACCESS_TOKEN:     dbRow.access_token,
        JOBBER_REFRESH_TOKEN:    dbRow.refresh_token,
        JOBBER_TOKEN_EXPIRES_AT: dbRow.expires_at,
        SUPABASE_URL:            envs[0].kv.SUPABASE_URL,
        SUPABASE_SERVICE_ROLE_KEY: envs[0].kv.SUPABASE_SERVICE_ROLE_KEY,
      },
    });
    log(`[jobber-token] webhook_tokens row: exp ${dbRow.expires_at} app ${jwtAppId(dbRow.access_token)}`);
  }

  // Rank ONLY access_tokens belonging to the canonical app (or whose app can't
  // be decoded). A foreign-app token (e.g. the write app's, in a sibling .env)
  // is ignored — never picked, never propagated.
  const ranked = envs
    .map(e => ({ env: e, exp: jwtExpMs(e.kv.JOBBER_ACCESS_TOKEN), app: jwtAppId(e.kv.JOBBER_ACCESS_TOKEN) }))
    .filter(c => c.exp > 0 && (!clientId || !c.app || c.app === clientId))
    .sort((a, b) => b.exp - a.exp);
  const best = ranked[0];
  log(`[jobber-token] best app-matched exp: ${best ? new Date(best.exp).toISOString() : '(none)'}`);

  // Fast path: an app-matched token is still valid (60s buffer)
  if (!force && best && best.exp > Date.now() + 60_000) {
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

  // Refresh path requires CLIENT_ID/SECRET; fail fast with a clear message
  // if we got this far without them (no fresh DB row, no env credentials).
  if (!clientId || !clientSecret) {
    throw new Error('No fresh token in webhook_tokens AND JOBBER_CLIENT_ID/CLIENT_SECRET not provided — cannot refresh.');
  }

  // Refresh as the canonical app: try its DB refresh_token first, then others.
  const refreshTokens = [...new Set([dbRow && dbRow.refresh_token, ...ranked.map(r => r.env.kv.JOBBER_REFRESH_TOKEN)].filter(Boolean))];
  log(`[jobber-token] refreshing as app ${clientId}; trying ${refreshTokens.length} refresh_token candidate(s)`);

  let lastErr;
  for (const rt of refreshTokens) {
    try {
      const result = await refreshWith(rt, clientId, clientSecret);
      // Defense in depth: never store a token that isn't the canonical app's.
      if (jwtAppId(result.access_token) !== clientId) { log('[jobber-token] refreshed token app mismatch — refusing to store'); continue; }
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
