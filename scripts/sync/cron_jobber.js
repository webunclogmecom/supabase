// ============================================================================
// cron_jobber.js — periodic Jobber → Supabase sync
// ============================================================================
// Runs every 2 minutes via GitHub Actions. Pulls deltas from Jobber GraphQL
// (clients, properties, jobs, visits, invoices, quotes, users) since the
// last cursor in public.sync_cursors, upserts into raw.jobber_pull_*, then
// replays the flagged rows through webhook-jobber so they land in public.*.
//
// Token handling: reads + writes public.webhook_tokens directly (no .env
// dependency), so the cron is stateless across runs. If access_token is
// within 60s of expiry, refreshes via the Jobber OAuth endpoint and writes
// the new tokens back to webhook_tokens.
//
// Required process.env (set as GitHub Actions secrets):
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY
//   SUPABASE_PAT             (used by populate/lib/db.js Management API caller)
//   JOBBER_CLIENT_ID         (only for the refresh path)
//   JOBBER_CLIENT_SECRET     (only for the refresh path)
//
// CLI:
//   node scripts/sync/cron_jobber.js              # one full cycle
//   node scripts/sync/cron_jobber.js --no-replay  # skip replay, only refresh raw cache
// ============================================================================

const https = require('https');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY;
const CLIENT_ID    = process.env.JOBBER_CLIENT_ID;
const CLIENT_SECRET= process.env.JOBBER_CLIENT_SECRET;

if (!SUPABASE_URL || !SERVICE_KEY) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');
if (!CLIENT_ID || !CLIENT_SECRET) throw new Error('JOBBER_CLIENT_ID and JOBBER_CLIENT_SECRET are required');

const SKIP_REPLAY = process.argv.includes('--no-replay');
// Properties + users have no updatedAt filter in Jobber's API → pulling them
// every 2 min would re-fetch all ~400 rows each cycle and stall the cron.
// Default to skipping unless --full is passed (use that for a daily/manual run).
const FULL = process.argv.includes('--full');

// ---- Tiny REST helpers --------------------------------------------------------

function request({ host, path, method = 'GET', headers = {}, body = null }) {
  return new Promise((resolve, reject) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({
      hostname: host, path, method,
      headers: { ...headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) },
    }, (res) => {
      let d = ''; res.on('data', (c) => (d += c));
      res.on('end', () => resolve({ status: res.statusCode, body: d }));
    });
    req.on('error', reject);
    req.setTimeout(60_000, () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload);
    req.end();
  });
}

function rest(path, opts = {}) {
  const u = new URL(SUPABASE_URL + '/rest/v1' + path);
  return request({
    host: u.hostname,
    path: u.pathname + u.search,
    method: opts.method || 'GET',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
      ...(opts.headers || {}),
    },
    body: opts.body,
  });
}

// ---- Token management ---------------------------------------------------------

