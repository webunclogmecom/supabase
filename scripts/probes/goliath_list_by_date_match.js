// Re-match the 128 Airtable Goliath visits to our Supabase visits by
// (client_code + visit_date), since the AT Jobber Visit ID is empty on these.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error(`PG ${r.status}: ${r.body.slice(0,300)}`); return JSON.parse(r.body); }
async function listAT(table, fields, filter) {
  const out=[]; let offset; const enc=encodeURIComponent;
  do {
    const fp = (fields||[]).map(f => `fields%5B%5D=${enc(f)}`).join('&');
    const ff = filter ? `&filterByFormula=${enc(filter)}` : '';
    const path = `/v0/${AT_BASE}/${enc(table)}?${fp}&pageSize=100${ff}${offset?`&offset=${enc(offset)}`:''}`;
    const r = await http({hostname:'api.airtable.com',path,method:'GET',headers:{Authorization:`Bearer ${AT_KEY}`}});
    if (r.status>=300) throw new Error(`AT ${r.status}: ${r.body.slice(0,200)}`);
    const j = JSON.parse(r.body);
    for (const rec of (j.records||[])) out.push({id:rec.id, ...rec.fields});
    offset = j.offset;
  } while (offset);
  return out;
}

(async () => {
  console.log('[1/4] Pull Airtable visits with Goliath truck (2026)...');
  const atVisits = await listAT('Visits',
    ['Truck','Visit Date','Service Type','Client Code','Status','Jobber Visit ID'],
    `AND(IS_AFTER({Visit Date},'2025-12-31'),OR(FIND('Goliath',ARRAYJOIN({Truck}))>0,{Truck}='Goliath'))`);
  console.log(`  ${atVisits.length} AT visits to reattribute\n`);

  console.log('[2/4] Pull all 2026 Supabase visits + truck attribution...');
  const sbxVisits = await pg(`
    SELECT v.id AS visit_id, c.client_code, v.visit_date::text AS visit_date,
      v.visit_status, vh.name AS db_truck, v.title
    FROM visits v
    LEFT JOIN clients c ON c.id = v.client_id
    LEFT JOIN vehicles vh ON vh.id = v.vehicle_id
    WHERE v.visit_date >= '2026-01-01';`);
  console.log(`  ${sbxVisits.length} Supabase visits indexed\n`);

  // Build a lookup: (client_code + visit_date) → list of Supabase visits
  const sbxIndex = new Map();
  for (const v of sbxVisits) {
    if (!v.client_code) continue;
    const key = `${v.client_code}|${v.visit_date}`;
    if (!sbxIndex.has(key)) sbxIndex.set(key, []);
    sbxIndex.get(key).push(v);
  }
  // Also build ±1 day tolerance lookup
  function findMatches(client_code, target_date, tolerance_days = 1) {
    const matches = [];
    for (let off = -tolerance_days; off <= tolerance_days; off++) {
      const [y, m, d] = target_date.split('-').map(Number);
      const dt = new Date(Date.UTC(y, m - 1, d));
      dt.setUTCDate(dt.getUTCDate() + off);
      const altDate = dt.toISOString().slice(0, 10);
      const key = `${client_code}|${altDate}`;
      if (sbxIndex.has(key)) matches.push(...sbxIndex.get(key));
    }
    return matches;
  }

  console.log('[3/4] Match each AT Goliath visit against Supabase by (client_code + visit_date)...');
  const results = [];
  for (const av of atVisits) {
    const clientCode = Array.isArray(av['Client Code']) ? av['Client Code'][0] : av['Client Code'];
    const visitDate = av['Visit Date'];
    if (!clientCode || !visitDate) {
      results.push({...av, db_truck: 'NO_CLIENT_OR_DATE', db_visit_id: null, db_visit_date: null, db_title: null});
      continue;
    }
    const matches = findMatches(clientCode, visitDate, 1);
    if (matches.length === 0) {
      results.push({...av, db_truck: 'NO_MATCH', db_visit_id: null, db_visit_date: null, db_title: null});
    } else if (matches.length === 1) {
      const m = matches[0];
      results.push({...av, db_truck: m.db_truck || 'NULL', db_visit_id: m.visit_id, db_visit_date: m.visit_date, db_title: m.title});
    } else {
      // Multiple matches — pick the one with non-NULL truck, else first
      const withTruck = matches.find(m => m.db_truck);
      const m = withTruck || matches[0];
      results.push({...av, db_truck: m.db_truck || 'NULL', db_visit_id: m.visit_id, db_visit_date: m.visit_date, db_title: m.title, ambiguous: matches.length});
    }
  }

  console.log('[4/4] Building report...\n');

  // Summary
  const byTruck = {};
  for (const r of results) {
    if (!byTruck[r.db_truck]) byTruck[r.db_truck] = 0;
    byTruck[r.db_truck]++;
  }
  console.log('Reattribution summary:');
  for (const [truck, count] of Object.entries(byTruck).sort((a,b) => b[1]-a[1])) {
    let action = '';
    if (truck === 'David') action = '→ Update AT Truck to David 2,000';
    else if (truck === 'Moises') action = '→ Update AT Truck to Moises 9,000';
    else if (truck === 'Cloggy') action = '→ Update AT Truck to Cloggy 120';
    else if (truck === 'NULL') action = '→ GPS gap, defer to operator memory';
    else if (truck === 'NO_MATCH') action = '→ AT visit has no Supabase counterpart (AT-only or pre-cleanup)';
    else action = '→ Manual review';
    console.log(`  ${truck.padEnd(15)} ${String(count).padStart(4)}  ${action}`);
  }

  // Output markdown
  const md = [];
  md.push(`# Goliath reattribution list — ${new Date().toISOString().slice(0,10)}\n`);
  md.push(`## What this is\n`);
  md.push(`128 Airtable 2026 visits have \`Truck = "Goliath 5,000"\`. Goliath was decommissioned 2026-05-01 and has zero Samsara telemetry, so those labels can't reflect reality. Our Supabase \`visits.vehicle_id\` is derived from Samsara GPS cross-reference against property coordinates (ADR 012). This list maps each AT Goliath-labeled visit to our DB's correctly-attributed truck.\n`);
  md.push(`Matching strategy: AT has empty \`Jobber Visit ID\` on these 128 visits, so we match by (\`Client Code\` + \`Visit Date\` ±1 day). The ±1 day tolerance catches the common ET-vs-UTC date confusion between AT and Jobber.\n`);
  md.push(`## Summary\n`);
  md.push(`| Our DB says truck = | Count | Action for ops |`);
  md.push(`|---|---|---|`);
  for (const [truck, count] of Object.entries(byTruck).sort((a,b) => b[1]-a[1])) {
    let action = '';
    if (truck === 'David') action = 'Update Airtable Truck → **David 2,000**';
    else if (truck === 'Moises') action = 'Update Airtable Truck → **Moises 9,000**';
    else if (truck === 'Cloggy') action = 'Update Airtable Truck → **Cloggy 120**';
    else if (truck === 'NULL') action = 'GPS had no overlap (telemetry gap or off-site work) — defer to operator memory';
    else if (truck === 'NO_MATCH') action = 'No matching Supabase visit found — AT-only entry; check separately';
    else if (truck === 'NO_CLIENT_OR_DATE') action = 'AT visit missing client_code or date';
    else action = `Manual review (${truck})`;
    md.push(`| ${truck} | ${count} | ${action} |`);
  }

  md.push(`\n## Full reattribution list\n`);
  md.push(`Grouped by correct truck for ops convenience. Sorted by visit_date desc within each group.\n`);

  for (const groupTruck of ['David', 'Moises', 'Cloggy', 'NULL', 'NO_MATCH', 'NO_CLIENT_OR_DATE']) {
    const group = results.filter(r => r.db_truck === groupTruck).sort((a,b) => (b['Visit Date']||'').localeCompare(a['Visit Date']||''));
    if (group.length === 0) continue;
    md.push(`\n### ${groupTruck} (${group.length})\n`);
    md.push(`| AT Visit Date | Client Code | Service | AT Status | DB visit_id | DB title | DB date (if mismatch) |`);
    md.push(`|---|---|---|---|---|---|---|`);
    for (const r of group) {
      const clientCode = Array.isArray(r['Client Code']) ? r['Client Code'][0] : r['Client Code'];
      const dbDateNote = r.db_visit_date && r.db_visit_date !== r['Visit Date'] ? r.db_visit_date : '';
      md.push(`| ${r['Visit Date']||'-'} | ${clientCode||'-'} | ${r['Service Type']||'-'} | ${r['Status']||'-'} | ${r.db_visit_id || '-'} | ${(r.db_title||'').replace(/\|/g,'\\|').slice(0,40)} | ${dbDateNote} |`);
    }
  }

  const outPath = path.resolve(__dirname, `../../reports/goliath_reattribution_2026_05_12.md`);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, md.join('\n'));
  console.log(`\n✓ Report: ${outPath}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
