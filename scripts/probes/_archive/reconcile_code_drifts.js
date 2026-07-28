// For the 8 Samsara geofences whose code prefix doesn't match any active
// client in our DB, look up the canonical code in AT Clients (primary source
// of truth for client_code per CLAUDE.md) and Jobber (fallback).
//
// Output: a per-row reconciliation plan — either update clients.client_code
// or rename the Samsara geofence.
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SAM = process.env.SAMSARA_API_TOKEN;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const JOBBER_TOKEN = process.env.JOBBER_ACCESS_TOKEN;

const H = { apikey: KEY, Authorization: `Bearer ${KEY}` };
const AT_H = { Authorization: `Bearer ${AT_KEY}` };

async function rest(qs, opts = {}) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, { ...opts, headers: { ...H, ...(opts.headers || {}) } });
  if (!r.ok) throw new Error(`REST ${r.status} ${await r.text()}`);
  return r.json();
}
async function samsara(p) {
  const r = await fetch(`https://api.samsara.com${p}`, { headers: { Authorization: `Bearer ${SAM}` } });
  if (!r.ok) throw new Error(`Samsara ${r.status}`);
  return r.json();
}
async function airtable(t, qs = '') {
  const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/${encodeURIComponent(t)}?${qs}`, { headers: AT_H });
  if (!r.ok) throw new Error(`AT ${r.status} ${await r.text()}`);
  return r.json();
}
async function jobber(query, variables = {}) {
  const r = await fetch('https://api.getjobber.com/api/graphql', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${JOBBER_TOKEN}`,
      'Content-Type': 'application/json',
      'X-JOBBER-GRAPHQL-VERSION': '2025-04-16',
    },
    body: JSON.stringify({ query, variables }),
  });
  const j = await r.json();
  if (j.errors) throw new Error(`Jobber: ${JSON.stringify(j.errors)}`);
  return j.data;
}

function normalize(s) {
  return (s || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

(async () => {
  // The 8 drifted Samsara geofences identified in the audit
  const targets = [
    { sam_code: '014-FEN', sam_name: 'Fendi Château Residences' },
    { sam_code: '019-GT',  sam_name: 'G7 Kitchens 34&35' },
    { sam_code: '057-BAY', sam_name: 'Bayshore executive Plaza SLS' },
    { sam_code: '132-PU',  sam_name: 'Pummarola' },
    { sam_code: '133-MU',  sam_name: 'Mutra' },
    { sam_code: '140-TCY', sam_name: 'Tacos yoyo' },
    { sam_code: '167-JOY', sam_name: 'The Joyce' },
    { sam_code: '199-STK', sam_name: 'Steak House' },
  ];

  // Pull full AT Clients table once
  console.log('Pulling AT Clients table...');
  const atRecords = [];
  let offset = null;
  do {
    const qs = new URLSearchParams({ pageSize: '100' });
    if (offset) qs.set('offset', offset);
    const r = await airtable('Clients', qs.toString());
    atRecords.push(...(r.records || []));
    offset = r.offset;
  } while (offset);
  console.log(`  ${atRecords.length} AT records pulled\n`);

  // Show fields of a sample
  if (atRecords[0]) {
    console.log('AT sample fields:', Object.keys(atRecords[0].fields || {}).slice(0, 20).join(', '), '\n');
  }

  // Canonical fields per AT schema
  const codeField = 'Client Code #3';
  const nameField = 'Client Name';
  console.log(`Using AT field for code: "${codeField}", name: "${nameField}"\n`);

  // Reconcile each target
  const findings = [];
  for (const t of targets) {
    const ntn = normalize(t.sam_name);
    // 1) AT match by name fuzzy
    let atMatches = [];
    for (const r of atRecords) {
      const an = normalize(r.fields?.[nameField]);
      if (!an) continue;
      if (an.includes(ntn) || ntn.includes(an)) atMatches.push(r);
    }
    // Tighten if too many — require code overlap or substring of ≥6 chars
    if (atMatches.length > 5) {
      atMatches = atMatches.filter(r => {
        const an = normalize(r.fields?.[nameField]);
        return an.length >= 6 && (an === ntn || an.startsWith(ntn.slice(0, 8)));
      });
    }

    const atSummary = atMatches.map(r => ({
      at_code: r.fields?.[codeField],
      at_name: r.fields?.[nameField],
      at_id: r.id,
    }));

    // 2) DB lookup — does any client by this AT code already exist?
    let dbMatches = [];
    if (atMatches.length === 1 && atMatches[0].fields?.[codeField]) {
      const code = atMatches[0].fields[codeField];
      dbMatches = await rest(`clients?client_code=eq.${encodeURIComponent(code)}&select=id,client_code,name,status`);
    }

    findings.push({
      sam_code: t.sam_code,
      sam_name: t.sam_name,
      at_matches: atSummary,
      db_match: dbMatches[0] || null,
    });
  }

  // Print results
  for (const f of findings) {
    console.log(`\n--- Samsara: ${f.sam_code} ${f.sam_name} ---`);
    if (f.at_matches.length === 0) {
      console.log('  AT: no match by name → likely AT-only or renamed; needs Yannick eyeballing');
    } else if (f.at_matches.length === 1) {
      const m = f.at_matches[0];
      const drifted = m.at_code !== f.sam_code;
      console.log(`  AT: ${m.at_code} ${m.at_name} (rec ${m.at_id})`);
      if (drifted) {
        console.log(`  ⚠ AT code (${m.at_code}) ≠ Samsara code (${f.sam_code})`);
        if (f.db_match) {
          console.log(`  DB: ${f.db_match.client_code} ${f.db_match.name} (id=${f.db_match.id}, ${f.db_match.status})`);
          if (f.db_match.client_code === m.at_code) {
            console.log(`  ✅ DB matches AT — Samsara is the outlier. Action: rename Samsara geofence`);
          } else {
            console.log(`  ⚠ DB code ≠ AT code either — Action: update DB to AT, rename Samsara to AT`);
          }
        } else {
          console.log(`  DB: no client with code ${m.at_code}`);
        }
      } else {
        console.log(`  AT and Samsara agree on code — but DB doesn't have it`);
      }
    } else {
      console.log(`  AT: ${f.at_matches.length} candidates — ambiguous, surface to Yannick:`);
      for (const m of f.at_matches) {
        console.log(`    - ${m.at_code} ${m.at_name}`);
      }
    }
  }

  // Also: check for clients in our DB with each Samsara code as canonical
  console.log('\n--- For reference: DB clients whose code prefix matches the SAMSARA codes ---');
  for (const t of targets) {
    const r = await rest(`clients?client_code=eq.${encodeURIComponent(t.sam_code)}&select=id,client_code,name,status`);
    console.log(`  ${t.sam_code}: ${r.length ? JSON.stringify(r[0]) : 'NO DB ROW'}`);
  }
})().catch(err => { console.error(err); process.exit(1); });
