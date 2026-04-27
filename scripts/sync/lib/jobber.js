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
const API_VERSION = '2026-04-16'; // pin an explicit schema version

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
  // Delegate to shared cross-session token manager. It reads BOTH Supabase/.env
  // and Slack/.env, picks the freshest-expiring token, tries every known
  // refresh_token if a refresh is needed, and writes the result back to both
  // .env files + the Supabase webhook_tokens row — so multiple sessions don't
  // invalidate each other's refresh_token.
  const { getValidToken } = require('../jobber_token');
  ACCESS_TOKEN = await getValidToken({ verbose: true });
  // Re-read rotated refresh_token from .env (syncAndMaybeRefresh wrote it back)
  const fs = require('fs');
  const env = fs.readFileSync(require('path').resolve(__dirname, '../../../.env'), 'utf8');
  const m = env.match(/^JOBBER_REFRESH_TOKEN=(.+)$/m);
  if (m) REFRESH_TOKEN = m[1].trim();
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function gql(query, variables = {}, _retries = 0) {
  if (!ACCESS_TOKEN) throw new Error('JOBBER_ACCESS_TOKEN missing — run scripts/jobber_auth.js once to authorize');
  const body = JSON.stringify({ query, variables });
  const r = await postJson(GRAPHQL_URL, {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${ACCESS_TOKEN}`,
    'X-JOBBER-GRAPHQL-VERSION': API_VERSION,
  }, body);
  if (r.status === 401 && _retries === 0) {
    await refreshAccessToken();
    return gql(query, variables, 1);
  }
  if (r.status >= 300) throw new Error(`Jobber GraphQL HTTP ${r.status}: ${r.body.slice(0, 400)}`);
  const parsed = JSON.parse(r.body);

  // Handle throttling with exponential backoff (max 3 retries)
  const isThrottled = parsed.errors?.some(e => e.extensions?.code === 'THROTTLED');
  if (isThrottled && _retries < 3) {
    const waitSec = Math.pow(2, _retries) * 15; // 15s, 30s, 60s
    const available = parsed.extensions?.cost?.throttleStatus?.currentlyAvailable;
    console.log(`    [throttled] available=${available ?? '?'}, waiting ${waitSec}s (retry ${_retries + 1}/3)`);
    await sleep(waitSec * 1000);
    return gql(query, variables, _retries + 1);
  }

  if (parsed.errors) throw new Error(`Jobber GraphQL errors: ${JSON.stringify(parsed.errors).slice(0, 400)}`);

  // Log cost budget periodically
  const cost = parsed.extensions?.cost;
  if (cost) {
    const avail = cost.throttleStatus?.currentlyAvailable;
    if (avail !== undefined && avail < 2000) {
      console.log(`    [budget] ${avail}/${cost.throttleStatus.maximumAvailable} remaining (restore ${cost.throttleStatus.restoreRate}/min)`);
    }
  }

  return parsed.data;
}

// ----------------------------------------------------------------------------
// Paginated delta pull
// ----------------------------------------------------------------------------
// entityField: top-level GraphQL connection name (e.g. "clients", "invoices")
// nodeFields:  GraphQL fragment string for the node shape we care about
// updatedAfter: ISO timestamp string — cursor filter
// ----------------------------------------------------------------------------
// Ensure timestamps are ISO8601 (Jobber rejects "2020-01-01 00:00:00+00")
function toISO(ts) {
  if (!ts) return null;
  const d = new Date(ts);
  if (isNaN(d.getTime())) return ts; // pass through if already valid
  return d.toISOString();
}

async function pullDelta({ entityField, nodeFields, updatedAfter, pageSize = 100, maxPages = 500 }) {
  const allNodes = [];
  let cursor = null;
  let page = 0;

  const filterType = filterTypeName(entityField);
  const cursorField = CURSOR_FIELD[entityField];
  const nodeTimeField = NODE_TIME_FIELD[entityField];

  // Inject the node time field into the query if not already present
  let fields = nodeFields;
  if (nodeTimeField && !nodeFields.includes(nodeTimeField)) {
    fields = nodeFields + `\n      ${nodeTimeField}`;
  }

  while (page < maxPages) {
    page++;

    // Build filter: use the entity-specific cursor field, or no filter if entity doesn't support one
    let filter = {};
    let filterDecl = '';
    if (cursorField && updatedAfter) {
      filter = { [cursorField]: { after: toISO(updatedAfter) } };
      filterDecl = `, $filter: ${filterType}FilterAttributes`;
    }

    const q = `
      query Delta($after: String, $first: Int!${filterDecl}) {
        ${entityField}(after: $after, first: $first${filterDecl ? ', filter: $filter' : ''}) {
          pageInfo { hasNextPage endCursor }
          nodes { ${fields} }
        }
      }
    `;
    const vars = { after: cursor, first: pageSize };
    if (cursorField && updatedAfter) vars.filter = filter;

    const data = await gql(q, vars);
    const conn = data[entityField];
    if (!conn) throw new Error(`entity ${entityField} missing in response`);
    allNodes.push(...conn.nodes);
    if (!conn.pageInfo.hasNextPage) break;
    cursor = conn.pageInfo.endCursor;
  }

  // Tag each node with the time field used for cursor advancement
  if (nodeTimeField) {
    for (const n of allNodes) {
      if (!n._cursorTime) n._cursorTime = n[nodeTimeField];
    }
  }

  return allNodes;
}

// Maps GraphQL connection name to its FilterAttributes type prefix
// Verified against Jobber introspection 2026-04-10
function filterTypeName(field) {
  const map = {
    clients: 'Client',
    properties: 'Properties',   // plural!
    jobs: 'Job',
    visits: 'Visit',
    invoices: 'Invoice',
    quotes: 'Quote',
    users: 'Users',             // plural!
  };
  return map[field] || field;
}

// Which cursor field to use for delta filters per entity
// Jobber schema is inconsistent: some have updatedAt, some only createdAt, some neither
const CURSOR_FIELD = {
  clients:    'updatedAt',
  properties: null,         // PropertiesFilterAttributes has no time filter
  jobs:       'createdAt',  // no updatedAt filter
  visits:     'createdAt',  // no updatedAt filter
  invoices:   'updatedAt',
  quotes:     'updatedAt',
  users:      null,         // UsersFilterAttributes has no time filter
};

// Which node field carries the timestamp for advancing the cursor
const NODE_TIME_FIELD = {
  clients:    'updatedAt',
  properties: null,         // Property type has no time fields at all
  jobs:       'updatedAt',
  visits:     'createdAt',  // Visit type has no updatedAt field
  invoices:   'updatedAt',
  quotes:     'updatedAt',
  users:      'createdAt',  // User type has no updatedAt field
};

module.exports = { gql, pullDelta, refreshAccessToken };
