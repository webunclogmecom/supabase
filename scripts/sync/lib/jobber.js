// ============================================================================
// jobber.js — Thin Jobber GraphQL client with auto-refresh
// ============================================================================
// Used by incremental_sync.js. Supports:
//   • automatic token refresh when expired (writes back to .env)
//   • paginated queries (Jobber uses cursor pagination: pageInfo.hasNextPage)
//   • updatedAt filter per entity for delta pulls
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');

const GRAPHQL_URL = 'https://api.getjobber.com/api/graphql';
const TOKEN_URL = 'https://api.getjobber.com/api/oauth/token';
const API_VERSION = '2025-01-20'; // pin an explicit schema version

let ACCESS_TOKEN = process.env.JOBBER_ACCESS_TOKEN;
let REFRESH_TOKEN = process.env.JOBBER_REFRESH_TOKEN;
const CLIENT_ID = process.env.JOBBER_CLIENT_ID;
const CLIENT_SECRET = process.env.JOBBER_CLIENT_SECRET;

function postJson(url, headers, bodyStr) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request({
      hostname: u.hostname,
      path: u.pathname,
      method: 'POST',
      headers: { ...headers, 'Content-Length': Buffer.byteLength(bodyStr) },
    }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    req.write(bodyStr);
    req.end();
  });
}

function updateEnv(updates) {
  const envPath = path.resolve(__dirname, '../../../.env');
  let content = fs.readFileSync(envPath, 'utf8');
  for (const [k, v] of Object.entries(updates)) {
    const re = new RegExp(`^${k}=.*$`, 'm');
    if (re.test(content)) content = content.replace(re, `${k}=${v}`);
    else content += `\n${k}=${v}`;
  }
  fs.writeFileSync(envPath, content);
}

async function refreshAccessToken() {
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(REFRESH_TOKEN)}&client_id=${encodeURIComponent(CLIENT_ID)}&client_secret=${encodeURIComponent(CLIENT_SECRET)}`;
  const r = await postJson(TOKEN_URL, { 'Content-Type': 'application/x-www-form-urlencoded' }, body);
  if (r.status >= 300) throw new Error(`Jobber refresh failed HTTP ${r.status}: ${r.body.slice(0, 300)}`);
  const parsed = JSON.parse(r.body);
  ACCESS_TOKEN = parsed.access_token;
  REFRESH_TOKEN = parsed.refresh_token || REFRESH_TOKEN;
  const expiresAt = new Date(Date.now() + (parsed.expires_in || 3600) * 1000).toISOString();
  updateEnv({
    JOBBER_ACCESS_TOKEN: ACCESS_TOKEN,
    JOBBER_REFRESH_TOKEN: REFRESH_TOKEN,
    JOBBER_TOKEN_EXPIRES_AT: expiresAt,
  });
  console.log('  [jobber] access token refreshed, expires', expiresAt);
}

async function gql(query, variables = {}, _retry = false) {
  if (!ACCESS_TOKEN) throw new Error('JOBBER_ACCESS_TOKEN missing — run scripts/jobber_auth.js once to authorize');
  const body = JSON.stringify({ query, variables });
  const r = await postJson(GRAPHQL_URL, {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${ACCESS_TOKEN}`,
    'X-JOBBER-GRAPHQL-VERSION': API_VERSION,
  }, body);
  if (r.status === 401 && !_retry) {
    await refreshAccessToken();
    return gql(query, variables, true);
  }
  if (r.status >= 300) throw new Error(`Jobber GraphQL HTTP ${r.status}: ${r.body.slice(0, 400)}`);
  const parsed = JSON.parse(r.body);
  if (parsed.errors) throw new Error(`Jobber GraphQL errors: ${JSON.stringify(parsed.errors).slice(0, 400)}`);
  return parsed.data;
}

// ----------------------------------------------------------------------------
// Paginated delta pull
// ----------------------------------------------------------------------------
// entityField: top-level GraphQL connection name (e.g. "clients", "invoices")
// nodeFields:  GraphQL fragment string for the node shape we care about
// updatedAfter: ISO timestamp string — cursor filter
// ----------------------------------------------------------------------------
async function pullDelta({ entityField, nodeFields, updatedAfter, pageSize = 100, maxPages = 500 }) {
  const allNodes = [];
  let cursor = null;
  let page = 0;

  while (page < maxPages) {
    page++;
    const q = `
      query Delta($after: String, $first: Int!, $filter: ${capitalizeSingular(entityField)}FilterAttributes) {
        ${entityField}(after: $after, first: $first, filter: $filter) {
          pageInfo { hasNextPage endCursor }
          nodes { ${nodeFields} }
        }
      }
    `;
    const filter = updatedAfter ? { updatedAt: { after: updatedAfter } } : {};
    const data = await gql(q, { after: cursor, first: pageSize, filter });
    const conn = data[entityField];
    if (!conn) throw new Error(`entity ${entityField} missing in response`);
    allNodes.push(...conn.nodes);
    if (!conn.pageInfo.hasNextPage) break;
    cursor = conn.pageInfo.endCursor;
  }
  return allNodes;
}

function capitalizeSingular(field) {
  // clients -> Client, properties -> Property, invoices -> Invoice
  const map = {
    clients: 'Client',
    properties: 'Property',
    jobs: 'Job',
    visits: 'Visit',
    invoices: 'Invoice',
    quotes: 'Quote',
    users: 'User',
  };
  return map[field] || field;
}

module.exports = { gql, pullDelta, refreshAccessToken };
