// scripts/probes/check_client_code_available.js
//
// Before assigning or renumbering a client code, check ALL THREE source
// systems (DB + Airtable + Jobber) for any client whose code starts with
// the proposed numeric prefix. A DB-only check is NOT enough — Airtable
// can hold a code that hasn't yet been written back to `public.clients.
// client_code` (e.g. 2026-05-29 Jerusalem Pizza was 226-JER in AT but
// NULL in DB, which is why the Aromas 214→226 rename earlier today
// collided with it).
//
// CLI:
//   node scripts/probes/check_client_code_available.js 227
//   node scripts/probes/check_client_code_available.js 227 PER     # also check the exact code 227-PER
//
// Exit code 0 if the prefix is free, 1 if any collision is found.
// Prints every collision row across all three systems.

const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const SB_URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

const prefix = process.argv[2];
const suffix = process.argv[3] || null;
if (!prefix || !/^\d+$/.test(prefix)) {
  console.error('Usage: node check_client_code_available.js <prefix> [<suffix>]');
  console.error('  e.g.  node check_client_code_available.js 227');
  console.error('  e.g.  node check_client_code_available.js 227 PER');
  process.exit(2);
}

async function getJobberToken() {
  const r = await fetch(`${SB_URL}/rest/v1/webhook_tokens?source_system=eq.jobber&select=access_token`, {
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}` },
  });
  return (await r.json())[0]?.access_token;
}

async function dbCheck() {
  // Match any client whose code starts with prefix-
  const q = `SELECT id, client_code, name, status FROM public.clients
             WHERE client_code ~ '^${prefix}(-|$)'
             OR (client_code IS NULL AND id IN (
                  SELECT entity_id FROM public.entity_source_links
                  WHERE entity_type='client' AND source_name ILIKE '${prefix}-%'
                ))
             ORDER BY id`;
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  return r.json();
}

async function atCheck() {
  const params = new URLSearchParams({ pageSize: '100' });
  params.append('fields[]', 'Client Code #3');
  params.append('fields[]', 'Client Name');
  params.append('filterByFormula', `LEFT({Client Code #3}, ${prefix.length + 1}) = "${prefix}-"`);
  const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/tbl5lXLtHKUWilDDj?${params}`, {
    headers: { Authorization: `Bearer ${AT_KEY}` },
  });
  const j = await r.json();
  return (j.records || []).map(rec => ({
    rec_id: rec.id,
    client_code: rec.fields['Client Code #3'],
    name: rec.fields['Client Name'],
  }));
}

async function jobberCheck(token) {
  // Jobber search by company name prefix — paginated `clients` query, filter by name
  let after = null, all = [];
  for (let page = 0; page < 5; page++) {
    const q = `query($after: String) { clients(first: 100, after: $after, searchTerm: "${prefix}-") {
      nodes { id companyName name }
      pageInfo { hasNextPage endCursor }
    } }`;
    const r = await fetch('https://api.getjobber.com/api/graphql', {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' },
      body: JSON.stringify({ query: q, variables: { after } }),
    });
    const j = await r.json();
    if (j.errors) { console.error('Jobber:', JSON.stringify(j.errors).slice(0, 300)); break; }
    const nodes = j.data?.clients?.nodes || [];
    // Filter to exactly prefix- since searchTerm is a substring search
    for (const n of nodes) {
      const cn = n.companyName || n.name || '';
      if (new RegExp(`^${prefix}-`).test(cn)) all.push({ gid: n.id, companyName: cn });
    }
    if (!j.data.clients.pageInfo.hasNextPage) break;
    after = j.data.clients.pageInfo.endCursor;
  }
  return all;
}

(async () => {
  console.log(`Checking client-code prefix ${prefix}${suffix ? ` (suffix filter: ${suffix})` : ''} across DB + Airtable + Jobber…\n`);

  const token = await getJobberToken();
  const [dbRows, atRows, jbRows] = await Promise.all([dbCheck(), atCheck(), jobberCheck(token)]);

  console.log(`[DB]       public.clients with code prefix ${prefix}-`);
  if (dbRows.length === 0) console.log('  (none)');
  else for (const r of dbRows) console.log(`  id=${r.id}  client_code=${r.client_code}  name=${r.name}  status=${r.status}`);

  console.log(`\n[Airtable] Clients table with Client Code #3 ~ "${prefix}-"`);
  if (atRows.length === 0) console.log('  (none)');
  else for (const r of atRows) console.log(`  ${r.rec_id}  ${r.client_code}  ${r.name}`);

  console.log(`\n[Jobber]   Clients whose companyName starts with "${prefix}-"`);
  if (jbRows.length === 0) console.log('  (none)');
  else for (const r of jbRows) console.log(`  ${r.gid}  "${r.companyName}"`);

  // Also check the exact suffix combination if specified
  let collision = dbRows.length + atRows.length + jbRows.length > 0;
  if (suffix) {
    const exact = `${prefix}-${suffix}`;
    const dbExact = dbRows.find(r => r.client_code === exact);
    const atExact = atRows.find(r => r.client_code === exact);
    const jbExact = jbRows.find(r => r.companyName.startsWith(exact + ' '));
    console.log(`\nExact code "${exact}" availability:`);
    console.log(`  DB:       ${dbExact ? `TAKEN (id=${dbExact.id})` : 'free'}`);
    console.log(`  Airtable: ${atExact ? `TAKEN (${atExact.rec_id})` : 'free'}`);
    console.log(`  Jobber:   ${jbExact ? `TAKEN (${jbExact.gid})` : 'free'}`);
    if (dbExact || atExact || jbExact) collision = true;
  }

  console.log(`\nResult: prefix ${prefix} ${collision ? 'has COLLISIONS — pick another number' : 'is AVAILABLE'}`);
  process.exit(collision ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