async function getJobberToken() {
  const r = await rest('/webhook_tokens?source_system=eq.jobber&select=access_token,refresh_token,expires_at');
  if (r.status !== 200) throw new Error(`webhook_tokens read failed: ${r.status} ${r.body}`);
  const row = JSON.parse(r.body)[0];
  if (!row) throw new Error('No jobber row in webhook_tokens — run scripts/jobber_auth.js once locally first.');

  const expMs = new Date(row.expires_at).getTime();
  if (expMs > Date.now() + 60_000) {
    return row.access_token;
  }

  // Refresh
  console.log('[cron] access token expiring; refreshing');
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(CLIENT_ID)}&client_secret=${encodeURIComponent(CLIENT_SECRET)}`;
  const tr = await request({
    host: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  if (tr.status >= 300) throw new Error(`Refresh failed ${tr.status}: ${tr.body.slice(0,200)}`);
  const tokens = JSON.parse(tr.body);
  // exp lives in JWT claim
  const newExpMs = JSON.parse(Buffer.from(tokens.access_token.split('.')[1], 'base64').toString()).exp * 1000;

  const upd = await rest('/webhook_tokens?source_system=eq.jobber', {
    method: 'PATCH',
    body: JSON.stringify({
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token || row.refresh_token,
      expires_at: new Date(newExpMs).toISOString(),
      updated_at: new Date().toISOString(),
    }),
  });
  if (upd.status >= 300) throw new Error(`webhook_tokens update failed: ${upd.status}`);
  console.log(`[cron] refreshed; new exp ${new Date(newExpMs).toISOString()}`);
  return tokens.access_token;
}

// ---- Jobber GraphQL -----------------------------------------------------------

async function gql(token, query, variables = {}) {
  const body = JSON.stringify({ query, variables });
  const r = await request({
    host: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
    },
    body,
  });
  if (r.status >= 300) throw new Error(`GraphQL ${r.status}: ${r.body.slice(0, 300)}`);
  const j = JSON.parse(r.body);
  if (j.errors?.length) throw new Error(`GraphQL error: ${JSON.stringify(j.errors[0])}`);
  return j.data;
}

// ---- Sync logic — adapted from scripts/sync/incremental_sync.js ---------------
// We don't reuse incremental_sync.js directly because that module reads tokens
// from .env, which we don't have in CI. The logic is duplicated minimally here.

const CURSOR_FIELD = {
  clients: 'updatedAt', properties: null, jobs: 'createdAt',
  visits: 'createdAt', invoices: 'updatedAt', quotes: 'updatedAt', users: null,
};
const NODE_TIME_FIELD = {
  clients: 'updatedAt', properties: null, jobs: 'updatedAt',
  visits: 'createdAt', invoices: 'updatedAt', quotes: 'updatedAt', users: 'createdAt',
};
const FILTER_TYPE = {
  clients: 'Client', properties: 'Properties', jobs: 'Job',
  visits: 'Visit', invoices: 'Invoice', quotes: 'Quote', users: 'Users',
};

const ENTITIES = [
  { name: 'clients',    rawTable: 'jobber_pull_clients',    fields: 'id firstName lastName companyName isCompany isArchived emails { address primary description } phones { number primary description } billingAddress { street city province postalCode country } balance updatedAt' },
  { name: 'properties', rawTable: 'jobber_pull_properties', fields: 'id client { id } address { street city province postalCode country }' },
  { name: 'jobs',       rawTable: 'jobber_pull_jobs',       fields: 'id jobNumber title client { id } property { id } jobStatus startAt endAt total updatedAt' },
  { name: 'visits',     rawTable: 'jobber_pull_visits',     fields: 'id title startAt endAt completedAt visitStatus client { id } job { id } invoice { id } assignedUsers { nodes { id } } createdAt', pageSize: 25 },
  { name: 'invoices',   rawTable: 'jobber_pull_invoices',   fields: 'id invoiceNumber invoiceStatus issuedDate dueDate subject amounts { subtotal total invoiceBalance depositAmount } client { id } updatedAt' },
  { name: 'quotes',     rawTable: 'jobber_pull_quotes',     fields: 'id quoteNumber quoteStatus amounts { subtotal total depositAmount } client { id } updatedAt' },
  { name: 'users',      rawTable: 'jobber_pull_users',      fields: 'id name { first last full } email { raw } isAccountOwner isAccountAdmin createdAt' },
];

async function pullDelta(token, entity, cursor) {
  const cursorField = CURSOR_FIELD[entity.name];
  const nodeTimeField = NODE_TIME_FIELD[entity.name];
  const pageSize = entity.pageSize || 100;
  const all = [];
  let after = null, page = 0, maxPages = 200;

  let fields = entity.fields;
  if (nodeTimeField && !fields.includes(nodeTimeField)) fields += ` ${nodeTimeField}`;

  while (page++ < maxPages) {
    const filterType = FILTER_TYPE[entity.name];
    const useFilter = cursorField && cursor;
    const q = `query Delta($after: String, $first: Int!${useFilter ? `, $filter: ${filterType}FilterAttributes` : ''}) {
      ${entity.name}(after: $after, first: $first${useFilter ? ', filter: $filter' : ''}) {
        pageInfo { hasNextPage endCursor }
        nodes { ${fields} }
      }
    }`;
    const vars = { after, first: pageSize };
    if (useFilter) vars.filter = { [cursorField]: { after: new Date(cursor).toISOString() } };
    const data = await gql(token, q, vars);
    const conn = data[entity.name];
    if (!conn) break;
    all.push(...conn.nodes);
    if (!conn.pageInfo.hasNextPage) break;
    after = conn.pageInfo.endCursor;
  }
  if (nodeTimeField) for (const n of all) if (!n._cursorTime) n._cursorTime = n[nodeTimeField];
  return all;
}

// ---- Raw upsert via Supabase Management API SQL -------------------------------

async function execSql(sql) {
  const projectRef = SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];
  const PAT = process.env.SUPABASE_PAT;
  if (!PAT) throw new Error('SUPABASE_PAT missing');
  const r = await request({
    host: 'api.supabase.com',
    path: `/v1/projects/${projectRef}/database/query`,
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${PAT}` },
    body: JSON.stringify({ query: sql }),
  });
  if (r.status >= 300) throw new Error(`SQL ${r.status}: ${r.body.slice(0, 300)}`);
  try { return JSON.parse(r.body); } catch { return []; }
}

