// Backfill the 8 orphan records identified in the 2026-05-12 NULL audit:
//   - 4 clients with empty name (348, 451, 455, 457): hit Jobber API, write name
//   - 2 invoices with NULL client_id (1665, 1693): pull client from Jobber
//   - 2 visits with NULL start_at (1706, 1767): pull start_at from Jobber
//
// One-shot. Idempotent — only writes where target column is still NULL.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const CLIENT_ID = process.env.JOBBER_CLIENT_ID;
const CLIENT_SECRET = process.env.JOBBER_CLIENT_SECRET;

function http(opts, body) {
  return new Promise((res, rej) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({ ...opts, headers: { ...(opts.headers || {}), ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) } }, r => {
      const c = []; r.on('data', x => c.push(x)); r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.setTimeout(30000, () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload);
    req.end();
  });
}
async function pg(sql) { const r = await http({ hostname: 'api.supabase.com', path: `/v1/projects/${PROD}/database/query`, method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' } }, JSON.stringify({ query: sql })); if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 300)}`); return JSON.parse(r.body); }
async function rest(path, opts = {}) {
  const u = new URL(SUPABASE_URL + '/rest/v1' + path);
  const r = await http({ hostname: u.hostname, path: u.pathname + u.search, method: opts.method || 'GET', headers: { apikey: SVC, Authorization: `Bearer ${SVC}`, 'Content-Type': 'application/json', ...(opts.headers || {}) } }, opts.body);
  if (r.status >= 300) throw new Error(`REST ${path} → ${r.status}: ${r.body.slice(0, 300)}`);
  return r.body ? JSON.parse(r.body) : null;
}

async function getJobberToken() {
  const rows = await rest('/webhook_tokens?source_system=eq.jobber&select=access_token,refresh_token,expires_at');
  const row = rows[0];
  if (!row) throw new Error('no jobber token row');
  if (new Date(row.expires_at).getTime() > Date.now() + 60_000) return row.access_token;
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(CLIENT_ID)}&client_secret=${encodeURIComponent(CLIENT_SECRET)}`;
  const tr = await http({ hostname: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }, body);
  if (tr.status >= 300) throw new Error(`token refresh ${tr.status}: ${tr.body.slice(0, 200)}`);
  const tokens = JSON.parse(tr.body);
  const newExp = JSON.parse(Buffer.from(tokens.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await rest('/webhook_tokens?source_system=eq.jobber', { method: 'PATCH', body: JSON.stringify({ access_token: tokens.access_token, refresh_token: tokens.refresh_token || row.refresh_token, expires_at: new Date(newExp).toISOString(), updated_at: new Date().toISOString() }) });
  return tokens.access_token;
}
async function gql(token, query) {
  const r = await http({ hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' } }, JSON.stringify({ query }));
  if (r.status >= 300) throw new Error(`gql ${r.status}: ${r.body.slice(0, 300)}`);
  const j = JSON.parse(r.body);
  if (j.errors?.length) throw new Error(`gql err: ${JSON.stringify(j.errors[0])}`);
  return j.data;
}

(async () => {
  const token = await getJobberToken();
  console.log('Got Jobber token.\n');

  // === 1. 4 NULL-name clients ===
  console.log('=== [1/3] Backfill 4 NULL-name clients ===');
  const orphanClients = await pg(`
    SELECT c.id, esl.source_id AS jobber_gid
    FROM clients c
    JOIN entity_source_links esl ON esl.entity_type='client' AND esl.entity_id=c.id AND esl.source_system='jobber'
    WHERE (c.name IS NULL OR c.name='') AND c.id IN (348, 451, 455, 457);`);

  for (const c of orphanClients) {
    const q = `{ client(id: "${c.jobber_gid}") { id isCompany companyName firstName lastName name } }`;
    const data = await gql(token, q).catch(e => { console.log(`  ! ${c.id} fetch failed: ${e.message}`); return null; });
    if (!data?.client) { console.log(`  ! client ${c.id}: Jobber returned no record`); continue; }
    const jc = data.client;
    const inferred = jc.isCompany ? (jc.companyName || jc.name) : `${jc.firstName || ''} ${jc.lastName || ''}`.trim();
    const finalName = inferred || jc.name || null;
    if (!finalName) { console.log(`  ! client ${c.id}: Jobber too has empty name`); continue; }
    await rest(`/clients?id=eq.${c.id}&name=is.null`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ name: finalName }) });
    // is.null didn't catch empty-string, do it again with eq.empty
    await rest(`/clients?id=eq.${c.id}&name=eq.`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ name: finalName }) });
    console.log(`  ✓ client ${c.id} → "${finalName}" (isCompany=${jc.isCompany}, jobber name="${jc.name}")`);
  }

  // === 2. 2 NULL client_id invoices ===
  console.log('\n=== [2/3] Backfill 2 NULL client_id invoices ===');
  const orphanInvoices = await pg(`
    SELECT i.id, esl.source_id AS jobber_id
    FROM invoices i
    JOIN entity_source_links esl ON esl.entity_type='invoice' AND esl.entity_id=i.id AND esl.source_system='jobber'
    WHERE i.client_id IS NULL;`);

  for (const inv of orphanInvoices) {
    // jobber_id may be numeric or GID. Always wrap in GID form.
    const gid = inv.jobber_id.startsWith('Z2lk') ? inv.jobber_id
      : Buffer.from(`gid://Jobber/Invoice/${inv.jobber_id}`).toString('base64').replace(/=+$/, '');
    const q = `{ invoice(id: "${gid}") { id client { id } } }`;
    const data = await gql(token, q).catch(e => { console.log(`  ! invoice ${inv.id} gql failed: ${e.message}`); return null; });
    const jobberClientGid = data?.invoice?.client?.id;
    if (!jobberClientGid) { console.log(`  ! invoice ${inv.id}: Jobber returned no client`); continue; }
    // Look up our client_id by jobber GID
    const rows = await pg(`SELECT entity_id FROM entity_source_links WHERE entity_type='client' AND source_system='jobber' AND source_id='${jobberClientGid}' LIMIT 1;`);
    if (!rows.length) { console.log(`  ! invoice ${inv.id}: jobber client ${jobberClientGid} not in our DB`); continue; }
    const cid = rows[0].entity_id;
    await rest(`/invoices?id=eq.${inv.id}&client_id=is.null`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ client_id: cid }) });
    console.log(`  ✓ invoice ${inv.id} → client_id=${cid} (jobber=${jobberClientGid})`);
  }

  // === 3. 2 NULL start_at scheduled visits ===
  console.log('\n=== [3/3] Backfill 2 NULL start_at scheduled visits ===');
  const orphanVisits = await pg(`
    SELECT v.id, esl.source_id AS jobber_gid
    FROM visits v
    JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
    WHERE v.visit_status='scheduled' AND v.start_at IS NULL;`);

  for (const v of orphanVisits) {
    const q = `{ visit(id: "${v.jobber_gid}") { id startAt endAt completedAt } }`;
    const data = await gql(token, q).catch(e => { console.log(`  ! visit ${v.id} gql failed: ${e.message}`); return null; });
    const startAt = data?.visit?.startAt;
    if (!startAt) { console.log(`  ! visit ${v.id}: Jobber too has null startAt — leaving NULL (emergency/TBD)`); continue; }
    await rest(`/visits?id=eq.${v.id}&start_at=is.null`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ start_at: startAt }) });
    console.log(`  ✓ visit ${v.id} → start_at=${startAt}`);
  }

  // Final state
  console.log('\n=== Final state ===');
  const final = await pg(`
    SELECT
      (SELECT COUNT(*) FROM clients WHERE (name IS NULL OR name='') AND status='ACTIVE')::int AS null_name_clients,
      (SELECT COUNT(*) FROM invoices WHERE client_id IS NULL)::int AS null_client_invoices,
      (SELECT COUNT(*) FROM visits WHERE visit_status='scheduled' AND start_at IS NULL)::int AS null_start_at_visits;`);
  console.log(' ', final[0]);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
