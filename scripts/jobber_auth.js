// ============================================================================
// Jobber OAuth 2.0 — One-time Token Exchange
// ============================================================================
//
// Run this ONCE to authorize the Unclogme Claude app and capture tokens.
//
// Usage:
//   node scripts/jobber_auth.js
//
// What it does:
//   1. Spins up a tiny local HTTP server on http://localhost:3000
//   2. Opens the Jobber consent URL in your default browser
//   3. You click "Allow" in Jobber → Jobber redirects to /callback?code=XXX
//   4. Script exchanges the code for access_token + refresh_token
//   5. Saves both to .env (JOBBER_ACCESS_TOKEN, JOBBER_REFRESH_TOKEN)
//   6. Shuts down the local server
//
// After this runs once, scripts/jobber_api.js handles all subsequent calls
// and auto-refreshes the access token when expired.
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });
const http = require('http');
const https = require('https');
const { URL } = require('url');
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');

const CLIENT_ID = process.env.JOBBER_CLIENT_ID;
const CLIENT_SECRET = process.env.JOBBER_CLIENT_SECRET;
const REDIRECT_URI = process.env.JOBBER_REDIRECT_URI || 'http://localhost:3000/callback';
const PORT = 3000;

if (!CLIENT_ID || !CLIENT_SECRET) {
  console.error('ERROR: JOBBER_CLIENT_ID and JOBBER_CLIENT_SECRET must be set in .env');
  process.exit(1);
}

const AUTH_URL = `https://api.getjobber.com/api/oauth/authorize?client_id=${CLIENT_ID}&redirect_uri=${encodeURIComponent(REDIRECT_URI)}&response_type=code`;
const TOKEN_URL = 'https://api.getjobber.com/api/oauth/token';

// ----------------------------------------------------------------------------
// POST helper (no external deps)
// ----------------------------------------------------------------------------
function postForm(urlString, formData) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlString);
    const body = Object.entries(formData)
      .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
      .join('&');

    const req = https.request(
      {
        hostname: u.hostname,
        path: u.pathname + u.search,
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => {
          try {
            const parsed = JSON.parse(data);
            if (res.statusCode >= 200 && res.statusCode < 300) resolve(parsed);
            else reject(new Error(`HTTP ${res.statusCode}: ${data}`));
          } catch (e) {
            reject(new Error(`Bad JSON response: ${data}`));
          }
        });
      }
    );
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// ----------------------------------------------------------------------------
// Update .env file with new token values
// ----------------------------------------------------------------------------
function updateEnvFile(updates) {
  const envPath = path.resolve(__dirname, '../.env');
  let content = fs.readFileSync(envPath, 'utf8');

  for (const [key, value] of Object.entries(updates)) {
    const regex = new RegExp(`^${key}=.*$`, 'm');
    if (regex.test(content)) {
      content = content.replace(regex, `${key}=${value}`);
    } else {
      content += `\n${key}=${value}`;
    }
  }

  fs.writeFileSync(envPath, content);
}

// ----------------------------------------------------------------------------
// Open URL in default browser (cross-platform)
// ----------------------------------------------------------------------------
function openBrowser(url) {
  const cmd =
    process.platform === 'win32'
      ? `start "" "${url}"`
      : process.platform === 'darwin'
      ? `open "${url}"`
      : `xdg-open "${url}"`;
  exec(cmd, (err) => {
    if (err) {
      console.log('\nCould not auto-open browser. Open this URL manually:\n');
      console.log(url);
      console.log();
    }
  });
}

// ----------------------------------------------------------------------------
// Main: spin up server, handle callback, exchange code for tokens
// ----------------------------------------------------------------------------
async function main() {
  console.log('Jobber OAuth — starting local callback server...\n');
  console.log('[debug] CLIENT_ID:', CLIENT_ID);
  console.log('[debug] REDIRECT_URI:', REDIRECT_URI);
  console.log('[debug] PORT:', PORT);
  console.log('[debug] platform:', process.platform);
  console.log('[debug] cwd:', process.cwd());
  console.log('[debug] .env path:', path.resolve(__dirname, '../.env'));
  console.log();

  const server = http.createServer(async (req, res) => {
    console.log(`[debug] incoming request: ${req.method} ${req.url}`);
    if (!req.url.startsWith('/callback')) {
      res.writeHead(404);
      res.end('Not found');
      return;
    }

    const u = new URL(req.url, `http://localhost:${PORT}`);
    const code = u.searchParams.get('code');
    const error = u.searchParams.get('error');

    if (error) {
      res.writeHead(400, { 'Content-Type': 'text/html' });
      res.end(`<h1>Authorization failed</h1><pre>${error}</pre>`);
      console.error(`\nERROR: ${error}`);
      server.close();
      process.exit(1);
    }

    if (!code) {
      res.writeHead(400);
      res.end('Missing code parameter');
      return;
    }

    console.log('Authorization code received. Exchanging for tokens...');

    try {
      const tokenResponse = await postForm(TOKEN_URL, {
        client_id: CLIENT_ID,
        client_secret: CLIENT_SECRET,
        grant_type: 'authorization_code',
        code: code,
        redirect_uri: REDIRECT_URI,
      });

      const { access_token, refresh_token, expires_in } = tokenResponse;
      const expiresAt = new Date(Date.now() + expires_in * 1000).toISOString();

      updateEnvFile({
        JOBBER_ACCESS_TOKEN: access_token,
        JOBBER_REFRESH_TOKEN: refresh_token,
        JOBBER_TOKEN_EXPIRES_AT: expiresAt,
      });

      console.log('\n✓ SUCCESS — tokens saved to .env');
      console.log(`  Access token expires: ${expiresAt}`);
      console.log(`  Refresh token: stored (rotates on each use)`);
      console.log('\nYou can now run jobber API queries.');

      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(`
        <html>
          <head><title>Jobber OAuth — Success</title></head>
          <body style="font-family:sans-serif;max-width:600px;margin:80px auto;">
            <h1 style="color:#2d7d32;">Authorization successful</h1>
            <p>Tokens saved to <code>.env</code>. You can close this tab.</p>
            <p style="color:#666;">Access token expires: ${expiresAt}</p>
          </body>
        </html>
      `);

      setTimeout(() => {
        server.close();
        process.exit(0);
      }, 1000);
    } catch (err) {
      console.error('\nERROR exchanging code:', err.message);
      res.writeHead(500, { 'Content-Type': 'text/html' });
      res.end(`<h1>Token exchange failed</h1><pre>${err.message}</pre>`);
      server.close();
      process.exit(1);
    }
  });

  server.on('error', (err) => {
    if (err.code === 'EADDRINUSE') {
      console.error(`\nFATAL: Port ${PORT} is already in use.`);
      console.error('Another process (previous auth run? dev server?) is holding it.');
      console.error('Fix: close that process, or run: netstat -ano | findstr :3000');
    } else {
      console.error('\nFATAL server error:', err);
    }
    process.exit(1);
  });

  server.listen(PORT, '127.0.0.1', () => {
    console.log(`Local server listening on http://localhost:${PORT}`);
    console.log('\nOpening Jobber authorization page in your browser...');
    console.log('If it does not open, paste this URL into your browser:\n');
    console.log(AUTH_URL);
    console.log();
    console.log('[debug] Waiting for Jobber to redirect to /callback...');
    console.log('[debug] KEEP THIS TERMINAL OPEN until you see SUCCESS.\n');
    openBrowser(AUTH_URL);
  });
}

main().catch((err) => {
  console.error('FATAL:', err);
  process.exit(1);
});
