// scripts/probes/check_client_code_available.js
//
// Before assigning or renumbering a client code, check BOTH remaining
// LIVE systems (DB + Jobber) for any client whose code starts with the
// proposed numeric prefix. A DB-only check is NOT enough — Jobber can hold a
// code typed into the Company Name that has not been parsed into
// `public.clients.client_code` yet.
//
// AIRTABLE WAS THE THIRD SOURCE AND IS GONE. It was sunsetted 2026-07-24 and
// must never be queried again (see the workspace CLAUDE.md / memory
// project_airtable_sunset). Its historical value here was real — on 2026-05-29
// Jerusalem Pizza was 226-JER in Airtable but NULL in the DB, which is how the
// Aromas 214→226 rename collided — but that data now lives in `public.clients`,
// so the DB check covers it. Do NOT re-add an Airtable branch.
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

// atCheck() removed 2026-07-28: it queried the Airtable Clients table, and Airtable
// was sunsetted 2026-07-24. Leaving a live call to a dead API here would have made
// this probe report "(none)" for Airtable forever, which reads as "checked and clear"
// rather than "not checked" — a false all-clear on the exact question the probe exists
// to answer. The DB check now covers it; those codes were migrated into public.clients.

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
    if (j.errors || !j.data?.clients) { console.error('Jobber unavailable (skipping Jobber check):', JSON.stringify(j.errors || j).slice(0, 200)); return null; }
    const nodes = j.data.clients.nodes || [];
    // Filter to exactly prefix- since searchTerm is a substring search
    for (const n of nodes) {
      const cn = n.companyName || n.name || '';
      if (new RegExp(`^${prefix}-`).test(cn)) all.push({ gid: n.id, companyName: cn });
    }
    if (!j.data.clients.pageInfo?.hasNextPage) break;
    after = j.data.clients.pageInfo.endCursor;
  }
  return all;
}

(async () => {
  console.log(`Checking client-code prefix ${prefix}${suffix ? ` (suffix filter: ${suffix})` : ''} across DB + Jobber…\n`);

  const token = await getJobberToken();
  const [dbRows, jbRows] = await Promise.all([dbCheck(), jobberCheck(token)]);

  console.log(`[DB]       public.clients with code prefix ${prefix}-`);
  if (dbRows.length === 0) console.log('  (none)');
  else for (const r of dbRows) console.log(`  id=${r.id}  client_code=${r.client_code}  name=${r.name}  status=${r.status}`);

  console.log(`\n[Jobber]   Clients whose companyName starts with "${prefix}-"`);
  if (jbRows === null) console.log('  SKIPPED — Jobber unavailable; result reflects the DB only');
  else if (jbRows.length === 0) console.log('  (none)');
  else for (const r of jbRows) console.log(`  ${r.gid}  "${r.companyName}"`);

  // Also check the exact suffix combination if specified
  let collision = dbRows.length + (jbRows ? jbRows.length : 0) > 0;
  if (suffix) {
    const exact = `${prefix}-${suffix}`;
    const dbExact = dbRows.find(r => r.client_code === exact);
    const jbExact = jbRows ? jbRows.find(r => r.companyName.startsWith(exact + ' ')) : null;
    console.log(`\nExact code "${exact}" availability:`);
    console.log(`  DB:       ${dbExact ? `TAKEN (id=${dbExact.id})` : 'free'}`);
    console.log(`  Jobber:   ${jbExact ? `TAKEN (${jbExact.gid})` : 'free'}`);
    if (dbExact || jbExact) collision = true;
  }

  console.log(`\nResult: prefix ${prefix} ${collision ? 'has COLLISIONS — pick another number' : 'is AVAILABLE'}`);
  process.exit(collision ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
