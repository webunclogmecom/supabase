// 98_jobber_at_client_diff.mjs
// Cross-reference Jobber clients vs Airtable clients. Bucket into:
//   A) In Jobber only (missing from AT)
//   B) In AT only (missing from Jobber)
//   C) In both (matched by client_code OR name)
//
// Special focus: clients WITHOUT a client_code in either system.
//
// Matching strategy: try client_code first (exact, case-insensitive after
// trimming). If no code, fall back to name (case-insensitive substring or
// exact). Names get normalized: lowercased, spaces collapsed, punctuation
// stripped.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${(await r.text()).slice(0, 600)}`);
  return JSON.parse(await r.text());
}

async function fetchAll(table) {
  const all = [];
  let offset = null;
  do {
    const q = new URLSearchParams();
    q.set('pageSize', '100');
    if (offset) q.set('offset', offset);
    const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/${encodeURIComponent(table)}?${q}`, {
      headers: { Authorization: `Bearer ${AT_KEY}` },
    });
    const j = await r.json();
    all.push(...(j.records || []));
    offset = j.offset;
  } while (offset);
  return all;
}

// Normalize names for fuzzy matching: lowercase, collapse whitespace,
// strip punctuation, drop trailing/leading whitespace.
const normName = (s) => String(s || '')
  .toLowerCase()
  .replace(/[^\w\s]/g, ' ')
  .replace(/\s+/g, ' ')
  .trim();

// Extract client_code from a Jobber companyName like "043-MIL Mila".
// Returns { code: "043-MIL", name: "Mila" } or { code: null, name: <whole> }.
function parseJobberCompany(company) {
  if (!company) return { code: null, name: '' };
  const m = String(company).match(/^\s*(\d{3}-[A-Za-z0-9]+)\s+(.+)$/);
  if (m) return { code: m[1].toUpperCase(), name: m[2].trim() };
  return { code: null, name: String(company).trim() };
}

// --- pull both sides ----------------------------------------------------------

console.log('Fetching AT Clients...');
const atRecords = await fetchAll('Clients');
console.log(`  ${atRecords.length} AT records`);

console.log('Fetching Jobber raw clients...');
const jbRecords = await pg(`
  SELECT data->>'id' AS gid,
         data->>'companyName' AS company,
         data->>'name' AS name,
         data->>'firstName' AS first_name,
         data->>'lastName' AS last_name
  FROM raw.jobber_pull_clients;
`);
console.log(`  ${jbRecords.length} Jobber raw clients`);

// --- shape both sides into a common record ------------------------------------

const atClients = atRecords.map(r => {
  const f = r.fields || {};
  // AT "Client Code #3" is the canonical client code field per CLAUDE.md.
  const code = (f['Client Code #3'] || f['Client Code'] || '').toString().trim().toUpperCase() || null;
  const name = String(f['Client Name'] || f['Name'] || '').trim();
  const status = String(f['ACTIVE/INACTIVE'] || '').trim().toUpperCase();
  return { at_id: r.id, code, name, status, normName: normName(name) };
});

const jbClients = jbRecords.map(r => {
  const parsed = parseJobberCompany(r.company);
  // Fall back to firstName + lastName for residential clients with no company.
  const personal = [r.first_name, r.last_name].filter(Boolean).join(' ').trim();
  const finalName = parsed.name || r.name || personal || '(no name)';
  return {
    gid: r.gid,
    code: parsed.code,
    name: finalName,
    is_residential: !r.company && (personal || r.name),
    normName: normName(finalName),
  };
});

// --- build lookup maps --------------------------------------------------------

const atByCode = new Map();
const atByName = new Map();
for (const c of atClients) {
  if (c.code) atByCode.set(c.code, c);
  if (c.normName) {
    if (!atByName.has(c.normName)) atByName.set(c.normName, []);
    atByName.get(c.normName).push(c);
  }
}

const jbByCode = new Map();
const jbByName = new Map();
for (const c of jbClients) {
  if (c.code) jbByCode.set(c.code, c);
  if (c.normName) {
    if (!jbByName.has(c.normName)) jbByName.set(c.normName, []);
    jbByName.get(c.normName).push(c);
  }
}

// --- bucket ------------------------------------------------------------------

const jobberOnly = []; // in Jobber, not in AT
const atOnly = [];     // in AT, not in Jobber

for (const jb of jbClients) {
  let matched = false;
  if (jb.code && atByCode.has(jb.code)) matched = true;
  else if (jb.normName && atByName.has(jb.normName)) matched = true;
  if (!matched) jobberOnly.push(jb);
}

for (const at of atClients) {
  let matched = false;
  if (at.code && jbByCode.has(at.code)) matched = true;
  else if (at.normName && jbByName.has(at.normName)) matched = true;
  if (!matched) atOnly.push(at);
}

// --- output ------------------------------------------------------------------

const banner = (s) => console.log(`\n${'='.repeat(70)}\n${s}\n${'='.repeat(70)}`);

banner('SUMMARY');
console.log({
  at_total: atClients.length,
  jb_total: jbClients.length,
  jobber_only: jobberOnly.length,
  jobber_only_no_code: jobberOnly.filter(c => !c.code).length,
  jobber_only_residential: jobberOnly.filter(c => c.is_residential).length,
  at_only: atOnly.length,
  at_only_no_code: atOnly.filter(c => !c.code).length,
});

banner(`A) In JOBBER but NOT in AT (${jobberOnly.length})`);
console.log(`  -- with client code --`);
jobberOnly.filter(c => c.code).forEach(c => {
  console.log(`    ${c.code.padEnd(12)}  ${c.name}  ${c.is_residential ? '[residential]' : ''}`);
});
console.log(`\n  -- NO client code --`);
jobberOnly.filter(c => !c.code).forEach(c => {
  console.log(`    ${'—'.padEnd(12)}  ${c.name}  ${c.is_residential ? '[residential]' : ''}  (gid ${c.gid.slice(0, 40)}...)`);
});

banner(`B) In AT but NOT in Jobber (${atOnly.length})`);
console.log(`  -- with client code --`);
atOnly.filter(c => c.code).forEach(c => {
  console.log(`    ${c.code.padEnd(12)}  ${c.name}  [${c.status || '?'}]`);
});
console.log(`\n  -- NO client code --`);
atOnly.filter(c => !c.code).forEach(c => {
  console.log(`    ${'—'.padEnd(12)}  ${c.name || '(no name)'}  [${c.status || '?'}]  ${c.at_id}`);
});
