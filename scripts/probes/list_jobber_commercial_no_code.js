// scripts/probes/list_jobber_commercial_no_code.js
//
// List every client in our DB that has NO client_code and whose Jobber
// record shows isCompany=true (Commercial). These are the ones missing
// from Airtable that should likely get a code assigned + an AT row
// created so they can be ranged by AT-driven views.
//
// Output:
//   - Plain table in stdout (for quick reading)
//   - reports/jobber_commercial_no_code.json (machine-readable, sorted by
//     visit_count DESC so the highest-touch ones surface first)
//   - reports/jobber_commercial_no_code.csv (paste-into-AT/Sheets ready)

const fs = require('fs');
const path = require('path');
const https = require('https');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const SB_URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function req({ host, path, method = 'GET', headers = {}, body = null }) {
  return new Promise((resolve, reject) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const r = https.request({ hostname: host, path, method, headers: { ...headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) } }, (res) => {
      let d = ''; res.on('data', c => (d += c));
      res.on('end', () => resolve({ status: res.statusCode, body: d }));
    });
    r.on('error', reject);
    r.setTimeout(60_000, () => r.destroy(new Error('timeout')));
    if (payload) r.write(payload);
    r.end();
  });
}

async function pg(sql) {
  const r = await req({
    host: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 300)}`);
  return JSON.parse(r.body);
}

let JOBBER_TOKEN = null;
async function getToken() {
  const r = await req({ host: SB_URL.replace('https://', '').split('/')[0], path: '/rest/v1/webhook_tokens?source_system=eq.jobber&select=access_token,refresh_token,expires_at', headers: { apikey: KEY, Authorization: `Bearer ${KEY}` } });
  const row = JSON.parse(r.body)[0];
  const expMs = new Date(row.expires_at).getTime();
  if (expMs > Date.now() + 60_000) { JOBBER_TOKEN = row.access_token; return; }
  const CLIENT_ID = process.env.JOBBER_CLIENT_ID, CLIENT_SECRET = process.env.JOBBER_CLIENT_SECRET;
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(CLIENT_ID)}&client_secret=${encodeURIComponent(CLIENT_SECRET)}`;
  const tr = await req({ host: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
  const tokens = JSON.parse(tr.body);
  const newExpMs = JSON.parse(Buffer.from(tokens.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await req({ host: SB_URL.replace('https://', '').split('/')[0], path: '/rest/v1/webhook_tokens?source_system=eq.jobber', method: 'PATCH', headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ access_token: tokens.access_token, refresh_token: tokens.refresh_token || row.refresh_token, expires_at: new Date(newExpMs).toISOString(), updated_at: new Date().toISOString() }) });
  JOBBER_TOKEN = tokens.access_token;
}

async function jobberClient(gid) {
  const r = await req({
    host: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: { Authorization: `Bearer ${JOBBER_TOKEN}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' },
    body: JSON.stringify({
      query: `query($id: EncodedId!) {
        client(id: $id) {
          id name companyName isCompany isLead isArchived createdAt
          billingAddress { street city province postalCode }
          phone email
          jobberWebUri
        }
      }`,
      variables: { id: gid },
    }),
  });
  if (r.status === 401) throw new Error('token-expired');
  const j = JSON.parse(r.body);
  if (j.errors) return { error: j.errors[0].message };
  return { client: j.data?.client };
}

(async () => {
  console.log('Loading NULL-code clients from DB…');
  await getToken();

  const dbRows = await pg(`
    SELECT c.id, c.name, c.status,
           esl.source_id AS jobber_gid,
           (SELECT COUNT(*)::int FROM public.visits v WHERE v.client_id=c.id AND v.deleted_at IS NULL) AS visits_total,
           (SELECT COUNT(*)::int FROM public.visits v WHERE v.client_id=c.id AND v.deleted_at IS NULL AND v.visit_status='completed') AS visits_completed,
           (SELECT MAX(v.visit_date) FROM public.visits v WHERE v.client_id=c.id AND v.visit_status='completed' AND v.deleted_at IS NULL) AS last_completed
    FROM public.clients c
    LEFT JOIN public.entity_source_links esl ON esl.entity_type='client' AND esl.entity_id=c.id AND esl.source_system='jobber'
    WHERE c.client_code IS NULL AND esl.source_id IS NOT NULL
    ORDER BY c.name;
  `);
  console.log(`${dbRows.length} NULL-code Jobber-linked clients to inspect.\n`);

  const commercial = [], residential = [], errors = [];
  let i = 0, lastRefresh = Date.now();
  for (const r of dbRows) {
    i++;
    if (Date.now() - lastRefresh > 5 * 60_000) { await getToken(); lastRefresh = Date.now(); }
    if (i % 25 === 0) console.log(`  ${i}/${dbRows.length}  commercial=${commercial.length}  residential=${residential.length}`);
    let res;
    try { res = await jobberClient(r.jobber_gid); }
    catch (e) {
      if (e.message === 'token-expired') { await getToken(); lastRefresh = Date.now(); try { res = await jobberClient(r.jobber_gid); } catch (e2) { errors.push({ id: r.id, err: e2.message }); continue; } }
      else { errors.push({ id: r.id, err: e.message }); continue; }
    }
    if (res.error) { errors.push({ id: r.id, err: res.error }); continue; }
    if (!res.client) { errors.push({ id: r.id, err: 'no client returned' }); continue; }
    const entry = {
      db_id: r.id,
      db_name: r.name,
      jobber_name: res.client.companyName || res.client.name,
      isCompany: res.client.isCompany,
      isArchived: res.client.isArchived,
      visits_total: r.visits_total,
      visits_completed: r.visits_completed,
      last_completed: r.last_completed,
      email: res.client.email,
      phone: res.client.phone,
      address: res.client.billingAddress
        ? [res.client.billingAddress.street, res.client.billingAddress.city, res.client.billingAddress.province, res.client.billingAddress.postalCode].filter(Boolean).join(', ')
        : null,
      jobber_url: res.client.jobberWebUri,
      created_at: res.client.createdAt,
      status: r.status,
    };
    if (res.client.isCompany) commercial.push(entry);
    else residential.push(entry);
    await new Promise(s => setTimeout(s, 60));
  }

  // Sort commercial by recent-activity desc (most active first)
  commercial.sort((a, b) => {
    if (b.visits_total !== a.visits_total) return b.visits_total - a.visits_total;
    return (b.last_completed || '').localeCompare(a.last_completed || '');
  });

  console.log(`\nTotal commercial-no-code:    ${commercial.length}`);
  console.log(`Total residential-no-code:   ${residential.length}`);
  console.log(`Errors:                      ${errors.length}\n`);
  console.log(`=== COMMERCIAL clients with NO client_code (${commercial.length}) ===`);
  console.log(`(sorted by visits_total desc; the top of this list is highest priority to code)\n`);
  for (const c of commercial) {
    const archived = c.isArchived ? '[ARCHIVED] ' : '';
    const last = c.last_completed ? ` last=${c.last_completed}` : '';
    console.log(`  ${archived}id=${c.db_id}  visits=${c.visits_total} (${c.visits_completed} completed)${last}`);
    console.log(`    name: ${c.jobber_name}`);
    if (c.address) console.log(`    addr: ${c.address}`);
    if (c.email)   console.log(`    email: ${c.email}`);
    if (c.phone)   console.log(`    phone: ${c.phone}`);
    console.log(`    ${c.jobber_url}`);
  }

  // Write reports
  const dateStr = new Date().toISOString().slice(0, 10);
  const out = path.resolve(__dirname, `../../reports/jobber_commercial_no_code_${dateStr}.json`);
  try { fs.mkdirSync(path.dirname(out), { recursive: true }); } catch {}
  fs.writeFileSync(out, JSON.stringify({
    ran_at: new Date().toISOString(),
    universe: dbRows.length,
    commercial_count: commercial.length,
    residential_count: residential.length,
    errors_count: errors.length,
    commercial,
    residential_summary: residential.map(r => ({ db_id: r.db_id, jobber_name: r.jobber_name, visits_total: r.visits_total })),
    errors,
  }, null, 2));
  console.log(`\nWrote: ${out}`);

  // CSV
  const csvOut = path.resolve(__dirname, `../../reports/jobber_commercial_no_code_${dateStr}.csv`);
  const csvLines = [['db_id', 'jobber_name', 'visits_total', 'visits_completed', 'last_completed', 'address', 'phone', 'email', 'isArchived', 'jobber_url'].join(',')];
  for (const c of commercial) {
    const esc = v => v == null ? '' : `"${String(v).replace(/"/g, '""')}"`;
    csvLines.push([c.db_id, esc(c.jobber_name), c.visits_total, c.visits_completed, c.last_completed || '', esc(c.address), esc(c.phone), esc(c.email), c.isArchived, esc(c.jobber_url)].join(','));
  }
  fs.writeFileSync(csvOut, csvLines.join('\n'));
  console.log(`Wrote: ${csvOut}`);
})().catch(e => { console.error(e); process.exit(1); });
