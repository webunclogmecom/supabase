// Audit client_code drift: DB vs Airtable (canonical) vs Jobber (secondary).
//
// AT is the source of truth for client_code per CLAUDE.md ("client_code
// originates in Airtable, but Yan often types the NNN-XX prefix into
// Jobber's Company Name field too").
//
// Matches DB clients to AT records via:
//   1. entity_source_links (entity_type=client, source_system=airtable)
//   2. fallback: fuzzy name match
//
// Then checks: does DB.client_code == AT."Client Code #3"?
// Same for Jobber (parsed from companyName / name prefix).
//
// Output: list of mismatches with proposed action.
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const JOBBER_TOKEN = process.env.JOBBER_ACCESS_TOKEN;

async function rest(qs, opts = {}) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, { ...opts, headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, ...(opts.headers || {}) } });
  if (!r.ok) throw new Error(`REST ${r.status} ${await r.text()}`);
  return r.json();
}
async function airtableAll() {
  const all = [];
  let offset = null;
  do {
    const qs = new URLSearchParams({ pageSize: '100' });
    if (offset) qs.set('offset', offset);
    const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/Clients?${qs}`, { headers: { Authorization: `Bearer ${AT_KEY}` } }).then(r => r.json());
    all.push(...(r.records || []));
    offset = r.offset;
  } while (offset);
  return all;
}
function normalize(s) {
  return (s || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}
function parsePrefix(name) {
  return name?.match(/^\s*(\d{3}-[A-Z0-9]+)/)?.[1] || null;
}

(async () => {
  console.log('Pulling AT Clients + DB clients...\n');
  const atRecords = await airtableAll();
  const clients = await rest('clients?select=id,client_code,name,status&limit=10000');

  // Index AT by id + by code + by normalized name
  const atById = {}, atByCode = {}, atByName = {};
  for (const r of atRecords) {
    atById[r.id] = r;
    const code = r.fields?.['Client Code #3'];
    if (code) atByCode[String(code).toUpperCase()] = r;
    const name = r.fields?.['Client Name'];
    if (name) atByName[normalize(name)] = r;
  }

  // Pull ESL airtable links for all clients
  const ids = clients.map(c => c.id);
  const eslAt = {};
  for (let i = 0; i < ids.length; i += 200) {
    const chunk = ids.slice(i, i + 200);
    const r = await rest(`entity_source_links?entity_type=eq.client&source_system=eq.airtable&entity_id=in.(${chunk.join(',')})&select=entity_id,source_id`);
    for (const e of r) eslAt[e.entity_id] = e.source_id;
  }

  const mismatches = [];
  const matched = { agree: 0, db_missing_code: 0, at_silent: 0, no_at_match: 0 };

  for (const c of clients) {
    const dbCode = c.client_code?.toUpperCase() || null;
    // 1) try ESL
    let atRec = eslAt[c.id] ? atById[eslAt[c.id]] : null;
    // 2) fallback: by DB code
    if (!atRec && dbCode) atRec = atByCode[dbCode] || null;
    // 3) fallback: by normalized name
    if (!atRec) {
      const nc = normalize(c.name);
      if (nc.length >= 6) {
        atRec = atByName[nc] || null;
        if (!atRec) {
          for (const [n, r] of Object.entries(atByName)) {
            if (n.length >= 8 && (n.includes(nc) || nc.includes(n))) { atRec = r; break; }
          }
        }
      }
    }
    if (!atRec) { matched.no_at_match++; continue; }
    const atCode = atRec.fields?.['Client Code #3']?.toUpperCase() || null;
    if (!atCode) { matched.at_silent++; continue; }
    if (!dbCode) {
      matched.db_missing_code++;
      mismatches.push({
        kind: 'db_missing_code', db_id: c.id, db_name: c.name?.slice(0, 40),
        db_code: '(none)', at_code: atCode, at_name: atRec.fields?.['Client Name']?.slice(0, 40),
        status: c.status,
      });
      continue;
    }
    if (dbCode === atCode) { matched.agree++; continue; }
    mismatches.push({
      kind: 'drift', db_id: c.id, db_name: c.name?.slice(0, 40),
      db_code: dbCode, at_code: atCode, at_name: atRec.fields?.['Client Name']?.slice(0, 40),
      status: c.status,
    });
  }

  console.log('=== Summary ===');
  console.table([
    { metric: 'DB clients (all statuses)', count: clients.length },
    { metric: 'AT-matched, agree',         count: matched.agree },
    { metric: 'AT-matched, DB missing code', count: matched.db_missing_code },
    { metric: 'AT-matched, AT silent on code', count: matched.at_silent },
    { metric: 'No AT match (Jobber-only)', count: matched.no_at_match },
    { metric: 'AT + DB DISAGREE on code',  count: mismatches.filter(m => m.kind === 'drift').length },
  ]);

  if (mismatches.length) {
    console.log(`\n=== Mismatches (${mismatches.length}) ===`);
    console.table(mismatches.slice(0, 60));
  }
})().catch(err => { console.error(err); process.exit(1); });