function sqlEsc(v) {
  if (v == null) return 'NULL';
  return "'" + String(v).replace(/'/g, "''") + "'";
}

async function upsertRaw(rawTable, nodes) {
  if (!nodes.length) return;
  const BATCH = 50;
  for (let i = 0; i < nodes.length; i += BATCH) {
    const batch = nodes.slice(i, i + BATCH);
    const ids = batch.map(n => sqlEsc(n.id)).join(', ');
    await execSql(`DELETE FROM raw.${rawTable} WHERE data->>'id' IN (${ids});`);
    const values = batch.map(n => `(${sqlEsc(JSON.stringify(n))}::jsonb, now(), TRUE)`).join(',\n');
    await execSql(`INSERT INTO raw.${rawTable} (data, ingested_at, needs_populate) VALUES ${values};`);
  }
}

async function getCursor(name) {
  const r = await rest(`/sync_cursors?entity=eq.${encodeURIComponent(name)}&select=last_synced_at`);
  if (r.status !== 200) return null;
  return JSON.parse(r.body)[0]?.last_synced_at;
}

async function setCursor(name, ts, rowsPulled) {
  await rest(`/sync_cursors?entity=eq.${encodeURIComponent(name)}`, {
    method: 'PATCH',
    body: JSON.stringify({
      last_synced_at: ts,
      last_run_finished: new Date().toISOString(),
      last_run_status: 'success',
      rows_pulled: rowsPulled,
      updated_at: new Date().toISOString(),
    }),
  });
}

// ---- Replay flagged raw rows through webhook-jobber --------------------------

async function replayFlagged(jobberClientSecret, includeFull) {
  const crypto = require('crypto');
  // On incremental runs, skip properties (no delta filter — would waste time on
  // unchanged rows). They're picked up via PROPERTY_* webhooks or --full runs.
  const TOPICS = includeFull ? {
    jobber_pull_clients:    { entity: 'client',    topic: 'CLIENT_UPDATE' },
    jobber_pull_properties: { entity: 'property',  topic: 'PROPERTY_UPDATE' },
    jobber_pull_jobs:       { entity: 'job',       topic: 'JOB_UPDATE' },
    jobber_pull_visits:     { entity: 'visit',     topic: 'VISIT_UPDATE' },
    jobber_pull_invoices:   { entity: 'invoice',   topic: 'INVOICE_UPDATE' },
    jobber_pull_quotes:     { entity: 'quote',     topic: 'QUOTE_UPDATE' },
  } : {
    jobber_pull_clients:    { entity: 'client',    topic: 'CLIENT_UPDATE' },
    jobber_pull_jobs:       { entity: 'job',       topic: 'JOB_UPDATE' },
    jobber_pull_visits:     { entity: 'visit',     topic: 'VISIT_UPDATE' },
    jobber_pull_invoices:   { entity: 'invoice',   topic: 'INVOICE_UPDATE' },
    jobber_pull_quotes:     { entity: 'quote',     topic: 'QUOTE_UPDATE' },
  };

  const summary = [];
  for (const [table, { topic }] of Object.entries(TOPICS)) {
    const r = await execSql(`SELECT data->>'id' AS gid FROM raw.${table} WHERE needs_populate=TRUE;`);
    const rows = r || [];
    if (!rows.length) continue;

    let ok = 0, fail = 0;
    for (const { gid } of rows) {
      const payload = JSON.stringify({ topic, webHookEvent: { itemId: gid, occurredAt: new Date().toISOString() } });
      const sig = crypto.createHmac('sha256', jobberClientSecret).update(payload).digest('base64');
      const wr = await request({
        host: SUPABASE_URL.replace(/https?:\/\//, '').replace(/\/$/, ''),
        path: '/functions/v1/webhook-jobber',
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-jobber-hmac-sha256': sig },
        body: payload,
      });
      if (wr.status >= 200 && wr.status < 300) {
        ok++;
        await execSql(`UPDATE raw.${table} SET needs_populate=FALSE WHERE data->>'id'=${sqlEsc(gid)};`);
      } else {
        fail++;
      }
    }
    summary.push({ table, ok, fail });
  }
  return summary;
}

// ---- Main ---------------------------------------------------------------------

(async () => {
  const startMs = Date.now();
  console.log(`[cron] start ${new Date().toISOString()}`);

  const token = await getJobberToken();

  let totalPulled = 0;
  for (const entity of ENTITIES) {
    // Skip non-time-filterable entities on incremental runs (use --full for those)
    if (!FULL && (entity.name === 'properties' || entity.name === 'users')) {
      continue;
    }
    const cursor = await getCursor(entity.name);
    let nodes;
    try {
      nodes = await pullDelta(token, entity, cursor);
    } catch (err) {
      console.error(`[cron] ${entity.name} pull failed: ${err.message.slice(0, 200)}`);
      continue;
    }
    if (nodes.length) {
      await upsertRaw(entity.rawTable, nodes);
      const newCursor = nodes.reduce((max, n) => {
        const ts = n._cursorTime || n.updatedAt || n.createdAt;
        return ts && ts > max ? ts : max;
      }, cursor || '2020-01-01T00:00:00Z');
      await setCursor(entity.name, newCursor, nodes.length);
      console.log(`[cron] ${entity.name}: pulled ${nodes.length}, cursor → ${newCursor}`);
      totalPulled += nodes.length;
    } else if (NODE_TIME_FIELD[entity.name]) {
      // Advance cursor to now() so we don't keep re-querying empty windows
      await setCursor(entity.name, new Date().toISOString(), 0);
    }
  }

  if (!SKIP_REPLAY && totalPulled > 0) {
    console.log(`[cron] replaying ${totalPulled} raw rows through webhook-jobber`);
    const summary = await replayFlagged(CLIENT_SECRET, FULL);
    if (summary.length) console.table(summary);
  }

  console.log(`[cron] done in ${Math.round((Date.now() - startMs) / 1000)}s — ${totalPulled} rows pulled`);
})().catch(err => {
  console.error('[cron] FATAL:', err.message);
  process.exit(1);
});
